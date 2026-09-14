import AppKit
import SwiftUI

// MARK: - 货架卡（海报 / 方卡 + 电台 / hero / 视频）

// 逐张对 `CatalogCards.swift` 的 SwiftUI 版等价替换：字号、内缩、圆角、遮罩浓度照搬，
// 颜色改用系统语义色（SwiftUI 的 `.primary`/`.secondary` 就是它们）。

// MARK: 海报卡（powerswoosh）

/// 主页「专属精选推荐」「为你制作的歌单」「音乐回忆」的大卡 [AX] 246×328。
/// 3:4 竖图 + 图底 chin：eyebrow 11/600 白 / 标题 13/600 白 / 第三行 11/400 白，
/// 左右内缩 16、末行距图底 15；chin 两行 45、三行 60。
final class CatalogPosterCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let artworkView = CatalogArtworkView()
    private let eyebrowField = CatalogCardKit.label(size: M.posterEyebrowSize,
                                                    weight: .semibold, color: .white)
    private let titleField = CatalogCardKit.label(size: M.posterTitleSize,
                                                  weight: .semibold, color: .white)
    private let descField = CatalogCardKit.label(size: M.posterDescSize, color: .white)
    private let playButton = CatalogPlayButton()

    override func build() {
        artworkView.cornerRadius = M.posterCornerRadius
        artworkView.hoverScrimOpacity = 0.18
        addSubview(artworkView)
        for field in [eyebrowField, titleField, descField] {
            CatalogCardKit.applyArtworkShadow(field)
            artworkView.addSubview(field)
        }
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)
    }

    override func apply(_ item: CatalogItem) {
        eyebrowField.stringValue = item.eyebrow ?? ""
        eyebrowField.isHidden = item.eyebrow == nil
        titleField.stringValue = item.title
        descField.stringValue = item.description ?? ""
        descField.isHidden = item.description == nil

        let lineCount = 1 + (item.eyebrow == nil ? 0 : 1) + (item.description == nil ? 0 : 1)
        artworkView.legibilityHeight = lineCount >= 3 ? M.posterChinThreeLine : M.posterChinTwoLine
        artworkView.setArtwork(url: item.artworkURL, points: 250,
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

    override var artworkViewForAlignment: NSView? { artworkView }

    override func layout() {
        super.layout()
        artworkView.frame = bounds

        let inset = M.posterTextInset
        let width = max(0, bounds.width - inset * 2)
        var y = M.posterBottomInset
        for field in [descField, titleField, eyebrowField] where !field.isHidden {
            let height = CatalogCardKit.lineHeight(field)
            field.frame = NSRect(x: inset - CatalogCardKit.labelInset, y: y,
                                 width: width + CatalogCardKit.labelInset * 2, height: height)
            y += height + 2
        }

        playButton.frame = NSRect(x: bounds.width - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)
    }
}

// MARK: 方卡（product-lockup）与电台瓷砖

/// 绝大多数货架用的卡 [AX] 图 179.5 + 文字块 37。图下两行：标题 13/400 主色、
/// 副标题 13/400 次要色，图底 +4 起、行距 2。
/// 电台（`.station`）复用同一张卡，只是把台名压在图上（`overlaysName`）。
final class CatalogSquareCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let artworkView = CatalogArtworkView()
    private let nameOverlay = CatalogCardKit.label(size: M.stationNameSize,
                                                   weight: .bold, color: .white, lines: 2)
    private let titleField = CatalogCardKit.label(size: M.squareTextSize)
    private let subtitleField = CatalogCardKit.label(size: M.squareTextSize,
                                                     color: .secondaryLabelColor)
    private let starButton = NSButton()
    private let explicitBadge = CatalogExplicitBadge()
    private let playButton = CatalogPlayButton()

    private var overlaysName = false
    /// 艺人卡那一档（圆头像 + 名字居中），见 `CatalogItem.isCircularArtwork`。
    private var circularArtwork = false

    override func build() {
        addSubview(artworkView)
        CatalogCardKit.applyArtworkShadow(nameOverlay)
        artworkView.addSubview(nameOverlay)
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)

        addSubview(titleField)
        addSubview(subtitleField)

        starButton.isBordered = false
        starButton.bezelStyle = .shadowlessSquare
        starButton.title = ""
        starButton.imagePosition = .imageOnly
        starButton.imageScaling = .scaleNone
        starButton.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        starButton.contentTintColor = NSColor(Color.amberKey)
        starButton.target = self
        starButton.action = #selector(toggleFavorite)
        // [HIG] 图标键必须自带 label
        starButton.setAccessibilityLabel("取消心水")
        starButton.toolTip = "取消心水"
        addSubview(starButton)

        addSubview(explicitBadge)
    }

    override func apply(_ item: CatalogItem) {
        overlaysName = item.kind == .station
        circularArtwork = item.isCircularArtwork
        // 圆的那档半径 = 边长的一半，边长只有 `layout()` 知道，所以在那边补上
        artworkView.cornerRadius = overlaysName ? M.stationCornerRadius
                                                : MusicMetrics.Card.artworkCornerRadius
        titleField.alignment = circularArtwork ? .center : .left
        // 台名压图那档的可读性渐变高 = 边长的 45%；边长随内容列宽走，
        // 所以只在这里记开关，真实高度在 `layout()` 里按 bounds 给。
        artworkView.legibilityHeight = overlaysName ? bounds.width * 0.45 : 0
        nameOverlay.stringValue = item.title
        nameOverlay.isHidden = !overlaysName
        // 电台瓷砖的台名已经压在图上，渐变占位上不再摆音符
        artworkView.setArtwork(url: item.artworkURL, points: 200,
                               fallbackColors: item.fallbackColors,
                               brandGlyphSize: overlaysName ? nil : 30)

        titleField.stringValue = item.title
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = item.subtitle == nil
        starButton.isHidden = !item.isFavorite
        explicitBadge.isHidden = !item.isExplicit
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

    override var artworkViewForAlignment: NSView? { artworkView }

    @objc private func toggleFavorite() {
        guard let track = item?.track else { return }
        appState?.library.toggleFavorite(track)
    }

    override func layout() {
        super.layout()
        let side = bounds.width
        artworkView.frame = NSRect(x: 0, y: bounds.height - side, width: side, height: side)
        if circularArtwork { artworkView.cornerRadius = side / 2 }
        if overlaysName { artworkView.legibilityHeight = side * 0.45 }

        if overlaysName {
            let inset = M.posterTextInset
            let width = max(0, side - inset * 2)
            let height = nameOverlay.sizeThatFits(NSSize(width: width,
                                                         height: .greatestFiniteMagnitude)).height
            nameOverlay.frame = NSRect(x: inset - CatalogCardKit.labelInset,
                                       y: M.posterBottomInset,
                                       width: width + CatalogCardKit.labelInset * 2,
                                       height: height)
        }

        playButton.frame = NSRect(x: side - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)

        layoutTextBlock(width: side, top: artworkView.frame.minY)
    }

    /// 标题行是 `HStack(spacing: 3)`：标题字宽算完，星形与 Explicit 标依次贴排。
    private func layoutTextBlock(width: CGFloat, top: CGFloat) {
        let titleHeight = CatalogCardKit.lineHeight(titleField)
        let titleY = top - M.squareTextTop - titleHeight

        // 艺人卡只有一行名字、居中占满卡宽：星标（曲目才有）与 Explicit 标（专辑才有）
        // 在艺人上都不会出现，也就不用给它们让位。
        if circularArtwork {
            titleField.frame = NSRect(x: -CatalogCardKit.labelInset, y: titleY,
                                      width: width + CatalogCardKit.labelInset * 2,
                                      height: titleHeight)
            return
        }

        // 用字形自己的尺寸，别用 `intrinsicContentSize`：无边框图标键报的是 cell 的
        // 内容盒（[探针实测] 14.5×8），比 11pt star.fill 的字形（15×14）还小，字形会溢出。
        let starSize = starButton.isHidden ? .zero : (starButton.image?.size ?? .zero)
        let badgeSize = explicitBadge.isHidden ? .zero : explicitBadge.intrinsicContentSize
        let trailing = (starButton.isHidden ? 0 : starSize.width + 3)
            + (explicitBadge.isHidden ? 0 : badgeSize.width + 3)
        let titleWidth = min(CatalogCardKit.textWidth(titleField), max(0, width - trailing))
        titleField.frame = NSRect(x: -CatalogCardKit.labelInset, y: titleY,
                                  width: titleWidth + CatalogCardKit.labelInset * 2,
                                  height: titleHeight)

        var x = titleWidth
        if !starButton.isHidden {
            x += 3
            starButton.frame = NSRect(x: x, y: titleY + (titleHeight - starSize.height) / 2,
                                      width: starSize.width, height: starSize.height)
            x += starSize.width
        }
        if !explicitBadge.isHidden {
            x += 3
            explicitBadge.frame = NSRect(x: x, y: titleY + (titleHeight - badgeSize.height) / 2,
                                         width: badgeSize.width, height: badgeSize.height)
        }

        if !subtitleField.isHidden {
            let height = CatalogCardKit.lineHeight(subtitleField)
            subtitleField.frame = NSRect(x: -CatalogCardKit.labelInset, y: titleY - 2 - height,
                                         width: width + CatalogCardKit.labelInset * 2, height: height)
        }
    }

    /// 封面进主体、标题进主体、副标题进艺人页（与 SwiftUI 版三个独立的 `NavigationLink` 同）。
    override func handleClick(at point: NSPoint, clickCount: Int) {
        guard let item else { return }
        if !subtitleField.isHidden, let route = item.subtitleRoute,
           subtitleField.frame.contains(point) {
            appState?.push(route)
            return
        }
        if titleField.frame.contains(point) {
            // 点名字只跳转、不播：没有 route 的资料库艺人卡走它自己那条跳转（`onOpen`）。
            if let route = item.route {
                appState?.push(route)
            } else if let onOpen = item.onOpen {
                onOpen()
            }
            return
        }
        guard artworkView.frame.contains(point), isInteractive else { return }
        activatePrimary()
    }
}

