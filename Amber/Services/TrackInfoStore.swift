import Foundation
import os

// MARK: - 面板字段

/// 「显示简介」面板能编辑的全部字段。Track 本身有的那几项（标题/艺人/专辑/音轨/光盘）
/// 在提交时写回 LibraryStore 的 Track 记录，其余只存在这里。
///
/// 字段清单照 getinfo 规格 §4.1（详细信息）/ §4.4（选项）/
/// §4.5（分类）与 §4.3（歌词）。§4.2（插图）、§4.6（文件）不在这里：插图走已有的
/// `artworkURL` 与导入链，文件页全只读、由界面层现算。
struct TrackInfo: Codable, Equatable, Sendable {
    // —— 详细信息页
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var albumArtist: String = ""
    var composer: String = ""
    var showComposerInAllViews: Bool = false
    var grouping: String = ""
    var genre: String = ""
    var year: Int? = nil
    var trackNumber: Int? = nil
    var trackCount: Int? = nil
    var discNumber: Int? = nil
    var discCount: Int? = nil
    var isCompilation: Bool = false
    var bpm: Int? = nil
    var comments: String = ""
    /// 首行弹出菜单的二选一（[AX] 实测只有「标题」/「作品名称」两项）
    var useWorkAndMovement: Bool = false
    var workName: String = ""
    var movementName: String = ""
    var movementNumber: Int? = nil
    var movementCount: Int? = nil

    // —— 选项页
    var mediaKind: MediaKind = .music
    var startTimeEnabled: Bool = false
    var startTime: TimeInterval = 0
    var stopTimeEnabled: Bool = false
    /// nil = 用曲目原时长
    var stopTime: TimeInterval? = nil
    var rememberPlaybackPosition: Bool = false
    var skipWhenShuffling: Bool = false
    /// [AX] 值域 −255…255，11 个吸附档步长 51，±255 ↔ ±100%
    var volumeAdjustment: Int = 0
    /// nil = 「无」。取值是 `EqualizerPreset.name`
    var equalizerPreset: String? = nil

    // —— 分类页
    var sortTitle: String = ""
    var sortAlbum: String = ""
    var sortAlbumArtist: String = ""
    var sortArtist: String = ""
    var sortComposer: String = ""

    // —— 歌词页
    /// 非 nil ＝「自定义歌词」勾着，用这份纯文本顶掉音源的词
    var customLyrics: String? = nil

    enum MediaKind: String, Codable, CaseIterable, Sendable {
        case music, movie, homeVideo, tvShow, audiobook, book, podcast, videoPodcast, musicVideo

        /// [RES] 清单照 Music 自己那张 **`res 241` 的前 9 条单选面板标题**
        ///（`Tools/loc-strings.py --res 241`）：
        ///
        /// ```
        /// 1 歌曲信息  2 电影信息  3 本地视频信息  4 电视节目信息  5 有声书信息
        /// 6 图书信息  7 播客信息  8 视频播客信息  9 音乐视频信息
        /// （10 光盘信息 / 11 iTunes LP / 12 iTunes 特辑不是「媒体种类」，
        ///   是另外三种容器形态，不摆进这颗弹出菜单）
        /// ```
        ///
        /// 面板标题按媒体种类分了这几套，多选那一族（13–22）也一一对应，
        /// 所以这九条就是媒体种类的取值域。**弹出菜单本身没采到**
        ///（sample §4.7：样本是云端曲目，菜单里只有当前值一项；本地文件的
        /// 完整选项集是 spec §7 #10 的缺口），所以「顺序照标题表」这一点是 `[推]`。
        ///
        /// 原先只摆五条（音乐/播客/有声书/音乐视频/家庭视频）是照 spec §4.4 那句
        /// 散文写的，比标题表少了电影、电视节目、图书、视频播客四种。
        var displayName: String {
            switch self {
            case .music: return "音乐"
            case .movie: return "电影"
            case .homeVideo: return "本地视频"
            case .tvShow: return "电视节目"
            case .audiobook: return "有声书"
            case .book: return "图书"
            case .podcast: return "播客"
            case .videoPodcast: return "视频播客"
            case .musicVideo: return "音乐视频"
            }
        }

