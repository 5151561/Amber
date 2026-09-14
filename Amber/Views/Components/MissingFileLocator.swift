import AppKit

/// 「文件失联」那条链：发现原始文件不在原处 → 问要不要查找 → 用户指路 → 追问要不要用
/// 这个位置把其余丢失的文件一起找回来 → 进度 → 三条独立的收尾文案。
///
/// 规格来源 `library 规格` §10.1（证据档 `[实测]`，基线 macOS 27.0 正式版
/// 26A428 / Music 1.7.0）：整条链都在**一个函数**的控制流里——
/// 正文、默认按钮、次按钮、跑弹窗、批量追问、进度、收尾分支逐处地址见 §10.1.1；
/// res 143 idx 18–25 是**连号**的一整块流程文案（连号即同一段逻辑）。
///
/// 触发那句**代码里写的是 res 500 idx 56（通用条目）**，运行期由按媒体
/// 种类换表（`0x2` → 501 歌曲 /`0x10` → 504 视频 / …，机制见 §10.10.2）。Amber 只有歌曲，
/// 落到 501 那一份，也就是下表第一句。文案是从 Music.app 的 zh_CN `Localizable.strings`
/// 实测的（`Tools/loc-strings.py`），只按仓库惯例把「音乐」换成「Amber」
/// （同 `SettingsView` 顶上那条说明）。
///
/// | 出处 | 文案 |
/// | --- | --- |
/// | res 500→501 idx 56 | 因为找不到歌曲“%1$S”的原始文件，所以无法使用该歌曲。你想要查找它吗？ |
/// | res 143 idx 18 | 查找 |
/// | res 143 idx 19 | 你想要使用“%1$S”的位置来查找资料库中缺少的其他文件吗？ |
/// | res 143 idx 20 | 正在查找丢失的文件… |
/// | res 143 idx 21 | 查找文件 |
/// | res 143 idx 22 | “音乐”可以找到%1$S个缺少的文件（共%2$S个）。 |
/// | res 143 idx 23 | “音乐”找不到任何缺少的文件（共%S个）。 |
/// | res 143 idx 24 | 找不到标有“!”的文件。 |
/// | res 143 idx 25 | “音乐”可以找到所有缺少的文件。 |
///
/// **判定是懒的**——批次 45 由「没找到相反证据」升级成实测：整个原版
/// 7 个调用方，唯一具名的那个是 `-[AppStartPlaybackManager`
/// `startPlayingPlaylistItem:allowUserInteraction:playPlaylist:metricsDict:]`，
/// 即判定挂在**播放（使用）路径**上，
/// 不是后台扫描（§10.1.2）。所以这条链的入口只有一个——取流时拿不到文件
/// （`AppState.providerResolver`）。唯一一次全库扫描发生在用户点了「查找文件」之后，
/// 那是他自己要的，还带着进度页签。
///
/// 另一条旁证：res 143 整张表是**文件操作表**（拷贝 / 整合 / 定位），失联流程只占
/// idx 18–25 这一段，同表 idx 16/17 是「整合资料库」的两句警告 ⇒ 这批代码属于资料库的
/// **文件管理模块**，不是播放模块。
@MainActor
enum MissingFileLocator {

    // MARK: - 入口

