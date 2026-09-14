import AppKit
import Combine

/// 主窗。Amber 是单窗 App（Music 也是），所以这一份由 AppDelegate 持有，不做多开。
///
/// 窗口形态照 Music：`fullSizeContentView` + unified 工具栏，内容（含侧栏与面板）
/// 铺到窗顶；**标题栏照系统默认画自己的背景**，滚上来的内容被它挡住。
///
/// 这里原先写着 `titlebarAppearsTransparent = true`，那是抄错的：`NSWindow.h` 对这一位的
/// 原话是「the titlebar doesn't draw its background, allowing all buttons to show through」。
/// Music 不是这样——`design-ref/ui-spec/pages/songs.png` 顶上那一条工具栏是不透明的，
/// 列头紧贴在它下面，滚动的曲目行看不见。
///
/// [实测 probe] 2026-09-07（独立探针，`fullSizeContentView` + `.unified` + 一张 30pt
/// 红绿交替行的 `NSTableView`，滚到中段后`screencapture` 取窗口区域读像素）：
/// - `= true`：x=700 那一列从 y=0 一路到 y=130 都是同一套锐利条纹
///   （y0…20 绿 (0.51,0.97,0.37)、y22…50 红 (0.94,0.29,0.18)、y52…80 又是绿），
///   即**标题栏那 52pt 里就是内容本身**，红绿灯与搜索框直接压在曲目行上；
/// - `= false`：y0…50 变成一条被糊开的过渡带（(0.40,0.52,0.25) → (0.59,0.30,0.23)，
///   看不出行边界），y=52 才「啪」一下跳回锐利的绿 (0.51,0.97,0.37)——
///   标题栏画了背景，行被挡住，下沿正好落在 52。
/// 视图树上也对得起来：`NSTitlebarContainerView` 底下的`NSTitlebarBackgroundView`
/// `[0, 848, 1440, 52]` 在`= true` 时是 **HIDDEN**，`= false` 时在。
///
/// 关掉这一位**不动任何几何**（同一份探针两种取值逐条对过）：`contentLayoutRect`
/// 仍是 `[0, 0, 1440, 848]`、红绿灯仍在 (19,19)、`NSToolbarView` 仍是
/// `[0, 848, 1440, 52]`；`NSSplitViewItem(sidebarWithViewController:)` +
/// `allowsFullHeightLayout = true` 的侧栏仍是`[0, 0, 202.5, 900]`，照旧铺到窗顶。
///
/// **红绿灯始终在，不用占位项。** 旧 SwiftUI 版要在工具栏里留一件 1pt 的透明占位，
/// 因为 `.toolbar(.hidden)` 会把红绿灯一起收掉；AppKit 没有这回事：
/// [实测 2026-09-05] 把所有工具栏项摘光之后，`contentLayoutRect` 高仍是 848、
/// 红绿灯仍在 (19,19)、工具栏仍是 52 —— 标题栏不会塌。占位项已删。
/// 「播放中」时页面项的让位走 `NSToolbarItem.isHidden`（macOS 15+），件还在、只是不显示。
@MainActor
final class MainWindowController: NSWindowController {

    private let appState: AppState
    private let rootViewController: RootViewController
    private var cancellables = Set<AnyCancellable>()
    private var currentIdentifiers: [NSToolbarItem.Identifier] = []
    private weak var currentTopPage: ContentPageController?

    var splitViewController: MainSplitViewController? { rootViewController.splitViewController }
    private var navigation: ContentNavigationController? {
        rootViewController.splitViewController.navigationController
    }

