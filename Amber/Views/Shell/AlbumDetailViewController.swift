import AppKit
import SwiftUI

// MARK: - 专辑详情页（AppKit）—— 计划阶段 4 批 B
//
// 替代 `DetailViews.swift` 的`AlbumDetailView`。加载与文案（`load()` / `albumMetadata` /
// `albumFooterCount` / 年份反解）从旧版原样搬，一字不改。

@MainActor
final class AlbumDetailViewController: TrackTableViewController {

    private typealias M = MusicMetrics.Detail

    private let album: Album
    private var detail: AlbumDetail?
    private var loadTask: Task<Void, Never>?
    private var header: AlbumHeaderView?
    /// 已加入资料库的专辑才排星级列；未收藏的目录专辑只有加号／下载。
    private var style: TrackListStyle = .detail

    init(appState: AppState, album: Album) {
        self.album = album
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    // MARK: 形态

    override var trackStyle: TrackListStyle { style }
    /// [AX] 按钮行底 323 → 首行音轨顶 342
    override var headerBottomSpacing: CGFloat { M.albumTrackListTop }
    /// 专辑行的行体在 40 的留白之内（心水星挂在留白里），与旧版一致。
    override var trackRowContentInset: CGFloat { M.albumContentHorizontal }
    /// [AX] 末行音轨底 894 → 版权信息框顶 923
    override var footerTopSpacing: CGFloat { M.albumFooterTop }
    override var emptyMessage: String { "这张专辑现在没有曲目。" }
    override var emptyImage: String { "square.stack" }

    // MARK: 标题栏右端那两件

    /// 「共享」分享的是这张碟在音源网页版的公开页面（`ProviderWebLink.album`）。
    /// 用 route 里那张 `Album` 而不是`detail`：id 与音源在推进这一页时就定了，
    /// 不必等接口回来，那颗键也就不会加载完才冒出来。本地导入的专辑给不出，整件不摆。
    override var pageShareItems: [Any] { [album.webShareURL].compactMap { $0 } }

    /// 「•••」的项由页头给（能力袋与页头右键那份同一个，项序另有一份，
    /// 见 `CollectionActions.albumPageEntries`）。页头还没建起来（加载中 / 失败）时给空表，
    /// 工具栏那边退回窗口那份。
    override var pageMoreEntries: [MenuSpec.Entry] { header?.moreMenuEntries() ?? [] }

    /// 摆。[AX] `album-detail.json` 实测标题栏右端：共享 x=1171、更多 x=1207（另有搜索 1255）。
    /// 与 `pageMoreEntries` 分工：这一条只管摆不摆——页头还没建起来（加载中 / 失败）、
    /// 上一条给空表时这一件照样在，不会闪进闪出（[实测] §10.1 的
    /// `playlistShowsToolbarActions` 与`actionMenuFromSender:` 也是这么分的，
    /// macOS 27 / 26A5425a 基线）。
    override var pageShowsToolbarActions: Bool { true }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 入库 / 取消入库要换行的形态（星级列），喜爱要换标题后那颗 ★。
        observers.observe({ [appState] in appState.library.libraryAlbums }) { [weak self] _ in
            self?.libraryStateChanged()
        }
        observers.observe({ [appState] in appState.library.favoriteAlbumIDs }) { [weak self] _ in
            self?.refreshVisibleRows()
        }
        reload()
    }

    override func retryTapped() { reload() }

    // MARK: - 加载

    private func reload() {
        loadTask?.cancel()
        apply(state: .loading)
        loadTask = Task { [weak self] in
            guard let self else { return }
            // 本地导入归出来的专辑没有音源可问详情，曲目就在资料库里（见 ImportService）。
            if album.isLocal {
                let detail = AlbumDetail(album: album,
                                         tracks: appState.library.tracks(in: album))
                self.detail = detail
                self.show(detail)
                return
            }
            do {
                let detail = try await appState.provider(album.kind).albumDetail(album)
                guard !Task.isCancelled else { return }
                self.detail = detail
                self.show(detail)
            } catch {
                guard !Task.isCancelled else { return }
                self.apply(state: .error(error.localizedDescription))
            }
        }
    }