// MARK: hero 卡（editorial-card）

/// 探新首段与广播首段的宽卡：文字**在图上方**三行（eyebrow 11/600 次要色、
/// 标题 15/400 主色、副标题 15/400 次要色），下面是宽图（圆角 10），
/// 描述 12/400 纯白压在图内左下角（内缩 16、距底 16）。
final class CatalogHeroCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let eyebrowField = CatalogCardKit.label(size: M.heroEyebrowSize, weight: .semibold,
                                                    color: .secondaryLabelColor)
    private let titleField = CatalogCardKit.label(size: M.heroTitleSize)
    private let subtitleField = CatalogCardKit.label(size: M.heroTitleSize,
                                                     color: .secondaryLabelColor)
    private let artworkView = CatalogArtworkView()
    private let descField = CatalogCardKit.label(size: M.heroDescSize, color: .white)
    private let playButton = CatalogPlayButton()

    override func build() {
        addSubview(eyebrowField)
        addSubview(titleField)
        addSubview(subtitleField)
        artworkView.cornerRadius = M.heroCornerRadius
        artworkView.hoverScrimOpacity = 0.15
        addSubview(artworkView)
        CatalogCardKit.applyArtworkShadow(descField)
        artworkView.addSubview(descField)
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)
    }

    override func apply(_ item: CatalogItem) {
        eyebrowField.stringValue = item.eyebrow ?? ""
        eyebrowField.isHidden = item.eyebrow == nil
        titleField.stringValue = item.title
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = item.subtitle == nil
        descField.stringValue = item.description ?? ""
        descField.isHidden = item.description == nil
        artworkView.setArtwork(url: item.artworkURL, points: 400,
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

    override var artworkViewForAlignment: NSView? { artworkView }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y = bounds.height
        for field in [eyebrowField, titleField, subtitleField] where !field.isHidden {
            let height = CatalogCardKit.lineHeight(field)
            y -= height
            field.frame = NSRect(x: -CatalogCardKit.labelInset, y: y,
                                 width: width + CatalogCardKit.labelInset * 2, height: height)
        }

        artworkView.frame = NSRect(x: 0, y: 0, width: width,
                                   height: max(0, bounds.height - M.heroTextHeight))

        if !descField.isHidden {
            let inset = M.heroDescInset
            let height = CatalogCardKit.lineHeight(descField)
            descField.frame = NSRect(x: inset - CatalogCardKit.labelInset, y: inset,
                                     width: max(0, width - inset * 2) + CatalogCardKit.labelInset * 2,
                                     height: height)
        }

        playButton.frame = NSRect(x: width - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)
    }
}

