import AppKit
import SwiftUI

// MARK: - 铺满内容列的卡（大横幅 / 链接格）、节目宽卡与多列曲目行

// MARK: 大横幅（super-hero-lockup）

/// 主页「推荐歌单」的整宽卡：一张图铺满内容列，**一句描述居中压在图底**，段里只有一张。
/// 圆角 14；描述 15/400 纯白、宽 60%、居中、距图底 21；可读性渐变高 175；
/// 悬停时整图罩 `rgba(51,51,51,.3)`，播放键在**左下角**内缩 10
/// （别的卡在右下，super-hero 的 CSS 就是 `inset-inline-start:10px`）。
final class CatalogBannerCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let artworkView = CatalogArtworkView()
    private let captionField = CatalogCardKit.label(size: M.bannerDescSize, color: .white, lines: 2)
    private let playButton = CatalogPlayButton()

    override func build() {
        artworkView.cornerRadius = M.bannerCornerRadius
        artworkView.hoverScrimColor = NSColor(white: 0.2, alpha: 1)
        artworkView.hoverScrimOpacity = Float(M.bannerHoverScrim)
        artworkView.legibilityHeight = M.bannerScrimHeight
        addSubview(artworkView)

        captionField.alignment = .center
        CatalogCardKit.applyArtworkShadow(captionField, blur: 5, dy: 2)
        artworkView.addSubview(captionField)

        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)
    }

    override func apply(_ item: CatalogItem) {
        // 音源的歌单没有描述时退回歌单名，别让整张大横幅上没有字。
        let description = item.description?.isEmpty == false ? item.description! : item.title
        captionField.stringValue = description
        artworkView.setArtwork(url: item.artworkURL, points: 600,
                               fallbackColors: item.fallbackColors)
        playButton.setVisible(false, animated: false)
    }

    override func hoverDidChange(_ hovering: Bool, animated: Bool) {
        artworkView.setHovering(hovering, animated: animated)
        playButton.setVisible(hovering && item?.onPlay != nil, animated: animated)
    }

    override func resetContent() {
        artworkView.prepareForReuse()
        playButton.setVisible(false, animated: false)
    }

    override func layout() {
        super.layout()
        artworkView.frame = bounds

        let captionWidth = bounds.width * M.bannerDescWidthRatio
        let height = captionField.sizeThatFits(NSSize(width: captionWidth,
                                                      height: .greatestFiniteMagnitude)).height
        captionField.frame = NSRect(x: (bounds.width - captionWidth) / 2,
                                    y: M.bannerDescBottomInset,
                                    width: captionWidth, height: height)

        // 播放键在左下角：SwiftUI 版是给 `CardPlayButton`（自带 8 内缩）再加 10−8=2 的外缩。
        playButton.frame = NSRect(x: M.bannerControlInset, y: M.bannerControlInset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)
    }
}

// MARK: 节目宽卡（horizontal-lockup）

/// 「最新电台节目」宽卡 [AX] 381×118：方图 94 贴左（上下各留 12，圆角 5），
/// 标题 15/400 垂直居中（最多两行），右侧 •••。
final class CatalogEpisodeCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    /// 卡右沿到 ••• 右沿的距离（SwiftUI 版 `.padding(.trailing, 14)`）
    private static let trailingInset: CGFloat = 14
    private static let moreSize = NSSize(width: 24, height: 28)
    private static let gap: CGFloat = 12

    private let artworkView = CatalogArtworkView()
    private let titleField = CatalogCardKit.label(size: M.episodeTitleSize, lines: 2)
    private let moreButton = CatalogMoreButton()

    override func build() {
        artworkView.cornerRadius = M.episodeCornerRadius
        addSubview(artworkView)
        addSubview(titleField)
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        addSubview(moreButton)
    }

    override func apply(_ item: CatalogItem) {
        artworkView.setArtwork(url: item.artworkURL, points: 100,
                               fallbackColors: item.fallbackColors)
        titleField.stringValue = item.title
        moreButton.setHovering(false)
    }

    override func hoverDidChange(_ hovering: Bool, animated: Bool) {
        moreButton.setHovering(hovering)
    }

    override func resetContent() {
        artworkView.prepareForReuse()
        moreButton.setHovering(false)
    }

    override func layout() {
        super.layout()
        let size = M.episodeArtworkSize
        artworkView.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)

        let moreX = bounds.width - Self.trailingInset - Self.moreSize.width
        moreButton.frame = NSRect(x: moreX, y: (bounds.height - Self.moreSize.height) / 2,
                                  width: Self.moreSize.width, height: Self.moreSize.height)

        // HStack(spacing: 12)：图 | 12 | 标题 | 12 | Spacer(min 8) | 12 | •••
        let titleX = size + Self.gap
        let titleWidth = max(0, moreX - Self.gap - 8 - titleX)
        let titleHeight = titleField.sizeThatFits(NSSize(width: titleWidth,
                                                         height: .greatestFiniteMagnitude)).height
        titleField.frame = NSRect(x: titleX - CatalogCardKit.labelInset,
                                  y: (bounds.height - titleHeight) / 2,
                                  width: titleWidth + CatalogCardKit.labelInset * 2,
                                  height: titleHeight)
    }

    /// ••• 与右键弹的是同一份（基类的 `makeTrackMenu`）：有曲目上下文走
    /// `TrackActions.catalogRow`，没有的走`CollectionActions`。
    /// 从前这里另手写了一份「只有一条播放」的菜单，同一张卡的两处入口对不上。
    private func showMoreMenu() {
        guard let menu = makeTrackMenu(), !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
}

