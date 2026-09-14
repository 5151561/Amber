import Combine
import Foundation

// MARK: - 艺人目录页的数据模型

/// Music 的艺人主页不是「详情表格」，是**目录页的一种**：容器 `ArtistDetailPageView` 与
/// 主页/新发现/广播共用同一台状态机 `CatalogPagePresenter<Page>`
/// （`artistpage 规格` §0 的边界那段：「页面容器本身、状态机是 `catalogpage` scope
/// 的题目；通用网格/货架卡片是 `lockup` scope 的题目」）。所以 Amber 这边同构：
/// 这个模型与 `CatalogFeedModel` 是同一个协议的两个实现，页面控制器是同一台
/// `CatalogPageViewController`。
///
/// 段结构照 Music 1.7 实机（2026-09-06，告五人页 AX 树 `sections=8`，自上而下）：
///
/// | 段 | 布局 | 内容 |
/// | --- | --- | --- |
/// | 0 | `.artistHero` | 满幅艺人大图背景（钉住不随滚，图上艺人名 + ⓘ / ▶ / ★ 三枚圆键） |
/// | 1 | `.artistBand(rows: 3)` | 左「最新發行」卡 + 右「熱門歌曲 ›」多列曲目 |
/// | 2 | `.squares(rows: 1)` | 「專輯」货架 |
/// | 3 | `.squares(rows: 1)` | 「單曲和 EP ›」货架 |
/// | 4 | `.squares(rows: 1)` | 「現場演出專輯」货架 |
/// | 5 | `.squares(rows: 1)` | 「相似藝人」货架（圆头像 + 名字） |
///
/// Music 还有「藝人歌單」「曾參與作品」两段，QQ / 网易都没有现成接口
/// （网易 eapi `/api/artist/playlists` 实测 400），交不出来就整段省掉——
/// 与目录页同一条规矩。
@MainActor
final class ArtistPageModel: ObservableObject, CatalogPageModelProviding {

    @Published private(set) var state: CatalogPageState = .loading

    /// 艺人页不摆页面大标题（`CatalogPageViewController.showsPageTitle` 给 false），
    /// 这里给艺人名只是让协议有个说得通的值。
    var title: String { artist.name }
    let emptyMessage = "这位艺人暂时没有可显示的内容。"
    let emptyImage = "music.mic"

    var statePublisher: AnyPublisher<CatalogPageState, Never> { $state.eraseToAnyPublisher() }

    private let appState: AppState
    private let artist: Artist
    private var reloadTask: Task<Void, Never>?
    /// 相似艺人单独取（见 `performReload`）；空就没有那一段。
    private var similarArtists: [Artist] = []

    init(appState: AppState, artist: Artist) {
        self.appState = appState
        self.artist = artist
    }

    deinit { reloadTask?.cancel() }

    // MARK: - 背景层

    /// 钉住的满幅封面（`ArtistBackdropView`）用的图：优先宽幅页头图（2000×938），
    /// 没有这张的艺人才退回方头像——见 `QQAPI.parseSingerDetail`，约一半艺人拿不到。
    var backdropArtworkURL: String? { artist.bannerURL ?? artist.avatarURL }

    // MARK: - 取数