        /// [RES] 面板标题（`res 241` 1–9），单选态。换媒体种类时窗口标题跟着换。
        var panelTitle: String {
            switch self {
            case .music: return "歌曲信息"
            case .movie: return "电影信息"
            case .homeVideo: return "本地视频信息"
            case .tvShow: return "电视节目信息"
            case .audiobook: return "有声书信息"
            case .book: return "图书信息"
            case .podcast: return "播客信息"
            case .videoPodcast: return "视频播客信息"
            case .musicVideo: return "音乐视频信息"
            }
        }
    }

    init() {}

    /// **只剩迁移器在用**：面板的存储格式已经是 `track_info` 那三十二列，这份 `Codable`
    /// 现在唯一的消费者是 `AmberDatabaseMigration` 读那一次旧 `trackinfo.json`
    /// （以及钉住它的那几条用例）。
    ///
    /// 手写 `init(from:)` 而不是用合成的：合成的 `Decodable` 对非可选属性缺键会直接抛错，
    /// 而旧存档正是「上一版 Amber 写的、少几个后来才加的键」那种——整份解不出来
    /// ＝ 用户手打的注释、自定义歌词在迁移那一刻一次全丢。所以这一串不能删。
    ///
    /// **但新加的面板字段不要再往这里加一行**：它们只会出现在升级链的 `ADD COLUMN` 里，
    /// 旧 JSON 里永远不可能有（那份文件在迁移那天就停止生长了）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// `try?` 套在`decodeIfPresent` 外面会多一层可选（`String??`），逐个拆平。
        func optString(_ key: CodingKeys) -> String? { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) }
        func str(_ key: CodingKeys) -> String { optString(key) ?? "" }
        func int(_ key: CodingKeys) -> Int? { ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) }
        func bool(_ key: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        func seconds(_ key: CodingKeys) -> TimeInterval? {
            ((try? c.decodeIfPresent(TimeInterval.self, forKey: key)) ?? nil)
        }

        title = str(.title)
        artist = str(.artist)
        album = str(.album)
        albumArtist = str(.albumArtist)
        composer = str(.composer)
        showComposerInAllViews = bool(.showComposerInAllViews)
        grouping = str(.grouping)
        genre = str(.genre)
        year = int(.year)
        trackNumber = int(.trackNumber)
        trackCount = int(.trackCount)
        discNumber = int(.discNumber)
        discCount = int(.discCount)
        isCompilation = bool(.isCompilation)
        bpm = int(.bpm)
        comments = str(.comments)
        useWorkAndMovement = bool(.useWorkAndMovement)
        workName = str(.workName)
        movementName = str(.movementName)
        movementNumber = int(.movementNumber)
        movementCount = int(.movementCount)

        mediaKind = ((try? c.decodeIfPresent(MediaKind.self, forKey: .mediaKind)) ?? nil) ?? .music
        startTimeEnabled = bool(.startTimeEnabled)
        startTime = seconds(.startTime) ?? 0
        stopTimeEnabled = bool(.stopTimeEnabled)
        stopTime = seconds(.stopTime)
        rememberPlaybackPosition = bool(.rememberPlaybackPosition)
        skipWhenShuffling = bool(.skipWhenShuffling)
        volumeAdjustment = int(.volumeAdjustment) ?? 0
        equalizerPreset = optString(.equalizerPreset)

        sortTitle = str(.sortTitle)
        sortAlbum = str(.sortAlbum)
        sortAlbumArtist = str(.sortAlbumArtist)
        sortArtist = str(.sortArtist)
        sortComposer = str(.sortComposer)

        customLyrics = optString(.customLyrics)
    }
}

extension TrackInfo {
    /// 按一条曲目现有的字段填一份「没编辑过」的简介。
    init(track: Track) {
        self.init()
        title = track.title
        artist = track.artistName
        album = track.albumName
        trackNumber = track.trackNumber
        discNumber = track.discNumber
    }

