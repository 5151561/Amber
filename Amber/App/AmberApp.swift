import AppKit
import Combine
import SwiftUI

/// 应用入口。界面层换成 AppKit 骨架之后（design-ref/appkit-rewrite-plan.md 阶段 1），
/// 这里不再是 SwiftUI 的 `App` 场景，而是一个普通的`NSApplicationDelegate`：
/// 主菜单用 `NSMenu` 代码建（没有 nib），主窗由`MainWindowController` 持有，
/// 设置窗 / QQ 登录 sheet /「显示选项」面板归 `AuxiliaryWindows`。
///
/// `AppState` 在这里构造唯一一份。Amber 是单窗 App（Music 也是），所以不存在
/// 「第二扇窗共用同一份状态」的问题——旧注释里那段 `WindowGroup` 的顾虑随场景一起没了。
///
/// 菜单命令的实现全在这个类上：菜单项 target = nil 走响应链，NSApp 的 delegate
/// 是链上最后一环，所以焦点在哪都送得到（见 MainMenu 的注释）。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 自己写 `main()`，不用`NSApplicationDelegate` 扩展合成的那一份。
    ///
    /// [实测 2026-09-05] 合成版跑起来进程在、菜单栏在，但 `applicationDidFinishLaunching`
    /// 一次都没进——主窗一扇都没建出来。`NSApplication.delegate` 不持有对象，
    /// 合成的 `main()` 造出的 delegate 没人接住就被释放了。这里用静态变量把它钉住。
    ///
    /// **实例化的是 `AmberApplication.shared`，不是`NSApplication.shared`。**
    /// [实测 probe 2026-09-08] 独立 bundle（Info.plist 写着
    /// `NSPrincipalClass = ProbeApplication`）：`main` 里调`NSApplication.shared`
    /// 拿回来的是 **`NSApplication`**，之后再调`ProbeApplication.shared` 也只会拿到
    /// 那一份已经造好的 `NSApplication`；一上来就调`ProbeApplication.shared` 才拿到子类。
    /// 认 `NSPrincipalClass` 的是`NSApplicationMain()`，不是`+sharedApplication`——
    /// 自己写 `main()` 就必须自己点名子类，否则`AmberApplication` 一次都不会被造出来
    /// （空格＝播放/暂停在焦点落在列表上时全程失效，就是这么来的）。
    private static var delegate: AppDelegate?

    static func main() {
        let app = AmberApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// 非 private：`DebugSnapshot` 的`-dumpmenus` 要拿它当场装一份曲目菜单出来自证。
    let appState = AppState()
    private var windowController: MainWindowController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        AuxiliaryWindows.shared.configure(appState: appState)
        MainMenu.install(on: NSApp)

        let controller = MainWindowController(appState: appState)
        windowController = controller
        AuxiliaryWindows.shared.mainWindowProvider = { [weak controller] in controller?.window }
        controller.showWindow(nil)
        NSApp.activate()

        // QQ 登录面板：状态在 AppState 上（音质气泡、侧栏账号按钮都只置这一位），
        // 呈现归 AuxiliaryWindows。旧版是 `.sheet(isPresented:)`，语义一一对应。
        appState.$showingQQLogin
            .removeDuplicates()
            .sink { showing in
                if showing {
                    AuxiliaryWindows.shared.presentQQLogin()
                } else {
                    AuxiliaryWindows.shared.dismissQQLogin()
                }
            }
            .store(in: &cancellables)

        configureDebugDestination()

        // 登录态校验 + 账号歌单进资料库：上屏时跑一次（AppState 构造时不发请求）。
        Task { await appState.runLaunchTasksOnce() }
    }

    /// ⌘W 关主窗**不退出**：Music 关掉主窗后照常继续播放，程序坞里点一下再开回来
    /// （旧 SwiftUI 版也是关窗不退出）。退出走 ⌘Q。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 程序坞点一下、窗口已经关了的时候把主窗开回来。
    /// 窗口 `isReleasedWhenClosed = false`（见 MainWindowController），
    /// 所以被 close 过之后这一份 controller 仍持有同一扇窗，`showWindow` 直接把它排回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    /// 程序坞图标的右键菜单。每次右键都会调一次，所以按当前播放态当场建一份
    /// （菜单弹出后不会再被校验，见 `DockMenu` 的注释）。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.make(appState: appState, target: self)
    }

    // MARK: - 命令（走响应链，AppDelegate 是最后一环）

    @objc func amberShowSettings(_ sender: Any?) {
        AuxiliaryWindows.shared.showSettings()
    }

    @objc func amberShowQQLogin(_ sender: Any?) {
        appState.showingQQLogin = true
    }

    @objc func amberNewPlaylist(_ sender: Any?) {
        appState.promptNewPlaylist()
    }

    @objc func amberRefreshAccountPlaylists(_ sender: Any?) {
        Task { await appState.syncAccountPlaylists(manual: true) }
    }

    /// 「文件 ▸ 导入…」：选文件/文件夹，交给 `AppState.importItems`。
    ///
    /// 面板允许选目录（一张碟一次拖进来），也允许多选；音乐光盘在 macOS 由 cddafs
    /// 挂成一堆 AIFF 文件，选中那个宗卷就是普通的文件夹导入。
    @objc func amberImportFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportWorker.panelContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "导入"
        panel.message = "选择要导入资料库的音频文件或文件夹"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.appState.importItems(panel.urls)
        }
        if let window = windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    @objc func amberToggleSidebar(_ sender: Any?) {
        windowController?.splitViewController?.toggleSidebar(sender)
    }

    @objc func amberShowSongsViewOptions(_ sender: Any?) {
        AuxiliaryWindows.shared.toggleSongsViewOptions()
    }

    @objc func amberTogglePlayPause(_ sender: Any?) {
        appState.player.togglePlayPause()
    }

    @objc func amberNextTrack(_ sender: Any?) {
        appState.player.next()
    }

    @objc func amberPreviousTrack(_ sender: Any?) {
        appState.player.previous()
    }

    /// [实测] §3.3 `incrementDecrementVolume:`：内部 0…256 刻度、步进 ±12。
    /// 与整窗播放器上那条 ⌘↑/⌘↓ 走同一把尺（`VolumeScale`），别在两处各定一个步长。
    @objc func amberVolumeUp(_ sender: Any?) {
        appState.player.volume = VolumeScale.increment(appState.player.volume, steps: 1)
    }

    @objc func amberVolumeDown(_ sender: Any?) {
        appState.player.volume = VolumeScale.increment(appState.player.volume, steps: -1)
    }

    @objc func amberToggleShuffle(_ sender: Any?) {
        appState.player.toggleShuffle()
    }

    /// 程序坞菜单的「随机播放 ▸ 打开 / 关闭」：置位而不是取反（tag 1 = 打开）。
    @objc func amberSetShuffle(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let on = item.tag == 1
        guard appState.player.isShuffled != on else { return }
        appState.player.toggleShuffle()
    }

    /// 程序坞菜单里对**当前这首**的两条。列表里的同名动作在 `TrackActions`，
    /// 那份对整份选中集生效；这里的作用对象只有正在播的那一首。
    @objc func amberToggleNowPlayingFavorite(_ sender: Any?) {
        guard let track = appState.player.currentTrack else { return }
        appState.library.toggleFavorite(track)
    }

    @objc func amberSetNowPlayingRating(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let track = appState.player.currentTrack else { return }
        appState.library.setRating(item.tag, for: track.id)
    }

    @objc func amberSetRepeatMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let mode = PlayerController.RepeatMode(rawValue: item.tag) else { return }
        appState.player.repeatMode = mode
    }

    @objc func amberToggleMiniPlayer(_ sender: Any?) {
        AuxiliaryWindows.shared.toggleMiniPlayer()
    }

    /// 「窗口 ▸ 切换到迷你播放器」（⇧⌘M）。源窗取当前 key 窗——miniplayer spec §4.1 的
    /// `doSwitchWithSource:` 就是「把发命令的那扇窗收掉」，⌥ 按着则留着。
    @objc func amberSwitchToMiniPlayer(_ sender: Any?) {
        AuxiliaryWindows.shared.doSwitch(from: NSApp.keyWindow)
    }

    /// miniplayer spec §7 的三个切换动作（`AMPToggleMiniplayer{Art,Queue,Lyrics}Action`）。
    @objc func amberToggleMiniPlayerLargeArtwork(_ sender: Any?) {
        AuxiliaryWindows.shared.toggleMiniPlayerLargeArtwork()
    }

    @objc func amberToggleMiniPlayerQueue(_ sender: Any?) {
        AuxiliaryWindows.shared.toggleMiniPlayerQueue()
    }

    @objc func amberToggleMiniPlayerLyrics(_ sender: Any?) {
        AuxiliaryWindows.shared.toggleMiniPlayerLyrics()
    }

    @objc func amberGoToNowPlaying(_ sender: Any?) {
        guard let track = appState.player.currentTrack else { return }
        appState.goToAlbum(of: track)
    }

    // MARK: - 启用态 / 勾选态 / 随状态翻的标题

    /// spec §7：大封面 / 待播清单两个动作的 `isValid` = `currState ∉ {6,7,8}`；
    /// **实例为 nil（迷你窗还没建出来）时按有效处理**。
    static func miniPlayerActionIsValid(_ state: Int?) -> Bool {
        guard let state else { return true }
        return !MiniPlayerStates.isFullWindow(state)
    }
}

