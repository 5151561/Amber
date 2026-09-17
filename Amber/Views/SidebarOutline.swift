import AppKit
import SwiftUI

// MARK: - 侧栏

/// 侧栏的骨架：**一张真的 NSOutlineView**，装在分栏控制器的 sidebar 项里。
///
/// Music 那一列（`SidebarOutlineModelController`）就是 NSOutlineView，选中由行视图自绘。
/// Amber 这边走过三版：
/// 1. `List` + 每行一个`Button` + 手绘选中底色——外观对了，但方向键在侧栏里走不动、
///    VoiceOver 报不出选中态、右键不预选中行；
/// 2. `List(selection:)`——语义全对（`AXOutline` + `AXRow`），但选中填充取 App 的
///    `AccentColor`（Amber 那份就是 Music 红），画出来是一整条实心红胶囊，行图标的红
///    还被选中前景色顶掉洗成白色。[实测 2026-09-05] `.tint(灰)` 挂在那个 List 上无效：
///    emphasized 的侧栏选中填充不吃 view tint，底色仍与相邻未选中行同值；
/// 3. NSOutlineView + `NSViewRepresentable` 宿主——语义与外观都对了，但整棵树还挂在
///    SwiftUI 底下，行内容要靠 `SidebarView.entries` 每次 body 重算再走`updateNSView`。
///
/// 现在是第四版：宿主壳去掉，直接是分栏的一列（design-ref/appkit-rewrite-plan.md 阶段 1）。
/// 行内容由这里订阅各 store 自己算（`TaskBag` + `Observations`；历史：原先是 Combine，
/// 剥离之后换成 `@Observable`），**像素一个不改**。
@MainActor
final class SidebarViewController: NSViewController {
    private typealias M = MusicMetrics.Sidebar

    private let appState: AppState
    private let controller: SidebarOutlineController
    private let outline = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let accountButton = NSButton()
    private let accountIcon = SidebarAccountAvatarView()
    /// 头像当前贴的是哪个地址：异步取图回来时对一下，换号后不会把上一个人的头像贴上去。
    private var accountAvatarURL: String?
    private let observers = TaskBag()

    init(appState: AppState) {
        self.appState = appState
        self.controller = SidebarOutlineController(appState: appState)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        outline.controller = controller
        outline.dataSource = controller
        outline.delegate = controller

        // 玻璃只有窗口根那一层（`NSVisualEffectView(material: .contentBackground)` 铺满整窗）。
        // 侧栏看着半透明是因为它**什么都不画**——自己糊 `.sidebar` / `.behindWindow` 材质是错的：
        // 窗口 `isOpaque == true`、采不到桌面，只会渲染成恒定浅灰（实测 #4E4D4B，
        // 而侧栏该是 #2A2B2C）。所以这里从滚动视图到表格全线不画背景。
        // 同理**不能**设 `style = .sourceList`：那会自己画一层 sidebar 材质，与窗口根那层叠起来颜色就错了。
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.intercellSpacing = .zero
        outline.rowSizeStyle = .custom
        outline.headerView = nil
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.indentationPerLevel = 0
        // 组标题不吸顶：Music 的组标题跟着内容一起滚（`home.json` 里它就是一条普通 AXRow）。
        outline.floatsGroupRows = false
        // 选中底色是 `SidebarRowView.drawSelection(in:)` 自绘的。
        // 这里必须留 `.regular`——覆盖`drawSelection(in:)` 是**替换**系统那一层，不是叠加；
        // 换成 `.none` 的话 AppKit 压根不再调`drawSelection`，胶囊就整个不画了。
        outline.selectionHighlightStyle = .regular
        // [AX] Music 的这棵树是 `AXOutline "边栏"`；NSOutlineView 自己不带标题。
        outline.setAccessibilityLabel("边栏")
        // 拖曲目到「心水歌曲」/ 可编辑的播放列表行上。落点反馈由行视图自绘（见 SidebarRowView）。
        outline.registerForDraggedTypes([TrackTransfer.pasteboardType])
        outline.draggingDestinationFeedbackStyle = .regular

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        // `outlineTableColumn` 是 ObjC 的 assign 属性，导进 Swift 是 `unowned(unsafe)`。
        // 全仓只此一处，按判据不做外壳：列由上一行的 `addTableColumn` 交给 outline 持有，
        // 指针跟着 outline 一起活。
        unsafe outline.outlineTableColumn = column

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // [AX] Music 与 Amber 的侧栏滚动区都正好从工具栏下沿起（Music `[0, 85, 202.5, 814]`），
        // 顶部没有额外内缩；交给 AppKit 自动加安全区内边距会把首行推下去。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        controller.outlineView = outline

        // 侧栏这一列的**初始宽度就是这个 frame 的宽**：`NSSplitViewController` 在没有
        // autosave 记录时按子控制器 view 的 frame 给首次厚度，这是系统自己的办法。
        // 上一版在 `MainSplitViewController.viewWillAppear` 里`setPosition` + 探
        // UserDefaults 键，[实测 2026-09-05] 侧栏仍是 180（= minimumThickness）——
        // 那时分栏还没排过版，setPosition 被随后的首次布局盖掉了。
        // [AX] 202.5 是 Music 的侧栏宽（滚动区 `[0, 85, 202.5, 814]`）。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: M.widthIdeal, height: 900))
        container.addSubview(scrollView)
        let account = makeAccountButton()
        container.addSubview(account)

        // [AX] 侧栏滚动区上到工具栏下沿 85（`safeAreaLayoutGuide` 顶端就是那条线：
        // 窗口是 fullSizeContentView，侧栏这一列铺满整窗，AppKit 把工具栏那 52pt
        // 记成安全区内边距），下到账号那一块**上面**收住（Music：滚动区 `[0, 85, 202.5, 814]`、
        // 账号组 `[0, 899, 202.5, 50]`），不是穿到底下去。
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: account.topAnchor),
            account.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            account.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            account.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            account.heightAnchor.constraint(equalToConstant: M.accountTop + M.accountSize + M.accountBottom),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadEntries()