// MARK: 链接格（link-box）

/// 新发现「探索更多」的链接格：一行文字 + 右端 ›，底色 `labelColor` 5%、圆角 10、
/// 左右内缩 16，文字 15/400 用主题色。
final class CatalogLinkCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let titleField = CatalogCardKit.label(size: M.linkTextSize, color: NSColor(Color.amberKey))
    private let chevron = NSImageView()

    override func build() {
        layer?.cornerRadius = M.linkCornerRadius
        addSubview(titleField)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        chevron.contentTintColor = NSColor(Color.amberKey)
        chevron.imageScaling = .scaleNone
        addSubview(chevron)
        applyColors()
    }

    override func apply(_ item: CatalogItem) {
        titleField.stringValue = item.title
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset = M.linkTextInset
        let chevronSize = chevron.image?.size ?? .zero
        chevron.frame = NSRect(x: bounds.width - inset - chevronSize.width,
                               y: (bounds.height - chevronSize.height) / 2,
                               width: chevronSize.width, height: chevronSize.height)
        let height = CatalogCardKit.lineHeight(titleField)
        let width = max(0, chevron.frame.minX - 8 - inset)
        titleField.frame = NSRect(x: inset - CatalogCardKit.labelInset,
                                  y: (bounds.height - height) / 2,
                                  width: width + CatalogCardKit.labelInset * 2, height: height)
    }
}

// MARK: 热门搜索结果的横卡（top-search-lockup）

