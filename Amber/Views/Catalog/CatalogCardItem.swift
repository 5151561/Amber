import AppKit

// MARK: - 目录页卡片项的契约（阶段 3 两批并行的接口）

/// 目录页（主页 / 新发现 / 广播）换成 `NSCollectionView` 后，页面/布局/数据源（批 A）
/// 与七种卡型 item（批 B）分两批并行做，两边只通过这个文件说话：
/// - 批 A 只用 `CatalogCardRegistry` 拿复用标识与尺寸、用两个协议喂数据；
/// - 批 B 只改 `CatalogCardRegistry` 的登记表与尺寸数字，实现各 item 类。
///
/// 卡型与尺寸出处见 `MusicMetrics.Catalog`（Music 1.7 实测），
/// 组件家族对应关系见 `CatalogItem.Kind` 上的注释。

/// 一张卡（对应 `CatalogItem.Kind` 的八种）。
@MainActor
protocol CatalogCardConfigurable: NSCollectionViewItem {
    /// 每次复用都会重新调；实现要把上一次的图/文/悬浮态全部清掉再装。
    func configure(with item: CatalogItem, appState: AppState)
}

/// 多列曲目行（新发现「新歌精选 / 正在流行中 / 大家都在听」那种 379×56 的行）。
@MainActor
protocol CatalogTrackRowConfigurable: NSCollectionViewItem {
    func configure(with track: Track, appState: AppState)
}

/// 能被悬浮的卡。悬浮不由每张卡自己挂 tracking area，而是页面控制器在 collection view
/// 的 `mouseMoved` 里 hitTest 找到鼠标下面那张卡再分发：翻页箭头本来就要在那一层看鼠标
/// 位置，两件事共用一份；滚轮滚动、鼠标不动时也重算一次，悬浮态跟着滚到鼠标下面的那张走
/// （tracking area 要等下一次鼠标移动才发 enter/exit）。
@MainActor
protocol CatalogHoverTarget: NSView {
    func setHovering(_ hovering: Bool)
}

@MainActor
enum CatalogCardRegistry {

    private typealias M = MusicMetrics.Catalog

    static func identifier(for kind: CatalogItem.Kind) -> NSUserInterfaceItemIdentifier {
        switch kind {
        case .poster: return .init("CatalogPosterItem")
        case .square: return .init("CatalogSquareItem")
        case .hero: return .init("CatalogHeroItem")
        case .banner: return .init("CatalogBannerItem")
        case .station: return .init("CatalogStationItem")
        case .episode: return .init("CatalogEpisodeItem")
        case .video: return .init("CatalogVideoItem")
        case .link: return .init("CatalogLinkItem")
        case .artistHero: return .init("ArtistHeroItem")
        case .release: return .init("ArtistReleaseItem")
        case .topResult: return .init("CatalogTopResultItem")
        }
    }

    static let trackRowIdentifier = NSUserInterfaceItemIdentifier("CatalogTrackRowItem")

    /// 把全部卡型登记到 collection view 上。
    /// 电台（`.station`）与方卡是同一个类，`configure` 里按`item.kind` 切「台名压图」。
    static func register(in collectionView: NSCollectionView) {
        let classes: [(CatalogItem.Kind, NSCollectionViewItem.Type)] = [
            (.poster, CatalogPosterItem.self),
            (.square, CatalogSquareItem.self),
            (.station, CatalogSquareItem.self),
            (.hero, CatalogHeroItem.self),
            (.banner, CatalogBannerItem.self),
            (.episode, CatalogEpisodeItem.self),
            (.video, CatalogVideoItem.self),
            (.link, CatalogLinkItem.self),
            (.artistHero, ArtistHeroItem.self),
            (.release, ArtistReleaseItem.self),
            (.topResult, CatalogTopResultItem.self),
        ]
        for (kind, itemClass) in classes {
            collectionView.register(itemClass, forItemWithIdentifier: identifier(for: kind))
        }
        collectionView.register(CatalogTrackRowItem.self, forItemWithIdentifier: trackRowIdentifier)
    }

