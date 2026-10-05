import AppKit

// MARK: - 曲目的右键 / ••• 菜单

/// 曲目菜单的**动作定义**：一个动作一份，≈ Music 那 25 个 `AMPAction` 子类
/// （[实测] contextmenu spec §2）。每一份自己算可用性（≈ `isValid`）与执行体
/// （≈ `executeWithCompletion:`），**不管自己排在哪**。
///
/// 项序由各界面各出一份数组（`catalogRow` / `libraryRow` / `queueRow`），
/// 照搬 Music 那 4 个装配点各传各的 action 数组。**这一层必须分开**：实测下来
/// 各处菜单的大段排布确实不同（目录三处是 6 段、播放队列是 8 段且把入库与
/// 「从队列中移除」提到最前、把「移除下载」甩到末段），不是一份表能盖住的。
///
/// Music 的菜单对**整份选中集**生效（`specListForSelectedItems`），所以这里收的是一组曲目：
/// 单行右键就是一首，表格里多选后右键则是多首。只对单曲有意义的项（前往专辑/艺人）
/// 在多选时自动不可用，于是被摘掉——与 Music 靠 `isValid` 摘项同解。
///
/// **互斥对拆成两份定义**（心水/取消心水、添加到资料库/从资料库中删除、下载/移除下载）：
/// Music 就是两个类、判据同一个方向相反（spec §3.2），永远只出现一个。拆开的好处是
/// 它们能排在**不同位置**——实测里「添加到资料库」在第 2 段、「从资料库中删除」是最后一项，
/// 队列那份的「下载」在第 4 段而「移除下载」在末段。合成一条会话可切换项就排不出来了。
@MainActor
struct TrackActions {

    let tracks: [Track]
    unowned let appState: AppState
    /// 这份菜单是从哪份列表里弹出来的：整份可见行 + 当前行的下标。
    /// 给了它，「播放」就是 Music 的「从这一行开始放，后面接着放」；不给才退回「只播选中的」。
    var playContext: TrackPlayContext?
    /// 「从播放列表中删除」这类只在特定列表里成立的移除项，不给就不摆。
    var remove: (title: String, run: () -> Void)?
    /// 「播放」这一项在没有曲目上下文的卡（电台/节目）上直接走卡自己的 onPlay。
    var fallbackPlay: (() -> Void)?

    init(tracks: [Track], appState: AppState,
         playContext: TrackPlayContext? = nil,
         remove: (title: String, run: () -> Void)? = nil,
         fallbackPlay: (() -> Void)? = nil) {
        self.tracks = tracks
        self.appState = appState
        self.playContext = playContext
        self.remove = remove
        self.fallbackPlay = fallbackPlay
    }

    private var player: PlayerController { appState.player }
    private var library: LibraryStore { appState.library }
    /// 下载状态直接问 appState 手里那份：菜单每次打开都重建，读一次快照就够。
    private var downloads: DownloadStore { appState.downloads }

    private var single: Track? { tracks.count == 1 ? tracks[0] : nil }
    private var isCurrent: Bool {
        guard let single else { return false }
        return player.currentTrack?.id == single.id
    }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    /// 多选时，只要还有没心水的就整批心水；全都心水了才是「取消心水」。
    private var allFavorite: Bool { !tracks.isEmpty && tracks.allSatisfy { library.isFavorite($0) } }
    private var allInLibrary: Bool { !tracks.isEmpty && tracks.allSatisfy { library.isInLibrary($0) } }
    private var allDownloaded: Bool { !tracks.isEmpty && tracks.allSatisfy { downloads.isDownloaded($0.id) } }
    /// 这一批里有「文件 › 导入…」进来的本地曲目（`local:` 前缀，见`Track.isLocal`）。
    /// 它本来就在本机，下载/移除下载对它没有意义——「移除下载」只会把「媒体」文件夹里
    /// 那份删掉，留下一条播不响的资料库记录。
    private var hasLocal: Bool { tracks.contains(where: \.isLocal) }
    /// 全都勾着才是「取消勾选所选项」，只要还有没勾的就整批勾上（与心水那条同解）。
    private var allChecked: Bool { !tracks.isEmpty && tracks.allSatisfy { library.isChecked($0) } }

    private var isEmpty: Bool { tracks.isEmpty }
}

// MARK: - 各界面的项序

extension TrackActions {

