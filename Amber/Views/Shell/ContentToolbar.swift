import AppKit
import SwiftUI

// MARK: - 标识符

extension NSToolbarItem.Identifier {
    /// 返回键（`isNavigational`：AppKit 会把它排在左侧导航区，跟着侧栏边界对齐）
    static let amberBack = NSToolbarItem.Identifier("amber.back")
    /// 页面标题（13pt secondary，左对齐）
    static let amberPageTitle = NSToolbarItem.Identifier("amber.page-title")
    /// 筛选与排序 ☰
    static let amberFilter = NSToolbarItem.Identifier("amber.filter")
    /// 页内搜索框（211×38）
    static let amberSearch = NSToolbarItem.Identifier("amber.search")
    /// 搜索页的居中搜索框
    static let amberSearchCenter = NSToolbarItem.Identifier("amber.search-center")
    /// 搜索页的范围分段控件
    static let amberSearchScope = NSToolbarItem.Identifier("amber.search-scope")
    /// 目录页右端的音乐源切换胶囊（Amber 自己的件，Music 没有）
    static let amberProvider = NSToolbarItem.Identifier("amber.provider")
    static let amberShare = NSToolbarItem.Identifier("amber.share")
    static let amberMore = NSToolbarItem.Identifier("amber.more")
    /// 内容列 ↔ 面板列的跟踪分隔件（`NSTrackingSeparatorToolbarItem`）。
    /// 排在页面那几件之后，让 AppKit 把它们关进内容列那一区（见 `MainWindowController`）。
    static let amberPanelSeparator = NSToolbarItem.Identifier("amber.panel-separator")
}

// MARK: - 共用的件

/// 标题栏各件的构造。放在一处是因为「资料库四页 + 歌曲页」用的是同一套形态
/// （[AX] Music 1.7：标题 221.5 起、筛选槽 1208 宽 40、搜索槽 1248 宽 217、字段 211×38）。
@MainActor
enum ContentToolbarItems {

    /// 页面标题。Music 把它放在标题栏而不是内容区（[AX] `AXStaticText [221.5, 50, …, 18]`）。
    ///
    /// view 就是一枚裸 `NSTextField`，**不套容器**：[实测 2026-09-05] macOS 26 会给
    /// 自定义容器视图套液态玻璃平台（`NSToolbarPlatterView` + `NSGlassEffectView`），
    /// 标题就变成一颗灰胶囊、文字还被截成「…」；裸标签 AppKit 不套。
    /// 位置由 AppKit 排，与 Music 差的那一截由 `ToolbarTitleLabel` 的对齐内缩补。
    static func title(_ text: String, identifier: NSToolbarItem.Identifier = .amberPageTitle)
        -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = ToolbarTitleLabel(labelWithString: text)
        // 系统默认字号就是 Music 的这一档：`NSFont.systemFontSize` = 13，
        // [PX] 页面标题字形高 12、灰 55% 反推的也是 13pt secondary。用系统的，别写死。
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        item.view = label
        item.label = text
        item.paletteLabel = text
        item.isEnabled = false
        return item
    }

    /// 改标题（「最近添加」的标题跟着滚动联动当前段名）。
    static func setTitle(_ text: String, on item: NSToolbarItem?) {
        guard let label = item?.view as? ToolbarTitleLabel else { return }
        label.stringValue = text
        item?.label = text
    }

    /// 筛选与排序 ☰。用 `NSMenuToolbarItem`：它自己画 AppKit 的菜单钮，
    /// 菜单内容每次弹出前由 delegate 重建（勾选态要跟着当前排序走）。
    static func filter(identifier: NSToolbarItem.Identifier = .amberFilter,
                       menu: NSMenu) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease",
                             accessibilityDescription: "筛选与排序")
        item.menu = menu
        item.showsIndicator = false
        item.label = "筛选与排序"
        item.paletteLabel = "筛选与排序"
        item.toolTip = "筛选与排序"
        return item
    }

    /// 页内搜索框。Music 的这一件是定死的 211×38（`.searchable` 的宽度既改不了、
    /// 实测也比它宽出一大截），所以直接放一个改了固有尺寸的 `NSSearchField`。
    static func search(identifier: NSToolbarItem.Identifier = .amberSearch,
                       placeholder: String,
                       binder: SearchFieldBinder) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let field = binder.field
        field.placeholderString = placeholder
        item.view = field
        item.label = placeholder
        item.paletteLabel = placeholder
        return item
    }
}

