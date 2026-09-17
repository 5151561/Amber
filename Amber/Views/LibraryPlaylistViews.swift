import SwiftUI

/// 资料库播放列表的公用右键菜单（详情页、网格卡都已经是 AppKit）。
///
/// 资料库里的播放列表有三种来源（`LibraryPlaylist.Origin`），界面上一视同仁，
/// 差别只在能不能编辑与曲目从哪来：
/// - `.local` 自建：曲目存在本地，能改名、加歌、删歌；
/// - `.added` / `.account`：只是音源歌单的镜像，曲目每次打开时向音源取
///   （跟目录里的歌单详情页同一条路），本地这份镜像不可编辑。
///   （往账号里加歌是有的——曲目菜单的「添加到播放列表 › 账号歌单」，
///   写完不动镜像，下次打开自然是新的。）

// 详情页已经换成 AppKit：`PlaylistDetailViewController`（`Source.library`）——
// 本地自建列表直接读库、镜像列表向音源取，头部第三枚键仍是下面那份 `LibraryPlaylistMenu`
// （用 `NSHostingMenu` 包成 `NSMenu`）。

// MARK: - 公用菜单

/// 播放列表的右键 / ••• 菜单。侧栏行与详情页头共用这一份（用 `NSHostingMenu` 包成 `NSMenu`）；
/// 「所有播放列表」的网格卡是纯 AppKit，照这里的项目自己造了一颗 `NSMenu`
/// （见 `LibraryPlaylistCardView.makeCardMenu`），改动要两边一起改。
struct LibraryPlaylistMenu: View {
    let playlist: LibraryPlaylist
    /// 详情页头的 ••• 里不重复摆播放键（旁边就是播放与随机播放）。
    var includesPlayback = true

    @EnvironmentObject private var appState: AppState
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if includesPlayback {
            Button("播放") { Task { await appState.playLibraryPlaylist(playlist) } }
            Button("随机播放") { Task { await appState.playLibraryPlaylist(playlist, shuffled: true) } }
            Divider()
        }
        // 分享的是音源网页版那一页（自建列表只在本机，没有可分享的页面）。
        // 位置照 `CollectionActions.entries`：分享在「重命名 / 刷新 / 删除」那几条之前。
        //
        // **不用 `ShareLink`**：它渲染出来的就是 `standardShareMenuItem` 那一条
        // （实测 dump 里 action 是 `_performStandardShareMenuItem:`），在右键菜单里
        // 弹出的浮层锚不住、从屏幕角上冒出来。走 `MenuSpec.shareEntry` 那份自列服务的子菜单，
        // 与 AppKit 那条渲染路是同一份东西。
        if let url = playlist.webShareURL {
            MenuSpec.Rows([MenuSpec.shareEntry(.init("分享", symbol: "square.and.arrow.up"),
                                               urls: [url])])
            Divider()
        }
        if playlist.isEditable {
            // 改名弹窗由 RootViewController 统一挂着：菜单一关，菜单内容这棵子树就没了，
            // alert 挂在这里根本弹不出来。
            Button("重命名…") { appState.playlistNamePrompt = .rename(playlistID: playlist.id) }
        }
        if playlist.origin == .account {
            Button("刷新账号歌单") { Task { await appState.syncAccountPlaylists(manual: true) } }
        }
        Button("从资料库中删除") {
            if appState.sidebarSelection == .playlist(id: playlist.id) {
                appState.sidebarSelection = .allPlaylists
            }
            library.deletePlaylist(id: playlist.id)
        }
    }
}
