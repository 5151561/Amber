import AppKit
import SwiftUI

/// 「显示选项」面板的 AppKit 宿主（Music 的 `ViewNSMenuHelper.doShowHideViewOptions:`）。
///
/// [AX] 2026-08-15 实录：一扇标题「显示选项」的小窗，286×655，浮在主窗之上、
/// 拖不动大小。从前用 SwiftUI 的 `UtilityWindow` 场景表达同一件事，现在是一扇
/// `NSPanel`——`.utilityWindow` 给它窄标题栏、`isFloatingPanel` 给它浮在主窗之上、
/// `hidesOnDeactivate = false` 让 Amber 切到后台时它别自己消失（Music 那扇不会消失）。
///
/// 里面仍是 SwiftUI（`SongsViewOptionsView`），属计划里允许的「叶子」：一屏勾选框，
/// 不滚动大列表、不参与主窗每帧布局。
@MainActor
final class SongsViewOptionsPanelController: NSWindowController {
    private typealias M = MusicMetrics.SongsViewOptions

    init(appState: AppState) {
        let host = NSHostingController(rootView: SongsViewOptionsView()
            .environment(appState.songsTable)
            .environment(appState.listViewSize))
        let panel = NSPanel(contentViewController: host)
        // 不含 .resizable：Music 那扇也拖不动大小
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.title = "显示选项"
        panel.isFloatingPanel = true
        // 不设 becomesKeyOnlyIfNeeded：那条要靠视图报「我需要 key 才能用」，
        // NSHostingView 里的 SwiftUI 控件报不准，勾选框会变成点不动的灰态。
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 先按存档摆位（没存档就居中），再把尺寸按实录钉回去：
        // 存档里可能是上个版本的旧尺寸，而这扇窗的大小是规格不是偏好。
        let autosaveName = "AmberSongsViewOptionsPanel"
        if !panel.setFrameUsingName(autosaveName) {
            panel.center()
        }
        panel.setContentSize(NSSize(width: M.windowWidth, height: M.windowHeight))
        panel.setFrameAutosaveName(autosaveName)
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 开着就收，收着就开——Music 的 doShowHideViewOptions: 是一颗开关，不是「再开一扇」。
    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            window?.orderFront(nil)
        }
    }
}
