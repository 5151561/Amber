import AppKit
import Combine

/// 内容列的导航栈。对应 Music 的 `AMPNavigationController`（` 界面逻辑笔记`）。
///
/// 与 `NavigationStack` 的关键差别、也是换掉它的理由：**被 pop 的页面不销毁**。
/// SwiftUI 的 `navigationDestination` 在返回时把 destination 整个丢掉、下次再进重建，
/// 滚动位置、已取回的详情、图片全归零（design brief 3.3 要求返回时保留滚动位置）。
/// 这里的栈持有的是 `NSViewController`，切页只换**谁露在外面**，控制器一直活着。
/// 更进一步：视图也一直挂在容器里，切页只切 `isHidden`（理由见`install`）。
///
/// 过渡切换动画用 crossfade，不做滑动：Music 的前进/后退也没有横向位移，
/// 而且滑动会把还在拉数据的页面拖出一段空白。
@MainActor
final class ContentNavigationController: NSViewController {

    private let appState: AppState
    private var stack: [ContentPageController] = []
    private var cancellables = Set<AnyCancellable>()
    /// 栈顶变了要通知窗口重建工具栏。
    var onStackChanged: (() -> Void)?

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // 自己什么都不画：窗口根那层 `NSVisualEffectView` 就是背景。
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        appState.$sidebarSelection
            .removeDuplicates()
            .sink { [weak self] item in
                self?.setRoot(for: item ?? .search)
            }
            .store(in: &cancellables)

