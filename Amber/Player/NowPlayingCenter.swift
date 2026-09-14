import AppKit
import MediaPlayer
import UserNotifications

/// 系统 Now Playing 集成：控制中心、媒体键、Touch Bar。
///
/// 顺带管「通知 › 歌曲更改时」（设置 › 通用）：这里本来就盯着当前曲目，
/// 换歌的判定和元数据都是现成的，不必再找一处监听。
final class NowPlayingCenter {

    static let shared = NowPlayingCenter()

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private weak var player: PlayerController?
    /// 已写入 nowPlayingInfo 的曲目，用于检测切歌（切歌必须重建元数据，否则控制中心一直显示旧标题）
    private var lastTrackID: String?
    /// 已发过换歌通知的曲目。与 `lastTrackID` 分开记：那个在停止播放时会清空，
    /// 清空后接着播同一首就会再发一条，而「同一首歌不发第二条」得跨停止/续播成立。
    private var notifiedTrackID: String?

    /// 换歌通知固定用这个标识符：`add` 遇到同标识符会替换掉已送达的那条，
    /// 连着切几首不至于在通知中心堆一屏。
    private static let songChangeNotificationID = "com.changlepan.Amber.songChange"

    private init() {}

    func configure(player: PlayerController) {
        self.player = player

        // 回调由系统在任意线程投递（媒体键走的不是主线程），不能用 assumeIsolated 赌它是主线程，
        // 赌错直接 fatalError。统一跳一次主线程再动 player。
        commands.playCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor in player?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in player?.seek(to: position) }
            return .success
        }
    }

    func update(track: Track?, artwork: NSImage?, position: TimeInterval, duration: TimeInterval, rate: Double) {
        guard let track else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            lastTrackID = nil
            return
        }
        if track.id != lastTrackID {
            // 新曲目：重建完整信息
            lastTrackID = track.id
            postSongChangeNotificationIfNeeded(track: track, artwork: artwork)
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyArtist: track.artistName,
                MPMediaItemPropertyAlbumTitle: track.albumName,
                MPMediaItemPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if let artwork {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }
            infoCenter.nowPlayingInfo = info
        } else if let artwork, infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
            // 封面晚到时补上
            infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        infoCenter.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = duration
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
        // macOS 上必须显式维护 playbackState，否则控制中心/菜单栏的播放状态不跟手
        infoCenter.playbackState = rate > 0 ? .playing : .paused
    }
}

// MARK: - 通知 › 歌曲更改时

extension NowPlayingCenter {

    /// 设置窗把「通知 › 歌曲更改时」勾上的那一刻调这个去要授权。
    ///
    /// 只在系统还没问过（`notDetermined`）时才 request：用户拒绝过之后再 request
    /// 也弹不出面板，只会在每次勾选时白跑一趟。要改主意得去系统设置里改，这点和 Music.app 一致。
    @MainActor
    func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        // 不要 .sound：换歌是背景事件，Music.app 也只出横幅不出声
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    /// 换歌时发一条本地通知。开关关着、或这首已经通知过，就什么都不做。
    ///
    /// 同步这一段只做去重标记，剩下的（读偏好、判前台、取封面、投递）都在主线程的 Task 里做：
    /// 偏好与 `NSApp` 都是主线程的东西，封面还可能要等下载。
    private func postSongChangeNotificationIfNeeded(track: Track, artwork: NSImage?) {
        guard notifiedTrackID != track.id else { return }
        notifiedTrackID = track.id
        Task { @MainActor in
            guard AppSettings.shared.values.notifyOnSongChange else { return }
            // 前台不打扰：macOS 默认就不展示前台通知，显式判一次，免得哪天默认变了才发现
            guard !NSApp.isActive else { return }

            let content = UNMutableNotificationContent()
            content.title = track.title
            // 第二行给「艺人 — 专辑」。搜索来的曲目常常没有专辑节点，
            // 这时只留艺人，别拼出一个悬着的破折号。
            content.body = [track.artistName, track.albumName]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            if let attachment = await Self.artworkAttachment(track: track, artwork: artwork) {
                content.attachments = [attachment]
            }
            // trigger 为 nil＝立即投递
            let request = UNNotificationRequest(
                identifier: Self.songChangeNotificationID, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// 封面附件。`UNNotificationAttachment` 只收本地文件，所以要把图落成一张临时 PNG
    /// （系统会把这个文件搬进它自己的存储区，不用我们再清）。
    ///
    /// 换歌那一刻封面多半还没到（`PlayerController` 是异步取的），所以补问一次 `ImageCache`——
    /// 它与播放器那次下载共用同一个在途请求，不会多下一张。但最多等一秒：
    /// 一条「换歌了」的通知晚到就没意义了，拿不到就不带附件照发。
    private static func artworkAttachment(track: Track, artwork: NSImage?) async -> UNNotificationAttachment? {
        var image = artwork
        if image == nil {
            image = await withTaskGroup(of: NSImage?.self) { group in
                group.addTask { await ImageCache.shared.image(for: track.artworkURL) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(1))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberSongChange-\(UUID().uuidString).png")
        do {
            try png.write(to: file, options: .atomic)
            return try UNNotificationAttachment(identifier: "artwork", url: file, options: nil)
        } catch {
            // 建附件失败时文件还留在临时目录里，自己收掉
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }
}
