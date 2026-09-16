import AppKit
import SwiftUI

// MARK: - 房间页页头（AppKit）—— 计划阶段 5 批 B

/// 目录二级页（「查看全部 ›」的落点，Music 叫 room）的页头，两处共用：
///
/// - 网格类房间页 `CatalogRoomViewController`：装成第 0 段的段头（0 件 item 的段，
///   与 `CatalogPageViewController` 的页面大标题行同一条路——布局配置的全局头在
///   0 段快照下会被整个丢掉）；
/// - 曲目类房间页 `TrackListPageController(kind: .room)`：装成表格第 0 行的头部视图
///   （`TrackTableHeaderView`）。
///
/// 原先它是 SwiftUI 叶子 `CatalogRoomHeader`（`CatalogGridPages.swift`），
/// 这一版换成纯 AppKit，**像素一个不改**：`VStack(spacing: 8)`、按钮 32 高、
/// 胶囊左右内缩 20、圆键 32×32、副标题 13pt 次要色，都照搬。
///
/// 分类浏览页（「探索更多」的落点）多一排标签胶囊，也在这里：它与大标题是同一块
/// 页头（旧版 `CatalogTagBrowsePage` 里那两截就在同一个 `VStack` 里）。
@MainActor
final class CatalogRoomHeaderView: NSView, NSCollectionViewElement, TrackTableHeaderView {

    private typealias P = MusicMetrics.Page

    // MARK: 旧版 SwiftUI 里的那几个数（换骨架，一个不改）

    /// 按钮行高。旧版 `.frame(height: 32)` / `.frame(width: 32, height: 32)`。
    private static let actionHeight: CGFloat = 32
    /// 两枚键之间。旧版 `HStack(spacing: 8)`。
    private static let actionGap: CGFloat = 8
    /// 标题与按钮组之间的最小空档。旧版 `HStack(spacing: 16)` + `Spacer()`。
    private static let titleToActions: CGFloat = 16
    /// 胶囊键左右内缩。旧版 `.padding(.horizontal, 20)`。
    private static let capsuleInset: CGFloat = 20
    /// 标题行与副标题之间。旧版 `VStack(alignment: .leading, spacing: 8)`。
    private static let subtitleGap: CGFloat = 8
    /// 副标题字号。旧版 `.font(.system(size: 13))`。
    private static let subtitleSize: CGFloat = 13
    /// 大标题与标签排之间。旧版 `CatalogTagBrowsePage` 的 `tagRow.padding(.top, 14)`。
    private static let tagRowGap: CGFloat = 14
    /// 标签排上下各留 2。旧版 `HStack(...).padding(.vertical, 2)`。
    private static let tagRowPadding: CGFloat = 2

    // MARK: 视图

    private let titleLabel = CatalogCardKit.label(size: P.titleSize, weight: .bold)
    private let subtitleLabel = CatalogCardKit.label(
        size: CatalogRoomHeaderView.subtitleSize, color: .secondaryLabelColor)
    private let playButton = RoomActionButton(shape: .capsule)
    private let shuffleButton = RoomActionButton(shape: .circle)
    private let tagScroll = NSScrollView()
    private let tagStrip = TagStripView()

    // MARK: 状态（视图自己持有，不经 `@Published` 绕一圈——计划 §2 铁律 3）

    /// 页头自己让出的左右留白。
    /// - 集合视图里给 0：那一段的 `contentInsets` 已经把 34 让掉了；
    /// - 表格头部里给 `Page.leadingMargin`：头部视图铺满整表宽。
    var horizontalInset: CGFloat = 0 { didSet { needsLayout = true } }

    private var onPlay: (() -> Void)?
    private var onShuffle: (() -> Void)?
    private var onSelectTag: ((CatalogTagRef) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(titleLabel)
        addSubview(subtitleLabel)

        playButton.set(title: "播放", systemImage: "play.fill", tint: NSColor(Color.amberKey))
        playButton.target = self
        playButton.action = #selector(playClicked)
        playButton.isHidden = true
        addSubview(playButton)

        shuffleButton.set(title: nil, systemImage: "shuffle", tint: .labelColor)
        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleClicked)
        shuffleButton.toolTip = "随机播放"
        shuffleButton.setAccessibilityLabel("随机播放")
        shuffleButton.isHidden = true
        addSubview(shuffleButton)

