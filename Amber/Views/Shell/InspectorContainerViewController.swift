import AppKit

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
    /// 歌词那一档也是真的控制器了：`InspectorLyricsViewController` 直接持有
    /// `SyncedLyricsViewController` 当子控制器（计划 §1.3），中间那层
    /// `NSViewControllerRepresentable` 没了——AGENTS.md 界面层铁律 1。
    let lyrics: InspectorLyricsViewController

    private let appState: AppState

    /// [实测] §1.1：`mode` **0 = 歌词、1 = 队列**；§1.5：没有显式赋值 →
    /// **默认站在歌词**。这里的 `mode` 是容器实例自己的字段（一扇窗一份），
    /// 是**视图层的当前画面**——哪一档由宿主推进来（主窗是 `MainSplitViewController`、
    /// 迷你窗是 `MiniPlayerContentView` 的形态机），宿主读的是全局那一份
    /// `AppState.inspectorMode`。容器自己不订阅 `inspectorMode`：
    /// 迷你窗那台的档位是从 `currState` 的跳表里出来的，容器绕过宿主自己换档
    /// 会与那台形态机打架。
    private(set) var mode: PlayerInspector

    /// [实测] inspector 规格 §4.2：整窗播放器那份容器打开**沉浸档**
    /// （`MPContentView.inspectorIsImmersionMode:` 是唯一写入点，didSet 把它传给歌词控制器——
    /// `isImmersionMode` 与 `isMiniPlayerMode` 是同一个开关的正反面）。
    ///
    /// Amber 这边一台容器从生到死只归一个宿主，所以做成 `let`：主窗与迷你窗恒 false，
    /// 整窗播放器那台建的时候就传 true。歌词面板按它选字号档与基线
    /// （侧栏 24pt、视口高 0.381 vs 整窗四档字号 + 基线对齐封面中心）。
    ///
    /// §4.2 另记了一条：Music 那条 didSet 传导**只对旧壳 `TSLLyricsControllerWrapper`
    /// 生效**（`swift_dynamicCastObjCClass` 判型，新实现`LyricsXViewController`
    /// 判型失败直接 return），所以沉浸模式这条线在 Music 的新旧两套歌词实现之间
    /// 不对称，spec 标 `[部分]`。Amber 只有一套歌词实现，不存在这个分叉。
    /// 反面那一位 `isMiniPlayerMode` 也不另存——凡是「非沉浸」的分支就是它。
    let isImmersionMode: Bool

    init(appState: AppState, immersion: Bool = false) {
        self.appState = appState
        self.isImmersionMode = immersion
        self.queue = PlayQueueViewController(appState: appState)
        self.lyrics = InspectorLyricsViewController(appState: appState, immersion: immersion)
        // 起手就站在全局那一档：面板收起期间档位也记着，新建的容器（比如迷你窗那台）
        // 不该一律从歌词开始。
        self.mode = appState.inspectorMode
        super.init(nibName: nil, bundle: nil)
        // [实测] §1.5：两个都 `addChildViewController`。
        addChild(queue)
        addChild(lyrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 面板是不是**真的在跟随**（[TYPE] `LyricsOptions.isActive`）。
    ///
    /// 只有整窗播放器那台宿主要推这一位：它是**常驻 + 位移**的（收起时整块挪到窗外
    /// + alpha 0），既不走 `viewWillDisappear` 也不走`viewDidHide()`，
    /// 歌词的每帧驱动得靠这一位停。主窗与迷你窗都不用碰——那两处收面板走的是
    /// 上面两条通路，歌词控制器自己就停了（见 `InspectorLyricsViewController.syncVisibility()`）。
    var isActive: Bool {
        get { lyrics.isActive }
        set { lyrics.isActive = newValue }
    }

    /// [实测] §1.2：`includeBackdrop` 决定根视图是毛玻璃还是素面。
    /// **主窗这条路 `includeBackdrop = false`**（两个 init 都以`w0 = 0` 调指定初始化器），
    /// 所以根视图是素面 `NSView`，背景由宿主给——Amber 这边是窗口根那层玻璃
    ///（见 `RootViewController`），与 Music 同构。
    /// **§4 实读：两处创建点都传 false**——整窗播放器那份的玻璃不来自这里，
    /// 而是宿主把本容器套进一层玻璃（Music 是 `AMPVibrantContainerView`，
    /// Amber 是整窗播放器容器给的 platter 玻璃）。所以 `includeBackdrop` 这一路
    /// 没有已知调用方，不实现。
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
