import AppKit
import SwiftUI

/// 附属窗口的统一入口：设置窗（⌘,）、QQ 登录 sheet、「显示选项」面板、迷你播放器窗（⌥⌘M）。
///
/// 界面层改成 AppKit 骨架之后（design-ref/appkit-rewrite-plan.md 阶段 1），
/// 这三扇窗不再由 SwiftUI 的 `Settings` / `UtilityWindow` / `.sheet` 场景开出来，
/// 而是各自一个 `NSWindowController` / `NSPanel` / sheet，由这里统一持有与开关。
/// 窗里的内容暂时仍是 SwiftUI（`NSHostingController` 包着），属于计划里允许的「叶子」。
///
/// 调用方：主菜单（Amber ▸ 设置… / 登录 QQ 音乐…）、歌曲页筛选菜单的「查看显示选项」、
/// 音质气泡的「音频质量设置」、`AppState.showingQQLogin` 的订阅者。
@MainActor
final class AuxiliaryWindows {
    static let shared = AuxiliaryWindows()

    private(set) var appState: AppState?

    /// 主窗。sheet 要挂在它上面；面板要跟着它走。由 AppDelegate 在建好主窗后指定。
    var mainWindowProvider: () -> NSWindow? = { NSApp.mainWindow }

    /// 各扇窗各自留一份：关掉不销毁，下次开还是同一份（位置、折叠态、frame autosave 都在上面）。
    private var settings: SettingsWindowController?
    private var songsViewOptions: SongsViewOptionsPanelController?
    private var qqLoginSheet: NSWindow?
    private var miniPlayer: MiniPlayerWindowController?
    private var infoPanel: InfoPanelWindowController?

    /// AppDelegate 建好 `AppState` 后调一次。
    func configure(appState: AppState) {
        self.appState = appState
    }

    /// 打开设置窗；`tab` 给了就切到那一页（音质气泡要直达「播放」页）。
    func showSettings(tab: SettingsTab? = nil) {
        guard let appState else { return }
        let controller = settings ?? {
            let created = SettingsWindowController(appState: appState)
            settings = created
            return created
        }()
        controller.showSettings(tab: tab)
    }

    /// 在主窗上以 sheet 呈现 QQ 登录面板。已经开着就不重复开。
    func presentQQLogin() {
        guard let appState, qqLoginSheet == nil, let parent = mainWindowProvider() else { return }

        let host = NSHostingController(rootView: QQLoginView(onDismiss: { [weak self] in
            self?.dismissQQLogin()
        }).auxiliaryEnvironment(appState))
        // 面板自己 `frame(width: 420)` + 内容定高，sheet 的尺寸就照它报的来
        host.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.isReleasedWhenClosed = false

        // 先记下来再改 `showingQQLogin`：订阅这条 @Published 的人会回头再叫一次
        // presentQQLogin，靠上面那句 `qqLoginSheet == nil` 挡住重入。
        qqLoginSheet = sheet
        appState.showingQQLogin = true
        parent.beginSheet(sheet, completionHandler: nil)
    }