        // 标签排：旧版是一条 `ScrollView(.horizontal, showsIndicators: false)`。
        tagScroll.drawsBackground = false
        tagScroll.hasHorizontalScroller = false
        tagScroll.hasVerticalScroller = false
        tagScroll.horizontalScrollElasticity = .allowed
        tagScroll.verticalScrollElasticity = .none
        tagScroll.automaticallyAdjustsContentInsets = false
        tagScroll.documentView = tagStrip
        tagScroll.isHidden = true
        addSubview(tagScroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 装数据

    /// 网格 / 曲目房间页：标题 + 可选的两枚键 + 可选副标题。
    func configure(title: String, subtitle: String?,
                   onPlay: (() -> Void)?, onShuffle: (() -> Void)?) {
        titleLabel.stringValue = title
        setSubtitle(subtitle)
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        playButton.isHidden = onPlay == nil
        shuffleButton.isHidden = onShuffle == nil
        tagScroll.isHidden = true
        tagStrip.setTags([], selected: nil, onSelect: nil)
        needsLayout = true
    }

    /// 分类浏览页：标题 + 一排可选标签胶囊。
    func configure(title: String, tags: [CatalogTagRef], selected: CatalogTagRef?,
                   onSelect: @escaping (CatalogTagRef) -> Void) {
        titleLabel.stringValue = title
        setSubtitle(nil)
        onPlay = nil
        onShuffle = nil
        playButton.isHidden = true
        shuffleButton.isHidden = true
        onSelectTag = onSelect
        tagScroll.isHidden = tags.isEmpty
        tagStrip.setTags(tags, selected: selected, onSelect: onSelect)
        needsLayout = true
    }

    /// 曲目房间页在拿到曲目之后才知道有几首、该不该摆两枚键。
    func update(subtitle: String?, hasActions: Bool) {
        setSubtitle(subtitle)
        playButton.isHidden = !hasActions || onPlay == nil
        shuffleButton.isHidden = !hasActions || onShuffle == nil
        needsLayout = true
    }

    private func setSubtitle(_ value: String?) {
        subtitleLabel.stringValue = value ?? ""
        subtitleLabel.isHidden = (value ?? "").isEmpty
    }

    @objc private func playClicked() { onPlay?() }
    @objc private func shuffleClicked() { onShuffle?() }

    // MARK: - 高度

    /// 高 = `.padding(.top, titleTop)` + max(大标题行高, 按钮 32)
    ///      + [副标题：8 + 行高] + [标签排：14 + 排高]。
    /// 两行的高度取裸标签的自然高（系统默认值，AGENTS「界面层」第 6 条）。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        var height = P.titleTop + max(ceil(titleLabel.fittingSize.height), Self.actionHeight)
        if !subtitleLabel.isHidden {
            height += Self.subtitleGap + ceil(subtitleLabel.fittingSize.height)
        }
        if !tagScroll.isHidden {
            height += Self.tagRowGap + tagStrip.fittingHeight + Self.tagRowPadding * 2
        }
        return ceil(height)
    }

    // MARK: - 排版

    override func layout() {
        super.layout()
        let inset = horizontalInset
        let labelInset = CatalogCardKit.labelInset
        let titleHeight = ceil(titleLabel.fittingSize.height)
        let rowHeight = max(titleHeight, Self.actionHeight)
        var y = P.titleTop

        // 两枚键靠右（旧版 `Spacer()`），与标题行垂直居中对齐。
        var titleRight = bounds.width - inset
        let actionY = y + (rowHeight - Self.actionHeight) / 2
        if !shuffleButton.isHidden {
            titleRight -= Self.actionHeight
            shuffleButton.frame = NSRect(x: titleRight, y: actionY,
                                         width: Self.actionHeight, height: Self.actionHeight)
            titleRight -= Self.actionGap
        }
        if !playButton.isHidden {
            let width = ceil(playButton.intrinsicContentSize.width)
            titleRight -= width
            playButton.frame = NSRect(x: titleRight, y: actionY,
                                      width: width, height: Self.actionHeight)
        }
        if !playButton.isHidden || !shuffleButton.isHidden {
            titleRight -= Self.titleToActions
        }

        titleLabel.frame = NSRect(x: inset - labelInset,
                                  y: y + (rowHeight - titleHeight) / 2,
                                  width: max(1, titleRight - inset + labelInset * 2),
                                  height: titleHeight)
        y += rowHeight

        if !subtitleLabel.isHidden {
            let height = ceil(subtitleLabel.fittingSize.height)
            y += Self.subtitleGap
            subtitleLabel.frame = NSRect(x: inset - labelInset, y: y,
                                         width: max(1, bounds.width - inset * 2 + labelInset * 2),
                                         height: height)
            y += height
        }

        if !tagScroll.isHidden {
            y += Self.tagRowGap
            let height = tagStrip.fittingHeight + Self.tagRowPadding * 2
            tagScroll.frame = NSRect(x: inset, y: y,
                                     width: max(1, bounds.width - inset * 2), height: height)
            tagStrip.verticalPadding = Self.tagRowPadding
            tagStrip.frame = NSRect(x: 0, y: 0, width: tagStrip.fittingWidth, height: height)
            tagStrip.needsLayout = true
        }
    }
}

// MARK: - 页头右端那两枚键

/// 胶囊「播放」与圆形「随机播放」。旧版：13pt semibold 前景色 + `Color.primary.opacity(0.065)`
/// 的底，胶囊左右内缩 20、圆键 32×32。
private final class RoomActionButton: NSButton {

