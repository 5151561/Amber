import AppKit
import SwiftUI

// MARK: - 搜索落地页（词条为空时）—— 计划阶段 5 批 C
//
// 原 `SearchLandingView`（SwiftUI）原样搬成 AppKit：一张`NSCollectionView` +
// 组合布局，两段——
// - **最近搜索**（`RecentSearchCardsView` / `JSRecentSearchItem` §5）：17pt 段标题 + 右上
//   红色「清除」独立动作（`ClearRecentSearchesAction`）；卡片货架，卡 ~214×64、圆角 10；
// - **浏览类别**（`SearchLandingBrickLockupView` §3）：砖块网格，砖 ~219×127（比例 1.72）、
//   圆角 10、渐变底、左下角白色粗体标签，点击即以该类别词条发起搜索。
// Music 落地页没有页面大标题，直接从段标题开始。
//
// 这一段没走目录页引擎：两种卡（最近搜索卡、类别砖）都不在 `CatalogItem.Kind` 里，
// 砖块网格也不是引擎现有的段布局，而批 C 不碰 `Views/Catalog/**`。段头、0 宽闸门这些
// 与引擎同一套写法（见 `CatalogPageViewController` 文件头的实测笔记）。

@MainActor
final class SearchLandingViewController: ContentPageController {

    /// 点了最近搜索卡 / 类别砖：以这个词条发起搜索。
    var onSelectTerm: ((String) -> Void)?
    /// 「清除」（ClearRecentSearchesAction §5）。
    var onClearRecents: (() -> Void)?

    // MARK: 度量（都只在这一页用，不进 MusicMetrics）

    /// 页面左右边距与目录页同一条（[AX] 内容左沿 → 卡片 34）。
    private static let leadingMargin = MusicMetrics.Page.leadingMargin
    /// 页顶留白（旧版 `SearchView` 的`.padding(.top, 14)`）。
    private static let topPadding: CGFloat = 14
    /// 页底留白（旧版 `.padding(.bottom, 24)`）。
    private static let bottomPadding: CGFloat = 24
    /// 两段之间（旧版 `VStack(spacing: 28)`）。
    private static let sectionSpacing: CGFloat = 28
    /// 段标题底 → 内容顶（旧版每段 `VStack(spacing: 14)`）。段头视图也按这条贴底排。
    fileprivate static let headingToContent: CGFloat = 14
    /// 段标题 17pt bold（实测 Music 落地页段标题比目录页的 15 大一档）。
    private static let headingSize: CGFloat = 17
    /// 最近搜索卡 [实测] 214×64、圆角 10，货架间距 20（旧版 `HStack(spacing: 20)`）。
    private static let recentCardSize = NSSize(width: 214, height: 64)
    private static let recentCardGap: CGFloat = 20
    /// [实测] SearchLandingBrickGridLayoutConfiguration：5 列、列距 ~19、行距 ~15；
    /// 旧版用 `GridItem(.adaptive(minimum: 200), spacing: 19)` 等价实现，这里照抄那三个数。
    private static let brickMinWidth: CGFloat = 200
    private static let brickColumnGap: CGFloat = 19
    private static let brickRowGap: CGFloat = 15
    /// 砖块比例 [实测] 219×127 ≈ 1.72。
    private static let brickAspect: CGFloat = 1.72

    /// 段标题行的高 = 17pt bold 裸标签的自然高（AGENTS「界面层」第 6 条：能由系统给的别写死）。
    private static let headingHeight: CGFloat = {
        let probe = NSTextField(labelWithString: "Ag最近搜索")
        probe.font = .systemFont(ofSize: headingSize, weight: .bold)
        return ceil(probe.fittingSize.height)
    }()

    // MARK: 状态

    private enum LandingSection {
        case recents
        case browse
    }

    private let scrollView = NSScrollView()
    private let collectionView = SearchLandingCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<String, String>!

    /// 布局按段序号分派要看的表，与快照同时更新（同 `CatalogPageViewController`）。
    private var layoutSections: [LandingSection] = [.browse]
    private var recents: [String] = []
    /// 宽度还没落定时挡下来的那一份，等 `viewDidLayout` 补灌（0 宽灌快照会爆内存，
    /// 见 `CatalogPageViewController.apply(sections:)` 上那段实测）。
    private var pendingApply = false

