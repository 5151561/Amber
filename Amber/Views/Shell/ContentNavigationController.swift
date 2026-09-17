import AppKit

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
final class ContentNavigationController: NSViewController, NavigationIntentReceiving {

    private let appState: AppState
    private var stack: [StackEntry] = []
    private let observers = TaskBag()
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

        observers.observeNow({ [appState] in appState.sidebarSelection }) { [weak self] item in
            self?.setRoot(for: item ?? .search)
        }

        // 换音乐源：跟着音源走的那几页整页重建（见 `rebuildProviderRoots`）。
        observers.observe({ [appState] in appState.selectedProvider }) { [weak self] _ in
            self?.rebuildProviderRoots()
        }

        // 「前往专辑 / 前往艺人」那条不再在这里订阅——它现在沿响应链下来，
        // 见下面的 `amberOpenRoute(_:)`。
    }

    // MARK: - 导航意图（响应链）

    /// 「前往专辑 / 前往艺人」、目录卡片的落点、待播清单分区头的「来自《…》」——
    /// 整个 App 的导航意图都经这一条进来。发起方是 `AppState.push` / `goToAlbum` /
    /// `goToArtist` / `openLibraryArtist`，它们只 `sendAction`、不留状态
    /// （`AGENTS.md` 界面层铁律 4）。
    ///
    /// 这里从前订的是 `appState.pendingRoute`：一个可变字段当一次性信箱，收到就入栈
    /// 再写回 nil。删掉它的直接理由是 `.trackGrid` 那种落点能带上百个 `Track` 常驻在
    /// 字段上（design-ref/reactive-ui-review.md §2.1「事件当状态存」）；顺带也把
    /// 「`@Published` 在 willSet 发布，`= nil` 写完立刻被外层赋值覆盖」那个老坑的
    /// 最后一点残留一起收了——`Observations` 早已把它从根上消掉，但信箱本身还在。
    @objc func amberOpenRoute(_ sender: Any?) {
        guard let intent = sender as? NavigationIntent else { return }
        switch intent.destination {
        case .route(let route):
            push(route)
        case .libraryArtist(let id):
            openLibraryArtist(id: id)
        }
    }

    /// 跳到资料库「艺人」根页并选中某一行。**不是 push**：那一页是侧栏「艺人」的根页。
    ///
    /// `setRoot` 在这里**同步**调一次，而不是只写侧栏选中项等那条观察：`Observations`
    /// 要到下一轮才到，而选中要交给的正是这一次换出来的那一页。侧栏高亮照旧写一份，
    /// 它那条观察随后还会再调一次 `setRoot(for: .artists)`——同一份缓存根页，
    /// `install` 只把它提到最前，幂等。
    ///
    /// **与信箱版的一处行为差**：艺人页上面压着二级页（艺人 → 专辑）时，从前
    /// `sidebarSelection` 已经是 `.artists`、不换根，于是选中悄悄落在被压住的那一页上，
    /// 用户还停在专辑页；现在换根会把压着的页出栈，真的跳过去——这才是这条意图的字面意思。
    private func openLibraryArtist(id: String) {
        appState.sidebarSelection = .artists
        setRoot(for: .artists)
        (top as? any LibraryArtistSelecting)?.selectLibraryArtist(id: id)
    }

    // MARK: - 栈

    /// 栈里的一格：页面 + **把它推上来的那条 `Route`**。
    ///
    /// route 记在栈这一侧而不是记在 `ContentPageController` 上：页面控制器是工厂按
    /// `Route` 造出来的，它自己不需要知道「我是被哪条路由推上来的」；「这一层是不是
    /// 同一个落点」从头到尾只有导航栈关心。根页由侧栏选中项决定、不是 push 进来的，
    /// route 给 nil（唯一的例外见 `rootRoute(for:)`）。
    private struct StackEntry {
        let route: Route?
        let page: ContentPageController
    }

    var top: ContentPageController? { stack.last?.page }
    var depth: Int { stack.count }
    var canGoBack: Bool { stack.count > 1 }

    /// 栈深上限。每一层都攥着一整页视图与它取回的数据，而再深也不会有人按这么多次返回。
    /// 有了下面 push 的去重之后正常用法根本够不到这个数，它只是最后一道闸。
    private static let maxDepth = 16

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
        stack = [StackEntry(route: Self.rootRoute(for: item), page: page)]
        install(page, replacing: outgoing.last?.page, animated: false)
        for entry in outgoing where entry.page !== page {
            if isCachedRoot(entry.page) { conceal(entry.page) } else { retire(entry.page) }
        }
    }

    /// 根页里唯一能用 `Route` 指到的一页：侧栏「播放列表」组的那一行，与`.libraryPlaylist`
    /// 是同一份歌单、同一张详情页。登记上它，站在这份歌单上再点一次指向它自己的落点
    /// （待播清单分区头的「来自《…》」、卡片菜单里的「前往歌单」）才判得出「已经在这儿了」。
    /// 其余根页（搜索、主页、资料库四页…）压根没有对应的 `Route`，给 nil。
    private static func rootRoute(for item: SidebarItem) -> Route? {
        if case .playlist(let id) = item { return .libraryPlaylist(id: id) }
        return nil
    }

    /// 往栈上推一层。**`Route` 是 `Hashable`，这里就拿它当页面的身份。**
    ///
    /// - **栈顶就是它**：什么都不做。从前每点一次都新建一个 VC——待播清单分区头那条
    ///   「来自《某某》」连点五次＝五层同一张歌单，每一层各发一遍 `playlistDetail`
    ///   网络请求、视图全留在容器里（`install` 只切 `isHidden`），要按五次返回才出得来
    ///   （design-ref/reactive-ui-review.md 故障 12）。目录卡片那 21 处 `RouteLink` 同理。
    /// - 不是栈顶就真造一页，**哪怕栈里更深处已经有同一页**。「专辑 → 艺人 → 又回同一张
    ///   专辑」是一次合法的绕圈，返回该回到刚才那位艺人；跳回旧的那一层会把中间几层
    ///   连同它们的滚动位置一起吞掉。而且 `Route` 的载荷是整份值——`Route.album(of:)`
    ///   造的是 `trackCount: 0` 的合成 `Album`，同一张碟从不同入口进来压根不相等——
    ///   按「栈里有没有」判会时灵时不灵，那比不判更糟。栈无限长由`trimToMaxDepth` 兜底。
    func push(_ route: Route) {
        // 栈顶就是它：什么都不做。这一条是确定对的——同一个落点连点几次，
        // 载荷同源、必然相等。
        guard stack.last?.route != route else { return }
        trimToMaxDepth()
        let page = ContentPageFactory.page(for: route, appState: appState)
        let previous = stack.last?.page
        stack.append(StackEntry(route: route, page: page))
        install(page, replacing: previous, animated: true)
    }

    /// 顶到上限时从**栈底往上**丢（根页不动）：最近那几层才是返回链上真会走回去的。
    private func trimToMaxDepth() {
        while stack.count >= Self.maxDepth, stack.count > 1 {
            let entry = stack.remove(at: 1)
            if !isCachedRoot(entry.page) { retire(entry.page) }
        }
    }

    @discardableResult
    func pop() -> Bool { popTo(stack.count - 2) }

    func popToRoot() { popTo(0) }

    /// 返回到栈里第 `index` 层，把压在它上面的全部出栈。`pop()` /`popToRoot()` /
    /// push 撞上「栈里已经有」都走这一条。
    @discardableResult
    private func popTo(_ index: Int) -> Bool {
        guard index >= 0, index < stack.count - 1 else { return false }
        let outgoing = Array(stack[(index + 1)...])
        stack.removeSubrange((index + 1)...)
        // 拆视图必须等淡入淡出跑完，中途 `removeFromSuperview` 会把动画截断。
        install(stack[index].page, replacing: outgoing.last?.page, animated: true) { [weak self] in
            guard let self else { return }
            for entry in outgoing where !self.isCachedRoot(entry.page) { self.retire(entry.page) }
        }
        return true
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
            if let index = stack.firstIndex(where: { $0.page === page }) {
                stack[index] = StackEntry(route: stack[index].route, page: fresh)
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
        if page.view.amberSuperview === view {
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

        guard let outgoing, outgoing !== page, outgoing.view.amberSuperview === view,
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
        // 闭包本身按不检查处理。`nonisolated(unsafe)` 本身就是一句不安全声明，
        // 下面调它的那一下跟着标 `unsafe`——保证它安全的就是上面这条「必在主线程」。
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
                unsafe finish?()
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

/// 资料库「艺人」页接「选中某位艺人」这一条。由 `LibraryArtistsViewController` 实现。
///
/// 走协议而不是 `as? LibraryArtistsViewController`：导航栈只认 `ContentPageController`，
/// 不该反过来认识具体是哪一页（与 `AboutPanelPresenting` 同形）。
@MainActor
protocol LibraryArtistSelecting: AnyObject {
    func selectLibraryArtist(id: String)
}
