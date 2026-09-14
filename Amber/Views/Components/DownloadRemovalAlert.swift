import AppKit

/// 「移除下载」的确认警告。
///
/// 点已下载那枚图标＝把本地那份删掉，这是一次**误触就丢文件**的破坏性动作，
/// 且图标本身没有任何字面提示（灰圆下箭头 / 红 ✓ 看着都像「已完成」的状态灯）。
/// 所以凡是**点图标**触发的移除都先问一句；••• 菜单里的「移除下载」是明写着的选项，
/// 照旧直接执行（与「从资料库中删除」那张警告同一条判据，见 `LibraryDeleteAlert.confirm`）。
@MainActor
enum DownloadRemovalAlert {

    /// `count` 是这次要移除的曲目数（整张碟/整个歌单就是它的曲目数）。
    /// `window` 给得出就贴成 sheet，给不出（SwiftUI 叶子里拿不到宿主窗）退回 `runModal`。
    static func confirm(count: Int, in window: NSWindow?, remove: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count > 1
            ? "是否确定要移除所选的 \(count) 首歌曲的下载？"
            : "是否确定要移除这首歌曲的下载？"
        alert.informativeText = "本地文件会被删除，之后要重新下载才能离线播放。"
        alert.addButton(withTitle: "移除下载")
        alert.addButton(withTitle: "取消")
        // [HIG] 破坏性按钮交给系统那套护栏（防误触 + 警示外观），与删除歌曲那张一致。
        alert.buttons[0].hasDestructiveAction = true
        // NSAlert 只认英文 "Cancel" 才替它绑 esc，中文标题得自己补一条。
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { remove() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }
}