/// 标题栏里的页面标题标签。
///
/// 只多一件事：把对齐矩形往左扩 `Titlebar.titleLeading`（11）。AppKit 按对齐矩形排
/// 工具栏项（两侧各垫 4），对齐矩形比 frame 宽出的那 11pt 就把 frame 推到 viewer + 15——
/// [实测] 裸标签 x = 8 时落在 218.5，Music 在 221.5，故取 11（算法见 `Titlebar.titleLeading`）。
/// 用负的对齐内缩而不是外面套容器，是因为容器会被 macOS 26 套上玻璃平台。
final class ToolbarTitleLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: -MusicMetrics.Titlebar.titleLeading, bottom: 0, right: 0)
    }
}

/// 固定 211×38 的搜索框（Music 实测；`NSSearchField` 的固有高度到不了 38）。
///
/// **尺寸只能用约束给，`intrinsicContentSize` 和`minSize/maxSize` 都不管用。**
/// [实测 2026-09-05，独立探针] 同一个 `intrinsicContentSize = 211×38` 的自定义视图放进
/// `NSToolbarItem`：只给固有尺寸 →`NSToolbarItemViewer` 把它排成`[4, 8, 211, 36]`
/// （viewer 上下各留 8，高度被压到 36）；再补上已弃用的 `minSize/maxSize = 211×38` →
/// **一点没变，仍是 36**；改成 `translatesAutoresizingMaskIntoConstraints = false` +
/// 必需的 38pt 高度约束 → `[4, 7, 211, 38]`，上下各 7。
/// 后者与 Music 完全对上（[AX] `songs.json` 字段`[1251, 40, 211, 38]`，工具栏顶 33，正是 +7）。
/// 这也是 `maxSize` 的弃用说明写的那句：让系统用约束去量。
final class MusicSearchField: NSSearchField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: MusicMetrics.SongsTable.searchFieldWidth),
            heightAnchor.constraint(equalToConstant: MusicMetrics.SongsTable.searchFieldHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 搜索框 ↔ 页模型的接线。`NSSearchField` 要一个 delegate，而页模型不是 NSObject，
/// 所以中间放这一层。
///
/// `text` 是「现在的搜索词是什么」的读取闭包，内部用 `Observations` 盯着它。
@MainActor
final class SearchFieldBinder: NSObject, NSSearchFieldDelegate {
    let field = MusicSearchField(frame: .zero)
    private let onChange: (String) -> Void
    private var sync: Task<Void, Never>?

    init(text: @escaping @MainActor @Sendable () -> String,
         onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init()
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        // 模型那边被别处改了（比如切页重建），把字段同步过来；只在真的不同才回写，
        // 否则会把输入光标顶到末尾。
        //
        // `Observations` 在这里建而不是由调用方传进来：它的 emit 闭包带
        // `@_inheritActorContext`，要在**隔离上下文**里构造才拿得到主 actor 隔离，
        // 而调用点全是 `lazy var binder = …` 的属性初始化器，那里不是。
        sync = Task { [weak self] in
            for await value in Observations(text) {
                guard let self, self.field.stringValue != value else { continue }
                self.field.stringValue = value
            }
        }
    }

    deinit { sync?.cancel() }

    func controlTextDidChange(_ notification: Notification) {
        onChange(field.stringValue)
    }
}

// MARK: - 资料库四页

/// 资料库「专辑 / 最近添加 / 艺人 / 所有播放列表」四页的宿主。
///
/// [AX] 这四页的标题栏同构：页面标题在左（221.5 起、13pt secondary），
/// 右端是筛选槽（1208 宽 40）与搜索槽（1248 宽 217，字段 211×38）。
/// 原先是 `LibraryViews.swift` 里的`LibraryPageChrome` 修饰符。
@MainActor
class LibraryPageController: ContentPageController {
    let model: LibraryPageModel
    private let pageTitle: String
    private let allItemsTitle: String
    private let placeholder: String
    /// 专辑页有排序菜单；最近添加页没有（[实测] `supportedSortOptions` 返回 nil，
    /// `recents 规格` §2.2）。艺人页与所有播放列表页同样没有。
    private let hasSort: Bool
    private lazy var binder = SearchFieldBinder(text: { [model] in model.search }) { [weak self] text in
        self?.model.search = text
    }
    private lazy var menuController = LibraryFilterMenuController(
        model: model, allItemsTitle: allItemsTitle, hasSort: hasSort)
    /// 造出来的标题件。「最近添加」的标题会跟着滚动联动当前段名，得留着改它。
    private weak var titleItem: NSToolbarItem?

    /// 标题栏标题的覆盖值（nil = 这一页不覆盖，一直用页名）。默认不覆盖，
    /// 只有「最近添加」写它（段名跟着滚动走）。
    ///
    /// **这一位属于写它的那一页**，不许挂回四页共用的 `LibraryPageModel`（原委见那边的
    /// 注释）：它是一次性显示态，摆进那份共享模型里，迟早又会被谁接成整页刷新
    /// （「滚过一个段头 = 整页重灌」）。所以它长在页控制器自己身上。
    ///
    /// 不是事件流，所以不走 `EventChannel`——计划 §1.4 那条判据问的是「消费方关心
    /// 『发生了一次』还是『现在的值是什么』」：建标题件那一刻得有个字摆上去，要的是
    /// **当前值**。而这个状态的写方与读方是同一台控制器，连订阅都省了：当前值由
    /// `makePageToolbarItem` 直接读，后续变化由 `didSet` 直接改攥在手里的那一件
    /// （同计划 §2 铁律 3 的口径：界面自己的显示态不绕广播）。
    ///
    /// 去重留在这里——它就是从前那句 `.removeDuplicates()`：滚动时每帧都会写一次。
    var displayTitle: String? {
        didSet {
            guard displayTitle != oldValue else { return }
            ContentToolbarItems.setTitle(displayTitle ?? pageTitle, on: titleItem)
        }
    }

    init(appState: AppState, model: LibraryPageModel, title: String, allItemsTitle: String,
         placeholder: String, hasSort: Bool,
         @ViewBuilder content: @escaping () -> some View) {
        self.model = model
        self.pageTitle = title
        self.allItemsTitle = allItemsTitle
        self.placeholder = placeholder
        self.hasSort = hasSort
        super.init(appState: appState, content: content)
    }

    /// AppKit 原生页版（阶段 5 起的常态）：视图由子类 `loadView` 自己搭，
    /// 标题栏三件的形态与取值仍走这里同一份。
    init(nativePage appState: AppState, model: LibraryPageModel, title: String,
         allItemsTitle: String, placeholder: String, hasSort: Bool) {
        self.model = model
        self.pageTitle = title
        self.allItemsTitle = allItemsTitle
        self.placeholder = placeholder
        self.hasSort = hasSort
        super.init(nativePage: appState)
    }

    override var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        // 弹性空隙把标题槽撑到右端两件跟前——[AX] 标题组宽 985.5、右端两件贴着窗沿。
        [.amberPageTitle, .flexibleSpace, .amberFilter, .amberSearch]
    }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .amberPageTitle:
            // 「当前值」那一路。切页回来时这一件会被重造（`MainWindowController`
            // 的 `replacePageOwnedItems`），所以标题得当场问 `displayTitle` 要，
            // 不能指望订阅补——「最近添加」滚到半截切走再切回来，靠的就是这一句。
            let item = ContentToolbarItems.title(displayTitle ?? pageTitle)
            titleItem = item
            return item
        case .amberFilter:
            return ContentToolbarItems.filter(menu: menuController.menu)
        case .amberSearch:
            return ContentToolbarItems.search(placeholder: placeholder, binder: binder)
        default:
            return nil
        }
    }
}