    /// 用户点播的这一首找不到文件了。
    ///
    /// **只给用户主动点播的那一首弹**（判据是 `PlayerController.currentStartIsUserInitiated`）：
    /// 一队里连着好几首缺文件时，自动连播每撞一首弹一张会把用户埋了——那些照旧只打
    /// 感叹号（`LibraryStore.markFileMissing` 在取流那一步已经打过了）。
    ///
    /// 这条分档**仍是 `[推]`**：spec 没量过自动连播撞上时是什么行为，而「弹一串模态对话框」
    /// 不可能是任何一版 Music 的行为。批次 45 多的是一条正面旁证——弹窗那个函数唯一具名的
    /// 调用方形参里就写着 `allowUserInteraction:`（§10.1.2），说明 Music 自己也把「许不许
    /// 打断用户」做成了起播路径上的一个开关；**至于自动连播时它取什么值，spec 没说**。
    static func present(for track: Track, appState: AppState) {
        let window = hostWindow()
        let alert = NSAlert()
        // 整句就是正文，没有第二行说明：Music 那条串本身已经把原因和问题一起说全了。
        alert.messageText =
            "因为找不到歌曲“\(track.title)”的原始文件，所以无法使用该歌曲。你想要查找它吗？"
        alert.addButton(withTitle: "查找")
        // 次按钮在 ASM 里是**二选一**：`w8=(23987<<16)|2; w9=w8+2; cmp w22,#0` ——
        // `w22==0` 取 res 23987 idx 4「取消」、否则取 idx 2「否」（`w22` 到底是什么
        // spec 没说）。Amber 固定取「取消」那一支：这张弹窗在 Amber 侧只有「用户主动点播」
        // 一个来路，那条路上用户刚做了一个动作、这是在中途拦下他，「取消」才是 macOS 里
        // 退出一段流程的标准措辞。
        alert.addButton(withTitle: "取消")
        // NSAlert 只认英文 "Cancel" 才替它绑 esc，中文标题得自己补一条
        //（与 `DownloadRemovalAlert`、`LibraryDeleteAlert` 同一条）。
        alert.buttons[1].keyEquivalent = "\u{1b}"
        run(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            chooseFile(for: track, in: window, appState: appState)
        }
    }

    // MARK: - 指路