    /// 首次上屏与错误页点「重试」都走这条；上一轮还没跑完就取消（同 `CatalogFeedModel.reload`）。
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.performReload() }
    }

    private func performReload() async {
        state = .loading
        similarArtists = []
        do {
            let provider = appState.provider(artist.kind)
            let detail = try await provider.artistDetail(artist)
            guard !Task.isCancelled else { return }
            state = .content(title: detail.artist.name, sections: sections(for: detail))

            // 相似艺人是**另一条**请求，且不进 `ArtistDetail`：它与正文（热门歌曲/专辑）
            // 无关，交不出来时整段省掉就行，不该并进详情去决定这一页成不成立。
            // 所以先让正文上屏，再补这一段——串在同一条 `reloadTask` 里，
            // 页面重载时跟着一起被取消。
            similarArtists = await provider.similarArtists(detail.artist)
            guard !Task.isCancelled, !similarArtists.isEmpty else { return }
            state = .content(title: detail.artist.name, sections: sections(for: detail))
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - 段 → 卡

    /// hero 这一段其实在数据到位**之前**就能摆（艺人名与头像随路由一起进来），
    /// Music 那边也是先出大图再补货架。这里仍然等数据齐了再一起上屏：
    /// 引擎的三态是「覆盖层 + 空快照」那一套（`CatalogPageViewController.apply(_:)`），
    /// 要让 hero 在加载态里活着就得给引擎再开一条「有内容的加载态」，
    /// 为一张图把三态弄成四态不划算。取舍写在这里，改主意时从这条注释开始。
    private func sections(for detail: ArtistDetail) -> [CatalogSection] {
        var sections: [CatalogSection] = []
        sections.append(heroSection(detail))
        if let band = bandSection(detail) { sections.append(band) }
        if let albums = albumsSection(detail) { sections.append(albums) }
        if let singles = singlesSection(detail) { sections.append(singles) }
        if let live = liveAlbumsSection(detail) { sections.append(live) }
        if let similar = similarSection() { sections.append(similar) }
        return sections
    }

    /// 满幅大图那一段：段里就一件。简介进 `description`（卡上那枚 ⓘ 用它），
    /// 白底 ▶ 播全部热门歌曲。
    private func heroSection(_ detail: ArtistDetail) -> CatalogSection {
        let tracks = detail.hotTracks
        let item = CatalogItem(
            id: "artist-hero-\(detail.artist.id)", kind: .artistHero,
            title: detail.artist.name,
            // 优先宽幅页头图（2000×938），没有这张的艺人才退回方头像——见
            // `QQAPI.parseSingerDetail`，约一半艺人拿不到。
            artworkURL: detail.artist.bannerURL ?? detail.artist.avatarURL,
            description: detail.artist.description,
            route: .artist(detail.artist),
            onPlay: tracks.isEmpty ? nil : { [appState] in appState.player.play(tracks) })
        return CatalogSection(id: "artist-hero", layout: .artistHero, items: [item])
    }

    /// 并排带：左边一张「最新發行」卡、右边「熱門歌曲 ›」的多列曲目（每列 3 行）。
    /// 两半都交不出来才整段省掉；只有一半时布局那边会自己退化（见
    /// `CatalogPageViewController.artistBandSection`）。
    private func bandSection(_ detail: ArtistDetail) -> CatalogSection? {
        let tracks = detail.hotTracks
        let release = latestRelease(detail.albums).map(releaseItem)
        guard release != nil || !tracks.isEmpty else { return nil }
        var section = CatalogSection(id: "artist-band", layout: .artistBand(rows: 3),
                                     title: release == nil ? nil : "最新发行")
        section.items = release.map { [$0] } ?? []
        section.tracks = tracks
        if !tracks.isEmpty {
            // › 挂在右半那个标题上：点进去是热门歌曲的全部列表。
            section.trailingTitle = "热门歌曲"
            section.destination = .trackGrid(title: "热门歌曲", tracks: tracks)
            section.showsChevron = true
        }
        return section
    }

    /// 「最新發行」= 发行日期最新的那张。两个音源的 `publishDate` 都是`yyyy-MM-dd`
    /// （网易云 `NeteaseAPI.formatDate`、QQ 的`release_time` / `publicTime`），
    /// 定长同格式，字符串比大小就是按日期比。一张都没有日期时退回第一张。
    private func latestRelease(_ albums: [Album]) -> Album? {
        let dated = albums.filter { !($0.publishDate ?? "").isEmpty }
        if let newest = dated.max(by: { ($0.publishDate ?? "") < ($1.publishDate ?? "") }) {
            return newest
        }
        return albums.first
    }

    private func releaseItem(_ album: Album) -> CatalogItem {
        CatalogItem(
            id: "release-\(album.id)", kind: .release,
            title: album.name,
            artworkURL: album.artworkURL,
            // [PX] 三行：发行日期 12pt 次要色 / 专辑名 16pt 主色 /「N 首歌曲」13pt 次要色。
            // 音源没给曲目数（`trackCount == 0`）就省掉末行，别写「0 首歌曲」。
            // 日期摆成 Music 的中文形（实机：2026年3月9日），不是音源的 2026-03-09。
            eyebrow: Self.localizedDate(album.publishDate),
            subtitle: album.trackCount > 0 ? "\(album.trackCount) 首歌曲" : nil,
            route: .album(album),
            onPlay: { [appState] in Task { await appState.playAlbum(album) } })
    }

    /// 「專輯」货架：单行方卡，只有「录音室专辑」这一类。
    ///
    /// 排序照 Music 实机（2025 → 2024 → 2023 → …新到旧）：音源的返回顺序
    /// （QQ `order:1` 实测 2016 / 2007 / 2014 … 不是新到旧）直接摆会乱序。
    /// 没给日期的保持音源顺序、垫在后面。
    ///
    /// 这里**不**把「最新發行」那张从货架里剔掉：Music 的專輯货架就是艺人的完整发行列表，
    /// 最新那张照样排在第一位。剔掉反而会让「› 查看全部」那一页与货架对不上。
    private func albumsSection(_ detail: ArtistDetail) -> CatalogSection? {
        let albums = sortedByNewest(detail.albums.filter { Self.isStudioAlbum($0) })
        guard !albums.isEmpty else { return nil }
        var section = CatalogSection(id: "artist-albums", layout: .squares(rows: 1), title: "专辑")
        section.destination = .albumGrid(title: "专辑", albums: albums)
        section.showsChevron = true
        section.items = albums.map(albumCard)
        return section
    }

    /// 「單曲和 EP」货架（Music 艺人页实机有的段，`albumType` ∈ {Single, EP}）。
    /// 网易的 type 是英文名（Single / EP），QQ 是 EP / Single，一个集合盖两边。
    private func singlesSection(_ detail: ArtistDetail) -> CatalogSection? {
        let singles = sortedByNewest(detail.albums.filter { Self.isSingleOrEP($0) })
        guard !singles.isEmpty else { return nil }
        var section = CatalogSection(id: "artist-singles", layout: .squares(rows: 1),
                                     title: "单曲和 EP")
        section.destination = .albumGrid(title: "单曲和 EP", albums: singles)
        section.showsChevron = true
        section.items = singles.map(albumCard)
        return section
    }

    /// 「現場演出專輯」货架（QQ `albumType == 演唱会`；网易不区分，这段整段省掉）。
    private func liveAlbumsSection(_ detail: ArtistDetail) -> CatalogSection? {
        let live = sortedByNewest(detail.albums.filter { Self.isLiveAlbum($0) })
        guard !live.isEmpty else { return nil }
        var section = CatalogSection(id: "artist-live", layout: .squares(rows: 1),
                                     title: "现场演出专辑")
        section.destination = .albumGrid(title: "现场演出专辑", albums: live)
        section.showsChevron = true
        section.items = live.map(albumCard)
        return section
    }

    /// 艺人页的方卡：专辑名一行（最多两行）+ 年份一行。
    /// Music 实机（專輯 / 單曲和 EP / 現場演出專輯都是这个形）：「2025年」，
    /// 没给日期就不摆第二行——副标题写艺人名是多余的（这就是 TA 的艺人页）。
    private func albumCard(_ album: Album) -> CatalogItem {
        CatalogItem(
            id: album.id, kind: .square,
            title: album.name,
            artworkURL: album.artworkURL,
            subtitle: Self.yearLabel(album.publishDate),
            route: .album(album),
            onPlay: { [appState] in Task { await appState.playAlbum(album) } })
    }

    // MARK: - 专辑类型与日期

    /// 类型词的两个集合：QQ `albumType`（录音室专辑 / EP / Single / 演唱会，
    /// [实测 2026-09-06 curl]）与网易 `type`（专辑 / EP / Single）都落得进去。
    /// 给不出类型（nil / 认不得的词）一律当录音室专辑，别把人家的碟弄丢。
    private static let singleTypes: Set<String> = ["Single", "单曲", "EP"]
    private static let liveTypes: Set<String> = ["演唱会", "現場演出", "现场演出", "Live"]

    private static func isStudioAlbum(_ album: Album) -> Bool {
        !(singleTypes.contains(album.albumType ?? "") || liveTypes.contains(album.albumType ?? ""))
    }

    private static func isSingleOrEP(_ album: Album) -> Bool {
        singleTypes.contains(album.albumType ?? "")
    }

    private static func isLiveAlbum(_ album: Album) -> Bool {
        liveTypes.contains(album.albumType ?? "")
    }

    /// 音源两个平台给的日期都是定长 `yyyy-MM-dd`（网易云`NeteaseAPI.formatDate`、
    /// QQ 的 `release_date` / `publicTime`），字符串比大小就是按日期比。
    /// 没给日期的保持原顺序、垫在后面。
    private func sortedByNewest(_ albums: [Album]) -> [Album] {
        albums.enumerated().sorted { lhs, rhs in
            let left = lhs.element.publishDate ?? ""
            let right = rhs.element.publishDate ?? ""
            switch (left.isEmpty, right.isEmpty, left == right) {
            case (true, true, _), (_, _, true): return lhs.offset < rhs.offset
            case (true, false, _): return false
            case (false, true, _): return true
            default: return left > right
            }
        }.map(\.element)
    }

    /// 「2026-03-09」→「2026年3月9日」（Music 資訊行的中文日期）；
    /// 格式对不上就原样返回，至少不编。
    private static func localizedDate(_ date: String?) -> String? {
        guard let date, !date.isEmpty else { return nil }
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return date }
        return "\(year)年\(month)月\(day)日"
    }

    /// 「2026-03-09」→「2026年」（专辑卡的第二行，Music 实机只给年份）。
    private static func yearLabel(_ date: String?) -> String? {
        guard let date, date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
        return "\(year)年"
    }

    /// 「相似艺人」货架：这一页最后一段（Music 的 macOS 艺人页把它摆在最底下）。
    ///
    /// 沿用「专辑」那条 `.squares(rows: 1)` 的方卡货架——同一张`.square` 卡、同一套
    /// 尺寸与间距，只把封面切成圆的（`isCircularArtwork`，Music 里艺人一律圆头像）。
    /// 不新造卡型、不为这一栏另立度量。
    ///
    /// 没有「› 查看全部」：接口一次就给这么些（`QQAPI.similarArtistCount`），
    /// 没有第二页可翻，摆个 › 点进去只会看到同一批人。
    private func similarSection() -> CatalogSection? {
        guard !similarArtists.isEmpty else { return nil }
        var section = CatalogSection(id: "artist-similar", layout: .squares(rows: 1),
                                     title: "相似艺人")
        section.items = similarArtists.map { artist in
            // 只有名字一行：艺人卡不摆副标题（Music 也不摆），也没有「播放这位艺人」的落点，
            // 所以不给 `onPlay`——整卡就一个落点：那位艺人的页面。
            CatalogItem(
                id: "similar-\(artist.id)", kind: .square,
                title: artist.name,
                artworkURL: artist.avatarURL,
                isCircularArtwork: true,
                route: .artist(artist))
        }
        return section
    }
}

// MARK: - 主页 / 新发现 / 广播那台模型也走同一个协议

/// `CatalogFeedModel` 的`title` / `emptyMessage` / `emptyImage` / `state` / `reload()`
/// 本来就是这几样，只差一条把 `@Published` 抹成普通 publisher 的桥（协议里写不了
/// `@Published`）。写成扩展是为了不动那个文件。
extension CatalogFeedModel: CatalogPageModelProviding {
    var statePublisher: AnyPublisher<CatalogPageState, Never> { $state.eraseToAnyPublisher() }
}
