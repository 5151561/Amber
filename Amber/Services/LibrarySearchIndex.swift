import Foundation

/// `search_index` 那张 FTS5 表：怎么重建、怎么跟着增删改走、怎么问「这个词命中了哪些 id」。
///
/// **分工。** [`LibrarySearch`](LibrarySearch.swift) 是**纯文本层**（切词、拼音、查询串生成），
/// 一个字都不碰数据库；这一层只管那张表，不认识界面。七处搜索最终都落到这里的
/// `matchedIDs`，而调用方看到的只有 `LibraryStore.searchFilter(_:kind:)` 一个入口。
///
/// ## 这张表覆盖什么
///
/// - `track`：`track` 表里的**每一行**，不只是资料库里那些。理由是维护挂在
///   `LibraryStore.persistTracks` 上——那是曲目行写入的唯一漏斗，挂在那儿就不可能漏；
///   而 `track` 表故意不做 GC（见 schema 注释），所以曲目只有增改、没有删。
///   索引比资料库宽没有坏处：七处搜索各自筛的是**自己手里那份数组**，
///   表只回答「这个词命中了哪些 id」，命中了一个没在数组里的 id 不会凭空多出一行。
/// - `album` / `playlist`：`library_album` / `playlist` 两张表的行，一一对应。
/// - `artist`：**派生的**，没有源表也就没有自己的增删改调用点，
///   只能在动过 `library_album` / `library_track` 之后对一遍账（见 `reconcileArtists`）。
///
/// ## 为什么要一份内存里的指纹
///
/// `owner_id` 是 FTS5 的 `UNINDEXED` 列，`WHERE owner_id = ?` 是**全表扫**（FTS5 只给
/// 分词那几列建倒排索引，普通列没有 B 树）。而 `persistTracks` 是每一次起播、每一次
/// 列表重写都要走的路——每首歌扫一遍表再重算一次拼音，量一上来就是平方。
///
/// 于是这里记一份 `owner → 正文指纹`：**正文没变就一条语句都不发**。
/// 指纹取的是切分后正文的 `hashValue`（不是原串），这样开库时从表里那三列直接就能算出来，
/// 与写入时算的是同一个东西。真正要发语句的只剩「新对象」（纯 INSERT，不用扫）
/// 和「改过名」（DELETE + INSERT，此时那一次扫是值得的，本来就少）。
///
/// **事务回滚之后这份指纹会与表对不上**（内存说写过了，表里回滚掉了）。不补救，
/// 因为落库失败已经把 `LibraryStore.mirrorIsStale` 竖起来了，这一程的搜索一律退回
/// 内存筛选、根本不看这张表；下次开库指纹又是从表里现读的。
@MainActor
final class LibrarySearchIndex {

    /// 四种可搜对象。`rawValue` 就是 `owner_kind` 列里存的那个字符串。
    enum Kind: String {
        case track, album, playlist, artist
    }

    /// `owner → 已入库正文的指纹`。键是 `kind + \u{1} + id`：`owner_id` 在四种对象之间
    /// **不保证唯一**（音源的曲目 id 与专辑 id 各自成体系，撞上了谁也拦不住），
    /// 所以这张表的「一行」由 (kind, id) 一起认，删除的 WHERE 也带上 `owner_kind`。
    private var fingerprints: [String: Int] = [:]

    private static func cacheKey(_ kind: Kind, _ id: String) -> String {
        kind.rawValue + "\u{1}" + id
    }

    // MARK: - 开库时读一次

    /// 把表里现有的正文指纹读进内存。
    ///
    /// 与 `LibraryStore.loadFromDatabase` 同一条纪律：**先读进局部变量，读完了才赋值**。
    /// 读到一半抛错时留下半份指纹，比没有指纹更糟——后续写入会以为某些行已经在表里而跳过。
    func load(from db: SQLiteDatabase) throws {
        var loaded: [String: Int] = [:]
        for row in try db.query(
            "SELECT owner_kind, owner_id, name, artist, album FROM search_index", [],
            { (kind: $0.text(0), id: $0.text(1),
               fingerprint: Self.fingerprint($0.text(2), $0.text(3), $0.text(4))) }) {
            guard let kind = Kind(rawValue: row.kind) else { continue }
            loaded[Self.cacheKey(kind, row.id)] = row.fingerprint
        }
        fingerprints = loaded
    }