/// 搜索结果页「热门搜索结果」网格里的一张卡（Music 的 `TopSearchLockupComponentItem`，
/// `search-musicui 规格` §2）：缩略图 44 贴左（艺人切圆、歌曲圆角 4）+ 右侧两行
/// （标题 13/600、「类型 · 副标题」11/400 次要色）+ 尾标（艺人 ›、歌曲 •••），
/// 整卡一块 `labelColor` 7% 的圆角 10 底。
///
/// 排版逐条照 Amber 旧版 SwiftUI 的 `TopResultsCard`（`TopSearchLockupView.swift`）搬，
/// 像素一个不改：`HStack(spacing: 12)` + 左右内缩 12、两行间距 3、卡高 76。
/// 尾标那颗 ••• 在旧版里也只是**画上去的**（整卡的点击是播放），所以这里同样不接点击，
/// 曲目菜单走右键（`CatalogCardContentView.menu(for:)`）。
final class CatalogTopResultCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let artworkView = CatalogArtworkView()
    private let titleField = CatalogCardKit.label(size: M.topResultTitleSize, weight: .semibold)
    private let subtitleField = CatalogCardKit.label(size: M.topResultSubtitleSize,
                                                     color: .secondaryLabelColor)
    private let trailingIcon = NSImageView()

    override func build() {
        layer?.cornerRadius = M.topResultCornerRadius
        addSubview(artworkView)
        addSubview(titleField)
        addSubview(subtitleField)
        trailingIcon.imageScaling = .scaleNone
        trailingIcon.contentTintColor = .secondaryLabelColor
        addSubview(trailingIcon)
        applyColors()
    }

    override func apply(_ item: CatalogItem) {
        // 圆的那档半径 = 边长的一半（艺人一律圆头像，见 `CatalogItem.isCircularArtwork`）。
        artworkView.cornerRadius = item.isCircularArtwork
            ? M.topResultArtworkSize / 2 : M.topResultArtworkCornerRadius
        artworkView.setArtwork(url: item.artworkURL, points: M.topResultArtworkSize,
                               fallbackColors: item.fallbackColors)
        titleField.stringValue = item.title
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = item.subtitle == nil
        // 有曲目上下文的是歌曲卡（尾标 •••），其余（艺人）是 ›，与旧版两支一致。
        let symbol = item.track == nil ? "chevron.right" : "ellipsis"
        trailingIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.topResultIconSize, weight: .medium))
    }

    override func resetContent() {
        artworkView.prepareForReuse()
    }

    override var artworkViewForAlignment: NSView? { artworkView }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// 旧版是 `Color.primary.opacity(0.07)`，即`labelColor` 7%。
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(M.topResultBackgroundAlpha).cgColor
        }
    }

    override func layout() {
        super.layout()
        let size = M.topResultArtworkSize
        artworkView.frame = NSRect(x: M.topResultInset, y: (bounds.height - size) / 2,
                                   width: size, height: size)

        let iconSize = trailingIcon.image?.size ?? .zero
        let iconX = bounds.width - M.topResultInset - iconSize.width
        trailingIcon.frame = NSRect(x: iconX, y: (bounds.height - iconSize.height) / 2,
                                    width: iconSize.width, height: iconSize.height)

        // HStack(spacing: 12)：图 | 12 | 文字块 | 12 | Spacer(min 0) | 12 | 尾标
        let textX = M.topResultInset + size + M.topResultGap
        let textWidth = max(0, iconX - M.topResultGap * 2 - textX)
        let titleHeight = CatalogCardKit.lineHeight(titleField)
        let subtitleHeight = subtitleField.isHidden ? 0 : CatalogCardKit.lineHeight(subtitleField)
        let blockHeight = subtitleField.isHidden
            ? titleHeight : titleHeight + M.topResultLineGap + subtitleHeight
        let bottom = ((bounds.height - blockHeight) / 2).rounded()
        if !subtitleField.isHidden {
            subtitleField.frame = NSRect(x: textX - CatalogCardKit.labelInset, y: bottom,
                                         width: textWidth + CatalogCardKit.labelInset * 2,
                                         height: subtitleHeight)
        }
        titleField.frame = NSRect(x: textX - CatalogCardKit.labelInset,
                                  y: bottom + blockHeight - titleHeight,
                                  width: textWidth + CatalogCardKit.labelInset * 2,
                                  height: titleHeight)
    }
}

// MARK: 多列曲目行（track-lockup）

/// 探新「新歌精选 / 正在流行中 / 大家都在听」的行 [AX] 379×56：
/// 图 40 + 标题 13/主色 / 歌手 12/次要色两行 + •••；分隔线从文字列（52）起。
///
/// SwiftUI 版把分隔线摆在 56 的行**外面**（整行实占 57），这里把它收进 56 内的最底一线，
/// 好让行 pitch 与 [AX] 实测的 56 一致（new.json：同列相邻行 y 差正好 56）。
final class CatalogTrackRowView: NSView, CatalogHoverTarget {

    private typealias M = MusicMetrics.Catalog

    private(set) var track: Track?
    private weak var appState: AppState?

    private let hoverBackground = CALayer()
    private let divider = CALayer()
    private let artworkView = CatalogArtworkView()
    private let playOverlay = NSButton()
    private let titleField = CatalogCardKit.label(size: 13)
    private let artistField = CatalogCardKit.label(size: 12, color: .secondaryLabelColor)
    private let moreButton = CatalogMoreButton()

    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        hoverBackground.cornerRadius = 6
        hoverBackground.opacity = 0
        layer?.addSublayer(hoverBackground)
        layer?.addSublayer(divider)

        artworkView.cornerRadius = 4
        addSubview(artworkView)

