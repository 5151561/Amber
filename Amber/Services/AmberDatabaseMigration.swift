import Foundation

// MARK: - 旧存档的模型

/// 旧 `library.json` 里的一首歌。
///
/// **为什么不复用 `Track`。** 迁移器解的是**磁盘上已经写死的那份 JSON**，不是现在的内存模型。
/// 这件事已经发生了：`Track.localPath` 现在**已经删掉**（本地性只由下载索引一处说了算），
/// 拿今天的 `Track` 去解旧存档，`localPath` 会被 `Decodable` 静默跳过
/// ——`local_file` 的种子规则里「`localPath` 非空且 index.json 里没有」那条补充就永远补不到
/// 任何一行，不报错、不告警，只是新库里少了几首歌的本机文件。
/// 那条种子规则（连同它的 `FileManager.fileExists` 闸）是挡住 8 条死路径的唯一一道门，
/// 而它要的那份路径，今天只有这个类型还存着。
///
/// 所以这一份是**旧存档的形状的快照**，字段只增不改，跟着磁盘走，不跟着内存模型走。
/// 反过来也成立：以后 `Track` 加了新字段，这里不加，迁移器就当旧存档里没有——本来也没有。
struct LegacyTrack: Codable {
    let id: String
    let kind: ProviderKind
    let title: String
    let artistName: String
    let artistId: String?
    let albumName: String
    let albumId: String?
    let artworkURL: String?
    let duration: TimeInterval
    /// 以下全是后加的可选字段：旧文件里没有这些键，合成的 `Decodable` 对**非可选**属性
    /// 缺键会直接抛错（`Track.losslessAvailable` 那条注释说的就是这个坑）。
    /// 可选性在这里不是「值可以没有」，是「键可以没有」。
    let trackNumber: Int?
    let discNumber: Int?
    let mediaMid: String?
    let losslessAvailable: Bool?
    /// 「文件 › 导入…」进来的本机文件绝对路径。
    ///
    /// **这一格就是这个类型存在的唯一理由**，见类型头上那段注释。
    let localPath: String?

    var isLocal: Bool { id.hasPrefix(Track.localIDPrefix) }

    /// 回到内存模型。
    ///
    /// 只给两个地方用：算 `album_key` 时要调 `LibraryStore.fallbackKey(for:)`（那个函数收
    /// `Track`），以及回灌台账时要调 `LibraryStore.backfilledContainers(from:)`。
    /// 两处都是**调仓库里已有的那一份实现**，不是在迁移器里另抄一遍规则——
    /// `album_key` 尤其不能抄：它现在是一个**落盘的列**，抄一份就等于给一个已持久化的键
    /// 造第二份真相，两边哪天漂移了专辑会静默认不出来。
    ///
    /// `Track` 上已经没有 `localPath` 那一格了，所以这里也没什么可传的：
    /// 种子规则要的路径直接从 `LegacyTrack.localPath` 取。
    var asTrack: Track {
        Track(id: id, kind: kind, title: title, artistName: artistName, artistId: artistId,
              albumName: albumName, albumId: albumId, artworkURL: artworkURL, duration: duration,
              trackNumber: trackNumber, discNumber: discNumber, mediaMid: mediaMid,
              losslessAvailable: losslessAvailable)
    }

    /// 从内存模型倒过来造一份。
    ///
    /// 只有一个来源用得上：`recentContainers` 里的 `.track(Track)`。那个 case 的载荷是
    /// 现役 `RecentContainer` 解出来的真 `Track`（台账整体照 §1 复用现有类型解码），
    /// 而它在曲目字段的优先级里排**最后**一位，本来就只当兜底。
    ///
    /// **`localPath` 一律给 nil**：`Track` 上已经没有这一格，台账里解出来的那份
    /// 也就不参与 `local_file` 的种子规则。代价是「只在台账里出现过、且有本机文件」
    /// 的歌拿不到 external 行，而那种歌同时也不在资料库、心水、最近播放、任何歌单里。
    init(_ track: Track) {
        id = track.id
        kind = track.kind
        title = track.title
        artistName = track.artistName
        artistId = track.artistId
        albumName = track.albumName
        albumId = track.albumId
        artworkURL = track.artworkURL
        duration = track.duration
        trackNumber = track.trackNumber
        discNumber = track.discNumber
        mediaMid = track.mediaMid
        losslessAvailable = track.losslessAvailable
        localPath = nil
    }
}

/// 旧 `library.json` 里的一份播放列表。
///
/// 与 `LibraryPlaylist` 逐字段同形，只把 `tracks` 换成 `[LegacyTrack]`——理由见
/// `LegacyTrack` 头上那段：歌单里那份也是完整副本，也带着 `localPath`。
/// `source: Playlist?` 原样复用现役类型：它整块存进 `playlist.source_json`，
/// Amber 自己一个字段都不改，也没有任何查询按它的内部字段筛。
struct LegacyLibraryPlaylist: Codable {
    let id: String
    let name: String
    let origin: LibraryPlaylist.Origin
    let source: Playlist?
    let tracks: [LegacyTrack]
    let coverURL: String?
    let description: String?
    let createdAt: Date
    let addedAt: Date
}

/// 旧 `library.json` 的整份形状：`LibraryStore.Storage` 的快照，19 个键。
///
/// **只有 `favorites` 与 `recents` 是非可选的**，其余 17 个全可选。这不是随手写的：
/// 那两个是最初就有的键，其余都是后加的，而合成的 `Decodable` 对非可选属性缺键会**抛错**
/// ——一抛错整份存档就整份解不出来，心水、评分、播放次数、几十份歌单一次全没。
/// 可选性在这里表达的是「这个键可能根本不在文件里」，不是「这个值可以为空」。
///
/// `recentContainers` 的可选性还多一层意思，见 `AmberDatabaseMigration` 里回灌那一段：
/// 要能分出「旧存档没有这个键」（按老规则回灌一份）与「新存档、台账确实是空的」（不回灌）。
struct LegacyLibraryArchive: Codable {
    var favorites: [LegacyTrack] = []
    var recents: [LegacyTrack] = []
    var favoriteAlbums: [String]?
    var favoriteArtists: [String]?
    var ratings: [String: Int]?
    var libraryTracks: [LegacyTrack]?
    var libraryAlbums: [Album]?
    var playCounts: [String: Int]?
    var skipCounts: [String: Int]?
    var addedAt: [String: Date]?
    var lastPlayedAt: [String: Date]?
    var lastSkippedAt: [String: Date]?
    var albumAddedAt: [String: Date]?
    var playlists: [LegacyLibraryPlaylist]?
    var dismissedAccountPlaylists: [String]?
    var uncheckedTracks: [String]?
    var suggestLessTracks: [String]?
    var suggestLessArtists: [String]?
    var recentContainers: [RecentContainer]?
}

/// 旧 `trackinfo.json` 的形状（`TrackInfoStore` 从前那个 `Storage` 壳子的快照）。
///
/// `TrackInfo` 与 `LoudnessEntry` 都**原样复用现役类型**：它们不像 `Track` 那样有字段要退场，
/// 而且 `TrackInfo` 自己手写了 `init(from:)` 逐条 `decodeIfPresent`，本来就是照「旧文件缺键」
/// 设计的，再抄一份只会多一处会发霉的副本。并进主库之后那份 `Codable` 只剩这里在用
/// （见 `TrackInfo.init(from:)` 的注释）。
private struct LegacyTrackInfoArchive: Codable {
    var infos: [String: TrackInfo] = [:]
    var resumePositions: [String: TimeInterval]?
}