        // 播放列表增删改名 → 侧栏「播放列表」组跟着变。
        // `entries` 回读 `library.playlists`。以前要回主队列一跳才读得到新值
        //（`@Published` 在 willSet 发布），现在 `Observations` 在值落定之后才发，
        // 那一跳不需要了。
        observers.observeNow({ [appState] in appState.library.playlists }) { [weak self] _ in
            self?.reloadEntries()
        }
        // 通用页「显示 › iTunes Store」：关掉时整组连同组标题一起消失（Music 同）。
        observers.observeNow({ AppSettings.shared.values.showITunesStore }) { [weak self] shown in
            guard let self else { return }
            // 选中项不能停在一个侧栏里已经不存在的页上（那样右边还显示着 iTunes Store，
            // 侧栏却没有一行是高亮的），退回主页。
            if !shown, self.appState.sidebarSelection == .store {
                self.appState.sidebarSelection = .home
            }
            self.reloadEntries()
        }
        // 外部改选中（工具栏「在当前音乐源中搜索」、上面那条退回主页……）→ 高亮跟着走。
        // **用推下来的值**。历史：Combine 的 `@Published` 在 willSet 发布，那一刻回读
        // `appState.sidebarSelection` 拿到的还是上一项，高亮就会永远慢一拍
        // （点主页再点新发现，亮的是主页）；换成 `Observations` 之后值已经落定，
        // 回读也对了，但推下来的那份仍是最短路径，照旧用它。
        observers.observe({ [appState] in appState.sidebarSelection }) { [weak self] selection in
            self?.reloadEntries(selection: selection)
        }
        // 账号那一行跟着登录态与账号资料翻（名字、头像）。
        // 两条都用 `observeNow`：原来没有 `dropFirst`，订阅当场就拿当前登录态刷一次账号行。
        observers.observeNow({ [weak appState] in appState?.qqLogin.credential }) { [weak self] _ in
            self?.updateAccount()
        }
        observers.observeNow({ [weak appState] in appState?.qqLogin.profile }) { [weak self] _ in
            self?.updateAccount()
        }
    }

    private func reloadEntries(selection: SidebarItem? = nil) {
        controller.update(entries: entries, selection: selection ?? appState.sidebarSelection)
    }

    /// 侧栏当前该有哪些行。顶部四行不分组；下面三组各带一条组标题。
    /// symbol 名与 SwiftUI 版的 `SidebarView.entries` 一个不改。
    private var entries: [SidebarEntry] {
        var rows: [SidebarEntry] = [
            .item(.search, symbol: "magnifyingglass"),
            .item(.home, symbol: "house"),
            .item(.discovery, symbol: "square.grid.2x2"),
            .item(.radio, symbol: "dot.radiowaves.left.and.right"),
            .group("资料库"),
            .item(.recentlyAdded, symbol: "clock"),
            .item(.artists, symbol: "music.mic"),
            .item(.albums, symbol: "square.stack"),
            .item(.songs, symbol: "music.note"),
        ]
        // 通用页「显示 › iTunes Store」：关掉时整组连同组标题一起消失，
        // 与 Music 一致（那边关掉后侧栏就没有「商店」这一段了）。
        if AppSettings.shared.values.showITunesStore {
            rows.append(.group("商店"))
            rows.append(.item(.store, symbol: "bag"))
        }
        rows.append(.group("播放列表"))
        rows.append(.item(.allPlaylists, symbol: "square.grid.3x3"))
        // Music 可以把选中的歌直接拖到边栏的行上。「心水歌曲」与可编辑的播放列表行都是落点，
        // 收歌的逻辑在 `SidebarOutlineController.accept(_:atRow:)`。
        rows.append(.item(.favorites, symbol: "heart.square"))
        // Music 把资料库里的每份播放列表逐条列在这一组下面，行图标是列表封面。
        rows.append(contentsOf: appState.library.playlists.map(SidebarEntry.playlist))
        return rows
    }

    // MARK: - 账号按钮

    /// 侧栏底部那颗账号按钮。它不是列表的一行，不进 outline view
    /// （[AX] Music 里它同样是分栏那一列里、滚动区之外的一个 `AXButton [18, 910, 73, 28]`）。
    /// 圆头像 + 一行文字，尺寸取 `MusicMetrics.Sidebar.account*`，与 SwiftUI 版同值。
    private func makeAccountButton() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        accountIcon.translatesAutoresizingMaskIntoConstraints = false

        accountButton.isBordered = false
        accountButton.bezelStyle = .inline
        accountButton.font = .systemFont(ofSize: 12)
        accountButton.contentTintColor = .labelColor
        accountButton.alignment = .left
        accountButton.target = self
        accountButton.action = #selector(showQQLogin)
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        updateAccount()

        container.addSubview(accountIcon)
        container.addSubview(accountButton)
        NSLayoutConstraint.activate([
            accountIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: M.accountLeading),
            accountIcon.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                constant: -M.accountBottom),
            accountIcon.widthAnchor.constraint(equalToConstant: M.accountSize),
            accountIcon.heightAnchor.constraint(equalToConstant: M.accountSize),
            accountButton.leadingAnchor.constraint(equalTo: accountIcon.trailingAnchor,
                                                   constant: M.accountSpacing),
            accountButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                    constant: -10),
            accountButton.centerYAnchor.constraint(equalTo: accountIcon.centerYAnchor),
        ])
        return container
    }

    /// 账号那一行显示的是**账号名**，不是登录状态词（Music 那颗按钮的 AX description
    /// 就是用户名本身）。资料还没拉回来（或这次没取到）时才退回状态词。
    private func updateAccount() {
        let profile = appState.qqLogin.profile
        accountButton.title = profile?.nickname
            ?? (appState.qqLogin.isLoggedIn ? "QQ 音乐已登录" : "登录 QQ 音乐")
        accountIcon.initial = profile?.nickname.first.map(String.init)
        loadAccountAvatar(profile?.avatarURL)
    }

    private func loadAccountAvatar(_ urlString: String?) {
        guard urlString != accountAvatarURL else { return }
        accountAvatarURL = urlString
        accountIcon.image = ImageCache.shared.memoryCachedImage(for: urlString)
        guard let urlString, accountIcon.image == nil else { return }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: urlString)
            // 回来时地址可能已经换人了（注销、换号），对不上就不贴。
            guard let self, self.accountAvatarURL == urlString else { return }
            self.accountIcon.image = image
        }
    }

    @objc private func showQQLogin() {
        appState.showingQQLogin = true
    }
}