    /// 面板改完之后，Track 本体那五项的现值（`LibraryStore.updateTrack` 的 transform 用）。
    ///
    /// **标题留了一道空值闸**：清空标题等于把资料库里那一行变成空白，界面上看着就像
    /// 曲目丢了。Track 的其余四项清空都是合法编辑（专辑名确实可以没有），只有标题
    /// 空了就回落旧值。[推]
    func apply(to track: inout Track) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { track.title = title }
        track.artistName = artist
        track.albumName = album
        track.trackNumber = trackNumber
        track.discNumber = discNumber
    }
}

// MARK: - 均衡器预设

/// 选项页「均衡器」弹出菜单的预设名。
///
/// **只有名字是实测的**：`getinfo 样本` §4.7 对 `ITID:17` 发`AXPress` 展开，
/// 数到 24 项——首项「无」之后一条分隔线，所以名字是 23 条。
/// **每个预设的频段曲线一条证据都没有**（Music 的 EQ 系数没挖到），
/// 所以这里只有名字，没有曲线；生效部分见本文件末尾那条缺口说明。
enum EqualizerPreset {

    /// [AX] 顺序照实测，`names[0]` 是「无」＝不加均衡（面板上它后面画一条分隔线）。
    static let names: [String] = [
        "无",
        "低沉", "电子乐", "钢琴曲", "高音", "古典",
        "减少低音", "减少高音", "爵士乐", "拉丁音乐", "流行乐",
        "平缓", "诵读音乐", "舞曲", "嘻哈音乐", "小型扬声器",
        "休闲音乐", "摇滚乐", "原声", "增加低音", "增加高音",
        "增加声乐", "R&B",
    ]

    /// 「无」那一项的名字。存进 `TrackInfo.equalizerPreset` 的 nil 与它同义。
    static let none = "无"

    /// 认不认识这个名字（旧存档里存过、后来改名的预设读回来当「无」）。
    static func isKnown(_ name: String) -> Bool { names.contains(name) }
}

// MARK: - 起播时要问的那几项

/// 起播 / 组随机队列时问「这首要不要跳过 / 从哪起 / 到哪停 / 音量补多少」的轻结构。
/// 全是默认值时 `TrackInfoStore.playbackOverrides(for:)` 返回 nil，播放器照老路走。
struct PlaybackOverrides: Equatable, Sendable {
    var startTime: TimeInterval?      // 起播位置
    var stopTime: TimeInterval?       // 提前结束
    var skipWhenShuffling: Bool
    var rememberPlaybackPosition: Bool
    var volumeAdjustment: Int         // −255…255
    var equalizerPreset: String?

    init(startTime: TimeInterval? = nil, stopTime: TimeInterval? = nil,
         skipWhenShuffling: Bool = false, rememberPlaybackPosition: Bool = false,
         volumeAdjustment: Int = 0, equalizerPreset: String? = nil) {
        self.startTime = startTime
        self.stopTime = stopTime
        self.skipWhenShuffling = skipWhenShuffling
        self.rememberPlaybackPosition = rememberPlaybackPosition
        self.volumeAdjustment = volumeAdjustment
        self.equalizerPreset = equalizerPreset
    }

    /// 什么都没设：等于没有 override。
    static let neutral = PlaybackOverrides()

    init(_ info: TrackInfo) {
        self.init(
            // 勾没勾上是开关，值是值：勾着但值是 0 与没勾同解（起播本来就从 0 起）。
            startTime: (info.startTimeEnabled && info.startTime > 0) ? info.startTime : nil,
            stopTime: info.stopTimeEnabled ? info.stopTime : nil,
            skipWhenShuffling: info.skipWhenShuffling,
            rememberPlaybackPosition: info.rememberPlaybackPosition,
            volumeAdjustment: info.volumeAdjustment,
            equalizerPreset: (info.equalizerPreset == EqualizerPreset.none) ? nil : info.equalizerPreset)
    }