/// 媒体文件夹 `index.json` 里的一条。
///
/// 形状照 `DownloadStore.Entry`（它是 `private`，够不着，所以这里复制一份形状）。
/// 除了头三格，其余**全是后加的可选格**：老清单里根本没有这些键，
/// 而合成的 `Decodable` 对非可选属性缺键会直接抛错（同 `LegacyTrack` 那段）。
private struct LegacyDownloadEntry: Codable {
    var path: String
    var bytes: Int
    var date: Date
    var mtime: Date?
    var quality: String?
    var codec: String?
    var sampleRate: Double?
    var bitDepth: Int?
    var tier: String?
    var tagged: Bool?
    var tagVersion: Int?
}

/// 阶段 5 起清单的外层形状（`DownloadStore.Manifest` 的形状快照）。
///
/// `manifestVersion` 这个键在这里只作**判形状**用——两种形状的区分靠它。
/// 那一版起清单里**不再有 external 条目**，它们只住在 `local_file` 里；
/// 也就是说「把库删了重迁」这条路恢复得回媒体夹里的那些，恢复不回原地引用的那些
///（那是「external 是权威、没有第二处能重建它」的另一面）。
private struct LegacyDownloadManifest: Codable {
    var manifestVersion: Int
    var entries: [String: LegacyDownloadEntry]
}

// MARK: - 迁移器

/// 一次性的「旧 JSON 存档 → SQLite 主库」。
///
/// **安全性全部来自 sidecar + rename 这一条**：先往 `library.sqlite.new` 里建库、灌数据、
/// 自校验，全过了才 `rename` 成 `library.sqlite`。中途任何一步崩了 / 抛了，磁盘上只剩一个
/// 孤儿 `.new`（下次启动照样重来）和**一个字没动的旧 JSON**。没有「写了一半的库」这种状态。
///
/// **改名只跟着 store 走**（见 `runIfNeeded` 的 `renameLegacyOnSuccess`）：一份存档改名
/// ＝ 宣布「它已经没人读了」。阶段 1、2 那两轮一份都不改（JSON 仍是唯一真值源，
/// 建出来的库没有任何人读，核不对就把 `library.sqlite` 删了当无事发生）；阶段 3 起
/// `library.json`、阶段 4 起 `trackinfo.json` / `loudness.json` 各自跟着自己的 store 退场。
///
/// ## 失败策略：「读不出来」永远不能变成「写空的」
///
/// 这是迁移顺手要修的那个洞。今天 `LibraryStore.load()` 是 `try?` + `guard else { return }`：
/// 一个 enum case 解不出来 → 静默空库 → 用户随手点个心水触发 `save()` → 空快照 `.atomic`
/// **覆盖原文件** → 心水、评分、播放次数、几十份歌单一次全没。迁移是堵这个洞的唯一时机。
///
/// | 情形 | 处置 |
/// |---|---|
/// | `library.json` 不存在（或 0 字节）| 正常：建一个空库，不报错 |
/// | `library.json` 在、非空、**解不动** | **中止**：不建库、不动 JSON，抛 `Failure.archiveUnreadable` |
/// | 另外三份解不动 | 各贡献 0 条（与现状一致，这三份丢了不致命），迁移继续，`Report.warnings` 记一笔 |
/// | 写库出错（`SQLITE_FULL` / `SQLITE_IOERR`）| 删 sidecar、JSON 不动，抛 `Failure.write` |
/// | 自校验不过 | 同上，抛 `Failure.validationFailed` |
///
/// `archiveUnreadable` 单列一个 case 就是为了让调用方分得出来：接线那一步要据此弹**阻塞式**
/// 警告并把 JSON 改名留底，而不是像今天一样一声不响地以空库启动。
@MainActor
enum AmberDatabaseMigration {

    // MARK: - 出错

    enum Failure: Error, CustomStringConvertible {
        /// `library.json` 在、非空、但解不动。**调用方必须单独认这一条**：
        /// 它意味着用户的整份资料库在磁盘上，只是这个版本的代码读不懂——
        /// 正确处置是停下来问人，不是接着往下走。
        case archiveUnreadable(url: URL, underlying: any Error)
        /// 写 sidecar 时 SQLite 报错。`SQLITE_FULL` / `SQLITE_IOERR` 都落这里。
        case write(SQLiteError)
        /// 灌完之后自校验没过。每条 reason 是一句人话，说明哪个数对不上。
        case validationFailed(reasons: [String])
        /// 校验都过了，sidecar 改名成正式库这一步失败（权限、目录被占）。
        case promoteFailed(underlying: any Error)
        /// 关连接之后 sidecar 的 `-wal` 不是 0 字节，说明 checkpoint 没跑成，
        /// 还有几笔只在 wal 里。见 `discardSidecarWAL`。
        case walNotCheckpointed(url: URL, bytes: Int)

        var description: String {
            switch self {
            case .archiveUnreadable(let url, let underlying):
                return "旧存档解不动，已中止迁移（JSON 一个字没动）：\(url.path) —— \(underlying)"
            case .write(let error):
                return "写库出错，已删掉 sidecar：\(error)"
            case .validationFailed(let reasons):
                return "迁移自校验没过，已删掉 sidecar：\n" + reasons.map { "  · \($0)" }
                    .joined(separator: "\n")
            case .promoteFailed(let underlying):
                return "sidecar 改名成正式库失败：\(underlying)"
            case .walNotCheckpointed(let url, let bytes):
                return "checkpoint 之后 \(url.lastPathComponent)-wal 还有 \(bytes) 字节，已中止"
            }
        }
    }

    /// 非致命的缺口。三份附属 JSON 丢了不影响资料库本身，但得让调用方知道。
    enum Warning: Hashable, CustomStringConvertible {
        case trackInfoUnreadable(URL)
        case loudnessUnreadable(URL)
        case downloadIndexUnreadable(URL)

        var description: String {
            switch self {
            case .trackInfoUnreadable(let url): return "trackinfo.json 解不动，简介与断点贡献 0 条：\(url.path)"
            case .loudnessUnreadable(let url): return "loudness.json 解不动，响度贡献 0 条：\(url.path)"
            case .downloadIndexUnreadable(let url): return "index.json 解不动，本机文件贡献 0 条：\(url.path)"
            }
        }
    }

    // MARK: - 结果

    /// 跑完之后的报告。手工演习时直接打印它核对计数。
    struct Report: CustomStringConvertible {
        /// false ＝ 库本来就在，这次什么都没做（幂等那一路）。
        let didRun: Bool
        let databaseURL: URL
        /// 表名 → 行数。**校验通过之后从库里现数的**，不是写的时候攒的计数器——
        /// 攒出来的数只能证明「我以为我写了多少」。
        let counts: [String: Int]
        let warnings: [Warning]

