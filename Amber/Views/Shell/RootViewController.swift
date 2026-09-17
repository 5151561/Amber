import AppKit
import Combine
import SwiftUI

/// 窗口根。三件事：铺那层玻璃、把分栏/迷你播放器/整窗播放器/toast/艺人简介面板叠起来、
/// 收 Esc 与改名弹窗。
///
/// **玻璃是窗口根给的**：`NSVisualEffectView(material: .contentBackground)` 铺满整窗，
/// 侧栏、面板、内容都靠它，自己什么都不画（见 SidebarOutline.swift 里的实测注释：
/// 侧栏自己糊 `.sidebar` / `.behindWindow` 材质会渲染成恒定浅灰 #4E4D4B，
/// 而侧栏该是 #2A2B2C）。
///
/// 视图树里能看到**两个** `[0,0,1440,900] material=18 blend=1` 的 `NSVisualEffectView`，
/// 那不是我们建重了，也不是嵌套——是 `NSThemeFrame` 下的两个**同级**子视图：
/// 上面那个是本控制器的 view，下面那个是 **AppKit 自己铺的窗口背景层**。
/// [实测 2026-09-05，独立探针] 同样的窗口形态（`fullSizeContentView` + 透明标题栏 +
/// unified 工具栏），把 `contentViewController` 换成一个 view 是**普通 `NSView`** 的控制器，
/// `NSThemeFrame` 下照样有那一层 `NSVisualEffectView material=18 blend=1`。
/// 系统给的那层别动；我们这层留着是因为它同时给子视图提供 vibrancy 落点。
@MainActor
final class RootViewController: NSViewController, AboutPanelPresenting {

    private let appState: AppState
    let splitViewController: MainSplitViewController
    private let nowPlayingController: NowPlayingContainerViewController
    private var miniPlayer: NSView?
    private let toast = ToastView()
    private var cancellables = Set<AnyCancellable>()
    private let observers = TaskBag()
    private var nameAlertShown = false

    init(appState: AppState) {
        self.appState = appState
        self.splitViewController = MainSplitViewController(appState: appState)
        self.nowPlayingController = NowPlayingContainerViewController(appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        // `.followsWindowActiveState` 会让窗口失焦时整层材质变淡，Music 不是这样。
        effect.state = .active
        view = effect
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(splitViewController)
        let split = splitViewController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: view.topAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        installMiniPlayer()

        // 整窗播放器常驻、盖在最上面（收起时被整体位移到窗口下沿之外）。
        addChild(nowPlayingController)
        view.addSubview(nowPlayingController.view)
        nowPlayingController.setPresented(appState.showingNowPlaying, animated: false)

        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.isHidden = true
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // [PX] 旧 SwiftUI 版是 `.padding(.top, 44)`，位置一个不改。
            toast.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
        ])

        observers.observe({ [appState] in appState.toastMessage }) { [weak self] message in
            self?.toast.show(message)
        }

        observers.observe({ [appState] in appState.showingNowPlaying }) { [weak self] presented in
            self?.nowPlayingController.setPresented(presented, animated: true)
        }

        // 播放列表命名（改名 / 新建）：侧栏行、网格卡、详情页头、⌘N 都只登记意图，
        // 弹窗统一在这里。旧版是 MainView 上的 `.alert`（挂在菜单里弹不出来——
        // 菜单一关那棵子树就没了）。
        observers.observe({ [appState] in appState.playlistNamePrompt }) { [weak self] prompt in
            guard let self, let prompt else { return }
            self.presentPlaylistNameAlert(prompt)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        nowPlayingController.layoutInHost(bounds: view.bounds)
    }

    // MARK: - 迷你播放器