@MainActor
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let player = appState.player
        switch item.action {
        case MainMenu.Action.togglePlayPause:
            item.title = player.isPlaying ? "暂停" : "播放"
            return player.currentTrack != nil
        case MainMenu.Action.nextTrack, MainMenu.Action.previousTrack:
            return !player.queue.isEmpty
        case MainMenu.Action.goToNowPlaying:
            return player.currentTrack != nil
        case MainMenu.Action.toggleShuffle:
            item.state = player.isShuffled ? .on : .off
            return true
        case MainMenu.Action.setRepeatMode:
            item.state = item.tag == player.repeatMode.rawValue ? .on : .off
            return true
        case MainMenu.Action.toggleMiniPlayer:
            // Music 那条是带对钩的开关：窗开着就勾上。
            item.state = AuxiliaryWindows.shared.isMiniPlayerVisible ? .on : .off
            return true
        // 下面四条照 miniplayer spec §4.2 / §7：全部返回 true，靠**改标题**表达状态。
        case MainMenu.Action.switchToMiniPlayer:
            item.title = AuxiliaryWindows.shared.isMiniPlayerVisible
                ? "从迷你播放器切换回来" : "切换到迷你播放器"
            return true
        case MainMenu.Action.miniPlayerLyrics:
            // ★ 标题**只认 currState == 1**（组 I 的歌词态）：窗口化 5 / 全窗口 8 里
            // 面板其实也开着，菜单仍说「显示歌词」——spec §4.2 特意记了这条不对称，照抄。
            item.title = AuxiliaryWindows.shared.miniPlayerState == 1 ? "隐藏歌词" : "显示歌词"
            // 三个动作里唯一恒可用的一个：它不覆写 `AMPAction.isValid`，继承的基类实现恒 YES，
            // 所以在全窗口态 {6,7,8} 下依然能用（spec §7「剩下的真不对称只有一条」）。
            return true
        case MainMenu.Action.miniPlayerQueue:
            item.title = AuxiliaryWindows.shared.miniPlayerState == 2
                ? "隐藏待播清单" : "显示待播清单"
            return AppDelegate.miniPlayerActionIsValid(AuxiliaryWindows.shared.miniPlayerState)
        case MainMenu.Action.miniPlayerLargeArtwork:
            let state = AuxiliaryWindows.shared.miniPlayerState
            item.title = state.map(MiniPlayerStates.isWindowed) == true
                ? "隐藏大插图" : "显示大插图"
            return AppDelegate.miniPlayerActionIsValid(state)
        case MainMenu.Action.refreshAccountPlaylists:
            return appState.qqLogin.isLoggedIn
        // 一批还没导完就再开一批，两批会抢「媒体」文件夹里的同一个落点。
        case MainMenu.Action.importFiles:
            return !appState.isImporting
        case MainMenu.Action.toggleSidebar:
            let collapsed = windowController?.splitViewController?.isSidebarCollapsed ?? false
            item.title = collapsed ? "显示边栏" : "隐藏边栏"
            return windowController?.splitViewController != nil
        default:
            return true
        }
    }
}