        var description: String {
            guard didRun else { return "迁移：库已存在，未执行（\(databaseURL.path)）" }
            let lines = counts.sorted { $0.key < $1.key }.map { "  \($0.key) = \($0.value)" }
            return (["迁移完成：\(databaseURL.path)"] + lines
                + warnings.map { "  ⚠︎ \($0)" }).joined(separator: "\n")
        }
    }

    // MARK: - 入口

    /// 库不在就迁一次，在就什么都不做。
    ///
    /// - Parameters:
    ///   - directory: Application Support 里那个目录（`library.json` / `trackinfo.json` /
    ///     `loudness.json` 的家）。nil ＝ `~/Library/Application Support/Amber/`，
    ///     解析规则与四个 store 的 `init(directory:)` 逐字相同。
    ///   - mediaFolder: 媒体文件夹（`index.json` 的家，与上面那个目录**不是**同一个）。
    ///     nil ＝ 设置 › 文件 ›「媒体」文件夹。
    ///   - renameLegacyOnSuccess: 成功之后把**已经没人读的**那些旧存档改名
    ///     `*.json.migrated-<yyyyMMdd>`。默认关着（阶段 1、2 那两轮 JSON 仍是唯一真值源）。
    ///     打开之后改哪几份**跟着 store 一份一份来**：阶段 3 是 `library.json`，
    ///     阶段 4 `trackinfo.json` / `loudness.json` 跟上（理由见下面那段实测）。
    ///     媒体夹的 `index.json` 任何时候都不改名——它是媒体文件夹的自解释**清单**，
    ///     不是 Amber 的存档。
    @discardableResult
    static func runIfNeeded(directory: URL? = nil,
                            mediaFolder: URL? = nil,
                            renameLegacyOnSuccess: Bool = false) throws -> Report {
        let support = resolvedDirectory(directory)
        let databaseURL = support.appendingPathComponent(databaseName)

        // 幂等就这一条：库在，一切免谈。**故意不去读它的 user_version**——
        // 那是 `AmberDatabase` 开库路径的事，迁移器只回答「要不要从 JSON 造一份出来」。
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Report(didRun: false, databaseURL: databaseURL, counts: [:], warnings: [])
        }

        let media = mediaFolder ?? AppSettings.shared.values.mediaFolder
        let archiveURL = support.appendingPathComponent(libraryArchiveName)
        let infoURL = support.appendingPathComponent(trackInfoArchiveName)
        let loudnessURL = support.appendingPathComponent(loudnessArchiveName)
        let indexURL = media.appendingPathComponent(downloadIndexName)

        // 四份 JSON 各自独立读。**主存档先读**：它解不动就得在建任何文件之前掉头，
        // 一个空的 sidecar 都不要留下。
        let archive = try loadArchive(at: archiveURL)
        var warnings: [Warning] = []
        let infoArchive = loadTrackInfoArchive(at: infoURL, warnings: &warnings)
        let loudness = loadLoudness(at: loudnessURL, warnings: &warnings)
        let downloadIndex = loadDownloadIndex(at: indexURL, warnings: &warnings)

        let plan = Plan(archive: archive,
                        infos: infoArchive.infos,
                        resumePositions: infoArchive.resumePositions ?? [:],
                        loudness: loudness,
                        downloadIndex: downloadIndex)

        // sidecar：孤儿（上一次崩在半路）先清掉。不清的话 `AmberDatabase` 会读到
        // 那份库里已经是 1 的 user_version，建表那段一条都不跑，然后往一份**半份数据**上
        // 继续灌——校验多半会拦住，但那是靠运气，不是靠设计。
        let sidecarURL = support.appendingPathComponent(databaseName + sidecarSuffix)
        removeDatabaseFiles(at: sidecarURL)

        let counts: [String: Int]
        do {
            counts = try write(plan, to: sidecarURL)
        } catch {
            removeDatabaseFiles(at: sidecarURL)
            throw error
        }

        do {
            try FileManager.default.moveItem(at: sidecarURL, to: databaseURL)
        } catch {
            removeDatabaseFiles(at: sidecarURL)
            throw Failure.promoteFailed(underlying: error)
        }

        if renameLegacyOnSuccess {
            // **Application Support 里这三份存档，现在一份都没人读了。**
            //
            // 改名的含义就是这个，所以它只能跟着**对应的 store 真的改读 SQL** 那一刻走，
            // 一份都不能提前：阶段 3 只搬了 `LibraryStore`，那一轮就只改名 `library.json`；
            // 阶段 4 `TrackInfoStore` 与 `LoudnessStore` 也并进了主库（见两者 `init`——
            // 开的是 `AmberDatabase`，没有 `fileURL` 了），这两份才跟上来。
            //
            // [实测 2026-09-17] 提前改名什么后果，阶段 3 那天试过一次：三份一起改名跑实机，
            // `loudness.json` 从 15 条变成 6 条——`LoudnessStore` 那时还在读
            // `loudness.json`，被改名之后它当成空的从头开始，又把空的写了回去。
            // 正是这次改造要堵的那条「读不出来变成写空的」，只不过换了个地方发生。
            //
            // 媒体夹的 `index.json` 永远不进这个数组：它是媒体文件夹的自解释**清单**，
            // 不是 Amber 的存档，搬完之后照样有人读、有人写。
            for url in [archiveURL, infoURL, loudnessURL] { renameLegacy(url) }
        }

