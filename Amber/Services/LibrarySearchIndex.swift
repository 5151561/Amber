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

    /// `owner → 已入库正文的指纹`。键是 (kind, id)：`owner_id` 在四种对象之间
    /// **不保证唯一**（音源的曲目 id 与专辑 id 各自成体系，撞上了谁也拦不住），
    /// 所以这张表的「一行」由 (kind, id) 一起认，删除的 WHERE 也带上 `owner_kind`。
    private var fingerprints: [Key: Int] = [:]

    /// 指纹表的键。id 按 **UTF-8 字节**存，不按 `String` 存。
    ///
    /// `String` 的 `==` 与哈希按 Unicode 规范等价（分解式 `é` 与预组合 `é`、开尔文符号 `K` 与 `K`
    /// 是同一个键），而表里 `owner_id = ?` 是逐字节比的。艺人 id 就是「前缀 + 艺人名」，
    /// 两种拼写在表里是两行、在 `[String: Int]` 里却是一个键：先写进去的那行从此在内存里
    /// 「看不见」，对账既不会删它也不会重写它——退库之后留下一条搜得到、点进去却空的幽灵。
    /// [实测 2026-10-06，`LibraryArtistReconcileTests` 的随机序列第 41 步就撞上了]
    /// 键与表用同一套相等，这一类分叉才不存在。
    private struct Key: Hashable {
        let kind: Kind
        let id: [UInt8]
        init(_ kind: Kind, _ id: String) {
            self.kind = kind
            self.id = Array(id.utf8)
        }
        var idString: String { String(decoding: id, as: UTF8.self) }
    }

    // MARK: - 开库时读一次

    /// 把表里现有的正文指纹读进内存。
    ///
    /// 与 `LibraryStore.loadFromDatabase` 同一条纪律：**先读进局部变量，读完了才赋值**。
    /// 读到一半抛错时留下半份指纹，比没有指纹更糟——后续写入会以为某些行已经在表里而跳过。
    func load(from db: SQLiteDatabase) throws {
        var loaded: [Key: Int] = [:]
        for row in try db.query(
            "SELECT owner_kind, owner_id, name, artist, album FROM search_index", [],
            { (kind: $0.text(0), id: $0.text(1),
               fingerprint: Self.fingerprint($0.text(2), $0.text(3), $0.text(4))) }) {
            guard let kind = Kind(rawValue: row.kind) else { continue }
            loaded[Key(kind, row.id)] = row.fingerprint
        }
        // 换了一条连接（或第一次开库）：临时表与触发器是连接级的，跟着连接一起没了，
        // 这一份「艺人名全是 NFC」的结论也就不作数了——下一次对账先全量一遍再说。
        // 建在赋值之前：它抛错时与上面读到一半抛错同解，什么都不留。
        try Self.installArtistTouchLog(in: db)
        fingerprints = loaded
        artistNamesAllNFC = nil
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
    ///
    /// 逐字节互不相同；**别装进 `Set<String>`**，规范等价的两种拼写会在那里并成一个（见 `Key`）。
    func ids(of kind: Kind) -> [String] {
        fingerprints.keys.lazy.filter { $0.kind == kind }.map(\.idString)
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
        let key = Key(kind, id)
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
        fingerprints.removeValue(forKey: Key(kind, id))
        try Self.deleteRows(kind, id: id, in: db)
    }

    /// 普通 FTS5 表支持直接 DELETE（external content 表不支持，这也是 schema 选普通表的
    /// 理由之一）。`owner_kind` 一起进 WHERE，理由见 `fingerprints` 上那段。
    private static func deleteRows(_ kind: Kind, id: String, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
                   [kind.rawValue, id])
    }

    /// 艺人那一档**全量**对账：库里现在该有哪些艺人，表里就留哪些。
    ///
    /// 艺人是从专辑 / 曲目的艺人名**派生**的，没有「新建一位艺人」这种动作，
    /// 所以它没法像其余三类那样挂在某个写入漏斗上。多出来的撤掉、少的补上、
    /// 名字没变的一条语句都不发（`upsert` 自己会判）。
    ///
    /// 日常写入走的是 `reconcileTouchedArtists`（只核对这一次动到的艺人名）；
    /// 这一条留给它自己判定「增量答不准」的时候，以及当对照组（一致性测试拿它当真值）。
    func reconcileArtists(_ wanted: [(id: String, name: String)],
                          in db: SQLiteDatabase) throws {
        // 键按字节比（见 `Key`）：`Set<String>` 会把规范等价的两种拼写并成一个而漏删。
        let wantedKeys = Set(wanted.map { Key(.artist, $0.id) })
        let stale = fingerprints.keys.filter { $0.kind == .artist && !wantedKeys.contains($0) }
        for key in stale {
            try delete(.artist, id: key.idString, in: db)
        }
        for artist in wanted {
            try upsert(.artist, id: artist.id, name: artist.name, in: db)
        }
    }

    // MARK: - 艺人那一档：增量对账

    /// 全量对账为什么不够（[实测 2026-10-06，Release，`LibraryScaleBenchmarkTests`]）：
    /// 200 / 1 万 / 5 万首 = 0.09 / 4.7 / 25.2 ms，5 万首时其中 22 ms 是 `derivedArtists`
    ///（两表 UNION 扫全部行 + 给全部艺人名做 `localizedStandardCompare` 排序——对账根本不用排序），
    /// 是「5 万首删一首」34 ms 里最大的一块。而一次退库 / 入库 / 改曲目真正可能变的，
    /// 只有被它动到的那几个艺人名。
    ///
    /// ## 「动到了哪些名字」由触发器记，不由调用方报
    ///
    /// 连接级的 TEMP 触发器挂在三张来源表上，把**字节上真变了**的艺人名记进 `temp.artist_touched`：
    ///
    /// - `library_album`：增 / 删记那一行的 `artist_name`；改了 `artist_name` 新旧都记。
    /// - `library_track`：增 / 删记它那首歌在 `track` 里的 `artist_name`。
    /// - `track`：改了 `artist_name`、且这首歌**正在** `library_track` 里，新旧都记。
    ///
    /// 不让落库助手自己举手报名字，是因为第三条在助手那一层看不见：曲目行只有一个写入漏斗
    ///（`persistTracks`），起播、列表重写拿着音源新给的元数据走过它时，一首资料库曲目的艺人名
    /// 可能就这么被改了，而那条路跟「资料库」毫不相干。从前的全量对账也漏这一条（那几条路不举手），
    /// 要等下一次别的入库 / 退库顺手补上；触发器在 SQL 那一层，哪条路写的都逃不掉。
    /// 记录表与写入同在一个事务里，回滚时一起回滚，不会留下「名字记了、写却没成」的账。
    ///
    /// ## 什么时候退回全量
    ///
    /// 增量答「这个名字还有没有人挂着」用的是 SQL 的 `=`（逐字节），而全量版的去重
    /// 走 Swift 的 `==`（Unicode 规范等价：分解式 `é` 与预组合 `é`、开尔文符号 `K` 与 `K`
    /// 都算同一个人，留下的是**先出现的那个拼写**）。两者只在库里有「规范等价但字节不同」的
    /// 两种拼写时才会分叉；两个 NFC 串规范等价就必然逐字节相同，所以只要库里的艺人名
    /// **全是 NFC**，逐字节判就与全量版逐字一致。于是：
    ///
    /// - `artistNamesAllNFC` 不是 `true`（这一程还没全量过、上一次写失败、库里确有非 NFC 名字）→ 全量；
    /// - 这一批动到的名字里有非 NFC 的 → 全量（全量会把这一位重新算成 false）。
    ///
    /// 真实资料库里非 NFC 的艺人名极少（多见于从 macOS 文件名里直接取的名字），
    /// 一旦有，就退回从前那条全量路，不会更慢也不会答错。
    private var artistNamesAllNFC: Bool?

    private static let touchedTable = "artist_touched"

    /// 建那张记录表与六个触发器。`IF NOT EXISTS`：同一条连接上第二个 store 开库时不重复建。
    ///
    /// TEMP 对象不进库文件、不进 schema 版本，所以这里不需要迁移；连接关掉就没了，
    /// 下一次开库 `load` 会再建一遍。
    static func installArtistTouchLog(in db: SQLiteDatabase) throws {
        let t = touchedTable
        try db.execute("""
            CREATE TEMP TABLE IF NOT EXISTS \(t) (name TEXT PRIMARY KEY) WITHOUT ROWID;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_album_ins AFTER INSERT ON main.library_album
            BEGIN INSERT OR IGNORE INTO \(t) VALUES (NEW.artist_name); END;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_album_del AFTER DELETE ON main.library_album
            BEGIN INSERT OR IGNORE INTO \(t) VALUES (OLD.artist_name); END;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_album_upd
            AFTER UPDATE OF artist_name ON main.library_album
            WHEN OLD.artist_name IS NOT NEW.artist_name
            BEGIN INSERT OR IGNORE INTO \(t) VALUES (OLD.artist_name), (NEW.artist_name); END;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_ltrack_ins AFTER INSERT ON main.library_track
            BEGIN INSERT OR IGNORE INTO \(t)
                  SELECT artist_name FROM track WHERE id = NEW.track_id; END;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_ltrack_del AFTER DELETE ON main.library_track
            BEGIN INSERT OR IGNORE INTO \(t)
                  SELECT artist_name FROM track WHERE id = OLD.track_id; END;
            CREATE TEMP TRIGGER IF NOT EXISTS \(t)_track_upd
            AFTER UPDATE OF artist_name ON main.track
            WHEN OLD.artist_name IS NOT NEW.artist_name
             AND EXISTS (SELECT 1 FROM library_track WHERE track_id = NEW.id)
            BEGIN INSERT OR IGNORE INTO \(t) VALUES (OLD.artist_name), (NEW.artist_name); END;
            """)
    }

    /// 某个艺人名（逐字节）还有没有入库专辑或资料库曲目挂着。
    /// 两边各走一条现成索引：`library_album_artist`、`track_artist` + `library_track` 主键。
    private static let artistReferencedSelect = """
        SELECT EXISTS (SELECT 1 FROM library_album WHERE artist_name = ?)
            OR EXISTS (SELECT 1 FROM track t JOIN library_track lt ON lt.track_id = t.id
                        WHERE t.artist_name = ?)
        """

    /// 日常对账：只核对这一次（自上次对账以来）动到的艺人名。`LibraryStore.persist` 每个事务末尾调一次。
    ///
    /// 什么都没动到时只有一条「读空临时表」的查询，所以不必再由调用方判「这次写跟艺人有没有关系」——
    /// 起播、记账那些热路走到这里也只是白读一次空表。
    /// 结果与 `reconcileAllArtists` 逐字一致，前提与退路见 `artistNamesAllNFC`。
    func reconcileTouchedArtists(in db: SQLiteDatabase) throws {
        let touched = try db.query("SELECT name FROM \(Self.touchedTable)", [], { $0.text(0) })
        guard !touched.isEmpty else { return }
        try db.run("DELETE FROM \(Self.touchedTable)")
        guard artistNamesAllNFC == true, touched.allSatisfy(Self.isNFC) else {
            try reconcileAllArtists(in: db)
            return
        }
        for name in touched where !name.isEmpty {  // 空名全量版也跳过（`artists(from:)`）
            let id = Artist.libraryIDPrefix + name
            let referenced = try db.query(Self.artistReferencedSelect, [name, name],
                                          { $0.int(0) != 0 }).first ?? false
            if referenced {
                try upsert(.artist, id: id, name: name, in: db)
            } else if fingerprints[Key(.artist, id)] != nil {
                // 全量版删的也只是「指纹里有、却不再该有」的那些（`ids(of: .artist)` 取自指纹），
                // 同一道闸，才逐字一致；也免得给每个早就不在的名字白发一条全表扫的 DELETE。
                try delete(.artist, id: id, in: db)
            }
        }
    }

    /// 全量对账，顺手重新判一次「库里的艺人名是不是全是 NFC」（见 `artistNamesAllNFC`）。
    ///
    /// 那一判要看到**每一种拼写**，包括被去重吃掉的那些，所以从原始候选序列上判，
    /// 不从 `derivedArtists` 的结果上判。代价压在纯 ASCII 名字之外：ASCII 一定是 NFC、
    /// 跳过；非 ASCII 的按名字去重后才做一次 NFC 归一（5 万个汉字名逐个归一要 20 ms，
    /// 去重后只剩艺人数那么多次），同一类里出现第二种拼写本身就说明有非 NFC。
    func reconcileAllArtists(in db: SQLiteDatabase) throws {
        let candidates = try db.query(LibraryStore.artistCandidatesSelect, [], {
            (name: $0.text(0), kind: ProviderKind(rawValue: $0.text(1)) ?? .netease)
        })
        var allNFC = true
        var firstSpelling: [String: String] = [:]
        for candidate in candidates where !candidate.name.utf8.allSatisfy({ $0 < 0x80 }) {
            if let first = firstSpelling[candidate.name] {
                guard first.utf8.elementsEqual(candidate.name.utf8) else { allNFC = false; break }
            } else {
                guard Self.isNFC(candidate.name) else { allNFC = false; break }
                firstSpelling[candidate.name] = candidate.name
            }
        }
        try reconcileArtists(LibraryStore.artists(from: candidates).map { (id: $0.id, name: $0.name) },
                             in: db)
        artistNamesAllNFC = allNFC
    }

    /// 写库失败过：内存指纹与表可能对不上了，下一次对账老老实实全量。
    func invalidateArtistBaseline() {
        artistNamesAllNFC = nil
    }

    /// 逐字节就是 NFC。`==` 在这里用不得——它本身就是按规范等价比的，永远答 true。
    private static func isNFC(_ name: String) -> Bool {
        name.utf8.allSatisfy { $0 < 0x80 }
            || name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(name.utf8)
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