// MARK: - 账号头像

/// 侧栏底部那枚圆头像：有头像图就按 aspect fill 裁进圆里，没有就画昵称首字（Music 同），
/// 连昵称都没有（未登录）才画人形占位。
///
/// **不能**拿 `NSImageView` 加`layer.cornerRadius` 来做这个圆：`NSImageView` 是`NSControl`，
/// 有非零的 `alignmentRectInsets`——约束落在对齐矩形上（28×28 是对的），frame 却被撑高，
/// [实测 -dumpviews 2026-09-08] 那一版是 `NSImageView [16, 878.5, 28, 32.5]`：
/// layer 跟着 frame 画，半径 14 的圆角落在 28×32.5 上就成了一枚椭圆，
/// 上下还各凸出容器 2.25pt。普通 `NSView` 的`alignmentRectInsets` 是零，自己画就不会走形。
@MainActor
final class SidebarAccountAvatarView: NSView {
    private typealias M = MusicMetrics.Sidebar

    /// 账号头像。nil 时按 `initial` 画占位。
    var image: NSImage? { didSet { needsDisplay = true } }
    /// 昵称首字（占位用）。
    var initial: String? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: M.accountSize, height: M.accountSize) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        if let image {
            NSGraphicsContext.saveGraphicsState()
            circle.setClip()
            // QQ 回的头像是方图（`s=140`），非方图按 aspect fill 居中裁，不留黑边。
            let scale = max(bounds.width / max(image.size.width, 1),
                            bounds.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        NSColor.systemBlue.withAlphaComponent(0.55).setFill()
        circle.fill()
        if let initial, !initial.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: bounds.height / 2),
                .foregroundColor: NSColor.white,
            ]
            let text = initial as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        } else if let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)
                .applying(.init(paletteColors: [.white]))) {
            person.draw(in: NSRect(x: bounds.midX - person.size.width / 2,
                                   y: bounds.midY - person.size.height / 2,
                                   width: person.size.width, height: person.size.height))
        }
    }
}

