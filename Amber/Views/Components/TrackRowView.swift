import AppKit
import SwiftUI

// MARK: - 曲目行（阶段 4 批 A）

// `TrackRow.swift`（SwiftUI）的等价替换：一行一个`NSTableRowView`，按
// `TrackRowConfiguration.style` 切三套格子布局。原则是计划 §2 铁律 5
// 「换骨架，像素一个不改」——列宽、字号、间距、圆角、浓度全部照搬 SwiftUI 版
// （数与出处都在 `MusicMetrics.TrackRow` / `MusicMetrics.Rating` 里）。
//
// 三套版式（`TrackListStyle`）：
// - `.detail` / `.libraryAlbum`：专辑紧凑行，行高 45。收藏星悬挂在行体左侧 −24，
//   序号列 27、标题列吃剩余宽、星级 60（仅 `.libraryAlbum`）+ 入库键 16、时长 44、••• 23.5。
// - `.playlist`：歌单行，行高 56。收藏星槽 40、封面 40、（榜单）名次 16、
//   标题/艺人/专辑三列等分、入库键 16、时长 53、••• 40。
// - `.search` / `.library`：丰富行，行高 54。收藏星在行体外 15+22+4、序号列 27、封面 40、
//   标题+艺人两行、专辑列、（搜索）来源标、时长 44、••• 23.5。
//
// 三条与 SwiftUI 版不同、但都是「AppKit 本来就对」的地方：
// 1. **行 = 内容列整宽**（与 Music 的 AX 一致：行 `[202.5, …, 1267.5]`，行内第一格
//    「喜爱」在 216.5、序号格在 242.5＝页面左内缩）。SwiftUI 版的 `TrackRow` 只有列表宽、
//    收藏星靠负偏移伸进页面留白里；表格里没有「伸出行外」这回事（`hitTest` 出了
//    bounds 就是 nil），所以左右留白由行自己让（`contentInset`），星落在留白里、点得到。
// 2. **分隔线画在行内最底一线**：表格里行 pitch 必须等于行高，SwiftUI 版是把 `Divider`
//    摆在行外、整行实占 46/55/57。
// 3. 悬浮/选中底色用 `labelColor` 的一档浓度自己画（`Color.primary` 就是`labelColor`，
//    与批 B 的头部按钮同一条），不走系统强调色。
//
// 铁律：不新增 Representable（1）；滚动容器里的格子不挂 `NSHostingView`（2）——
// 四条电平走 `TrackRowLevelsView`（CALayer 自绘，理由见那个类的注释）；
// 悬浮态由行自己的 tracking area 持有并推给格子，不经 `@Published`（3）。

/// 表格占满内容列、页面左右留白交给行来让时，让表格把留白告诉行。
///
/// 批 B 的三个详情页头部（`DetailHeaderViews.swift`）就是这么做的：头部视图本身是整宽，
/// 40pt 内缩画在自己里面。行照同一条走，默认值按形态给（见 `contentInset`），
/// 与旧版调用点不一致的页面在建表时实现这个协议改掉；表格若已经自己内缩过就给 0。
@MainActor
protocol TrackRowContentInsetProviding: AnyObject {
    var trackRowContentInset: CGFloat { get }
}

/// 行的右键 / ••• 菜单由**表格**来造。
///
/// 「菜单作用于哪几首」（整份选中集还是只有被点的这一行）与「右键落在选区外先预选」
/// 都只有页面看得全：行视图既不知道选中集里那些行号对应哪些曲目，也不该去改选区。
/// 行只负责把「我这一行被右键了」转上去——`SongsTableController.menuTracks(forRow:)`
/// + `TrackDisplayTableView.menu(for:)` 是仓库里这件事的正确形状，这里照它走。
@MainActor
protocol TrackRowMenuProviding: AnyObject {
    /// 这一行要弹什么。`row` 是表格行号；nil = 不弹。
    func trackRowMenu(forRow row: Int) -> NSMenu?
}

final class TrackRowView: NSTableRowView, TrackRowViewConfigurable {

    private typealias M = MusicMetrics.TrackRow
    private typealias R = MusicMetrics.Rating

    // MARK: 状态

    private var configuration: TrackRowConfiguration?
    private weak var appState: AppState?
    private var style: TrackListStyle?

