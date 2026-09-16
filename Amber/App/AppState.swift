import AppKit
import Combine
import Foundation
import SwiftUI

/// 全局应用状态：provider 注册表、播放器、资料库、导航与提示。
@MainActor
final class AppState: ObservableObject {

    @Published var sidebarSelection: SidebarItem? = .home
    // 侧栏的显示/隐藏不再由 AppState 持有。骨架换成 AppKit 之后，收起态是
    // `NSSplitViewItem.isCollapsed` 自己的事，⌃⌘S 直接落到分栏控制器的
    // `toggleSidebar(_:)`（AppKit 的标准动作，连折叠动画和 autosave 一起给）。
    // 再在这里放一份 @Published 只会变成两处真值，早晚对不上。
    @Published var selectedProvider: ProviderKind
    @Published var playerInspector: PlayerInspector?
    @Published var showingNowPlaying = false
    @Published var showingQQLogin = false
    @Published var toastMessage: String?
    /// 播放列表命名弹窗的待办。弹窗由 `RootViewController` 统一挂着——右键菜单一关，
    /// 菜单内容那棵子树就没了，alert 挂在菜单里弹不出来，所以这里只登记意图。
    @Published var playlistNamePrompt: PlaylistNamePrompt?
    /// 菜单里的「前往专辑 / 前往艺人」要从任意位置推一层详情页，而导航栈由 MainView 持有；
    /// 这里只登记意图，MainView 收到后入栈并清空（Music 的 doGoToAlbum:/doGoToArtist:）。
    @Published var pendingRoute: Route?
    /// 资料库「艺人」页的待选行（`Artist.libraryIDPrefix + 艺人名`）。
    ///
    /// 搜索的资料库范围点艺人时，Music 不是推一层艺人详情页，而是**直接跳回资料库的
    /// 「艺人」目录并选中那一行**（实测截图：左列表选中「告五人」、右侧是该艺人的专辑块）。
    /// 那一页的选中态是页面自己的 `@State`，跨页传不过去，所以在这里登记一次意图，
    /// `LibraryArtistsPage` 收到就选中并清空。
    @Published var pendingLibraryArtistID: String?
    /// 启动参数 `-search <词>` 带进来的词条。搜索页建起来时取一次就清掉。
    /// 与 `-albums` / `-home` 那一批同类：搜索框在标题栏上，实机验收敲不进去。
    var launchSearchTerm: String?

    /// 歌曲表的列／排序／筛选。表格与「显示选项」窗口是两棵视图树，必须共享同一份。
    let songsTable: SongsTableSettings
    /// 列表字号／行高的三档，与 Music 一样是全局偏好（见 ListViewSize）。
    let listViewSize: ListViewSizeStore

    let player: PlayerController
    let library: LibraryStore
    /// 已下载曲目。取流地址本身就是明文音频，下载 = 把那条 URL 存到磁盘（见 DownloadStore）。
    let downloads: DownloadStore
    /// 默认输出设备的画像。「杜比全景声＝自动」要靠它决定这台输出该不该取沉浸声
    /// （见 `effectiveQuality`）。它自己盯着 CoreAudio 的默认设备与声道配置。
    let audioOutput = AudioOutputMonitor()
    /// 每首歌量到的响度（设置 › 播放 ›「音量平衡」）。播放器边播边量，写回这里；
    /// 已下载的文件在落地时离线量。**不是** ObservableObject，见 `LoudnessStore` 的注释。
    let loudness = LoudnessStore()
    /// 「显示简介」面板的编辑结果（另存 `trackinfo.json`，理由见`TrackInfoStore`）。
    let trackInfo = TrackInfoStore.shared
    let qqLogin: QQLoginStore
    let neteaseLogin: NeteaseLoginStore
    let providerSettings: ProviderSettingsStore
    /// 歌词缓存。侧栏歌词（InspectorLyricsView）与整窗歌词（NowPlayingLyrics）共用一份，
    /// 同一首在两处之间来回切只打一次网络。整窗那条路上拿不到 AppState，
    /// 所以本体是 `LyricsStore.shared`，这里只是给能拿到 AppState 的视图一个入口。
    let lyricsStore = LyricsStore.shared
    /// 注册表始终是全量：关掉的源仍要能给资料库里的旧内容取流
    private let providers: [ProviderKind: any MusicProvider]
    /// 启动校验登录态要用；`providers` 里那份是同一个对象，存一次省得回头强转。
    private let qqAPI: QQAPI
    private let neteaseAPI: NeteaseAPI
    private var cancellables = Set<AnyCancellable>()
    private var didLaunchSync = false
    /// MV 播放窗。第一支 MV 点开时才建，之后一直复用这一扇（见 `playMV`）。
    private var mvPlayerWindow: MVPlayerWindowController?
    /// 上一条 toast 的自动消失计时，来新的就取消。
    private var toastTask: Task<Void, Never>?
    /// 「文件 › 导入…」。跑起来之后菜单项置灰（见 `AppDelegate.validateMenuItem`）：
    /// 一批还没导完又开一批，两批会抢同一个「媒体」文件夹里的落点。
    private lazy var importService: ImportService = {
        let service = ImportService(library: library, downloads: downloads)
        service.defaultKind = { [weak self] in
            self?.providerSettings.defaultProvider ?? .qq
        }
        // 设置 › 高级 ›「自动更新已导入歌曲的插图」：没有内嵌封面时按「艺人 标题」
        // 到默认音源搜一张。尽力而为——搜不到、没网、被限流都只是没有封面而已。
        service.artworkLookup = { [weak self] artist, title in
            guard let self else { return nil }
            let keyword = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            guard !keyword.isEmpty else { return nil }
            let provider = self.provider(self.providerSettings.defaultProvider)
            let found = try? await provider.searchTracks(keyword: keyword, limit: 1, offset: 0)
            return found?.first?.artworkURL
        }
        return service
    }()
    @Published private(set) var isImporting = false

