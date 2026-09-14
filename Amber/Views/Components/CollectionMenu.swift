import AppKit

// MARK: - 专辑 / 歌单 / 艺人的右键 / ••• 菜单

/// 「一张碟、一份歌单、一个艺人」这类**集合**的菜单。曲目那份在 `TrackActions`。
///
/// 项序照实测的 `-[CatalogAlbumHeaderModel actionMenuFromSender:]`（真身，
/// 19 个 action 依次入栈 → `createMenuForActions:hideDisabled:YES`，14 项 6 段）：
///
/// ```
/// Pin、Unpin | Add to Library、Download、Remove Download、Add to Playlist ▸
/// | Play Next、Add to Queue | Favorite、Undo Favorite、Suggest Less、Undo Suggest Less
/// | Share ▸ | Delete from Library
/// ```
///
/// 与目录曲目行那份（`TrackActions.catalogRow`）逐段同构，只少了 Create Station 与 Get Info。
///
/// **调用方只报「自己能做什么」**：给了闭包就是能做，没给就是不能做，
/// 排在哪由本文件说了算。这样六处卡片/页头不必各自再排一遍顺序——
/// 从前正是各排各的，才排出了「专辑网格卡没有下载、专辑页头也没有、
/// 艺人页里那颗 ••• 却有」这种看着像抄漏的差异。
///
/// 摘项与分隔线规矩见 `MenuSpec`：没给的闭包＝不可用＝不摆，空掉的分隔线自动并掉。
@MainActor
struct CollectionActions {

    /// **Amber 加的两条**：实测那份页头菜单里没有「播放」——你已经站在那一页上了。
    /// 卡片不是页面，点一下是进去而不是播放，所以卡片菜单需要它。`[Amber]`
    var play: (() -> Void)?
    var shuffle: (() -> Void)?

    var addToLibrary: (() -> Void)?
    /// 实测里「从资料库中删除」是**最后一项**，与「添加到资料库」隔着整份菜单——
    /// 所以这两条是两个字段而不是一条可切换项。
    var deleteFromLibrary: (() -> Void)?
    var download: (() -> Void)?
    var removeDownload: (() -> Void)?

    var playNext: (() -> Void)?
    var addToQueue: (() -> Void)?

    /// 心水与取消心水同样是两条（[实测] spec §3.2：判据同一个、方向相反，永远只出现一个）。
    var favorite: (() -> Void)?
    var undoFavorite: (() -> Void)?

    /// 「减少推荐 / 撤销减少推荐」。目前只有**艺人**接得上（QQ 的不喜欢名单收歌手），
    /// 专辑与歌单两家都没有对应接口，那两处一条都不给，于是整对自动不摆。
    /// 判据与接线见 `AppState.canSuggestLess(artist:less:)`。
    var suggestLess: (() -> Void)?
    var undoSuggestLess: (() -> Void)?

    /// 「前往专辑 / 前往歌单 / 前往艺人」——标题随落点类型换。
    var goTo: (title: String, run: () -> Void)?
    /// 副标题上那个艺人的落点（卡片副标题可点时才有）。
    var goToArtist: (() -> Void)?
    /// 取流被拒时的兜底：还能去音源网页版看（MV 卡）。`[Amber]`
    var openOnWeb: (() -> Void)?
    /// 「分享 ▸」交给系统共享菜单的那条链接：音源网页版的公开页面
    /// （`Album.webShareURL` 这一族，见`ProviderWebLink`）。给不出就不摆。
    var shareURL: URL?

    /// Amber 自己的两条歌单管理项，Music 无对应。摆在破坏性末段之前。`[Amber]`
    var rename: (() -> Void)?
    var syncAccount: (() -> Void)?

    /// 「添加到播放列表 ▸」整条交进来：它是子菜单，内容用曲目那份现成的
    /// （`TrackActions.addToPlaylistEntry`，本机列表 + 账号歌单两段）。
    /// 同一件事不在这里再写一份。nil = 这一页拿不出曲目。
    var addToPlaylist: MenuSpec.Entry?

    /// 「评分 ▸」。整张碟一个分（与页头那排星同一份，`LibraryStore.rating(for:)`）。
    var rating: (current: Int, set: (Int) -> Void)?

    /// 「勾选所选项 / 取消勾选所选项」。与曲目菜单的 `doCheckSelectedTracks:` 同解：
    /// 整批一起勾、一起取消；勾选列关着时不给，整条不摆。
    var check: (isAllChecked: Bool, run: () -> Void)?

    init() {}
}

// MARK: - 项序

extension CollectionActions {

