#if DEBUG
import AppKit
import SwiftUI

/// 实机验收的自证口子（只进 DEBUG）：不依赖辅助功能与屏幕录制权限，
/// App 自己把窗口的视图树 frame 与渲染图写出来。
///
/// - `-dumpviews <path>`：延时后把主窗（及所有可见窗）的视图树写成文本，
///   每行「缩进 类名 [x, y, w, h]（窗口坐标，左上原点，与 AX 的报法一致）+ 关键属性」，
///   工具栏各件另列。拿它对 `design-ref/ui-spec/pages/*.json` 的 AX frame。
/// - `-snapshot <path>`：`cacheDisplay(in:to:)` 把窗口内容渲染成 PNG。
///   玻璃与 vibrancy 走的是窗口服务器合成，这条路画不出，只看版式。
/// - `-dumpmenus <path>`：把各份菜单当场装配出来写成文本——程序坞右键菜单
///   （`applicationDockMenu(_:)`）、悬浮播放条那颗 •••（`PlayerMoreMenu`）、
///   迷你窗那颗 ⋯、曲目菜单的三份项序（`TrackActions` 的目录行/资料库行/播放队列）
///   与集合菜单骨架（`CollectionActions`）、标题栏右端那颗 •••。菜单不是视图，`-dumpviews` 里看不到它；
///   而这些都要点/右键才弹得出来，交互又驱动不了（见 AGENTS）——
///   所以让 App 自己把当场建出来的那份写下来，项集与顺序就地自证。
/// - `-dumpdelay <秒>`：三者共用的延时，默认 2.5。
/// - `-scroll <点数>`：dump 之前把内容列那张滚动视图往下滚这么多点。
///   用来自证「跟着滚动联动」的那一类行为（「最近添加」的标题栏标题跟当前段名）——
///   发键那条路要先把焦点落到滚动视图上，靠 System Events 驱动不了。
// 整份都在主线程：读的是 NSApp、窗口视图树、各份菜单，本来就没有别的跑法。
@MainActor
enum DebugSnapshot {

