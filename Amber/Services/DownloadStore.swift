import AVFoundation
import Combine
import Foundation

/// 一首歌的下载状态。UI（••• 菜单、歌曲表的「下载」列）只认这四种。
enum DownloadState: Equatable {
    case none
    /// 0...1。总长度未知（服务端没给 Content-Length）时停在 0，界面按不确定进度画。
    case downloading(progress: Double)
    case downloaded(URL)
    case failed(String)
}

/// 「+ / ↓ / ⏹ / ✓」这一枚键的四种形态。
///
/// 专辑页头、播放列表页头、资料库艺人页的专辑块、艺人目录页的 release 卡、曲目行——
/// 摆的都是同一枚键，词汇必须一模一样（同一张碟从哪儿点都得是同一个手感）。
/// 所以聚合规则写在这里，不在各自的视图里各写一遍 switch。
enum LibraryDownloadAction: Equatable {
    /// 不在资料库：`plus`
    case addToLibrary
    /// 在库、还有没下完的：`arrow.down`
    case download
    /// 有曲目正在下：`stop.fill`（点它取消）
    case stop
    /// 全下完了：`checkmark`（点它移除下载）
    case done

    var symbol: String {
        switch self {
        case .addToLibrary: return "plus"
        case .download: return "arrow.down"
        case .stop: return "stop.fill"
        case .done: return "checkmark"
        }
    }

    var label: String {
        switch self {
        case .addToLibrary: return "添加到资料库"
        case .download: return "下载"
        case .stop: return "停止下载"
        case .done: return "已下载"
        }
    }
}

/// 已下载曲目的落地与索引。
///
/// **这里不需要任何解密**：QQ / 网易的在线取流 URL 给的就是明文音频——2026-09-05 逐档实测
/// 头字节直接是 `fLaC` / `ID3` / `ftyp` / `OggS`，CDN 对任意 byte range 回 206
///（见 `StreamQuality` 的注释）。所以「下载」= 把`providerResolver` 解出来的那条 URL
/// 原样存到磁盘，播的时候换成本地文件。QMC 那套加密只出现在 QQ 官方客户端自己下的 `.mflac` 里。
///
/// Music 的对应行为：下载过的歌在歌曲表里有一个「已下载」标记，••• 菜单第二栏是
/// 「下载 / 移除下载」，且只对已在资料库里的曲目出现（`doDownloadCloudTrackSelection:`
/// 的 validateMenuItem: 就是这么摘的）。歌从资料库删掉时本地那份也一起删。
@MainActor
final class DownloadStore: ObservableObject {

    /// 每首歌的当前状态。`@Published` 让整张表跟着刷新；
    /// 进度是 1% 一跳（见 `report`），不是每个数据包都发一次。
    @Published private(set) var states: [String: DownloadState] = [:]

    /// 由 AppState 注入：解析曲目的**远端**流地址。
    /// 必须是「不查本地」的那一条，否则下载会去读自己刚写下的文件（见 AppState.init）。
    var resolveRemoteURL: ((Track) async throws -> URL)?

    /// 由 AppState 注入：取这首歌的词，写进标签里的歌词那一格（见 `lyricsText`）。
    /// 接的是 `LyricsStore`——两处歌词面板共用的那份缓存，刚看过词的那首一趟网络都不用再打。
    ///
    /// **不抛错**：取不到就是空数组。歌词是锦上添花，不能让它把一次成功的下载拖成失败。
    var resolveLyrics: ((Track) async -> [LyricLine])?

    /// 换「媒体」文件夹时的一句回音（搬完了 / 搬不动），由 AppState 转成 toast。
    /// 搬家是用户在设置窗按了「好」之后才发生的事，没有回音就只能靠去 Finder 里翻。
    var onMediaFolderChanged: ((String) -> Void)?

    /// 一首歌落地并进索引之后叫一次，带上它在「媒体」文件夹里的绝对路径。
    /// `AppState` 接到`LoudnessStore.measureIfNeeded`：已经在本地的文件直接离线量响度，
    /// 用不着等用户把整首听完（音量平衡第一遍只量不调，见 `SettingsValues.soundCheck`）。
    var onDownloaded: ((Track, URL) -> Void)?

    /// 同时最多下几首。多了对 CDN 不礼貌，也没有更快——单条连接本来就能跑满。
    private static let maxConcurrent = 2

    /// 落盘目录 = 设置 › 文件 ›「媒体」文件夹。用户改了路径就整份搬过去（见 `migrate`），
    /// 所以这里是 `var`。
    private var directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    /// 测试注入了目录时不跟着设置跑：那份临时目录才是这次测的落点。
    private let directoryIsPinned: Bool
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    /// id → 索引条目。`states` 是它加上「正在下的那几首」的视图。
    private var index: [String: Entry] = [:]
    /// 正在下载的曲目 id → 任务，用来做并发闸门与取消。
    private var running: [String: Task<Void, Never>] = [:]
    /// 排队等位的曲目，先进先出。
    private var pending: [Track] = []

    /// 索引条目。路径存**相对**「媒体」文件夹的：绝对路径带用户名，换机器/改名字就整份失效；
    /// 而且用户随时能在设置里换文件夹（见 `migrate`），存相对的搬完照旧成立。
    ///
    /// **一个例外**：「文件 › 导入…」没勾「拷贝到媒体文件夹」时，音频原地留在用户自己的
    /// 目录里，那种条目存的是以 `/` 开头的**绝对**路径（见`fileURL(forPath:)`）——
    /// 它不归「媒体」文件夹管，搬家不搬它、删歌也不删它。
    private struct Entry: Codable {
        var path: String
        var bytes: Int
        var date: Date
        /// 音质文案，如「无损 · 44.1 kHz 16 位 FLAC」。落地后从文件本身读，
        /// 不是设置里选的那一档——阶梯会降级，两者常常对不上。
        var quality: String?
        /// 标签写进去了没有。**必须是 Optional**：这一格是后加的，用户手上的老索引里
        /// 根本没有这个键，合成的 `Decodable` 对非可选属性缺键会直接抛错
        ///（理由同 `Track.losslessAvailable`）。
        /// `nil` ＝ 还没补过，`backfillTags` 挑的就是它们。
        var tagged: Bool? = nil
        /// 补这一条时用的写入器版本（`DownloadStore.tagWriterVersion`）。
        /// 同样**必须是 Optional**，理由同上：这一格比 `tagged` 还晚加，
        /// 已经补过标签的老索引里只有 `tagged: true`、没有这个键。
        /// `tagged == true` 但版本对不上就要重排一次，见`needsTagBackfill`。
        var tagVersion: Int? = nil
    }

