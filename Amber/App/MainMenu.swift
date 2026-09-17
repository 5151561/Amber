import AppKit

/// 主菜单。没有 nib，整棵树在这里用 `NSMenu` 建出来（AppDelegate 启动时调一次）。
///
/// 命令一律 **target = nil**，即走响应链：菜单项发出的 action 会依次问
/// key 窗口的第一响应者 → 各级视图与视图控制器 → 窗口 → 窗口控制器 → NSApp →
/// **NSApp 的 delegate**。Amber 的这些命令大多实现在 `AppDelegate` 上（选择器统一带`am`
/// 前缀，见下），所以「有没有窗口、焦点在哪」都不影响它们能不能被送达；
/// 启用态、勾选态与随状态翻的标题统一由 `AppDelegate.validateMenuItem(_:)` 给。
/// 页面级命令反过来利用响应链：实现放在那一页的 VC 上，不在这一页时自动没人响应、
/// 菜单项自动变灰——**一行 validate 都不用写**。现在有五条：「显示简介」「显示重复项目」
/// 「查看显示选项…」「删除」「查找」。
///
/// 为什么不复用 AppKit 现成的 `toggleSidebar(_:)` 这类选择器：`NSSplitViewController`
/// 自己就响应它，于是「谁来 validate」取决于分栏控制器当时在不在响应链里
/// （第一响应者是窗口本身时它就不在），菜单标题会在「隐藏边栏 / 显示边栏」之间
/// 变得不确定。改用只有 AppDelegate 实现的 `amberToggleSidebar(_:)`，转发给分栏控制器，
/// 派发与校验就都只有一处。
///
/// **编辑菜单例外**：撤销/重做/剪切/拷贝/粘贴/全选必须走 AppKit 的标准选择器
/// （`undo:` / `cut:` / …），否则文本框、搜索框里连 ⌘V 都用不了——这些命令的实现
/// 在 `NSTextView` / `NSWindow` 那一层，响应链本来就会找到它们。
///
/// 撤销那两条的启用态与标题也归 AppKit：`undo:` 全框架只有 `NSWindow` 实现
/// （[实测 probe 2026-09-17]），它按**第一响应者的** `undoManager` 现算，
/// 并把标题改成「撤销<动作名>」。Amber 这边要做的只有一件——让窗口交得出一份
/// undo manager，见 `MainWindowController.windowWillReturnUndoManager(_:)`。
/// 「删除」与「查找」不在这条例外里：它们在 Music 里作用于**选中的曲目 / 页内搜索框**，
/// 与字段编辑器无关，所以做成页面级命令。
enum MainMenu {

