import AppKit
import SwiftUI

/// ⌘, 设置窗的 AppKit 宿主。
///
/// Music 的设置窗（实录 `settings 规格` §0）就是标准的
/// **偏好窗**形态：`AXDialog`、顶上一条`AXToolbar`（每个 tab 一颗 55×56 的按钮、水平居中）、
/// **窗口标题 = 当前 tab 名**、窗宽恒 650 而高度随 tab 变。`NSTabViewController(tabStyle: .toolbar)`
/// 天生就是这一套：工具栏、切页动画、按每页 `preferredContentSize` 改窗高全是它给的，
/// 所以这里只要把五张 pane 各包一个 `NSHostingController` 塞进去。
///
/// 红绿灯三颗全隐：[AX] Music 那扇窗的树里一颗窗口按钮都没有，截图左上角也是空的——
/// 关窗只能走底下那对「取消 / 好」。这与「按『好』才生效」是一件事的两面：
/// 没有一颗按下去等于「就这样吧」的关窗键。⌘W 仍然管用，所以 `styleMask` 里留着`.closable`。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let appState: AppState
    /// 五张 pane 共用的那一份草稿（「好」才写回各 store）
    private let model = SettingsDraftModel()
    private let tabs: SettingsTabViewController
    private static let frameAutosaveName = "AmberSettingsWindow"

    /// [AX] 五张页的顺序 = 工具栏上五颗按钮的顺序，Music 是通用/播放/文件/高级，
    /// Amber 在「播放」后面多插一张自己的「音源」。图标与从前 `Tab(...)` 那一份一致。
    private static let items: [(tab: SettingsTab, title: String, symbol: String)] = [
        (.general, "通用", "gearshape"),
        (.playback, "播放", "play.circle"),
        (.providers, "音源", "square.stack.3d.down.right"),
        (.files, "文件", "folder"),
        (.advanced, "高级", "gearshape.2"),
    ]

    init(appState: AppState) {
        self.appState = appState
        tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        super.init(window: nil)

        for item in Self.items {
            let pane = Self.pane(for: item.tab, model: model, appState: appState)
            let host = NSHostingController(rootView: pane)
            // 窗高要随每张页的自然高度走（[AX] 通用 647 / 播放 852 / 文件 332 / 高级 469），
            // 这条正是把 SwiftUI 量出来的理想尺寸报成 `preferredContentSize`，
            // `NSTabViewController` 再据此改窗。计划里那条「sizingOptions = []」说的是
            // 挂在**定尺寸槽**里的 `NSHostingView`，与这里的窗口自适应是两回事。
            host.sizingOptions = [.preferredContentSize]
            let tabItem = NSTabViewItem(viewController: host)
            tabItem.label = item.title
            tabItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
            tabs.addTabViewItem(tabItem)
        }

        let window = NSWindow(contentViewController: tabs)
        // 不含 .resizable：Music 那扇窗拖不动大小，宽恒 650、高由当前 tab 决定
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // [AX] 标题文字在**工具栏上面**独占一行（AXStaticText y=42，AXToolbar y=67 高 56），
        // 这正是 `.preference` 这档工具栏样式；默认的 .automatic 会把标题和工具栏并成一条。
        window.toolbarStyle = .preference
        // [AX] 角色是 AXDialog 而不是普通 AXWindow
        window.setAccessibilitySubrole(.dialog)
        // 先按存档摆位，没存档才居中——反过来写的话每次都居中，等于没有 autosave
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window

        // 「取消 / 好」关的是**我这扇**，不是当时凑巧是 key 的那扇
        model.close = { [weak window] in window?.performClose(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 开窗时把各 store 的当前值重新抓成草稿（从前是 `SettingsView.onAppear` 做的）。
    /// 窗已经开着时不抓：那会把用户正在编的一半改动冲掉。
    func showSettings(tab: SettingsTab?) {
        if window?.isVisible != true {
            model.refresh(settings: .shared,
                          providerSettings: appState.providerSettings,
                          listViewSize: appState.listViewSize,
                          qqLogin: appState.qqLogin)
        }
        if let tab, let index = Self.items.firstIndex(where: { $0.tab == tab }) {
            tabs.selectedTabViewItemIndex = index
        }
        // 三颗窗口按钮要在窗口真正上屏后再摘：NSWindow 在 orderFront 时会重建标题栏视图，
        // 建之前设的 isHidden 会被它抹掉。
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        hideWindowButtons()
        // 工具栏是 NSTabViewController 在上屏那一刻才装到窗上的，标题栏会再重建一次，
        // 所以下一轮 runloop 补摘一遍（从前那个 SettingsWindowChrome 也是这么干的）。
        DispatchQueue.main.async { [weak self] in self?.hideWindowButtons() }
        NSApp.activate()
    }

    private func hideWindowButtons() {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = true
        }
    }

    @ViewBuilder
    private static func pane(for tab: SettingsTab,
                             model: SettingsDraftModel,
                             appState: AppState) -> some View {
        switch tab {
        case .general: GeneralSettingsPane(model: model).auxiliaryEnvironment(appState)
        case .playback: PlaybackSettingsPane(model: model).auxiliaryEnvironment(appState)
        case .providers: ProviderSettingsPane(model: model).auxiliaryEnvironment(appState)
        case .files: FilesSettingsPane(model: model).auxiliaryEnvironment(appState)
        case .advanced: AdvancedSettingsPane(model: model).auxiliaryEnvironment(appState)
        }
    }
}

/// 只为一件事继承一层：把窗口标题跟着当前 tab 名走（[AX] 标题 = tab 名）。
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let label = tabViewItem?.label {
            view.window?.title = label
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 首次上屏时 didSelect 已经在没有 window 的时候发生过了，补一次标题
        if let label = tabView.selectedTabViewItem?.label {
            view.window?.title = label
        }
    }
}
