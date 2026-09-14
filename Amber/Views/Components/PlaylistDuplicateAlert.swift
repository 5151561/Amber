import AppKit

// 加入播放列表时撞重的询问。
//
// 出处：library 规格 §10.4（`[RES]`+`[TYPE]`，基线 macOS 27 26A428）。
// 那一节把「撞名」拆成三条互不相干的链，本文件做的是**第二条**：
//
// - 云端撞名（res 9013 idx 34–36，`Keep Duplicate` / `Delete Duplicate`）——Amber 没有云库，不做；
// - **加入歌单撞重（这一条）**——语义是「加还是跳过」；
// - 导入撞名（res 500 idx 124–126）——语义是「替换」，见 `ImportReplaceAlert`。
//
// 「二值」不是猜的，是这几条串一起坐实的：pref 名 `MusicLibraryManager_AddToPlaylistDuplicatePolicy`
// ObjC 入口 `addItemIdentifiers:playlist:duplicatePolicy:completion:`、
// assert 串 `outShouldAddDuplicates != nullptr`（一个出参布尔，不是三态枚举）、
// 日志串 `User selected to not add duplicates to playlist.`，以及
// `result != PlaylistEditingAddDuplicateResult::eUndefined`。所以按钮只有两颗，
// **不许自己加「取消」**——那会把二值决定悄悄变成三选一。

/// 撞重询问里**不碰 AppKit 的那一半**：谁算重复、两支各自最终加哪些。
///
/// 单独拎出来是为了能离线单测（`AmberTests/PlaylistDuplicateTests.swift`）——
/// 弹窗那半截要真起一个 `NSAlert` 才跑得动，规则这半截不该跟着一起被挡在测试之外
/// （与 `ImportReplacePrompt` 同一条理由）。
enum PlaylistDuplicatePlan {

    /// 一次「加入播放列表」的两条出路。问句一出，用户选哪颗就用哪一支。
    struct Plan: Equatable {
        /// `添加`（res 9008 idx 37）：原样全加，重复的照加不误——
        /// 这正是 `LibraryStore.addTracks` 一直以来的行为（Music 允许同一首在一份列表里出现多次）。
        let addingAll: [Track]
        /// `跳过`（res 9008 idx 38）：把重复的剔掉之后剩下的。
        let skippingDuplicates: [Track]

        /// 撞了几条。
        var duplicateCount: Int { addingAll.count - skippingDuplicates.count }

        /// 要不要问这一句。判据是**两支的结果不一样**——一样就没什么可问的，
        /// 问了反而是拿一个没有分歧的选择去拦用户。
        var hasDuplicates: Bool { duplicateCount > 0 }
    }

    /// 判重口径：**按 `Track.id` 比**，不比曲名。
    ///
    /// Amber 的 `Track.id` 形如`ne:347230` / `qq:0039Mn…` / 本地导入的`local:<sha1>`
    /// （见 `Models.swift`），同一首歌在 Amber 里就是同一个 id；反过来，两首同名不同源的歌
    /// 是两个 id，本来就该各占一行。
    ///
    /// 这与 §10.3 的「显示重复项目」**不是一回事**：那一档是资料库的**视图过滤**
    /// （`contentIsShowingDuplicates`，宽松/严格两个档位按曲名等字段比，且只过滤显示、
    /// 不自动合并不自动删）。本条是加入歌单这一刻的一次性判定，只问「这份列表里已经有它了吗」。
    ///
    /// 批内自己重复（同一批里同一个 id 出现两次）算不算重复：**`[推]`**——spec 没有证据。
    /// 这里定成**算**，模型是「按顺序一首一首往列表里放」：第一份落进去之后，
    /// 后面那几份就是「列表里已经有的那首」的重复了，与它们本来就在列表里没有区别。
    /// 另一种定法（只跟原有曲目比、批内重复照放）被否掉的理由是它会让「跳过」自相矛盾：
    /// 用户明说了不要重复项，结果列表里还是多出了一对新的重复。
    static func plan(adding tracks: [Track], existing: [Track]) -> Plan {
        // 预置成列表现有的 id，随后一边扫一边长——这一句就是上面那个「按顺序放」的模型本身。
        var seen = Set(existing.map(\.id))
        var kept: [Track] = []
        for track in tracks where seen.insert(track.id).inserted { kept.append(track) }
        return Plan(addingAll: tracks, skippingDuplicates: kept)
    }
}