    var entries: [MenuSpec.Entry] {
        [
            // Amber 没有「置顶」（资料库里没有置顶这个概念）——列在原位，摘掉后整段自然并掉。
            .command(.init("置顶")),
            .command(.init("取消置顶")),
            .separator,
            .command(.init("播放", run: play)),
            .command(.init("随机播放", run: shuffle)),
            .separator,
            .command(.init("添加到资料库", run: addToLibrary)),
            .command(.init("下载", run: download)),
            .command(.init("移除下载", run: removeDownload)),
            .separator,
            .command(.init("稍后播放", symbol: "text.line.first.and.arrowtriangle.forward",
                           run: playNext)),
            .command(.init("加入待播清单", symbol: "text.line.last.and.arrowtriangle.forward",
                           run: addToQueue)),
            .separator,
            // 集合用「喜爱」、曲目用「心水」——Amber 一直分着用，不要互换。
            // （Music 实测两处都是 `FAVORITE_MENU_ITEM` = 喜爱，Amber 在曲目上另择了词，此处从旧。）
            .command(.init("喜爱", run: favorite)),
            .command(.init("取消喜爱", run: undoFavorite)),
            .command(.init("减少推荐", run: suggestLess)),
            .command(.init("撤销减少推荐", run: undoSuggestLess)),
            .separator,
            // 导航段的位置照播放队列那份实测（前往… → 分享同段，排在末段之前）。`[推]`
            .command(.init(goTo?.title ?? "前往", run: goTo?.run)),
            .command(.init("前往艺人", run: goToArtist)),
            .command(.init("在网页中打开", run: openOnWeb)),
            MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                                urls: [shareURL].compactMap { $0 }),
            .separator,
            .command(.init("重命名…", run: rename)),
            .command(.init("刷新账号歌单", run: syncAccount)),
            .separator,
            .command(.init("从资料库中删除", run: deleteFromLibrary)),
        ]
    }

    /// **资料库专辑页标题栏右端那颗 •••**。
    /// [实机截图 2026-09-09 用户提供]（两张，差别只在剪贴板里有没有图 →「粘贴」出不出现）：
    ///
    /// ```
    /// 置顶专辑、下载、添加到播放列表 ▸ | 插播 | 获得专辑插图、（粘贴）
    /// | 分享 ▸ | 在 Apple Music 中显示
    /// | 喜爱、减少推荐、评分 ▸、取消勾选所选 | 从资料库删除
    /// ```
    ///
    /// **与页头那份（`entries`）不是一份**，Music 自己就排得不一样：这里「分享 ▸」自成一段
    /// 且排在「在 Apple Music 中显示」**之前**（页头那份是同段且在其后）、评价四条甩到末段、
    /// 「插播」那一段只有一条、第一段不分隔就接上「下载 / 添加到播放列表」。
    /// 这正是本文件开头那句：项序由各装配点各出一份，差异是 Music 有意为之。
    var albumPageEntries: [MenuSpec.Entry] {
        [
            .command(.init("置顶专辑")),
            // 截图那张碟已在资料库里，所以没有这一条；目录里的碟要有，位置照页头那份
            // 摆在「下载」之前。`[推]`
            .command(.init("添加到资料库", run: addToLibrary)),
            .command(.init("下载", run: download)),
            .command(.init("移除下载", run: removeDownload)),
            addToPlaylist ?? .command(.init("添加到播放列表")),
            .separator,
            .command(.init("稍后播放", symbol: "text.line.first.and.arrowtriangle.forward",
                           run: playNext)),
            // Music 这一段只有「插播」一条；Amber 的这一对一路都是连着的，后一条留在原位。`[Amber]`
            .command(.init("加入待播清单", symbol: "text.line.last.and.arrowtriangle.forward",
                           run: addToQueue)),
            .separator,
            // 这两条 Amber 没有：封面来自音源，换不了，也就无所谓从剪贴板贴一张。
            .command(.init("获得专辑插图")),
            .command(.init("粘贴")),
            .separator,
            MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                                urls: [shareURL].compactMap { $0 }),
            .separator,
            // Music 那条是「在 Apple Music 中显示」——Amber 的「店」是音源的网页版。
            .command(.init("在网页中打开", run: openOnWeb)),
            .separator,
            .command(.init("喜爱", run: favorite)),
            .command(.init("取消喜爱", run: undoFavorite)),
            .command(.init("减少推荐", run: suggestLess)),
            .command(.init("撤销减少推荐", run: undoSuggestLess)),
            ratingEntry,
            checkEntry,
            .separator,
            .command(.init("从资料库中删除", run: deleteFromLibrary)),
        ]
    }

    /// **播放列表页那颗 ••• / 页头右键**——Music 里这两处是**同一份菜单**。
    ///
    /// 两个出处对上了：
    ///
    /// 1. [实机截图 2026-09-09 23:49 用户提供]（心水歌曲页，部分曲目已下载）实际可见的是
    ///    `置顶播放列表、下载 | 插播 | 在新窗口中打开 | 分享 ▸ | 取消勾选所选 | 移除下载`；
    /// 2. [RES] `playlists 规格` §6.0.1（macOS 27 / 26A5425a）——
    ///    `-[PlaylistHeaderModel actionMenuFromSender:]` 最后一步直接把
    ///    **全局共享的 `NSApp.trackContextMenu`** 还回去（前面那一大段 C++ 是在拼
    ///    「当前选中了什么」的 objectSpec，不是在拼菜单项）；菜单项**静态定义在
    ///    `MainMenu.nib`** 里，共 **73 项、全部默认隐藏**，运行时按 objectSpec 逐项显隐。
    ///
    /// **裁剪不改顺序**：截图那份子集在 nib 全集里的编号是
    /// Pin 3 → Download 7 → Play Next 18 → Open in New Window 29 → Share 31 →
    /// Uncheck Selection 46 → Remove Download 54，**严格递增**。所以 nib 那张表就是项序权威，
    /// 下面每一条都标了它在全集里的编号，日后要补别的项按编号插进去即可。
    /// （哪些项在歌单页真的会显示，那一层仍是缺口——`ItemNSMenuHelper.menuNeedsUpdate:`
    /// 里 2971 条的大构建器没走完，记在 contextmenu spec 名下。）
    ///
    /// 与专辑页那份（`albumPageEntries`）的差别是 Music 自己排的：这里没有
    /// 「添加到播放列表 / 喜爱 / 减少推荐 / 评分」，多了「在新窗口中打开」
    /// （nib #29 `doOpenInNewWindow:`；[实测] §8.4`Music.StandalonePlaylistWindowController`，
    /// 最小 780×580 的独立窗），而且「移除下载」(#54) 排在「从资料库中删除」(#55) **之前**。
    ///
    /// 截图那一页「下载」与「移除下载」**同时出现**（部分曲目已下载），
    /// 所以这两条在 Amber 侧也按能力各给各的，不是二选一。
    var playlistPageEntries: [MenuSpec.Entry] {
        [
            // Amber 没有「置顶」；「在新窗口中打开」同样没有（Amber 只有主窗与迷你窗）。
            // 两条都列在原位，摘掉后整段自然并掉，与专辑页那份的「获得专辑插图 / 粘贴」同解。
            // #3 Pin：Amber 没有「置顶」；#29 Open in New Window 同样没有（只有主窗与迷你窗）。
            // 两条都列在原位，摘掉后整段自然并掉，与专辑页那份的「获得专辑插图 / 粘贴」同解。
            .command(.init("置顶播放列表")),
            // #5 Add to Library。目录里的歌单才有。
            .command(.init("添加到资料库", run: addToLibrary)),
            // #7 Download
            .command(.init("下载", run: download)),
            .separator,
            // #18 Play Next / #19 Add to Queue——nib 里这两条就是挨着的，图标也照它。
            .command(.init("稍后播放", symbol: "text.line.first.and.arrowtriangle.forward",
                           run: playNext)),
            .command(.init("加入待播清单", symbol: "text.line.last.and.arrowtriangle.forward",
                           run: addToQueue)),
            .separator,
            // #29 Open in New Window
            .command(.init("在新窗口中打开")),
            .separator,
            // #31 Share（nib 里就是子菜单 + `square.and.arrow.up`）
            MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                                urls: [shareURL].compactMap { $0 }),
            .separator,
            // #45/#46 Check / Uncheck Selection
            checkEntry,
            .separator,
            // #50 Rename…。原先照 `entries` 摆在「分享」之后，按 nib 编号是错的：
            // 它排在勾选那一段（45/46）之后。「刷新账号歌单」是 Amber 自己的，跟着它走。`[Amber]`
            .command(.init("重命名…", run: rename)),
            .command(.init("刷新账号歌单", run: syncAccount)),
            .separator,
            // #54 Remove Download
            .command(.init("移除下载", run: removeDownload)),
            // #55 Delete from Library（**歌单版** `doDeletePlaylistFromLibrary:`；nib 里
            // #56 是曲目版，两条各算一项——与 §2.5 Delete 键「有没有选中行」的分叉对上）。
            // 截图那一页是心水歌曲、删不掉，所以没显示这一条。
            .command(.init("从资料库中删除", run: deleteFromLibrary)),
        ]
    }

    /// Music 的评分子菜单是「无 / ★…★★★★★」六项单选（与曲目那份同形）。
    private var ratingEntry: MenuSpec.Entry {
        guard let rating else { return .command(.init("评分")) }
        return .submenu(.init("评分"), (0...5).map { value in
            .command(.init(value == 0 ? "无" : String(repeating: "★", count: value),
                           isOn: value == rating.current, run: { rating.set(value) }))
        })
    }

    private var checkEntry: MenuSpec.Entry {
        .command(.init(check?.isAllChecked == true ? "取消勾选所选项" : "勾选所选项",
                       run: check?.run))
    }

    /// 一条能做的都没有时返回 nil——卡片没有可做的事就不该弹一份空菜单出来。
    func makeMenu() -> NSMenu? {
        let menu = MenuSpec.makeMenu(entries)
        return menu.items.isEmpty ? nil : menu
    }
}