    /// 音量调整滑杆 −255…255 折成 dB。
    ///
    /// **±100% 对应多少 dB 没有实测证据** `[推]`：只量到滑杆的量程（−255…255，
    /// 11 个吸附档步长 51）和两端的字面串 `-100%` / `+100%`，Music 把百分比折成增益的
    /// 那段代码没挖到。取 **±12 dB**——iTunes 这根滑杆传统上就是 ±100% ↔ 约 ±12 dB
    /// 的量程（也是 ReplayGain 之类逐曲增益字段的常用满量程）；再大就会把已经接近
    /// 满刻度的母带推爆，再小又调不动。中间线性插值：滑杆在 AX 里是线性量程，
    /// 11 个等距吸附档也说明它不是对数刻度。
    static let fullScaleDB: Double = 12

    static func gainDB(forAdjustment raw: Int) -> Double {
        let clamped = Double(min(max(raw, -255), 255))
        return clamped / 255 * fullScaleDB
    }

    var gainDB: Double { Self.gainDB(forAdjustment: volumeAdjustment) }
}

// MARK: - 存档

/// 「显示简介」面板的编辑结果，落在主库的 `track_info` 与 `track_resume` 两张表里。
///
/// **从前另存一份 `trackinfo.json`**，理由是「面板三十多个字段、注释与自定义歌词
/// 能长到几 KB，塞进 `library.json` 就意味着每一次心水 / 评分 / 播放计数都要把整份
/// 简介重新编码写盘一遍」——那是**整份重写**时代的账：两份表改动频率差两个数量级，
/// 只能靠分成两个文件、各自防抖来隔开。
///
/// 并进主库之后这条理由自然消失：写的粒度是**那一行**，改一首歌的 bpm 只重写那一行，
/// 别人的注释、别人的自定义歌词一个字节都不碰，连同一首歌的那几 KB 歌词也只在
/// 它自己被改时才重写。三十多个字段因此**逐列展开、不存整块 JSON**——存整块的话
/// 「改一个 bpm」又变回「把这一首的几 KB 歌词重写一遍」，等于把刚拆掉的那笔写放大
/// 按首搬了回来。
///
/// 断点（`track_resume`）单开一张表，理由见 schema 里那段：那张是设置，这张是状态。
@MainActor
@Observable
final class TrackInfoStore {

    static let shared = TrackInfoStore()

    /// 编辑过的那些曲目。键是 `track.id`。
    /// 面板一次只开一首，改完要让歌曲表跟着重画——所以这一份要可观察
    /// （与 `LibraryStore.ratings` 同性质，不是逐行热查的那一类）。
    ///
    /// **内存这一份与 `track_info` 那一行逐字相同**：`title` / `artist` / `album` /
    /// `trackNumber` / `discNumber` 五项在两边都是空的，由 `info(for:)` 每次从 `Track`
    /// 现取（见 `stored(_:)`）。留在内存里就是第二份真值，而且是注定会发霉的那一份。
    private(set) var infos: [String: TrackInfo] = [:]

    /// 「记住播放位置」记下的断点。**不进 `TrackInfo` 本体**：那是设置，这是状态——
    /// 混在一起的话，面板每次比对「有没有改」都会被播放进度搅成「改了」。
    private(set) var resumePositions: [String: TimeInterval] = [:]
    /// 上一次真写进 `track_resume` 的各首断点。播放中每 0.1 s 来一次，挪得不够远就不写。
    private var persistedResumePositions: [String: TimeInterval] = [:]
    /// 断点挪过这么多秒才值得再写一次库。[推]
    private static let resumeSaveStep: TimeInterval = 5

    /// 读库失败与落库失败两条。与 `LibraryStore.log` 同解（都是降级路径，不弹界面）。
    private static let log = AmberDiagnostics.logger("trackinfo")

    /// 主库连接。**nil ＝ 开库这一步就失败了**（磁盘满、目录没权限）：内存这一份照常能用，
    /// 只是这一程的改动落不了盘。与 `LibraryStore.database` 同解。
    private let database: AmberDatabase?