/// 弹窗那一半。形状照抄 `ImportReplaceAlert` / `LibraryDeleteAlert`：
/// 有宿主窗就贴 sheet，没有就 `runModal`。
///
/// **只管本地可编辑的播放列表**（`LibraryStore.addTracks` 那条路）。账号歌单那条
/// （`AppState.addTracksToAccountPlaylist`）不走这里：那边的去重归音源管，
/// Amber 手上连那份歌单的完整曲目表都没有（是按需现取的镜像），拿什么判重都是编的。
@MainActor
enum PlaylistDuplicateAlert {

    /// 往本地列表里加歌的**唯一入口**：不撞重就一句不问直接加，撞了才问。
    ///
    /// `LibraryStore.addTracks` 本身不动：它是数据层，「加还是跳过」是用户的决定，
    /// 属于界面层——同一个数据层调用，两支只是喂给它的曲目不同而已。
    ///
    /// `completion` 收到的是**真加进去的条数**。调用方拿它决定报不报「已加入」：
    /// 用户选了「跳过」而一条也没落地时还弹一句「已加入」就是句假消息
    /// （与 `AppState.promptNewPlaylist` 那次修的是同一种病）。
    static func addTracks(_ tracks: [Track], to playlist: LibraryPlaylist,
                          library: LibraryStore, in window: NSWindow? = nil,
                          completion: @escaping (Int) -> Void) {
        guard !tracks.isEmpty, playlist.isEditable else {
            completion(0)
            return
        }
        // 列表现有的曲目现查一遍，不用调用方手上那份快照——菜单是打开那一刻搭的，
        // 从搭好到点下去之间列表可能已经被别处改过了。
        let existing = library.playlists.first { $0.id == playlist.id }?.tracks ?? []
        let plan = PlaylistDuplicatePlan.plan(adding: tracks, existing: existing)
        guard plan.hasDuplicates else {
            library.addTracks(tracks, toPlaylist: playlist.id)
            completion(tracks.count)
            return
        }
        ask(in: window ?? hostWindow()) { addDuplicates in
            let picked = addDuplicates ? plan.addingAll : plan.skippingDuplicates
            if !picked.isEmpty { library.addTracks(picked, toPlaylist: playlist.id) }
            completion(picked.count)
        }
    }

    /// 问句 res 9008 idx 36、按钮 res 9008 idx 37/38，三条都是实测的中文原文 `[RES]`。
    /// 回调 true ＝ 用户选了「添加」。
    private static func ask(in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "有一些重复项目正在添加到播放列表。你是想要添加这些重复项目，还是想要跳过它们？"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "跳过")
        // esc 绑给「跳过」是 `[推]`：spec 只给了这两颗按钮，没说哪颗吃 esc。
        // 选保守的那一支——两支都会往列表里加东西，「跳过」加得少、且不制造新的重复项，
        // 误按 esc 的代价小；而且它对应的正是那句日志
        //（`User selected to not add duplicates to playlist.`）所记的那一支。
        // 中文标题拿不到 NSAlert 自动给的 esc（系统只对英文 "Cancel" 绑），得手补
        //（同 `ImportReplaceAlert` / `LibraryDeleteAlert` 里那条注释）。
        alert.buttons[1].keyEquivalent = "\u{1b}"
        // spec 只给了这一句问话，没有配套的补充说明串，所以 `informativeText` 空着——
        // 自己编一句「解释」等于往复刻里掺私货。
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        // 隔一拍再贴：上一张 sheet 的完成回调回来时它自己还没从窗上撤干净，
        // 同一扇窗上紧接着 `beginSheetModal`，第二张会被吞掉
        //（与 `ImportReplaceAlert` / `LibraryDeleteAlert` / `MissingFileLocator` 同一条）。
        DispatchQueue.main.async {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        }
    }

    /// 菜单那类入口手上没有宿主窗，自己去问一次（与 `LibraryDeleteAlert` 同一条）。
    private static func hostWindow() -> NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }
}