    /// 「查找」之后的选取面板。指完这一首当场接着播——用户点「查找」的意图就是想听它，
    /// 指完路还要回去再双击一次不合理。
    private static func chooseFile(for track: Track, in window: NSWindow?,
                                   appState: AppState) {
        let panel = NSOpenPanel()
        // 与「文件 › 导入…」同一份类型表（下下来的歌不少是 .mp4，只列 .audio 会把它们变灰）。
        panel.allowedContentTypes = ImportWorker.panelContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "打开"
        panel.message = "选择“\(track.title)”的原始文件"
        // 从它原来待的那一层开始找：文件多半只是被挪到了旁边。目录已经没了也无所谓，
        // 面板自己会退回默认位置。
        panel.directoryURL = track.localURL?.deletingLastPathComponent()
        let oldURL = track.localURL
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let picked = panel.url else { return }
            relocate(trackID: track.id, to: picked, appState: appState)
            // 接着播这一首。队列里那份 `Track` 还记着老路径，但取流第一跳读的是下载索引
            //（`relocate` 刚把它改成新位置），所以重来一次就能放出声。
            appState.player.retryCurrent(id: track.id)
            guard let oldURL else { return }
            askToFindOthers(anchor: picked, replacing: oldURL, in: window, appState: appState)
        }
        guard let window else {
            handler(panel.runModal())
            return
        }
        // 隔一拍再贴：警告那张 sheet 的完成回调回来时它自己还没从窗上撤干净，
        // 同一扇窗上紧接着 `beginSheetModal`，第二张会被吞掉——表现是点了「查找」
        // 什么都没发生。
        DispatchQueue.main.async {
            panel.beginSheetModal(for: window, completionHandler: handler)
        }
    }

    /// 一条曲目重新指路：资料库四处的副本 + 下载索引。
    ///
    /// 下载索引这一半不能省：取流第一跳问的就是它（`AppState.providerResolver`），
    /// 只改资料库的话，刚指完路的那一首照旧播不出来——它还在按索引里那条死路径找文件。
    private static func relocate(trackID: String, to url: URL, appState: AppState) {
        appState.library.relocateLocalTrack(id: trackID, to: url)
        guard let track = appState.library.track(withID: trackID) else { return }
        // 「外部」＝不在「媒体」文件夹里的原地引用（`DownloadStore.adoptLocalFile` 的语义）：
        // 用户可以把文件指到任何地方，指到媒体文件夹外面就是一份外部引用，
        // 以后从资料库删歌时不该跟着删它。
        let media = AppSettings.shared.values.mediaFolder.standardizedFileURL.path
        let external = !url.standardizedFileURL.path.hasPrefix(media + "/")
        appState.downloads.adoptLocalFile(at: url, for: track, external: external)
    }

    // MARK: - 顺手找回其余的

    /// res 143 idx 19：用刚指好的这个位置去找资料库里**其余**缺少的文件。
    ///
    /// 先扫一遍库，没有别的缺失就不问——问了之后无论回哪一条收尾文案都是废话。`[推]`
    private static func askToFindOthers(anchor: URL, replacing oldURL: URL,
                                        in window: NSWindow?, appState: AppState) {
        let others = appState.library.missingLocalTracks()
        guard !others.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "你想要使用“\(anchor.lastPathComponent)”的位置来查找资料库中缺少的其他文件吗？"
        alert.addButton(withTitle: "查找文件")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        run(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            findOthers(others, anchor: anchor, replacing: oldURL, in: window, appState: appState)
        }
    }

    /// 「正在查找丢失的文件…」那一段：贴一张进度页签，`stat` 全甩到后台，回来报账。
    private static func findOthers(_ tracks: [Track], anchor: URL, replacing oldURL: URL,
                                   in window: NSWindow?, appState: AppState) {
        let plan = tracks.compactMap { track -> (id: String, from: String)? in
            guard let path = track.localPath else { return nil }
            return (track.id, path)
        }
        let sheet = beginProgress(in: window)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                candidates(for: plan, anchor: anchor, replacing: oldURL)
            }.value
            for (id, url) in found { relocate(trackID: id, to: url, appState: appState) }
            endProgress(sheet, in: window)
            report(found: found.count, total: plan.count, in: window)
        }
    }

    /// 按「用户指的这份文件位移到哪儿了」把其余丢失路径推过去，逐条验存在。
    ///
    /// 两趟，都从同一件事出发——**用户指的那一份文件，老路径与新路径的公共后缀就是位移规律**：
    ///
    /// 1. **前缀改写**：老路径去掉公共后缀剩下的那一截换成新路径的那一截。
    ///    这一趟管的是最常见的两种现场：整个「媒体」文件夹改名/搬家、某一层目录被挪走。
    /// 2. **同名兜底**：第一趟推不出来的，试试新文件所在的那个目录里有没有同名文件。
    ///    管的是「文件原本散在各处、现在被一股脑收进同一个文件夹」。
    ///
    /// Music 具体怎么找 spec **仍**没有证据（§10.1.1 读到的是弹窗那个函数的控制流，
    /// 批量修复的函数体没展开），这两趟是照「使用它的**位置**」这句话
    /// 推的，标 `[推]`。判据是「推出来的路径上真有文件」，所以推错了也只是找不回来，
    /// 不会把条目指到一份不相干的文件上。
    nonisolated static func candidates(for plan: [(id: String, from: String)],
                                       anchor: URL, replacing oldURL: URL) -> [(String, URL)] {
        let fm = FileManager.default
        let (oldPrefix, newPrefix) = shift(from: oldURL, to: anchor)
        let anchorDirectory = anchor.standardizedFileURL.deletingLastPathComponent()
        var result: [(String, URL)] = []
        for item in plan {
            let path = URL(fileURLWithPath: item.from).standardizedFileURL.path
            var candidate: URL?
            if !oldPrefix.isEmpty, path.hasPrefix(oldPrefix + "/") {
                let tail = String(path.dropFirst(oldPrefix.count + 1))
                candidate = URL(fileURLWithPath: newPrefix).appendingPathComponent(tail)
            }
            if candidate == nil || !fm.fileExists(atPath: candidate!.path) {
                let sameName = anchorDirectory
                    .appendingPathComponent((path as NSString).lastPathComponent)
                candidate = fm.fileExists(atPath: sameName.path) ? sameName : nil
            }
            guard let candidate, fm.fileExists(atPath: candidate.path) else { continue }
            result.append((item.id, candidate))
        }
        return result
    }

    /// 位移规律：两条路径的公共后缀之前，各自剩下的那一截。
    ///
    /// `/Volumes/D/音乐/A/B/x.m4a` → `~/Music/Amber/A/B/x.m4a` 得到
    /// （`/Volumes/D/音乐`，`~/Music/Amber`）：公共后缀是`A/B/x.m4a`。
    /// 两条路径完全相同（用户又指回了原处）时公共后缀吃掉全部，返回两个空串，
    /// 第一趟自然全不命中——这正是想要的，那种情况下没有任何位移可推。
    nonisolated private static func shift(from oldURL: URL,
                                          to newURL: URL) -> (old: String, new: String) {
        var old = oldURL.standardizedFileURL.pathComponents
        var new = newURL.standardizedFileURL.pathComponents
        while let a = old.last, let b = new.last, a == b, old.count > 1, new.count > 1 {
            old.removeLast()
            new.removeLast()
        }
        func join(_ components: [String]) -> String {
            let path = NSString.path(withComponents: components)
            // `pathComponents` 的第一格是 "/"，拼回去会多一条尾斜杠（"/" 本身除外）。
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        // 只剩根了 ＝ 没有可用的公共后缀（两条路径连文件名都不同），第一趟直接放弃。
        guard old.count > 1, new.count > 1 else { return ("", "") }
        return (join(old), join(new))
    }

    /// 三条**独立**的收尾文案（spec §10.1 第 3 条：不是一句带参数的话）。这四条串
    /// （idx 25 全找到 / idx 24 `!` 说明 / idx 22 找到 M of N / idx 23 一个没找到）的取串点
    /// 已逐个定位在内，`[实测]`。
    private static func report(found: Int, total: Int, in window: NSWindow?) {
        let alert = NSAlert()
        switch found {
        case total:
            alert.messageText = "“Amber”可以找到所有缺少的文件。"
        case 0:
            alert.messageText = "“Amber”找不到任何缺少的文件（共\(total)个）。"
            alert.informativeText = "找不到标有“!”的文件。"
        default:
            alert.messageText = "“Amber”可以找到\(found)个缺少的文件（共\(total)个）。"
            alert.informativeText = "找不到标有“!”的文件。"
        }
        alert.addButton(withTitle: "好")
        run(alert, in: window) { _ in }
    }

    // MARK: - 进度页签

    /// res 143 idx 20。没有可贴的窗就整个省掉——这一段是纯提示，缺了不影响结果，
    /// 而 `runModal` 一个没有按钮的窗只会把自己卡死在那儿。
    private static func beginProgress(in window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        let label = NSTextField(labelWithString: "正在查找丢失的文件…")
        label.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                            constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        let sheet = NSWindow(contentRect: content.frame, styleMask: [.titled],
                             backing: .buffered, defer: true)
        sheet.contentView = content
        window.beginSheet(sheet)
        bar.startAnimation(nil)
        return sheet
    }

    private static func endProgress(_ sheet: NSWindow?, in window: NSWindow?) {
        guard let sheet, let window else { return }
        window.endSheet(sheet)
    }

    // MARK: - 小工具

    private static func hostWindow() -> NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// 有窗就贴成页签，没窗退回 `runModal`（与`DownloadRemovalAlert` 同一条）。
    private static func run(_ alert: NSAlert, in window: NSWindow?,
                            completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else {
            completion(alert.runModal())
            return
        }
        // 与上面选取面板同一个理由：上一张页签的完成回调回来时它还没从窗上撤干净。
        DispatchQueue.main.async {
            alert.beginSheetModal(for: window, completionHandler: completion)
        }
    }
}