    private static let recentsSectionID = "search-landing-recents"
    private static let browseSectionID = "search-landing-browse"
    private static let headerIdentifier = NSUserInterfaceItemIdentifier("SearchLandingHeaderView")

    // MARK: - 生命周期

    init(appState: AppState) {
        super.init(nativePage: appState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // 页面自己不画背景：玻璃只有窗口根那一层（见 RootViewController）。
        let container = NSView()

        collectionView.collectionViewLayout = makeLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(SearchRecentCardItem.self,
                                forItemWithIdentifier: SearchRecentCardItem.identifier)
        collectionView.register(SearchBrickItem.self,
                                forItemWithIdentifier: SearchBrickItem.identifier)
        collectionView.register(SearchLandingHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: Self.headerIdentifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // 顶部那 52 交给系统（`automaticallyAdjustsContentInsets`）；底部给迷你播放器让位要走
        // 安全区，直接写 `contentInsets` 会把自动调整连同那 52 一起关掉（同目录页）。
        scrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MusicMetrics.MiniPlayer.scrollReserve, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        makeDataSource()
        apply()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if pendingApply, collectionView.bounds.width > 0 {
            apply()
        }
    }

    /// 页面复显（搜索页 `showLanding(_:)` 切回来、或从侧栏切回搜索页）。
    /// 被 `isHidden` 关着的那段时间里挡下的快照在这里补灌——藏着的时候灌，
    /// `invalidateLayout()` 标的脏等不到布局 pass（AppKit 跳过隐藏子树），
    /// 复显时就会拿旧几何摆新内容。
    override func pageDidAppear() {
        super.pageDidAppear()
        if pendingApply { apply() }
    }

    /// 最近搜索变了（新搜了一次、或点了「清除」）。
    func setRecents(_ terms: [String]) {
        guard terms != recents else { return }
        recents = terms
        guard isViewLoaded, dataSource != nil else { return }
        apply()
    }

    // MARK: - 数据源

    private func makeDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            guard let self else { return NSCollectionViewItem() }
            if let term = Self.recentTerm(of: identifier) {
                let item = collectionView.makeItem(withIdentifier: SearchRecentCardItem.identifier,
                                                   for: indexPath) as? SearchRecentCardItem
                item?.configure(term: term) { [weak self] in self?.onSelectTerm?(term) }
                return item ?? NSCollectionViewItem()
            }
            let category = Self.category(of: identifier)
            let item = collectionView.makeItem(withIdentifier: SearchBrickItem.identifier,
                                               for: indexPath) as? SearchBrickItem
            if let category {
                item?.configure(category: category) { [weak self] in self?.onSelectTerm?(category.term) }
            }
            return item ?? NSCollectionViewItem()
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self, kind == NSCollectionView.elementKindSectionHeader else { return nil }
            let view = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: Self.headerIdentifier,
                for: indexPath) as? SearchLandingHeaderView
            switch self.layoutSection(at: indexPath.section) {
            case .recents:
                view?.configure(title: "最近搜索",
                                clear: { [weak self] in self?.onClearRecents?() })
            case .browse, .none:
                view?.configure(title: "浏览类别", clear: nil)
            }
            return view
        }
    }

    private func apply() {
        // 硬闸一：已经在窗口里、宽度却还是 0 时不许灌快照（组合布局会在 0 宽容器里
        // 无限生成 item，实测几秒吃掉几十 GB）。挡下的这一份等 `viewDidLayout` 补灌。
        //
        // 硬闸二：自己或祖先正被 `isHidden` 关着时也不许灌。搜索页提交词条那一刻，
        // 同一轮 runloop 里先来 `setRecents`（最近搜索段整段插回）、紧接着
        // `showLanding(false)` 把落地页关掉；`invalidateLayout()` 只标脏、重算要等下一次
        // 布局 pass，而 AppKit 的布局 pass 跳过隐藏子树，那次重算就被吞了——回到落地页
        // 时 collection view 还拿着「只有浏览类别一段」的缓存几何摆两段内容，卡片纵向错位。
        // 挡下的这一份等 `pageDidAppear()` 补灌。
        if (view.window != nil && collectionView.bounds.width <= 0)
            || view.isHiddenOrHasHiddenAncestor {
            pendingApply = true
            return
        }
        pendingApply = false

        var sections: [LandingSection] = []
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        if !recents.isEmpty {
            sections.append(.recents)
            snapshot.appendSections([Self.recentsSectionID])
            snapshot.appendItems(recents.map { "recent:\($0)" }, toSection: Self.recentsSectionID)
        }
        sections.append(.browse)
        snapshot.appendSections([Self.browseSectionID])
        snapshot.appendItems(SearchLandingCategory.catalog.map { "brick:\($0.term)" },
                             toSection: Self.browseSectionID)

        layoutSections = sections
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    private func layoutSection(at index: Int) -> LandingSection? {
        index < layoutSections.count ? layoutSections[index] : nil
    }

    private static func recentTerm(of identifier: String) -> String? {
        identifier.hasPrefix("recent:") ? String(identifier.dropFirst("recent:".count)) : nil
    }

    private static func category(of identifier: String) -> SearchLandingCategory? {
        let term = identifier.hasPrefix("brick:") ? String(identifier.dropFirst("brick:".count)) : ""
        return SearchLandingCategory.catalog.first { $0.term == term }
    }

    // MARK: - 组合布局

    private func makeLayout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.layoutSection(at: index) else {
                return SearchLandingViewController.blankSection()
            }
            switch section {
            case .recents:
                return self.recentsLayoutSection()
            case .browse:
                return self.browseLayoutSection(containerWidth: environment.container.contentSize.width)
            }
        }
    }

    private static func blankSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(1))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        return NSCollectionLayoutSection(group: group)
    }

    /// 最近搜索：卡片货架，横向自由滑（同目录页的货架，不吸附）。
    private func recentsLayoutSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .absolute(Self.recentCardSize.width),
                                          heightDimension: .absolute(Self.recentCardSize.height))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Self.recentCardGap
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.leadingMargin,
                                                        bottom: 0, trailing: Self.leadingMargin)
        section.boundarySupplementaryItems = [header(topGap: Self.topPadding)]
        return section
    }

    /// 浏览类别：砖块网格，行优先（旧版 `LazyVGrid` 同）。列数按内容列宽算：
    /// 每列至少 `brickMinWidth`，列距固定，余下的宽度平分给各列。
    private func browseLayoutSection(containerWidth: CGFloat) -> NSCollectionLayoutSection {
        let inner = max(1, containerWidth - Self.leadingMargin * 2)
        let columns = max(1, Int((inner + Self.brickColumnGap)
            / (Self.brickMinWidth + Self.brickColumnGap)))
        let width = ((inner - Self.brickColumnGap * CGFloat(columns - 1)) / CGFloat(columns))
            .rounded(.down)
        let height = (width / Self.brickAspect).rounded()

        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute(max(1, width)), heightDimension: .absolute(max(1, height))))
        let row = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(inner),
                                               heightDimension: .absolute(max(1, height))),
            subitem: item, count: columns)
        row.interItemSpacing = .fixed(Self.brickColumnGap)
        let section = NSCollectionLayoutSection(group: row)
        section.interGroupSpacing = Self.brickRowGap
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.leadingMargin,
                                                        bottom: Self.bottomPadding,
                                                        trailing: Self.leadingMargin)
        section.boundarySupplementaryItems = [
            header(topGap: recents.isEmpty ? Self.topPadding : Self.sectionSpacing)
        ]
        return section
    }

    /// 段头自己带上「上一段底 → 本段标题顶」的那段空白：组合布局的 `contentInsets.top`
    /// 落在段头**下面**（见 `CatalogPageViewController` 文件头 probe4 那条实测）。
    private func header(topGap: CGFloat) -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(topGap + Self.headingHeight + Self.headingToContent)),
            elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
    }
}