// MARK: - 行模型

/// 侧栏的一行。组标题也是一行（Music 的组标题在 AX 里同样是 `AXRow (AXOutlineRow)`）。
enum SidebarEntry: Hashable {
    /// 普通行：SF Symbol + 文字
    case item(SidebarItem, symbol: String)
    /// 播放列表行：图标槽换成列表封面
    case playlist(LibraryPlaylist)
    /// 组标题行，不可选中
    case group(String)

    var sidebarItem: SidebarItem? {
        switch self {
        case .item(let item, _): return item
        case .playlist(let playlist): return .playlist(id: playlist.id)
        case .group: return nil
        }
    }

    var title: String {
        switch self {
        case .item(let item, _): return item.title
        case .playlist(let playlist): return playlist.name
        case .group(let title): return title
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// NSOutlineView 的 item 必须是能按身份比对的对象（AppKit 内部拿 `isEqual:`/`hash` 认行），
/// Swift 的 enum 直接塞进 `Any` 过不去，包一层。
final class SidebarNode: NSObject {
    let entry: SidebarEntry

    init(_ entry: SidebarEntry) {
        self.entry = entry
        super.init()
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? SidebarNode)?.entry == entry
    }

    override var hash: Int { entry.hashValue }
}

// MARK: - 控制器

/// 数据源 + 代理 + 选中态双向同步。对应 Music 的 `SidebarOutlineModelController`。
@MainActor
final class SidebarOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private typealias M = MusicMetrics.Sidebar

    let appState: AppState
    weak var outlineView: SidebarOutlineView?

    private(set) var nodes: [SidebarNode] = []
    /// 我们自己往 outline view 上写选中时置位，免得代理回调把这一下再回灌进模型
    ///（照 `SongsTableController.isSyncing` 的写法）。
    private var isSyncing = false
    private var appliedEntries: [SidebarEntry] = []

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    // MARK: 同步

    func update(entries: [SidebarEntry], selection: SidebarItem?) {
        guard let outline = outlineView else { return }
        if entries != appliedEntries {
            appliedEntries = entries
            nodes = entries.map(SidebarNode.init)
            outline.reloadData()
        }
        syncSelection(selection)
    }

    /// 外部改 `sidebarSelection`（工具栏「在当前音乐源中搜索」、关掉 iTunes Store 后退回主页……）
    /// → 高亮跟着走。
    private func syncSelection(_ selection: SidebarItem?) {
        guard let outline = outlineView else { return }
        let target = selection.flatMap { item in
            nodes.firstIndex { $0.entry.sidebarItem == item }
        }
        let current = outline.selectedRow >= 0 ? outline.selectedRow : nil
        guard target != current else { return }
        isSyncing = true
        if let target {
            outline.selectRowIndexes([target], byExtendingSelection: false)
            // 可视区还没有高度时**不能**滚：装配那一趟 clip view 是 0 高的，
            // `scrollRowToVisible` 会把「让 0…32 这块可见」解成「把它的下沿对到 0 高视口的下沿」，
            // 于是整个内容被顶上去整整一行（[AX] 首行「搜索」跑到滚动区上沿之外的 y=65，
            // 而滚动区从 97 起）。有了高度之后这一句才是「必要时才滚」的原意。
            if (outline.enclosingScrollView?.contentView.bounds.height ?? 0) > 0 {
                outline.scrollRowToVisible(target)
            }
        } else {
            outline.deselectAll(nil)
        }
        isSyncing = false
    }

    func entry(atRow row: Int) -> SidebarEntry? {
        nodes.indices.contains(row) ? nodes[row].entry : nil
    }

    // MARK: 数据源

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? nodes.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    // MARK: 代理

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return M.rowHeight + M.rowVerticalInset * 2 }
        // 组标题上方那 13pt 空隙不属于任何一行（[AX] Music 的 AXRow 之间真有缝：
        // 广播行 148+32=180 →「资料库」组标题 193）。AppKit 的行是首尾相接的，
        // 只能把它算进组标题行的高度、内容压到下 19pt——像素与 Music 一致，
        // 代价是这三条组标题的 `AXRow` 高度报 32 而不是 19。
        // [AX] 试过在行视图里覆盖 `accessibilityFrame()` 把它改回 19：**无效**。
        // AXRow 不是 `NSTableRowView` 本身（在行视图上`setAccessibilityLabel` 也不会
        // 出现在 AXRow 的标题上），它的 frame 由表格按 `rect(ofRow:)` 现算。
        // 可选中的行仍是整 32 的行距，这一条只影响不可选中的组标题。
        return node.entry.isGroup
            ? M.groupTopSpacing + M.groupRowHeight
            : M.rowHeight + M.rowVerticalInset * 2
    }

    /// 组标题行不可选中。方向键会自己跳过去（NSTableView 的键盘导航也问这一条）。
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        ((item as? SidebarNode)?.entry.isGroup ?? true) == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.entry.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let entry = (item as? SidebarNode)?.entry
        let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
        let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView
            ?? {
                let fresh = SidebarRowView()
                fresh.identifier = identifier
                return fresh
            }()
        // 行视图是复用的，装到别的行上之前得把上一次的角色重置掉。
        view.isGroupContent = entry?.isGroup ?? false
        view.setAccessibilityLabel(entry?.title)
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let entry = (item as? SidebarNode)?.entry else { return nil }
        switch entry {
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("SidebarGroup")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarGroupCellView
                ?? {
                    let fresh = SidebarGroupCellView()
                    fresh.identifier = identifier
                    return fresh
                }()
            view.configure(title: title)
            return view
        case .item(let item, let symbol):
            let identifier = NSUserInterfaceItemIdentifier("SidebarItem")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarItemCellView
                ?? {
                    let fresh = SidebarItemCellView()
                    fresh.identifier = identifier
                    return fresh
                }()
            view.configure(title: item.title, symbol: symbol)
            return view
        case .playlist(let playlist):
            let identifier = NSUserInterfaceItemIdentifier("SidebarPlaylist")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarPlaylistCellView
                ?? {
                    let fresh = SidebarPlaylistCellView()
                    fresh.identifier = identifier
                    return fresh
                }()
            view.configure(playlist: playlist)
            return view
        }
    }

    /// 用户点行 / 按方向键 → 写回 `sidebarSelection`。
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let outline = outlineView else { return }
        guard let item = entry(atRow: outline.selectedRow)?.sidebarItem else { return }
        guard appState.sidebarSelection != item else { return }
        appState.sidebarSelection = item
    }

    // MARK: 右键菜单

    /// 只有播放列表行有菜单（照原先挂在行上的 `.contextMenu { LibraryPlaylistMenu }`）。
    /// 菜单现搭一份 `NSMenu`，先例见`SongsTableController.rowMenu(for:)`。
    func rowMenu(atRow row: Int) -> NSMenu? {
        guard case .playlist(let playlist) = entry(atRow: row) else { return nil }
        return NSHostingMenu(rootView: LibraryPlaylistMenu(playlist: playlist)
            .environment(appState)
            .environment(appState.library))
    }

    // MARK: 拖入落点

    /// 这一行接不接曲目。Music 支持把选中的歌直接丢到侧栏的行上；
    /// 只有 Amber 自建的列表能收，账号同步来的是只读镜像（Amber 没有写回音源的能力）。
    func acceptsTracks(atRow row: Int) -> Bool {
        switch entry(atRow: row) {
        case .item(.favorites, _): return true
        case .playlist(let playlist): return playlist.isEditable
        default: return false
        }
    }

    /// 返回 false 表示这一批没有实际落进去（比如全都已经心水过了）。
    private func accept(_ tracks: [Track], atRow row: Int) -> Bool {
        switch entry(atRow: row) {
        case .item(.favorites, _):
            // 已经心水的跳过——拖同一批两次不该把它们取消掉。
            let added = tracks.filter { !appState.library.isFavorite($0) }
            guard !added.isEmpty else { return false }
            for track in added { appState.library.toggleFavorite(track) }
            appState.showToast(added.count > 1 ? "已心水 \(added.count) 首" : "已心水")
            return true
        case .playlist(let playlist) where playlist.isEditable:
            // 撞重先问一句（spec §10.4 第二条链，见 `PlaylistDuplicateAlert`）。
            // 这里照旧返回 true：拖放这一下**已经被接住了**，问句是接住之后的事；
            // 返回值等的是「落点收不收」，不能拿它去等一张 sheet 的答复。
            PlaylistDuplicateAlert.addTracks(tracks, to: playlist, library: appState.library,
                                             in: outlineView?.amberWindow) { [appState] added in
                guard added > 0 else { return }
                appState.showToast("已加入「\(playlist.name)」")
            }
            return true
        default:
            return false
        }
    }

    /// 侧栏永远是「落在这一行上」，不存在行间插入。AppKit 对平铺的 outline 默认会提
    /// 「插到第 N 个孩子前面」，所以这里自己按光标位置把落点改钉到那一行。
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let point = outlineView.convert(info.draggingLocation, from: nil)
        let row = outlineView.row(at: point)
        guard row >= 0, acceptsTracks(atRow: row), nodes.indices.contains(row) else { return [] }
        outlineView.setDropItem(nodes[row], dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? SidebarNode, let row = nodes.firstIndex(of: node) else { return false }
        let tracks = (info.draggingPasteboard.pasteboardItems ?? []).flatMap { item -> [Track] in
            guard let data = item.data(forType: TrackTransfer.pasteboardType),
                  let payload = try? JSONDecoder().decode(TrackTransfer.self, from: data)
            else { return [] }
            return payload.tracks
        }
        guard !tracks.isEmpty else { return false }
        return accept(tracks, atRow: row)
    }
}