    /// `defaults` 一路传给四个偏好 store。默认是`.standard`，只有测试会换：
    /// 单元测试跑在 App 宿主进程里，`UserDefaults.standard` 就是`com.changlepan.Amber`
    /// 本人那份偏好，测试里随手改一下音质就会写进开发者真实的设置（见 `QQLoginStore`）。
    init(defaults: UserDefaults = .standard) {
        songsTable = SongsTableSettings(defaults: defaults)
        listViewSize = ListViewSizeStore(defaults: defaults)
        let neteaseAPI = NeteaseAPI()
        let qqAPI = QQAPI()
        self.qqAPI = qqAPI
        self.neteaseAPI = neteaseAPI
        providers = [.netease: neteaseAPI, .qq: qqAPI]
        player = PlayerController()
        library = LibraryStore()
        downloads = DownloadStore()
        qqLogin = QQLoginStore(defaults: defaults)
        neteaseLogin = NeteaseLoginStore()
        let settings = ProviderSettingsStore(defaults: defaults)
        providerSettings = settings
        selectedProvider = settings.defaultProvider

        NowPlayingCenter.shared.configure(player: player)
        // 遥控器（iOS「遥控」App，DACP）：与 NowPlayingCenter 同一形制的单例 + configure。
        RemoteControlServer.shared.configure(target: player)

        // 音量跨启动保留：上次退出时那一格，下次打开还是那一格（Music 同）。
        // 落盘挂在 AppState 而不是播放器里，理由同 `loudness`——播放器不持有要落盘的东西。
        // 改音量的入口有四个（播放页、迷你播放器、⌘↑／⌘↓、遥控器），它们最终都写
        // `player.volume`，所以只在这一条 `$volume` 上记就够，不用每个入口各记一遍。
        // `dropFirst` 跳过订阅时那一次当前值：启动本身不该写盘。
        if let stored = defaults.object(forKey: Self.volumeKey) as? Double {
            player.volume = min(max(stored, 0), 1)
        }
        player.$volume
            .dropFirst()
            .removeDuplicates()
            .sink { [defaults] volume in defaults.set(volume, forKey: Self.volumeKey) }
            .store(in: &cancellables)
        // 听歌记账全部由播放器发起：从前只在视图层的点击入口记，播放器自动连播那几首
        // 一次都不算，一张专辑放完只有双击的那首 +1。
        player.onSkip = { [weak self] track in self?.library.recordSkip(track) }
        player.onTrackStarted = { [weak self] track in self?.library.noteStarted(track) }
        player.onTrackPlayed = { [weak self] track in self?.library.notePlayed(track) }
        // 设置 › 通用 ›「歌曲列表复选框」：自动连播跳过没勾的（手动切歌不认勾，与 Music 同）。
        player.isTrackChecked = { [weak self] in self?.library.isChecked($0) ?? true }
        // 音量平衡的两头：播之前问一次这首量过没有，播完把量出来的写回去。
        // 表放在 AppState 而不是播放器里——播放器不该持有需要落盘的东西。
        player.loudnessProvider = { [weak self] track in self?.loudness.entry(for: track) }
        // 「显示简介 › 选项」那几项的生效接线。三条闭包都没注入时播放器走原来那条路，
        // 所以这里是唯一的接入点（见 `PlayerController.playbackOverridesProvider`）。
        player.playbackOverridesProvider = { [weak self] id in
            self?.trackInfo.playbackOverrides(for: id)
        }
        player.resumePositionProvider = { [weak self] id in
            self?.trackInfo.resumePosition(for: id)
        }
        player.onResumePosition = { [weak self] id, seconds in
            self?.trackInfo.setResumePosition(seconds, for: id)
        }
        player.onLoudnessMeasured = { [weak self] track, entry in
            self?.loudness.record(entry, for: track)
        }
        // 空间化：设置里的「自动」先按当前输出设备折算，再折成 AVFoundation 的格式集合。
        // 这条闭包在**每支 item 出生时**问一次，所以换设备后下一首自然按新设备来。
        player.spatializationProvider = { [weak self] in
            guard let self else { return .multichannel }
            return AudioOutputRules.spatializationFormats(for: self.resolvedDolbyAtmos)
        }

        // 自动连播：队尾快见底时拿当前这首去问它自己的音源要**相似歌曲**。
        // 只有这一条路（QQ 走 `GetSimilarSongs`，网易云走`simiSong`）——
        // 面板上写的是「将播放类似歌曲」，不掺别的召回，见 `MusicProvider.similarTracks`。
        player.autoplaySupported = { [weak self] kind in
            self?.providers[kind]?.supportsAutoplay ?? false
        }
        player.autoplayCandidatesProvider = { [weak self] track, limit in
            guard let self, let provider = self.providers[track.kind] else { return [] }
            return await provider.similarTracks(track, limit: limit)
        }

        // 取流。播放不指定档位＝走音源的 `qualityProvider`（= `effectiveQuality`）。
        let resolveRemote: (Track) async throws -> URL = { [weak self] track in
            guard let self, let provider = self.providers[track.kind] else {
                throw ProviderError.api("未知音乐源")
            }
            return try await provider.trackStreamURL(track: track)
        }
        // 下载走**另一档**：设置 › 播放 里流播放与下载是两个选择器（Music 同），
        // 下载还有自己的「下载杜比全景声」。所以这条 resolver 显式传 `downloadQuality`。
        downloads.resolveRemoteURL = { [weak self] track in
            guard let self, let provider = self.providers[track.kind] else {
                throw ProviderError.api("未知音乐源")
            }
            return try await provider.trackStreamURL(track: track, quality: self.downloadQuality)
        }
        // 下载好的文件里也带一份歌词（LRC 写进标签，见 `DownloadStore.lyricsText`）。
        // 走 `LyricsStore` 的**显示口**而不是直接 `provider.lyrics`：一来侧栏与整窗歌词
        // 共用的就是这份缓存，刚看过词的那首下载时一趟网络都不用再打，也不会把同一首问两遍；
        // 二来勾了「自定义歌词」的那些歌，文件里写进去的要与面板上看到的是同一份。
        // 取不到（没有词、断网、这个音源不认这首）就是空数组，下载照旧成功。
        downloads.resolveLyrics = { [weak self] track in
            guard let self, let provider = self.providers[track.kind] else { return [] }
            return await self.lyricsStore.displayLyrics(for: track, using: provider)
        }
        downloads.onMediaFolderChanged = { [weak self] message in self?.showToast(message) }
        // MV 下载走**视频那一档**：设置 › 播放 › 视频质量里「流播放」与「下载」是两个
        // 选择器（Music 同），跟音频的音质档没有关系。
        downloads.resolveMVURL = { [weak self] mv in
            guard let self, let provider = self.providers[mv.kind] else {
                throw ProviderError.api("未知音乐源")
            }
            return try await provider.mvStreamURL(
                mv: mv, maxHeight: AppSettings.shared.values.videoDownloadQuality.maxHeight)
        }
        downloads.onMVDownloadFinished = { [weak self] (mv: MV, result: Result<URL, Error>) in
            switch result {
            case .success:
                self?.showToast("已下载「\(mv.title)」")
            case .failure(let error):
                self?.showToast((error as? ProviderError)?.errorDescription
                    ?? error.localizedDescription)
            }
        }
        // 刚落地的文件立刻离线量一遍响度：这样「音量平衡」对下载过的歌第一次播就生效，
        // 不用先完整听一遍（在线播的那条路仍然是第一遍只量不调）。
        downloads.onDownloaded = { [weak self] track, url in
            self?.loudness.measureIfNeeded(track: track, fileURL: url)
        }
        // 歌从资料库删掉，本地那份下载也一起没（Music 同）。挂在 store 上而不是逐个删除
        // 入口里调：入口有单曲 / 整张碟 / 表格好几处，漏一处就留下一个没人认领的音频文件。
        library.onTracksRemoved = { [weak self] ids in self?.downloads.remove(ids: ids) }
        // 设置 › 通用 ›「自动下载」：进资料库的歌自动落地。与上面那条对称——
        // 入库入口同样有单曲 / 整张碟 / 歌单同步好几处，只能挂在 store 上。
        library.onTracksAdded = { [weak self] tracks in
            guard AppSettings.shared.values.automaticDownloads else { return }
            self?.downloads.download(tracks)
        }
        // 本地文件找不着了：不静默跳下一首，弹一张「你想要查找它吗？」（spec §10.1）。
        // 那条链整段在 `MissingFileLocator` 里；这里只负责把播放器与它接上。
        player.onLocalFileMissing = { [weak self] track in
            guard let self else { return }
            MissingFileLocator.present(for: track, appState: self)
        }
        // 播放优先本地：下载过的直接播文件，连网络都不用碰（Music 也是先用本地副本）。
        // 「文件 › 导入…」进来的曲目本来就只有本地这一份（`Track.localPath`），
        // 音源那条路对它没有意义——查不到就直接报错，不去拿 `local:` 的 id 打接口。
        player.providerResolver = { [weak self] track in
            if let self, case .downloaded(let url) = self.downloads.state(for: track.id) {
                return url
            }
            if track.isLocal {
                guard let url = track.localURL,
                      FileManager.default.fileExists(atPath: url.path) else {
                    // §10.1 的**懒判定**就是这一下：Music 那条链的唯一具名调用方是
                    // `-[AppStartPlaybackManager startPlayingPlaylistItem:…]`（§10.1.2
                    // 实测），判定挂在拿它去用的这一刻，不是任何一遍后台扫描。
                    // 标记打在这里，所以自动连播、预取撞上的
                    // 也照样会在表格里留下那枚感叹号；弹不弹对话框是播放器那头的事。
                    self?.library.markFileMissing(track.id)
                    throw ProviderError.localFileMissing(trackID: track.id)
                }
                return url
            }
            return try await resolveRemote(track)
        }

        // QQ 登录态与音质注入
        qqAPI.credentialProvider = { [weak self] in self?.qqLogin.credential }
        // 档位不是直接给 qqLogin.quality，而是过一道设置窗的夹取（无损开关 / 杜比全景声）
        qqAPI.qualityProvider = { [weak self] in self?.effectiveQuality ?? .standard }
        qqAPI.onCredentialExpired = { [weak self] in
            guard let self else { return }
            self.qqLogin.markExpired()
            self.showToast("QQ音乐登录已过期，请重新登录")
        }
        qqLogin.qrAPI = qqAPI

        // 网易云同一套接线。档位过的是同一道 `effectiveQuality`：音质是全局一份偏好，
        // 不按音源各存一份——设置 › 播放 里也只有一个档位选择器。
        neteaseAPI.credentialProvider = { [weak self] in self?.neteaseLogin.credential }
        neteaseAPI.qualityProvider = { [weak self] in self?.effectiveQuality ?? .standard }
        neteaseAPI.onCredentialExpired = { [weak self] in
            guard let self else { return }
            self.neteaseLogin.markExpired()
            self.showToast("网易云音乐登录已过期，请重新登录")
        }
        neteaseLogin.qrAPI = neteaseAPI

        // 账号里的歌单进资料库、登录态校验：都由 MainView 在上屏时触发
        //（init 里不发网络请求也不动资料库——AppState 只是被构造出来时不该有副作用），
        // 之后登录态一变再同步一次歌单。
        qqLogin.$credential
            .dropFirst()
            .removeDuplicates { $0?.cookie == $1?.cookie }
            .sink { [weak self] _ in
                Task { [weak self] in await self?.syncAccountPlaylists() }
            }
            .store(in: &cancellables)

        neteaseLogin.$credential
            .dropFirst()
            .removeDuplicates { $0?.cookie == $1?.cookie }
            .sink { [weak self] _ in
                Task { [weak self] in await self?.syncAccountPlaylists() }
            }
            .store(in: &cancellables)

        // 取流失败（VIP／网络）以前只写进 player.lastError，界面上一点提示都没有，
        // 表现就是「点了没反应」。统一弹到顶部 toast。
        player.$lastError.compactMap { $0 }.sink { [weak self] message in
            self?.showToast(message)
        }
        .store(in: &cancellables)

        // 子 store 的变化**不再**转发到 AppState：转发会让每次播放进度、每次资料库改动
        // 都把所有 `@EnvironmentObject var appState` 的视图重画一遍。
        // 各子 store 自己作为 environmentObject 注入（见 AmberApp），需要谁就观察谁。

        // 在设置里关掉当前正在浏览的源时，换到还开着的第一个源
        providerSettings.$enabled.sink { [weak self] kinds in
            guard let self, !kinds.contains(self.selectedProvider),
                  let fallback = ProviderKind.allCases.first(where: kinds.contains)
            else { return }
            self.selectedProvider = fallback
        }
        .store(in: &cancellables)
    }