// MARK: - 收货架的 collection view

/// 组合布局给横滚段（`orthogonalScrollingBehavior`）内部造的那个`_NSCollectionScrollView`
/// 自带横向滚动条与背景，Music 的货架两样都没有；它每次布局都会把自己那两样打开，
/// 所以挂进来时与每次布局都要按一遍（与目录页 `CatalogShelfCollectionView` 同一处理）。
private final class SearchLandingCollectionView: NSCollectionView {

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        makeInternalShelfTransparent(of: subview)
    }

    override func layout() {
        super.layout()
        for subview in subviews { makeInternalShelfTransparent(of: subview) }
    }

    private func makeInternalShelfTransparent(of view: NSView) {
        guard let shelf = view as? NSScrollView else { return }
        shelf.drawsBackground = false
        if shelf.hasHorizontalScroller { shelf.hasHorizontalScroller = false }
        if shelf.hasVerticalScroller { shelf.hasVerticalScroller = false }
        if let inner = shelf.documentView as? NSCollectionView {
            inner.backgroundColors = [.clear]
        }
    }
}

// MARK: - 段头（标题 + 可选的红「清除」）

private final class SearchLandingHeaderView: NSView, NSCollectionViewElement {

    private let title = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var clear: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        // 「清除」是独立动作（ClearRecentSearchesAction §5），13pt 品牌红、无边框。
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.attributedTitle = NSAttributedString(
            string: "清除",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .foregroundColor: NSColor(Color.amberKey)])
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        // 「上一段底 → 标题顶」那段空白由布局独家决定（段头高 = topGap + 标题行高 +
        // headingToContent），所以标题钉**自己的底**往上量 headingToContent，标题顶自然落在
        // topGap 上。钉顶再配一份 topGap 就成了两个真值源：`.recents` 段整段插入/删除时，
        // diffable 眼里 `.browse` 段没变、段头视图不保证重配，两个值会差 14pt。
        NSLayoutConstraint.activate([
            title.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SearchLandingViewController.headingToContent),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearButton.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title text: String, clear: (() -> Void)?) {
        title.stringValue = text
        self.clear = clear
        clearButton.isHidden = clear == nil
    }

    @objc private func clearTapped() { clear?() }
}