    /// 收掉 QQ 登录 sheet（登录成功 / 用户点关闭 / `showingQQLogin` 变 false）。
    func dismissQQLogin() {
        appState?.showingQQLogin = false
        guard let sheet = qqLoginSheet else { return }
        qqLoginSheet = nil
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            // 还没挂上去就被叫停（主窗当时不在）：直接收掉，免得留一扇孤窗
            sheet.close()
        }
    }

    /// 「显示选项」面板：开着就收，收着就开（Music 的 doShowHideViewOptions:）。
    func toggleSongsViewOptions() {
        guard let appState else { return }
        let controller = songsViewOptions ?? {
            let created = SongsViewOptionsPanelController(appState: appState)
            songsViewOptions = created
            return created
        }()
        controller.toggle()
    }

    // MARK: - 「显示简介」面板

    /// 曲目右键 / ••• 的「显示简介」、文件菜单的 ⌘I 都走这一条。
    ///
    /// **一扇窗，换曲目就换内容**：Music 那边窗口是复用还是新建，
    /// （0xa28 字节）没有定性过，getinfo spec §7 缺口 #4 明写着「单例复用」这个说法
    /// 本批没有证据。这里按一扇算——同时开出七八扇曲目简介，无论 Music 怎么做
    /// 都不像它。要换回多扇只用把这里的复用判断去掉。
    func showInfoPanel(tracks: [Track]) {
        guard let appState, !tracks.isEmpty else { return }
        // 换曲目就整份重建：面板里的一切（草稿、六个 Tab 的控件绑定、异步取词）
        // 都是按建窗时那一首装配的，没有「换一首」的入口。
        infoPanel?.close()
        let created = InfoPanelWindowController(tracks: tracks, appState: appState)
        infoPanel = created
        created.show()
    }

    #if DEBUG
    /// 实机自证用（`-getinfo … -tab N`）：切到第 N 个 Tab。
    func selectInfoPanelTab(_ index: Int) {
        infoPanel?.debugSelectTab(index)
    }
    #endif

    // MARK: - 迷你播放器窗

    /// 菜单勾选态读这一位。窗还没建出来时不去建它。
    var isMiniPlayerVisible: Bool { miniPlayer?.isVisible == true }

    /// 迷你播放器当前的形态（`MiniPlayerContentView.currState`）。
    /// **窗还没建出来就返回 nil**——spec §7 的三个切换动作在「实例为 nil」时一律按有效处理。
    var miniPlayerState: Int? { miniPlayer?.currentState }

    /// 「窗口 ▸ 迷你播放器」（⌥⌘M）：开着就收，收着就开。
    func toggleMiniPlayer() {
        if isMiniPlayerVisible {
            hideMiniPlayer()
        } else {
            showMiniPlayer()
        }
    }

    func showMiniPlayer() {
        miniPlayerController()?.showWindow(nil)
    }

    func hideMiniPlayer() {
        miniPlayer?.hide()
    }

    #if DEBUG
    /// 实机自证用（`-miniplayer -minisize 宽x高`，见`AppDelegate.applyDebugLaunchArguments`）：
    /// 把窗撑到指定内容尺寸，再按新 frame 反推形态——程序改尺寸不走 `windowWillResize:`，
    /// 不补这一句就永远停在建窗时那一档。
    func resizeMiniPlayer(to size: NSSize) {
        guard let controller = miniPlayer else { return }
        controller.window?.setContentSize(size)
        controller.applyFormStateForCurrentFrame(animated: false)
    }
    #endif

    /// 「窗口 ▸ 切换到迷你播放器」（⇧⌘M）。spec §4.1 `doSwitchWithSource:`：
    ///
    /// ```
    /// flags = NSEvent.modifierFlags
    /// if flags & == 0 { source.isVisible = false }   // = Option
    /// mp.lastShowWasDueToSwitch = (flags & == 0)
    /// mp.showWindow(nil)
    /// ```
    ///
    /// 即**⌥ 点它 = 源窗留着**，不按 ⌥ 则把源窗收掉并记住「这次是切过来的」
    /// （迷你窗关掉时据此把主窗放回来，见 `MiniPlayerWindowController.windowWillClose`）。
    ///
    /// 反方向（迷你窗已经开着 = 菜单标题是「从迷你播放器切换回来」）走同一条命令：
    /// 把主窗叫回来，非 ⌥ 时收掉迷你窗。`[推]`——规格只记了`doSwitchWithSource:` 这一半，
    /// 另一半按 `validate_doSwitchToMiniPlayer:` 的标题语义补齐。
    func doSwitch(from source: NSWindow?) {
        let keepSource = NSEvent.modifierFlags.contains(.option)
        if isMiniPlayerVisible {
            mainWindowProvider()?.makeKeyAndOrderFront(nil)
            if !keepSource {
                miniPlayer?.lastShowWasDueToSwitch = false
                miniPlayer?.hide()
            }
            return
        }
        guard let controller = miniPlayerController() else { return }
        if !keepSource { source?.orderOut(nil) }
        controller.lastShowWasDueToSwitch = !keepSource
        controller.showWindow(nil)
    }

    /// spec §7「大封面」（⌥⌘A）：组 I ⇄ 组 II 互转，面板保持不变。
    func toggleMiniPlayerLargeArtwork() {
        guard let controller = miniPlayerController() else { return }
        controller.showWindow(nil)
        controller.toggleLargeArtwork()
    }

    /// spec §7「待播清单」（⌥⌘U）。
    func toggleMiniPlayerQueue() {
        guard let controller = miniPlayerController() else { return }
        controller.showWindow(nil)
        controller.toggleQueue()
    }

    /// spec §7「歌词」（⌃⌘U）。三个动作里唯一**恒可用**的一个（基类 `isValid` 恒 YES）。
    func toggleMiniPlayerLyrics() {
        guard let controller = miniPlayerController() else { return }
        controller.showWindow(nil)
        controller.toggleLyrics()
    }

    /// Music 的 `MiniPlayerWindowController.singleton`：没有就造一份。
    /// 造出来只是有了 controller，窗要等 `showWindow` 才`loadWindow`。
    @discardableResult
    private func miniPlayerController() -> MiniPlayerWindowController? {
        guard let appState else { return nil }
        if let miniPlayer { return miniPlayer }
        let created = MiniPlayerWindowController(appState: appState)
        // 迷你窗里点封面 / 关掉一扇「切过来的」迷你窗 = 把主窗放回来。
        created.onSwitchToMainWindow = { [weak self] in
            self?.mainWindowProvider()?.makeKeyAndOrderFront(nil)
        }
        miniPlayer = created
        return created
    }
}

extension View {
    /// 附属窗里那些 SwiftUI 叶子要的 `environmentObject` 一次注满。
    ///
    /// 主窗那棵树是 `MainView` 一路注下去的，附属窗各是**独立的一棵**
    /// `NSHostingController` 树，环境不会自己传过来——少注一个，用到它的那张页
    /// 会在运行时直接崩（`@EnvironmentObject` 取不到就是 fatalError），
    /// 所以这里按 `MainView` 那份清单一次注齐，而不是各窗各注各的。
    @MainActor
    func auxiliaryEnvironment(_ appState: AppState) -> some View {
        environmentObject(appState)
            .environmentObject(appState.player)
            .environmentObject(appState.library)
            .environmentObject(appState.downloads)
            .environment(appState.qqLogin)
            .environment(appState.neteaseLogin)
            .environment(appState.providerSettings)
            .environmentObject(appState.player.clock)
            .environmentObject(appState.songsTable)
            .environmentObject(appState.listViewSize)
            .environmentObject(AppSettings.shared)
    }
}
