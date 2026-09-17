import AppKit
import SwiftUI

// MARK: - 资料库网格卡（AppKit）—— 阶段 5 批 A

// 专辑页 / 最近添加 / 所有播放列表三页的网格 cell 一律走这一套。
// 零件全部复用阶段 3 批 B 做好的目录页卡片件：封面 `CatalogArtworkView`
// （贴图、渐变占位、悬浮暗罩、圆角都在它那层）、悬浮播放键 `CatalogPlayButton`、
// 标签 `CatalogCardKit.label`（不吃点击的`NSTextField`）。
//
// 这里只把 `LibraryGridCard`（SwiftUI）的排版原样搬过来（计划 §2 铁律 5「换骨架，
// 像素一个不改」）：封面 = 列宽的正方形，下面是定高 46 的两行文字块（左 12 右 10），
// 底垫 10。数字见 `MusicMetrics.LibraryGrid` / `MusicMetrics.Card`，出处标在那边。
// 悬浮态由卡片自己持有（铁律 3），右键菜单是卡片自己的 `NSMenu`（铁律 4）。

// MARK: - 列宽换算

/// 资料库网格页（专辑 / 最近添加 / 所有播放列表）共用的列宽换算与重排。
@MainActor
enum LibraryGridSizing {
    /// 内容列宽还没定（`loadView` 时 bounds 仍是 0）时的占位尺寸，
    /// 等 `viewDidLayout` 拿到真实宽再重算。
    /// 0 宽就灌数据会让流式布局把每格算成 0 宽，几秒吃掉几十 GB（实测）。
    static let placeholder = NSSize(width: 220,
                                    height: MusicMetrics.LibraryGrid.cellHeight(itemWidth: 220))

    static func itemSize(in collectionView: NSCollectionView) -> NSSize {
        MusicMetrics.LibraryGrid.itemSize(containerWidth: collectionView.bounds.width) ?? placeholder
    }

    /// 列宽变了（改窗口宽、开合侧栏）：重算布局，并把在屏卡片的封面按新列宽重新请求一档
    /// （`ArtworkSize` 的阶梯写在请求地址里，卡片的 frame 由`layout()` 自己跟）。
    static func reflow(_ collectionView: NSCollectionView?, lastWidth: inout CGFloat) {
        guard let collectionView else { return }
        let width = itemSize(in: collectionView).width
        guard width != lastWidth else { return }
        lastWidth = width
        collectionView.collectionViewLayout?.invalidateLayout()
        for case let item as LibraryGridItemSizing in collectionView.visibleItems() {
            item.update(width: width)
        }
    }
}

/// 能跟着列宽换封面档位的网格 item。
@MainActor
protocol LibraryGridItemSizing: NSCollectionViewItem {
    func update(width: CGFloat)
}

// MARK: - 收悬浮的 collection view

/// 资料库网格页的 collection view：卡片的悬浮态由它按 hitTest 分发。
///
/// 与目录页同一条理由（见 `CatalogHoverTarget`）：滚轮滚动不产生`mouseMoved`，
/// 每张卡各挂 tracking area 的话，滚过去之后高亮会留在滚走的那张卡上。
/// 这里在滚动视图的 bounds 变化时也重算一次，悬浮态跟着鼠标底下那张走。
@MainActor
final class LibraryGridCollectionView: NSCollectionView {