    /// **目录页的曲目行 / 目录卡**。
    ///
    /// 实测项序：`-[CatalogAlbumTracksModel actionMenuForItems:source:]` 的真身
    /// 21 个 action 依次入栈到栈上数组，
    /// `arrayWithObjects:count:21` → `createMenuForActions:hideDisabled:YES`，**槽位偏移即项序**。
    /// `-[CatalogPlaylistTracksModel actionMenuForItems:source:]` 逐项完全一致。
    ///
    /// ```
    /// Pin、Unpin | Add to Library、Download、Remove Download、Add to Playlist ▸
    /// | Play Next、Add to Queue、Create Station
    /// | Get Info、Favorite、Undo Favorite、Suggest Less、Undo Suggest Less
    /// | Share ▸ | Delete from Library
    /// ```
    func catalogRow() -> [MenuSpec.Entry] {
        [playEntry, .separator]
            + libraryAndDownloadSegment
            + [.separator]
            + queueSegment
            + [.separator]
            + tasteSegment
            + [.separator, shareEntry, .separator, deleteFromLibraryEntry]
    }

    /// **资料库表格里的曲目行**（歌曲表、专辑/歌单/艺人详情页的曲目表）。
    ///
    /// Music 这一处走的是旧栈 `ItemNSMenuHelper` 的大构建器，
    /// **这一块尚未走完**（contextmenu spec §10-2 的最大剩矿），所以没有实测项序可抄。
    /// 这里按最近的有实测的同类菜单拼：主体照目录曲目行，导航段的位置照播放队列那份
    /// （队列实测里「前往播放列表/专辑/艺人 → 在 iTunes Store 中显示 → 分享」同段，
    /// 排在评价段之后、拷贝之前）。`[推]`
    func libraryRow() -> [MenuSpec.Entry] {
        [playEntry, .separator]
            + removeSegment
            + libraryAndDownloadSegment
            + [.separator]
            + queueSegment
            + [.separator]
            + tasteSegment
            + [.separator]
            + navigationSegment
            + [.separator, copyEntry, .separator, deleteFromLibraryEntry]
    }

    /// **播放队列的行右键**。
    ///
    /// 实测项序：`-[ITPlayQueueModel actionMenuForItems:source:]` @。
    /// 这一处**不走** `createMenuForActions:`，是直接`NSMenu.addItem:` 逐个加，
    /// 21 项 + 7 条分隔线 = 8 段；末尾自己实现「禁用即隐藏」。
    ///
    /// ```
    /// Add to Library、从队列中移除 | Pin、Unpin | Play Next、Add to Queue
    /// | Download、Add to Playlist ▸
    /// | Get Info、Favorite、Undo Favorite、Suggest Less、Undo Suggest Less、Create Station
    /// | Go to Playlist、Go to Album、Go to Artist、Show in iTunes Store、Share ▸
    /// | Copy | Remove Download、Delete from Library
    /// ```
    /// 注意与目录那份的三处不同：入库与移除被提到最前、队列段提前到第 3 段、
    /// 「移除下载」被甩到末段与「从资料库中删除」作伴。
    func queueRow() -> [MenuSpec.Entry] {
        [playEntry, .separator, addToLibraryEntry] + removeSegment
            + [.separator, pinEntry, unpinEntry,
               .separator] + queueSegmentWithoutStation
            + [.separator, downloadEntry, addToPlaylistEntry, .separator]
            + tasteSegment + [createStationEntry, .separator]
            + navigationSegment
            + [.separator, copyEntry,
               .separator, removeDownloadEntry, deleteFromLibraryEntry]
    }

    /// 「添加到播放列表 ▸」里的账号歌单那一段（一家音源一段，段头写音源名）。
    /// 一份可写的都没有时是空数组，整段连标题一起不摆。
    ///
    /// 摆在这一层而不是私有那一层，是因为播放器那份 ••• 菜单（`PlayerMoreMenu`）
    /// 要拼同一段——两处的「添加到播放列表」得是同一件事，不能各写各的。
    var accountPlaylistSection: [MenuSpec.Entry] {
        let playlists = appState.writableAccountPlaylists(for: tracks)
        guard let kind = playlists.first?.kind else { return [] }
        return [.section("\(kind.displayName)的歌单", playlists.map { playlist in
            .command(.init(playlist.name, run: {
                appState.addTracksToAccountPlaylist(tracks, playlist: playlist)
            }))
        })]
    }