    /// 菜单里那批带 `am` 前缀的命令。
    ///
    /// 大多实现在 `AppDelegate` 上；**五条例外是页面级命令**，实现在那一页的 VC 上
    /// （`getInfo` / `showHideDuplicates` / `songsViewOptions` / `deleteSelection` / `find`）。
    /// 响应链因此顺带把「这一页在不在」也算了——不在这一页时没有谁响应这个选择器，
    /// AppKit 自动把菜单项变灰。这正好对上 Music 里「显示重复项目」挂在
    /// `NativeContentController`（内容控制器，不是 App 级对象）上的事实，
    /// spec §10.3.1/§10.3.2 `[实测]`。
    enum Action {
        static let showSettings = #selector(AppDelegate.amberShowSettings(_:))
        static let showQQLogin = #selector(AppDelegate.amberShowQQLogin(_:))
        static let newPlaylist = #selector(AppDelegate.amberNewPlaylist(_:))
        static let refreshAccountPlaylists = #selector(AppDelegate.amberRefreshAccountPlaylists(_:))
        static let importFiles = #selector(AppDelegate.amberImportFiles(_:))
        static let toggleSidebar = #selector(AppDelegate.amberToggleSidebar(_:))
        /// 页面级命令：只对歌曲表有意义（那扇面板调的就是歌曲表的列与行高），
        /// 所以实现挪去了 `LibrarySongsViewController`。从前它在 AppDelegate 上，
        /// 于是在主页/新发现/广播上也亮着，点开是一扇调不到任何东西的面板。
        static let songsViewOptions =
            #selector(LibrarySongsViewController.amberShowSongsViewOptions(_:))
        static let showHideDuplicates =
            #selector(LibrarySongsViewController.amberShowHideDuplicates(_:))
        /// 同为页面级命令（实现在曲目表页与资料库歌曲页上，见「文件 ▸ 显示简介」那段）。
        static let getInfo = #selector(TrackTableViewController.amberGetInfo(_:))
        /// 「编辑 ▸ 删除」：把选中的曲目移出资料库。表格里的 ⌫ 发的是同一个选择器
        /// （`TrackDisplayTableView.keyDown`），于是菜单与键盘是同一条命令。
        static let deleteSelection =
            #selector(LibrarySongsViewController.amberDeleteSelection(_:))
        /// 「编辑 ▸ 查找」⌘F：把焦点交给这一页标题栏上那颗搜索框。
        static let find = #selector(LibrarySongsViewController.amberFind(_:))
        static let togglePlayPause = #selector(AppDelegate.amberTogglePlayPause(_:))
        static let nextTrack = #selector(AppDelegate.amberNextTrack(_:))
        static let previousTrack = #selector(AppDelegate.amberPreviousTrack(_:))
        static let volumeUp = #selector(AppDelegate.amberVolumeUp(_:))
        static let volumeDown = #selector(AppDelegate.amberVolumeDown(_:))
        static let toggleShuffle = #selector(AppDelegate.amberToggleShuffle(_:))
        static let setRepeatMode = #selector(AppDelegate.amberSetRepeatMode(_:))
        static let goToNowPlaying = #selector(AppDelegate.amberGoToNowPlaying(_:))
        static let toggleMiniPlayer = #selector(AppDelegate.amberToggleMiniPlayer(_:))
        static let switchToMiniPlayer = #selector(AppDelegate.amberSwitchToMiniPlayer(_:))
        static let miniPlayerLargeArtwork = #selector(AppDelegate.amberToggleMiniPlayerLargeArtwork(_:))
        static let miniPlayerQueue = #selector(AppDelegate.amberToggleMiniPlayerQueue(_:))
        static let miniPlayerLyrics = #selector(AppDelegate.amberToggleMiniPlayerLyrics(_:))
    }

    // 只标这一个方法而不是整个 enum：`Action` 那组常量要在非隔离处比对。
    @MainActor
    static func install(on app: NSApplication) {
        let main = NSMenu()
        main.addItem(appMenuItem(appName: app.amberDisplayName))
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(controlsMenuItem())
        let window = windowMenuItem()
        main.addItem(window)
        let help = helpMenuItem()
        main.addItem(help)
        app.mainMenu = main
        // 这两条必须在挂上 mainMenu 之后指定，AppKit 才会往里补「前置全部窗口」
        // 与搜索框那一栏。
        app.windowsMenu = window.submenu
        app.helpMenu = help.submenu
    }

    // MARK: - Amber