    /// 正文指纹：**切分之后**那三列拼起来求哈希。
    ///
    /// 取切分后而不是原串，是为了让「开库时从表里三列现算」与「写入时从模型字段现算」
    /// 得出同一个值——表里存的本来就是切分后的正文。拼音那一列不进指纹：它是这三列的函数。
    ///
    /// `Hasher` 的种子每进程一换，所以这个值**不能落盘**、也不能跨进程比。
    /// 这里两头都在同一个进程里（开库读一次、这一程的写入各算一次），正合用；
    /// 真要落盘就得换成稳定哈希，那又是另一份要维护的东西，没必要。
    private static func fingerprint(_ name: String, _ artist: String, _ album: String) -> Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(artist)
        hasher.combine(album)
        return hasher.finalize()
    }

    /// 某一类已经在索引里的 id（从内存那份指纹里取，不问库）。
    func ids(of kind: Kind) -> Set<String> {
        let prefix = kind.rawValue + "\u{1}"
        return Set(fingerprints.keys.lazy
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) })
    }

    // MARK: - 维护

    private static let insertSQL = """
        INSERT INTO search_index (name, artist, album, phonetic, owner_kind, owner_id)
        VALUES (?,?,?,?,?,?)
        """

    /// 入库 / 改名。正文没变就一条语句都不发（见类型头上那段）。
    ///
    /// 写进去的行由 `LibrarySearch.indexRow` 出，列序与建表语句一致——
    /// 正文按字段分列（短语只在列内谈相邻），拼音合成一列。
    func upsert(_ kind: Kind, id: String, name: String, artist: String = "", album: String = "",
                in db: SQLiteDatabase) throws {
        let current = Self.fingerprint(LibrarySearch.segment(name),
                                      LibrarySearch.segment(artist),
                                      LibrarySearch.segment(album))
        let key = Self.cacheKey(kind, id)
        if let known = fingerprints[key] {
            guard known != current else { return }
            // 改过名：先撤掉旧行。这一条是全表扫，但它只发生在真改了名的时候。
            try Self.deleteRows(kind, id: id, in: db)
        }
        let row = LibrarySearch.indexRow(name: name, artist: artist, album: album)
        try db.run(Self.insertSQL,
                   [row.name, row.artist, row.album, row.phonetic, kind.rawValue, id])
        fingerprints[key] = current
    }

    /// 退库 / 删除。
    ///
    /// **不拿内存指纹当闸**：指纹只管「要不要重写」，该删的一律真发一条 DELETE。
    /// 指纹哪天与表对不上（事务回滚过），漏删留下的是一条搜得到却打不开的幽灵，
    /// 比多发一条语句糟得多。
    func delete(_ kind: Kind, id: String, in db: SQLiteDatabase) throws {
        fingerprints.removeValue(forKey: Self.cacheKey(kind, id))
        try Self.deleteRows(kind, id: id, in: db)
    }

    /// 普通 FTS5 表支持直接 DELETE（external content 表不支持，这也是 schema 选普通表的
    /// 理由之一）。`owner_kind` 一起进 WHERE，理由见 `fingerprints` 上那段。
    private static func deleteRows(_ kind: Kind, id: String, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
                   [kind.rawValue, id])
    }

    /// 艺人那一档对账：库里现在该有哪些艺人，表里就留哪些。
    ///
    /// 艺人是从专辑 / 曲目的艺人名**派生**的，没有「新建一位艺人」这种动作，
    /// 所以它没法像其余三类那样挂在某个写入漏斗上。处置是在动过 `library_album` /
    /// `library_track` 的那几次写之后跑一遍这个对账：多出来的撤掉、少的补上、
    /// 名字没变的一条语句都不发（`upsert` 自己会判）。
    ///
    /// 代价是每次对账要把候选序列现算一遍（两张小表的扫描），发生在「入库 / 退库 /
    /// 改曲目」这种用户点一下的路径上，不在起播、记账那条热路上。
    func reconcileArtists(_ wanted: [(id: String, name: String)],
                          in db: SQLiteDatabase) throws {
        let wantedIDs = Set(wanted.map(\.id))
        for id in ids(of: .artist).subtracting(wantedIDs) {
            try delete(.artist, id: id, in: db)
        }
        for artist in wanted {
            try upsert(.artist, id: artist.id, name: artist.name, in: db)
        }
    }

    // MARK: - 全量重建

    /// 把整张索引推倒重来，源是库里现有的 `track` / `library_album` / `playlist` 与派生艺人。
    ///
    /// **幂等**：先清空再灌，跑几次结果都一样，所以它既能当升级链上的一次性修复
    /// （`AmberDatabase` 的 v4），也能在任何时候被再调一次。
    ///
    /// 不碰内存指纹（`static`，压根没有实例）：调这个函数的时机只有开库那一下，
    /// 此时 `LibraryStore` 还没建出来，它的 `load` 随后会从重建好的表里现读。
    static func rebuild(in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM search_index")

        func insert(_ row: LibrarySearch.IndexRow, _ kind: Kind, _ id: String) throws {
            try db.run(insertSQL, [row.name, row.artist, row.album, row.phonetic,
                                   kind.rawValue, id])
        }

        for track in try db.query("SELECT id, title, artist_name, album_name FROM track", [], {
            (id: $0.text(0), title: $0.text(1), artist: $0.text(2), album: $0.text(3))
        }) {
            try insert(LibrarySearch.indexRow(name: track.title, artist: track.artist,
                                              album: track.album), .track, track.id)
        }
        for album in try db.query("SELECT id, name, artist_name FROM library_album", [], {
            (id: $0.text(0), name: $0.text(1), artist: $0.text(2))
        }) {
            try insert(LibrarySearch.indexRow(name: album.name, artist: album.artist),
                       .album, album.id)
        }
        for playlist in try db.query("SELECT id, name, source_json FROM playlist", [], {
            (id: $0.text(0), name: $0.text(1), source: $0.optText(2))
        }) {
            try insert(LibrarySearch.indexRow(name: playlist.name,
                                              artist: creatorName(playlist.source)),
                       .playlist, playlist.id)
        }
        for artist in try derivedArtists(in: db) {
            try insert(LibrarySearch.indexRow(name: artist.name), .artist, artist.id)
        }
    }

    /// 歌单的 `artist` 列放**创建者**：本地自建列表没有创建者，那一列就是空串。
    /// 创建者藏在 `source_json` 里（`LibraryPlaylist.source` 整块存的 JSON）。
    private static func creatorName(_ sourceJSON: String?) -> String {
        sourceJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Playlist.self, from: $0) }?
            .creatorName ?? ""
    }

    /// 库里现在派生得出哪些艺人。
    ///
    /// **与 `LibraryStore.libraryArtists()` 共用候选 SQL 与去重规则**，两边必须是同一批
    /// id：艺人页列的是那个函数的结果，而搜索筛的是这里写进表的 id，
    /// 两份规则一旦漂移，表现是「艺人页上有这个人、搜他的名字却搜不到」。
    static func derivedArtists(in db: SQLiteDatabase) throws -> [(id: String, name: String)] {
        let candidates = try db.query(LibraryStore.artistCandidatesSelect, [], {
            (name: $0.text(0), kind: ProviderKind(rawValue: $0.text(1)) ?? .netease)
        })
        return LibraryStore.artists(from: candidates).map { (id: $0.id, name: $0.name) }
    }

    // MARK: - 查询

    /// 一个词在这一类对象里命中了哪些 id。
    ///
    /// `query` 必须来自 `LibrarySearch.ftsQuery(_:)`——**任何地方都不许手拼 MATCH 表达式**，
    /// 用户在搜索框里随手敲一个 `*` `-` `AND` 就是一条 `SQLITE_ERROR`。
    /// 空查询在那个函数里就返回 nil 了，走不到这儿（裸空串报 `fts5: syntax error near ""`）。
    static func matchedIDs(_ kind: Kind, query: String,
                           in db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query(matchSelect, [query, kind.rawValue], { $0.text(0) }))
    }

    private static let matchSelect = """
        SELECT owner_id FROM search_index WHERE search_index MATCH ? AND owner_kind = ?
        """
}