// MARK: - DEBUG 直达口子

#if DEBUG
/// `-neteaselogin` 开出来那扇窗的强引用：`NSWindow` 不被谁持有就会被回收。
@MainActor private var debugNeteaseLoginWindow: NSWindow?
#endif

@MainActor
extension AppDelegate {
    /// 实机验收用的启动参数。原先挂在 `MainView.onAppear`，骨架换成 AppKit 之后
    /// 搬到这里，语义与参数名一个不改。
    private func configureDebugDestination() {
        #if DEBUG
        DebugSnapshot.installIfRequested()
        let arguments = CommandLine.arguments
        let appState = self.appState
        let player = appState.player
        let library = appState.library

        if let index = arguments.firstIndex(of: "-qqprobe"), index + 1 < arguments.count,
           let qq = appState.provider(.qq) as? QQAPI {
            let path = arguments[index + 1]
            Task { await qq.debugProbeCatalog(to: path) }
        }
        if let index = arguments.firstIndex(of: "-qqplaylistprobe"), index + 1 < arguments.count,
           let qq = appState.provider(.qq) as? QQAPI {
            let path = arguments[index + 1]
            Task { await qq.debugProbeUserPlaylists(to: path) }
        }
        if arguments.contains("-albumdemo") {
            Task {
                let provider = appState.provider(appState.selectedProvider)
                var keyword: String?
                if let qi = arguments.firstIndex(of: "-q"), qi + 1 < arguments.count {
                    keyword = arguments[qi + 1]
                }
                var album: Album?
                if let keyword {
                    album = (try? await provider.searchAlbums(keyword: keyword, limit: 5, offset: 0))?.first
                } else {
                    if case .albums(let albums) = await provider.catalogItems(.newReleases(page: 0)).items {
                        album = albums.first
                    }
                    if album == nil {
                        album = (try? await provider.searchAlbums(keyword: "告五人", limit: 5, offset: 0))?.first
                    }
                }
                guard let album else { return }
                await MainActor.run { appState.push(.album(album)) }
                // `-addthis`：把这张碟连同它的曲目加进资料库，用来自证「资料库里的专辑」
                // 那一路形态（星级列、标题栏那颗 ••• 走 `albumPageEntries` 那份项序）。
                if arguments.contains("-addthis"),
                   let detail = try? await provider.albumDetail(album) {
                    await MainActor.run {
                        appState.library.addAlbumToLibrary(detail.album, tracks: detail.tracks)
                    }
                }
                // `-downloadthis`：把这张专辑页**自己那份**曲目丢进下载队列，用来自证
                // 页头那枚键的 ↓ / ⏹ / ✓ 三态（库里那份曲目未必与音源返回的一致）
                if arguments.contains("-downloadthis"),
                   let detail = try? await provider.albumDetail(album) {
                    await MainActor.run { appState.downloads.download(detail.tracks) }
                }
            }
        }
        // 艺人页同上（阶段 4 最后一批换成 AppKit）：`-artistdemo [-q 关键词]`。
        if arguments.contains("-artistdemo") {
            Task {
                let provider = appState.provider(appState.selectedProvider)
                var keyword = "告五人"
                if let qi = arguments.firstIndex(of: "-q"), qi + 1 < arguments.count {
                    keyword = arguments[qi + 1]
                }
                let artist = (try? await provider.searchArtists(keyword: keyword,
                                                                limit: 5, offset: 0))?.first
                if let artist { await MainActor.run { appState.push(.artist(artist)) } }
                // 再带 `-artistbio` 就顺手把介绍面板弹开（走 ⓘ 的同一条路，
                // 好让 `-dumpviews` 连面板里的文字一起写出来）。页面要先把详情拉回来，
                // hero 才在树里，所以等一会儿再找。
                guard arguments.contains("-artistbio") else { return }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run {
                    guard let root = NSApp.keyWindow?.contentView,
                          let hero = Self.findArtistHero(in: root) else { return }
                    hero.debugPresentBio()
                }
            }
        }
        // 间奏三个点只在特定时刻才看得到，留个直达口子方便实机自证：
        // `-playrecent <标题关键词> [-seek <秒>]` —— 从最近播放里挑一首、跳到那一秒。
        if let index = arguments.firstIndex(of: "-playrecent"), index + 1 < arguments.count {
            let keyword = arguments[index + 1]
            let seek = arguments.firstIndex(of: "-seek")
                .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
            Task { @MainActor in
                // 最近播放是异步灌进来的，等它有货。
                for _ in 0..<40 where library.recentTracks.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let track = library.recentTracks.first(where: {
                    $0.title.localizedCaseInsensitiveContains(keyword)
                }) else { return }
                appState.playNow(track)
                appState.showingNowPlaying = true
                guard let seek else { return }
                // 时长要等 item 就绪才有，seek 早了会被夹回 0。
                for _ in 0..<80 where player.duration <= 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                player.seek(to: seek)
            }
        }
        // `-getinfo [标题关键词] [-tab 0..5]`：把「显示简介」面板直接开出来。
        // 它平时要右键 / ⌘I 才弹得出，而实机验收驱动不了鼠标（见 AGENTS）；
        // 配 `-dumpviews` 就能把六个 Tab 的 frame 写下来对`getinfo 样本` 的实测表。
        if let index = arguments.firstIndex(of: "-getinfo") {
            let keyword = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-")
                ? arguments[index + 1] : nil
            let tab = arguments.firstIndex(of: "-tab")
                .flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
            Task { @MainActor in
                // 资料库是异步灌进来的，等它有货。
                for _ in 0..<40 where library.libraryTracks.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let pool = library.libraryTracks + library.recentTracks
                guard let track = keyword.map({ word in
                    pool.first { $0.title.localizedCaseInsensitiveContains(word) }
                }) ?? pool.first else { return }
                AuxiliaryWindows.shared.showInfoPanel(tracks: [track])
                if let tab { AuxiliaryWindows.shared.selectInfoPanelTab(tab) }
            }
        }
        // `-autoplay [ne]`：起播一首歌好让自动连播那一段有种子。
        // 不带参数走 QQ（`GetSimilarSongs`）；带`ne` 走网易云（`simiSong`）——
        // 两家的相似歌曲是两条不同的接口，只跑一边验不到另一边。
        if let index = arguments.firstIndex(of: "-autoplay"), player.currentTrack == nil {
            let wantsNetease = index + 1 < arguments.count && arguments[index + 1] == "ne"
            let track = wantsNetease
                ? Track(id: "ne:1330348068", kind: .netease,
                        title: "起风了", artistName: "买辣椒也用券",
                        artistId: nil, albumName: "起风了", albumId: nil, artworkURL: nil, duration: 0)
                : Track(id: "qq:004OJ2Hr0NDxI7", kind: .qq,
                        title: "傻鱼", artistName: "王栎鑫",
                        artistId: nil, albumName: "傻鱼", albumId: nil, artworkURL: nil, duration: 0)
            appState.playNow(track)
        }
        // `-neteaselogin [qr]`：把网易云登录面板单独开成一扇窗。
        // 它平时是设置窗里的一张 sheet，要点两下鼠标才到得了，而实机验收驱动不了鼠标
        // （见 AGENTS）；带上 `qr` 就顺手把扫码那条真流程也跑起来（取 unikey → 画码 →
        // 轮询 801），配 `-dumpviews` 就能自证码画出来了、状态行是「请使用网易云音乐 App 扫描」。
        if let index = arguments.firstIndex(of: "-neteaselogin") {
            let host = NSHostingController(rootView:
                NeteaseLoginView().auxiliaryEnvironment(appState))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "网易云音乐登录"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            debugNeteaseLoginWindow = window
            if index + 1 < arguments.count, arguments[index + 1] == "qr" {
                appState.neteaseLogin.startQRLogin()
            }
        }
        if arguments.contains("-recents") { appState.sidebarSelection = .recentlyAdded }
        // 资料库各页改动多，留直达口子方便实机自证
        if arguments.contains("-albums") { appState.sidebarSelection = .albums }
        if arguments.contains("-artists") { appState.sidebarSelection = .artists }
        // `-libartist <名字>`：直接选中某位资料库艺人，省得为了看详情面去驱动鼠标
        if let index = arguments.firstIndex(of: "-libartist"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            appState.openLibraryArtist(named: name)
            // `-downloadfirst`：顺手把这位艺人第一张专辑丢进下载队列，用来自证
            // 专辑块那枚 ↓ 的「下载中 / 已下完」两态（交互不能驱动鼠标，见 AGENTS）
            if arguments.contains("-downloadfirst"),
               let album = library.albums(byArtist: name).first {
                appState.downloads.download(library.tracks(in: album))
            }
        }
        // 目录页三页（主页/新发现/广播）同上
        if arguments.contains("-home") { appState.sidebarSelection = .home }
        if arguments.contains("-discover") { appState.sidebarSelection = .discovery }
        if arguments.contains("-radio") { appState.sidebarSelection = .radio }
        // 歌曲表改动多，留个直达口子方便实机自证
        if arguments.contains("-songs") { appState.sidebarSelection = .songs }
        // 播放列表（资料库 + 账号同步）同上
        if arguments.contains("-playlists") { appState.sidebarSelection = .allPlaylists }
        // 搜索页：词条要落进标题栏那只搜索框，实机敲不进去，所以由参数带进来。
        if let index = arguments.firstIndex(of: "-search"), index + 1 < arguments.count {
            appState.launchSearchTerm = arguments[index + 1]
            appState.sidebarSelection = .search
        }
        // 目录二级页（「查看全部 ›」的落点）：那颗 › 是鼠标才点得到的，
        // 「最近播放」这一种数据现成，给个直达口子验二级页的版式。
        if arguments.contains("-recentsroom") {
            appState.sidebarSelection = .home
            let list = LocalTrackList(id: "recents", title: "最近播放", tracks: library.recentTracks)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                appState.push(.localTracks(list))
            }
        }
        // 右侧面板（歌词 / 待播清单）：胶囊上那两颗键没有菜单命令，实机验收点不到，
        // 所以给一个与 `-songs` / `-nowplaying` 同族的直达口子，配`-dumpviews`
        // 就能量到「面板开着时工具栏各件的 x」（跟踪分隔件是否生效看这个）。
        if arguments.contains("-lyrics") { appState.playerInspector = .lyrics }
        if arguments.contains("-queue") { appState.playerInspector = .queue }
        // `-panelafter lyrics|queue <秒>`：**开着面板再切档**。上面两条是开窗前就把值设好，
        // 走的是「面板第一次渲染」那条路；胶囊上点一下走的是「已经开着再换一档」那条，
        // 两条会分家（面板里那片 SwiftUI 跟不跟得上状态，只有后者验得出来）。
        if let index = arguments.firstIndex(of: "-panelafter"), index + 2 < arguments.count {
            let mode = PlayerInspector(rawValue: arguments[index + 1])
            let delay = Double(arguments[index + 2]) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                appState.playerInspector = mode
            }
        }
        // `-providerafter <源> <秒>`：**页面已经铺好之后再换音乐源**。标题栏那枚切换胶囊
        // 只有鼠标点得到（见 AGENTS），而「换源重拉」与「首次上屏」走的是两条路，
        // 只有后者验得出来货架重排是否干净，所以给一条与 `-panelafter` 同族的口子。
        if let index = arguments.firstIndex(of: "-providerafter"), index + 2 < arguments.count,
           let kind = ProviderKind(rawValue: arguments[index + 1]) {
            let delay = Double(arguments[index + 2]) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                appState.selectedProvider = kind
            }
        }
        if arguments.contains("-nowplaying") {
            if arguments.contains("-withtrack"), let recent = library.recentTracks.first,
               player.currentTrack == nil {
                appState.playNow(recent)
            }
            appState.showingNowPlaying = true
        }
        // 独立迷你播放器窗：菜单命令实机点不到（computer-use 够不着窗），
        // 给一个同族的直达口子，配 `-dumpviews` 量版式。
        // `-minisize <宽>x<高>` 顺便把窗撑到指定尺寸，用来验形态阶梯的三档
        // （<200 横条、250 方形、>宽+200 开抽屉）。
        if arguments.contains("-miniplayer") {
            AuxiliaryWindows.shared.showMiniPlayer()
            if let index = arguments.firstIndex(of: "-minisize"), index + 1 < arguments.count {
                let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    AuxiliaryWindows.shared.resizeMiniPlayer(
                        to: NSSize(width: parts[0], height: parts[1]))
                }
            }
            // `-minipanel lyrics|queue`：走真正的开关命令（不是直接设 frame），
            // 用来验「面板是从下沿往下长出来的」而不是在窗内挤占封面。
            if let index = arguments.firstIndex(of: "-minipanel"), index + 1 < arguments.count {
                switch arguments[index + 1] {
                case "lyrics": AuxiliaryWindows.shared.toggleMiniPlayerLyrics()
                case "queue": AuxiliaryWindows.shared.toggleMiniPlayerQueue()
                default: break
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// 在视图树里找那张满幅 hero（`-artistbio` 用）。
    static func findArtistHero(in view: NSView) -> ArtistHeroView? {
        if let hero = view as? ArtistHeroView { return hero }
        for sub in view.subviews {
            if let hero = findArtistHero(in: sub) { return hero }
        }
        return nil
    }
    #endif
}