// MARK: 视频卡（vertical-video）

/// 新发现「观看艺人分享」的卡：16:9 缩略图 + 图下两行（标题 / 艺人名）。
/// 不给 `points`：MV 封面是 640×360 的 16:9 模板，方图阶梯改写会让 CDN 404。
///
/// 缩略图右下角还有一颗时长角标（旧版搜索结果的 `MVCard` 那颗）：**有 `item.badge`
/// 才画**。搜索结果的 MV 卡在那里放时长，主页/新发现的视频卡不给 badge，那两页照旧不画。
final class CatalogVideoCardView: CatalogCardContentView {

    private typealias M = MusicMetrics.Catalog

    private let artworkView = CatalogArtworkView()
    private let titleField = CatalogCardKit.label(size: M.squareTextSize)
    private let subtitleField = CatalogCardKit.label(size: M.squareTextSize,
                                                     color: .secondaryLabelColor)
    private let playButton = CatalogPlayButton()
    private let durationBadge = CatalogCornerBadge()

    override func build() {
        addSubview(artworkView)
        playButton.onClick = { [weak self] in self?.item?.onPlay?() }
        artworkView.addSubview(playButton)
        durationBadge.isHidden = true
        artworkView.addSubview(durationBadge)
        addSubview(titleField)
        addSubview(subtitleField)
    }

