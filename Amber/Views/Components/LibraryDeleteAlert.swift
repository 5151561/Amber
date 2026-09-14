import AppKit

/// 「从资料库中删除」的两张对话框。
///
/// 规格来源 `library 规格` §10.2（文案是 `[RES]`，分表机制是`[实测]`；
/// 基线 macOS 27.0 正式版 26A428 / Music 1.7.0）：删除**不是**一问一答，而是两段——
/// 先确认要不要删（这一张 Amber 早就有，原先写在 `SongsTableView.confirmDelete` 里），
/// 再问**文件去哪**。文案从 Music.app 的 zh_CN `Localizable.strings` 实测
/// （`Tools/loc-strings.py`）：
///
/// | 出处 | 文案 |
/// | --- | --- |
/// | res 500→501 idx 76 | 你是要将所选歌曲移到废纸篓，还是要将它保留在“媒体”文件夹中？ |
/// | res 500→501 idx 77 | 你是要将所选歌曲移到废纸篓，还是要将它们保留在“媒体”文件夹中？ |
/// | res 9008 idx 14 | 仅“媒体”文件夹中的文件会被移到废纸篓中。 |
/// | res 9008 idx 15 | 移到废纸篓 |
/// | res 9008 idx 22/23 | 保留文件 |
///
/// 上表写 `500→501` 是因为**代码里只写 res 500（通用条目）**，歌曲那一份是运行期由
/// 按媒体种类（`0x2` = 歌曲）换表得来的（§10.10.2 实测，与 §10.1 同机制）。
/// 别把 501 当成「代码里就写着 501」——那张表从来不被字面引用。
///
/// 同一张 9008 里还并排摆着**直接删**的那一套措辞（idx 16「仅“媒体”文件夹中的文件会被
/// 删除。」+ idx 20/21「删除文件」）。Amber 走的是废纸篓那一套（idx 14/15 + 22/23）：
/// 可撤销，而且这是 macOS 上删用户文件的默认做法。
///
/// **关键限制词是「仅“媒体”文件夹中的文件」**：删除只对媒体文件夹内的文件动手。
/// 「添加到资料库时不复制文件」那类外部引用条目（`ImportService` 的`copyToMediaFolder`
/// 关着时导进来的），删除时只删记录、不碰磁盘文件——这一点 Amber 本来就是对的
/// （`DownloadStore.remove(ids:)` 里那条`isExternal` 判定），§10.2 只是把它坐实了。
///
/// **这一问只给本地曲目**（`Track.isLocal`）。音源曲目下载下来的那份文件也在「媒体」
/// 文件夹里，但 Music 对它们问的是另一句——「你要从资料库删除此歌曲还是从这台电脑上
/// 移除下载？」（res 501 idx 79/80），三选一，是独立的一条链。那条不在这一批的范围里，
/// 所以音源曲目照旧：删条目 ＝ 连下载一起清掉（`LibraryStore.onTracksRemoved`）。
@MainActor
enum LibraryDeleteAlert {

    /// 需要先确认的入口（⌫ / 图标这类点下去就没的）：两张都走。
    static func confirm(tracks: [Track], in window: NSWindow? = nil, appState: AppState,
                        delete: @escaping () -> Void) {
        guard !tracks.isEmpty else { return }
        let window = window ?? hostWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tracks.count > 1
            ? "是否确定要从资料库中删除所选的 \(tracks.count) 首歌曲？"
            : "是否确定要从资料库中删除所选歌曲？"
        alert.addButton(withTitle: "删除歌曲")
        alert.addButton(withTitle: "取消")
        // [HIG] 「删除歌曲」是破坏性动作，交给系统自己那套护栏：
        // `NSButton.hasDestructiveAction`（macOS 11+）文档原话是设为 true
        // "allows the system to guard a destructive-action button against accidental
        // presses, and can give the button a special appearance in certain contexts
        // to caution against unintentional use."——防误触与警示外观都由系统给，
        // 按钮位置、标题、排布不受影响，视觉照旧。
        //
        // 默认键**不动**，仍留在「删除歌曲」上。一颗 NSButton 只有一个 keyEquivalent，
        // 把回车挪给「取消」就等于把 esc 从它身上拿走（见下面那条：中文标题拿不到
        // 系统替补的 esc），换来的是「回车能关窗」、丢掉的是「esc 能关窗」——净亏。
        alert.buttons[0].hasDestructiveAction = true
        // NSAlert 只在按钮标题正好是英文 "Cancel" 时才替它绑上 esc，中文标题拿不到。
        alert.buttons[1].keyEquivalent = "\u{1b}"
        run(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            askFileDisposition(tracks: tracks, in: window, appState: appState, delete: delete)
        }
    }

    /// 明写着的入口（右键/••• 菜单里的「从资料库中删除」）：不再问一遍「确定吗」，
    /// 但**「文件去哪」这一问不能省**——它不是确认，是一个 Amber 猜不出来的选择。
    /// 省掉它就等于替用户选了「删文件」，而那一半用户想要的是「条目不要了、文件留着」。
    static func askFileDisposition(tracks: [Track], in window: NSWindow? = nil,
                                   appState: AppState, delete: @escaping () -> Void) {
        guard !tracks.isEmpty else { return }
        let window = window ?? hostWindow()
        // 只有本地曲目、且文件真在「媒体」文件夹里的那些才有的可问（见类型注释）。
        let ids = tracks
            .filter { $0.isLocal && appState.downloads.hasMediaFolderFile($0.id) }
            .map(\.id)
        guard !ids.isEmpty else {
            delete()
            return
        }
        let alert = NSAlert()
        alert.messageText = ids.count > 1
            ? "你是要将所选歌曲移到废纸篓，还是要将它们保留在“媒体”文件夹中？"
            : "你是要将所选歌曲移到废纸篓，还是要将它保留在“媒体”文件夹中？"
        alert.informativeText = "仅“媒体”文件夹中的文件会被移到废纸篓中。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "保留文件")
        // 「取消」是 `[推]`：spec 那三条串里没有它（res 9008 只给了两颗动作键）。
        // 留着的理由是这张是**第二**张——从菜单进来的用户在此之前没被问过任何一句，
        // 没有退路的话，误点一次「从资料库中删除」就再也回不了头了。
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[2].keyEquivalent = "\u{1b}"
        run(alert, in: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                // 先处置文件再删条目：删条目会触发 `onTracksRemoved` → `downloads.remove(ids:)`，
                // 那条是**永久删**。这里先把索引清掉（`trash` 自己就清），
                // 后面那一下就找不到条目、什么也不做了。
                appState.downloads.trash(ids: ids)
                delete()
            case .alertSecondButtonReturn:
                // 同一条理由，只是这一支不动文件：不先 `forget`，随后的`remove(ids:)`
                // 会把用户刚说要保留的文件删掉。
                appState.downloads.forget(ids: ids)
                delete()
            default:
                break
            }
        }
    }

    /// 菜单那类入口手上没有宿主窗，自己去问一次（与 `MissingFileLocator` 同一条）。
    private static func hostWindow() -> NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// 有窗就贴成页签，没窗退回 `runModal`（与`DownloadRemovalAlert` 同一条）。
    private static func run(_ alert: NSAlert, in window: NSWindow?,
                            completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else {
            completion(alert.runModal())
            return
        }
        // 隔一拍再贴：上一张页签的完成回调回来时它自己还没从窗上撤干净，
        // 同一扇窗上紧接着 `beginSheetModal`，第二张会被吞掉。
        DispatchQueue.main.async {
            alert.beginSheetModal(for: window, completionHandler: completion)
        }
    }
}