    private weak var hoveredCard: LibraryGridCardView?
    private var hoverArea: NSTrackingArea?
    private var boundsObserver: NSObjectProtocol?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        clearHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        // 块式观察者的闭包是 `@Sendable`；`queue: .main` 已经把投递线程钉死在主线程，
        // 所以用 `assumeIsolated` 接回主线程隔离的自己。
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshHover() } }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // 鼠标还在可视区里（压在卡片或播放键上）就不算真的退出。
        guard !visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        clearHover()
    }

    /// 页面被切走时导航容器只把视图 `isHidden` 掉，不会再来 exited；由页面调这一下。
    func clearHover() {
        setHoveredCard(nil)
    }

    private func refreshHover() {
        guard let window, window.isKeyWindow else { clearHover(); return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// `point` 是本视图（文稿）坐标。
    private func updateHover(at point: NSPoint) {
        guard let superview, visibleRect.contains(point) else { clearHover(); return }
        var hit = hitTest(convert(point, to: superview))
        var target: LibraryGridCardView?
        while let view = hit, view !== self {
            if let card = view as? LibraryGridCardView { target = card; break }
            hit = view.superview
        }
        setHoveredCard(target)
    }

    /// **判据不能只是「还是不是同一个对象」。** 卡片自己那一位`isHovering` 会在
    /// `prepareForReuse` 里被清成 false，而`reloadData()` 正是让在屏 item 全走一遍
    /// `prepareForReuse`——重载之后`hoveredCard` 仍指着同一个对象，只按对象相等短路的话
    /// 这一下就再也发不出去：光标停在一张卡上，此时一个下载完成或别处点了个喜爱，
    /// 这张卡的暗罩和悬浮播放键当场消失、鼠标不动就回不来，播放键也点不到
    /// （design-ref/reactive-ui-review.md 故障 10 前半）。
    /// 所以再加一条「卡自己记的那一位与期望不一致也重新下发」。
    private func setHoveredCard(_ card: LibraryGridCardView?) {
        if card === hoveredCard, card?.isHovering ?? true { return }
        hoveredCard?.setHovering(false)
        hoveredCard = card
        card?.setHovering(true)
    }

    /// 每轮布局落定之后按鼠标现在压在哪儿重判一次。
    ///
    /// 挂在 `layout()` 而不是各页重载完各调一次：`reloadData()` 会把在屏 item 全丢回
    /// 复用队列，同一个卡视图很可能被换去装另一张碟——那时「悬浮的是哪张卡」已经变了，
    /// 而鼠标一动不动，不会再来 `mouseMoved`。列宽变了（改窗宽、开合侧栏）也是同一回事。
    /// 这里做一次 hitTest 就全覆盖了，各页也不用各记一次；且必须在`super.layout()`
    /// 之后——卡片的 frame 是那一句才落定的。
    override func layout() {
        super.layout()
        refreshHover()
    }
}

// MARK: - 卡片

/// 卡片上的装饰图（喜爱的红 ★、心水卡的大星）：不吃点击，
/// 整卡的命中分派照常走（同 `CatalogLabel`）。
final class LibraryCardImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 资料库网格卡的共同外形：封面（列宽的正方形）+ 定高 46 的两行文字块。
///
/// 对应 SwiftUI 的 `LibraryGridCard`。可点区域只有封面——旧版里
/// `NavigationLink` 也只包着封面那一块，文字块不是链接。
@MainActor
class LibraryGridCardView: NSView, CatalogHoverTarget {

    fileprivate typealias M = MusicMetrics.LibraryGrid

    let artworkView = CatalogArtworkView()
    /// 资料库这三张卡的播放键是 15pt 字形、不带投影（`CardPlayButton` 的默认档；
    /// 目录页那批才是 14pt + 投影）。
    let playButton = CatalogPlayButton(iconSize: 15, hasShadow: false)
    // 标题与副标题都是 13pt——正好是 `NSFont.systemFontSize`，所以直接取系统默认值，
    // 不在 `MusicMetrics` 里另立一条常量（计划 §2 铁律 6 第一问）。
    let titleField = CatalogCardKit.label(size: NSFont.systemFontSize, lines: 2)
    let subtitleField = CatalogCardKit.label(size: NSFont.systemFontSize,
                                             color: .secondaryLabelColor)

    private(set) weak var appState: AppState?
    private(set) var isHovering = false
    /// 建卡时的列宽，只用来决定封面请求哪一档（`ArtworkSize` 的阶梯）。
    private(set) var artworkWidth: CGFloat = 0

    /// 文字块顶到标题的额外留白（心水卡的标题多 4）。
    var titleTopPadding: CGFloat = 0
    /// 标题与副标题的行距。
    var textSpacing: CGFloat = MusicMetrics.Card.textSpacing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addSubview(artworkView)
        playButton.onClick = { [weak self] in self?.play() }
        artworkView.addSubview(playButton)
        addSubview(titleField)
        addSubview(subtitleField)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 子类接口

    /// 子类在这里补自己的子视图。
    func build() {}
    /// 点封面的落点。
    var route: Route? { nil }
    /// 悬浮播放键与右键「播放」的动作。
    func play() {}
    /// 摆不摆悬浮播放键（旧版是把 `play` 传成 nil：心水歌曲一首都没有时就不摆）。
    var hasPlayButton: Bool { true }
    /// 右键菜单。
    func makeCardMenu() -> NSMenu? { nil }
    /// 标题行右侧挂的东西占多宽（喜爱 ★）。
    var titleTrailingWidth: CGFloat { 0 }
    /// 子类在这里摆自己挂在标题右侧的东西（`titleTop` 是标题框顶）。
    func layoutTitleAccessory(x: CGFloat, titleTop: CGFloat) {}

    // MARK: 装配

    /// `width` 取网格算好的列宽，不读`view.bounds`：取出复用格时 item 的 frame 还没设，
    /// 读到的是 0 或上一轮的宽，封面就会按错的档位去请求。
    func configureCommon(appState: AppState, width: CGFloat) {
        self.appState = appState
        artworkWidth = width
        setAccessibilityLabel(titleField.stringValue)
        needsLayout = true
    }

    /// 列宽变了：封面换一档重新请求。子类重写去调自己那句 `setArtwork`。
    func updateArtworkWidth(_ width: CGFloat) {
        guard width > 0, width != artworkWidth else { return }
        artworkWidth = width
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if isHovering {
            isHovering = false
            hoverDidChange(false, animated: false)
        }
        appState = nil
        artworkView.prepareForReuse()
        playButton.setVisible(false, animated: false)
    }

    // MARK: 悬浮（由 `LibraryGridCollectionView` 按 hitTest 分发）

    final func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverDidChange(hovering, animated: true)
    }

    func hoverDidChange(_ hovering: Bool, animated: Bool) {
        artworkView.setHovering(hovering, animated: animated)
        playButton.setVisible(hovering && hasPlayButton, animated: animated)
    }

    // MARK: 点击与菜单

    override func mouseDown(with event: NSEvent) {}

    /// 与 SwiftUI 的 `Button` 同：按下不触发，抬手仍在盒内才算一次点击。
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        handleClick(at: point)
    }

    /// 旧版只有封面是 `NavigationLink`，文字块不是。
    func handleClick(at point: NSPoint) {
        guard artworkView.frame.contains(point), let route else { return }
        appState?.push(route)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeCardMenu() }

    override func accessibilityPerformPress() -> Bool {
        guard let route else { return false }
        appState?.push(route)
        return true
    }

    // MARK: 排版

    override func layout() {
        super.layout()
        let side = bounds.width
        artworkView.frame = NSRect(x: 0, y: bounds.height - side, width: side, height: side)
        playButton.frame = NSRect(x: side - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)
        layoutTextBlock(top: artworkView.frame.minY)
    }

    /// 文字块：左 12 右 10（[实测] `AMPGridCollectionViewItem` 的 label 布局常量），
    /// 顶紧贴封面底（[AX] 封面底 344 = 文字块顶 344，零间距），
    /// 标题最多两行、副标题一行，行距 `Card.textSpacing`。
    private func layoutTextBlock(top: CGFloat) {
        let inset = CatalogCardKit.labelInset
        let available = max(0, bounds.width - M.labelLeading - M.labelTrailing)
        let titleBox = max(0, available - titleTrailingWidth)
        // 标题一行放得下就按字宽收窄（★ 要紧跟在字后面）；放不下就占满、由它自己折成两行。
        // 字宽向上取整：正好等于字宽的框会因为排版器那半个点的差额把一行挤成两行。
        let titleWidth = min(ceil(CatalogCardKit.textWidth(titleField)), titleBox)
        let titleHeight = titleField.sizeThatFits(
            NSSize(width: titleWidth + inset * 2, height: .greatestFiniteMagnitude)).height
        let titleTop = top - titleTopPadding
        titleField.frame = NSRect(x: M.labelLeading - inset, y: titleTop - titleHeight,
                                  width: titleWidth + inset * 2, height: titleHeight)
        layoutTitleAccessory(x: M.labelLeading + titleWidth, titleTop: titleTop)

        guard !subtitleField.isHidden else { return }
        let height = CatalogCardKit.lineHeight(subtitleField)
        subtitleField.frame = NSRect(x: M.labelLeading - inset,
                                     y: titleTop - titleHeight - textSpacing - height,
                                     width: available + inset * 2, height: height)
    }
}