    static func installIfRequested() {
        let args = CommandLine.arguments
        let delay = args.firstIndex(of: "-dumpdelay")
            .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 2.5
        let dumpPath = args.firstIndex(of: "-dumpviews").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let snapPath = args.firstIndex(of: "-snapshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let menuPath = args.firstIndex(of: "-dumpmenus").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let scrollBy = args.firstIndex(of: "-scroll")
            .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        guard dumpPath != nil || snapPath != nil || menuPath != nil else { return }
        if let scrollBy {
            // 滚在 dump 之前的半程：页面已经铺好、dump 还没开始。
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.5) {
                MainActor.assumeIsolated { scrollContent(by: scrollBy) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if let dumpPath { try? dumpViews().write(toFile: dumpPath, atomically: true, encoding: .utf8) }
                if let snapPath { snapshot(to: snapPath) }
                if let menuPath {
                    let text = dumpDockMenu() + dumpPlayerMoreMenu() + dumpMiniWindowMenu()
                        + dumpTrackMenus() + dumpCollectionMenu() + dumpPlaylistMenu()
                        + dumpToolbarMoreMenu()
                    try? text.write(toFile: menuPath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// 程序坞菜单那棵树。系统往下补的「选项 / 显示所有窗口 / 隐藏 / 退出」不在这份里——
    /// 那几条是 Dock 自己加的，App 这边根本看不到。
    static func dumpDockMenu() -> String {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let menu = delegate.applicationDockMenu(NSApp) else { return "DOCKMENU -\n" }
        var out = "DOCKMENU autoenables=\(menu.autoenablesItems)\n"
        walk(menu, depth: 1, into: &out)
        return out
    }

    /// 悬浮播放条那颗 ••• 弹的菜单（与整窗播放器共用 `PlayerMoreMenu` 那张表）。
    ///
    /// 没在放歌时这颗按钮本来就不出菜单——但那样这份表就永远自证不了，
    /// 所以退而用一首现成的曲目把表装出来，只为看项集与顺序（标题里注明是哪种）。
    static func dumpPlayerMoreMenu() -> String {
        if let capsule = firstView(of: MiniPlayerView.self), let menu = capsule.makeMoreMenu() {
            var out = "PLAYERMENU（正在播放）items=\(menu.numberOfItems)\n"
            walk(menu, depth: 1, into: &out)
            return out
        }
        guard let appState = (NSApp.delegate as? AppDelegate)?.appState,
              let track = fallbackTrack(appState) else { return "PLAYERMENU -\n" }
        let menu = MenuSpec.makeMenu(PlayerMoreMenu.entries(
            track: track, appState: appState,
            library: appState.library, downloads: appState.downloads))
        var out = "PLAYERMENU（未在播放，用 \"\(track.title)\" 装表）items=\(menu.numberOfItems)\n"
        walk(menu, depth: 1, into: &out)
        return out
    }

    /// 装菜单用的兜底曲目：正在播的那首，否则资料库里第一首。
    private static func fallbackTrack(_ appState: AppState) -> Track? {
        appState.player.currentTrack
            ?? appState.library.libraryTracks.first
            ?? appState.library.recentTracks.first
    }

    /// 独立迷你播放器窗那颗 ⋯ 弹的菜单（`-miniplayer` 开窗之后才有）。
    static func dumpMiniWindowMenu() -> String {
        guard let contents = firstView(of: MiniPlayerContentView.self) else {
            return "MINIWINDOWMENU -\n"
        }
        let menu = contents.actionMenu()
        var out = "MINIWINDOWMENU items=\(menu.numberOfItems)\n"
        walk(menu, depth: 1, into: &out)
        return out
    }

    /// 曲目菜单的三份项序（目录曲目行 / 资料库表格行 / 播放队列）。
    ///
    /// 这三份是右键才弹得出来的，鼠标交互驱动不了；但菜单本来就是**当场装配**的，
    /// 让 App 自己把装好的那份写下来即可自证项集与顺序——不用点一下。
    static func dumpTrackMenus() -> String {
        guard let appState = (NSApp.delegate as? AppDelegate)?.appState else { return "TRACKMENUS -\n" }
        guard let track = fallbackTrack(appState) else { return "TRACKMENUS (没有可用曲目)\n" }
        let actions = TrackActions(tracks: [track], appState: appState)
        var out = ""
        for (name, entries) in [("CATALOGROW", actions.catalogRow()),
                                ("LIBRARYROW", actions.libraryRow()),
                                ("QUEUEROW", actions.queueRow())] {
            let menu = MenuSpec.makeMenu(entries)
            out += "\(name) track=\"\(track.title)\" items=\(menu.numberOfItems)\n"
            walk(menu, depth: 1, into: &out)
        }
        return out
    }

    /// 集合菜单（专辑/歌单/艺人）的**完整骨架**：把能力全给上，看段落划分与项序。
    /// 各调用点实际给了哪几条要看各自的卡，这里只自证 `CollectionActions` 这张表本身。
    static func dumpCollectionMenu() -> String {
        var all = CollectionActions()
        all.play = {}
        all.shuffle = {}
        all.addToLibrary = {}
        all.deleteFromLibrary = {}
        all.download = {}
        all.removeDownload = {}
        all.playNext = {}
        all.addToQueue = {}
        all.favorite = {}
        all.undoFavorite = {}
        all.suggestLess = {}
        all.undoSuggestLess = {}
        all.goTo = (title: "前往专辑", run: {})
        all.goToArtist = {}
        all.openOnWeb = {}
        all.shareURL = URL(string: "https://y.qq.com/n/ryqq/albumDetail/000MkMni19ClKG")
        all.rename = {}
        all.syncAccount = {}
        all.addToPlaylist = .submenu(.init("添加到播放列表"), [.command(.init("新建播放列表", run: {}))])
        all.rating = (current: 3, set: { _ in })
        all.check = (isAllChecked: true, run: {})
        guard let menu = all.makeMenu() else { return "COLLECTIONMENU -\n" }
        var out = "COLLECTIONMENU（能力全开）items=\(menu.numberOfItems)\n"
        walk(menu, depth: 1, into: &out)
        // 专辑页那颗 ••• 是同一个能力袋的**另一份项序**（[实机截图] 那张表），单列一份对照。
        let page = MenuSpec.makeMenu(all.albumPageEntries)
        out += "ALBUMPAGEMENU（能力全开）items=\(page.numberOfItems)\n"
        walk(page, depth: 1, into: &out)
        return out
    }

    /// 标题栏右端那颗 ••• 现在弹的是什么（`MainWindowController` 的 `.amberMore`）。
    ///
    /// 它的项是**开菜单那一刻**由栈顶那一页给的（`pageMoreEntries` → `menuNeedsUpdate:`），
    /// 所以这里照样只调 `menu.update()`——那一句走的就是真身那条路，不是另抄一份。
    /// 配 `-albumdemo` 用：能看到专辑页把 `CollectionActions` 那张表交上来了没有。
    /// 那颗「共享」不在这份里，它是工具栏件不是菜单，`-dumpviews` 的 TOOLBAR 段里看。
    static func dumpToolbarMoreMenu() -> String {
        // 走可见窗而不是 `NSApp.mainWindow`：dump 时 App 未必是最前那个（脚本跑着），
        // mainWindow 那会儿是 nil。
        guard let item = NSApp.windows.filter(\.isVisible)
            .compactMap({ $0.toolbar?.items })
            .flatMap({ $0 })
            .first(where: { $0.itemIdentifier == .amberMore }) as? NSMenuToolbarItem
        else { return "TOOLBARMORE -\n" }
        let menu = item.menu
        // 直接叫一声代理的 `menuNeedsUpdate:`——弹出时系统叫的就是这一句。
        // （`menu.update()` 那条路时灵时不灵：它还带着「已经是最新的就不问」的判断，
        // 而这份菜单从没弹开过。dump 要的是确定性，不是模拟点击。）
        menu.delegate?.menuNeedsUpdate?(menu)
        var out = "TOOLBARMORE items=\(menu.numberOfItems)\n"
        walk(menu, depth: 1, into: &out)
        return out + dumpToolbarShare()
    }

    /// 那颗「共享」现在会把什么交给系统共享面板。同样只叫代理那一句
    /// （`itemsForSharingServicePickerToolbarItem:`）——系统点开面板时问的就是它。
    /// 面板本身是系统的浮层，弹不弹得出来只能用鼠标验（见 AGENTS：交互类交给用户）。
    private static func dumpToolbarShare() -> String {
        guard let item = NSApp.windows.filter(\.isVisible)
            .compactMap({ $0.toolbar?.items })
            .flatMap({ $0 })
            .first(where: { $0.itemIdentifier == .amberShare })
            as? NSSharingServicePickerToolbarItem
        else { return "TOOLBARSHARE -（这一页没有可分享的东西，整件不摆）\n" }
        let items = item.delegate?.items(for: item) ?? []
        var out = "TOOLBARSHARE label=\"\(item.label)\" items=\(items.count)\n"
        for one in items { out += "  \(one)\n" }
        return out
    }

    /// 侧栏播放列表行那份 SwiftUI 菜单（`LibraryPlaylistMenu`，`NSHostingMenu` 包成 `NSMenu`）。
    ///
    /// 单列一份是因为它是 **SwiftUI 那条渲染路**：AppKit 那边的项从 `MenuSpec.makeMenu`
    /// 出来，这边是 `Menu { … }` / `ShareLink`，两条路各有各的坑，得各自自证。
    /// `NSHostingMenu` 造出来 items 就已经在了，不用点一下（见会话笔记）。
    static func dumpPlaylistMenu() -> String {
        guard let appState = (NSApp.delegate as? AppDelegate)?.appState,
              // 优先挑一份**分享得出去**的（`qq:radio:` 那种在网页版没有页面，
              // 拿它当样本就看不到「分享」这一条到底渲没渲出来）。
              let playlist = appState.library.playlists.first(where: { $0.webShareURL != nil })
                  ?? appState.library.playlists.first else { return "PLAYLISTMENU -\n" }
        let menu = NSHostingMenu(rootView: LibraryPlaylistMenu(playlist: playlist)
            .environment(appState)
            .environment(appState.library))
        var out = "PLAYLISTMENU playlist=\"\(playlist.name)\" origin=\(playlist.origin.rawValue) items=\(menu.numberOfItems)\n"
        walk(menu, depth: 1, into: &out)
        return out
    }

    /// 所有可见窗里的第一个这种视图（迷你窗开着时它不一定是 main window）。
    private static func firstView<V: NSView>(of type: V.Type) -> V? {
        for window in NSApp.windows where window.isVisible {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            if let hit = firstView(of: type, in: root) { return hit }
        }
        return nil
    }

    private static func firstView<V: NSView>(of type: V.Type, in view: NSView) -> V? {
        if let hit = view as? V { return hit }
        for sub in view.subviews {
            if let hit = firstView(of: type, in: sub) { return hit }
        }
        return nil
    }

    private static func walk(_ menu: NSMenu, depth: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem { out += "\(pad)---\n"; continue }
            var extra = item.isEnabled ? "" : " disabled"
            if let view = item.view {
                extra += " view=\(type(of: view)) frame=\(fmt(view.frame))"
                extra += labelsText(in: view)
            }
            if !item.keyEquivalent.isEmpty {
                extra += " key=\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
            }
            if item.image != nil { extra += " image" }
            if item.state == .on { extra += " ✓" }
            if item.indentationLevel > 0 { extra += " indent=\(item.indentationLevel)" }
            if let action = item.action { extra += " action=\(action)" }
            out += "\(pad)\"\(item.title)\"\(extra)\n"
            if let submenu = item.submenu { walk(submenu, depth: depth + 1, into: &out) }
        }
    }

    /// 菜单项自定义视图里的文字（`MiniPlayerMenuHeaderView` 的标题/副标题靠它自证）。
    private static func labelsText(in view: NSView) -> String {
        var parts: [String] = []
        if let field = view as? NSTextField {
            parts.append("\"\(field.stringValue)\" \(fmt(field.frame))")
        }
        for sub in view.subviews {
            let text = labelsText(in: sub)
            if !text.isEmpty { parts.append(text.trimmingCharacters(in: .whitespaces)) }
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// 把内容列那张滚动视图往下滚。认「文稿是 collection view 且当前可见」的那一张——
    /// 侧栏是 outline view，导航栈里被收起的页面 `isHiddenOrHasHiddenAncestor` 为真。
    private static func scrollContent(by points: Double) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let root = window.contentView,
              let scroll = contentScrollView(in: root) else { return }
        let target = NSPoint(x: scroll.documentVisibleRect.minX,
                             y: scroll.documentVisibleRect.minY + points)
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func contentScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           scroll.documentView is NSCollectionView,
           !scroll.isHiddenOrHasHiddenAncestor {
            return scroll
        }
        for subview in view.subviews {
            if let found = contentScrollView(in: subview) { return found }
        }
        return nil
    }

    static func dumpViews() -> String {
        var out = ""
        for window in NSApp.windows where window.isVisible {
            let frame = window.frame
            out += "WINDOW \(type(of: window)) title=\"\(window.title)\" frame=\(fmt(frame)) contentLayoutRect=\(fmt(window.contentLayoutRect)) key=\(window.isKeyWindow)\n"
            if let toolbar = window.toolbar {
                out += "  TOOLBAR items=\(toolbar.items.count) visible=\(toolbar.isVisible)\n"
                for item in toolbar.items {
                    let v = item.view
                    let r = v.flatMap { $0.window == nil ? nil : windowRect(of: $0) }
                    out += "    ITEM \(item.itemIdentifier.rawValue) hidden=\(item.isHidden) label=\"\(item.label)\" view=\(v.map { String(describing: type(of: $0)) } ?? "-") frame=\(r.map(fmt) ?? "-")\n"
                }
            }
            // 从主题框架（contentView.superview）往下走，标题栏与红绿灯也在里面
            if let root = window.contentView?.superview ?? window.contentView {
                walk(root, depth: 1, into: &out)
            }
        }
        return out
    }

    private static func walk(_ view: NSView, depth: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: depth)
        var extra = ""
        if view.isHidden { extra += " hidden" }
        // 淡入淡出（迷你窗的 rollover 就是改 alpha）光看 hidden 看不出来，顺手记一笔。
        if view.alphaValue < 0.999 { extra += String(format: " alpha=%.2f", view.alphaValue) }
        if let field = view as? NSTextField { extra += " text=\"\(field.stringValue.prefix(40))\" font=\(field.font.map { "\($0.pointSize)" } ?? "-")" }
        if let button = view as? NSButton, !button.title.isEmpty { extra += " title=\"\(button.title)\"" }
        if let scroll = view as? NSScrollView {
            extra += " docBounds=\(fmt(scroll.documentView?.bounds ?? .zero)) clipOrigin=\(fmt(scroll.contentView.bounds.origin))"
        }
        if let table = view as? NSTableView { extra += " rows=\(table.numberOfRows) rowH=\(table.rowHeight) sel=\(table.selectedRow)" }
        if let effect = view as? NSVisualEffectView { extra += " material=\(effect.material.rawValue) blend=\(effect.blendingMode.rawValue)" }
        if let split = view as? NSSplitView { extra += " dividers=\(split.arrangedSubviews.count - 1)" }
        if let id = view.identifier?.rawValue { extra += " id=\(id)" }
        let name = String(describing: type(of: view))
        out += "\(pad)\(name) \(fmt(windowRect(of: view)))\(extra)\n"
        // NSHostingView 内部是 SwiftUI 的私有层，往下没有意义
        if name.hasPrefix("NSHostingView") || name.hasPrefix("_NSHostingView") { return }
        for sub in view.subviews { walk(sub, depth: depth + 1, into: &out) }
    }

    /// 窗口坐标、左上原点（AX 的 frame 报法减去窗口原点）。
    private static func windowRect(of view: NSView) -> CGRect {
        guard let window = view.window else { return view.frame }
        let r = view.convert(view.bounds, to: nil)
        let h = window.frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func fmt(_ r: CGRect) -> String {
        "[\(num(r.minX)), \(num(r.minY)), \(num(r.width)), \(num(r.height))]"
    }
    private static func fmt(_ p: CGPoint) -> String { "(\(num(p.x)), \(num(p.y)))" }
    private static func num(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 每一扇可见窗各写一张：主窗落在 `<path>`，其余按窗口类名加后缀
    /// （`snap.png` → `snap-MiniPlayerWindow.png`）。
    ///
    /// 原来只拍 `keyWindow`，附属窗（迷你播放器、MV、设置）就永远拍不到——
    /// 它们不一定是 key，`-dumpviews` 又只给 frame 不给像素。
    static func snapshot(to path: String) {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        var main = true
        for window in NSApp.windows where window.isVisible {
            guard let root = window.contentView?.superview ?? window.contentView,
                  root.bounds.width > 0, root.bounds.height > 0,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
            root.cacheDisplay(in: root.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let dest = main
                ? url
                : URL(fileURLWithPath: "\(stem.path)-\(type(of: window)).\(ext)")
            try? data.write(to: dest)
            main = false
        }
    }
}
#endif
