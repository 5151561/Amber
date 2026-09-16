import AppKit
import Combine
import SwiftUI

/// 主窗的三列：侧栏 / 内容 / 面板。对应 Music 的 `MainSplitViewController`。
///
/// 换掉 `NavigationSplitView` 之后，§1.2 表里的两条绕路直接没了：
/// - 列宽不再需要 `navigationSplitViewColumnWidth`（那个修饰符只能挂在传给
///   `NavigationSplitView` 的列根视图上，写在列内部 macOS 26 上静默失效），
///   直接是 `NSSplitViewItem.minimumThickness / maximumThickness`；
/// - 面板不再需要「必须挂在 `NavigationSplitView` 本身、写进`detail:` 就失效」，
///   `NSSplitViewItem(inspectorWithViewController:)` 就是一列。
///
/// [AX] Music 的这棵树：`AXSplitter [1211.5, 85, 0.5, 871]` + 面板列
/// `[1212, 33, 258, 923]`；侧栏那侧是`AXScrollArea [0, 85, 202.5, 814]` +
/// `AXSplitter [202.5, 85, 0.5, 871]`。内容能从两边穿到面板/侧栏底下去，
/// 靠的就是「面板是分栏的一列」这件事。
@MainActor
final class MainSplitViewController: NSSplitViewController {

    private let appState: AppState
    let sidebarViewController: SidebarViewController
    let navigationController: ContentNavigationController
    /// 面板列的容器（inspector spec §1）：歌词与待播清单两个子控制器常驻其中，
    /// 换档靠交叉淡入。**不再是「一台 `NSHostingController` 换`rootView`」**——
    /// 待播清单换成 AppKit 之后它有滚动位置、选区、定时器，抽换 `rootView` 装不下。
    let inspectorContainer: InspectorContainerViewController
    private var cancellables = Set<AnyCancellable>()
    /// 我们自己收合面板时置位，免得 `splitViewDidResizeSubviews` 把这一下回灌进模型。
    private var isSyncingInspector = false

    init(appState: AppState) {
        self.appState = appState
        self.sidebarViewController = SidebarViewController(appState: appState)
        self.navigationController = ContentNavigationController(appState: appState)
        self.inspectorContainer = InspectorContainerViewController(appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 分栏自己不画背景：玻璃在窗口根那一层（见 RootViewController）。
        splitView.dividerStyle = .thin
        splitView.autosaveName = "AmberMainSplit"

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        // 初始宽度不在这里写：`autosaveName` 没有记录时，AppKit 按子控制器 view 的 frame
        // 给首次厚度——`SidebarViewController.loadView` 的容器 frame 已经是 202.5。
        sidebar.minimumThickness = MusicMetrics.Sidebar.widthMin
        sidebar.maximumThickness = MusicMetrics.Sidebar.widthMax
        sidebar.canCollapse = true
        // 标题栏那颗系统侧栏开关照 Music 摘掉（工具栏里没有这一件），
        // 收起入口是「显示 ▸ 隐藏边栏」⌃⌘S → `toggleSidebar(_:)`。
        sidebar.allowsFullHeightLayout = true
        addSplitViewItem(sidebar)

        let content = NSSplitViewItem(viewController: navigationController)
        content.minimumThickness = 400
        addSplitViewItem(content)

        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorContainer)
        // [实测] inspector spec §2.1 实测的四条：宽度 min == max == 258（拖不动）、
        // 满高布局、拖拽悬停可临时展开、全屏时贴右缘悬停也能露出来。
        inspector.minimumThickness = MusicMetrics.Inspector.width
        inspector.maximumThickness = MusicMetrics.Inspector.width
        inspector.canCollapse = true
        inspector.allowsFullHeightLayout = true
        inspector.isSpringLoaded = true
        // `revealsOnEdgeHoverInFullscreen` 在公开 SDK 里没有（`NSSplitViewItem.h` 里
        // 只到 `allowsFullHeightLayout`）。Music 设的是同名 SPI——这里先问一句
        // `responds(to:)` 再写，选择器不在就什么也不做，不会崩。
        let revealsOnEdgeHover = Selector(("setRevealsOnEdgeHoverInFullscreen:"))
        if inspector.responds(to: revealsOnEdgeHover) {
            inspector.setValue(true, forKey: "revealsOnEdgeHoverInFullscreen")
        }
        inspector.isCollapsed = !appState.isInspectorOpen
        addSplitViewItem(inspector)

        // 歌词 / 待播清单现在是**两件事**：`inspectorMode` 是全局的档位（永不为 nil），
        // `isInspectorOpen` 是主窗这一扇「面板列开着没有」。任一变了都重推一次，
        // 开合走 animator、「减弱动态效果」时直接到位。
        //
        // `@Published` 是在 **willSet** 里发的，同步读回属性拿到的是旧值——所以
        // 先 `receive(on:)` 落到下一轮再读（与两个迷你播放器里的订阅同一条注意事项）。
        appState.$inspectorMode.removeDuplicates().map { _ in () }
            .merge(with: appState.$isInspectorOpen.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncInspector() }
            .store(in: &cancellables)
    }