    /// 标签写入器的版本。**写入器的产物变了就要 +1**，否则用户手上已经补过的那些
    /// 永远等不到新的那一层。
    ///
    /// - 1：最初那版（四种容器各写各的规范标签）。
    /// - 2：现在这一版。这个号原本代表「带封面的 FLAC 前面多一块 ID3v2.4，Finder 才
    ///      看得见封面」，那一手已经撤掉——Finder 那头改走以后的 QuickLook 缩略图扩展，
    ///      写出去的那几个文件用户自己删了，所以号不再往上抬。
    static let tagWriterVersion = 2

    /// `directory` 供测试注入临时目录；默认落设置 › 文件 ›「媒体」文件夹
    /// （出厂 `~/Music/Amber/媒体`，见 `SettingsValues.defaultMediaFolder`）。
    ///
    /// `legacyDirectory` 是这条设置接线之前的老落点`~/Library/Application Support/Amber/Downloads/`：
    /// 新目录还没有索引、老目录有，就整份搬过来一次（首次启动的搬家）。测试注入它来验证这段。
    init(directory: URL? = nil, legacyDirectory: URL? = nil, settings: AppSettings = .shared) {
        self.settings = settings
        directoryIsPinned = directory != nil
        let base = directory ?? settings.values.mediaFolder
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let legacy = legacyDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Amber/Downloads", isDirectory: true)
        adoptLegacyIfNeeded(from: legacy)
        loadIndex()

        // 设置窗按「好」才写回 `AppSettings`，所以这条订阅每次改路径只会响一次。
        // `dropFirst` 跳过当前值：上面已经按它开的目录。
        // 取的是**闭包参数**里的目录，不是 `settings.values`：`@Published` 在`willSet`
        // 发消息，订阅回调里读回去拿到的还是旧值。
        settings.$values
            .map(\.mediaFolder)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] folder in
                guard let self, !self.directoryIsPinned else { return }
                self.migrate(to: folder)
            }
            .store(in: &cancellables)
    }

    // MARK: - 索引里的路径

    /// 索引条目里的路径 → 文件。相对「媒体」文件夹的照旧拼；以 `/` 开头的是
    /// 「文件 › 导入…」原地引用的外部文件，原样当绝对路径用。
    private func fileURL(forPath path: String) -> URL {
        Self.isExternal(path) ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }

    /// 外部（原地引用）条目：绝对路径。搬「媒体」文件夹不搬它，删歌也不删它。
    nonisolated static func isExternal(_ path: String) -> Bool { path.hasPrefix("/") }

    // MARK: - 本地导入

    /// 「文件 › 导入…」落地的本机文件登记进下载索引。
    ///
    /// 为什么让 `DownloadStore` 认领它：歌曲表的「云端下载 / 云端状态」两列、播放取流、
    /// 音质文案，全都只问 `state(for:)`。本地曲目在这里登记一次，那几处一行都不用改，
    /// 也就不会出现「对着一份本机文件画下载箭头，点下去还拿 `local:` 的 id 去打音源」。
    ///
    /// `external` ＝ 文件不在「媒体」文件夹里（没勾「拷贝到媒体文件夹」的原地引用）：
    /// 索引里存绝对路径，从资料库删歌时**不删**它——那是用户自己的文件，不是 Amber 造的。
    func adoptLocalFile(at url: URL, for track: Track, external: Bool) {
        let path: String
        if external {
            path = url.standardizedFileURL.path
        } else {
            // 媒体文件夹内的一律存相对路径，跟下载来的那些同一套规矩。
            let base = directory.standardizedFileURL.path
            let full = url.standardizedFileURL.path
            path = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        index[track.id] = Entry(path: path, bytes: bytes, date: Date(), quality: nil)
        states[track.id] = .downloaded(url)
        saveIndex()
        // 音质文案要读文件，慢一点无所谓，别挡着导入那一串。
        Task { [weak self] in
            guard let text = await Self.qualityText(of: url) else { return }
            guard let self, var entry = self.index[track.id] else { return }
            entry.quality = text
            self.index[track.id] = entry
            self.saveIndex()
        }
        onDownloaded?(track, url)
    }

    // MARK: - 查询

    func state(for trackID: String) -> DownloadState {
        states[trackID] ?? DownloadState.none
    }

    func isDownloaded(_ trackID: String) -> Bool {
        if case .downloaded = state(for: trackID) { return true }
        return false
    }

    /// 已下载曲目占用的磁盘字节数（设置/资料库信息里要报「已下载 n 首，共 x MB」时用）。
    var totalBytes: Int { index.values.reduce(0) { $0 + $1.bytes } }

    /// 索引的一份只读快照：id → 路径（相对「媒体」文件夹的，外部条目是绝对路径）。
    ///
    /// 撞名让位的判据就是它（见 `placement`）。做成快照是给「文件 › 导入…」用的：
    /// 那条路真正算落点的地方在 `Task.detached` 里（`ImportWorker` 整段`nonisolated`），
    /// 够不着这个 store，只能由主线程先抓一份塞进 `ImportOptions`。
    var indexedPaths: [String: String] { index.mapValues(\.path) }

    /// 这一批里正在下的那几首。「停止」只取消它们——已下好的不能顺手删掉。
    func downloadingIDs(in tracks: [Track]) -> [String] {
        tracks.filter {
            if case .downloading = state(for: $0.id) { return true }
            return false
        }.map(\.id)
    }

    /// 一枚键该摆成什么样。`inLibrary` 由调用方给（专辑/播放列表/单曲各有各的判定）。
    func action(inLibrary: Bool, tracks: [Track]) -> LibraryDownloadAction {
        guard inLibrary else { return .addToLibrary }
        guard !tracks.isEmpty else { return .done }
        if !downloadingIDs(in: tracks).isEmpty { return .stop }
        return tracks.allSatisfy { isDownloaded($0.id) } ? .done : .download
    }

    /// 按上面那枚键的语义执行：下 / 停 / 删。`.addToLibrary` 各页的入库路径不同，由调用方自己处理。
    func perform(_ action: LibraryDownloadAction, tracks: [Track]) {
        switch action {
        case .download: download(tracks)
        case .stop: remove(ids: downloadingIDs(in: tracks))
        case .done: removeDownload(tracks)
        case .addToLibrary: break
        }
    }

    // MARK: - 下载

    /// 下载一批曲目。已下载与正在下的跳过；超过并发上限的排队。
    func download(_ tracks: [Track]) {
        for track in tracks {
            guard !isDownloaded(track.id), running[track.id] == nil,
                  !pending.contains(where: { $0.id == track.id })
            else { continue }
            // 先把状态摆成 0 进度：点了菜单要马上有反应，不能等排到它才变样。
            states[track.id] = .downloading(progress: 0)
            pending.append(track)
        }
        pump()
    }

    /// 删掉本地文件与索引条目。正在下的先取消。
    func removeDownload(_ tracks: [Track]) {
        remove(ids: tracks.map(\.id))
    }

    /// 这条曲目在「媒体」文件夹里有一份文件（不是原地引用的外部文件）。
    ///
    /// 「从资料库中删除」要靠它判断该不该问那句「你是要将所选歌曲移到废纸篓，还是要将
    /// 它保留在“媒体”文件夹中？」——[RES] `library 规格` §10.2 的关键限制词是
    /// 「**仅**“媒体”文件夹中的文件」：外部引用的那些删除时只清记录、一个字节都不碰，
    /// 既然如此也就没什么可问的。
    func hasMediaFolderFile(_ trackID: String) -> Bool {
        guard let entry = index[trackID] else { return false }
        return !Self.isExternal(entry.path)
    }

    /// 只清索引与状态，**磁盘上的文件原样留着**（§10.2 的「保留文件」那一支）。
    ///
    /// 与 `remove(ids:)` 的差别只有「删不删文件」这一件事。清索引这一半不能省：
    /// 条目都不在资料库里了，索引里却还记着一条「已下载」，下次同一首歌重新入库时
    /// 会顶着一个指向旧文件的「已下载」状态。
    func forget(ids: [String]) {
        for id in ids {
            running[id]?.cancel()
            running[id] = nil
            pending.removeAll { $0.id == id }
            index[id] = nil
            states.removeValue(forKey: id)
        }
        saveIndex()
        pump()
    }

    /// 移到废纸篓（§10.2 的「移到废纸篓」那一支）。
    ///
    /// 用 `trashItem` 而不是`removeItem`：Music 那句问的就是「移到废纸篓」，
    /// 用户还能反悔捞回来。外部引用的文件照旧一个字节都不碰（只清索引）——
    /// 那是用户自己的文件，删歌不该把人家硬盘上的歌扔进废纸篓。
    func trash(ids: [String]) {
        for id in ids {
            running[id]?.cancel()
            running[id] = nil
            pending.removeAll { $0.id == id }
            if let entry = index[id], !Self.isExternal(entry.path) {
                try? FileManager.default.trashItem(at: fileURL(forPath: entry.path),
                                                   resultingItemURL: nil)
            }
            index[id] = nil
            states.removeValue(forKey: id)
        }
        saveIndex()
        pump()
    }

    /// 按 id 删（曲目从资料库移出时走这条：那时手里只有 id）。
    func remove(ids: [String]) {
        for id in ids {
            running[id]?.cancel()
            running[id] = nil
            pending.removeAll { $0.id == id }
            if let entry = index[id] {
                // 原地引用的本地文件（绝对路径）只清索引：那份文件是用户的，
                // 「从资料库移除」不该把人家硬盘上的歌删了。
                if !Self.isExternal(entry.path) {
                    try? FileManager.default.removeItem(at: fileURL(forPath: entry.path))
                }
                index[id] = nil
            }
            states.removeValue(forKey: id)
        }
        saveIndex()
        pump()
    }

    /// 把队头补到并发上限。每条任务结束时再叫一次。
    private func pump() {
        while running.count < Self.maxConcurrent, !pending.isEmpty {
            let track = pending.removeFirst()
            running[track.id] = Task { [weak self] in
                await self?.run(track)
                guard let self else { return }
                self.running[track.id] = nil
                self.pump()
            }
        }
    }

    private func run(_ track: Track) async {
        do {
            guard let resolveRemoteURL else { throw ProviderError.api("下载未初始化") }
            let remote = try await resolveRemoteURL(track)
            let temp = try await Downloader.fetch(remote) { [weak self] progress in
                Task { @MainActor [weak self] in self?.report(progress, for: track.id) }
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            let relative = try place(temp, for: track)
            let destination = directory.appendingPathComponent(relative)
            // 落地的是裸流，一个标签都没有，按 `Track` 补写一遍（见「标签」那一节）。
            // 写砸了**不算下载失败**：音频本身是好的，状态照旧 `.downloaded`，
            // 只是 `tagged` 不置位，下次启动的回填还会再试一遍。
            // 大小与音质文案都要等标签写完再取——写完文件长度就变了。
            let lyrics = await lyricsText(for: track)
            let tagged = await Self.writeTags(for: track,
                                              artworkURL: Self.tagArtworkURL(for: track),
                                              lyrics: lyrics,
                                              to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            index[track.id] = Entry(path: relative,
                                    bytes: bytes, date: Date(),
                                    quality: await Self.qualityText(of: destination),
                                    tagged: tagged,
                                    // 写砸了就别留版本号：留着等于声称「已经补到当前版本」，
                                    // 下次启动的回填反而挑不到它。
                                    tagVersion: tagged ? Self.tagWriterVersion : nil)
            states[track.id] = .downloaded(destination)
            saveIndex()
            onDownloaded?(track, destination)
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            states[track.id] = .failed(message)
        }
    }

    /// 进度只在整百分点变化时发一次。`states` 是`@Published`，
    /// 每个数据包发一次等于让整张歌曲表按网卡的节奏重画。
    private func report(_ progress: Double, for id: String) {
        if case .downloading(let old) = state(for: id),
           Int(old * 100) == Int(progress * 100) { return }
        states[id] = .downloading(progress: progress)
    }

    /// 把临时文件搬进「媒体」文件夹，返回落点。扩展名一律按头字节判（见 `fileExtension`）。
    ///
    /// 设置 › 文件 ›「保持"媒体"文件夹有序」开着时按 `艺人/专辑/编号标题.ext` 摆
    /// （Music 的「媒体」文件夹就是这个形状），关着时是扁平的 `<id>.ext`。
    /// **只影响新文件**：改开关不重排已经下好的那些，那会让离线播放的路径全部失效。
    private func place(_ temp: URL, for track: Track) throws -> String {
        let wanted = Self.relativePath(for: track,
                                       ext: Self.fileExtension(of: temp),
                                       organized: settings.values.keepMediaFolderOrganized)
        let base = directory
        let relative = Self.placement(of: wanted, for: track.id, occupied: indexedPaths) {
            FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
        }
        let destination = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 走到这里只剩两种可能：落点是空的，或者它就是这首歌自己上次落的那份（重下盖回去）。
        // 别人的文件在上面那步就让开了，所以这句删不掉不属于自己的东西。
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return relative
    }

    /// 落盘的**相对**路径（索引里存的就是它）。
    ///
    /// 有序时逐段安全化：`艺人/专辑/编号标题.ext`——Music 的「媒体」文件夹就是这个形状，
    /// 一个字符都不多。缺项各有回落：没有艺人/专辑名的用「未知艺人 / 未知专辑」（Music 同名），
    /// 没有音轨号就不写编号。
    ///
    /// **这里不管撞名**，所以它是个纯函数（同样的 `Track` 永远给同一个名字，好测也好复用给
    /// 「文件 › 导入…」）。同名怎么让位交给 `availablePath`：判据要看索引，不该拖进来。
    nonisolated static func relativePath(for track: Track, ext: String, organized: Bool) -> String {
        guard organized else { return safeName(track.id) + "." + ext }
        let artist = safeName(track.artistName.isEmpty ? "未知艺人" : track.artistName)
        let album = safeName(track.albumName.isEmpty ? "未知专辑" : track.albumName)
        let number = track.trackNumber.map { String(format: "%02d ", $0) } ?? ""
        let title = safeName(track.title.isEmpty ? track.id : track.title)
        return "\(artist)/\(album)/\(number)\(title).\(ext)"
    }

    /// 这条曲目该落在哪个相对路径：`wanted` 被**别的**曲目占着就依次让位。
    ///
    /// `occupied` 是索引的一份快照（id → 相对路径）。判据是索引而**不是「文件存在」**：
    /// 同一首歌重下时目标文件当然已经在那儿了，按文件存在判的话每重下一次就多长出一个 ` 1`；
    /// 索引里那条 path 记的就是它自己，那份本来就该被覆盖。
    nonisolated static func placement(of wanted: String, for id: String,
                                      occupied: [String: String],
                                      exists: (String) -> Bool = { _ in false }) -> String {
        let taken = Set(occupied.filter { $0.key != id }.values)
        let mine = occupied[id]
        // 索引不认得、但确实躺在「媒体」文件夹里的文件也要让开：用户自己往里拖过东西，
        // 或者上一版的命名规则留下的孤儿。**只让开别人的**——`mine` 那条是这首歌自己上次
        // 落的地方，重下要盖回去，按「文件存在」判会每下一次多长一个 ` 1`。
        return availablePath(wanted) { candidate in
            taken.contains(candidate) || (candidate != mine && exists(candidate))
        }
    }

    /// 目标名被占就往后找第一个空位：`标题 1.ext`、` 标题 2.ext`……（Finder 拷贝重名、
    /// Music 的「媒体」文件夹都是这个词汇）。同一张碟里两首同名同编号的歌就是这么分开的。
    ///
    /// 「占着」由调用方定义（落地时看索引、迁移那条看索引 + 磁盘），这里只管数数。
    nonisolated static func availablePath(_ relative: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(relative) else { return relative }
        let ext = (relative as NSString).pathExtension
        let stem = (relative as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: - 去掉老文件名里的 id 后缀

    /// 一次性的改名迁移：把有序模式下 `编号标题-1nRaad.ext` 改成` 编号标题.ext`。
    ///
    /// 那截后缀是「同碟同名同编号会撞车」的老解法，用户不要它（Music 的「媒体」文件夹里
    /// 就是 `01 标题.m4a`）。已经下好的那些总不能让他重下一遍，所以启动时原地改名一次
    ///（接线见 `AppState.runLaunchTasksOnce`，要赶在播放开始之前——正在播的文件被改名会断流）。
    ///
    /// 不需要「做过没有」的标记：改完就没有条目再满足 `strippingIDSuffix` 的判据了，
    /// 之后每次启动都是一趟空转。
    func renameLegacySuffixedFiles() {
        let fm = FileManager.default
        // 索引里现有的路径全算被占；这一轮刚改出来的名字也要立刻算进去，
        // 否则两条同碟同名的条目会一起认领同一个新名字。
        var taken = Set(index.values.map(\.path))
        var changed = false
        // 按键排序：同一批里两条撞到同一个新名字时，谁改到手得是稳定的，
        // 不然每次启动改出来的结果都不一样。
        for id in index.keys.sorted() {
            guard let entry = index[id],
                  let fresh = Self.strippingIDSuffix(from: entry.path, id: id),
                  !taken.contains(fresh)
            else { continue }
            let to = directory.appendingPathComponent(fresh)
            // 新名字已经被磁盘上某个文件占着（索引不认得的、用户自己放的）就留着旧名，
            // 什么都不覆盖。
            guard !fm.fileExists(atPath: to.path) else { continue }
            // 改砸了（权限、卷满、文件已经不在了）就保持原样、索引一个字不动：
            // 宁可留个难看的旧名字，也不能让索引指向一个不存在的文件——
            // `loadIndex` 下次启动会把那条清掉，那首歌就凭空变成「没下载」。
            guard (try? fm.moveItem(at: directory.appendingPathComponent(entry.path), to: to)) != nil
            else { continue }
            taken.remove(entry.path)
            taken.insert(fresh)
            var updated = entry
            updated.path = fresh
            index[id] = updated
            // `states` 存的是绝对 URL，跟着换一份，否则界面上那条还指着老名字。
            states[id] = .downloaded(to)
            changed = true
        }
        if changed { saveIndex() }
    }

    /// 摘掉老命名尾巴 `-<id 短后缀>` 之后的相对路径；不是那个形状就返回 nil（＝这条不改）。
    ///
    /// 判据不是「短横线 + 6 位安全字符」这个形状，而是**尾巴正好等于当初生成它的那一段**
    /// （`safeName(id)` 的末 6 位）——那是老`relativePath` 唯一的产法，比看形状紧得多：
    /// 歌名里本来就带短横线的（`Rondo - II.flac`、`Mono-1.flac`）不可能与自己 id 的末 6 位
    /// 相等，不会被误伤。
    ///
    /// 三种一律返回 nil：
    ///
    /// - 外部条目——「导入…」没勾拷贝、留在用户自己目录里的原始文件，Amber 只是引用它，
    ///   改人家的文件名跟往里写标签是同一条线（见 `needsTagBackfill`）；
    /// - `mv:` 开头的键——MV 的落点照旧带后缀（见`mvRelativePath`）；
    /// - 路径里没有 `/` 的——那是扁平模式的`<安全化 id>.ext`，按 id 命名本来就是设计。
    ///   它还正好是最容易被误伤的一种：id 里带短横线时（`qq:1-abcdef`）文件名的尾巴
    ///   天然就等于自己的末 6 位，不挡掉这条就会把整个文件名切成半截 id。
    nonisolated static func strippingIDSuffix(from path: String, id: String) -> String? {
        guard path.contains("/"), !isExternal(path), !id.hasPrefix(mvKey("")) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        let suffix = "-" + String(safeName(id).suffix(6))
        // `stem.count > suffix.count`：整个文件名就是那截后缀时改完会剩个空名字。
        guard !ext.isEmpty, stem.hasSuffix(suffix), stem.count > suffix.count else { return nil }
        return "\(folder)/\(stem.dropLast(suffix.count)).\(ext)"
    }

    // MARK: - 标签

    /// 封面按**全屏播放器**那一档拉（`ArtworkSize.fullPlayer`）。写进文件的那张会被
    /// Finder、Music.app、手机上的播放器反复放大用，宁可大一点；
    /// `ArtworkSize.url` 自己会夹到 CDN 真支持的边长，不会请求出一个 404。
    ///
    /// 单拎出来是因为折算要读 `NSScreen.main` 的像素倍率——那是主线程这一侧的事，
    /// 算好再把字符串交给下面那几个 `nonisolated` 的函数。
    private static func tagArtworkURL(for track: Track) -> String? {
        ArtworkSize.url(track.artworkURL, points: ArtworkSize.fullPlayer)
    }

    /// 按 `Track` 组标签。
    ///
    /// 年份与曲风留空：`Track` 上没有这两项（两家的曲目接口都不给），
    /// 宁可没有也不写一个猜的——写错的年份比没有年份更难发现。
    nonisolated private static func makeTags(for track: Track,
                                             artworkURL: String?,
                                             lyrics: String?) async -> AudioTags {
        var tags = AudioTags()
        tags.title = track.title.isEmpty ? nil : track.title
        tags.artist = track.artistName.isEmpty ? nil : track.artistName
        tags.album = track.albumName.isEmpty ? nil : track.albumName
        // 专辑艺人没有单独的来源，用曲目艺人顶：这一格空着时 Finder / Music.app 会按
        // 每首歌各自的艺人把一张碟拆成好几张。
        tags.albumArtist = tags.artist
        tags.trackNumber = track.trackNumber.flatMap { $0 > 0 ? $0 : nil }
        // 碟号两家的基数不同（见 `Array<Track>.sortedByAlbumOrder`）：QQ 的`index_cd` 从 0 起，
        // 网易的 `cd` 从 1 起。标签里的碟号是 1 起的，QQ 那边要 +1——
        // 2026-09-09 实机下 QQ 的《Emily》原声带（单碟），24 首拿到的 `index_cd` 全是 0，
        // 原样写进去就是一张「第 0 碟」的碟。
        // 注意资料库「光盘编号」那一列显示的仍是音源原值，这条只管写进文件的那一份。
        let disc = track.kind == .qq ? track.discNumber.map { $0 + 1 } : track.discNumber
        tags.discNumber = disc.flatMap { $0 > 0 ? $0 : nil }
        tags.lyrics = lyrics
        if let (data, mime) = await fetchArtwork(artworkURL) {
            tags.artwork = data
            tags.artworkMIME = mime
        }
        return tags
    }

    /// 给刚落地的新文件写标签。返回「真写进去了」（认不出的容器返回 false，不是错）。
    nonisolated private static func writeTags(for track: Track, artworkURL: String?,
                                              lyrics: String?, to url: URL) async -> Bool {
        let tags = await makeTags(for: track, artworkURL: artworkURL, lyrics: lyrics)
        return (try? AudioTagWriter.write(tags, to: url)) ?? false
    }

    /// 问一次歌词，序列化成 LRC 文本（`LyricsLRC.text`：只留正文与译文的行级时间戳）。
    ///
    /// 没接 resolver、这首确认没有词、或者滤完只剩空壳，一律返回 nil ＝ 这一格不写。
    /// 跟封面同一条线：取不到就少写一格，不该让整首歌的标签跟着一起没有。
    ///
    /// 「纯音乐占位词」不在这里滤：两家音源各自的类别位（QQ `lyric_style`、
    /// 网易 `pureMusic`）在取词那一步就把这种歌归成了「没有词」，到这里就是空数组。
    private func lyricsText(for track: Track) async -> String? {
        guard let resolveLyrics else { return nil }
        return LyricsLRC.text(from: await resolveLyrics(track))
    }

    /// 拉封面的**原始字节**。
    ///
    /// 不走 `ImageCache`：那边返回的是解码后的`NSImage`，而四种容器都是把原图整块塞进去，
    /// 从位图再编码一遍等于白掉一次画质、还平白多出几倍体积。
    ///
    /// MIME 先看**魔数**再退回响应头：头字节这一路本来就是这个文件的规矩
    ///（见 `fileExtension(ofHeader:)`），CDN 的`Content-Type` 不一定准。
    /// 两条都认不出 JPEG / PNG 就不写封面——容器里的封面块要声明 MIME，声明错了
    /// 播放器直接不显示，还不如没有。
    ///
    /// 拉不到（断网、404）返回 nil，只写文字标签：封面是锦上添花，
    /// 不该让整首歌的标签跟着一起没有。
    nonisolated private static func fetchArtwork(_ urlString: String?) async -> (Data, String)? {
        guard let urlString, let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              !data.isEmpty
        else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "image/jpeg") }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "image/png") }
        let declared = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let declared, declared == "image/jpeg" || declared == "image/png" else { return nil }
        return (data, declared)
    }

    // MARK: - 给老文件补标签

    /// 正在跑的回填。同一时间只跑一份；测试要等它跑完，所以不是 `private`。
    private(set) var backfillTask: Task<Void, Never>?

    /// 有写入器的四种容器。落地时的扩展名是按**头字节**判的（见 `fileExtension(ofHeader:)`），
    /// 所以拿索引里的路径就能知道这份文件能不能带标签，不必先把它整个复制一份再去试。
    private static let taggableExtensions: Set<String> = ["flac", "ogg", "mp3", "m4a"]

    /// 这条索引要不要补标签。四种一律不碰：
    ///
    /// - 已经补到**当前版本**的（`tagged == true` 且`tagVersion == tagWriterVersion`）——
    ///   再写一遍只是白改一次用户的文件。反过来，`tagged == true` 却没有版本号
    ///   （或版本号更老）的要重排一次：那是写入器升级之前补的，缺新加的那一层。
    ///   版本一升就是**四种容器全部重排**，不按容器细分：升的那一版改了什么、
    ///   波及哪些容器，这条判定并不知道也不该知道；重写一遍是幂等的（写入器都是整块替换，
    ///   而且回填还有备份 + 验收兜底），漏补却是用户自己发现不了的；
    /// - `mv:` 开头的键——那是视频不是曲目（两张表共用一份索引，见`mvKey`）；
    /// - 外部条目——「文件 › 导入…」没勾「拷贝到媒体文件夹」时留在用户自己目录里的
    ///   原始文件，Amber 只是引用它。往里写标签等于替用户改他自己的收藏，
    ///   跟「从资料库移除时不删它」是同一条线；
    /// - 没有写入器的容器（落地成 `.bin` 的那些）——`AudioTagWriter.write` 会返回 false，
    ///   `tagged` 于是永远不置位。不在这里挡掉的话，每次启动都会为它整份复制一次备份
    ///   再原样删掉（见 `retag`），一份都写不成还白搬一遍磁盘。
    nonisolated static func needsTagBackfill(key: String, path: String,
                                             tagged: Bool?, tagVersion: Int?) -> Bool {
        let current = tagged == true && tagVersion == tagWriterVersion
        guard !current, !key.hasPrefix(mvKey("")) else { return false }
        guard taggableExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            return false
        }
        return !isExternal(path)
    }

    /// 把「标签这条路接上之前」下好的那些文件补写一遍。
    ///
    /// 用户手上已有的下载全是裸流，总不能让他重下一遍，所以启动时挑出来补
    ///（接线见 `AppState.runLaunchTasksOnce`）。
    /// 串行 + `.background`：正在下的那两首要用带宽和磁盘，回填是可以慢慢来的活。
    func backfillTags(for tracks: [Track]) {
        guard backfillTask == nil else { return }
        var seen = Set<String>()
        let queue = tracks.filter { track in
            guard seen.insert(track.id).inserted, let entry = index[track.id] else { return false }
            return Self.needsTagBackfill(key: track.id, path: entry.path,
                                         tagged: entry.tagged, tagVersion: entry.tagVersion)
        }
        guard !queue.isEmpty else { return }
        backfillTask = Task(priority: .background) { [weak self] in
            for track in queue {
                guard let self, !Task.isCancelled else { break }
                // 每首都重查一遍索引：这中间用户可能把它删了、或者它刚被重下过一遍。
                guard let entry = self.index[track.id],
                      Self.needsTagBackfill(key: track.id, path: entry.path,
                                            tagged: entry.tagged, tagVersion: entry.tagVersion)
                else { continue }
                let url = self.fileURL(forPath: entry.path)
                // 回填的老文件同样缺词，顺手补上。多这一趟网络往返在串行 + `.background`
                // 的回填里无所谓；问不到就只补文字标签与封面，不能卡住后面那些。
                let lyrics = await self.lyricsText(for: track)
                guard await Self.retag(track, artworkURL: Self.tagArtworkURL(for: track),
                                       lyrics: lyrics, at: url),
                      var fresh = self.index[track.id]
                else { continue }
                fresh.tagged = true
                fresh.tagVersion = Self.tagWriterVersion
                fresh.bytes = Self.fileSize(of: url) ?? fresh.bytes
                self.index[track.id] = fresh
                // 逐首落盘而不是攒到最后：回填可能跑几分钟，中途退出 App 也不该白补。
                self.saveIndex()
            }
            self?.backfillTask = nil
        }
    }

    /// 回填改的是**用户已经有的文件**，比新下载那条路多一层保险：
    /// 先在同目录复制一份备份（同目录才不跨卷，还原就是一次 rename），写完验一眼这份文件
    /// 还能被解码器打开；不通过就整份还原、`tagged` 不置位——留着下次再试，
    /// 也好过把一首本来能播的歌改坏。
    nonisolated private static func retag(_ track: Track, artworkURL: String?,
                                          lyrics: String?, at url: URL) async -> Bool {
        let fm = FileManager.default
        guard let size = fileSize(of: url), size > 0 else { return false }
        // 验收那步对 Ogg 要换判据，而写完之后头字节还是不是 OggS 不好说，先记下来。
        let isOgg = fileExtension(of: url) == "ogg"
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).amtagbak")
        try? fm.removeItem(at: backup)
        guard (try? fm.copyItem(at: url, to: backup)) != nil else { return false }

        let tags = await makeTags(for: track, artworkURL: artworkURL, lyrics: lyrics)
        let written = try? AudioTagWriter.write(tags, to: url)
        if written == false {
            // 认不出的容器：`write` 在分派给写入器之前就返回了，文件一个字节都没动过，
            // 备份直接删掉即可。
            try? fm.removeItem(at: backup)
            return false
        }
        if await verifyTagged(url, isOgg: isOgg, atLeast: size) {
            try? fm.removeItem(at: backup)
            return true
        }
        // 抛错了，或者写出来的文件打不开：把备份换回去，当这一趟没发生过。
        try? fm.removeItem(at: url)
        try? fm.moveItem(at: backup, to: url)
        return false
    }

    /// 写完之后确认这份文件还能被解码器打开——`AVURLAsset` 能解出时长就算过。
    ///
    /// Ogg 是例外：AVFoundation 根本不认这个容器（duration 一律 0），
    /// 只能退回一条弱一点的判据「文件还在、而且没比原来短」。
    /// 回填的都是本来一个标签都没有的文件，写完只会变长；缩了就是写坏了。
    nonisolated private static func verifyTagged(_ url: URL, isOgg: Bool,
                                                 atLeast original: Int) async -> Bool {
        guard let size = fileSize(of: url), size > 0 else { return false }
        if isOgg { return size >= original }
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return false }
        return duration.seconds > 0
    }

    nonisolated private static func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.intValue }
    }

    // MARK: - MV 下载

    /// 由 AppState 注入：按设置 › 播放 ›「视频质量 › 下载」那一档解析 MV 的远端地址。
    var resolveMVURL: ((MV) async throws -> URL)?

    /// 一支 MV 下完（或下砸）的回音，由 AppState 转成 toast。
    var onMVDownloadFinished: ((MV, Result<URL, Error>) -> Void)?

    /// 正在下的 MV。跟曲目那套的排队/并发闸门分开：MV 是用户一支一支点的，
    /// 不像整张碟那样一次几十首，用不着队列。
    private var mvTasks: [String: Task<Void, Never>] = [:]

    /// MV 在 `states` / `index` 里的键。加前缀是为了跟曲目 id 彻底分开——
    /// 两张表共用一份索引（省掉第二套持久化与启动校验），
    /// 但**曲目那条路上的任何逻辑都不会碰到 `mv:` 开头的键**。
    nonisolated static func mvKey(_ mvID: String) -> String { "mv:" + mvID }

    func mvState(for mv: MV) -> DownloadState { state(for: Self.mvKey(mv.id)) }

    /// 已经下好的那份文件；没下过就是 nil（播放器优先用它，见 `AppState.playMV`）。
    func localMVURL(for mv: MV) -> URL? {
        if case .downloaded(let url) = mvState(for: mv) { return url }
        return nil
    }

    /// 下载一支 MV 到「媒体」文件夹的 `MV/` 子目录。已下好或正在下的直接返回。
    func downloadMV(_ mv: MV) {
        let key = Self.mvKey(mv.id)
        guard !isDownloaded(key), mvTasks[key] == nil else { return }
        states[key] = .downloading(progress: 0)
        mvTasks[key] = Task { [weak self] in
            await self?.runMV(mv)
            self?.mvTasks[key] = nil
        }
    }

    /// 删掉本地那份 MV（正在下的先取消）。
    func removeMVDownload(_ mv: MV) {
        let key = Self.mvKey(mv.id)
        mvTasks[key]?.cancel()
        mvTasks[key] = nil
        if let entry = index[key] {
            try? FileManager.default.removeItem(at: fileURL(forPath: entry.path))
            index[key] = nil
        }
        states.removeValue(forKey: key)
        saveIndex()
    }

    private func runMV(_ mv: MV) async {
        let key = Self.mvKey(mv.id)
        do {
            guard let resolveMVURL else { throw ProviderError.api("下载未初始化") }
            let remote = try await resolveMVURL(mv)
            let temp = try await Downloader.fetch(remote) { [weak self] progress in
                Task { @MainActor [weak self] in self?.report(progress, for: key) }
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            let relative = Self.mvRelativePath(for: mv)
            let destination = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            index[key] = Entry(path: relative,
                               bytes: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                               date: Date(), quality: nil)
            states[key] = .downloaded(destination)
            saveIndex()
            onMVDownloadFinished?(mv, .success(destination))
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            states[key] = .failed(message)
            onMVDownloadFinished?(mv, .failure(error))
        }
    }

    /// MV 的落点：`MV/<安全化的标题>-<id 尾 6 位>.mp4`（相对「媒体」文件夹）。
    ///
    /// 不跟「保持有序」那套走：MV 不属于任何一张专辑，摆进 `艺人/专辑/` 无处可放，
    /// Music 也是把视频单独归一类。扩展名写死 `mp4` 而不是像音频那样按头字节判——
    /// 两家给的都是 mp4 容器（QQ `format=264`、网易 vod），而头字节判容器那张表
    /// 会把 `ftyp` 一律说成`m4a`（那是音频扩展名）。
    /// 末尾照旧带 id 短后缀（曲目那边已经不带了）：同名 MV（现场版/录音室版）不会互相覆盖，
    /// 而 MV 的文件名用户基本不看——曲目那边去掉后缀是因为它出现在「媒体」文件夹里，
    /// 用户天天对着它。
    nonisolated static func mvRelativePath(for mv: MV) -> String {
        let title = safeName(mv.title.isEmpty ? mv.id : mv.title)
        let suffix = String(safeName(mv.id).suffix(6))
        return "MV/\(title)-\(suffix).mp4"
    }

    // MARK: - 换「媒体」文件夹

    /// 首次启动的搬家：这条设置接线之前下载落在 Application Support 下，
    /// 新目录还没索引、老目录有，就整份搬过来一次。搬不动就继续用老目录——
    /// 宁可媒体文件夹与设置不一致，也不能让已下好的歌凭空「消失」。
    private func adoptLegacyIfNeeded(from legacy: URL) {
        let fm = FileManager.default
        guard legacy.standardizedFileURL != directory.standardizedFileURL,
              !fm.fileExists(atPath: indexURL.path),
              fm.fileExists(atPath: legacy.appendingPathComponent("index.json").path)
        else { return }
        // 先把老目录的索引读进来，`moveContents` 才知道该搬哪几个文件；
        // 搬完（或搬砸）都清空，紧接着的 `loadIndex` 会按最终的`directory` 重新读一遍。
        index = Self.decodeIndex(at: legacy.appendingPathComponent("index.json"))
        do {
            try moveContents(from: legacy, to: directory)
        } catch {
            directory = legacy
        }
        index = [:]
    }

    /// 用户在设置里改了「媒体」文件夹：把已下好的整份搬过去。
    ///
    /// 失败就**留在原地**（`moveContents` 自己回滚已搬的那几个），索引与状态一个不动，
    /// 只报一句——半搬不搬的目录比没搬更难收拾。
    private func migrate(to newDirectory: URL) {
        guard newDirectory.standardizedFileURL != directory.standardizedFileURL else { return }
        let count = index.count
        do {
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            try moveContents(from: directory, to: newDirectory)
        } catch {
            onMediaFolderChanged?("「媒体」文件夹没能搬过去：\(error.localizedDescription)")
            return
        }
        directory = newDirectory
        // 路径是相对的，搬完照旧成立；但 `states` 里存的是绝对 URL，要按新目录重发一遍。
        // 外部条目（原地引用的导入文件）本来就没搬，按它自己的绝对路径重发。
        states = index.mapValues { .downloaded(self.fileURL(forPath: $0.path)) }
        saveIndex()
        if count > 0 { onMediaFolderChanged?("已把 \(count) 首下载移到新的「媒体」文件夹") }
    }

    /// 按索引逐条搬文件（连同它的子目录），再搬 index.json。
    /// 中途失败把已经搬过去的搬回来，让源目录回到调用前的样子。
    private func moveContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var moved: [String] = []
        do {
            // 外部条目（原地引用的导入文件）不归「媒体」文件夹管，不参与搬家。
            for path in index.values.map(\.path) where !Self.isExternal(path) {
                let from = source.appendingPathComponent(path)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = destination.appendingPathComponent(path)
                try fm.createDirectory(at: to.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: from, to: to)
                moved.append(path)
            }
        } catch {
            for path in moved {
                try? fm.moveItem(at: destination.appendingPathComponent(path),
                                 to: source.appendingPathComponent(path))
            }
            throw error
        }
        let sourceIndex = source.appendingPathComponent("index.json")
        if fm.fileExists(atPath: sourceIndex.path) {
            try? fm.removeItem(at: destination.appendingPathComponent("index.json"))
            try? fm.moveItem(at: sourceIndex, to: destination.appendingPathComponent("index.json"))
        }
    }

    /// 曲目 id 形如 `qq:0039MnYb0qxYhV`，冒号在路径里能用但在别的地方（NSURL 的 scheme
    /// 解析、命令行）容易被当分隔符，统一换成下划线；别的可疑字符一并换掉。
    nonisolated static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return String(String.UnicodeScalarView(id.unicodeScalars.map {
            allowed.contains($0) ? $0 : "_"
        }))
    }

    /// 按**头字节**判容器，不看 URL 上的扩展名：QQ 的 purl 带的扩展名是档位码约定的，
    /// 降级取到别的容器时那个名字就是错的，而 AVPlayer 认扩展名。
    ///
    /// **这条只管落地命名**，跟 `AudioTagWriter.write` 的分派**故意不一致**，别去对齐：
    /// 这里看到的是刚下完的裸流，那时还没有任何 ID3 前缀，`ID3` 打头就是 mp3；
    /// 而分派器面对的可能是用户手上、别的工具处理过的文件——为了让 Finder 显示封面，
    /// Mp3tag 那类工具会给 FLAC 前面加一块 ID3，它必须先跳过那一块再看真魔数。
    /// 何况这条手里只有头十几个字节、没有文件句柄，本来也跳不过去。
    nonisolated static func fileExtension(ofHeader head: [UInt8]) -> String {
        func matches(_ ascii: String, at offset: Int) -> Bool {
            let bytes = Array(ascii.utf8)
            guard head.count >= offset + bytes.count else { return false }
            return Array(head[offset..<(offset + bytes.count)]) == bytes
        }
        if matches("fLaC", at: 0) { return "flac" }
        if matches("OggS", at: 0) { return "ogg" }
        if matches("ID3", at: 0) { return "mp3" }
        // MPEG 帧同步：11 位全 1。裸 MP3 不一定带 ID3 头。
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 { return "mp3" }
        // ISO BMFF：前 4 字节是 box 长度，第 5-8 字节才是 'ftyp'（m4a / mp4 / E-AC-3 都在这里）
        if matches("ftyp", at: 4) { return "m4a" }
        return "bin"
    }

    nonisolated private static func fileExtension(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "bin" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        return fileExtension(ofHeader: [UInt8](head))
    }

    /// 落地后从文件本身读真实规格，复用音质气泡那套文案（`StreamFormat`）。
    /// 读不出来就不写这一项——宁可留空，也不写一个猜的档位。
    private static func qualityText(of url: URL) async -> String? {
        guard let format = await StreamFormat.read(from: AVPlayerItem(url: url)) else { return nil }
        return "\(format.tierName) · \(format.detail)"
    }

    // MARK: - 索引持久化

    /// 启动时校验文件还在，不在就把那条清掉——用户在 Finder 里删过、或者换过盘。
    private func loadIndex() {
        let stored = Self.decodeIndex(at: indexURL)
        guard !stored.isEmpty else { return }
        var alive: [String: Entry] = [:]
        var restored: [String: DownloadState] = [:]
        for (id, entry) in stored {
            let url = fileURL(forPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            alive[id] = entry
            restored[id] = .downloaded(url)
        }
        index = alive
        states = restored
        if alive.count != stored.count { saveIndex() }
    }

    private static func decodeIndex(at url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return stored
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - 取字节

/// `URLSession.downloadTask` 的 async 封装。
///
/// 用不了 `URLSession.shared.download(from:)`：那条 async API 不报进度。
/// 走 delegate 版拿 `didWriteData`，落到磁盘的临时文件由调用方负责搬走。
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    /// `finishTasksAndInvalidate` 之前 URLSession 强引用 delegate，
    /// 所以 await 期间这个对象一直活着，不用自己持有自己。
    private var task: URLSessionDownloadTask?

    static func fetch(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let downloader = Downloader()
        downloader.onProgress = onProgress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                let session = URLSession(configuration: .default,
                                         delegate: downloader, delegateQueue: nil)
                downloader.task = session.downloadTask(with: url)
                downloader.task?.resume()
                // 会话不再收新任务后自己收摊，否则每下一首漏一条会话。
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            downloader.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // HTTP 错误**不算** URLSession 的错误：403 / 404 照样走这条回调，
        // 「下载」到的是一段错误正文。不看状态码的话它会被当成音频存进资料库。
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(.failure(ProviderError.api("下载失败（HTTP \(response.statusCode)）")))
            return
        }
        // 回调一返回系统就删掉 location，必须在这里先搬到自己的临时文件。
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            finish(.success(temp))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 成功那一支已经在 didFinishDownloadingTo 里回过了，finish 自带一次性保护。
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
