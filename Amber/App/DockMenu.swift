import AppKit

/// 程序坞图标的右键菜单（`NSApplicationDelegate.applicationDockMenu(_:)`）。
///
/// 结构照 Music 1.7 的那一份复刻：顶上是「播放中 + 曲目 + 艺人 — 专辑」三行灰字，
/// 接着是对当前这首歌的两条（评分 / 心水），然后重复播放、随机播放两个子菜单，
/// 最后是播放、下一首、上一首。
///
/// 底下那几条不用（也不该）自己摆：「选项 ▸ 在程序坞中保留 / 登录时打开 / 在访达中显示」
/// 与「显示所有窗口 / 隐藏 / 退出」都是 Dock 自己往这份菜单下面补的，
/// 任何 App 都白得——Music 的那份也是系统补的，不是它自己建的。
///
/// Music 里另有「启用妙选」「减少推荐」「在 iTunes Store 中显示」三条，
/// Amber 没有对应的能力，一律不摆——与 `TrackActions` 同一条规矩。
///
/// 两点与主菜单不同，都是程序坞菜单的性质决定的：
///
/// 1. **`autoenablesItems = false`，启用态与标题在这里当场写死。** 自动启用要走
///    `validateMenuItem(_:)`，而这份菜单由 Dock 进程显示、Amber 可能整个在后台，
///    菜单弹出后不会再被校验一次。反正每次右键都会重新调 `applicationDockMenu(_:)`，
///    当场按 `player` 的现状建一份就够了。
/// 2. **`target` 显式指到 AppDelegate**，不是主菜单那种 `target = nil` 走响应链：
///    App 在后台时没有 key 窗口，响应链的头一截根本不存在。
@MainActor
enum DockMenu {

    /// 只有这份菜单会发的命令（其余复用 `MainMenu.Action`）。
    enum Action {
        static let toggleFavorite = #selector(AppDelegate.amberToggleNowPlayingFavorite(_:))
        static let setRating = #selector(AppDelegate.amberSetNowPlayingRating(_:))
        static let setShuffle = #selector(AppDelegate.amberSetShuffle(_:))
    }

    static func make(appState: AppState, target: AnyObject) -> NSMenu {
        let player = appState.player
        let library = appState.library
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let track = player.currentTrack {
            menu.addItem(caption("播放中"))
            menu.addItem(caption(track.title, indent: 1))
            let subtitle = track.albumName.isEmpty
                ? track.artistName : "\(track.artistName) — \(track.albumName)"
            if !subtitle.isEmpty { menu.addItem(caption(subtitle, indent: 1)) }
            menu.addItem(ratingItem(rating: library.rating(for: track.id), target: target))
            menu.addItem(item(library.isFavorite(track) ? "取消心水" : "心水",
                              Action.toggleFavorite, target))
            menu.addItem(.separator())
        }

        menu.addItem(repeatItem(mode: player.repeatMode, target: target))
        menu.addItem(shuffleItem(isShuffled: player.isShuffled, target: target))
        menu.addItem(.separator())

        // 标题跟着播放态翻，与「控制」菜单那条同解（见 AppDelegate.validateMenuItem）。
        menu.addItem(item(player.isPlaying ? "暂停" : "播放",
                          MainMenu.Action.togglePlayPause, target,
                          enabled: player.currentTrack != nil))
        menu.addItem(item("下一首", MainMenu.Action.nextTrack, target,
                          enabled: !player.queue.isEmpty))
        menu.addItem(item("上一首", MainMenu.Action.previousTrack, target,
                          enabled: !player.queue.isEmpty))
        return menu
    }

    // MARK: - 子菜单

    /// 评分：「无 / ★…★★★★★」六项单选，与 `TrackActions.ratingEntry` 同形。
    private static func ratingItem(rating: Int, target: AnyObject) -> NSMenuItem {
        let parent = NSMenuItem(title: "评分", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for value in 0...5 {
            let entry = item(value == 0 ? "无" : String(repeating: "★", count: value),
                             Action.setRating, target)
            entry.tag = value
            entry.state = value == rating ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// 重复播放：关闭 / 全部 / 单曲，与「控制 ▸ 重复」同一批 tag。
    private static func repeatItem(mode: PlayerController.RepeatMode,
                                   target: AnyObject) -> NSMenuItem {
        let parent = NSMenuItem(title: "重复播放", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for value in PlayerController.RepeatMode.allCases {
            let entry = item(value.menuTitle, MainMenu.Action.setRepeatMode, target)
            entry.tag = value.rawValue
            entry.state = value == mode ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// 随机播放：程序坞里 Music 把它做成子菜单（主菜单里则是一条带对钩的开关），
    /// 「打开 / 关闭」两项单选。发的是**置位**命令而不是 `toggleShuffle`——
    /// 已经开着时再点「打开」不该把它关掉。
    ///
    /// Music 的这份子菜单下面还有一组「歌曲 / 专辑 / 归类」（随机的粒度），
    /// Amber 的 `PlayerController` 只有「按歌曲随机」这一种，那一组整个不摆。
    private static func shuffleItem(isShuffled: Bool, target: AnyObject) -> NSMenuItem {
        let parent = NSMenuItem(title: "随机播放", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (title, on) in [("打开", true), ("关闭", false)] {
            let entry = item(title, Action.setShuffle, target)
            entry.tag = on ? 1 : 0
            entry.state = on == isShuffled ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - 工具

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject,
                             enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = target
        entry.isEnabled = enabled
        return entry
    }

    /// 顶上那三行灰字：不接命令，只报当前在放什么。
    private static func caption(_ title: String, indent: Int = 0) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        entry.indentationLevel = indent
        return entry
    }
}