    // MARK: - 状态

    var isSidebarCollapsed: Bool {
        splitViewItems.first?.isCollapsed ?? false
    }

    /// 把模型的两位（档位 + 开着没有）落到分栏上。[实测] inspector spec §2.3 的两个
    /// `doShowHide*` 分支原样保留，只是判据从「`mode` 是不是 nil」换成了那两位：
    ///
    /// - **面板收着**：用**无动画的裸 setter** 换档再展开——面板还没露脸，
    ///   没必要淡入（也避免「展开动画 + 交叉淡入」两套动画打架）；
    /// - **面板开着、只是换另一档**：走 `setMode(_:animated: true)` 交叉淡入，**分栏不动**；
    /// - **收起**：只收分栏，档位原样留在 `appState.inspectorMode` 上，
    ///   下次展开还是这一档（Music 那边第三支 `doShowHide*` 的语义）。
    private func syncInspector() {
        let wasCollapsed = splitViewItems.last?.isCollapsed ?? true
        let open = appState.isInspectorOpen
        inspectorContainer.setMode(appState.inspectorMode, animated: open && !wasCollapsed)
        setInspector(collapsed: !open)
    }

    private func setInspector(collapsed: Bool) {
        guard let item = splitViewItems.last, item.isCollapsed != collapsed else { return }
        isSyncingInspector = true
        defer { isSyncingInspector = false }
        if inspectorExpansionAnimates {
            item.animator().isCollapsed = collapsed
        } else {
            item.isCollapsed = collapsed
        }
    }

    /// [实测] inspector spec §2.4：展开 / 收起要不要走动画。
    ///
    /// `animate_inspector_expansion` 是 Music 的一个**隐藏偏好键**（键名照抄）：
    /// 没写过就当 true，只有显式写成 false 才不经 animator。
    /// Amber 原有的「系统『减弱动态效果』时直接到位」这条保留——那是无障碍要求，
    /// 与这个隐藏偏好是两件事，任一为「不动画」就不动画。
    private var inspectorExpansionAnimates: Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        let key = "animate_inspector_expansion"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// [实测] inspector spec §2.8：把曲目拖到窗口右缘悬停展开侧栏时，
    /// **强制切到队列**——这个手势的目的就是把曲目丢进待播清单，停在歌词上没意义。
    ///
    /// Music 实现的是私有回调 `_splitView:canSpringLoadRevealArrangedSubview:`。
    /// 公开 SDK 里没有对应的 `NSSplitViewDelegate` 方法，这里照它的选择器实现一份：
    /// AppKit 叫得到就生效，叫不到也只是这一句不执行——`springLoaded = true`
    /// 那半边（悬停临时展开）本来就是公开能力，不受影响。
    @objc(_splitView:canSpringLoadRevealArrangedSubview:)
    func splitView(_ splitView: NSSplitView,
                   canSpringLoadRevealArrangedSubview subview: NSView) -> Bool {
        guard splitView.arrangedSubviews.last === subview else { return false }
        // 只动容器自己那一档，**不动 `appState.inspectorMode` / `isInspectorOpen`**：
        // spring-load 是拖拽期间的临时露出，松手后 AppKit 自己收回去；
        // 写进模型会把面板永久留在展开态、还会把用户上次选的档位改掉。
        // Music 这里也只有一句裸 setter（§2.8：`w0 = 1` 后 return true）。
        inspectorContainer.setMode(.queue, animated: false)
        return true
    }

    /// 用户直接把面板那条分隔线拖到收起时，把状态写回模型（否则再点歌词键没反应）。
    /// AppKit 确实不会为「拖动收合」通知模型，所以这条补丁不能删。
    ///
    /// 但它现在只回灌「开着没有」这一位，**不碰档位**——从前这里写的是
    /// `playerInspector = nil`，于是拖收一次就把「上次看的是待播清单」也一并忘了。
    /// 也只回灌**收起**这一个方向：展开还有 spring-load 那条「拖拽期间临时露出」的路
    ///（见下面的 `canSpringLoadRevealArrangedSubview`），那一下不该被记成用户开了面板。
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isSyncingInspector, let item = splitViewItems.last else { return }
        if item.isCollapsed, appState.isInspectorOpen {
            appState.isInspectorOpen = false
        }
    }
}
