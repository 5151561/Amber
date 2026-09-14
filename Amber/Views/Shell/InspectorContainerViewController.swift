import AppKit
import SwiftUI

/// 主窗右侧检查器列的容器（Music 的 `MusicInspectorContainer`）。
///
/// 规格：inspector 规格 §1。
///
/// 换掉原先那个「一台 `NSHostingController<AnyView>` 靠换`rootView` 切档」的做法：
/// Music 这一层是**真正的容器控制器**——两个面板控制器在 `init` 里就建好并`addChild`，
/// 切档是把新面板插在旧面板底下做交叉淡入（§1.4），不是抽换内容。
/// 好处不只是同构：待播清单换成 AppKit 之后它是个有滚动位置、有选区、有定时器的
/// `NSViewController`，抽换`rootView` 那条路根本装不下它。
@MainActor
final class InspectorContainerViewController: NSViewController {

    /// [实测] §1.5：两个面板都是**启动即建**。
    let queue: PlayQueueViewController
    /// 歌词那一档这一轮不动，仍是 SwiftUI 叶子——它没有滚动容器里的 cell，
    /// 是计划 §2 铁律 2 认可的「叶子」形态（`SyncedLyricsView` 内部本来就是 AppKit + CALayer）。
    let lyrics: NSHostingController<AnyView>

    private let appState: AppState

    /// [实测] §1.1：`mode` **0 = 歌词、1 = 队列**；§1.5：没有显式赋值 →
    /// **默认站在歌词**。这里的 `mode` 是容器实例自己的字段（一扇窗一份），
    /// 与全局 `AppState.playerInspector`（nil = 收起）不是一回事：
    /// 面板收起期间容器仍记着上一次的档位。
    private(set) var mode: PlayerInspector = .lyrics

    init(appState: AppState) {
        self.appState = appState
        self.queue = PlayQueueViewController(appState: appState)
        self.lyrics = appState.hostingController {
            InspectorLyricsView()
        }
        super.init(nibName: nil, bundle: nil)
        // [实测] §1.5：两个都 `addChildViewController`。
        addChild(queue)
        addChild(lyrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// [实测] §1.2：`includeBackdrop` 决定根视图是毛玻璃还是素面。
    /// **主窗这条路 `includeBackdrop = false`**（两个 init 都以`w0 = 0` 调指定初始化器），
    /// 所以根视图是素面 `NSView`，背景由宿主给——Amber 这边是窗口根那层玻璃
    ///（见 `RootViewController`），与 Music 同构。传 true 的调用方在全屏播放器侧，
    /// Amber 还没有那一路。
    override func loadView() {
        let root = NSView()
        view = root
        install(panel(for: mode))
    }

    private func panel(for mode: PlayerInspector) -> NSView {
        switch mode {
        case .lyrics: return lyrics.view
        case .queue: return queue.view
        }
    }

    private func install(_ panel: NSView) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// [实测] §1.4 `mode` 的 didSet：**交叉淡入，不是抽换**。
    ///
    /// - 新面板插在旧面板**底下**（`positioned: .below`），靠 alpha 过渡，不做位移/推挤；
    /// - 动画时长 Music 没有显式设置，用 `NSAnimationContext` 的默认（spec 标`[推]`）；
    /// - completion 里那句「旧视图 alpha 复位 1」是为了视图复用——面板控制器是常驻的，
    ///   下次装回来不能带着 alpha 0；
    /// - completion 会**重新核对 mode**，快速连点两次不会把新面板误删。
    func setMode(_ newMode: PlayerInspector, animated: Bool) {
        guard isViewLoaded else { mode = newMode; return }
        guard newMode != mode else { return }
        mode = newMode

        let old = view.subviews.first
        let new = panel(for: newMode)
        install(new)

        guard animated else {
            old?.removeFromSuperview()
            return
        }

        new.alphaValue = 0
        view.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { _ in
            old?.animator().alphaValue = 0
            new.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            // completion 是 `@Sendable` 的，但`NSAnimationContext` 一定在主线程回调。
            MainActor.assumeIsolated {
                guard let self, self.mode == newMode else { return }
                old?.alphaValue = 1
                old?.removeFromSuperview()
            }
        }
    }
}