// MARK: - 表格

/// 右键预选 + 窗口激活态跟随。
final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarOutlineController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 选中胶囊分激活/未激活两档（见 SidebarRowView.drawSelection）。
        // 窗口 key 状态变了 AppKit 不会替我们把行标脏——它只管系统自己那层高亮。
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowKeyStateChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func windowKeyStateChanged(_ note: Notification) {
        guard let window = amberWindow, (note.object as? NSWindow) === window else { return }
        enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    /// 右键**先把那一行选中**（Music 的语义是「菜单只作用于被点的那一行」；侧栏是单选，
    /// 所以直接选中即可）。原先 SwiftUI 的 `Button` + `.contextMenu` 做不到这件事。
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, let controller, let entry = controller.entry(atRow: row),
              !entry.isGroup else { return nil }
        if selectedRow != row {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return controller.rowMenu(atRow: row)
    }
}

// MARK: - 行视图

/// 选中胶囊与拖入落点反馈都在这儿自绘——这一手正是这次换骨架要保住的外观。
final class SidebarRowView: NSTableRowView {
    private typealias M = MusicMetrics.Sidebar

    /// 组标题行：不画胶囊，AX 也只报下 19pt（顶上 13pt 是组间空隙）。
    var isGroupContent = false {
        didSet {
            guard isGroupContent != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 胶囊矩形。[AX] Music `home.json`：`AXCell [10, y, 182.5, 32]`（侧栏 202.5），
    /// [PX] `home.png` 主页那一行实测胶囊 x 10.0 → 192.5、y 85…115（行 84…116，上下各 1）。
    private var capsuleRect: NSRect {
        bounds.insetBy(dx: M.capsuleInset, dy: M.rowVerticalInset)
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    /// **选中不改内容色**。默认实现在选中时把这一档报成 `.emphasized`，
    /// `NSTableCellView` 收到之后会把图标和文字整体翻成白色——[PX] 实测就是这一下
    /// 把行图标的红洗成了 rgb(255,255,255)。
    /// Music 那条选中胶囊是压在侧栏底色上的**中性灰**，底上内容一个都不翻：
    /// [PX] `home.png` 主页那一行（选中）图标仍是 rgb(255,90,118)，文字仍是`.textColor`。
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// 组标题行也会被 AppKit 当成「group row」问一次背景，默认实现会糊一层组底色；
    /// 侧栏什么都不该画（玻璃在窗口根那一层），整个按住。
    override func drawBackground(in dirtyRect: NSRect) {}

    /// 选中底色：**中性灰**压在侧栏底色上，不是 accent。
    /// 激活/未激活按**窗口的 key 状态**分档，而不是 `isEmphasized`——后者在焦点移到右侧
    /// 内容表格时也会变 false，胶囊会跟着变淡，而 Music 的侧栏选中条只随窗口进出前台变化。
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, !isGroupContent else { return }
        let active = amberWindow?.isKeyWindow ?? false
        let fill: NSColor = active ? .amberSidebarSelection : .amberSidebarSelectionInactive
        let path = NSBezierPath(roundedRect: capsuleRect,
                                xRadius: M.rowCornerRadius, yRadius: M.rowCornerRadius)
        fill.setFill()
        path.fill()
    }

    /// 拖入落点反馈：沿用原先 `SidebarTrackDrop` 的样子——胶囊那一圈描 2pt 品牌色边。
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        let inset = M.dropBorderWidth / 2
        let path = NSBezierPath(roundedRect: capsuleRect.insetBy(dx: inset, dy: inset),
                                xRadius: M.rowCornerRadius, yRadius: M.rowCornerRadius)
        path.lineWidth = M.dropBorderWidth
        // `Color.amberKey` 是四档`bestMatch`（浅/深 × 普通/增强对比）的动态色，
        // 直接转成 NSColor 仍是动态的，不必在 MusicColors 那边再复制一份。
        NSColor(Color.amberKey).setStroke()
        path.stroke()
    }

}

// MARK: - 行内容

/// 普通行：SF Symbol + 文字。
///
/// **纯 AppKit**（NSImageView + NSTextField），不套 `NSHostingView`：侧栏就二十来行、
/// 结构固定，一行一个 SwiftUI 宿主只是白背一份宿主开销，而这一行要的东西
///（一个居中的符号 + 一行按尾部截断的文字）AppKit 原生就有。
/// 播放列表行的封面从前是唯一的例外（一棵 `ArtworkView`），现在也照这条办了
/// （见 `SidebarArtworkView`）——整份侧栏零 `NSHostingView`。
class SidebarItemCellView: NSTableCellView {
    fileprivate typealias M = MusicMetrics.Sidebar