/// 筛选 ☰ 的菜单。结构照 [实测] `library 规格` §4.2/§4.3
///（每页筛选固定两项 → 分隔 → 排序选项▸），与歌曲页那颗同形。
@MainActor
private final class LibraryFilterMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let model: LibraryPageModel
    private let allItemsTitle: String
    private let hasSort: Bool

    init(model: LibraryPageModel, allItemsTitle: String, hasSort: Bool) {
        self.model = model
        self.allItemsTitle = allItemsTitle
        self.hasSort = hasSort
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(check(allItemsTitle, on: !model.favoritesOnly,
                           action: #selector(selectAllItems)))
        menu.addItem(check("仅喜爱", on: model.favoritesOnly, action: #selector(selectFavorites)))
        guard hasSort else { return }
        menu.addItem(.separator())
        let sortItem = NSMenuItem(title: "排序选项", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "排序选项")
        for key in LibraryGridSortKey.allCases {
            let entry = check(key.title, on: model.sort.key == key, action: #selector(selectSortKey))
            entry.tag = key.rawValue
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(check("升序", on: model.sort.ascending, action: #selector(selectAscending)))
        submenu.addItem(check("降序", on: !model.sort.ascending, action: #selector(selectDescending)))
        sortItem.submenu = submenu
        menu.addItem(sortItem)
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func selectAllItems() { model.favoritesOnly = false }
    @objc private func selectFavorites() { model.favoritesOnly = true }

    @objc private func selectSortKey(_ sender: NSMenuItem) {
        guard let key = LibraryGridSortKey(rawValue: sender.tag) else { return }
        model.sort.key = key
        model.persistSort()
    }

    @objc private func selectAscending() {
        model.sort.ascending = true
        model.persistSort()
    }

    @objc private func selectDescending() {
        model.sort.ascending = false
        model.persistSort()
    }
}

// MARK: - 搜索页

/// 搜索页居中搜索框（Music 实测 centerDisplayItem §4.1.1，484×38 胶囊搜索框）。
///
/// 使用 AppKit 原生 `NSSearchField`，完全不用 SwiftUI 包装，
/// 彻底去除双层胶囊（系统 platter + SwiftUI 胶囊背景）和突兀的「取消」按钮，
/// 严格对齐 Apple Music 的工具栏搜索框规范。
final class SearchPageSearchField: NSSearchField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .default
        font = .systemFont(ofSize: NSFont.systemFontSize)
        let width = widthAnchor.constraint(
            equalToConstant: MusicMetrics.Titlebar.centerSearchFieldIdealWidth)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MusicMetrics.Titlebar.itemHeight),
            widthAnchor.constraint(
                greaterThanOrEqualToConstant: MusicMetrics.Titlebar.centerSearchFieldMinWidth),
            widthAnchor.constraint(
                lessThanOrEqualToConstant: MusicMetrics.Titlebar.centerSearchFieldIdealWidth),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 搜索页居中搜索框 ↔ 页模型/应用状态的双向绑定器。
@MainActor
final class SearchPageFieldBinder: NSObject, NSSearchFieldDelegate {
    let field = SearchPageSearchField(frame: .zero)
    private let model: SearchPageModel
    private let appState: AppState
    private let observers = TaskBag()

    init(model: SearchPageModel, appState: AppState) {
        self.model = model
        self.appState = appState
        super.init()

        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = model.query
        field.setAccessibilityLabel("搜索")
        field.toolTip = "搜索"
        updatePlaceholder()

        // 外部改写词条时同步给 AppKit 字段（如落地页点击最近搜索、Esc 清空）
        // `removeDuplicates()` 不用写了：`Observations` 对 Equatable 自带相邻去重。
        observers.observeNow({ [model] in model.query }) { [weak self] query in
            guard let self, self.field.stringValue != query else { return }
            self.field.stringValue = query
        }

        // 范围或当前音乐源改变时动态更新占位符
        observers.observeNow({ [model] in model.scope }) { [weak self] _ in self?.updatePlaceholder() }

        observers.observeNow({ [appState] in appState.selectedProvider }) { [weak self] _ in
            self?.updatePlaceholder()
        }

        // 焦点请求信号（进入页面、Esc 重置后保持焦点等）
        // focusToken 是只增的计数信号，相邻去重咬不到它。
        observers.observe({ [model] in model.focusToken }) { [weak self] _ in self?.focus() }
    }

    private func updatePlaceholder() {
        switch model.scope {
        case .online:
            field.placeholderString = appState.selectedProvider.displayName
        case .library:
            field.placeholderString = "资料库"
        }
    }

    func focus() {
        guard let window = field.amberWindow else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.field.amberWindow else { return }
                window.makeFirstResponder(self.field)
            }
            return
        }
        window.makeFirstResponder(field)
    }

    // MARK: - NSSearchFieldDelegate / NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        if model.query != text {
            model.query = text
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // 回车提交：检查是否按下了 Option 键
            let isOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            if isOption {
                model.submitOptionToken += 1
            } else {
                model.submitToken += 1
            }
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            // Esc：清空并回落地页，焦点留在此处（§2.3 cancelOperation: / viewDidAppear §4.1.7）
            model.onCancel()
            return true

        default:
            return false
        }
    }
}

/// 搜索页。[AX] 标题栏是「居中搜索框（`search.json` 组`[594, 33, 486, 52]`、
/// 字段 `[597, 40, 484, 38]`）+ 右端范围分段控件（`[1205, 40, 257, 38]`）」。
///
/// 页面本体是**两页合一**（计划阶段 5 批 C）：词条为空时是落地页
/// `SearchLandingViewController`，否则是结果页`SearchResultsViewController`
/// （目录页那台引擎吃 `SearchResultsModel`）。两页都常驻、只切`isHidden`——
/// 与导航容器对页面的做法一条道理：`NSCollectionView` 一离开视图树就把可见 item 全卸了，
/// 切回来要重排一帧。
///
/// 这一层自己不搭内容，只做三件事：标题栏那两件、按 `showsLanding` 切子页、
/// 以及上屏回焦（`viewDidAppear` / `pageDidAppear`）。
@MainActor
final class SearchPageController: ContentPageController {
    private let model: SearchPageModel
    private let results: SearchResultsModel
    private let landingPage: SearchLandingViewController
    private let resultsPage: SearchResultsViewController
    private lazy var binder = SearchPageFieldBinder(model: model, appState: appState)

    init(appState: AppState) {
        // 默认 tab 从「[tab名]」偏好串恢复（§4.1.3 createSegmentedControl 的解析逻辑）。
        let persisted = UserDefaults.standard.string(forKey: SearchScopeTab.defaultScopeKey)
        let model = SearchPageModel(scope: SearchScopeTab.from(persisted: persisted ?? "[在线]"))
        self.model = model
        let results = SearchResultsModel(appState: appState, page: model)
        self.results = results
        self.landingPage = SearchLandingViewController(appState: appState)
        self.resultsPage = SearchResultsViewController(appState: appState, model: results)
        super.init(nativePage: appState)
        landingPage.onSelectTerm = { [weak results] term in results?.selectTerm(term) }
        landingPage.onClearRecents = { [weak results] in results?.clearRecentSearches() }
        // 启动参数 `-search <词>` 带进来的词条，走的是落地页选词那同一条路。
        if let term = appState.launchSearchTerm {
            appState.launchSearchTerm = nil
            results.selectTerm(term)
        }
    }

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        // 两个子页在 `viewDidLoad` 里挂——`addChild` 要在`view` 已经落定之后做。
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [landingPage, resultsPage] as [ContentPageController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        // 首屏是落地页（词条为空）。
        resultsPage.view.isHidden = true

        observers.observeNow({ [results] in results.showsLanding }) { [weak self] landing in
            self?.showLanding(landing)
        }
        observers.observeNow({ [results] in results.recentSearches }) { [weak self] terms in
            self?.landingPage.setRecents(terms)
        }
    }

    override var pageToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [.flexibleSpace, .amberSearchCenter, .flexibleSpace, .amberSearchScope]
    }

    override func makePageToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .amberSearchCenter:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = binder.field
            item.label = "搜索"
            item.paletteLabel = "搜索"
            return item
        case .amberSearchScope:
            return makeScopeItem(identifier)
        default:
            return nil
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusIfEmpty()
    }

    /// 侧栏切回搜索页时视图并没有被摘（导航容器只切 `isHidden`），
    /// `viewDidAppear()` 不会再来，焦点得从这里补。
    override func pageDidAppear() {
        super.pageDidAppear()
        (results.showsLanding ? landingPage : resultsPage).pageDidAppear()
        focusIfEmpty()
    }

    override func pageDidDisappear() {
        super.pageDidDisappear()
        // 结果页要借这一下清悬浮态（货架的翻页胶囊、鼠标下那张卡）。
        landingPage.pageDidDisappear()
        resultsPage.pageDidDisappear()
    }

    // viewDidAppear（§4.1.7）：nativeSearchField.stringValue 为空且窗口 firstResponder 不是字段
    // → 把焦点交回搜索框
    private func focusIfEmpty() {
        if model.query.isEmpty {
            binder.focus()
        }
    }

    /// 落地页 ↔ 结果页。两页都留在场上，只切 `isHidden`；显隐照样通知子页，
    /// 好让结果页清掉悬浮态、回来时恢复各货架的横滚位置。
    private func showLanding(_ landing: Bool) {
        guard isViewLoaded else { return }
        let appearing: ContentPageController = landing ? landingPage : resultsPage
        let disappearing: ContentPageController = landing ? resultsPage : landingPage
        guard appearing.view.isHidden || !disappearing.view.isHidden else { return }
        disappearing.view.isHidden = true
        disappearing.pageDidDisappear()
        appearing.view.isHidden = false
        appearing.pageDidAppear()
    }

    /// Esc（§2.3 cancelOperation:）：清词条回落地页。焦点在搜索框里时字段自己就吃了
    /// （见 `SearchPageFieldBinder`），这一条管的是焦点落在页面内容上的情形
    /// —— 旧 SwiftUI 版那句 `.onExitCommand`。整窗播放器开着时 Esc 归它，照旧往上冒泡。
    override func cancelOperation(_ sender: Any?) {
        guard !appState.showingNowPlaying else {
            amberNextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
            return
        }
        results.cancelSearch()
    }

    /// 范围分段控件。Music 的 `createSegmentedControlAccessory`（§4.1.1）——
    /// 资料库 tab 恒在，在线 tab 依赖可用音乐源，没有音乐源时整件不摆。
    private func makeScopeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard !appState.providerSettings.orderedEnabled.isEmpty else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let control = NSSegmentedControl(labels: SearchScopeTab.allCases.map(\.title),
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(scopeChanged(_:)))
        control.segmentStyle = .automatic
        control.selectedSegment = SearchScopeTab.allCases.firstIndex(of: model.scope) ?? 0
        item.view = control
        item.label = "搜索范围"
        item.paletteLabel = "搜索范围"
        control.setAccessibilityLabel("搜索范围")
        return item
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              sender.selectedSegment < SearchScopeTab.allCases.count else { return }
        let tab = SearchScopeTab.allCases[sender.selectedSegment]
        // Music 以「[tab名]」偏好串持久化默认 tab（§4.1.3 读取 / 写入）。
        UserDefaults.standard.set(tab.persistedKey, forKey: SearchScopeTab.defaultScopeKey)
        model.scope = tab
    }
}