    /// `directory` 供测试注入临时目录；默认落`~/Library/Application Support/Amber/`。
    /// 解析规则由 `AmberDatabase.shared(directory:)` 一处管着——同一个目录拿到同一条连接，
    /// 四个 store 因此共用同一份 `library.sqlite`。
    init(directory: URL? = nil) {
        // 开库之前先把迁移跑到。生产路径上 `AppState` 已经先跑过一次（那一次才有窗口
        // 可以弹错，见 `AppState.prepareDatabase`），所以这里永远撞上「库已存在」那条
        // 幂等分支；留着这一行是为了**谁先开库谁负责迁移**——哪天有人又把某个 store
        // 排到了 `prepareDatabase()` 前面，代价也只是少一次警告，而不是用户的资料库
        // 被一个空库顶掉。`mediaFolder` 原样跟着 `directory` 走，理由见 `LibraryStore.init`。
        _ = try? AmberDatabaseMigration.runIfNeeded(directory: directory, mediaFolder: directory,
                                                    renameLegacyOnSuccess: true)
        database = try? AmberDatabase.shared(directory: directory)
        load()
        // **没有自己的 willTerminate 观察者了**（全 App 只剩 `AmberDatabase` 那一个）。
        // 每一次改动当场落库，退出前唯一还欠着的是被 5 秒台阶闸拦下的那点断点。
        database?.addTerminationTask { [weak self] in self?.writePendingResumePositions() }
    }

    // MARK: - 载入

    /// 载入成功了没有。**没成功就一个字都不许往回写**——与 `LibraryStore.isLoaded` 同解：
    /// 读不出来的时候往回写，等于拿空的覆盖掉好的。
    private var isLoaded = false