    init(appState: AppState) {
        self.appState = appState
        self.rootViewController = RootViewController(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = rootViewController
        // ⌘W 只是关窗、不退出（见 `applicationShouldTerminateAfterLastWindowClosed`），
        // 所以这扇窗关掉之后必须还在：程序坞点一下由 `applicationShouldHandleReopen`
        // 拿这同一份 controller 重新 `showWindow`。代码建的 NSWindow 默认是 true。
        window.isReleasedWhenClosed = false
        // `titlebarAppearsTransparent` 保持系统默认（false）＝标题栏自己画背景，见类型注释。
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // 拖窗口背景可移动窗口。
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1000, height: 640)
        // 像素级校准基线与 Music.app 对照窗口一致；窗口仍可自由缩放。
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        super.init(window: window)
        window.setFrameAutosaveName("AmberMainWindow")

        let toolbar = NSToolbar(identifier: "AmberMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar

        navigation?.onStackChanged = { [weak self] in self?.rebuildToolbar() }
        // 「播放中」展开时页面项全部让位（Music 那时工具栏是空的），红绿灯照旧。
        // 用推来的值，不回读属性：`@Published` 在 willSet 发布，回读拿到的是上一次的值，
        // 开合一次之后工具栏的显隐就整个反过来。
        appState.$showingNowPlaying
            .removeDuplicates()
            .sink { [weak self] showing in self?.applyToolbarVisibility(hidden: showing) }
            .store(in: &cancellables)
        rebuildToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 工具栏内容

    /// 当前该摆哪些件 = 返回键（栈深 >1 才有）+ 栈顶那一页要的 + 那一页自己要的分享/更多
    /// + 末尾那件跟踪分隔件。
    /// 一件都不摆也没关系：[实测] 空工具栏不会让标题栏塌（见类型注释）。
    ///
    /// **右端那两件按页问，不按栈深判。** 曾经整段挂在 `canGoBack` 上，于是侧栏点开的
    /// 歌单（栈深 1）右端空空如也。[AX] `design-ref/ui-spec/pages/*.json` 实测：
    ///
    /// | 页（json） | 返回 | 共享 | 更多 | 其它 |
    /// | --- | --- | --- | --- | --- |
    /// | `playlist-detail` | 有 206.5 | 有 1388 | 有 1424 | — |
    /// | `album-detail` | 有 206.5 | 有 1171 | 有 1207 | 搜索 1255 |
    /// | `catalog-artist` | 有 206.5 | 有 1388 | 有 1424 | — |
    /// | `favorite-songs` | **无** | 无 | **有 1170** | 排序 1206、搜索 1255 |
    /// | `library-artist-detail` | **有 206.5** | **无** | **无** | 排序 1208、搜索 1255 |
    /// | `all-playlists`/`albums`/`artists`/`recently-added`/`songs` | 无 | 无 | 无 | 排序 + 搜索 |
    ///
    /// 后两行把「按栈深」钉死：心水歌曲没有返回键却有「更多」，
    /// 资料库艺人详情有返回键却两件都没有。判据见 `ContentPageToolbarProviding`
    /// 的 `pageShowsToolbarActions`（[实测] §10.1，Music 那边同样是工具条模型上一个
    /// 独立布尔，macOS 27 / 26A5425a 基线）。
    private func makeIdentifiers() -> [NSToolbarItem.Identifier] {
        guard let navigation else { return [] }
        var ids: [NSToolbarItem.Identifier] = []
        if navigation.canGoBack { ids.append(.amberBack) }
        ids += navigation.top?.pageToolbarItemIdentifiers ?? []
        // 没有可分享的东西就不摆这一件（本地导入的专辑、Amber 自己建的列表、心水歌曲
        // 都没有网页版那一页）——与菜单里那条「分享」的取舍一致（`MenuSpec` 的禁用即隐藏）。
        let showsShare = !(navigation.top?.pageShareItems.isEmpty ?? true)
        let showsMore = navigation.top?.pageShowsToolbarActions == true
        // 排在这两件右边的那一组（筛选与排序 ☰、页内搜索框）——顺序照 [AX]：
        // 共享 → 更多 → 排序选项 → 搜索（`favorite-songs` 1170/1206/1255）。
        let trailing = navigation.top?.pageToolbarTrailingItemIdentifiers ?? []
        if showsShare || showsMore || !trailing.isEmpty {
            // 弹性空位只在右端真要摆件时才插：什么都不摆的根页（网格页那种）平白多一个
            // 弹性空位，会把它自己那几件推到最右去。
            ids.append(.flexibleSpace)
            if showsShare { ids.append(.amberShare) }
            if showsMore { ids.append(.amberMore) }
            ids += trailing
        }
        // 跟踪分隔件必须排在**所有**页面件之后：它就是内容列那一区的右边界。
        ids.append(.amberPanelSeparator)
        return ids
    }

    /// 页面项的**内容**变了（比如设置里多开了一个音乐源、切换胶囊该出现了）但标识符
    /// 没变：强制拆了重造一遍。
    func refreshPageToolbar() {
        currentIdentifiers = []
        currentTopPage = nil
        rebuildToolbar()
    }

    private func rebuildToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let ids = makeIdentifiers()
        let topPage = navigation?.top
        guard ids != currentIdentifiers || topPage !== currentTopPage else {
            applyToolbarVisibility()
            return
        }
        currentIdentifiers = ids
        currentTopPage = topPage
        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: toolbar.items.count - 1)
        }
        for id in ids {
            // 插入位置取**当前真实件数**，不是循环下标：`itemForItemIdentifier` 允许返回 nil
            // （例如只启用了一个音乐源时 `.amberProvider` 整件不摆，见 CatalogPageViewController），
            // 那一件不会进 `_currentItems`，下标就此比件数多出一。以前这类 nil 恰好都排在末位
            // （index == count，边界内）所以没暴露；末尾加了跟踪分隔件之后就越界，
            // `-[NSToolbar _forceInsertItem:atIndex:]` 抛断言
            // 「Invalid parameter not satisfying: index>=0 && index<=[_currentItems count]」，
            // 而它是在 `applicationDidFinishLaunching` 里抛的——AppKit 顶层把异常吞掉，
            // 于是菜单栏建好了、`showWindow` 那一句再也没执行到：**整个界面一扇窗都不出**。
            // [实测 lldb 2026-09-07] `breakpoint set -E objc` 停在 rebuildToolbar，
            // `ids = [flexibleSpace, am.provider, am.panel-separator]`、`index = 2`，
            // 而此时 toolbar 只有 1 件。
            toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
        }
        applyToolbarVisibility()
    }

    /// 「播放中」是整窗覆盖，而工具栏由 AppKit 画在它之上，页面项会穿帮。
    /// `NSToolbarItem.isHidden`（macOS 15+）正是为这件事准备的：件还在、只是不显示，
    /// 红绿灯与标题栏高度都不受影响。
    ///
    /// 跟踪分隔件是唯一的例外：它**不画任何东西**（[实测 probe] 2026-09-07，见
    /// `itemForItemIdentifier` 里的记录），藏不藏都看不出来，但一藏一放就是一次
    /// 跟踪约束的拆装，「播放中」开合会把前面那些件的 x 抖一下。所以让它一直在。
    private func applyToolbarVisibility(hidden: Bool? = nil) {
        guard let toolbar = window?.toolbar else { return }
        let hidden = hidden ?? appState.showingNowPlaying
        for item in toolbar.items where item.itemIdentifier != .amberPanelSeparator {
            item.isHidden = hidden
        }
        // 「播放中」是**整窗**覆盖（`NowPlayingHostController.layoutInHost` 把它铺成窗口
        // 那么大，`fullSizeContentView` 之下就一直盖到窗顶）。标题栏平时要画背景挡住滚上来
        // 的内容（见类型注释），但盖着整窗播放器的这一段不能画——否则它顶上会横一条 52pt
        // 的模糊带。件能靠 `isHidden` 让位，背景不能，只能把这一位跟着切。
        // Music 那一屏 design-ref 里没有截图/AX 可比对，这条是按「覆盖层要干净」定的。
        window?.titlebarAppearsTransparent = hidden
    }

    // MARK: - 窗口级命令

    @objc private func goBack(_ sender: Any?) {
        navigation?.pop()
    }

    @objc private func searchInCurrentProvider(_ sender: Any?) {
        appState.sidebarSelection = .search
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        currentIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.amberBack, .amberPageTitle, .amberFilter, .amberSearch, .amberSearchCenter, .amberSearchScope,
         .amberProvider, .amberShare, .amberMore, .amberPanelSeparator, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .amberBack:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "chevron.backward",
                                 accessibilityDescription: "返回")
            item.label = "返回"
            item.paletteLabel = "返回"
            item.toolTip = "返回"
            item.target = self
            item.action = #selector(goBack(_:))
            // [AX] Music 的返回键落在 `[206.5, 33, 40, 52]`，即内容列左沿 +4。
            // `isNavigational` 就是让 AppKit 把它排进左侧导航区、跟着侧栏边界对齐的那一位。
            item.isNavigational = true
            return item

        case .amberShare:
            // **共享走 AppKit 自己那件**（`NSSharingServicePickerToolbarItem`），不是右键菜单里
            // 那条自列服务的「分享 ▸」：工具栏上有可锚的矩形，系统共享面板就从这颗键底下弹出来，
            // 项集、排序、「更多…」那一条都归系统管。右键菜单没有锚点才必须自列
            // （原委见 `MenuSpec.shareEntry` 的头注）。
            //
            // 分享什么由栈顶那一页给（`pageShareItems`），点下去的那一刻才问——
            // 页面还在加载时先给出 route 里那个对象的链接，不用等接口回来。
            // 图标、标题（[AX] Music 也是「共享」）、AX 角色都用系统默认，不另写。
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            return item

        case .amberMore:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
            item.label = "更多"
            item.paletteLabel = "更多"
            item.toolTip = "更多"
            item.showsIndicator = false
            // 内容每次弹之前现造（`menuNeedsUpdate:`）：栈顶那一页的菜单跟着资料库状态变，
            // 建件那一刻的快照活不到用户点它的时候。
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item

        case .amberPanelSeparator:
            // 页面那几件是排在**内容列**里的，不是排在整扇窗里：
            // [AX] Music 的「排序选项」`AXMenuButton` 在`songs.json`（无面板）是 x=1208，
            // 在 `lyrics-panel.json` / `queue-panel.json`（面板开）是 x=951.5——差 256.5，
            // 正好是面板列（`[1212, 33, 258, 923]`）连它那条分栏线（`[1211.5, 85, 0.5, 871]`）。
            // `NSTrackingSeparatorToolbarItem`（macOS 11+）就是干这个的：把它排在所有页面件
            // 之后，AppKit 会把前面那些件关进 `dividerIndex` 左边那一区。
            //
            // [实测 probe] 2026-09-07（独立探针，同构的三列 `NSSplitViewController`，
            // 窗口内容 1440×900、面板列 258）：
            // - 不加这一件：面板收起时搜索件在 x=1221，展开后**还是** 1221（钉在窗右沿，
            //   压在面板上面）——这正是 Amber 现在的毛病；
            // - 加了这一件：收起 1220 → 展开 964（Δ=256，与 Music 的 Δ256.5 同一回事，
            //   差的 0.5 是两边窗宽 1440 / 1470 的半像素分栏线）→ 再收起回到 1220。
            //
            // **它不画线。** Music 那条也没有（`lyrics-panel.png` 右上角工具栏背景左右连成
            // 一片、边界处没有竖分隔线），所以这一点是采用前的硬条件。真截图逐点扫过
            // （标题栏带 y=26，x∈[1170,1195]）：加与不加两次的亮度序列**一模一样**——
            // 1181.5 之前 0.42x（内容列），1182 起 0.210（面板列），没有任何额外的亮线暗线；
            // 与同一张图内容区那条（y=200）的台阶也完全同形。视图树上同样干净：
            // `NSToolbarView` 底下只有`NSGlassContainerView`，没有多出任何 separator 视图。
            guard let split = splitViewController else { return nil }
            // 三列（侧栏 | 内容 | 面板）→ 分隔线 0 是侧栏那条、1 是面板那条。
            let dividerIndex = split.splitViewItems.count - 2
            guard dividerIndex >= 0 else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier,
                                                  splitView: split.splitView,
                                                  dividerIndex: dividerIndex)

        default:
            // 页面自己的件由栈顶那一页造（标题 / 筛选 / 搜索 / 范围）。
            return navigation?.top?.makePageToolbarItem(identifier)
        }
    }
}

// MARK: - 二级页右端那两件的内容

/// 「共享」分享什么，由栈顶那一页说了算。系统共享面板锚在这颗键底下弹，
/// 项集与「更多…」那一条都归系统管（见 `.amberShare` 那一支的注释）。
extension MainWindowController: NSSharingServicePickerToolbarItemDelegate {

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        navigation?.top?.pageShareItems ?? []
    }
}

/// 「•••」的项每次弹之前重灌。
extension MainWindowController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuSpec.fill(menu, with: navigation?.top?.pageMoreEntries ?? [])
        // 这一页什么都没给（网格页、搜索页，或详情页还在加载）时退回窗口这一条。
        // 它是 Amber 加的，Music 的 ••• 里没有对应项。`[Amber]`
        guard menu.items.isEmpty else { return }
        let search = NSMenuItem(title: "在当前音乐源中搜索",
                                action: #selector(searchInCurrentProvider(_:)),
                                keyEquivalent: "")
        search.target = self
        menu.addItem(search)
    }
}