    /// 入库 / 退库换的只是行里多不多一列星级（`.detail` ↔`.libraryAlbum`），
    /// **行高两档相同**（`TrackRowRegistry.rowHeight(for:)` 都走`compactHeight`），
    /// 所以不必整表重排：可见行重配一次就够——`TrackRowView.build(for:)` 只增删星级那一件，
    /// 离屏的行装回来时本来就会重走一次 `configure`。
    private func libraryStateChanged() {
        style = appState.library.isAlbumInLibrary(album) ? .libraryAlbum : .detail
        refreshVisibleRows()
    }

    private func show(_ detail: AlbumDetail) {
        style = appState.library.isAlbumInLibrary(detail.album) ? .libraryAlbum : .detail
        let tracks = detail.tracks
        let content = AlbumHeaderView.Content(
            album: detail.album,
            tracks: tracks,
            artworkURL: detail.album.artworkURL,
            title: detail.album.name,
            artist: detail.album.artistName,
            metadata: albumMetadata(detail),
            description: detail.album.description,
            hasLossless: tracks.contains { $0.losslessAvailable == true },
            isEmpty: tracks.isEmpty)
        if let header {
            header.apply(content)
        } else {
            header = AlbumHeaderView(
                appState: appState, content: content,
                play: { [weak self] in self?.play(tracks) },
                shuffle: { [weak self] in self?.play(tracks.shuffled()) })
        }
        header?.play = { [weak self] in self?.play(tracks) }
        header?.shuffle = { [weak self] in self?.play(tracks.shuffled()) }
        invalidateFooter()
        apply(header: header, tracks: tracks)
    }

    private func play(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        appState.player.play(tracks, source: queueSource)
    }

    /// 队列面板的「来自《…》」＝这张专辑，点它回专辑页。
    override var queueSource: PlayerController.QueueSource? {
        .init(title: detail?.album.name ?? album.name, route: .album(album))
    }

    // MARK: - 页脚（发行日期 + 「N 首歌曲，X 分钟」）

    override func makeFooterView() -> NSView? {
        guard let detail else { return nil }
        var lines: [String] = []
        if let date = detail.album.publishDate { lines.append(date) }
        lines.append(albumFooterCount(detail))
        // [AX] 版权信息左沿 253.5 = 封面左沿 242.5 再缩进 11；行内缩已经由 `trackRowContentInset`
        // 交给行去让，页脚在表里是整宽的一行，所以两段要自己加起来。
        return DetailFooterView(lines: lines,
                                leading: M.albumContentHorizontal + M.albumFooterLeading)
    }

    // MARK: - 文案（旧版原样搬）

    /// 头部信息行：Music.app 是「曲风 · 年份」（如 Mandopop · 2025），后面接音质与星级。
    /// 音源没给曲风就只剩年份——不放「专辑」这种没有信息量的占位词。
    private func albumMetadata(_ detail: AlbumDetail) -> String {
        var parts: [String] = []
        if let genre = detail.album.genre, !genre.isEmpty { parts.append(genre) }
        if let year = detail.album.publishDate?.releaseYear { parts.append("\(year)") }
        return parts.joined(separator: " · ")
    }

    /// 底部统计：Music.app 为「N 首歌曲，X 分钟」
    private func albumFooterCount(_ detail: AlbumDetail) -> String {
        let count = detail.tracks.count
        let minutes = Int((detail.tracks.reduce(0) { $0 + $1.duration } / 60).rounded())
        return minutes > 0 ? "\(count) 首歌曲，\(minutes) 分钟" : "\(count) 首歌曲"
    }
}

private extension String {
    /// 从形如 "2023-02-14" / "2023年2月14日" 的发行日期里取 4 位年份。
    var releaseYear: Int? {
        var digits = ""
        for ch in self {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
            if digits.count == 4 { break }
        }
        return digits.count == 4 ? Int(digits) : nil
    }
}