    /// `configure` 时读一次的快照（铁律 3：行自己持有，不订阅、不经`@Published`）。
    /// 当前曲 / 播放中 / 心水 / 入库 / 评分变了由表格（批 B）重刷可见行。
    private var isCurrent = false
    private var isPlaying = false
    private var isFavorite = false
    private var isInLibrary = false

    /// 悬浮态。行自己的 tracking area 推，推给各件。
    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            pushState()
            needsDisplay = true
        }
    }

    /// 页面左右留白。不设就按形态取旧版各自的默认值（逐页核过 SwiftUI 的调用点）：
    /// - `.playlist`：**0**。歌单详情与资料库播放列表里`TrackList` 摆在页面内缩**之外**
    ///   （只有头部与页脚各自内缩 40），所以行本来就占满内容列——[AX] Music 的歌单行
    ///   同样是 `[202.5, …, 1267.5]`、封面左沿 242.5 ＝ 行左 +40（那 40 是行内的收藏星槽）。
    /// - `.detail` / `.libraryAlbum`：**40**（专辑详情整块内缩`albumContentHorizontal`）。
    /// - `.search` / `.library`：**34**（`Page.leadingMargin`）。
    ///
    /// 两处例外在建表时改掉（见 `TrackRowContentInsetProviding`）：艺人页的热门歌曲是
    /// `.detail` 但页面内缩 34；目录里的「本地列表」网格页是`.playlist` 但整块内缩了 40。
    /// 表格若已经自己内缩过就给 0。
    var contentInset: CGFloat {
        get { explicitInset ?? defaultInset }
        set {
            guard explicitInset != newValue else { return }
            explicitInset = newValue
            needsLayout = true
            needsDisplay = true
        }
    }

    private var explicitInset: CGFloat?

    private var defaultInset: CGFloat {
        switch style {
        case .detail, .libraryAlbum: return MusicMetrics.Detail.albumContentHorizontal
        case .playlist: return 0
        case .search, .library, nil: return MusicMetrics.Page.leadingMargin
        }
    }

    // MARK: 件（按形态建，形态不变就一直复用）

    private var favoriteButton: TrackRowGlyphButton?
    private var leadingSlot: TrackRowLeadingSlot?
    private var artworkButton: TrackRowArtworkButton?
    private var rankLabel: CatalogLabel?
    private var titleLabel: CatalogLabel?
    /// 丰富行标题下的艺人（第二行）
    private var subtitleLabel: CatalogLabel?
    /// 歌单行的艺人 / 专辑两列（可点跳转）
    private var artistLink: TrackRowLinkButton?
    private var albumLink: TrackRowLinkButton?
    /// 丰富行的专辑列（不可点，与 SwiftUI 版同）
    private var albumLabel: CatalogLabel?
    private var kindBadge: TrackRowKindBadge?
    private var ratingView: TrackRowRatingView?
    private var addButton: TrackRowGlyphButton?
    private var durationLabel: CatalogLabel?
    private var moreButton: CatalogMoreButton?

    // MARK: 生命周期

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 底色自己画（悬浮 / 选中两档），别让 `NSTableRowView` 先铺一层不透明的。
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 与批 B 的头部一致：从上往下排，`MusicMetrics` 里那串窗口坐标直接对得上。
    override var isFlipped: Bool { true }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            // 入库键在「悬浮或选中」时显形（SwiftUI 版 `libraryActionButton.visible`）。
            pushState()
            needsDisplay = true
        }
    }

    // MARK: - 配置

    func configure(_ configuration: TrackRowConfiguration, appState: AppState) {
        self.appState = appState
        self.configuration = configuration
        build(for: configuration.style)

        let track = configuration.track
        let player = appState.player
        let library = appState.library
        isCurrent = player.currentTrack?.id == track.id
        isPlaying = isCurrent && player.isPlaying
        isFavorite = library.isFavorite(track)
        isInLibrary = library.isInLibrary(track)

        titleLabel?.stringValue = track.title
        subtitleLabel?.stringValue = track.artistName
        albumLabel?.stringValue = track.albumName
        durationLabel?.stringValue = track.duration.mmss
        rankLabel?.stringValue = "\(configuration.index)"
        leadingSlot?.setIndex(configuration.index)
        artworkButton?.setArtwork(url: track.artworkURL)
        ratingView?.setRating(library.rating(for: track.id))

        if let artistLink {
            artistLink.label.stringValue = track.artistName
            artistLink.isLink = track.canGoToArtist
        }
        if let albumLink {
            albumLink.label.stringValue = track.albumName
            albumLink.isLink = !track.albumName.isEmpty && Route.album(of: track) != nil
        }
        if let kindBadge {
            kindBadge.text = track.kind.shortName
        }

        // [HIG] 行的可达名称与屏幕上读到的一致：曲名 + 艺人（排了专辑列的形态再补专辑）。
        var parts = [track.title, track.artistName]
        if configuration.style.isRich { parts.append(track.albumName) }
        setAccessibilityLabel(parts.filter { !$0.isEmpty }.joined(separator: "，"))

        pushState()
        needsLayout = true
        needsDisplay = true
    }

    /// 心水 / 入库这两件是行自己点出来的，点完就地回读一次，不等表格刷。
    private func refreshLibraryState() {
        guard let appState, let track = configuration?.track else { return }
        isFavorite = appState.library.isFavorite(track)
        isInLibrary = appState.library.isInLibrary(track)
        pushState()
    }

    /// 悬浮 / 选中 / 当前曲三样推给各件。
    private func pushState() {
        let visible = hovering || isSelected
        favoriteButton?.setSymbol(isFavorite ? "star.fill" : "star")
        favoriteButton?.setVisible(hovering || isFavorite)
        favoriteButton?.toolTip = isFavorite ? "取消心水" : "心水"
        favoriteButton?.setAccessibilityLabel(isFavorite ? "取消心水" : "心水")

        leadingSlot?.setState(hovering: hovering, isCurrent: isCurrent, isPlaying: isPlaying)
        artworkButton?.setState(hovering: hovering, isCurrent: isCurrent, isPlaying: isPlaying)

        // + / ↓ / ⏹ 三态与专辑页头同一套词汇（`LibraryDownloadAction`）；
        // 「已下载」这一态**不用页头那枚红 ✓**——红 ✓ 说的是「整张碟/整个歌单都在本地了」，
        // 曲目行说的是这一首，Music 在行里画的是灰色实心圆 + 挖空的下箭头
        // （与歌曲表的云端列、资料库艺人页的下载列同一枚，见 `LibraryArtistCloudView`）。
        let addAction = configuration.map {
            appState?.downloads.action(inLibrary: isInLibrary, tracks: [$0.track]) ?? .addToLibrary
        } ?? .addToLibrary
        addButton?.setSymbol(addAction == .done ? "arrow.down.circle.fill" : addAction.symbol)
        addButton?.contentTintColor = addAction == .done ? .secondaryLabelColor : TrackRowKit.key
        // 下载相关的三态（↓ / ⏹ / ✓）常驻——它是状态，不看指针在哪儿；
        // 只有「+ 添加到资料库」还守着悬浮/选中才显形的老规矩。
        addButton?.setVisible(addAction == .addToLibrary ? visible : true)
        addButton?.toolTip = addAction.label
        addButton?.setAccessibilityLabel(addAction.label)

        moreButton?.setHovering(hovering)
        // [PX] 未悬浮的 ••• 是 0.75 的次要色（SwiftUI 版 `.opacity(hovering ? 1 : 0.75)`）。
        moreButton?.alphaValue = hovering ? 1 : 0.75

        let titleColor = isCurrent ? TrackRowKit.key : NSColor.labelColor
        titleLabel?.textColor = titleColor
        rankLabel?.textColor = titleColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
        configuration = nil
        isCurrent = false
        isPlaying = false
        isFavorite = false
        isInLibrary = false
        artworkButton?.prepareForReuse()
        leadingSlot?.prepareForReuse()
        titleLabel?.stringValue = ""
        subtitleLabel?.stringValue = ""
        albumLabel?.stringValue = ""
        durationLabel?.stringValue = ""
        rankLabel?.stringValue = ""
        artistLink?.label.stringValue = ""
        albumLink?.label.stringValue = ""
        favoriteButton?.setVisible(false)
        addButton?.setVisible(false)
    }

    // MARK: - 建件

    /// 换形态时**只按差异增删**，其余的件原样留着。
    ///
    /// `.detail` ↔ `.libraryAlbum` 只差一列星级（`TrackTableContract` 的`showsRating`），
    /// 从前这里一上来就 `for view in subviews { removeFromSuperview() }`：专辑页点一次
    /// 「添加到资料库」，整表 `reloadData()` 之后每个复用行还要把十几件子视图全拆全建。
    /// 留下来的件由 `configure` 重填、`layout()` 重排——各列的 frame 只看形态、
    /// 不看建的顺序，所以像素与全拆全建那一版一模一样。
    private func build(for style: TrackListStyle) {
        let previous = self.style
        guard previous != style else { return }
        self.style = style

        // 封面只有两套参数：歌单行暗罩 0.35 / 三角 15 bold / 未悬浮的当前曲在封面上摆电平，
        // 丰富行暗罩 0.18 / 三角 12 semibold / 电平归首列那一格。所以只有跨「歌单 ↔ 丰富」
        // 这条界才真要换一件，`.search` ↔ `.library` 之间照旧复用。
        if previous == .playlist || style == .playlist {
            artworkButton?.removeFromSuperview()
            artworkButton = nil
        }

        favoriteButton = part(favoriteButton, true) {
            // 收藏星：[PX] 实测 11.0×10.5，实心/空心**都是品牌红**（悬浮态的空心星不是灰的）。
            let favorite = TrackRowGlyphButton(symbol: "star", pointSize: 10)
            favorite.onClick = { [weak self] in
                guard let self, let track = configuration?.track else { return }
                appState?.library.toggleFavorite(track)
                refreshLibraryState()
            }
            return favorite
        }

        titleLabel = part(titleLabel, true) { TrackRowKit.label(size: 13) }

        durationLabel = part(durationLabel, true) {
            TrackRowKit.digitsLabel(size: 12, alignment: .right)
        }

        moreButton = part(moreButton, true) {
            let more = CatalogMoreButton()
            more.onClick = { [weak self] in self?.showMenu() }
            return more
        }

        leadingSlot = part(leadingSlot, style != .playlist) {
            let slot = TrackRowLeadingSlot()
            slot.playButton.onClick = { [weak self] in self?.play() }
            return slot
        }

        artworkButton = part(artworkButton, style.isRich) {
            let isPlaylist = style == .playlist
            let artwork = TrackRowArtworkButton(scrimOpacity: isPlaylist ? 0.35 : 0.18,
                                                glyphSize: isPlaylist ? 15 : 12,
                                                glyphWeight: isPlaylist ? .bold : .semibold,
                                                showsLevels: isPlaylist)
            artwork.onClick = { [weak self] in self?.play() }
            return artwork
        }

        rankLabel = part(rankLabel, style == .playlist) {
            TrackRowKit.digitsLabel(size: 13, color: .labelColor, alignment: .left)
        }

        artistLink = part(artistLink, style == .playlist) {
            let artist = TrackRowLinkButton(size: 13, color: .secondaryLabelColor)
            artist.onClick = { [weak self] in
                guard let track = self?.configuration?.track else { return }
                self?.appState?.goToArtist(of: track)
            }
            return artist
        }

        albumLink = part(albumLink, style == .playlist) {
            let album = TrackRowLinkButton(size: 13, color: .secondaryLabelColor)
            album.onClick = { [weak self] in
                guard let track = self?.configuration?.track,
                      let route = Route.album(of: track) else { return }
                self?.appState?.push(route)
            }
            return album
        }

        // 丰富行（搜索 / 本地列表）：标题下的艺人第二行 + 专辑列；来源标只有搜索有。
        let isRichList = style.isRich && style != .playlist
        subtitleLabel = part(subtitleLabel, isRichList) {
            TrackRowKit.label(size: 11, color: .secondaryLabelColor)
        }
        albumLabel = part(albumLabel, isRichList) {
            TrackRowKit.label(size: 12, color: .secondaryLabelColor)
        }
        kindBadge = part(kindBadge, style == .search) { TrackRowKindBadge() }

        ratingView = part(ratingView, style.showsRating) {
            let rating = TrackRowRatingView()
            rating.onRate = { [weak self] value in
                guard let id = self?.configuration?.track.id else { return }
                self?.appState?.library.setRating(value, for: id)
                self?.ratingView?.setRating(self?.appState?.library.rating(for: id) ?? 0)
            }
            return rating
        }

        addButton = part(addButton, style.isAlbumTable || style == .playlist) {
            // Music 在星级右侧留了一列 16pt：不在资料库时是「+」，已入库后变成「下载」。
            let button = TrackRowGlyphButton(symbol: "plus", pointSize: 13)
            button.onClick = { [weak self] in self?.toggleLibrary() }
            return button
        }
    }

    /// 这一件在新形态里还要不要：要就留着已有的（没有才造），不要就摘掉。
    private func part<V: NSView>(_ existing: V?, _ wanted: Bool, make: () -> V) -> V? {
        guard wanted else {
            existing?.removeFromSuperview()
            return nil
        }
        if let existing { return existing }
        let view = make()
        addSubview(view)
        return view
    }

    // MARK: - 版式

    /// 行体（悬浮 / 选中底色那块）在行内的位置。收藏星在专辑与丰富两种形态里都在行体之外。
    private var bodyRect: NSRect {
        let inset = contentInset
        let width = max(0, bounds.width - inset * 2)
        guard style == .search || style == .library else {
            return NSRect(x: inset, y: 0, width: width, height: bounds.height)
        }
        let lead = M.horizontalPadding + M.favoriteWidth + M.favoriteGap
        return NSRect(x: inset + lead, y: 0, width: max(0, width - lead), height: bounds.height)
    }

    /// 分隔线左沿（相对整行）：从曲名列起，不穿过序号与封面。
    private var dividerLeading: CGFloat {
        guard let configuration else { return contentInset }
        switch configuration.style {
        case .playlist:
            // [AMPAdjustableDividerTableRow] 40 + 40 + 10 = 90；榜单多一条名次列（12+16+12）＝120
            return contentInset + M.playlistFavoriteAreaWidth + M.artworkSize
                + (configuration.isChart ? M.chartRankGap * 2 + M.chartRankWidth : M.contentSpacing)
        case .search, .library:
            return contentInset + M.dividerLeading
        case .detail, .libraryAlbum:
            return contentInset + M.rowBodyInset + M.indexWidth + M.contentSpacing
        }
    }

    override func layout() {
        super.layout()
        guard let configuration else { return }
        switch configuration.style {
        case .playlist: layoutPlaylistRow(configuration)
        case .detail, .libraryAlbum: layoutAlbumRow(configuration)
        case .search, .library: layoutRichRow(configuration)
        }
    }

    /// 专辑紧凑行：`[星 −24] 6 | 序号 27 | 10 | 标题 * | 10 | [星级 60] 入库 16 | 10 | 时长 44 | 10 | ••• 23.5 | 15`
    private func layoutAlbumRow(_ configuration: TrackRowConfiguration) {
        let body = bodyRect
        let height = bounds.height
        let centerY = height / 2

        // 收藏星悬挂在行体左侧（[AX] Music 的「喜爱」格中心 229.5 ＝ 行左 +27 ＝ 页面内缩 −13）
        favoriteButton?.frame = NSRect(x: body.minX - M.detailFavoriteOffset, y: 0,
                                       width: M.favoriteWidth, height: height)

        var left = body.minX + M.rowBodyInset
        leadingSlot?.frame = NSRect(x: left, y: 0, width: M.indexWidth, height: height)
        left += M.indexWidth + M.contentSpacing

        var right = body.maxX - M.horizontalPadding
        layoutMoreButton(slotWidth: M.moreWidth, trailing: right, centerY: centerY)
        right -= M.moreWidth + M.contentSpacing

        if let durationLabel {
            TrackRowKit.layout(durationLabel, inkTrailing: right, width: M.durationWidth,
                               centerY: centerY)
        }
        right -= M.durationWidth + M.contentSpacing

        // 星级列与右侧 16pt 列当一个整体排（[AX] 1252…1324 与 1324…1340），首星才落在 1252.5。
        let ratingGroupWidth = configuration.style.showsRating ? R.rowWidth + M.addWidth : M.addWidth
        let groupX = right - ratingGroupWidth
        ratingView?.frame = NSRect(x: groupX, y: 0, width: R.rowWidth, height: height)
        addButton?.frame = NSRect(x: groupX + (configuration.style.showsRating ? R.rowWidth : 0)
                                     + M.addOffsetX,
                                  y: 0, width: M.addWidth, height: height)
        right = groupX - M.contentSpacing

        if let titleLabel {
            TrackRowKit.layout(titleLabel, inkLeading: left, width: max(0, right - left),
                               centerY: centerY)
        }
    }

    /// 丰富行：`15 星 22 4 | 6 序号 27 | 10 | 封面 40 | 10 | 标题/艺人 * | 10 | 专辑 * | [10 来源标] | 10 | 时长 44 | 10 | ••• 23.5 | 15`
    private func layoutRichRow(_ configuration: TrackRowConfiguration) {
        let body = bodyRect
        let height = bounds.height
        let centerY = height / 2

        favoriteButton?.frame = NSRect(x: contentInset + M.horizontalPadding, y: 0,
                                       width: M.favoriteWidth, height: height)

        var left = body.minX + M.rowBodyInset
        leadingSlot?.frame = NSRect(x: left, y: 0, width: M.indexWidth, height: height)
        left += M.indexWidth + M.contentSpacing
        artworkButton?.frame = NSRect(x: left, y: ((height - M.artworkSize) / 2).rounded(.toNearestOrEven),
                                      width: M.artworkSize, height: M.artworkSize)
        left += M.artworkSize + M.contentSpacing

        var right = body.maxX - M.horizontalPadding
        layoutMoreButton(slotWidth: M.moreWidth, trailing: right, centerY: centerY)
        right -= M.moreWidth + M.contentSpacing

        if let durationLabel {
            TrackRowKit.layout(durationLabel, inkTrailing: right, width: M.durationWidth,
                               centerY: centerY)
        }
        right -= M.durationWidth + M.contentSpacing

        if let kindBadge {
            let size = kindBadge.intrinsicContentSize
            kindBadge.frame = NSRect(x: right - size.width,
                                     y: (centerY - size.height / 2).rounded(.toNearestOrEven),
                                     width: size.width, height: size.height)
            right -= size.width + M.contentSpacing
        }

        // 标题列与专辑列都是 `maxWidth: .infinity`，剩余宽度对半分。
        let flexible = max(0, right - left - M.contentSpacing)
        let columnWidth = (flexible / 2).rounded(.toNearestOrEven)

        if let titleLabel {
            let titleHeight = titleLabel.intrinsicContentSize.height
            if let subtitleLabel {
                // 两行块整体居中，行距 1（SwiftUI 的 `VStack(spacing: 1)`）。
                let subtitleHeight = subtitleLabel.intrinsicContentSize.height
                let top = (height - (titleHeight + 1 + subtitleHeight)) / 2
                TrackRowKit.layout(titleLabel, inkLeading: left, width: columnWidth,
                                   centerY: top + titleHeight / 2)
                TrackRowKit.layout(subtitleLabel, inkLeading: left, width: columnWidth,
                                   centerY: top + titleHeight + 1 + subtitleHeight / 2)
            } else {
                TrackRowKit.layout(titleLabel, inkLeading: left, width: columnWidth, centerY: centerY)
            }
        }
        if let albumLabel {
            TrackRowKit.layout(albumLabel, inkLeading: left + columnWidth + M.contentSpacing,
                               width: columnWidth, centerY: centerY)
        }
    }

    /// 歌单行：`星槽 40 | 封面 40 [12 名次 16 12 | 10] 标题 * 10 | 艺人 * 10 | 专辑 * | 入库 16 | 时长 53 | ••• 40`
    private func layoutPlaylistRow(_ configuration: TrackRowConfiguration) {
        let body = bodyRect
        let height = bounds.height
        let centerY = height / 2

        // 收藏星在 40pt 槽里居中（槽宽使小封面左沿与上方 270 大封面左沿齐平）
        favoriteButton?.frame = NSRect(x: body.minX + (M.playlistFavoriteAreaWidth - M.favoriteWidth) / 2,
                                       y: 0, width: M.favoriteWidth, height: height)

        let columnsX = body.minX + M.playlistFavoriteAreaWidth
        let fixedRight = M.addWidth + M.playlistDurationWidth + M.playlistMoreWidth
        let columnWidth = ((body.maxX - columnsX - fixedRight) / 3).rounded(.toNearestOrEven)

        artworkButton?.frame = NSRect(x: columnsX,
                                      y: ((height - M.artworkSize) / 2).rounded(.toNearestOrEven),
                                      width: M.artworkSize, height: M.artworkSize)

        var titleLeading = columnsX + M.artworkSize
        if configuration.isChart, let rankLabel {
            // 名次排在封面右边一条 16pt 窄列，字号字重与曲名同级
            TrackRowKit.layout(rankLabel, inkLeading: titleLeading + M.chartRankGap,
                               width: M.chartRankWidth, centerY: centerY)
            titleLeading += M.chartRankGap * 2 + M.chartRankWidth
        } else {
            titleLeading += M.contentSpacing
        }
        if let titleLabel {
            TrackRowKit.layout(titleLabel, inkLeading: titleLeading,
                               width: max(0, columnsX + columnWidth - 10 - titleLeading),
                               centerY: centerY)
        }

        artistLink?.frame = NSRect(x: columnsX + columnWidth, y: 0,
                                   width: max(0, columnWidth - 10), height: height)
        albumLink?.frame = NSRect(x: columnsX + columnWidth * 2, y: 0,
                                  width: columnWidth, height: height)

        let addX = body.maxX - M.playlistMoreWidth - M.playlistDurationWidth - M.addWidth
        addButton?.frame = NSRect(x: addX, y: 0, width: M.addWidth, height: height)
        if let durationLabel {
            TrackRowKit.layout(durationLabel, inkTrailing: body.maxX - M.playlistMoreWidth,
                               width: M.playlistDurationWidth, centerY: centerY)
        }
        layoutMoreButton(slotWidth: M.playlistMoreWidth, trailing: body.maxX, centerY: centerY)
    }

    /// ••• 的字形占 `slotWidth` 的槽，命中区是 28×28（[实测]
    /// `EllipsisButton.intrinsicContentSize` → 28），在槽里居中。
    private func layoutMoreButton(slotWidth: CGFloat, trailing: CGFloat, centerY: CGFloat) {
        guard let moreButton else { return }
        let center = trailing - slotWidth / 2
        moreButton.frame = NSRect(x: (center - M.moreButtonSize / 2).rounded(.toNearestOrEven),
                                  y: (centerY - M.moreButtonSize / 2).rounded(.toNearestOrEven),
                                  width: M.moreButtonSize, height: M.moreButtonSize)
    }

    // MARK: - 绘制

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovering, !isSelected else { return }
        fillBody(NSColor.labelColor.withAlphaComponent(M.hoverOpacity))
    }

    /// 选中底色自己画：白 10.5% 圆角 6 的行体，不是系统强调色条
    /// （表格把 `selectionHighlightStyle` 设成`.regular`，这里整块覆盖掉）。
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillBody(NSColor.labelColor.withAlphaComponent(M.selectedOpacity))
    }

    private func fillBody(_ color: NSColor) {
        let rect = bodyRect
        guard rect.width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: M.hoverCornerRadius,
                     yRadius: M.hoverCornerRadius).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 分隔线画在行内最底一线（表格里行 pitch 必须等于行高），末行不画。
        guard configuration?.showsDivider == true else { return }
        let left = dividerLeading
        let right = bodyRect.maxX
        guard right > left else { return }
        NSColor.amberLabelDivider.setFill()
        NSRect(x: left, y: bounds.maxY - 1, width: right - left, height: 1).fill()
    }

    // MARK: - 悬浮

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
        // 复用一行、或滚动把新行送到光标底下时都不会再来一次 `mouseEntered`
        // （光标没动过），跟歌曲表「进来第一下不显形」是同一个坑，这里现场问一次位置。
        syncHoverFromMouse()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }

    private func syncHoverFromMouse() {
        guard NSApp.isActive, let window = amberWindow, window.isVisible else {
            hovering = false
            return
        }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovering = bounds.contains(local) && visibleRect.contains(local)
    }

    // MARK: - 点击

    /// 单击（选中）照旧交给表格；只截双击。第一次 `mouseDown` 已经把行选上了，
    /// 第二次带 `clickCount == 2` 到这里就直接播——不往下传，表格的`doubleAction`
    /// 也就不会再触发一次（不会播两遍）。
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2, configuration != nil else {
            super.mouseDown(with: event)
            return
        }
        play()
    }

    /// 表格若自己设了 `doubleAction`，落到这一行时调它也行（与双击同义）。
    func playFromRow() { play() }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    override func accessibilityPerformPress() -> Bool {
        play()
        return true
    }

    private func play() {
        guard let appState, let configuration else { return }
        if isCurrent {
            appState.player.togglePlayPause()
        } else {
            appState.player.play(configuration.playContext.tracks,
                                 startAt: configuration.playContext.index)
        }
    }

    /// 已入库时这枚键跟着这一首的下载态走（↓ / ⏹ / ✓），与专辑页头同一套词汇。
    private func toggleLibrary() {
        guard let appState, let track = configuration?.track else { return }
        let action = appState.downloads.action(inLibrary: isInLibrary, tracks: [track])
        if action == .addToLibrary {
            appState.library.addToLibrary(track)
            appState.showToast("已添加到资料库")
        } else if action == .done {
            // 点已下载那枚图标＝删掉本地那份，先问一句（`DownloadRemovalAlert`）
            DownloadRemovalAlert.confirm(count: 1, in: amberWindow) { [weak self] in
                appState.downloads.removeDownload([track])
                self?.refreshLibraryState()
            }
            return
        } else {
            appState.downloads.perform(action, tracks: [track])
        }
        refreshLibraryState()
    }

    private func showMenu() {
        guard let moreButton, let menu = makeMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    // MARK: - 菜单

    private var tableView: NSTableView? {
        var view: NSView? = amberSuperview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.amberSuperview
        }
        return nil
    }

    /// 菜单归表格造（`TrackRowMenuProviding`）：作用集与「右键先预选」是页面级事实，
    /// 行只把事件转上去。表格不认这条协议时才退回只算本行——那是给契约里
    /// 自带 `remove` 的调用点留的兜底，两条路不会同时生效。
    private func makeMenu() -> NSMenu? {
        if let table = tableView as? any TrackRowMenuProviding, let row = tableView?.row(for: self),
           row >= 0 {
            return table.trackRowMenu(forRow: row)
        }
        guard let appState, let configuration else { return nil }
        return TrackRowRegistry.menu(for: [configuration.track],
                                     playContext: configuration.playContext,
                                     removeTitle: configuration.removeTitle,
                                     remove: configuration.remove,
                                     appState: appState)
    }
}