    /// 一张卡的尺寸（含图下文字块）。`containerWidth` 是内容列宽——**每种卡的宽都跟着它走**
    /// （`MusicMetrics.Catalog.Shelf`：按档取列数，列数可为小数，小数部分就是右沿露头那半张）。
    static func size(for kind: CatalogItem.Kind, containerWidth: CGFloat) -> NSSize {
        let inner = M.Shelf.innerWidth(containerWidth: containerWidth)
        func shelfWidth(_ family: M.Shelf.Family) -> CGFloat {
            M.Shelf.cardWidth(family, containerWidth: containerWidth)
        }
        switch kind {
        case .poster:
            let w = shelfWidth(.poster)
            return NSSize(width: w, height: w * M.posterAspect)
        case .square, .station:
            let w = shelfWidth(.square)
            return NSSize(width: w, height: w + M.squareTextHeight)
        case .hero:
            let w = shelfWidth(.hero)
            return NSSize(width: w, height: M.heroTextHeight + w * M.heroArtworkRatio)
        case .banner:
            return NSSize(width: inner, height: (inner / M.bannerAspect).rounded())
        case .episode:
            // [AX] 节目宽卡的高不随宽变，三档实扫都是 118。
            return NSSize(width: shelfWidth(.episode), height: M.episodeHeight)
        case .video:
            let w = shelfWidth(.square)
            return NSSize(width: w, height: w * M.videoAspect + M.videoTextHeight)
        case .link:
            let width = (inner - M.linkColumnGap * CGFloat(M.linkColumns - 1)) / CGFloat(M.linkColumns)
            return NSSize(width: max(0, width), height: M.linkHeight)
        case .artistHero:
            // 只是兜底：hero 是满幅的，真实高度由 `.artistHero` 段的布局按可视高算
            // （`ArtistPage.heroHeightRatio` 0.72 乘窗口高）。这里给内容列宽 ×
            // `heroMinHeight`（[实测] 385 的兜底常量），免得没人给尺寸时塌成 0。
            return NSSize(width: containerWidth, height: MusicMetrics.ArtistPage.heroMinHeight)
        case .release:
            // [PX] 卡宽 364；高与右边「熱門歌曲」货架的三行曲目对齐（3 × 56 = 168）。
            return NSSize(width: MusicMetrics.ArtistPage.releaseWidth,
                          height: M.trackRowHeight * 3)
        case .topResult:
            // 网格卡：卡高定死 76，宽由内容列宽分成若干列（列宽下限 250、列距 22），
            // 与 `CatalogPageViewController.topResultsSection` 用同一条算法。
            let columns = M.topResultColumns(forWidth: inner)
            let width = (inner - M.topResultColumnGap * CGFloat(columns - 1)) / CGFloat(columns)
            return NSSize(width: max(0, width.rounded(.down)), height: M.topResultHeight)
        }
    }

    /// 多列曲目行。列宽跟着内容列走（与 hero 同一张列数表），行高恒 56。
    static func trackRowSize(containerWidth: CGFloat) -> NSSize {
        NSSize(width: M.Shelf.cardWidth(.track, containerWidth: containerWidth),
               height: M.trackRowHeight)
    }
}

/// 批 B 落地前的占位卡：一块圆角灰底 + 标题，尺寸由布局给。
final class CatalogPlaceholderItem: NSCollectionViewItem, CatalogCardConfigurable, CatalogTrackRowConfigurable {

    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        box.layer?.cornerRadius = MusicMetrics.Catalog.posterCornerRadius
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        view = box
    }

    func configure(with item: CatalogItem, appState: AppState) {
        label.stringValue = item.title
    }

    func configure(with track: Track, appState: AppState) {
        label.stringValue = track.title
    }
}