    /// 胶囊挂在窗口根上、盖在分栏之上，按内容列定位。
    ///
    /// 旧版用 `anchorPreference` + `overlayPreferenceValue` + `GeometryReader` 算位置，
    /// 还要 `.animation(nil)` 把外层漏进来的事务按住；换成约束之后位置天然跟着
    /// 内容列走（改窗宽、开合面板都是布局的事，不再经过一轮 SwiftUI 失效传播）。
    ///
    /// [AX] Music 首页：胶囊 `[486.5, 883, 700, 54]`，内容列 202.5…1470 的中线是
    /// 836.25，胶囊中线 836.5——就是按内容列居中的；距窗底 19（= bottomMargin）。
    private func installMiniPlayer() {
        // 阶段 2 起这是纯 AppKit 的 `MiniPlayerView: NSView`，不再是 SwiftUI 叶子；
        // 胶囊自己按 `intrinsicContentSize` 报 700×54，窄窗口由下面那条 ≤ 不等式压住。
        let host = MiniPlayerView(appState: appState)
        view.addSubview(host)
        miniPlayer = host

        let content = splitViewController.navigationController.view
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                         constant: -MusicMetrics.MiniPlayer.bottomMargin),
            // 窄窗口时封顶，别顶到内容列外面去。
            host.widthAnchor.constraint(
                lessThanOrEqualTo: content.widthAnchor,
                constant: -MusicMetrics.MiniPlayer.horizontalMargin * 2),
        ])
    }

    // MARK: - 介绍面板

    /// 艺人页 hero 上那枚 ⓘ、专辑页头与歌单页头简介末行的「更多」点开的那张卡
    /// （`AboutPanel.swift`）。
    /// 挂在窗口根上、盖在所有东西之上，与迷你播放器/整窗播放器/toast 同一套做法。
    /// 面板本身是 AppKit 覆盖层而不是 sheet，理由写在 `AboutPanelOverlayView` 的注释里。
    private var aboutOverlay: AboutPanelOverlayView?

    func presentAboutPanel(_ content: AboutContent) {
        dismissAboutPanel(animated: false)
        let overlay = AboutPanelOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.panel.apply(content)
        overlay.onDismiss = { [weak self] in self?.dismissAboutPanel(animated: true) }
        view.addSubview(overlay)   // 最后加 = 盖在最上面
        aboutOverlay = overlay
        fade(overlay, to: 1, from: 0, animated: true, completion: nil)
    }

    private func dismissAboutPanel(animated: Bool) {
        guard let overlay = aboutOverlay else { return }
        aboutOverlay = nil
        fade(overlay, to: 0, from: nil, animated: animated) { overlay.removeFromSuperview() }
    }

    /// [HIG] 开了「减弱动态效果」就直切（与 `ToastView.fade` 同一条）。
    private func fade(_ view: NSView, to alpha: CGFloat, from: CGFloat?,
                      animated: Bool, completion: (() -> Void)?) {
        if let from { view.alphaValue = from }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = alpha
            completion?()
            return
        }
        // 完成回调的类型是 `@Sendable`，而收尾闭包是调用方给的普通（非 Sendable）闭包。
        // `NSAnimationContext` 保证回调在主线程，这一条按不检查处理。
        nonisolated(unsafe) let finish = completion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = alpha
        } completionHandler: {
            finish?()
        }
    }

    // MARK: - Esc

    /// 「播放中」用 Esc 收起。响应链原生就有这条（`cancelOperation(_:)`），
    /// 旧版要在 NowPlayingView 里挂一颗零尺寸隐形按钮才收得到 Esc。
    override func cancelOperation(_ sender: Any?) {
        // 介绍面板压在最上面，Esc 先关它。
        if aboutOverlay != nil {
            dismissAboutPanel(animated: true)
            return
        }
        if appState.showingNowPlaying {
            appState.showingNowPlaying = false
            return
        }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    // MARK: - 命名（改名 / 新建）

    /// 改名与新建共用这一个 sheet，区别只在标题、确认键的字，以及**确认之后干什么**。
    ///
    /// 新建这一路的列表是在这里才建出来的：从前是先建再弹这个框，于是「取消」按下去
    /// 库里已经多了一份空列表（[实机打回 2026-09-08]），见 `AppState.promptNewPlaylist`。
    private func presentPlaylistNameAlert(_ prompt: PlaylistNamePrompt) {
        guard !nameAlertShown, let window = view.window else { return }
        nameAlertShown = true
        let library = appState.library
        let alert = NSAlert()
        let initialName: String
        switch prompt {
        case .rename(let playlistID):
            alert.messageText = "重命名播放列表"
            alert.addButton(withTitle: "完成")
            initialName = library.playlist(id: playlistID)?.name ?? ""
        case .create:
            alert.messageText = "新建播放列表"
            alert.addButton(withTitle: "创建")
            // 预填默认名（「新建播放列表」/ 重名时补序号），成为第一响应者时整段选中，
            // 直接打字就是替换掉它。
            initialName = library.defaultNewPlaylistName()
        }
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: initialName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                switch prompt {
                case .rename(let playlistID):
                    library.renamePlaylist(id: playlistID, to: field.stringValue)
                case .create(let tracks):
                    self.appState.commitNewPlaylist(name: field.stringValue, tracks: tracks)
                }
            }
            self.nameAlertShown = false
            self.appState.playlistNamePrompt = nil
        }
    }
}

// MARK: - toast

/// 顶部提示胶囊。直接 AppKit：一层玻璃 + 一行文字，淡入淡出。
/// [PX] 与旧 SwiftUI 版同形（`.regularMaterial` 胶囊、callout 字号、左右 16 上下 10）。
private final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // 胶囊：圆角取高度的一半。
        layer?.cornerRadius = bounds.height / 2
        layer?.masksToBounds = true
    }

    func show(_ message: String?) {
        hideWorkItem?.cancel()
        guard let message, !message.isEmpty else {
            fade(to: 0) { [weak self] in self?.isHidden = true }
            return
        }
        label.stringValue = message
        isHidden = false
        fade(to: 1, completion: nil)
    }

    /// [HIG] 开了「减弱动态效果」就直切：淡入淡出压短了仍是一次动效，
    /// Apple 在 *Adopting Liquid Glass* 里要求自绘动效自己按这项偏好降级。
    private func fade(to alpha: CGFloat, completion: (() -> Void)?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = alpha
            completion?()
            return
        }
        // 同上：收尾闭包不是 `Sendable`，但回调必在主线程，按不检查处理。
        nonisolated(unsafe) let finish = completion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = alpha
        } completionHandler: {
            finish?()
        }
    }
}