    enum Shape { case capsule, circle }

    private let shape: Shape
    private var tint: NSColor = .labelColor
    private var label: String?

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(title: String?, systemImage: String, tint: NSColor) {
        self.tint = tint
        label = title
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = tint
        if let title {
            imagePosition = .imageLeading
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: tint])
            setAccessibilityLabel(title)
            toolTip = title
        } else {
            imagePosition = .imageOnly
            attributedTitle = NSAttributedString(string: "")
        }
        invalidateIntrinsicContentSize()
    }

    /// 圆键是定死的 32×32；胶囊按内容宽 + 左右各 20。
    override var intrinsicContentSize: NSSize {
        switch shape {
        case .circle:
            return NSSize(width: 32, height: 32)
        case .capsule:
            return NSSize(width: ceil(super.intrinsicContentSize.width) + 40, height: 32)
        }
    }

    /// 圆角只跟高度走；配色不在这里改——`attributedTitle` 会反过来让布局失效。
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// `Color.primary.opacity(0.065)` 的 AppKit 等价：`labelColor` 打 6.5% 透明。
    /// 语义色要在当前绘制外观里解析才拿得到正确的 CGColor。
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
            contentTintColor = tint
            if let label {
                attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: tint])
            }
        }
    }
}

// MARK: - 标签排

/// 分类浏览页顶部那排胶囊的文稿视图：一排横着摆，选中的填主题色、其余是灰底胶囊。
private final class TagStripView: NSView {

    /// 旧版 `HStack(spacing: 8)`。
    private static let gap: CGFloat = 8

    private var pills: [CatalogTagPill] = []
    private var onSelect: ((CatalogTagRef) -> Void)?

    var verticalPadding: CGFloat = 0

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { pills.first?.intrinsicContentSize.height ?? 0 }

    var fittingWidth: CGFloat {
        guard !pills.isEmpty else { return 0 }
        return pills.reduce(0) { $0 + ceil($1.intrinsicContentSize.width) }
            + Self.gap * CGFloat(pills.count - 1)
    }

    /// **标签数组没变就只改各枚胶囊的选中态**，一枚都不重建。
    ///
    /// 页头那句「换选中的标签：只改胶囊的样子，不重建整条排（横滚位置照旧）」的承诺
    /// 必须落在这里：段头是复用视图，换完标签之后它会被重新 dequeue、再走一遍
    /// `configure(title:tags:selected:onSelect:)`，于是「换标签」这条路上照样会回到这句。
    /// 从前这里一上来就 `removeFromSuperview()` 整排重建，横滚位置随之归零。
    func setTags(_ tags: [CatalogTagRef], selected: CatalogTagRef?,
                 onSelect: ((CatalogTagRef) -> Void)?) {
        self.onSelect = onSelect
        if pills.map(\.ref) == tags {
            for pill in pills { pill.isSelectedTag = pill.ref == selected }
            return
        }
        pills.forEach { $0.removeFromSuperview() }
        pills = tags.map { tag in
            let pill = CatalogTagPill(ref: tag)
            pill.isSelectedTag = tag == selected
            pill.target = self
            pill.action = #selector(pillClicked(_:))
            addSubview(pill)
            return pill
        }
        needsLayout = true
    }

    @objc private func pillClicked(_ sender: CatalogTagPill) {
        onSelect?(sender.ref)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let height = fittingHeight
        for pill in pills {
            let width = ceil(pill.intrinsicContentSize.width)
            pill.frame = NSRect(x: x, y: verticalPadding, width: width, height: height)
            x += width + Self.gap
        }
    }
}

/// 一枚标签胶囊。旧版：13pt 字，左右 12、上下 6；选中填 `Color.amberKey` + 白字，
/// 其余 `Color.primary.opacity(0.06)` + 主色字。
private final class CatalogTagPill: NSButton {

    /// 旧版 `.padding(.horizontal, 12)` / `.padding(.vertical, 6)`。
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 6

    let ref: CatalogTagRef

    var isSelectedTag = false {
        didSet {
            guard oldValue != isSelectedTag else { return }
            applyColors()
        }
    }

    init(ref: CatalogTagRef) {
        self.ref = ref
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .noImage
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityLabel(ref.name)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let text = NSAttributedString(string: ref.name,
                                      attributes: [.font: NSFont.systemFont(ofSize: 13)]).size()
        return NSSize(width: ceil(text.width) + Self.horizontalInset * 2,
                      height: ceil(text.height) + Self.verticalInset * 2)
    }

    /// 同 `RoomActionButton`：配色不在 `layout()` 里改。
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let color: NSColor = isSelectedTag ? .white : .labelColor
            attributedTitle = NSAttributedString(
                string: ref.name,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color])
            layer?.backgroundColor = isSelectedTag
                ? NSColor(Color.amberKey).cgColor
                : NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }
}