// MARK: - 最近搜索卡

/// [实测] ~214×64、圆角 10，底色 quaternary，词条单行 + 右侧 chevron
/// （Music 的实体卡是「封面 + 标题 + 副标题 + 尾标」，Amber 的最近搜索只有词条，
/// 封面档用放大镜占位）。
private final class SearchRecentCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("SearchRecentCardItem")

    private let card = SearchClickableView()
    private let glyphBox = SearchClickableView()
    private let glyph = NSImageView()
    private let term = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override func loadView() {
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.fill = NSColor.labelColor.withAlphaComponent(0.07)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.button)

        glyphBox.wantsLayer = true
        glyphBox.layer?.cornerRadius = 4
        glyphBox.fill = NSColor.labelColor.withAlphaComponent(0.08)
        glyphBox.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(glyphBox)

        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyphBox.addSubview(glyph)

        term.font = .systemFont(ofSize: 13, weight: .semibold)
        term.lineBreakMode = .byTruncatingTail
        term.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(term)

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            glyphBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            glyphBox.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            glyphBox.widthAnchor.constraint(equalToConstant: 40),
            glyphBox.heightAnchor.constraint(equalToConstant: 40),
            glyph.centerXAnchor.constraint(equalTo: glyphBox.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphBox.centerYAnchor),
            term.leadingAnchor.constraint(equalTo: glyphBox.trailingAnchor, constant: 10),
            term.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            term.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        view = card
    }

    func configure(term text: String, onClick: @escaping () -> Void) {
        term.stringValue = text
        card.onClick = onClick
        card.setAccessibilityLabel(text)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.onClick = nil
        term.stringValue = ""
    }
}

// MARK: - 浏览类别砖

