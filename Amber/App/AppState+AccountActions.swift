import Foundation

// 右键菜单里那两条要**写音源账号**的动作：「添加到播放列表 › 账号歌单」与「减少推荐」。
//
// 为什么落在 AppState 而不是菜单里：菜单每次弹开都重建、点完就没了，
// 而这两件事都是「先打一条网络请求，回来再改本地状态、再报一句 toast」的异步活。
// 把 Task 挂在菜单项的闭包里，菜单一关闭那棵子树就被释放（`ClosureMenuItem` 的注释里
// 已经踩过一次弱引用 target 的坑）；挂在 AppState 上则与 `playPlaylist` 那批同一形制。
//
// 两条共同的规矩：
// - **不假装成功**：音源那边写成功了才改本地镜像、才报「已…」；抛了错就原样把话报出去。
// - **未登录/没能力的音源不摆**：判据由这里的 `can…` 出，菜单只负责把 nil 换成动作
//   （`MenuSpec` 的禁用即隐藏）。
extension AppState {

    // MARK: - 添加到账号歌单

    /// 这批曲目能加进哪些**账号歌单**。
    ///
    /// 三道闸：同一家音源（QQ 的歌加不进网易云的歌单）、不是本地导入的歌
    /// （`local:` 那批音源根本不认识）、而且是账号**自建**的歌单
    /// （`Playlist.isOwned`；收藏来的是别人的歌单，写进去只会被服务端拒）。
    ///
    /// 取的是资料库里那份账号歌单镜像（`syncAccountPlaylists` 同步进来的），
    /// 不现打接口：菜单是同步装配的，弹开那一刻等不起一条网络请求。
    /// 于是设置 › 通用 ›「同步资料库」关着时这一段是空的——镜像本来就没同步进来，
    /// 这与那颗开关的语义一致，不为它开后门。
    func writableAccountPlaylists(for tracks: [Track]) -> [Playlist] {
        guard let kind = commonProviderKind(of: tracks),
              provider(kind) is any MusicLibraryWriting,
              provider(kind).isLoggedIn else { return [] }
        return library.playlists.compactMap { playlist in
            guard playlist.origin == .account, let source = playlist.source,
                  source.kind == kind, source.isOwned == true else { return nil }
            return source
        }
    }

    /// 把这批曲目加进音源账号里的一份歌单。
    ///
    /// 加完**不动本地那份镜像**：账号歌单在 Amber 里是只读镜像，曲目每次打开详情页时
    /// 现向音源取（`playlistDetail` 这条没有缓存），所以下次点进去自然就有了。
    func addTracksToAccountPlaylist(_ tracks: [Track], playlist: Playlist) {
        guard let writer = provider(playlist.kind) as? any MusicLibraryWriting else {
            showToast("\(playlist.kind.displayName)不支持改歌单")
            return
        }
        let ids = tracks.map(\.id)
        Task { @MainActor in
            do {
                try await writer.addTracks(ids, to: playlist.id)
                showToast("已加入「\(playlist.name)」")
            } catch {
                showToast("加入「\(playlist.name)」失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 减少推荐

    /// 「减少推荐 / 撤销减少推荐」这一条现在摆不摆得出来。
    ///
    /// 与心水那一对同解（[实测] spec §3.2：判据同一个、方向相反，永远只出现一个）：
    /// 只要还有一首没说过就整批说，全都说过了才轮到「撤销」。
    /// 撤销还多一道——音源得真有撤销接口（网易云没有，见 `MusicTasteWriting`）。
    func canSuggestLess(_ tracks: [Track], less: Bool) -> Bool {
        guard let kind = commonProviderKind(of: tracks),
              let writer = provider(kind) as? any MusicTasteWriting,
              writer.isLoggedIn else { return false }
        let allMarked = tracks.allSatisfy { library.isSuggestedLess($0) }
        return less ? !allMarked : (writer.supportsUndoSuggestLess && allMarked)
    }

    func suggestLess(_ tracks: [Track], less: Bool) {
        guard let kind = commonProviderKind(of: tracks),
              let writer = provider(kind) as? any MusicTasteWriting else { return }
        // 只把「还没说过的」发出去（撤销时反过来）：整批重发一遍没意义，
        // 而 QQ 那条要先拿 mid 换数字 id，条数越少越省一次往返。
        let targets = tracks.filter { library.isSuggestedLess($0) != less }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        Task { @MainActor in
            do {
                try await writer.suggestLess(tracks: ids, less: less)
                library.setSuggestedLess(targets, less)
                let what = targets.count > 1 ? "\(targets.count) 首歌" : "这首歌"
                showToast(less ? "已对\(what)减少推荐" : "已对\(what)撤销减少推荐")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    /// 艺人那一份（QQ 的不喜欢名单收歌手；网易云没有这条能力）。
    /// 资料库派生的艺人（`library-artist:` 那种）不是音源里的艺人，冒号后面是名字不是 mid，
    /// 拿它去打接口只会得到一个错，所以直接不摆。
    func canSuggestLess(artist: Artist, less: Bool) -> Bool {
        guard !artist.isLibraryDerived,
              let writer = provider(artist.kind) as? any MusicTasteWriting,
              writer.isLoggedIn, writer.supportsArtistSuggestLess else { return false }
        let marked = library.isSuggestedLessArtist(artist.id)
        return less ? !marked : (writer.supportsUndoSuggestLess && marked)
    }

    func suggestLess(artist: Artist, less: Bool) {
        guard let writer = provider(artist.kind) as? any MusicTasteWriting else { return }
        Task { @MainActor in
            do {
                try await writer.suggestLess(artist: artist.id, less: less)
                library.setSuggestedLessArtist(artist.id, less)
                showToast(less ? "已对「\(artist.name)」减少推荐" : "已撤销减少推荐")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: -

    /// 这批曲目是不是同一家音源的、且都不是本地导入的。不是就返回 nil＝这一批做不了账号侧的事。
    private func commonProviderKind(of tracks: [Track]) -> ProviderKind? {
        guard !tracks.isEmpty, !tracks.contains(where: \.isLocal) else { return nil }
        let kinds = Set(tracks.map(\.kind))
        return kinds.count == 1 ? kinds.first : nil
    }
}