    fileprivate let symbolView = NSImageView()
    fileprivate let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbolView.imageScaling = .scaleNone
        symbolView.imageAlignment = .alignCenter
        // 图标选中时**也是红的**：Music `home.png` 主页那一行（选中）图标实测仍是
        // rgb(255,90,118)，没有被选中前景色顶掉。
        symbolView.contentTintColor = .amberSidebarAccent
        addSubview(symbolView)

        label.font = .systemFont(ofSize: M.rowFontSize)
        // [PX] Music 选中行的文字与未选中行同色（都是 .textColor，深色下白）——
        // 中性灰底不需要翻白，写死 accent 底那套「选中翻白」反而会与 Music 不一致。
        label.textColor = .textColor
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        amberTextField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: M.iconPointSize, weight: .regular)
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        symbolView.isHidden = false
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    override func layout() {
        super.layout()
        layoutSlots(iconView: symbolView)
    }

    /// 图标槽 + 文字槽的排布。两个数都是 [AX] Music `home.json` 的实测值：
    /// - 图标 `AXImage` 的 x 随符号宽窄在 24.5…30 之间浮动，但 [PX] 十一个符号的**墨迹中心**
    ///   一律落在 37.5（±0.25），说明符号是**居中**在一个固定槽里的，不是左对齐。
    ///   槽起点 `capsuleInset + rowContentLeading = 25`、宽`iconSlotWidth = 25`，中心正是 37.5。
    /// - 文字 `AXStaticText [54, y, 131.5, 18]`：左沿 54、右沿距胶囊右沿 7。
    fileprivate func layoutSlots(iconView: NSView) {
        let slotX = M.capsuleInset + M.rowContentLeading
        // 图标视图比名义槽两边各宽一点，只为不剪裁宽符号；中心仍是 slotX + iconSlotWidth/2 = 37.5。
        iconView.frame = NSRect(x: slotX - M.iconSlotOverflow, y: 0,
                                width: M.iconSlotWidth + M.iconSlotOverflow * 2,
                                height: bounds.height)
        let right = max(slotX + M.iconSlotWidth,
                        bounds.width - M.capsuleInset - M.textTrailing)
        // 文本框按自身行高居中摆，而不是撑满行高——NSTextFieldCell 的单行文字在过高的
        // 框里是**顶对齐**的，撑满会让文字整体上移。
        // x 直接就是 [AX] 的 54：Music 那条 `AXStaticText` 就是它的`NSTextField` 的 frame，
        // 两边是同一种控件，不需要再补墨迹偏移（原先的 `labelInkInset` 是 SwiftUI 时代
        // 拿 Text 凑 NSTextField 墨迹位置用的，已删）。
        let height = label.fittingSize.height
        label.frame = NSRect(x: M.textLeading,
                             y: ((bounds.height - height) / 2).rounded(),
                             width: right - M.textLeading,
                             height: height)
    }
}