    /// 「添加到播放列表 ▸」。两段：Amber 自己建的列表，以及**登录账号里自建的歌单**
    /// （后者按音源分段，见 `AppState.writableAccountPlaylists`）。
    ///
    /// 账号歌单这一段是新接的：从前这里只有本机列表，理由是「账号歌单是只读镜像」——
    /// 现在两家都有了往歌单里加歌的接口，那就该让用户加得进去。加完 Amber 这边不动镜像，
    /// 下次点开那份歌单会现向音源取（见 `addTracksToAccountPlaylist`）。
    /// **心水仍然只在本机**：那是 Amber 自己的资料库属性，不往账号里写。
    ///
    /// Music 这一条是唯一自带**动态子菜单**的 action（`JRNSMenu` + `AddToPlaylistNSMenuHelper`，
    /// 内容在菜单打开那一刻才算，spec §3.9）；Amber 的菜单本来就是每次打开重建，等价。
    ///
    /// 与 `accountPlaylistSection` 同理摆在这一层：专辑页那颗 ••• 也要「添加到播放列表 ▸」，
    /// 而那是整张碟的曲目——同一件事不能让 `CollectionActions` 再写一份。
    var addToPlaylistEntry: MenuSpec.Entry {
        guard !isEmpty else { return .command(.init("添加到播放列表")) }
        // 先弹命名框，确认之后才建列表并报「已加入」——从前是当场就建、toast 也当场就报，
        // 取消之后留下一份列表和一句假消息。见 AppState.promptNewPlaylist。
        var children: [MenuSpec.Entry] = [
            .command(.init("新建播放列表", run: { appState.promptNewPlaylist(with: tracks) })),
        ]
        let targets = library.editablePlaylists
        if !targets.isEmpty {
            children.append(.separator)
            children += targets.map { playlist in
                .command(.init(playlist.name, run: {
                    // 撞重先问一句（spec §10.4 第二条链，见 `PlaylistDuplicateAlert`）。
                    // 一条也没落地就不报「已加入」——用户刚选的是「跳过」。
                    PlaylistDuplicateAlert.addTracks(tracks, to: playlist, library: library) { added in
                        guard added > 0 else { return }
                        appState.showToast("已加入「\(playlist.name)」")
                    }
                }))
            }
        }
        children += accountPlaylistSection
        return .submenu(.init("添加到播放列表"), children)
    }

    /// 直接要一份 `NSMenu`。
    func makeMenu(_ entries: [MenuSpec.Entry]) -> NSMenu { MenuSpec.makeMenu(entries) }
}

// MARK: - 段落

private extension TrackActions {

    /// 资料库 + 下载 + 播放列表（目录实测的第 2 段）。
    var libraryAndDownloadSegment: [MenuSpec.Entry] {
        [addToLibraryEntry, downloadEntry, removeDownloadEntry, addToPlaylistEntry]
    }

    var queueSegment: [MenuSpec.Entry] { queueSegmentWithoutStation + [createStationEntry] }

    var queueSegmentWithoutStation: [MenuSpec.Entry] { [playNextEntry, addToQueueEntry] }

    /// 「信息 + 评价」段。实测里这是一个**绝不拆开、绝不换序的块**，
    /// 且永远由 Get Info 领起（目录曲目行、播放队列、播放器三处皆然）。
    /// 评分与勾选是 Amber 接上了而 Music 走旧栈 ITMessage 的两条，实测拿不到位置，
    /// 挂在这个块的**后面**——不插进那五连块里去。`[推]`
    var tasteSegment: [MenuSpec.Entry] {
        [getInfoEntry, favoriteEntry, undoFavoriteEntry,
         suggestLessEntry, undoSuggestLessEntry, ratingEntry, checkSelectedEntry]
    }

    var navigationSegment: [MenuSpec.Entry] {
        [goToAlbumEntry, goToArtistEntry, showInITunesStoreEntry, shareEntry]
    }

    /// 「从队列中移除」「从播放列表中删除」这一类。实测里队列那份把它摆在**第 2 项**
    /// （紧跟 Add to Library、在第一条分隔线之前），这里照办。
    var removeSegment: [MenuSpec.Entry] {
        guard let remove else { return [] }
        return [.command(.init(remove.title, run: remove.run)), .separator]
    }
}

// MARK: - 动作定义（一个动作一份）

private extension TrackActions {