// MARK: - 专辑卡

/// 资料库网格的专辑 cell（Music `AlbumCollectionItemLockup` / `AMPGridCollectionViewItem`）。
/// 已喜爱的专辑在标题后挂红 ★（AX 里是标题文本内联的附件；旧 SwiftUI 版用行排，
/// ★ 与标题顶对齐再下移 1.5，这里照搬）。
@MainActor
final class LibraryAlbumCardView: LibraryGridCardView {

    private let starView = LibraryCardImageView()
    private var album: Album?
    private var library: LibraryStore? { appState?.library }

    override func build() {
        starView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "已喜爱")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        starView.contentTintColor = NSColor(Color.amberKey)
        starView.imageScaling = .scaleNone
        starView.isHidden = true
        addSubview(starView)
    }

    func configure(album: Album, width: CGFloat, appState: AppState) {
        self.album = album
        titleField.stringValue = album.name
        subtitleField.stringValue = album.artistName
        subtitleField.isHidden = false
        starView.isHidden = !appState.library.isFavoriteAlbum(album)
        configureCommon(appState: appState, width: width)
        artworkView.setArtwork(url: album.artworkURL, points: width)
    }

    override func updateArtworkWidth(_ width: CGFloat) {
        super.updateArtworkWidth(width)
        guard let album else { return }
        artworkView.setArtwork(url: album.artworkURL, points: artworkWidth)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        album = nil
        starView.isHidden = true
    }

    override var route: Route? { album.map { .album($0) } }

    override func play() {
        guard let album, let appState else { return }
        Task { await appState.playAlbum(album) }
    }

    /// 用字形自己的尺寸，别用 `intrinsicContentSize`：11pt star.fill 的字形是 15×14。
    override var titleTrailingWidth: CGFloat {
        starView.isHidden ? 0 : (starView.image?.size.width ?? 0) + 3
    }

    override func layoutTitleAccessory(x: CGFloat, titleTop: CGFloat) {
        guard !starView.isHidden, let size = starView.image?.size else { return }
        // 旧版是 `HStack(alignment: .top, spacing: 3)` + `.padding(.top, 1.5)`。
        starView.frame = NSRect(x: x + 3, y: titleTop - 1.5 - size.height,
                                width: size.width, height: size.height)
    }

    // MARK: 右键菜单

    /// 项序走 `CollectionActions`：这里只报「这张碟能做什么」。
    ///
    /// 旧版这份手拼的菜单只有播放 / 喜爱 / 从资料库中删除——**漏了「下载 / 移除下载」**
    /// （专辑页头同样漏了，资料库艺人页那颗 ••• 却有，是抄漏不是有意）。
    /// Music 的这两条只对已在资料库里的对象出现（`doDownloadCloudTrackSelection:`
    /// 的 validateMenuItem: 就这么摘的，见 `DownloadStore` 头注）。
    override func makeCardMenu() -> NSMenu? {
        guard let album, let library, let appState else { return nil }
        var actions = CollectionActions()
        actions.play = { [weak self] in self?.play() }
        actions.shareURL = album.webShareURL
        // 点封面本来就进专辑页，但目录侧的专辑卡菜单里一直有这一条——
        // 六处卡片的项集要一致，缺它才是从前那种「看着像抄漏」的差异。
        if let route { actions.goTo = ("前往专辑", { appState.push(route) }) }

        if library.isFavoriteAlbum(album) {
            actions.undoFavorite = { library.toggleFavoriteAlbum(album) }
        } else {
            actions.favorite = { library.toggleFavoriteAlbum(album) }
        }

        let tracks = library.tracks(in: album)
        if library.isAlbumInLibrary(album) {
            // 整张碟删掉之前也要问一句「文件去哪」（spec §10.2）：本地导入的碟就摆在这一页里，
            // 一张碟几十个文件，静默删掉是不可逆的。碟里没有媒体文件夹里的文件时
            // `askFileDisposition` 自己就直通了，不会白弹一张。
            actions.deleteFromLibrary = {
                LibraryDeleteAlert.askFileDisposition(tracks: tracks, appState: appState) {
                    library.removeAlbumFromLibrary(album, tracks: tracks)
                }
            }
            let downloads = appState.downloads
            if !tracks.isEmpty {
                if tracks.allSatisfy({ downloads.isDownloaded($0.id) }) {
                    actions.removeDownload = { downloads.removeDownload(tracks) }
                } else {
                    actions.download = { downloads.download(tracks) }
                }
            }
        }
        return actions.makeMenu()
    }
}