// MARK: - 歌单列头

/// 歌单形态那条 32pt 的列头「歌曲 / 艺人 / 专辑 / 时长」（`TrackList.PlaylistTrackHeader`
/// 的 AppKit 版）：列宽算法与歌单行逐字一致，前三列之间各有一条 12pt 高的竖线。
final class TrackPlaylistHeaderView: NSView {

    private typealias M = MusicMetrics.TrackRow

    /// 与行同一条：页面左右留白由自己让。歌单形态默认 0（旧版 `TrackList` 就摆在
    /// 页面内缩之外），目录里那张内缩过 40 的网格页在建表时改掉。
    var contentInset: CGFloat = 0 {
        didSet {
            guard contentInset != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }

    private let songLabel = TrackRowKit.label(size: 12, color: .secondaryLabelColor)
    private let artistLabel = TrackRowKit.label(size: 12, color: .secondaryLabelColor)
    private let albumLabel = TrackRowKit.label(size: 12, color: .secondaryLabelColor)
    private let durationLabel = TrackRowKit.label(size: 12, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        songLabel.stringValue = "歌曲"
        artistLabel.stringValue = "艺人"
        albumLabel.stringValue = "专辑"
        durationLabel.stringValue = "时长"
        durationLabel.alignment = .right
        for label in [songLabel, artistLabel, albumLabel, durationLabel] { addSubview(label) }
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let left = contentInset + M.playlistFavoriteAreaWidth
        let right = bounds.width - contentInset
        let fixedRight = M.addWidth + M.playlistDurationWidth + M.playlistMoreWidth
        let columnWidth = ((right - left - fixedRight) / 3).rounded(.toNearestOrEven)
        let centerY = bounds.height / 2
        TrackRowKit.layout(songLabel, inkLeading: left, width: columnWidth, centerY: centerY)
        TrackRowKit.layout(artistLabel, inkLeading: left + columnWidth, width: columnWidth,
                           centerY: centerY)
        TrackRowKit.layout(albumLabel, inkLeading: left + columnWidth * 2, width: columnWidth,
                           centerY: centerY)
        TrackRowKit.layout(durationLabel, inkTrailing: right - M.playlistMoreWidth,
                           width: M.playlistDurationWidth, centerY: centerY)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let left = contentInset + M.playlistFavoriteAreaWidth
        let right = bounds.width - contentInset
        let fixedRight = M.addWidth + M.playlistDurationWidth + M.playlistMoreWidth
        let columnWidth = ((right - left - fixedRight) / 3).rounded(.toNearestOrEven)
        NSColor.amberLabelDivider.setFill()
        // 前两列右端各一条 12pt 高的竖线（列末再内缩 10），底下一条通宽的分隔线。
        for column in 0..<2 {
            let x = left + columnWidth * CGFloat(column + 1) - 11
            NSRect(x: x, y: (bounds.height - 12) / 2, width: 1, height: 12).fill()
        }
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