/// 播放列表行：图标槽换成列表封面。
///
/// 历史：这一格从前是全侧栏唯一的 `NSHostingView`（里面一棵`ArtworkView`），而且
/// **每换一个地址就 `removeFromSuperview` + 新建一棵 SwiftUI 树**——19pt 的一个方块背一份
/// 宿主、复用一次重建一次，正是铁律 2 要躲的那件事。现在换成`SidebarArtworkView`：
/// 换图不换视图，像素照 `ArtworkView` 逐条搬。
final class SidebarPlaylistCellView: SidebarItemCellView {
    private let artworkSlot = NSView()
    private let artworkView = SidebarArtworkView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 这一类行没有 SF Symbol，父类那个图标视图整个让位给封面槽。
        symbolView.isHidden = true
        artworkSlot.addSubview(artworkView)
        addSubview(artworkSlot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(playlist: LibraryPlaylist) {
        label.stringValue = playlist.name
        setAccessibilityLabel(playlist.name)
        artworkView.setArtwork(url: playlist.artworkURL)
    }

    override func layout() {
        super.layout()
        layoutSlots(iconView: artworkSlot)
        // 封面在图标槽里居中（[PX] 旧版实测封面 19pt 方块、中心与符号槽同心）。
        let size = M.playlistArtworkSize
        artworkView.frame = NSRect(x: (artworkSlot.bounds.width - size) / 2,
                                   y: (artworkSlot.bounds.height - size) / 2,
                                   width: size, height: size)
    }
}

/// 侧栏播放列表行那一格 19pt 的封面：`CALayer` 贴图 + 没图时的渐变占位。
///
/// 是 `Catalog/CatalogArtworkView` 的最小版——只留侧栏用得到的两层（占位渐变、封面），
/// 悬浮暗罩与可读性渐变不要。像素照旧版 `ArtworkView` 逐条搬，一个数都没改：
/// - 贴图 `resizeAspectFill` ＝ 旧版的 `scaledToFill` +`.clipped()`；
/// - 占位是 `amberKey 0.85 → amberPurple 0.55` 的 topLeading→bottomTrailing 渐变，
///   上面一枚白 0.75 的 `music.note`，字号照旧版的`.title2`（实测 17，与
///   `CatalogArtworkView` 的`loadingGlyphSize` 默认值同源）；
/// - 圆角 `playlistArtworkRadius`，`cornerCurve = .continuous` ＝ 旧版
///   `RoundedRectangle(style: .continuous)` 那只 squircle。
///
/// 取图走 `ImageCache`，与`Catalog/CatalogCardItems.swift` 的封面块同一套：
/// **先查内存缓存同步贴**（不然每次上屏必白一帧），没命中才起 `Task`；
/// 晚到的图用 `requestToken` 认主（地址里有 nil，光比地址分不出「这次的 nil」
/// 和「上一次的 nil」）。行是复用的，这两条缺一不可。
final class SidebarArtworkView: NSView {
    private typealias M = MusicMetrics.Sidebar