// MARK: - 播放列表卡

/// 「所有播放列表」网格里的一张卡，形态与专辑卡一致（封面 + 两行文字）。
/// 右键菜单的项目与 `LibraryPlaylistMenu`（侧栏行与详情页头仍在用那份 SwiftUI 菜单）一致。
@MainActor
final class LibraryPlaylistCardView: LibraryGridCardView {

    private var playlist: LibraryPlaylist?

    func configure(playlist: LibraryPlaylist, width: CGFloat, appState: AppState) {
        self.playlist = playlist
        titleField.stringValue = playlist.name
        subtitleField.stringValue = playlist.subtitle
        subtitleField.isHidden = false
        configureCommon(appState: appState, width: width)
        artworkView.setArtwork(url: playlist.artworkURL, points: width)
    }

    override func updateArtworkWidth(_ width: CGFloat) {
        super.updateArtworkWidth(width)
        guard let playlist else { return }
        artworkView.setArtwork(url: playlist.artworkURL, points: artworkWidth)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playlist = nil
    }

    override var route: Route? { playlist.map { .libraryPlaylist(id: $0.id) } }

    override func play() {
        guard let playlist, let appState else { return }
        Task { await appState.playLibraryPlaylist(playlist) }
    }

    /// 项序走 `CollectionActions`；项集与`LibraryPlaylistMenu`（侧栏行与详情页头共用的
    /// 那份 SwiftUI 菜单）一致。
    override func makeCardMenu() -> NSMenu? {
        guard let playlist, let appState else { return nil }
        var actions = CollectionActions()
        actions.play = { [weak self] in self?.play() }
        actions.shuffle = { Task { await appState.playLibraryPlaylist(playlist, shuffled: true) } }
        // 自己在 Amber 里建的列表只在本机，没有可分享的页面（`LibraryPlaylist.webShareURL` 给 nil）。
        actions.shareURL = playlist.webShareURL
        if let route { actions.goTo = ("前往歌单", { appState.push(route) }) }

        if playlist.isEditable {
            // 改名弹窗由 `RootViewController` 统一挂着：菜单一关这张卡还在，
            // 但弹窗本来就不该长在菜单里（与 `LibraryPlaylistMenu` 同一条）。
            actions.rename = { appState.playlistNamePrompt = .rename(playlistID: playlist.id) }
        }
        if playlist.origin == .account {
            actions.syncAccount = { Task { await appState.syncAccountPlaylists(manual: true) } }
        }
        actions.deleteFromLibrary = {
            if appState.sidebarSelection == .playlist(id: playlist.id) {
                appState.sidebarSelection = .allPlaylists
            }
            appState.library.deletePlaylist(id: playlist.id)
        }
        return actions.makeMenu()
    }
}