    private func load() {
        guard let db = database?.sqlite else { return }
        do {
            try loadFromDatabase(db)
        } catch {
            Self.log.error("""
                读库失败，这一程只读不写（库里那份一个字没动）：\
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// **先全读进局部变量，最后一次性赋值**：读到一半抛错时一个属性都不许动过。
    private func loadFromDatabase(_ db: SQLiteDatabase) throws {
        var loadedInfos: [String: TrackInfo] = [:]
        for row in try db.query(Self.infoSelect, [], { Self.decodeInfo($0) }) {
            loadedInfos[row.id] = row.info
        }
        var loadedResume: [String: TimeInterval] = [:]
        for row in try db.query("SELECT track_id, position FROM track_resume", [],
                                { (id: $0.text(0), position: $0.double(1)) }) {
            loadedResume[row.id] = row.position
        }
        infos = loadedInfos
        resumePositions = loadedResume
        persistedResumePositions = loadedResume
        isLoaded = true
    }

    /// 列序与 `Self.infoUpsert` 逐列对齐，改一处必须改另一处（`Row` 是按序号取的）。
    private static let infoSelect = """
        SELECT track_id, album_artist, composer, show_composer_in_all_views, grouping, genre,
               year, track_count, disc_count, is_compilation, bpm, comments,
               use_work_and_movement, work_name, movement_name, movement_number, movement_count,
               media_kind, start_time_enabled, start_time, stop_time_enabled, stop_time,
               remember_playback_position, skip_when_shuffling, volume_adjustment, equalizer_preset,
               sort_title, sort_album, sort_album_artist, sort_artist, sort_composer, custom_lyrics
        FROM track_info
        """

    private static func decodeInfo(_ row: Row) -> (id: String, info: TrackInfo) {
        var info = TrackInfo()
        // title / artist / album / trackNumber / discNumber 五项表里**没有列**，
        // 这里也就不填——`info(for:)` 每次从 `Track` 现取（见 schema 注释）。
        info.albumArtist = row.text(1)
        info.composer = row.text(2)
        info.showComposerInAllViews = row.bool(3)
        info.grouping = row.text(4)
        info.genre = row.text(5)
        info.year = row.optInt(6).map(Int.init)
        info.trackCount = row.optInt(7).map(Int.init)
        info.discCount = row.optInt(8).map(Int.init)
        info.isCompilation = row.bool(9)
        info.bpm = row.optInt(10).map(Int.init)
        info.comments = row.text(11)
        info.useWorkAndMovement = row.bool(12)
        info.workName = row.text(13)
        info.movementName = row.text(14)
        info.movementNumber = row.optInt(15).map(Int.init)
        info.movementCount = row.optInt(16).map(Int.init)
        info.mediaKind = TrackInfo.MediaKind(rawValue: row.text(17)) ?? .music
        info.startTimeEnabled = row.bool(18)
        info.startTime = row.double(19)
        info.stopTimeEnabled = row.bool(20)
        // 三态：NULL ＝ 用曲目原时长，不是 0 秒。
        info.stopTime = row.optDouble(21)
        info.rememberPlaybackPosition = row.bool(22)
        info.skipWhenShuffling = row.bool(23)
        info.volumeAdjustment = Int(row.int(24))
        // 同上：NULL ＝「无」。
        info.equalizerPreset = row.optText(25)
        info.sortTitle = row.text(26)
        info.sortAlbum = row.text(27)
        info.sortAlbumArtist = row.text(28)
        info.sortArtist = row.text(29)
        info.sortComposer = row.text(30)
        info.customLyrics = row.optText(31)
        return (row.text(0), info)
    }

    // MARK: - 读

    /// 没编辑过就按 Track 现有字段现填一份（title/artist/album/trackNumber/discNumber
    /// 从 track 来，其余空）。永远返回一份完整的，调用处不用判空。
    ///
    /// 编辑过的那五项也**照样从 track 现取**：资料库那份才是权威（别处改过标题、
    /// 导入回填过专辑名，面板一打开就该看见新值）。
    func info(for track: Track) -> TrackInfo {
        guard var stored = infos[track.id] else { return TrackInfo(track: track) }
        stored.title = track.title
        stored.artist = track.artistName
        stored.album = track.albumName
        stored.trackNumber = track.trackNumber
        stored.discNumber = track.discNumber
        return stored
    }

    /// 起播时问「这首要不要跳过 / 从哪起 / 到哪停 / 音量补多少」用的轻查询，
    /// 没编辑过的返回 nil，热路径上不构造整份 TrackInfo。
    func playbackOverrides(for id: String) -> PlaybackOverrides? {
        guard let info = infos[id] else { return nil }
        let overrides = PlaybackOverrides(info)
        // 只改过注释 / 分类的那些曲目在播放这条路上与没编辑过完全等价，
        // 一律回 nil，让播放器走「没有 override」那条一行不差的老路。
        return overrides == .neutral ? nil : overrides
    }

    /// 自定义歌词（勾了「自定义歌词」的那些曲目）。没有就是 nil，歌词照旧问音源。
    func customLyrics(for id: String) -> String? { infos[id]?.customLyrics }

    // MARK: - 写

    /// 提交面板的编辑。写两处：
    /// ① Track 本体有的字段（title/artistName/albumName/trackNumber/discNumber）
    ///    走 `LibraryStore.updateTrack(id:transform:)` 改资料库里那份（四处数组 + 播放列表）；
    /// ② 其余落进 `track_info` 里**那一行**。与 `info(for:)` 完全一致时什么都不做。
    func update(_ info: TrackInfo, for track: Track, library: LibraryStore) {
        guard info != self.info(for: track) else { return }
        library.updateTrack(id: track.id) { info.apply(to: &$0) }
        let stored = Self.stored(info)
        infos[track.id] = stored
        persist("简介") { db in try db.run(Self.infoUpsert, Self.binds(stored, id: track.id)) }
    }

    /// 面板上按「恢复」/ 清空这一首的全部编辑（Track 本体那五项不动——它们已经写进
    /// 资料库了，撤不回来）。
    func clear(for id: String) {
        guard infos.removeValue(forKey: id) != nil else { return }
        persist("清空简介") { db in
            try db.run("DELETE FROM track_info WHERE track_id = ?", [id])
        }
    }

    /// 面板交上来的那一份里，Track 本体那五项抹掉之后的样子——也就是 `track_info`
    /// 那一行的样子。它们的权威在资料库里（`apply(to:)` 刚写回去），存第二份只会发霉。
    private static func stored(_ info: TrackInfo) -> TrackInfo {
        var stored = info
        stored.title = ""
        stored.artist = ""
        stored.album = ""
        stored.trackNumber = nil
        stored.discNumber = nil
        return stored
    }

    // MARK: - 记住播放位置

    func resumePosition(for id: String) -> TimeInterval? { resumePositions[id] }

    /// 记 / 清一首的断点。播放器每 0.1 s 来一次，所以这里自己把写盘拦下来：
    /// 内存里随时是新的，只有挪过 `resumeSaveStep` 秒或者被清掉时才写一次。
    /// （退出前那道台阶闸拦下的最后一点由 `writePendingResumePositions` 补上，
    /// 见 `init` 里登记的收尾。）
    ///
    /// **这道闸一个字没改**：从 JSON 换到 SQL 只换了「写」——从前是排一次整份重写，
    /// 现在是一条单行 UPSERT。
    func setResumePosition(_ seconds: TimeInterval?, for id: String) {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            guard resumePositions.removeValue(forKey: id) != nil else { return }
            persistedResumePositions.removeValue(forKey: id)
            persist("清断点") { db in
                try db.run("DELETE FROM track_resume WHERE track_id = ?", [id])
            }
            return
        }
        resumePositions[id] = seconds
        let persisted = persistedResumePositions[id]
        guard persisted == nil || abs(seconds - persisted!) >= Self.resumeSaveStep else { return }
        persistedResumePositions[id] = seconds
        persist("断点") { db in try Self.writeResume(seconds, id: id, in: db) }
    }

    /// 台阶闸拦下的那一点（内存比表新的全部断点）补写下去。
    ///
    /// 退出前跑一次（见 `init`），于是「放到 2:03 退出、再打开」恢复到的是 2:03 而不是
    /// 上一格台阶的 1:58——这与从前 `flushNow` 在 `willTerminate` 里整份写下去是同一件事，
    /// 只是现在只写真的动过的那几行。
    private func writePendingResumePositions() {
        let pending = resumePositions.filter { persistedResumePositions[$0.key] != $0.value }
        guard !pending.isEmpty else { return }
        persist("补断点") { db in
            for (id, seconds) in pending { try Self.writeResume(seconds, id: id, in: db) }
        }
        persistedResumePositions = resumePositions
    }

    private static func writeResume(_ seconds: TimeInterval, id: String,
                                    in db: SQLiteDatabase) throws {
        try db.run("""
            INSERT INTO track_resume (track_id, position) VALUES (?,?)
            ON CONFLICT(track_id) DO UPDATE SET position = excluded.position
            """, [id, seconds])
    }

    // MARK: - 落库

    /// 写库的唯一出口：一个事务 + 出错只记一笔。与 `LibraryStore.persist` 同解——
    /// 改简介是「用户点了一下」的路径，磁盘满的时候抛个异常出去，界面层没有有意义的处置；
    /// 下面每一处都是「按内存现值整行写」，下一次成功的写自会补齐。
    private func persist(_ label: String, _ body: (SQLiteDatabase) throws -> Void) {
        guard isLoaded, let db = database?.sqlite else { return }
        do {
            try db.transaction { try body(db) }
        } catch {
            Self.log.error("""
                \(label, privacy: .public) 落库失败：\
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// 列序与 `Self.infoSelect` 逐列对齐。
    ///
    /// 面板是**整份**交上来的（点一次「好」提交全部字段），所以写的单位是**那一行**，
    /// 不去逐字段比出「只有 bpm 变了」再拼一条窄 UPDATE：那要另存一份「表里现在是什么」
    /// 的影子副本，而省下的是同一行里的几个格子——SQLite 本来就是整页写。
    /// 真正拆掉的那笔写放大是「整份存档」→「一行」，在这里就已经拿到了。
    private static let infoUpsert = """
        INSERT INTO track_info (
          track_id, album_artist, composer, show_composer_in_all_views, grouping, genre,
          year, track_count, disc_count, is_compilation, bpm, comments,
          use_work_and_movement, work_name, movement_name, movement_number, movement_count,
          media_kind, start_time_enabled, start_time, stop_time_enabled, stop_time,
          remember_playback_position, skip_when_shuffling, volume_adjustment, equalizer_preset,
          sort_title, sort_album, sort_album_artist, sort_artist, sort_composer, custom_lyrics)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(track_id) DO UPDATE SET
          album_artist = excluded.album_artist, composer = excluded.composer,
          show_composer_in_all_views = excluded.show_composer_in_all_views,
          grouping = excluded.grouping, genre = excluded.genre, year = excluded.year,
          track_count = excluded.track_count, disc_count = excluded.disc_count,
          is_compilation = excluded.is_compilation, bpm = excluded.bpm,
          comments = excluded.comments,
          use_work_and_movement = excluded.use_work_and_movement,
          work_name = excluded.work_name, movement_name = excluded.movement_name,
          movement_number = excluded.movement_number, movement_count = excluded.movement_count,
          media_kind = excluded.media_kind,
          start_time_enabled = excluded.start_time_enabled, start_time = excluded.start_time,
          stop_time_enabled = excluded.stop_time_enabled, stop_time = excluded.stop_time,
          remember_playback_position = excluded.remember_playback_position,
          skip_when_shuffling = excluded.skip_when_shuffling,
          volume_adjustment = excluded.volume_adjustment,
          equalizer_preset = excluded.equalizer_preset,
          sort_title = excluded.sort_title, sort_album = excluded.sort_album,
          sort_album_artist = excluded.sort_album_artist, sort_artist = excluded.sort_artist,
          sort_composer = excluded.sort_composer, custom_lyrics = excluded.custom_lyrics
        """

    private static func binds(_ info: TrackInfo, id: String) -> [any SQLBindable] {
        [
            id, info.albumArtist, info.composer, info.showComposerInAllViews, info.grouping,
            info.genre, info.year, info.trackCount, info.discCount, info.isCompilation,
            info.bpm, info.comments, info.useWorkAndMovement, info.workName,
            info.movementName, info.movementNumber, info.movementCount,
            info.mediaKind.rawValue, info.startTimeEnabled, info.startTime,
            info.stopTimeEnabled, info.stopTime, info.rememberPlaybackPosition,
            info.skipWhenShuffling, info.volumeAdjustment, info.equalizerPreset,
            info.sortTitle, info.sortAlbum, info.sortAlbumArtist, info.sortArtist,
            info.sortComposer, info.customLyrics,
        ]
    }

    /// 退出前把 wal 并回主库。
    ///
    /// **名字与全部调用点保留。** 从前它是「立刻把防抖中的那份 JSON 同步写下去」；
    /// 现在每一次改动当场落库，只剩两件事：把台阶闸拦下的最后一点断点补上，
    /// 再收掉 WAL 旁文件（见 `AmberDatabase.checkpoint()`）。
    func flushNow() {
        writePendingResumePositions()
        database?.checkpoint()
    }
}

// MARK: - 缺口
//
// **均衡器只存不生效**。预设名是 `[AX]` 实测的 23 条（见`EqualizerPreset.names`），
// 面板能选、能存、能读回来；但**没有接进音频链**，选了「摇滚乐」声音不会变。两条理由：
//
// 1. 每个预设的频段曲线**一条证据都没有**（Music 的 EQ 系数没挖到），接上去就是
//    把 23 条纯 `[推]` 的曲线当成复刻结果——`am-no-per-song-tuning` 那条经验反对的正是这个。
// 2. 接进去要改的是 `AudioTap` 的实时回调：现有的三节 biquad（低架 / 临场感 / 高架）
//    是增强器独占的，再挂一套要给 `TapDSP` 加状态、给`TapShared` 加一把 seqlock，
//    动的是**每一支 item 都要走的播放主路径**。音量调整能用现成的 `tap.setGain(dB:)`
//    叠上去（一个数、一条已经在跑的平滑斜坡），均衡器没有这种现成的挂点。
//
// 真要接：`SoundEnhancerCurve` 那套`Biquad.lowShelf/peaking/highShelf` 直接可用，
// 每个预设写成 3–5 段 `(频率, 增益, Q)`，在`TapDSP` 里另起一串状态跑在`tapEnhance`
// 之后、`tapGain` 之前，并在注释里标明曲线是 Amber 自拟的`[推]`。