    /// 「播放 / 暂停」。
    ///
    /// **这一条是 Amber 加的**：实测的四处菜单里都没有「播放」（Music 靠双击起播）。
    /// Amber 保留它是因为目录卡那类没有双击语义的落点也在用同一份菜单。`[Amber]`
    ///
    /// Music 里对列表行的「播放」是一件事：从这一行起播，队列是整份可见行。
    /// 多选时也一样——播第一首选中的，后面照旧接整份列表（不是只播这几首）。
    var playEntry: MenuSpec.Entry {
        .command(.init(isPlaying ? "暂停" : "播放", run: {
            guard !tracks.isEmpty else { fallbackPlay?(); return }
            if isCurrent {
                player.togglePlayPause()
            } else if let playContext {
                player.play(playContext.tracks, startAt: playContext.index)
            } else {
                player.play(tracks)
            }
        }))
    }

    /// Amber 没有「置顶歌曲」（资料库里没有置顶这个概念）。
    var pinEntry: MenuSpec.Entry { .command(.init("置顶歌曲")) }
    var unpinEntry: MenuSpec.Entry { .command(.init("取消置顶歌曲")) }

    var addToLibraryEntry: MenuSpec.Entry {
        .command(.init("添加到资料库", run: isEmpty || allInLibrary ? nil : {
            for track in tracks where !library.isInLibrary(track) { library.toggleLibrary(track) }
        }))
    }

    /// Music 的「下载」只对已在资料库里的曲目出现。
    var downloadEntry: MenuSpec.Entry {
        .command(.init("下载", run: !isEmpty && allInLibrary && !hasLocal && !allDownloaded ? {
            downloads.download(tracks.filter { !downloads.isDownloaded($0.id) })
            appState.showToast(tracks.count > 1 ? "开始下载 \(tracks.count) 首" : "开始下载")
        } : nil))
    }

    var removeDownloadEntry: MenuSpec.Entry {
        .command(.init("移除下载", run: !isEmpty && allDownloaded && !hasLocal ? {
            downloads.removeDownload(tracks)
        } : nil))
    }

    var playNextEntry: MenuSpec.Entry {
        .command(.init("稍后播放", symbol: "text.line.first.and.arrowtriangle.forward",
                       run: isEmpty ? nil : { player.playNext(tracks) }))
    }

    var addToQueueEntry: MenuSpec.Entry {
        .command(.init("加入待播清单", symbol: "text.line.last.and.arrowtriangle.forward",
                       run: isEmpty ? nil : { player.playLast(tracks) }))
    }

    /// Amber 没有电台。
    var createStationEntry: MenuSpec.Entry {
        .command(.init("创建电台", symbol: "badge.plus.radiowaves.right"))
    }

    /// 「显示简介」面板（`InfoPanelWindowController`，照 getinfo spec + sample 复刻）。
    ///
    /// **多选时只摆不接**：Music 多选走的是另一套（里那两道守卫、
    /// 混合态占位、脏标记批量覆写），而那一套一次都没采过、spec §5 整节是 `[推]`。
    /// 照着编不如先空着——摘掉这一项又会让菜单少一行，与实测项序对不上。
    var getInfoEntry: MenuSpec.Entry {
        .command(.init("显示简介", run: single.map { track in
            { AuxiliaryWindows.shared.showInfoPanel(tracks: [track]) }
        }))
    }

    /// [实测] spec §3.2：`FavoriteItemsAction` 与`UndoFavoriteItemsAction` 判据同一个、
    /// 方向相反，所以两条永远只出现一个。
    ///
    /// **整批合成一次撤销**（`withUndoGrouping`）：这两条对整份选中集生效，一下能改
    /// 几十首，逐首各记一笔的话用户要按几十次 ⌘Z 才回得去。写入口那边一个字不用改。
    var favoriteEntry: MenuSpec.Entry {
        .command(.init("心水", run: isEmpty || allFavorite ? nil : {
            library.withUndoGrouping("心水") {
                for track in tracks where !library.isFavorite(track) {
                    library.toggleFavorite(track)
                }
            }
        }))
    }

    var undoFavoriteEntry: MenuSpec.Entry {
        .command(.init("取消心水", run: !isEmpty && allFavorite ? {
            library.withUndoGrouping("取消心水") {
                for track in tracks where library.isFavorite(track) {
                    library.toggleFavorite(track)
                }
            }
        } : nil))
    }