// MARK: - 心水歌曲卡

/// 「心水歌曲」专属卡：浅底渐变 + 居中大红星，下面同样是两行文字
/// （标题多 4 的上留白、行距 2，与旧 SwiftUI 版 `FavoritesPlaylistCard` 一致）。
@MainActor
final class LibraryFavoritesCardView: LibraryGridCardView {

    private let starView = LibraryCardImageView()
    private var trackCount = 0

    override func build() {
        // 旧版：`Color.primary.opacity(0.08)` → `0.04`，左上到右下。
        artworkView.hoverScrimOpacity = 0.12
        starView.contentTintColor = NSColor(Color.amberKey)
        starView.imageScaling = .scaleNone
        starView.wantsLayer = true
        starView.layer?.masksToBounds = false
        starView.layer?.shadowColor = NSColor(Color.amberKey).cgColor
        starView.layer?.shadowOpacity = 0.3
        starView.layer?.shadowRadius = 8
        starView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        artworkView.addSubview(starView, positioned: .below, relativeTo: playButton)
        titleTopPadding = 4
        textSpacing = 2
    }

    func configure(favoriteCount: Int, width: CGFloat, appState: AppState) {
        trackCount = favoriteCount
        titleField.stringValue = "心水歌曲"
        subtitleField.stringValue = "\(favoriteCount) 首歌曲"
        subtitleField.isHidden = false
        configureCommon(appState: appState, width: width)
        applyPlaceholder()
    }