/// 砖块（SearchLandingBrickLockupComponentItem §3）：渐变底 + 左下角标题，
/// [实测] 比例 ~1.72（219×127）、圆角 10，标题 15pt bold 白字、内缩 13。
private final class SearchBrickItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("SearchBrickItem")

    private let brick = SearchClickableView()
    private let gradient = CAGradientLayer()
    private let titleField = NSTextField(labelWithString: "")

    override func loadView() {
        brick.wantsLayer = true
        brick.layer?.cornerRadius = 10
        brick.layer?.masksToBounds = true
        brick.setAccessibilityElement(true)
        brick.setAccessibilityRole(.button)

        gradient.startPoint = CGPoint(x: 0, y: 1)   // topLeading
        gradient.endPoint = CGPoint(x: 1, y: 0)     // bottomTrailing
        brick.layer?.addSublayer(gradient)
        brick.gradient = gradient

        titleField.font = .systemFont(ofSize: 15, weight: .bold)
        titleField.textColor = .white
        titleField.translatesAutoresizingMaskIntoConstraints = false
        brick.addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: brick.leadingAnchor, constant: 13),
            titleField.bottomAnchor.constraint(equalTo: brick.bottomAnchor, constant: -13),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: brick.trailingAnchor, constant: -13),
        ])

        view = brick
    }

    func configure(category: SearchLandingCategory, onClick: @escaping () -> Void) {
        titleField.stringValue = category.title
        gradient.colors = category.colors.map(\.cgColor)
        brick.onClick = onClick
        brick.setAccessibilityLabel(category.title)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        brick.onClick = nil
        titleField.stringValue = ""
    }
}

// MARK: - 可点的一块

/// 点击语义与 SwiftUI 的 `Button` 一致：按下不触发，抬手仍在盒内才算一次点击
/// （同 `CatalogCardContentView`）。
private final class SearchClickableView: NSView {

    var onClick: (() -> Void)?
    /// 渐变层要跟着 frame 走（`CALayer` 不吃约束）。
    var gradient: CAGradientLayer?
    /// 底色。`CGColor` 是「解析过」的颜色、不跟外观走，所以外观一变要重解一次
    /// （同 `CatalogLinkCardView.applyColors`）。
    var fill: NSColor? {
        didSet { applyFill() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        guard let fill else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = fill.cgColor
        }
    }

    /// 整块是一个点击目标：`NSTextField` 即便是 label 形态也会**吃掉**落在它身上的点击
    /// （不可编辑的 cell 把事件丢掉、不往父视图冒泡，见 `CatalogLabel` 上那段注释），
    /// 所以有落点时直接把命中收到自己身上。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, !isHidden else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        guard let gradient else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

// MARK: - 类别目录

/// 点击即以流派词发起在线搜索（Amber 无 Apple Music 的分类图，用色块砖替代）。
/// 色值与旧 `SearchLandingView` 那张表一字不差，只是换成`NSColor`。
struct SearchLandingCategory {
    let title: String
    let term: String
    let colors: [NSColor]

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static let catalog: [SearchLandingCategory] = [
        .init(title: "流行", term: "流行", colors: [rgb(0.94, 0.35, 0.38), rgb(0.80, 0.16, 0.28)]),
        .init(title: "摇滚", term: "摇滚", colors: [rgb(0.85, 0.45, 0.18), rgb(0.72, 0.28, 0.10)]),
        .init(title: "民谣", term: "民谣", colors: [rgb(0.24, 0.62, 0.48), rgb(0.10, 0.42, 0.34)]),
        .init(title: "电子", term: "电子", colors: [rgb(0.36, 0.55, 0.90), rgb(0.18, 0.30, 0.68)]),
        .init(title: "嘻哈", term: "嘻哈", colors: [rgb(0.55, 0.45, 0.82), rgb(0.34, 0.26, 0.60)]),
        .init(title: "爵士", term: "爵士", colors: [rgb(0.72, 0.52, 0.36), rgb(0.50, 0.32, 0.18)]),
        .init(title: "热门", term: "热门歌曲", colors: [rgb(0.92, 0.55, 0.22), rgb(0.76, 0.34, 0.10)]),
        .init(title: "轻音乐", term: "轻音乐", colors: [rgb(0.42, 0.72, 0.78), rgb(0.22, 0.50, 0.60)]),
        .init(title: "怀旧", term: "怀旧经典", colors: [rgb(0.60, 0.60, 0.65), rgb(0.38, 0.38, 0.44)]),
        .init(title: "舞曲", term: "舞曲", colors: [rgb(0.90, 0.36, 0.55), rgb(0.70, 0.18, 0.38)]),
    ]
}