    /// 设置里启用的音乐源（音乐源切换器只列这些）
    var enabledProviders: [ProviderKind] { providerSettings.orderedEnabled }

    func provider(_ kind: ProviderKind) -> any MusicProvider {
        providers[kind]!
    }

    /// 播放单个曲目。「最近播放」与播放次数由播放器回调记（见 init 里的三条接线）。
    func playNow(_ track: Track) {
        player.play([track])
    }

    /// 「文件 › 导入…」：把选中的文件/文件夹读进资料库。
    ///
    /// 没有模态进度窗（Music 的导入也只在窗口顶部走一条细进度条，Amber 的骨架上还没有
    /// 那条槽），结果在末尾报一句 toast。菜单项在跑的时候置灰，见 `isImporting`。
    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task { [weak self] in
            guard let self else { return }
            let summary = await self.importService.importItems(urls)
            self.isImporting = false
            self.showToast(summary.message)
        }
    }

    /// App 内播一支 MV（搜索结果的 MV 卡、新发现「观看艺人分享」的视频卡都走这条）。
    ///
    /// 三步：先把音乐按停（两套 `AVPlayer` 同时出声等于两首歌一起放）→ 按设置
    /// › 播放 ›「视频质量 › 流播放」那一档解析地址，下载过的直接用本地那份 →
    /// 交给 `MVPlayerWindowController` 那扇窗。取不到地址就报一句，
    /// 用户还能从右键菜单的「在网页中打开」去网页版看。
    func playMV(_ mv: MV) {
        player.pause()
        let window = mvPlayerWindow ?? {
            let controller = MVPlayerWindowController()
            mvPlayerWindow = controller
            return controller
        }()
        if let local = downloads.localMVURL(for: mv) {
            window.play(mv, url: local)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.provider(mv.kind).mvStreamURL(
                    mv: mv, maxHeight: AppSettings.shared.values.videoStreamQuality.maxHeight)
                window.play(mv, url: url)
            } catch {
                self.showToast((error as? ProviderError)?.errorDescription
                    ?? error.localizedDescription)
            }
        }
    }

    /// 播放歌单（异步取详情）
    func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) async {
        do {
            let detail = try await provider(playlist.kind).playlistDetail(playlist)
            guard !detail.tracks.isEmpty else {
                showToast("歌单为空")
                return
            }
            // 队列面板「继续播放」分区头的「来自《…》」＝这份歌单，点它回歌单页。
            let source = PlayerController.QueueSource(title: detail.playlist.name,
                                                      route: .playlist(playlist))
            if shuffled {
                player.play(detail.tracks.shuffled(), source: source)
            } else {
                player.play(detail.tracks, source: source)
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func playAlbum(_ album: Album) async {
        do {
            let detail = try await provider(album.kind).albumDetail(album)
            guard !detail.tracks.isEmpty else {
                showToast("专辑为空")
                return
            }
            player.play(detail.tracks,
                        source: .init(title: detail.album.name, route: .album(album)))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func playArtistHotTracks(_ artist: Artist) async {
        do {
            let detail = try await provider(artist.kind).artistDetail(artist)
            guard !detail.hotTracks.isEmpty else {
                showToast("暂无热门歌曲")
                return
            }
            player.play(detail.hotTracks,
                        source: .init(title: detail.artist.name, route: .artist(artist)))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// 主窗口上屏时跑一次的启动任务，每次运行只做一次。
    ///
    /// 先校登录态再同步歌单：cookie 过期后接口不会报错，只是悄悄按匿名返回，
    /// 不主动查的话边栏会一直写着「已登录」，而所有 VIP 歌都放不了；
    /// 而且过期这件事要在拉歌单之前就知道，否则会拿一份匿名的空结果去动资料库。
    ///
    /// **这两件事都不能挪回 `init`**：`AppState()` 一被构造就发网络请求的话，
    /// 任何构造它的测试都会在半路收到失败 toast 引起的 `objectWillChange`。
    func runLaunchTasksOnce() async {
        guard !didLaunchSync else { return }
        didLaunchSync = true
        // 两家各校一次。串着跑：两条都只在真有凭证时才发请求，
        // 没登录的那家立刻返回，并发起来省不下什么。
        await qqAPI.validateCredential()
        await neteaseAPI.validateCredential()
        // 校完凭证再拉账号资料：过期的那份在上一行已经被打回未登录，
        // 侧栏底部就不会先亮出一个其实已经登不上的名字。
        qqLogin.refreshProfile()
        await syncAccountPlaylists()
        // 老文件名带着一截 id 短后缀（`03 简单爱-1nRaad.flac`），改成新规则的名字。
        // 要赶在下面几条拿绝对 URL 之前、也在播放开始之前：正在播的文件被改名会断流。
        downloads.renameLegacySuffixedFiles()
        checkForMissingDownloads()
        measureDownloadedTracks()
        // 「下载完补写标签」这条路接上之前下好的那些文件全是裸流（音源 CDN 给的就是），
        // 在这里补一遍——总不能让用户为了几行元数据把整个资料库重下一遍。
        // 放在启动任务里而不是 `init`：`init` 只构造、不动磁盘也不发请求（见 init 末尾）。
        // 挑哪些、怎么保证不改坏用户已有的文件，都在 `DownloadStore.backfillTags` 里。
        downloads.backfillTags(for: library.libraryTracks)
        // 已经配过遥控器才在启动时广播：`start()` 会触发「本地网络」授权弹窗，
        // 从没用过遥控器的人不该每次开 App 都被问一次；配对表单打开时自己会起服务。
        if !RemoteControlServer.shared.pairedDevices.isEmpty { RemoteControlServer.shared.start() }
    }

    /// 启动时把「已经下载好、但还没量过响度」的补量一遍（设置 › 播放 ›「音量平衡」）。
    ///
    /// 这一遍只做筛选：`measureIfNeeded` 自己跳过已有条目、自己控制并发（串行一路，
    /// 见 `LoudnessStore.offlineQueue`），所以这里整份丢给它就行。
    /// 用户没开「音量平衡」也照量——量是免费的（后台串行读文件），
    /// 等他哪天打开开关时已经有数了，不用再听一遍。
    private func measureDownloadedTracks() {
        for track in library.libraryTracks {
            guard case .downloaded(let url) = downloads.state(for: track.id) else { continue }
            loudness.measureIfNeeded(track: track, fileURL: url)
        }
    }

    /// 设置 › 通用 ›「始终检查可用的下载」：启动时把资料库里还没落地的歌补下。
    ///
    /// 只在「自动下载」也开着时做——「始终检查」是自动下载的修饰语（Music 里它就排在
    /// 「自动下载」下面一行），自动下载关着还偷偷下就成了两个开关各行其是。
    /// `download` 自己会跳过已下好和正在下的，所以整份丢给它就行。
    private func checkForMissingDownloads() {
        let values = AppSettings.shared.values
        guard values.automaticDownloads, values.alwaysCheckForDownloads else { return }
        downloads.download(library.libraryTracks)
    }

    /// 把各音源账号里的歌单同步进资料库的「播放列表」。
    ///
    /// 主窗口上屏时、登录态变化时各自动跑一次；手动入口是「文件 ▸ 刷新账号歌单」
    /// 与账号歌单自己的右键菜单。`manual` 是用户自己点的那种：
    /// 这一次连之前从资料库里删掉的也一并拉回来。
    /// 真正拿去取流的档位：用户选的那一档，再过一道设置 › 播放 里的两个开关。
    ///
    /// - 「启用无损音频」关掉 → 从有损那几档起（Music 那边关掉就是封顶 AAC 256）；
    /// - 「杜比全景声」= 关闭 → 跳过沉浸声那一档。
    ///
    /// 夹取只改**起点**，降级阶梯照旧——这首歌没有目标档位时仍然一路往下试。
    var effectiveQuality: StreamQuality {
        let values = AppSettings.shared.values
        return qqLogin.quality.clamped(losslessEnabled: values.losslessEnabled,
                                       dolbyAtmos: resolvedDolbyAtmos)
    }

    /// 折算过的「杜比全景声」：`.automatic` 按当前默认输出设备变成`.alwaysOn` 或`.off`
    /// （见 `DolbyAtmosMode.resolved(for:)`），另外两档原样。
    ///
    /// **正在播的那一首不会因为换设备重新取流**：档位是在解析流地址那一刻定下的，
    /// 中途换档要换 item、要重新缓冲，为了一次插拔打断正在响的歌不值当。
    /// 下一首（含预取的那一首）自然按新设备的判定走。
    var resolvedDolbyAtmos: DolbyAtmosMode {
        AppSettings.shared.values.dolbyAtmos.resolved(for: audioOutput.output)
    }

    /// 下载时用的档位：设置 › 播放 ›「下载」那一档（夹取规则见 `downloadStreamQuality`）。
    ///
    /// 与 `effectiveQuality` 的不同：起点取的是设置里的下载档而不是登录态那档
    /// （下载是一次性的落地，用户愿意为它多花带宽是常事），杜比看的是
    /// 「下载杜比全景声」那个勾选框。
    var downloadQuality: StreamQuality { AppSettings.shared.values.downloadStreamQuality }

    /// 设置 › 高级 ›「还原所有对话框警告」。
    ///
    /// Amber 目前还没有「不再提示」这类可抑制的对话框，这颗键清的是留给它们的那个
    /// 偏好命名空间（`suppressedWarning.*`）——以后哪个对话框记了「不再提示」，
    /// 不用再回来改这里。
    func restoreSuppressedWarnings() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(AppState.suppressedWarningPrefix) {
            defaults.removeObject(forKey: key)
        }
        showToast("已还原所有对话框警告")
    }

    static let suppressedWarningPrefix = "suppressedWarning."

    /// 音量的落盘键（0…1 的 Double，见 init 里的接线）。
    private static let volumeKey = "playerVolume"

    func syncAccountPlaylists(manual: Bool = false) async {
        // 设置 › 通用 ›「同步资料库」。关掉后不再把账号里的歌单往资料库里搬；
        // 已经搬进去的不动（Music 关掉云资料库同步也只是停止同步）。
        // 手动点「刷新账号歌单」时给一句回音，否则看着像坏了。
        guard AppSettings.shared.values.syncLibrary else {
            if manual { showToast("「同步资料库」已关闭") }
            return
        }
        var fetched = 0
        for kind in ProviderKind.allCases {
            let remote = await provider(kind).accountPlaylists()
            // 没登录的音源返回空，但「空」也可能是这次请求失败——只有拿到过东西
            // 或者本来就没有该音源的账号歌单时才动库，免得一次网络抖动清空整组。
            let hadAny = library.playlists.contains { $0.origin == .account && $0.source?.kind == kind }
            guard !remote.isEmpty || hadAny else { continue }
            if remote.isEmpty && !isLoggedIn(kind) {
                library.syncAccountPlaylists([], kind: kind)
            } else if !remote.isEmpty {
                library.syncAccountPlaylists(remote, kind: kind, resetDismissed: manual)
                fetched += remote.count
            }
        }
        // 手动点的刷新一定要有回音：拉失败时什么都不动，界面上会像是没反应。
        if manual {
            showToast(fetched > 0 ? "已同步 \(fetched) 个账号歌单" : "没有取到账号歌单")
        }
    }

    /// 登录态问音源自己，不在这里按 kind 写死：「没有登录能力」与「`accountPlaylists`
    /// 的默认空实现」本来就是同一件事，两处各写一遍早晚会对不上。
    private func isLoggedIn(_ kind: ProviderKind) -> Bool {
        provider(kind).isLoggedIn
    }

    /// 「新建播放列表」：**只弹命名框，不建列表**。落地在 `commitNewPlaylist`。
    ///
    /// 从前这里是「先按默认名建出来，再弹改名框」——照搬 Music 侧栏就地编辑名字的模型
    /// （Music 那边新建的列表当场就在，Esc 只是结束编辑）。但 Amber 的命名走的是弹窗，
    /// 弹窗上有一颗「取消」，按下去列表却已经建好了；带曲目的入口更糟，
    /// 「已加入某某」的 toast 在弹窗之前就报了。[实机打回 2026-09-08]
    /// 有取消按钮就得真能取消，所以创建整个挪到确认之后。
    func promptNewPlaylist(with tracks: [Track] = []) {
        playlistNamePrompt = .create(tracks: tracks)
    }

    /// 命名框点「创建」之后真正落地的一步（`RootViewController` 调）。
    /// 名字留空就用默认名，与 `renamePlaylist` 对空名的处理一致。
    @discardableResult
    func commitNewPlaylist(name: String, tracks: [Track]) -> LibraryPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = library.createPlaylist(
            name: trimmed.isEmpty ? library.defaultNewPlaylistName() : trimmed,
            tracks: tracks)
        // 带曲目时才报「已加入」：空列表没什么可报的，Music 也不报。
        if !tracks.isEmpty { showToast("已加入「\(playlist.name)」") }
        return playlist
    }

    /// 播放资料库里的一份播放列表：本地列表直接放，音源列表先取详情。
    func playLibraryPlaylist(_ playlist: LibraryPlaylist, shuffled: Bool = false) async {
        if let source = playlist.source {
            await playPlaylist(source, shuffled: shuffled)
            return
        }
        guard !playlist.tracks.isEmpty else {
            showToast("这份播放列表是空的")
            return
        }
        let tracks = shuffled ? playlist.tracks.shuffled() : playlist.tracks
        player.play(tracks, source: .init(title: playlist.name,
                                          route: .libraryPlaylist(id: playlist.id)))
    }

    /// 往内容导航栈推一层。过渡期的登记点：`ContentNavigationController` 订阅
    /// `pendingRoute`，收到就入栈并清空（与旧`MainView.onChange(of:)` 同一条逻辑）。
    /// 计划里 §2 铁律 4 的终态是「导航意图走响应链冒泡」，那要等各页都换成 AppKit
    /// 之后再删这条；现在 21 处 `NavigationLink` 还是 SwiftUI 叶子里的（见 RouteLink.swift）。
    func push(_ route: Route) {
        pendingRoute = route
    }

    /// 「前往专辑」：曲目只带专辑名/id，得回资料库查出整张专辑才有详情页可推。
    func goToAlbum(of track: Track) {
        guard let album = library.album(for: track) else {
            showToast("这首歌所属的专辑不在资料库中")
            return
        }
        pendingRoute = .album(album)
    }

    /// 跳到资料库「艺人」页并选中某位艺人（搜索的资料库范围点艺人卡走这条）。
    ///
    /// 资料库艺人不是音源里的艺人，只是本地歌按艺人名分的类（`Artist.libraryIDPrefix`），
    /// 没有在线艺人页可去——拿名字当 mid 去打接口只会被拒（QQ 回 104400）。
    func openLibraryArtist(named name: String) {
        pendingLibraryArtistID = Artist.libraryIDPrefix + name
        sidebarSelection = .artists
    }

    /// 「前往艺人」：详情页按 id 拉全量资料，这里给个只带 id/名字的壳就够。
    /// 本地导入曲目没有在线 artistId，异步向音源检索该艺人，若匹配则跳转到在线艺人页；
    /// 若无匹配或离线，则回退跳转至资料库艺人。
    func goToArtist(of track: Track) {
        if let id = track.artistId, !id.isEmpty {
            pendingRoute = .artist(Artist(id: id, kind: track.kind, name: track.artistName,
                                          avatarURL: nil, description: nil))
            return
        }

        let trimmedName = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != ImportService.unknownArtist else {
            showToast("这首歌没有可跳转的艺人")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var candidateKinds: [ProviderKind] = [track.kind]
            if !candidateKinds.contains(self.selectedProvider) {
                candidateKinds.append(self.selectedProvider)
            }
            var matchedArtist: Artist?
            for kind in candidateKinds {
                guard let provider = self.providers[kind] else { continue }
                if let hits = try? await provider.searchArtists(keyword: trimmedName, limit: 5, offset: 0) {
                    if let exact = hits.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName }) {
                        matchedArtist = exact
                        break
                    } else if matchedArtist == nil, let first = hits.first {
                        matchedArtist = first
                    }
                }
            }
            if let matchedArtist {
                self.push(.artist(matchedArtist))
            } else {
                self.openLibraryArtist(named: trimmedName)
            }
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        // 连着两条 toast 时，旧的那个 3 秒计时要作废，否则它到点会把新的那条抹掉。
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }

    /// 歌词与待播清单共用 Music.app 右侧 Inspector；再次点击当前按钮即关闭。
    func toggleInspector(_ inspector: PlayerInspector) {
        playerInspector = playerInspector == inspector ? nil : inspector
    }
}

// MARK: - 侧栏与导航

enum SidebarItem: Hashable, Identifiable {
    case search
    case home
    case discovery
    case radio
    case recentlyAdded
    case artists
    case albums
    case songs
    case store
    case allPlaylists
    case favorites
    /// 资料库里的一份播放列表（侧栏「播放列表」组逐条列出，Music 同形）
    case playlist(id: String, name: String)

    var id: String {
        switch self {
        case .search: return "search"
        case .home: return "home"
        case .discovery: return "discovery"
        case .radio: return "radio"
        case .recentlyAdded: return "recently-added"
        case .artists: return "artists"
        case .albums: return "albums"
        case .songs: return "songs"
        case .store: return "store"
        case .allPlaylists: return "all-playlists"
        case .favorites: return "favorites"
        case .playlist(let id, _): return "playlist:\(id)"
        }
    }

    var title: String {
        switch self {
        case .search: return "搜索"
        case .home: return "主页"
        case .discovery: return "新发现"
        case .radio: return "广播"
        case .recentlyAdded: return "最近添加"
        case .artists: return "艺人"
        case .albums: return "专辑"
        case .songs: return "歌曲"
        case .store: return "iTunes Store"
        case .allPlaylists: return "所有播放列表"
        case .favorites: return "心水歌曲"
        case .playlist(_, let name): return name
        }
    }
}

enum PlayerInspector: String, Hashable, Identifiable {
    case lyrics
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: return "歌词"
        case .queue: return "待播清单"
        }
    }
}

/// 播放列表命名弹窗要办的事。改名与新建共用 `RootViewController` 那一个`NSAlert`。
///
/// 两者对「取消」的语义不同，所以必须分开记：改名时列表本来就在，取消什么都不动；
/// 新建时列表**还没建**，只有点「创建」才落地（见 `AppState.promptNewPlaylist`）。
enum PlaylistNamePrompt: Equatable {
    case rename(playlistID: String)
    case create(tracks: [Track])
}

/// 本地拼出来的曲目列表。音源没有对应歌单可落的段（「音乐回忆」）用它当落点。
struct LocalTrackList: Hashable {
    let id: String
    let title: String
    let tracks: [Track]
}

enum Route: Hashable {
    case playlist(Playlist)
    /// 资料库里的播放列表（本地自建 / 加进来的音源歌单 / 账号同步来的）
    case libraryPlaylist(id: String)
    case album(Album)
    case artist(Artist)
    case localTracks(LocalTrackList)
    /// 「探索更多」的落点：音源分类分组的浏览页
    case tagGroup(CatalogTagGroup)
    /// 目录页分段「查看全部」的专辑网格二级页
    case albumGrid(title: String, albums: [Album])
    /// 目录页分段「查看全部」的歌单网格二级页
    case playlistGrid(title: String, playlists: [Playlist])
    /// 目录页分段「查看全部」的曲目列表二级页
    case trackGrid(title: String, tracks: [Track])

    /// 曲目 →「所属专辑」的落点。
    ///
    /// 网易云播客单集的 albumId 是电台节目本身（`ne:djradio:<id>`，见 parseDJProgram），
    /// 拿去打专辑接口必回 400；那个 id 归歌单详情管（NeteaseAPI.playlistDetail 认这个前缀），
    /// 所以这里改落到电台节目单。曲目没有专辑就返回 nil，调用方据此不挂链接。
    static func album(of track: Track) -> Route? {
        guard let albumId = track.albumId, !albumId.isEmpty else { return nil }
        if albumId.contains(":djradio:") {
            return .playlist(Playlist(id: albumId, kind: track.kind,
                                      name: track.albumName.isEmpty ? track.artistName : track.albumName,
                                      coverURL: track.artworkURL,
                                      creatorName: track.artistName))
        }
        return .album(Album(id: albumId, kind: track.kind, name: track.albumName,
                            artistName: track.artistName, artistId: track.artistId,
                            artworkURL: track.artworkURL, publishDate: nil,
                            trackCount: 0, description: nil))
    }
}