/// 「这一屏该留哪几行」的三种答法。七处搜索拿到的都是它。
///
/// **为什么是「给 id 集合、让调用方自己筛数组」而不是「让 store 把结果查出来」**：
/// 七处各自的排序、分组、去重、与其它筛选条件的先后次序全都不一样
///（歌曲页要先判重复项再搜、专辑页要先摘空碟、歌单页头上还挂着一张合成卡），
/// 这些逻辑一个字都不该为了换搜索而动。内存数组仍然是真值，索引只回答「命中了谁」。
enum LibraryTextFilter {

    /// 空查询：不加筛选，全部留下。
    case all

    /// FTS5 命中的 id。
    case ids(Set<String>)

    /// 退路：按字段做内存子串匹配，也就是这次改造之前那套。
    ///
    /// 三种情况会走到这儿——库开不了、查询抛错、`mirrorIsStale` 竖着。与阶段 7 同一个理由：
    /// **表只是加速器，内存数组仍是真值**，绝不能让一次故障表现成「搜什么都没有」。
    /// 还有一种不是故障的情况见 `inMemory(_:)`。
    case substring(String)

    /// 不经过索引的那一路：给**从未落库**的那批行用（目录里浏览的歌单、
    /// 镜像账号歌单刚从音源取回来的曲目——它们的 id 索引压根不认识）。
    static func inMemory(_ raw: String) -> LibraryTextFilter {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? .all : .substring(keyword)
    }

    /// 这一行留不留。
    ///
    /// `fields` 是 `@autoclosure`：走 id 集合那条路时它一次都不会求值，
    /// 省掉每行一个临时数组——而那条路是常路。
    func keeps(_ id: String, _ fields: @autoclosure () -> [String]) -> Bool {
        switch self {
        case .all:
            return true
        case .ids(let ids):
            return ids.contains(id)
        case .substring(let keyword):
            return fields().contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }
}