    private let placeholder = CAGradientLayer()
    private let artwork = CALayer()
    private let glyph = NSImageView()

    private var loadTask: Task<Void, Never>?
    private var requestedURL: String?
    /// 请求序号，只增不减。
    private var requestToken: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = M.playlistArtworkRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        placeholder.colors = [NSColor(Color.amberKey).withAlphaComponent(0.85).cgColor,
                              NSColor(Color.amberPurple).withAlphaComponent(0.55).cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 1)   // topLeading
        placeholder.endPoint = CGPoint(x: 1, y: 0)     // bottomTrailing
        layer?.addSublayer(placeholder)

        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.isHidden = true
        layer?.addSublayer(artwork)

        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        glyph.contentTintColor = NSColor(white: 1, alpha: 0.75)
        glyph.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.glyphSize, weight: .regular))
        addSubview(glyph)
    }

    /// 占位上那枚音符的字号。旧版 `ArtworkView` 给的是`.title2`，
    /// 铁律 6：这个数系统自己就有，直接问它，实测值（17）只当验收标尺。
    private static let glyphSize = NSFont.preferredFont(forTextStyle: .title2).pointSize

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 这一格只是装饰，点击整行要接得住（与 `CatalogArtworkView` 同一条）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CatalogCardKit.setFrame(placeholder, bounds)
        CatalogCardKit.setFrame(artwork, bounds)
        glyph.frame = bounds
    }

    func setArtwork(url: String?) {
        // 与旧版 `ArtworkView(points:)` 同一句：按尺寸挑地址，缓存键跟着一起变。
        let request = ArtworkSize.url(url, points: M.playlistArtworkSize)
        // 「没有封面」这一路必须每次都走到底：行是复用的，`nil == nil` 认作「没变」
        // 就直接 return 的话，上一份歌单的封面会原样留在层上。
        guard request != requestedURL || request == nil else { return }
        requestedURL = request
        requestToken &+= 1
        let token = requestToken
        loadTask?.cancel()
        loadTask = nil
        guard let request else { showArtwork(nil); return }
        if let cached = ImageCache.shared.memoryCachedImage(for: request) {
            showArtwork(cached)
            return
        }
        showArtwork(nil)
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.image(for: request)
            guard let self, !Task.isCancelled, self.requestToken == token, let image else { return }
            self.showArtwork(image)
        }
    }

    /// nil ＝ 回到占位。贴图不走隐式动画：行是复用的，淡入会变成「上一张淡出成这一张」。
    private func showArtwork(_ image: NSImage?) {
        // 贴给层的是 CGImage：`contents` 收下`NSImage` 时 AppKit 会在提交那一刻按本层的
        // 尺寸／倍率重画一遍（理由见 `ImageCache.decode` 的头注）。
        let contents: Any?
        if let cgImage = image?.amberCGImage {
            contents = cgImage
        } else {
            contents = image
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.contents = contents
        artwork.isHidden = image == nil
        placeholder.isHidden = image != nil
        CATransaction.commit()
        glyph.isHidden = image != nil
    }
}

/// 组标题行。
final class SidebarGroupCellView: NSTableCellView {
    private typealias M = MusicMetrics.Sidebar

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: M.groupFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)
        amberTextField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    /// 坐标系钉死成未翻转，下面那句「内容压在视觉下方」才有确定含义。
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        // 内容压在**视觉下方**那 19pt：上面那 13pt 是组间空隙（见 heightOfRowByItem）。
        // [AX] Music 组标题文字 `[15, y+1.5, …, 16]`，即在 19pt 行里垂直居中。
        let height = label.fittingSize.height
        label.frame = NSRect(x: M.groupTextLeading,
                             y: (M.groupRowHeight - height) / 2,
                             width: max(0, bounds.width - M.groupTextLeading - M.capsuleInset),
                             height: height)
    }
}