        playOverlay.isBordered = false
        playOverlay.bezelStyle = .shadowlessSquare
        playOverlay.title = ""
        playOverlay.imagePosition = .imageOnly
        playOverlay.imageScaling = .scaleNone
        playOverlay.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        playOverlay.contentTintColor = .white
        playOverlay.wantsLayer = true
        playOverlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.4).cgColor
        playOverlay.target = self
        playOverlay.action = #selector(playNow)
        playOverlay.setAccessibilityLabel("播放")
        playOverlay.toolTip = "播放"
        playOverlay.isHidden = true
        artworkView.addSubview(playOverlay)

        addSubview(titleField)
        addSubview(artistField)
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        addSubview(moreButton)

        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with track: Track, appState: AppState) {
        self.track = track
        self.appState = appState
        artworkView.setArtwork(url: track.artworkURL, points: 80)
        titleField.stringValue = track.title
        artistField.stringValue = track.artistName
        setAccessibilityLabel("\(track.title)，\(track.artistName)")
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovering(false)
        track = nil
        appState = nil
        artworkView.prepareForReuse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            hoverBackground.backgroundColor = NSColor.separatorColor
                .withAlphaComponent(0.22).cgColor
            divider.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CatalogCardKit.setFrame(hoverBackground, bounds)
        CatalogCardKit.setFrame(divider, NSRect(x: M.trackDividerLeading, y: 0,
                                                width: max(0, bounds.width - M.trackDividerLeading),
                                                height: 1))

        // `.padding(.horizontal, 4)` + `.padding(.trailing, 10)` → 左 4、右 14
        let artworkSize: CGFloat = 40
        artworkView.frame = NSRect(x: 4, y: (bounds.height - artworkSize) / 2,
                                   width: artworkSize, height: artworkSize)
        playOverlay.frame = artworkView.bounds

        let moreSize = NSSize(width: 24, height: 28)
        let moreX = bounds.width - 14 - moreSize.width
        moreButton.frame = NSRect(x: moreX, y: (bounds.height - moreSize.height) / 2,
                                  width: moreSize.width, height: moreSize.height)

        // [WEB] 文字列从 56 起（图 40 + 间距 12 + 左内缩 4）
        let textX = 4 + artworkSize + 12
        let textWidth = max(0, moreX - 8 - textX)
        let titleHeight = CatalogCardKit.lineHeight(titleField)
        let artistHeight = CatalogCardKit.lineHeight(artistField)
        let blockHeight = titleHeight + 2 + artistHeight
        let artistY = (bounds.height - blockHeight) / 2
        artistField.frame = NSRect(x: textX - CatalogCardKit.labelInset, y: artistY,
                                   width: textWidth + CatalogCardKit.labelInset * 2,
                                   height: artistHeight)
        titleField.frame = NSRect(x: textX - CatalogCardKit.labelInset,
                                  y: artistY + artistHeight + 2,
                                  width: textWidth + CatalogCardKit.labelInset * 2,
                                  height: titleHeight)
    }

    // MARK: 悬浮（由页面控制器按 hitTest 分发，见 `CatalogHoverTarget`）

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        CatalogCardKit.setOpacity(hoverBackground, hovering ? 1 : 0, animated: false)
        playOverlay.isHidden = !hovering
        moreButton.setHovering(hovering)
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if event.clickCount >= 2 {
            playNow()
            return
        }
        // 歌手名可点进艺人页（与 SwiftUI 版那个独立的 NavigationLink 同）
        if artistField.frame.contains(point), let track,
           let route = Route.artist(of: track) {
            appState?.push(route)
        }
    }

    @objc private func playNow() {
        guard let track else { return }
        appState?.playNow(track)
    }

    /// 目录页的曲目行：项序走 `TrackActions.catalogRow()`，与目录卡、目录曲目行同一份。
    private func makeTrackMenu() -> NSMenu? {
        guard let track, let appState else { return nil }
        return MenuSpec.makeMenu(TrackActions(tracks: [track], appState: appState).catalogRow())
    }

    private func showMoreMenu() {
        guard let menu = makeTrackMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeTrackMenu() }

    override func accessibilityPerformPress() -> Bool {
        playNow()
        return true
    }
}

// MARK: - NSCollectionViewItem 外壳

final class CatalogBannerItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogBannerCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogEpisodeItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogEpisodeCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogLinkItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogLinkCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogTopResultItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogTopResultCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogTrackRowItem: NSCollectionViewItem, CatalogTrackRowConfigurable {
    private let row = CatalogTrackRowView()
    override func loadView() { view = row }
    override func prepareForReuse() { super.prepareForReuse(); row.prepareForReuse() }
    func configure(with track: Track, appState: AppState) {
        row.configure(with: track, appState: appState)
    }
}
