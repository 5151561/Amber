import AppKit
import SwiftUI

// MARK: - 播放器的 ••• 菜单

/// 三处播放器共用的那一份 ••• 菜单：底部悬浮播放条、整窗播放器、独立迷你播放器窗。
/// Music 里它们本来就是同一个 `PBPlayerMetadataViewModel` 的`actionMenu`，
/// 三处只是同一份元数据的三种排版；迷你窗那份在头尾各多包了几条自己的
/// （音质入口、显示/隐藏大插图，见 `MiniPlayerContentView.actionMenu`）。
///
/// 顺序照 [实测] §4.6 `PBPlayerMetadataViewModel.actionMenu`
/// （29 次 `addItem` = 6 分隔线 + 23 项）：
///
/// ```
/// Pin、Unpin、Add to Library、Download、Add to Playlist、—、Create Station、—、
/// Get Info、Favorite、Undo Favorite、Suggest Less、Undo Suggest Less、—、
/// Go to Playlist、Go to Album、Go to Artist、Show in iTunes Store、Show in Playlist ▸、—、
/// Share、Share Station、—、Copy、Show in Finder、—、
/// Remove Download、Delete from Library、Report a Concern…
/// ```
///
/// 装配与摘项的规矩见 `MenuSpec`——这份表就是那套基建的出处：Amber 还没有的命令照样列在原位，
/// `run` 给 nil（= Music 那边`validate_*` 报 NO）于是被摘掉，接上线时把 nil 换成动作即可。
///
/// 表里暂缺的是 §4.6 里 Amber 大概率永远不会有、中文名也没有实测出处的那几条
/// （前往播放列表 / 在播放列表中显示 / 共享电台 / 在访达中显示）；
/// 已列出的每一条的中文名与位置都来自 Music 实测截图。
///
/// 「稍后播放 / 加入待播清单」不在这张表里——这颗 ••• 说的就是**正在播放的这一首**，
/// 把它再排进队列没有意义。
///
/// **一张表、两个渲染器**：`entries` 是唯一的事实来源，AppKit 那边（悬浮条、迷你窗）
/// 走 `MenuSpec.makeMenu`，SwiftUI 那边（整窗播放器的`Menu { … }`）走本视图。
struct PlayerMoreMenu: View {

    let track: Track

    @EnvironmentObject private var appState: AppState
    /// 表本身读的是 `appState.library` / `.downloads`，这里再声明一次是为了**依赖登记**：
    /// 心水、入库这些状态一变，这棵子树才跟着重建。
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore

    var body: some View {
        MenuSpec.Rows(Self.entries(track: track, appState: appState,
                                   library: library, downloads: downloads))
    }
}

// MARK: - 表

extension PlayerMoreMenu {