        // 换音乐源：跟着音源走的那几页整页重建（见 `rebuildProviderRoots`）。
        appState.$selectedProvider
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildProviderRoots() }
            .store(in: &cancellables)

        // 「前往专辑 / 前往艺人」、目录卡片的 `NavigationLink` 垫片都只登记意图，
        // 入栈在这里做（逻辑与旧 `MainView.onChange(of: appState.pendingRoute)` 相同）。
        appState.$pendingRoute
            .compactMap { $0 }
            .sink { [weak self] route in
                guard let self else { return }
                self.push(route)
                self.appState.pendingRoute = nil
            }
            .store(in: &cancellables)
    }

    // MARK: - 栈

    var top: ContentPageController? { stack.last }
    var depth: Int { stack.count }
    var canGoBack: Bool { stack.count > 1 }

    /// 侧栏每一项的根页建一次就留着（Music 也是：主页/新发现/广播来回切不重拉、
    /// 滚动位置也还在）。只有「播放列表」组那些行不缓存——数量随资料库涨。
    private var rootPages: [SidebarItem: ContentPageController] = [:]

    /// 换根：侧栏选中项变了。压在上面的页丢掉（旧版是 `path.removeAll()`），
    /// 旧根若是缓存的就只隐藏视图，控制器与视图都原样留在场上。
    ///
    /// 换根**也要**发 `onStackChanged?()`：栈深没变（换根前后都可能是 1），但栈顶换了页，
    /// 而标题栏右端摆哪几件是**栈顶那一页自己的属性**（见 `pageShowsToolbarActions`），
    /// 不发这一声侧栏点开歌单时工具栏就不会重建。这一声由下面 `install` 那条统一发出
    /// （不动画那一支在 `guard` 的 else 里发），所以这里不用再补。
    func setRoot(for item: SidebarItem) {
        let page: ContentPageController
        if let cached = rootPages[item] {
            page = cached
        } else {
            page = ContentPageFactory.rootPage(for: item, appState: appState)
            if case .playlist = item {} else { rootPages[item] = page }
        }
        let outgoing = stack
        stack = [page]
        install(page, replacing: outgoing.last, animated: false)
        for controller in outgoing where controller !== page {
            if isCachedRoot(controller) { conceal(controller) } else { retire(controller) }
        }
    }

    func push(_ route: Route) {
        let page = ContentPageFactory.page(for: route, appState: appState)
        let previous = stack.last
        stack.append(page)
        install(page, replacing: previous, animated: true)
    }

    @discardableResult
    func pop() -> Bool {
        guard stack.count > 1 else { return false }
        let outgoing = stack.removeLast()
        // 拆视图必须等淡入淡出跑完，中途 `removeFromSuperview` 会把动画截断。
        install(stack[stack.count - 1], replacing: outgoing, animated: true) { [weak self] in
            self?.retire(outgoing)
        }
        return true
    }

    func popToRoot() {
        guard stack.count > 1 else { return }
        let outgoing = Array(stack.dropFirst())
        stack = [stack[0]]
        install(stack[0], replacing: outgoing.last, animated: true) { [weak self] in
            for controller in outgoing { self?.retire(controller) }
        }
    }

    /// 换音乐源：把跟着音源走的根页（主页 / 新发现 / 广播）**整页丢掉重建**，
    /// 而不是在原页上重灌一份快照。
    ///
    /// 原因是 `NSCollectionView` 的 orthogonal 货架换不干净：同一张 collection view
    /// 上「内容 → 空 → 新内容」这一来一回之后，货架里总有一张卡的视图 frame 停在旧位置
    /// （[实测 -dumpattrs] 布局报 y=93、视图却在 y=186，正好差一个段头高），
    /// `invalidateLayout` 与换一张布局都拉不回来。整页重建之后走的是冷启动那条路——
    /// 全新的 collection view 第一次灌快照，没有旧 cell 可留。
    ///
    /// 只换根页：压在上面的二级页（歌单/专辑/艺人详情）属于点开它时的那个音源，
    /// 换源不该把它们连根拔了，它们自己该怎样还怎样。
    private func rebuildProviderRoots() {
        for (item, page) in rootPages {
            guard let catalog = page as? CatalogPageViewController,
                  catalog.followsSelectedProvider else { continue }
            let fresh = ContentPageFactory.rootPage(for: item, appState: appState)
            rootPages[item] = fresh
            // 根页只可能在栈底。它就是栈顶时（没进二级页）当场换上；被压在下面时
            // 只换栈里那一格，等用户返回时 `pop()` 自己会把它装上。
            if let index = stack.firstIndex(where: { $0 === page }) {
                stack[index] = fresh
                if index == stack.count - 1 { install(fresh, replacing: page, animated: false) }
            }
            retire(page)
        }
    }

    private func isCachedRoot(_ page: ContentPageController) -> Bool {
        rootPages.values.contains { $0 === page }
    }

    // MARK: - 装配

    /// **在场的页面视图一律不摘，只切 `isHidden`。**
    ///
    /// 这里原来走 `NSViewController.transition(from:to:)`，它按文档会把 outgoing 的视图
    /// 从父视图里移走。而 `NSCollectionView` 一离开视图树就立刻卸掉全部可见 item
    /// （实测 `visibleItems` 从 5 瞬间归 0）；再挂回来时组合布局要重算一遍，横滚货架
    /// 与卡片在第一帧还落在中间态——这就是切主页/新发现/广播时看到的
    /// 「一堆封面先错位、闪一下才归位」。视图留在场上之后，可见 item、已贴的封面、
    /// 各货架的横滚偏移全部原样留着，切回是 0 帧的事。
    ///
    /// `completion` 在切换动画真正结束后调（不动画时同步调）。调用方靠它决定什么时候
    /// 把出栈的页面拆掉——见 `pop()` 上的注释。
    private func install(_ page: ContentPageController, replacing outgoing: ContentPageController?,
                         animated: Bool, completion: (() -> Void)? = nil) {
        if page.parent !== self { addChild(page) }
        // 页面视图一律走 autoresizing 而不是约束：容器里同时挂着好几页（当前这页可见、
        // 其余的 `isHidden`），用约束的话每装一页都要拆装一遍。
        page.view.translatesAutoresizingMaskIntoConstraints = true
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.width, .height]
        if page.view.superview === view {
            // 已经在场的（缓存根、被压在下面的页）只提到最前，不摘、不重挂。
            view.addSubview(page.view, positioned: .above, relativeTo: nil)
        } else {
            view.addSubview(page.view)
            // 自己挂就得自己布局一次——`transition(from:to:)` 原先是顺手做掉的。
            // 少这一句，页面**内部**的约束还没解算（滚动容器、collection view 都还是
            // 0×0），而目录页装好后几毫秒就会灌进第一份快照：`NSCollectionViewComposi-
            // tionalLayout` 在 0 宽容器里求解会无限生成 item，实测几秒吃掉几十 GB。
            //
            // **容器自己还没有宽度时绝对不能布局**：首次换根在 `viewDidLoad` 里发生，
            // 那会儿 `view.bounds` 还是 0×0，强行解算等于把上面那颗雷主动踩了
            // （实测启动 8 秒涨到 1.6 GB）。这一路交给窗口第一次布局去驱动，
            // 与换掉的 `transition` 那条路行为一致。
            if view.bounds.width > 0 { page.view.layoutSubtreeIfNeeded() }
            // 隐一下，好让新页与缓存页走同一条 `reveal` 通知路径。
            page.view.isHidden = true
        }

        guard let outgoing, outgoing !== page, outgoing.view.superview === view,
              // 「减弱动态效果」开着就不动画。
              animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            reveal(page)
            if let outgoing, outgoing !== page { conceal(outgoing) }
            onStackChanged?()
            completion?()
            return
        }

        // 自己做 crossfade（时长不设，取 `NSAnimationContext` 的默认值，
        // 与原先 `transition(options: [.crossfade])` 同）。
        page.view.alphaValue = 0
        reveal(page)
        // 完成回调的类型是 `@Sendable`，而这里的收尾闭包捕获的是主线程隔离的
        // 视图控制器。AppKit 保证这个回调在主线程调用，所以用 `assumeIsolated` 接回来，
        // 闭包本身按不检查处理。
        nonisolated(unsafe) let finish = completion
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = false
            page.view.animator().alphaValue = 1
            outgoing.view.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                page.view.alphaValue = 1
                self?.conceal(outgoing)
                outgoing.view.alphaValue = 1
                finish?()
            }
        }
        // 工具栏立刻换（不等淡入淡出跑完）：Music 的返回键与页面项也是随点随变。
        onStackChanged?()
    }

    /// 显 / 隐。视图没被摘，`viewDidAppear()` / `viewWillDisappear()` 不保证还会来，
    /// 所以页面要跟着显隐做事就重写 `pageDidAppear()` / `pageDidDisappear()`。
    private func reveal(_ page: ContentPageController) {
        guard page.view.isHidden else { return }
        page.view.isHidden = false
        page.pageDidAppear()
    }

    private func conceal(_ page: ContentPageController) {
        guard !page.view.isHidden else { return }
        page.view.isHidden = true
        page.pageDidDisappear()
    }

    /// 真正从栈里去掉、又不在根页缓存里的那一份才拆。**只是被压在下面、
    /// 或者切走的缓存根不动**——那正是「返回时滚动位置还在」「切回来不重排」靠的东西。
    private func retire(_ page: ContentPageController) {
        guard page.parent === self else { return }
        page.view.removeFromSuperview()
        page.view.isHidden = false
        page.view.alphaValue = 1
        page.removeFromParent()
    }
}