    /// 「减少推荐 / 撤销减少推荐」。写的是**音源账号里的口味**：
    /// QQ 是不喜欢名单（可加可撤），网易云是日推的「不感兴趣」（只能加，撤不回来，
    /// 于是那一家永远只摆得出前一条）。判据与接线都在 `AppState.canSuggestLess`。
    ///
    /// 与心水那一对同解（[实测] spec §3.2）：判据同一个、方向相反，永远只出现一个。
    var suggestLessEntry: MenuSpec.Entry {
        .command(.init("减少推荐", run: appState.canSuggestLess(tracks, less: true)
                       ? { appState.suggestLess(tracks, less: true) } : nil))
    }

    var undoSuggestLessEntry: MenuSpec.Entry {
        .command(.init("撤销减少推荐", run: appState.canSuggestLess(tracks, less: false)
                       ? { appState.suggestLess(tracks, less: false) } : nil))
    }

    /// Music 的评分子菜单是「无 / ★…★★★★★」六项单选；混合评分时六项都不勾。
    var ratingEntry: MenuSpec.Entry {
        guard !isEmpty else { return .command(.init("评分")) }
        let values = Set(tracks.map { library.rating(for: $0.id) })
        let current = values.count == 1 ? values.first! : -1
        let children: [MenuSpec.Entry] = (0...5).map { value in
            .command(.init(value == 0 ? "无" : String(repeating: "★", count: value),
                           isOn: value == current,
                           run: {
                               // 与心水那两条同解：整份选中集一次改完，撤销也只一步。
                               library.withUndoGrouping("评分") {
                                   for track in tracks { library.setRating(value, for: track.id) }
                               }
                           }))
        }
        return .submenu(.init("评分"), children)
    }

    /// Music 的 `doCheckSelectedTracks:`：整份选中集一起勾 / 一起取消。
    /// 勾选列关着时这一项整个不摆：那一列不存在，勾了也看不见。
    var checkSelectedEntry: MenuSpec.Entry {
        let enabled = !isEmpty && AppSettings.shared.values.songListCheckboxes
        return .command(.init(allChecked ? "取消勾选所选项" : "勾选所选项",
                              run: enabled ? { library.setChecked(tracks, !allChecked) } : nil))
    }

    /// Music 会把当前去不了的项摘掉：专辑得在资料库里查得到，艺人得有 id。
    var goToAlbumEntry: MenuSpec.Entry {
        let target = single.flatMap { library.album(for: $0) != nil ? $0 : nil }
        return .command(.init("前往专辑",
                              run: target.map { track in { appState.goToAlbum(of: track) } }))
    }

    var goToArtistEntry: MenuSpec.Entry {
        let target = single.flatMap { $0.canGoToArtist ? $0 : nil }
        return .command(.init("前往艺人",
                              run: target.map { track in { appState.goToArtist(of: track) } }))
    }

    /// Amber 没有 iTunes Store。
    var showInITunesStoreEntry: MenuSpec.Entry { .command(.init("在 iTunes Store 中显示")) }

    /// 「分享 ▸」：拷贝链接 + 系统里装了的共享服务（隔空投送 / 信息 / 邮件 …），
    /// 子菜单怎么来的见 `MenuSpec.shareEntry`。
    ///
    /// 交的是音源网页版那一页（`Track.webShareURL`）——Amber 没有服务端，
    /// 但两家的歌在网页上都有一份人人打得开的页面。本地导入的歌没有，那时整条不摆。
    /// 多选时一次分享多条链接。
    var shareEntry: MenuSpec.Entry {
        MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                            urls: tracks.compactMap(\.webShareURL))
    }

    var copyEntry: MenuSpec.Entry {
        .command(.init("拷贝", run: isEmpty ? nil : {
            let text = tracks.map { "\($0.title) — \($0.artistName)" }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }))
    }

    /// 菜单里这一项是明写着的选项，不再问一遍「确定吗」；但**「文件去哪」那一问要问**
    /// （spec §10.2，理由见 `LibraryDeleteAlert.askFileDisposition`）。
    var deleteFromLibraryEntry: MenuSpec.Entry {
        .command(.init("从资料库中删除", run: !isEmpty && allInLibrary ? { [tracks, appState] in
            let picked = tracks.filter { appState.library.isInLibrary($0) }
            LibraryDeleteAlert.askFileDisposition(tracks: picked, appState: appState) {
                // 多选删除也是一步撤销（撤销能把条目放回来，放不回已经进废纸篓的文件，
                // 见 `LibraryStore.LibraryRemoval`）。
                // 批量入口，理由同 `SongsTableView.deleteSelection`。
                appState.library.withUndoGrouping("从资料库中删除") {
                    appState.library.removeFromLibrary(picked)
                }
            }
        } : nil))
    }
}