    /// §4.6 全表，一条不少，顺序与分隔线都照抄。
    @MainActor
    static func entries(track: Track, appState: AppState,
                        library: LibraryStore, downloads: DownloadStore) -> [MenuSpec.Entry] {
        let isInLibrary = library.isInLibrary(track)
        let isDownloaded = downloads.isDownloaded(track.id)
        // 「这首有没有词」问的是两处面板共用的那份缓存（`LyricsStore`）：还没取过词时
        // 它是 nil，与「确认没有词」一样点不动。
        let hasLyrics = LyricsStore.shared.cachedLyrics(for: track)?.isEmpty == false
        return [
            // Amber 没有「置顶歌曲」（资料库里没有置顶这个概念）。
            .command(.init("置顶歌曲")),
            .command(.init("取消置顶歌曲")),
            .command(.init("添加到资料库",
                           run: isInLibrary ? nil : { library.toggleLibrary(track) })),
            // 「下载」只对已入库的曲目出现；本地导入的歌本来就在本机，没有可下的东西。
            .command(.init("下载", run: isInLibrary && !track.isLocal && !isDownloaded ? {
                downloads.download([track])
                appState.showToast("开始下载")
            } : nil)),
            addToPlaylist(track: track, appState: appState, library: library),
            .separator,
            // Amber 没有电台。
            .command(.init("创建电台", symbol: "badge.plus.radiowaves.right")),
            .separator,
            // 「显示简介」面板（照 getinfo spec + sample 复刻）。播放器这颗 ••• 永远只对
            // 当前这一首，没有多选态的问题。
            .command(.init("显示简介", run: {
                AuxiliaryWindows.shared.showInfoPanel(tracks: [track])
            })),
            // [实测] §3.2 四态可用性 = canFavorite && state != 该态，所以两项互斥出现。
            .command(.init("心水", run: library.isFavorite(track) ? nil : {
                library.toggleFavorite(track)
            })),
            .command(.init("取消心水", run: library.isFavorite(track) ? {
                library.toggleFavorite(track)
            } : nil)),
            // 写的是音源账号里的口味（QQ 的不喜欢名单 / 网易云的「不感兴趣」），
            // 判据与接线同 `TrackActions`，都在`AppState.canSuggestLess`。
            .command(.init("减少推荐", run: appState.canSuggestLess([track], less: true)
                           ? { appState.suggestLess([track], less: true) } : nil)),
            .command(.init("撤销减少推荐", run: appState.canSuggestLess([track], less: false)
                           ? { appState.suggestLess([track], less: false) } : nil)),
            .separator,
            // 去不了的项 Music 会摘掉：专辑得在资料库里查得到，艺人得有 id。
            .command(.init("前往专辑", run: library.album(for: track) != nil
                           ? { appState.goToAlbum(of: track) } : nil)),
            .command(.init("前往艺人", run: track.canGoToArtist
                           ? { appState.goToArtist(of: track) } : nil)),
            .command(.init("在 iTunes Store 中显示")),
            .separator,
            // 分享的是音源网页版那一页（同 `TrackActions.shareEntry`）。
            MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                                urls: [track.webShareURL].compactMap { $0 }),
            .separator,
            .command(.init("拷贝", run: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(track.title) — \(track.artistName)",
                                               forType: .string)
            })),
            .separator,
            .command(.init("移除下载", run: isDownloaded && !track.isLocal ? {
                downloads.removeDownload([track])
            } : nil)),
            .command(.init("从资料库中删除", run: isInLibrary ? {
                library.toggleLibrary(track)
            } : nil)),
            // [实测] §8.4：歌词举报挂在播放器元数据 VM 的菜单链末尾。
            .command(.init("报告歌词问题",
                           run: hasLyrics ? { reportLyricsConcern(appState) } : nil)),
        ]
    }

    /// 「添加到播放列表 ▸」。本机列表 + 登录账号里自建的歌单，
    /// 两段的规矩与排布都跟着 `TrackActions.addToPlaylistEntry` 走（那边是同一件事的正本）。
    @MainActor
    private static func addToPlaylist(track: Track, appState: AppState,
                                      library: LibraryStore) -> MenuSpec.Entry {
        // 先弹命名框，确认之后才建列表并报「已加入」（见 AppState.promptNewPlaylist）。
        var children: [MenuSpec.Entry] = [
            .command(.init("新建播放列表", run: { appState.promptNewPlaylist(with: [track]) })),
        ]
        let targets = library.editablePlaylists
        if !targets.isEmpty {
            children.append(.separator)
            children += targets.map { playlist in
                .command(.init(playlist.name, run: {
                    // 与 `TrackActions.addToPlaylistEntry` 同一条：撞重先问
                    //（spec §10.4，见 `PlaylistDuplicateAlert`）。
                    PlaylistDuplicateAlert.addTracks([track], to: playlist, library: library) { added in
                        guard added > 0 else { return }
                        appState.showToast("已加入「\(playlist.name)」")
                    }
                }))
            }
        }
        children += TrackActions(tracks: [track], appState: appState).accountPlaylistSection
        return .submenu(.init("添加到播放列表"), children)
    }

    /// [实测] §8.4 `PBPlayerMetadataViewModel.doReportAConcernForLyricsForCurrentlyPlayingItem`
    /// Amber 没有受理端，落成一条提示——位置与归属与 Music 一致。
    /// 歌词面板自己那份菜单（[TYPE] `LyricsOptions._buildOptionsMenu`）走的也是这一句。
    @MainActor
    static func reportLyricsConcern(_ appState: AppState) {
        appState.showToast("已记录歌词问题反馈")
    }

    /// 把表渲染成 `NSMenu`。悬浮条与迷你窗走这条；迷你窗还会在头尾拼上自己那几条。
    @MainActor
    static func makeMenu(_ entries: [MenuSpec.Entry]) -> NSMenu { MenuSpec.makeMenu(entries) }
}