    override func apply(_ item: CatalogItem) {
        artworkView.setArtwork(url: item.artworkURL, points: nil,
                               fallbackColors: item.fallbackColors)
        titleField.stringValue = item.title
        subtitleField.stringValue = item.subtitle ?? ""
        subtitleField.isHidden = item.subtitle == nil
        durationBadge.text = item.badge ?? ""
        durationBadge.isHidden = item.badge == nil
        playButton.setVisible(false, animated: false)
    }

    override func hoverDidChange(_ hovering: Bool, animated: Bool) {
        playButton.setVisible(hovering && item?.onPlay != nil, animated: animated)
    }

    override func resetContent() {
        artworkView.prepareForReuse()
        playButton.setVisible(false, animated: false)
    }

    override var artworkViewForAlignment: NSView? { artworkView }

    override func layout() {
        super.layout()
        let width = bounds.width
        // [AX] 视频卡的图下文字块是 35（方卡是 37），拿方卡那条会把 16:9 的图压掉 2。
        let artworkHeight = max(0, bounds.height - M.videoTextHeight)
        artworkView.frame = NSRect(x: 0, y: M.videoTextHeight, width: width, height: artworkHeight)

        playButton.frame = NSRect(x: width - CatalogPlayButton.inset - CatalogPlayButton.diameter,
                                  y: CatalogPlayButton.inset,
                                  width: CatalogPlayButton.diameter,
                                  height: CatalogPlayButton.diameter)

        // 时长角标在图内右下角，距图边 6（旧版 `.overlay(alignment: .bottomTrailing)` + `.padding(6)`）。
        if !durationBadge.isHidden {
            let badgeSize = durationBadge.intrinsicContentSize
            durationBadge.frame = NSRect(
                x: artworkView.bounds.width - M.videoBadgeInset - badgeSize.width,
                y: M.videoBadgeInset, width: badgeSize.width, height: badgeSize.height)
        }

        let titleHeight = CatalogCardKit.lineHeight(titleField)
        let titleY = M.videoTextHeight - M.squareTextTop - titleHeight
        titleField.frame = NSRect(x: -CatalogCardKit.labelInset, y: titleY,
                                  width: width + CatalogCardKit.labelInset * 2, height: titleHeight)
        if !subtitleField.isHidden {
            let height = CatalogCardKit.lineHeight(subtitleField)
            subtitleField.frame = NSRect(x: -CatalogCardKit.labelInset, y: titleY - 2 - height,
                                         width: width + CatalogCardKit.labelInset * 2, height: height)
        }
    }
}

// MARK: - NSCollectionViewItem 外壳

final class CatalogPosterItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogPosterCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogSquareItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogSquareCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogHeroItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogHeroCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}

final class CatalogVideoItem: NSCollectionViewItem, CatalogCardConfigurable {
    private let card = CatalogVideoCardView()
    override func loadView() { view = card }
    override func prepareForReuse() { super.prepareForReuse(); card.prepareForReuse() }
    func configure(with item: CatalogItem, appState: AppState) {
        card.configure(with: item, appState: appState)
    }
}
