import AppKit
import Foundation

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

    /// **手写 `init(from:)` 而不是用合成的**：合成的`Decodable` 对非可选属性缺键会直接
    /// 抛错（`LibraryStore.Storage` 那一串`decodeIfPresent` 注释是同一个坑）。面板字段
    /// 往后必然还要加，逐条 `decodeIfPresent` 回落默认值，旧存档才不会整份解不出来
    /// ——整份解不出来 ＝ 用户手打的注释、自定义歌词一次全丢。
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

/// 「显示简介」面板的编辑结果。
///
/// **另存一份 `trackinfo.json`，不并进`library.json`**：面板有三十多个字段、
/// 注释与自定义歌词还能长到几 KB，塞进 `LibraryStore.Storage` 就意味着每一次
/// 心水 / 评分 / 播放计数（这些都走同一个 `save()`）都要把整份简介重新编码写盘一遍。
/// 两份表的改动频率差了两个数量级，分开写盘各自防抖才对得上。
///
/// 落盘照抄 `LibraryStore.save()` / `LoudnessStore`：500 ms 防抖 + 串行写盘队列 +
/// 退出前同步兜底。
@MainActor
final class TrackInfoStore: ObservableObject {

    static let shared = TrackInfoStore()

    /// 编辑过的那些曲目。键是 `track.id`。
    /// 面板一次只开一首，改完要让歌曲表跟着重画——所以这一份是 `@Published`
    /// （与 `LibraryStore.ratings` 同性质，不是逐行热查的那一类）。
    @Published private(set) var infos: [String: TrackInfo] = [:]

    /// 「记住播放位置」记下的断点。**不进 `TrackInfo` 本体**：那是设置，这是状态——
    /// 混在一起的话，面板每次比对「有没有改」都会被播放进度搅成「改了」。
    private(set) var resumePositions: [String: TimeInterval] = [:]
    /// 上一次真落盘时各首的断点。播放中每 0.1 s 来一次，挪得不够远就不排写盘。
    private var persistedResumePositions: [String: TimeInterval] = [:]
    /// 断点挪过这么多秒才值得再写一次盘。[推]
    private static let resumeSaveStep: TimeInterval = 5

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?

    private static let saveDebounce: UInt64 = 500_000_000
    private static let writeQueue = DispatchQueue(label: "Amber.TrackInfoStore.write", qos: .utility)

    private struct Storage: Codable {
        var infos: [String: TrackInfo] = [:]
        var resumePositions: [String: TimeInterval]?
    }

    /// `directory` 供测试注入临时目录；默认落`~/Library/Application Support/Amber/`
    /// （与 `library.json` 同一个目录，定位方式照抄`LibraryStore.init`）。
    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Amber", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("trackinfo.json")
        load()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let storage = try? decoder.decode(Storage.self, from: data) {
            infos = storage.infos
            resumePositions = storage.resumePositions ?? [:]
        } else if let bare = try? decoder.decode([String: TrackInfo].self, from: data) {
            // 裸字典格式的存档（契约文档里写的那一版）。读得进来就认，下次写成带壳的。
            infos = bare
        }
        persistedResumePositions = resumePositions
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
    /// ② 其余落进自己这份存档。与 `info(for:)` 完全一致时什么都不做。
    func update(_ info: TrackInfo, for track: Track, library: LibraryStore) {
        guard info != self.info(for: track) else { return }
        library.updateTrack(id: track.id) { info.apply(to: &$0) }
        infos[track.id] = info
        save()
    }

    /// 面板上按「恢复」/ 清空这一首的全部编辑（Track 本体那五项不动——它们已经写进
    /// 资料库了，撤不回来）。
    func clear(for id: String) {
        guard infos.removeValue(forKey: id) != nil else { return }
        save()
    }

    // MARK: - 记住播放位置

    func resumePosition(for id: String) -> TimeInterval? { resumePositions[id] }

    /// 记 / 清一首的断点。播放器每 0.1 s 来一次，所以这里自己把写盘拦下来：
    /// 内存里随时是新的，只有挪过 `resumeSaveStep` 秒或者被清掉时才排一次落盘。
    /// （退出前 `flushNow` 会把最后那一点补上，见`init` 里的 willTerminate。）
    func setResumePosition(_ seconds: TimeInterval?, for id: String) {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            guard resumePositions.removeValue(forKey: id) != nil else { return }
            persistedResumePositions.removeValue(forKey: id)
            save()
            return
        }
        resumePositions[id] = seconds
        let persisted = persistedResumePositions[id]
        guard persisted == nil || abs(seconds - persisted!) >= Self.resumeSaveStep else { return }
        persistedResumePositions[id] = seconds
        save()
    }

    // MARK: - 落盘

    private func save() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            let storage = self.snapshot()
            let url = self.fileURL
            Self.writeQueue.async { Self.write(storage, to: url) }
        }
    }

    /// 立刻同步落盘。退出前兜底与测试断言磁盘内容时用。
    func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        persistedResumePositions = resumePositions
        let storage = snapshot()
        let url = fileURL
        Self.writeQueue.sync { Self.write(storage, to: url) }
    }

    private func snapshot() -> Storage {
        Storage(infos: infos, resumePositions: resumePositions)
    }

    private nonisolated static func write(_ storage: Storage, to url: URL) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: url, options: .atomic)
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