    override func updateArtworkWidth(_ width: CGFloat) {
        super.updateArtworkWidth(width)
        applyPlaceholder()
    }

    /// 渐变底色是 `labelColor` 派生的动态色，`cgColor` 只在当前 appearance 下解析一次，
    /// 所以浅深切换时要重来一遍。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPlaceholder()
    }

    private func applyPlaceholder() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            artworkView.setArtwork(url: nil, points: nil,
                                   fallbackColors: [Color(nsColor: .labelColor).opacity(0.08),
                                                    Color(nsColor: .labelColor).opacity(0.04)],
                                   brandGlyphSize: nil, loadingGlyphSize: nil)
        }
        // 星形字号跟着卡片宽走（旧版 `max(32, width * 0.28)`）。
        starView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: max(32, artworkWidth * 0.28),
                                           weight: .regular))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let size = starView.image?.size else { return }
        starView.frame = NSRect(x: (artworkView.bounds.width - size.width) / 2,
                                y: (artworkView.bounds.height - size.height) / 2,
                                width: size.width, height: size.height)
    }

    override var route: Route? {
        guard let appState else { return nil }
        return .localTracks(LocalTrackList(id: "favorites", title: "心水歌曲",
                                           tracks: appState.library.favoriteTracks))
    }

    /// 一首都没有时不摆播放键（旧版把 `play` 传成 nil）。
    override var hasPlayButton: Bool { trackCount > 0 }

    override func play() {
        guard let appState else { return }
        appState.player.play(appState.library.favoriteTracks, source: favoritesQueueSource)
    }

    /// 队列面板「继续播放」分区头的「来自《…》」＝心水歌曲那一页（与 `route` 同一个落点）。
    private var favoritesQueueSource: PlayerController.QueueSource? {
        guard let appState else { return nil }
        return .init(title: "心水歌曲",
                     route: .localTracks(LocalTrackList(
                        id: "favorites", title: "心水歌曲",
                        tracks: appState.library.favoriteTracks)))
    }

    /// 项序走 `CollectionActions`。心水歌曲是一份虚拟列表：既不能入库也不能删，
    /// 能做的只有播放与随机播放。
    override func makeCardMenu() -> NSMenu? {
        guard let appState else { return nil }
        var actions = CollectionActions()
        actions.play = { [weak self] in self?.play() }
        actions.shuffle = { [weak self] in
            appState.player.play(appState.library.favoriteTracks.shuffled(),
                                 source: self?.favoritesQueueSource)
        }
        return actions.makeMenu()
    }
}

// MARK: - NSCollectionViewItem 外壳

/// 专辑网格与「最近添加」共用这一个 item。
@MainActor
final class LibraryAlbumCollectionItem: NSCollectionViewItem, LibraryGridItemSizing {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryAlbumCollectionItem")

    private let card = LibraryAlbumCardView()

    override func loadView() { view = card }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.prepareForReuse()
    }

    func configure(album: Album, width: CGFloat, appState: AppState) {
        card.configure(album: album, width: width, appState: appState)
    }

    func update(width: CGFloat) { card.updateArtworkWidth(width) }
}

@MainActor
final class LibraryPlaylistCollectionItem: NSCollectionViewItem, LibraryGridItemSizing {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryPlaylistCollectionItem")

    private let card = LibraryPlaylistCardView()

    override func loadView() { view = card }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.prepareForReuse()
    }

    func configure(playlist: LibraryPlaylist, width: CGFloat, appState: AppState) {
        card.configure(playlist: playlist, width: width, appState: appState)
    }

    func update(width: CGFloat) { card.updateArtworkWidth(width) }
}

@MainActor
final class LibraryFavoritesCollectionItem: NSCollectionViewItem, LibraryGridItemSizing {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryFavoritesCollectionItem")

    private let card = LibraryFavoritesCardView()

    override func loadView() { view = card }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.prepareForReuse()
    }

    func configure(favoriteCount: Int, width: CGFloat, appState: AppState) {
        card.configure(favoriteCount: favoriteCount, width: width, appState: appState)
    }

    func update(width: CGFloat) { card.updateArtworkWidth(width) }
}