        return Report(didRun: true, databaseURL: databaseURL, counts: counts, warnings: warnings)
    }

    // MARK: - 文件名

    private static let databaseName = "library.sqlite"
    /// sidecar 后缀。全套安全性的落点，见类型头上那段。
    private static let sidecarSuffix = ".new"
    private static let libraryArchiveName = "library.json"
    private static let trackInfoArchiveName = "trackinfo.json"
    private static let loudnessArchiveName = "loudness.json"
    private static let downloadIndexName = "index.json"

    /// 目录不存在就建出来——`sqlite3_open_v2` 的 `CREATE` 只建文件不建父目录。
    /// 与 `AmberDatabase.resolvedDirectory` 同解。
    private static func resolvedDirectory(_ directory: URL?) -> URL {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Amber", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// 连 `-wal` / `-shm` 一起删。只删 `.sqlite` 会在磁盘上留下两个旁文件，
    /// 下次建同名库时 SQLite 会把那份陈旧的 wal 重放进新库。
    private static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// `library.json` → `library.json.migrated-20260917`。失败不抛：
    /// 到这一步库已经就位并且是权威了，改名只是留底。
    private static func renameLegacy(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let stamped = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).migrated-\(formatter.string(from: Date()))")
        try? FileManager.default.moveItem(at: url, to: stamped)
    }

    // MARK: - 读 JSON

    /// 主存档。**不存在**与**解不动**是两件完全不同的事，见类型头上那张表。
    private static func loadArchive(at url: URL) throws -> LegacyLibraryArchive {
        // 读不出字节 ＝ 文件不在（全新用户）。0 字节同理：那不是「坏掉的存档」，
        // 那是一次没写完的 `.atomic` 留下的空壳，按「没有存档」算才不会把新用户拦在门外。
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return LegacyLibraryArchive()
        }
        do {
            return try JSONDecoder().decode(LegacyLibraryArchive.self, from: data)
        } catch {
            throw Failure.archiveUnreadable(url: url, underlying: error)
        }
    }

    /// 简介与断点。解不动就当空的，记一条 warning。
    private static func loadTrackInfoArchive(at url: URL,
                                            warnings: inout [Warning]) -> LegacyTrackInfoArchive {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return LegacyTrackInfoArchive()
        }
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(LegacyTrackInfoArchive.self, from: data) {
            return archive
        }
        // 裸字典格式的老存档（`TrackInfoStore.load` 也认这一版）。读得进来就认。
        if let bare = try? decoder.decode([String: TrackInfo].self, from: data) {
            return LegacyTrackInfoArchive(infos: bare, resumePositions: nil)
        }
        warnings.append(.trackInfoUnreadable(url))
        return LegacyTrackInfoArchive()
    }

    private static func loadLoudness(at url: URL,
                                     warnings: inout [Warning]) -> [String: LoudnessEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: LoudnessEntry].self, from: data)
        else {
            warnings.append(.loudnessUnreadable(url))
            return [:]
        }
        return decoded
    }

    /// 读媒体夹的清单。**两种形状都认**，与 `DownloadStore.decodeIndex` 一致：
    /// 阶段 5 起是 `{manifestVersion, entries}`，在那之前整份就是 `{id: Entry}`。
    ///
    /// 这里必须跟上新形状，否则「把 `library.sqlite` 删掉重迁一次」——一条现成的
    /// 恢复路径，阶段 2 的实弹演习走的就是它——会在新形状的清单上解不动，
    /// 本机文件一条都迁不过来，而且只是一句 warning。
    private static func loadDownloadIndex(
        at url: URL, warnings: inout [Warning]
    ) -> [String: LegacyDownloadEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(LegacyDownloadManifest.self, from: data) {
            return manifest.entries
        }
        guard let decoded = try? decoder.decode([String: LegacyDownloadEntry].self, from: data)
        else {
            warnings.append(.downloadIndexUnreadable(url))
            return [:]
        }
        return decoded
    }

    // MARK: - 把四份存档摊成待写的行

    /// 解析好的、可以直接往表里灌的一份计划。
    ///
    /// 先全算好再开事务，不是边算边写：算的这一段要 `stat` 文件（`local_file` 的种子规则）、
    /// 要做几千次字典查找，混在事务里只会把写锁按住更久；而且算错了要中止的话，
    /// 在开事务之前掉头比回滚干净。
    ///
    /// `@MainActor` 是必须显式写的：嵌套类型**不继承**外层的全局 actor 隔离，
    /// 而这里的 `init` 要调 `LibraryStore` 上那两个 `@MainActor` 的静态函数。
    @MainActor
    private struct Plan {
        /// 去重后的曲目池，**按首次出现的先后**排。
        let tracks: [LegacyTrack]
        let archive: LegacyLibraryArchive
        /// 解析过的台账（去重 / 必要时回灌），就是要写进 `recent_container` 的那一份。
        let containers: [RecentContainer]
        let infos: [String: TrackInfo]
        let resumePositions: [String: TimeInterval]
        let loudness: [String: LoudnessEntry]
        let localFiles: [LocalFileRow]

        init(archive: LegacyLibraryArchive,
             infos: [String: TrackInfo],
             resumePositions: [String: TimeInterval],
             loudness: [String: LoudnessEntry],
             downloadIndex: [String: LegacyDownloadEntry]) {
            self.archive = archive
            self.infos = infos
            self.resumePositions = resumePositions
            self.loudness = loudness

            // 台账：**与 `LibraryStore.load()` 逐字同解**，调的也是同两个函数。
            //
            // - 键不在 → 按老规则回灌一份（旧存档只有逐曲历史，货架不至于空着）；
            //   键在但是空数组 → 不回灌（用户刚清空 / 一直没听）。
            //   `recentContainers` 做成可选就是为了分出这两种情况。
            // - 再 `deduplicated` 收一遍：存档里**确实会**留着同一格的两种身份
            //   （同一份歌单从资料库页与从目录页起播，去重键统一之前各记了一条）。
            //   这一步在 SQL 里不是锦上添花——`recent_container.dedupe_key` 上有
            //   `UNIQUE`，不收就是一条插不进去的语句，整份迁移当场中止。
            containers = LibraryStore.deduplicated(
                archive.recentContainers
                    ?? LibraryStore.backfilledContainers(from: archive.recents.map(\.asTrack)))

            // 曲目去重。同一首歌今天以**完整副本**存在五处，实测 247 份副本 → 199 首唯一曲目。
            //
            // **字段以哪一份为准**：libraryTracks > favorites > recents > 歌单 > 台账。
            // 它们理论上由 `updateTrack` 同步、实测也一致，但「理论上一致」不是规则——
            // 没有确定的顺序，同一份存档在不同机器上能迁出不同的库。
            // 顺序按「哪一份最可能是最新的」排：资料库那份是 `updateTrack` 的第一写入点，
            // 台账那份是最后一处、也是唯一一处将来会整个消失的（`.track` 只存 id）。
            var pool: [LegacyTrack] = []
            var seen: Set<String> = []
            func absorb(_ candidates: [LegacyTrack]) {
                for track in candidates where seen.insert(track.id).inserted {
                    pool.append(track)
                }
            }
            absorb(archive.libraryTracks ?? [])
            absorb(archive.favorites)
            absorb(archive.recents)
            for playlist in archive.playlists ?? [] { absorb(playlist.tracks) }
            absorb(containers.compactMap {
                if case .track(let track) = $0 { return LegacyTrack(track) }
                return nil
            })
            tracks = pool

            localFiles = Self.localFileRows(downloadIndex: downloadIndex,
                                            tracks: pool,
                                            addedAt: archive.addedAt ?? [:])
        }

        /// `local_file` 的种子规则。**这条最容易写错，三个判据缺一不可。**
        ///
        /// 1. 媒体文件夹的 `index.json` 每一条各出一行。`path` 以 `/` 开头的是
        ///    「文件 › 导入…」没勾拷贝时的**原地引用**（判据就是 `DownloadStore.isExternal`
        ///    本人），存绝对路径、搬媒体夹不搬它 → `scope='external'`；
        ///    其余是媒体夹内的相对路径 → `scope='media'`。
        ///    `mv:<id>` 那些键原样进来，它们在 `track` 表里没有对应行，
        ///    所以 `local_file` 故意没对 `track(id)` 建外键。
        ///
        /// 2. **外加**：`localPath` 非空、且该 id 在 `index.json` 里**没有**条目的，补一行
        ///    external。这一条捞的是「导入过、但下载索引里没登记」的那批。
        ///
        /// 3. **而且 `FileManager.fileExists` 必须为真。** 这道闸是死命令：实测用户本机
        ///    8 条带 `localPath` 的曲目**全部**指向改名前的 `~/Music/AM/媒体`、
        ///    **8 条文件全不存在**（同期 `index.json` 里 14 条是活的）。不加闸就等于
        ///    把一份已经腐败的真值原样灌进新库，而新库是要当权威用的。
        ///    `index.json` 那批**不过**这道闸：`DownloadStore.loadIndex` 启动时本来就
        ///    逐条校验文件还在不在，那份清单是活的；这里跟着它走，不替它做主。
        private static func localFileRows(downloadIndex: [String: LegacyDownloadEntry],
                                          tracks: [LegacyTrack],
                                          addedAt: [String: Date]) -> [LocalFileRow] {
            var rows: [LocalFileRow] = []
            // 字典没有顺序，排一下键：迁移两次得到的库应该逐字节一样，好做对比。
            for key in downloadIndex.keys.sorted() {
                guard let entry = downloadIndex[key] else { continue }
                rows.append(LocalFileRow(
                    key: key,
                    scope: DownloadStore.isExternal(entry.path) ? .external : .media,
                    relativePath: entry.path,
                    bytes: entry.bytes,
                    // 老清单没有这几格（阶段 5 才加），那时一律是 nil；
                    // 新清单里有就原样搬——它是媒体夹的自解释清单，不是只记一个路径。
                    mtime: entry.mtime,
                    addedAt: entry.date,
                    quality: entry.quality,
                    codec: entry.codec,
                    sampleRate: entry.sampleRate,
                    bitDepth: entry.bitDepth,
                    tier: entry.tier,
                    tagged: entry.tagged,
                    tagVersion: entry.tagVersion))
            }

            for track in tracks {
                guard let path = track.localPath, !path.isEmpty,
                      downloadIndex[track.id] == nil,
                      FileManager.default.fileExists(atPath: path) else { continue }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = attributes?[.modificationDate] as? Date
                rows.append(LocalFileRow(
                    key: track.id,
                    scope: .external,
                    relativePath: path,
                    bytes: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    mtime: mtime,
                    // 入库时间优先用资料库记的那个；没有就退到文件自己的 mtime，
                    // 再没有才是此刻。这一列 NOT NULL，总得有个数。
                    addedAt: addedAt[track.id] ?? mtime ?? Date(),
                    quality: nil, codec: nil, sampleRate: nil, bitDepth: nil, tier: nil,
                    tagged: nil, tagVersion: nil))
            }
            return rows
        }
    }

    /// 待写的一行 `local_file`。
    private struct LocalFileRow {
        enum Scope: String {
            /// 媒体夹内：可随时按清单重建的**投影**。
            case media
            /// 原地引用：这一行是**权威**，没有别处能重建它。
            case external
        }

        let key: String
        let scope: Scope
        let relativePath: String
        let bytes: Int
        let mtime: Date?
        let addedAt: Date
        let quality: String?
        /// 结构化音质四格，来自 `DownloadStore.readFormat(of:)`（清单里带着）。
        let codec: String?
        let sampleRate: Double?
        let bitDepth: Int?
        let tier: String?
        let tagged: Bool?
        let tagVersion: Int?
    }

    // MARK: - 写

    /// 建 sidecar、灌完、校验，再把旁文件收干净。返回从库里现数出来的行数。
    private static func write(_ plan: Plan, to sidecarURL: URL) throws -> [String: Int] {
        let counts = try fill(plan, at: sidecarURL)
        try discardSidecarWAL(at: sidecarURL)
        return counts
    }

    /// 关连接之后把 sidecar 的 `-wal` / `-shm` 清掉。
    ///
    /// **macOS 的系统 SQLite 是 persistent WAL。** 实测（本机，连接对象已经 dealloc、
    /// `sqlite3_close` 确实走完之后）`-wal` 与 `-shm` 两个文件**照旧留在磁盘上**，
    /// 与 SQLite 上游文档里「最后一条连接关闭时删掉它们」那句不一样。
    /// 不管的话，改完名磁盘上会永远躺着一对 `library.sqlite.new-wal` / `-shm` 孤儿
    /// ——而正式库旁边是一份全新的 wal，那两个文件从此再没有任何东西认领。
    ///
    /// **删之前先验 wal 是 0 字节**：`checkpoint(TRUNCATE)` 跑成功了它就该是 0。
    /// 不是 0 就说明 checkpoint 没跑成、还有几笔只在 wal 里，这时候删等于丢数据，
    /// 所以宁可整个中止（sidecar 一起删、JSON 不动）。
    private static func discardSidecarWAL(at url: URL) throws {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        if let size = (try? FileManager.default
            .attributesOfItem(atPath: walURL.path))?[.size] as? NSNumber, size.intValue != 0 {
            throw Failure.walNotCheckpointed(url: url, bytes: size.intValue)
        }
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    /// 灌数据那一段。连接的生死**整个圈在这个函数里**：它一返回，`sqlite3_close`
    /// 就已经走完了，外面才敢动 sidecar 的文件。
    private static func fill(_ plan: Plan, at sidecarURL: URL) throws -> [String: Int] {
        // `AmberDatabase(fileURL:)` 顺手把全套 schema 建好（`user_version` 0 → 1）。
        var database: AmberDatabase? = try AmberDatabase(fileURL: sidecarURL)
        defer {
            database?.checkpoint()
            database = nil
        }
        guard let sqlite = database?.sqlite else { return [:] }

        do {
            try sqlite.transaction {
                try insertTracks(plan, into: sqlite)
                try insertRelations(plan, into: sqlite)
                try insertAlbums(plan, into: sqlite)
                try insertPlaylists(plan, into: sqlite)
                try insertRecentContainers(plan, into: sqlite)
                try insertLedgers(plan, into: sqlite)
                try insertTrackInfo(plan, into: sqlite)
                try insertLoudness(plan, into: sqlite)
                try insertLocalFiles(plan, into: sqlite)
                // 搜索索引这一轮**就填**，不留到接线那一步：填的成本只有一次全量插入，
                // 而不填的代价是「库里有数据、搜索表是空的」这种半成品状态。
                //
                // 填法是**照搬运行期那一个**（`LibrarySearchIndex.rebuild`），不另写一份：
                // 它要的四样东西（`track` / `library_album` / `playlist` / 派生艺人）
                // 上面几行刚好全灌完，而且它本来就要在升级链的 v4 上跑。
                // 另写一份的代价不是啰嗦——是「迁过来那份索引」与「重建出来那份索引」
                // 可以悄悄不一样，而这种不一样在界面上的表现只是「有几首歌搜不到」。
                try LibrarySearchIndex.rebuild(in: sqlite)
            }
        } catch let error as SQLiteError {
            throw Failure.write(error)
        }

        let reasons = try validate(plan, in: sqlite)
        guard reasons.isEmpty else { throw Failure.validationFailed(reasons: reasons) }
        return try count(in: sqlite)
    }

    private static func insertTracks(_ plan: Plan, into db: SQLiteDatabase) throws {
        let sql = """
            INSERT INTO track (id, kind, title, artist_name, artist_id, album_name, album_id,
                               artwork_url, duration, track_number, disc_number, media_mid,
                               lossless_available, album_key)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        for track in plan.tracks {
            try db.run(sql, [
                track.id, track.kind.rawValue, track.title, track.artistName, track.artistId,
                track.albumName, track.albumId, track.artworkURL, track.duration,
                track.trackNumber, track.discNumber, track.mediaMid, track.losslessAvailable,
                // 物化的 album_key：**调仓库里那一份 `fallbackKey`**，不在这儿重拼。
                // 它现在是一个落盘的列，抄一份就是第二份真相。
                LibraryStore.fallbackKey(for: track.asTrack),
                // **`LegacyTrack.localPath` 不往这张表里搬。** `track` 表从 v3 起
                // 没有 `local_path` 这一列了（本地性只由`local_file` 回答），
                // 那一格在迁移器里只剩一个用处：喂 `local_file` 的种子规则
                // （`localFileRows`，带`fileExists` 闸）。这也正是 `LegacyTrack`
                // 必须留着那一格、而**不能改用 `Track` 解旧存档**的全部理由。
            ])
        }
    }

    /// 三张「原来是数组」的关系表。`position` 就是数组下标原样物化。
    ///
    /// 用裸 `INSERT` 不用 `INSERT OR IGNORE`：三张表的主键都是 `track_id`，撞键意味着
    /// 同一份数组里有两条同 id 的记录——那是存档本身坏了。`OR IGNORE` 会把它咽下去，
    /// 于是库里少一行、position 序列缺一格，而且谁都不知道。让它当场抛，
    /// sidecar 删掉、JSON 不动，比默默迁出一份少数据的库好。
    private static func insertRelations(_ plan: Plan, into db: SQLiteDatabase) throws {
        let sources: [(String, [LegacyTrack])] = [
            ("library_track", plan.archive.libraryTracks ?? []),
            ("favorite_track", plan.archive.favorites),
            ("recent_track", plan.archive.recents),
        ]
        for (table, tracks) in sources {
            let sql = "INSERT INTO \(table) (track_id, position) VALUES (?,?)"
            for (position, track) in tracks.enumerated() {
                try db.run(sql, [track.id, position])
            }
        }
    }

    private static func insertAlbums(_ plan: Plan, into db: SQLiteDatabase) throws {
        let sql = """
            INSERT INTO library_album (id, kind, name, artist_name, artist_id, artwork_url,
                                       publish_date, track_count, description, genre, album_type,
                                       position, added_at, album_key)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        let albums = plan.archive.libraryAlbums ?? []
        let libraryTracks = plan.archive.libraryTracks ?? []
        let addedAt = plan.archive.addedAt ?? [:]
        let albumAddedAt = plan.archive.albumAddedAt ?? [:]

        for (position, album) in albums.enumerated() {
            // `added_at` 的缺键回落**在这里算一次、写死**：
            // 「这张碟里曲目 addedAt 的最大值」。今天它是 `albumAddedDate(for:)` 里
            // 每问一次就全表扫一遍的 O(n) 兜底；算好落列之后运行时那一段可以整个删掉。
            let stamped = albumAddedAt[album.id]
                ?? libraryTracks.filter { belongs($0, to: album) }
                    .compactMap { addedAt[$0.id] }.max()
            try db.run(sql, [
                album.id, album.kind.rawValue, album.name, album.artistName, album.artistId,
                album.artworkURL, album.publishDate, album.trackCount, album.description,
                album.genre, album.albumType, position, stamped,
                LibraryStore.fallbackKey(name: album.name, artist: album.artistName,
                                         kind: album.kind, isLocal: album.isLocal),
            ])
        }
    }

    /// 一首歌是不是这张碟里的。
    ///
    /// 与 `LibraryStore.belongs(_:to:)` 同解，但那一个是 `private` 且收 `Track`，
    /// 这里收 `LegacyTrack`。**重复的只有这三行分支结构，键本身照旧调
    /// `LibraryStore.fallbackKey`**——会漂移的那部分（归一化口径、键里带哪几段）
    /// 仍然只有一份。
    private static func belongs(_ track: LegacyTrack, to album: Album) -> Bool {
        if let albumId = track.albumId { return albumId == album.id }
        guard !album.name.isEmpty, !track.albumName.isEmpty else { return false }
        return LibraryStore.fallbackKey(for: track.asTrack)
            == LibraryStore.fallbackKey(name: album.name, artist: album.artistName,
                                        kind: album.kind, isLocal: album.isLocal)
    }

    private static func insertPlaylists(_ plan: Plan, into db: SQLiteDatabase) throws {
        let playlistSQL = """
            INSERT INTO playlist (id, name, origin, source_json, cover_url, description,
                                  created_at, added_at, position)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
        let trackSQL = "INSERT INTO playlist_track (playlist_id, track_id, position) VALUES (?,?,?)"
        let encoder = JSONEncoder()

        for (position, playlist) in (plan.archive.playlists ?? []).enumerated() {
            // `source` 整块存 JSON：它是音源歌单的原样快照，Amber 一个字段都不改，
            // 也没有任何查询按它的内部字段筛。展开成列只会多十几列没人读的空值。
            let sourceJSON = playlist.source
                .flatMap { try? encoder.encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try db.run(playlistSQL, [
                playlist.id, playlist.name, playlist.origin.rawValue, sourceJSON,
                playlist.coverURL, playlist.description, playlist.createdAt, playlist.addedAt,
                position,
            ])
            // 主键是 (playlist_id, position)，**不是** (playlist_id, track_id)：
            // 同一首歌允许在一份列表里出现多次（Music 就是这样，`addTracks` 明写不去重）。
            for (trackPosition, track) in playlist.tracks.enumerated() {
                try db.run(trackSQL, [playlist.id, track.id, trackPosition])
            }
        }
    }

    /// 最近播放台账。
    ///
    /// 六个 case 各落成什么样由 `RecentContainer.storageRow` 说了算，**这里不自己摊**：
    /// 同一份映射运行期还要反过来走一遍（`LibraryStore.load()`），抄成两份的话
    /// 以后加一个 case 只改了一头，表现是「存进去了、读回来没了」，而且不报错。
    private static func insertRecentContainers(_ plan: Plan, into db: SQLiteDatabase) throws {
        let sql = """
            INSERT INTO recent_container (position, dedupe_key, kind, ref_id, payload)
            VALUES (?,?,?,?,?)
            """
        for (position, container) in plan.containers.enumerated() {
            let row = container.storageRow
            // `dedupe_key` 一律取 `RecentContainer.id`，**不按 case 自己拼**。
            // 关键在 `.playlist` 与 `.libraryPlaylist` **故意共用 `playlist:` 前缀**：
            // 同一份歌单有两条路进来（资料库歌单页 / 目录页），而 `LibraryPlaylist.from`
            // 沿用的就是音源歌单的 id。按 case 拆开前缀就会把同一份歌单摆成两张卡。
            try db.run(sql, [position, container.id, row.kind, row.refID, row.payload])
        }
    }

    /// 按 id 挂的那几本账：播放统计、评分、几份 id 集合。
    ///
    /// **游离键照搬，不许顺手清理。** 实测 `lastPlayedAt` 有 121 个键，而 `libraryTracks`
    /// 只有 57 条——听过但没入库的、入库后又移出的都在里面。「账按 id 记，与在不在资料库里
    /// 无关」是现有语义，所以这几张表**故意都没有外键**，这里也不按曲目池过滤。
    private static func insertLedgers(_ plan: Plan, into db: SQLiteDatabase) throws {
        let archive = plan.archive
        let playCounts = archive.playCounts ?? [:]
        let skipCounts = archive.skipCounts ?? [:]
        let addedAt = archive.addedAt ?? [:]
        let lastPlayedAt = archive.lastPlayedAt ?? [:]
        let lastSkippedAt = archive.lastSkippedAt ?? [:]

        // 五本账在旧存档里是五个独立字典，键各不相同（放过没跳过的只在 playCounts 里）。
        // 合成一行的前提是先取键的并集，不能拿任何一本当主键源。
        var ids = Set(playCounts.keys)
        ids.formUnion(skipCounts.keys)
        ids.formUnion(addedAt.keys)
        ids.formUnion(lastPlayedAt.keys)
        ids.formUnion(lastSkippedAt.keys)

        let statSQL = """
            INSERT INTO track_stat (track_id, play_count, skip_count, added_at,
                                    last_played_at, last_skipped_at)
            VALUES (?,?,?,?,?,?)
            """
        for id in ids.sorted() {
            try db.run(statSQL, [id, playCounts[id] ?? 0, skipCounts[id] ?? 0,
                                 addedAt[id], lastPlayedAt[id], lastSkippedAt[id]])
        }

        for (id, value) in (archive.ratings ?? [:]).sorted(by: { $0.key < $1.key }) {
            try db.run("INSERT INTO rating (id, value) VALUES (?,?)", [id, value])
        }

        // 几份纯 id 集合。**先过一遍 `Set`**：`load()` 那边也是 `Set(storage.x ?? [])`，
        // 存档里留着重复项是可能的，而这几张表的主键会把重复项变成一条插入失败。
        let sets: [(String, [String])] = [
            ("favorite_album", archive.favoriteAlbums ?? []),
            ("favorite_artist", archive.favoriteArtists ?? []),
            ("unchecked_track", archive.uncheckedTracks ?? []),
            ("suggest_less_track", archive.suggestLessTracks ?? []),
            ("suggest_less_artist", archive.suggestLessArtists ?? []),
            ("dismissed_account_playlist", archive.dismissedAccountPlaylists ?? []),
        ]
        for (table, values) in sets {
            for id in Set(values).sorted() {
                try db.run("INSERT INTO \(table) (id) VALUES (?)", [id])
            }
        }
    }

    private static func insertTrackInfo(_ plan: Plan, into db: SQLiteDatabase) throws {
        let sql = """
            INSERT INTO track_info (
              track_id, album_artist, composer, show_composer_in_all_views, grouping, genre,
              year, track_count, disc_count, is_compilation, bpm, comments,
              use_work_and_movement, work_name, movement_name, movement_number, movement_count,
              media_kind, start_time_enabled, start_time, stop_time_enabled, stop_time,
              remember_playback_position, skip_when_shuffling, volume_adjustment, equalizer_preset,
              sort_title, sort_album, sort_album_artist, sort_artist, sort_composer, custom_lyrics)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        // title / artist / album / trackNumber / discNumber 五项**故意不落列**：
        // `info(for:)` 每次从 `Track` 现取，资料库那份才是权威。存一份在这儿就是
        // 第二份真值，而且是注定会发霉的那一份。
        for (id, info) in plan.infos.sorted(by: { $0.key < $1.key }) {
            try db.run(sql, [
                id, info.albumArtist, info.composer, info.showComposerInAllViews, info.grouping,
                info.genre, info.year, info.trackCount, info.discCount, info.isCompilation,
                info.bpm, info.comments, info.useWorkAndMovement, info.workName,
                info.movementName, info.movementNumber, info.movementCount,
                info.mediaKind.rawValue, info.startTimeEnabled, info.startTime,
                info.stopTimeEnabled, info.stopTime, info.rememberPlaybackPosition,
                info.skipWhenShuffling, info.volumeAdjustment, info.equalizerPreset,
                info.sortTitle, info.sortAlbum, info.sortAlbumArtist, info.sortArtist,
                info.sortComposer, info.customLyrics,
            ])
        }

        for (id, position) in plan.resumePositions.sorted(by: { $0.key < $1.key }) {
            try db.run("INSERT INTO track_resume (track_id, position) VALUES (?,?)", [id, position])
        }
    }

    private static func insertLoudness(_ plan: Plan, into db: SQLiteDatabase) throws {
        // `gainDB` 是现算的派生量（目标 −16 LUFS、+6 上限、峰值留 1 dB），不落列——
        // 把可调参数算出来的结果存下来，改参数那天就全是陈旧值。
        let sql = "INSERT INTO loudness (track_id, lufs, peak_db, measured_at) VALUES (?,?,?,?)"
        for (id, entry) in plan.loudness.sorted(by: { $0.key < $1.key }) {
            try db.run(sql, [id, entry.lufs, entry.peakDB, entry.measuredAt])
        }
    }

    private static func insertLocalFiles(_ plan: Plan, into db: SQLiteDatabase) throws {
        // codec / sample_rate / bit_depth / tier 这一轮全是 NULL：它们来自 `StreamFormat`，
        // 要重读文件才有，而这里只搬清单里已经有的东西。
        //
        // [阶段 5] 那四列由 `DownloadStore.readFormat(of:)` 在**本来就要读一次文件**的两条路
        // （下载落地、「导入…」认领）上顺手填；已经在库里的老行会一直是 NULL，直到那首歌
        // 被重下或者重新认领一次。**故意不加一趟「把所有文件重读一遍」的回填**——
        // 那正是这四列当初选择「零额外 IO」时要躲开的开销（3000 首 × 40 MB 的冷读）。
        // 等真有消费者（阶段 7 / 8 的按音质筛选）时再看值不值。
        let sql = """
            INSERT INTO local_file (key, scope, relative_path, volume_uuid, bytes, mtime,
                                    added_at, quality, codec, sample_rate, bit_depth, tier,
                                    tagged, tag_version)
            VALUES (?,?,?,NULL,?,?,?,?,?,?,?,?,?,?)
            """
        for row in plan.localFiles {
            try db.run(sql, [row.key, row.scope.rawValue, row.relativePath, row.bytes, row.mtime,
                             row.addedAt, row.quality, row.codec, row.sampleRate, row.bitDepth,
                             row.tier, row.tagged, row.tagVersion])
        }
    }

    // MARK: - 校验

    /// 灌完之后对着源数据把每一张表数一遍。**不过就整个回滚**（删 sidecar、JSON 不动）。
    ///
    /// 为什么值得写这一大段：迁移是一次性的，跑错了没有第二次机会——旧 JSON 改名留底之后
    /// 用户不会再回头看一眼。而「少写了一张表」「position 差一位」这类错在界面上的表现是
    /// 「有几首歌不见了」，不是崩溃，可能几周之后才被发现。
    ///
    /// 收集全部 reason 再一起抛，不是遇到第一条就返回：一次跑完知道全部对不上的地方，
    /// 比修一条跑一遍快得多。
    private static func validate(_ plan: Plan, in db: SQLiteDatabase) throws -> [String] {
        var reasons: [String] = []

        func rows(_ table: String) throws -> Int {
            Int(try db.value("SELECT COUNT(*) FROM \(table)") { $0.int(0) } ?? 0)
        }
        func expect(_ table: String, _ expected: Int) throws {
            let actual = try rows(table)
            if actual != expected { reasons.append("\(table)：期望 \(expected) 行，实际 \(actual) 行") }
        }

        let archive = plan.archive
        try expect("track", plan.tracks.count)
        try expect("library_track", (archive.libraryTracks ?? []).count)
        try expect("favorite_track", archive.favorites.count)
        try expect("recent_track", archive.recents.count)
        try expect("library_album", (archive.libraryAlbums ?? []).count)

        let playlists = archive.playlists ?? []
        try expect("playlist", playlists.count)
        try expect("playlist_track", playlists.reduce(0) { $0 + $1.tracks.count })

        try expect("recent_container", plan.containers.count)
        // `dedupe_key` 上有 UNIQUE，重复本来就插不进去；数一遍是为了把「插入时被
        // 某条 OR IGNORE 咽掉了」这种将来可能被顺手加进来的写法也堵死。
        let distinctKeys = Int(try db.value(
            "SELECT COUNT(DISTINCT dedupe_key) FROM recent_container") { $0.int(0) } ?? 0)
        if distinctKeys != plan.containers.count {
            reasons.append("recent_container：\(plan.containers.count) 行里只有 \(distinctKeys) 个不同的 dedupe_key")
        }

        var statIDs = Set((archive.playCounts ?? [:]).keys)
        statIDs.formUnion((archive.skipCounts ?? [:]).keys)
        statIDs.formUnion((archive.addedAt ?? [:]).keys)
        statIDs.formUnion((archive.lastPlayedAt ?? [:]).keys)
        statIDs.formUnion((archive.lastSkippedAt ?? [:]).keys)
        try expect("track_stat", statIDs.count)
        try expect("rating", (archive.ratings ?? [:]).count)
        try expect("favorite_album", Set(archive.favoriteAlbums ?? []).count)
        try expect("favorite_artist", Set(archive.favoriteArtists ?? []).count)
        try expect("unchecked_track", Set(archive.uncheckedTracks ?? []).count)
        try expect("suggest_less_track", Set(archive.suggestLessTracks ?? []).count)
        try expect("suggest_less_artist", Set(archive.suggestLessArtists ?? []).count)
        try expect("dismissed_account_playlist", Set(archive.dismissedAccountPlaylists ?? []).count)

        try expect("track_info", plan.infos.count)
        try expect("track_resume", plan.resumePositions.count)
        try expect("loudness", plan.loudness.count)
        try expect("local_file", plan.localFiles.count)

        // 五张关系表里每个 track_id 都要能 JOIN 回 `track`。
        // 外键已经打开（`PRAGMA foreign_keys = ON`），照理插不进孤儿行——但
        // `playlist_track` 那条外键将来一旦被谁改成可空、或者哪张表被加了
        // `PRAGMA foreign_keys = OFF` 的路径，这里是第二道闸。
        for table in ["library_track", "favorite_track", "recent_track", "playlist_track"] {
            let orphans = Int(try db.value("""
                SELECT COUNT(*) FROM \(table) r LEFT JOIN track t ON t.id = r.track_id
                WHERE t.id IS NULL
                """) { $0.int(0) } ?? 0)
            if orphans > 0 { reasons.append("\(table)：有 \(orphans) 行的 track_id 在 track 表里找不到") }
        }
        // 第五处是台账里的 `.track`：它走 `ref_id`，没有外键可依。
        let orphanContainers = Int(try db.value("""
            SELECT COUNT(*) FROM recent_container c LEFT JOIN track t ON t.id = c.ref_id
            WHERE c.kind = 'track' AND t.id IS NULL
            """) { $0.int(0) } ?? 0)
        if orphanContainers > 0 {
            reasons.append("recent_container：有 \(orphanContainers) 条 .track 的 ref_id 在 track 表里找不到")
        }

        reasons.append(contentsOf: try spotCheckTracks(plan, in: db))
        return reasons
    }

    /// 随机抽三首，13 个字段逐个比对。
    ///
    /// 计数对得上只说明行数对，说明不了**列有没有错位**——`INSERT` 的列清单与 `VALUES`
    /// 的绑定顺序错一位，计数照样全对，而库里每首歌的专辑名都变成了艺人名。
    /// 抽查是唯一能抓到这种错的检查，而且它只要三行的代价。
    private static func spotCheckTracks(_ plan: Plan, in db: SQLiteDatabase) throws -> [String] {
        guard !plan.tracks.isEmpty else { return [] }
        var reasons: [String] = []
        let samples = plan.tracks.count <= 3 ? plan.tracks : (0..<3).map { _ in
            plan.tracks[Int.random(in: 0..<plan.tracks.count)]
        }

        let sql = """
            SELECT id, kind, title, artist_name, artist_id, album_name, album_id, artwork_url,
                   duration, track_number, disc_number, media_mid, lossless_available, album_key
            FROM track WHERE id = ?
            """
        for track in samples {
            guard let row = try db.value(sql, [track.id], { row -> [String: String] in
                [
                    "id": row.text(0), "kind": row.text(1), "title": row.text(2),
                    "artist_name": row.text(3), "artist_id": describe(row.optText(4)),
                    "album_name": row.text(5), "album_id": describe(row.optText(6)),
                    "artwork_url": describe(row.optText(7)),
                    "duration": String(row.double(8)),
                    "track_number": describe(row.optInt(9).map(Int.init)),
                    "disc_number": describe(row.optInt(10).map(Int.init)),
                    "media_mid": describe(row.optText(11)),
                    "lossless_available": describe(row.optBool(12)),
                    "album_key": row.text(13),
                ]
            }) else {
                reasons.append("抽查：\(track.id) 在 track 表里没有这一行")
                continue
            }
            let expected: [String: String] = [
                "id": track.id, "kind": track.kind.rawValue, "title": track.title,
                "artist_name": track.artistName, "artist_id": describe(track.artistId),
                "album_name": track.albumName, "album_id": describe(track.albumId),
                "artwork_url": describe(track.artworkURL),
                "duration": String(track.duration),
                "track_number": describe(track.trackNumber),
                "disc_number": describe(track.discNumber),
                "media_mid": describe(track.mediaMid),
                "lossless_available": describe(track.losslessAvailable),
                "album_key": LibraryStore.fallbackKey(for: track.asTrack),
            ]
            for (column, want) in expected.sorted(by: { $0.key < $1.key })
            where row[column] != want {
                reasons.append("抽查 \(track.id)：\(column) 期望 \(want)，实际 \(row[column] ?? "－")")
            }
        }
        return reasons
    }

    /// 比对用的字符串化。`nil` 与空串必须看得出区别——`media_mid` 是空串还是 NULL，
    /// 在取流那头是两件事。
    private static func describe(_ value: (some CustomStringConvertible)?) -> String {
        value.map { "\($0)" } ?? "<NULL>"
    }

    /// 报告里的计数：从库里现数，不是把写的时候的计数器抄出来。
    private static func count(in db: SQLiteDatabase) throws -> [String: Int] {
        let tables = [
            "track", "library_track", "favorite_track", "recent_track", "library_album",
            "playlist", "playlist_track", "recent_container", "track_stat", "rating",
            "favorite_album", "favorite_artist", "unchecked_track", "suggest_less_track",
            "suggest_less_artist", "dismissed_account_playlist", "track_info", "track_resume",
            "loudness", "local_file", "search_index",
        ]
        var counts: [String: Int] = [:]
        for table in tables {
            counts[table] = Int(try db.value("SELECT COUNT(*) FROM \(table)") { $0.int(0) } ?? 0)
        }
        return counts
    }
}