    @MainActor
    private static func appMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)
        menu.addItem(withTitle: "关于 \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(command("设置…", Action.showSettings, key: ",", modifiers: .command))
        // ⌘L 让给「控制 ▸ 前往正在播放的歌曲」——Music 里这颗键就是那件事。
        menu.addItem(command("登录 QQ 音乐…", Action.showQQLogin))
        menu.addItem(.separator())

        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "全部显示",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    // MARK: - 文件

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "文件")
        // Music 是「文件 ▸ 新建 ▸ 播放列表」；标题栏里没有新建键（[AX] all-playlists.json
        // 的工具栏里只有筛选与搜索两件），所以只走菜单。主场景不再是 WindowGroup，
        // ⌘N 也不会被「新建窗口」占用。
        menu.addItem(command("新建播放列表", Action.newPlaylist, key: "n", modifiers: .command))
        // 启用态跟着登录态走，见 AppDelegate.validateMenuItem。
        menu.addItem(command("刷新账号歌单", Action.refreshAccountPlaylists))
        menu.addItem(.separator())
        // Music 的「文件 ▸ 导入…」就是 ⌘O（那一栏里它排在「资料库」之后）。
        // 本机音频文件进资料库的唯一入口，见 ImportService。
        menu.addItem(command("导入…", Action.importFiles, key: "o", modifiers: .command))
        menu.addItem(.separator())
        // 「显示简介」（⌘I）。**位置与键位都是 `[推]`**：文案是实测的
        // （res 250 idx 33 `Show Info` / 显示简介），但它不在文件菜单那张 STR#
        // （res 30200 只有「新建」那一族与「导入…」共 8 条），所以 Music 把它排在
        // 文件菜单的哪一栏、⌘I 是不是它，都没有实测证据。按 Finder 一族的
        // 老规矩给 ⌘I，排在「导入…」之后、「关闭」之前。
        //
        // 与「显示重复项目」同为**页面级命令**：实现在
        // `TrackTableViewController.amberGetInfo(_:)`，不在曲目表页时响应链上没人接，
        // AppKit 自动把它变灰。
        menu.addItem(command("显示简介", Action.getInfo, key: "i", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    // MARK: - 编辑

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // 这一条原先绑的是 `NSText.delete(_:)`——那是文本框里的「删除选中的字」，
        // 与曲目删除毫无关系，于是 Music 里这一条该干的事（删掉选中的歌）在 Amber 里
        // 只有表格 `keyDown` 里裸接的 ⌫ 一条路，既进不了菜单也没法被 validate。
        // 改绑页面级的 `amberDeleteSelection(_:)`：不在有选中曲目的页上就自动变灰。
        // 没有快捷键——⌫ 由表格自己往响应链上发（AppKit 不把 ⌫ 当等价键）。
        menu.addItem(command("删除", Action.deleteSelection))
        menu.addItem(.separator())
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // 「查找」⌘F：macOS 上这颗键就是「在当前这一页里找东西」。Amber 各页的搜索框
        // 长在标题栏上，此前只能用鼠标点。同为页面级命令——没有搜索框的页（主页、
        // 新发现、广播）链上没人接，菜单项自动变灰，**不写 validate**。
        menu.addItem(command("查找", Action.find, key: "f", modifiers: .command))
        item.submenu = menu
        return item
    }

    // MARK: - 显示

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        // macOS 的 View 菜单在中文下就叫「显示」。
        let menu = NSMenu(title: "显示")
        // 侧栏不可收起（见 `MainSplitViewController`：`canCollapse = false`），
        // 所以这里没有「隐藏边栏」那一条——留着也只会是一条点不动的灰项。
        // Music 的 doShowHideViewOptions:（歌曲页筛选菜单里也有同一条）。
        menu.addItem(command("查看显示选项…", Action.songsViewOptions))
        // 「显示重复项目」（spec §10.3，res 30500 idx 16/17/18 与查看显示选项同表）。
        // 一项三态：宽松 / 严格（按住 Option）/ 退出，标题由 VC 的 validateMenuItem
        // 现算——照 Music，标题是在 `validateMenuItem:` 里算出来的，不是建菜单时定死的。
        // 没有快捷键：res 30500 里 idx 16/17/18 都不带 `###X` 那种键位后缀，而同表的
        // idx 19 `查看显示选项###J`、idx 14 ` 进入全屏幕###F#control` 带。`[RES]`
        // 摆位（跟在「查看显示选项…」后面、全屏那条分隔线之前）是 `[推]`：
        // spec 没给这一项在菜单里的排布，只知道它与查看显示选项同属一张资源表。
        menu.addItem(command("显示重复项目", Action.showHideDuplicates))
        menu.addItem(.separator())
        // 全屏用的是 AppKit 的标准项（`toggleFullScreen:`）。**标题不用自己翻**：
        // 这个选择器全框架只有 `NSWindow` 实现，响应链找到的就是窗口自己，
        // 而 `-[NSWindow validateMenuItem:]` 会把标题改成系统那两句
        // 「进入全屏幕 / 退出全屏幕」——[实测 probe 2026-09-17] 建一扇同形态的窗，
        // 把标题先写成「进入全屏幕」再让它 validate 一次，标题当场被改写成系统串。
        // 这里写死的这一句只是 validate 之前那一瞬的占位。
        let fullScreen = NSMenuItem(title: "进入全屏幕",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(fullScreen)
        item.submenu = menu
        return item
    }

    // MARK: - 控制

    private static func controlsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "控制")
        // 空格：Music 的「播放/暂停」就是无修饰的空格键。标题跟着播放态翻
        // （validateMenuItem 里改）。文本输入时的让路见 AmberApplication。
        menu.addItem(command("播放", Action.togglePlayPause, key: " ", modifiers: []))
        menu.addItem(command("下一首", Action.nextTrack, key: "\u{f703}", modifiers: .command))
        menu.addItem(command("上一首", Action.previousTrack, key: "\u{f702}", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(command("增大音量", Action.volumeUp, key: "\u{f700}", modifiers: .command))
        menu.addItem(command("减小音量", Action.volumeDown, key: "\u{f701}", modifiers: .command))
        menu.addItem(.separator())
        // Music 的「随机播放」是一个带对钩的菜单项，不是子菜单。
        menu.addItem(command("随机播放", Action.toggleShuffle))
        // 「重复」是三项单选的子菜单（关闭 / 全部 / 单曲），与 Music 同形。
        let repeatItem = NSMenuItem(title: "重复", action: nil, keyEquivalent: "")
        let repeatMenu = NSMenu(title: "重复")
        for mode in PlayerController.RepeatMode.allCases {
            let entry = command(mode.menuTitle, Action.setRepeatMode)
            entry.tag = mode.rawValue
            repeatMenu.addItem(entry)
        }
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)
        menu.addItem(.separator())
        // Music 的 ⌘L 是「前往正在播放的歌曲」：在当前列表里选中并滚到那一行。
        // Amber 还没有「在任意列表里定位并滚动」的机制，先落到这首歌所属的专辑页——
        // 查不到专辑时 goToAlbum 自己会给一句提示。[推] 落点与 Music 不完全同义。
        menu.addItem(command("前往正在播放的歌曲", Action.goToNowPlaying, key: "l",
                             modifiers: .command))
        item.submenu = menu
        return item
    }

    // MARK: - 窗口 / 帮助

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        // Music 的「窗口 ▸ 迷你播放器」就是 ⌥⌘M，带对钩（窗开着＝勾上），
        // 勾选态在 AppDelegate.validateMenuItem 里给。
        menu.addItem(command("迷你播放器", Action.toggleMiniPlayer, key: "m",
                             modifiers: [.command, .option]))
        // [RES] Music 的 `Switch to MiniPlayer###M#shift` = ⇧⌘M。标题随迷你窗开没开翻
        // （「切换到迷你播放器」/「从迷你播放器切换回来」，见 AppDelegate.validateMenuItem）。
        // ⌥ 点它 = 源窗留着，见 AuxiliaryWindows.doSwitch(from:)。
        menu.addItem(command("切换到迷你播放器", Action.switchToMiniPlayer, key: "m",
                             modifiers: [.command, .shift]))
        menu.addItem(.separator())
        // spec §7 的三个 AMPAction。快捷键由 `keyShortcutModifiers` 的位语义实测推出：
        // Command 恒有，bit0 = 加 Option、bit1 = 加 Control。
        // 三个动作里只有「歌词」恒可用（它不覆写基类的 `isValid`）——规格里唯一的真不对称。
        menu.addItem(command("显示大插图", Action.miniPlayerLargeArtwork, key: "a",
                             modifiers: [.command, .option], symbol: "photo"))
        menu.addItem(command("显示待播清单", Action.miniPlayerQueue, key: "u",
                             modifiers: [.command, .option], symbol: "list.bullet"))
        menu.addItem(command("显示歌词", Action.miniPlayerLyrics, key: "u",
                             modifiers: [.command, .control], symbol: "quote.bubble"))
        menu.addItem(.separator())
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        item.submenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "帮助")
        return item
    }

    // MARK: - 工具

    /// target = nil：走响应链。
    private static func command(_ title: String, _ action: Selector,
                                key: String = "",
                                modifiers: NSEvent.ModifierFlags = .command,
                                symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        // 迷你播放器那三个动作在 Music 里是带图标的（`AMPAction.icon`）。
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }
}

extension PlayerController.RepeatMode {
    var menuTitle: String {
        switch self {
        case .off: return "关闭"
        case .all: return "全部"
        case .one: return "单曲"
        }
    }
}

private extension NSApplication {
    /// 菜单里的应用名。Info.plist 的 `CFBundleDisplayName` 在 Debug 构建里也一定有值。
    var amberDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? ProcessInfo.processInfo.processName
    }
}
