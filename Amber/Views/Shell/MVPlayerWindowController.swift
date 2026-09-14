import AVKit
import AppKit
import Combine

/// App 内的 MV 播放窗。
///
/// 骨架照 §2 铁律 1：纯 AppKit + `AVKit.AVPlayerView`，不套 `NSViewRepresentable`。
/// `AVPlayerView` 自带整套播放控制（进度条、音量、全屏、画中画），`controlsStyle = .floating`
/// 是 QuickTime / Music 那种「浮在画面上、鼠标移开自动淡出」的样子——系统本来就对，
/// 不自己画一套。
///
/// 一扇窗复用：再点一支 MV 就换 item、改标题，不新开窗（Music 的视频窗也是一扇）。
/// 音乐播放器与它是两套 `AVPlayer`，媒体键/`MPRemoteCommandCenter` 仍归音乐那套，
/// 这里只在开播时把音乐按停（见 `AppState.playMV`），不接管远程控制。
@MainActor
final class MVPlayerWindowController: NSWindowController, NSWindowDelegate {

    /// 16:9 的默认内容尺寸。没有存档时按它开窗，之后由 `setFrameAutosaveName` 记住。
    private static let defaultContentSize = NSSize(width: 960, height: 540)
    private static let frameAutosaveName = "AmberMVPlayerWindow"

    private let videoPlayer = AVPlayer()
    private let playerView = AVPlayerView()
    private var cancellables = Set<AnyCancellable>()

    /// 当前这扇窗在播的 MV（重复点同一支时不必重新取流）。
    private(set) var currentMV: MV?

    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // 画面是 16:9 的，让窗口自己保持比例，免得拖出上下两条黑边
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 480, height: 270)
        super.init(window: nil)
        self.window = window
        window.delegate = self

        playerView.player = videoPlayer
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        playerView.allowsPictureInPicturePlayback = true
        window.contentView = playerView

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // 设置 › 高级 ›「在其他所有窗口前端播放视频」。订阅而不是开窗时读一次：
        // 用户在设置窗里一按「好」这扇窗就该跟着变，不用关掉重开。
        AppSettings.shared.$values
            .map(\.videoOnTop)
            .removeDuplicates()
            .sink { [weak window] onTop in window?.level = onTop ? .floating : .normal }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换片并开播。`url` 由调用方按设置里的画质档解析好（本地下载过的就是 file URL）。
    func play(_ mv: MV, url: URL) {
        currentMV = mv
        window?.title = Self.windowTitle(for: mv)
        videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        videoPlayer.play()
    }

    /// 关窗 = 停播并把 item 卸掉：留着 item 的话窗口关了声音还在响。
    func stop() {
        videoPlayer.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        currentMV = nil
    }

    /// 「标题 — 艺人」；没有艺人（访谈那种）就只有标题。
    static func windowTitle(for mv: MV) -> String {
        let title = mv.title.isEmpty ? "MV" : mv.title
        return mv.artistName.isEmpty ? title : "\(title) — \(mv.artistName)"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stop()
    }
}
