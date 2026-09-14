import AppKit

/// 待播清单面板里的全部视图零件：曲目行、三种分区头、三种信息行 / 空状态行、顶部设置头。
///
/// 对照 playqueue 规格 §3.6–§3.9。Music 把这些全写在
/// 一个源文件 `Music/PlayQueueViewController.swift` 里（§3.0），Amber 这边拆成两份：
/// 零件在本文件，控制器 + 数据源在 `PlayQueueViewController.swift`。
///
/// 铁律 2：这些格子都在滚动容器里，**一个 `NSHostingView` 都不许有**——全是 AppKit。
/// 铁律 3：悬浮态由 `PlayQueueCell` 自己持有（`rollover`），不绕`@Published`。

// MARK: - 本地化文案

/// 全部实测自 `/System/Applications/Music.app/Contents/Resources/zh_CN.lproj/UserInterface.strings`
/// （2026-09-09 `plutil -convert json` 直读）。Amber 没有本地化表，直接用中文字面量，
/// key 写在注释里备查。
enum PlayQueueStrings {
    /// `PLAY_QUEUE_HISTORY_TITLE`
    static let historyTitle = "历史记录"
    /// `PLAY_QUEUE_MAIN_TITLE`
    static let upNextTitle = "队列"
    /// `PLAY_QUEUE_CONTINUE_PLAYING_TITLE`
    static let continuePlayingTitle = "继续播放"
    /// `PLAY_QUEUE_CONTINUE_PLAYING_SUBTITLE` = `"来自：@"`（`@` 是占位符）
    static func continuePlayingSubtitle(_ source: String) -> String { "来自：\(source)" }
    /// `PLAY_QUEUE_CLEAR_BUTTON_TITLE`
    static let clearButtonTitle = "清除"
    /// `PLAY_QUEUE_AUTOPLAY_TITLE`
    static let autoplayTitle = "自动连播"
    /// `PLAY_QUEUE_AUTOPLAY_SUBTITLE`
    static let autoplaySubtitle = "将播放类似歌曲"
    /// `PLAY_QUEUE_CROSSFADE_BUTTON_TITLE`
    static let crossfadeTitle = "交叉渐入渐出"
    /// `PLAY_QUEUE_AUTOMIX_BUTTON_TITLE`
    static let automixTitle = "自动过渡"
    /// `PLAY_QUEUE_REPEATING_LABEL` = ` 重复播放“%@”`
    static func repeating(_ source: String) -> String { "重复播放“\(source)”" }
    /// `PLAY_QUEUE_REPEATING_LABEL_NO_SOURCE`
    static let repeatingNoSource = "重复"
    /// `PLAY_QUEUE_MORE_ITEMS_LABEL` = ` 其他%@首歌曲`
    static func moreItems(_ localizedCount: String) -> String { "其他\(localizedCount)首歌曲" }
    /// `PLAY_QUEUE_EMPTY_LABEL`
    static let emptyLabel = "队列中无音乐。"
    /// `REMOVE_FROM_PLAY_QUEUE_SWIPE_ACTION`
    static let removeSwipeAction = "移除"
    /// `AX_PLAYQUEUE_CONTAINER`（面板根视图的 VoiceOver 名字）
    static let containerAXLabel = "播放队列"
    /// Music 用的是 `TRACK_TABLE_MORE_BUTTON_AX_LABEL`——这个 key 不在 Music.app 自己的
    /// 四张 strings 表里（应在某个私有框架里），没查到原文，按 Amber 别处的 ••• 取「更多」。[推]
    static let moreButtonAXLabel = "更多"
}

/// 曲目行副标题：照实机截图 `design-ref/ui-spec/pages/queue-panel.png` 是「艺人 — 专辑」
/// （「宇多田光 — 40代はいろいろ…」）。Music 绑的是 item 模型的 `subtitle`，
/// Amber 的 `Track` 没有这一项，就地拼一份。
func playQueueSubtitle(for track: Track) -> String {
    let album = track.albumName.trimmingCharacters(in: .whitespaces)
    guard !album.isEmpty else { return track.artistName }
    return "\(track.artistName) — \(album)"
}

// MARK: - 小工具

private extension NSTextField {
    /// 换行标签：Music 的 `wrappingLabelWithStyle(_:)`。
    static func amberWrappingLabel(_ string: String = "") -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.isSelectable = false
        field.isEditable = false
        field.drawsBackground = false
        field.isBezeled = false
        return field
    }
}

private func playQueueSymbol(_ name: String,
                             textStyle: NSFont.TextStyle = .title3) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(.init(textStyle: textStyle))
}

// MARK: - 分区头：历史 / 队列 / 继续播放

/// [实测] playqueue spec §3.6 `SingleLineHeaderCell`：一行标题（＋可选「来自：…」副行）
/// ＋右侧「清除」按钮，整条贴分区头底部 −8。
///
/// Music 的「清除」在**禁用时标题不变灰**（专门写了个 `NonDimmingButtonCell`）——
/// AppKit 的 `NSButtonCell` 没有公开开关，这里改成「自己画属性串标题」：
/// 禁用时只吃掉点击，颜色不动。
final class PlayQueueSingleLineHeaderCell: NSView {

    private typealias M = MusicMetrics.PlayQueue

    private let titleField = NSTextField(labelWithString: "")
    private let fromButton = NSButton()
    private let actionButton = NSButton()

    /// 「来自：xxx」被点。
    var fromBlock: (() -> Void)?
    /// 「清除」被点。
    var actionBlock: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // 标题：Music 是 `labelWithStyle(8)`。Amber 取语义档`.headline`
        // （macOS 上 13pt semibold），与实机截图的「继续播放」对得上。
        titleField.font = .preferredFont(forTextStyle: .headline)
        titleField.textColor = .labelColor
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 「来自：…」：Music 是 `namedTextStyle(11)` ＋ 右对齐 ＋ 尾部截断 ＋ 初始隐藏。
        fromButton.isBordered = false
        fromButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fromButton.alignment = .right
        fromButton.lineBreakMode = .byTruncatingTail
        fromButton.isHidden = true
        fromButton.target = self
        fromButton.action = #selector(doFromClicked)
        fromButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 「清除」：无边框、accent 色、初始隐藏。字号不设——用系统默认控件字号
        //（实机验收值：与标题同一档、不加粗）。
        actionButton.isBordered = false
        actionButton.contentTintColor = .controlAccentColor
        actionButton.title = PlayQueueStrings.clearButtonTitle
        actionButton.isHidden = true
        actionButton.target = self
        actionButton.action = #selector(doActionClicked)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleStack = NSStackView(views: [titleField, fromButton])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.distribution = .fill
        titleStack.spacing = M.headerTitleStackSpacing

        // Music 在「清除」外面还套了一层 `actionContainer`，为的是按钮隐藏时那一格
        // 仍然占位（横排栈里 hidden 的 arranged subview 会被抽掉）。照抄。
        let actionContainer = NSView()
        actionContainer.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionContainer.addSubview(actionButton)

        let totalStack = NSStackView(views: [titleStack, actionContainer])
        totalStack.orientation = .horizontal
        // [实测] `alignment = 10` = `NSLayoutConstraint.Attribute.centerY`。
        // 基线对齐那条是「清除」与标题之间单独一根约束（下面 firstBaseline）。
        totalStack.alignment = .centerY
        totalStack.distribution = .fill
        totalStack.spacing = M.headerStackSpacing
        totalStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(totalStack)

        NSLayoutConstraint.activate([
            totalStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            totalStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            totalStack.bottomAnchor.constraint(equalTo: bottomAnchor,
                                               constant: -M.headerStackBottomInset),
            actionButton.leadingAnchor.constraint(equalTo: actionContainer.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: actionContainer.trailingAnchor),
            actionButton.topAnchor.constraint(greaterThanOrEqualTo: actionContainer.topAnchor),
            actionButton.bottomAnchor.constraint(lessThanOrEqualTo: actionContainer.bottomAnchor),
            // [实测] §3.6「与标题基线对齐」。
            actionButton.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 一次装配。三段分区头共用这一个入口，参数按 §3.6「分区头装配」那一段给。
    func configure(title: String,
                   source: String?,
                   sourceIsActionable: Bool,
                   showsClear: Bool,
                   clearEnabled: Bool) {
        titleField.stringValue = title
        if let source, !source.isEmpty {
            fromButton.isHidden = false
            fromButton.title = PlayQueueStrings.continuePlayingSubtitle(source)
            // 不可点时只吃掉点击。颜色不跟着灰——Music 的 `NonDimmingButtonCell` 就是这个意思。
            fromButton.isEnabled = sourceIsActionable
            fromButton.attributedTitle = NSAttributedString(
                string: PlayQueueStrings.continuePlayingSubtitle(source),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor])
        } else {
            fromButton.isHidden = true
        }
        actionButton.isHidden = !showsClear
        // [实测] §3.6：「清除」的可用性绑 `continuePlayingItems` 非空。
        actionButton.isEnabled = clearEnabled
        actionButton.attributedTitle = NSAttributedString(
            string: PlayQueueStrings.clearButtonTitle,
            attributes: [.foregroundColor: NSColor.controlAccentColor])
    }

    @objc private func doFromClicked() { fromBlock?() }
    @objc private func doActionClicked() { actionBlock?() }
}

// MARK: - 分区头：自动连播

/// [实测] playqueue spec §3.6 `AutoplayHeaderCell`：∞ 图标 ＋「自动连播」，
/// 底下一行「将播放类似歌曲」。高度是**懒测**出来的（§3.5），所以这里不写死高。
final class PlayQueueAutoplayHeaderCell: NSTableCellView {

    private typealias M = MusicMetrics.PlayQueue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let titleField = NSTextField(labelWithString: "")
        titleField.font = .preferredFont(forTextStyle: .headline)
        titleField.textColor = .labelColor
        titleField.maximumNumberOfLines = 1
        // [实测] §3.6：标题是属性串——`infinity` 的`NSTextAttachment` ＋ 一个空格 ＋ 文案。
        let title = NSMutableAttributedString()
        if let symbol = playQueueSymbol("infinity") {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: PlayQueueStrings.autoplayTitle,
                                        attributes: [.foregroundColor: NSColor.labelColor]))
        titleField.attributedStringValue = title

        let secondaryField = NSTextField.amberWrappingLabel(PlayQueueStrings.autoplaySubtitle)
        secondaryField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        secondaryField.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleField, secondaryField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // [实测] §3.6：容器 `alignVerticallyWith(self, inset: 11)`
            stack.topAnchor.constraint(equalTo: topAnchor, constant: M.autoplayHeaderVerticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor,
                                          constant: -M.autoplayHeaderVerticalInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 信息行：重复播放

/// [实测] playqueue spec §3.7 `RepeatingInfoCell`：`repeat` 图标 ＋ 文案，整体居中。
final class PlayQueueRepeatingInfoCell: NSTableCellView {

    private let label = NSTextField.amberWrappingLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let centerer = NSStackView(views: [icon, label])
        centerer.orientation = .horizontal
        centerer.alignment = .centerY
        centerer.spacing = MusicMetrics.PlayQueue.repeatingInfoSpacing
        centerer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(centerer)
        NSLayoutConstraint.activate([
            centerer.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerer.centerYAnchor.constraint(equalTo: centerYAnchor),
            // [实测] §3.7：`separateTrailingEdgesByAtLeast(0, to: self)`
            centerer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            centerer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// [实测] §3.7 `labelString`：源非空 → 「重复播放“源”」，否则 →「重复」。
    func configure(source: String?) {
        if let source, !source.isEmpty {
            label.stringValue = PlayQueueStrings.repeating(source)
        } else {
            label.stringValue = PlayQueueStrings.repeatingNoSource
        }
    }
}

// MARK: - 信息行：其他 N 首

/// [实测] playqueue spec §3.7 `MoreCountInfoCell`。
///
/// Amber 的 `PlayQueueModel.continuePlayingMoreCount` 恒 0（没有「继续播放还剩多少首」
/// 这个概念），所以这一行实际不会出现——路径照留，将来模型给了数就能显形。
final class PlayQueueMoreCountInfoCell: NSTableCellView {

    private typealias M = MusicMetrics.PlayQueue

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: M.moreCountIconSize),
            icon.heightAnchor.constraint(equalToConstant: M.moreCountIconSize),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.moreCountIconLeading),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor,
                                           constant: M.moreCountTextSpacing),
            label.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -M.moreCountTextTrailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// [实测] §3.7：数字走 `NumberFormatter` 的`.decimal` 本地化后填进「其他%@首歌曲」。
    func configure(count: Int) {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: count),
                                                        number: .decimal)
        label.stringValue = PlayQueueStrings.moreItems(formatted)
    }
}

// MARK: - 空状态行

/// [实测] playqueue spec §3.7 `EmptyMessageCell`：居中的「队列中无音乐。」，左右内缩 20。
final class PlayQueueEmptyMessageCell: NSTableCellView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let label = NSTextField.amberWrappingLabel(PlayQueueStrings.emptyLabel)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let inset = MusicMetrics.PlayQueue.emptyMessageHorizontalInset
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 曲目行

/// 约束钉的是 **alignment rect**，不是 frame——而 `NSButton` 的
/// `alignmentRectInsets` 在纵向是**负数**（实测`t:-2 / b:-2.5`，横向是 0），
/// 于是 `pinSize(28 × 28)` 这种写法量出来是`28 × 23.5`：宽对、高少了 4.5。
/// （这就是 §3.8 那颗 ••• 上一轮实测 `[1423, 102, 28, 23.5]` 的原因，
/// 不是「高度约束没写」，也不是被固有高压过去——两条约束都是 required 且都活着。）
///
/// 把 insets 归零，约束钉的就是 frame 本身，28×28 落地，点击热区也跟着回到 28×28。
final class PlayQueueFlushButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// [实测] playqueue spec §3.8 `PlayQueueCell`：34 封面 ＋ 两行文字 ＋ ••• 按钮。
///
/// 封面复用目录页那张 `CatalogArtworkView`（`CatalogCardItems.swift`）——不新写一个。
final class PlayQueueCell: NSTableCellView {

    private typealias M = MusicMetrics.PlayQueue

    private let artwork = CatalogArtworkView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private let secondaryLine = NSTextField(labelWithString: "")
    private let moreButton = PlayQueueFlushButton()
    private lazy var boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

    private(set) var item: PlayQueueItem?
    /// ••• 被点：控制器接过去弹 `model.actionMenu(for:)` 那份菜单。
    var onMoreClicked: ((PlayQueueCell) -> Void)?

    /// [实测] §3.8 `rollover` 的 didSet：只换 ••• 的着色，行底色不动。
    /// 铁律 3：这个状态由视图自己持有，不经 `@Published`。
    var rollover = false {
        didSet {
            guard rollover != oldValue else { return }
            moreButton.contentTintColor = rollover ? .controlAccentColor : .secondaryLabelColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        artwork.cornerRadius = 4
        artwork.hoverScrimOpacity = 0
        artwork.translatesAutoresizingMaskIntoConstraints = false

        titleField.textColor = .labelColor
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        // [实测] §3.8：两个文本都 `setHorizontalContentSizeConstraintActive: false`
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField = titleField

        secondaryLine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        secondaryLine.textColor = .secondaryLabelColor
        secondaryLine.maximumNumberOfLines = 1
        secondaryLine.lineBreakMode = .byTruncatingTail
        secondaryLine.translatesAutoresizingMaskIntoConstraints = false
        secondaryLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLine.setContentHuggingPriority(.defaultLow, for: .horizontal)

        moreButton.isBordered = false
        moreButton.showsBorderOnlyWhileMouseInside = true
        moreButton.image = playQueueSymbol("ellipsis")
        moreButton.imagePosition = .imageOnly
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.setAccessibilityLabel(PlayQueueStrings.moreButtonAXLabel)
        moreButton.target = self
        moreButton.action = #selector(doActionClicked)
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(artwork)
        addSubview(titleField)
        addSubview(secondaryLine)
        addSubview(moreButton)

        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: M.artworkSize),
            artwork.heightAnchor.constraint(equalToConstant: M.artworkSize),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: artwork.trailingAnchor,
                                                constant: M.artworkToTitleSpacing),
            // [实测] §3.8 照抄这条：**标题底边贴格子中线**，副行挂在标题下面。
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor),

            secondaryLine.topAnchor.constraint(equalTo: titleField.bottomAnchor),
            secondaryLine.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            secondaryLine.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            moreButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -M.moreButtonTrailingInset),
            // [实测] §3.8 `moreButton.pinSize(28 × 28)`。按钮是`PlayQueueFlushButton`
            // （`alignmentRectInsets` 归零），所以这两条钉的就是 frame，量出来 28×28。
            moreButton.widthAnchor.constraint(equalToConstant: M.moreButtonSize),
            moreButton.heightAnchor.constraint(equalToConstant: M.moreButtonSize),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: PlayQueueItem) {
        self.item = item
        let track = item.track
        titleField.attributedStringValue = attributedTitle(for: track)
        secondaryLine.stringValue = playQueueSubtitle(for: track)
        artwork.setArtwork(url: track.artworkURL, points: M.artworkSize)
        rollover = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        item = nil
        rollover = false
        artwork.prepareForReuse()
    }

    /// [实测] §3.8 `attributedTitle`：尾部截断 ＋ 关掉「为截断做紧排」；
    /// 有分级串（Amber 这边对应 explicit 标记）就在标题后面补一个粗体段。
    /// Amber 的 `Track` 目前没有分级字段，整段跳过——留着是为了将来加上时不用改结构。
    private func attributedTitle(for track: Track) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.allowsDefaultTighteningForTruncation = false
        let result = NSMutableAttributedString(
            string: track.title,
            attributes: [.paragraphStyle: paragraph,
                         .foregroundColor: NSColor.labelColor])
        if let rating = contentRatingString(for: track), !rating.isEmpty {
            result.append(NSAttributedString(string: " "))
            result.append(NSAttributedString(
                string: rating,
                attributes: [.paragraphStyle: paragraph,
                             .font: boldFont,
                             .foregroundColor: NSColor.labelColor]))
        }
        return result
    }

    /// Amber 侧还没有分级信息，恒 nil。
    private func contentRatingString(for track: Track) -> String? { nil }

    @objc private func doActionClicked() { onMoreClicked?(self) }

    /// 控制器把 ••• 的屏幕位置要回去弹菜单用。
    var moreButtonAnchor: NSButton { moreButton }
}

// MARK: - 顶部设置头

/// [实测] playqueue spec §3.9 `SettingsExtraHeader`：「自动连播」＋「混音」两颗按钮。
///
/// 窄了就把文字丢掉只剩图标（`setFrameSize` 那一档）——实机截图里 258 宽的面板
/// 正是这一档，两颗都只剩图标。
final class PlayQueueSettingsExtraHeader: NSView {

    private typealias M = MusicMetrics.PlayQueue

    private let backdrop = NSVisualEffectView()
    private let autoplayButton = NSButton()
    private let mixingButton = NSButton()
    private let stack: NSStackView
    private var widestButtonWidth: CGFloat = 0

    /// [实测] §3.9：高度变了就回调，控制器拿它去更新 scroller 的 contentInsets（§3.2 的 pocket）。
    var heightChangedBlock: ((CGFloat) -> Void)?
    var onAutoplayToggled: ((Bool) -> Void)?
    var onMixingToggled: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [autoplayButton, mixingButton])
        super.init(frame: frameRect)

        // 面板列本身坐在窗口玻璃上（RootViewController 那层），素面底衬会透出下面滚过去的行，
        // 所以顶部这块 pocket 自带一层 `.headerView` 材质。Music 走的是 Music 的桌面界面层的
        // pocket 机制，底衬由那套自己给。
        backdrop.material = .headerView
        backdrop.blendingMode = .withinWindow
        backdrop.state = .followsWindowActiveState
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        for button in [autoplayButton, mixingButton] {
            // [实测] §3.9：两颗按钮同一套配置。
            button.setButtonType(.pushOnPushOff)
            button.isBordered = true
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        autoplayButton.title = PlayQueueStrings.autoplayTitle
        autoplayButton.image = playQueueSymbol("infinity")
        autoplayButton.toolTip = PlayQueueStrings.autoplayTitle
        autoplayButton.action = #selector(doAutoplayClicked)

        // Music 用的是 App 自带 symbol `"Crossfade"` / `"automix"`（`imageWithSymbolName:`，
        // 不是 SF Symbol）。Amber 没有那两张图，统一用 SF Symbol `circlebadge.2.fill`
        //（Music 那两张的形状本来就与它同源），标题照旧随类型翻。
        mixingButton.image = playQueueSymbol("circlebadge.2.fill")
        mixingButton.title = PlayQueueStrings.crossfadeTitle
        mixingButton.toolTip = PlayQueueStrings.crossfadeTitle
        mixingButton.action = #selector(doMixingClicked)

        stack.orientation = .horizontal
        stack.alignment = .top
        stack.distribution = .fill
        stack.spacing = M.settingsSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // [实测] §3.9：两颗等宽，优先级 490（`.defaultHigh - 10`，Music 是现算出来的）。
        let equalWidth = autoplayButton.widthAnchor.constraint(equalTo: mixingButton.widthAnchor)
        equalWidth.priority = M.settingsEqualWidthPriority

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.settingsMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.settingsMargin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: M.settingsTopInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            equalWidth,
        ])

        // [实测] §3.9：`widestButtonWidth` 在 init 末尾算：混音按钮摆两种标题各量一次，
        // 与自动连播按钮取三者最大。
        widestButtonWidth = measureWidestButtonWidth()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func measureWidestButtonWidth() -> CGFloat {
        let saved = mixingButton.title
        var widest = autoplayButton.intrinsicContentSize.width
        for title in [PlayQueueStrings.crossfadeTitle, PlayQueueStrings.automixTitle] {
            mixingButton.title = title
            widest = max(widest, mixingButton.intrinsicContentSize.width)
        }
        mixingButton.title = saved
        return widest
    }

    /// 控制器在模型变化时推一次。
    func update(autoplayAvailable: Bool,
                autoplayEnabled: Bool,
                mixingAvailable: Bool,
                mixingEnabled: Bool,
                mixingType: PlayQueueMixingType) {
        // [实测] §3.9：`autoplay.enabled` 绑`autoplayAvailable`——Amber 恒 false，
        // 于是按钮照常画出来、但是禁用的。
        autoplayButton.isEnabled = autoplayAvailable
        autoplayButton.state = (autoplayAvailable && autoplayEnabled) ? .on : .off
        autoplayButton.contentTintColor = autoplayEnabled ? .controlAccentColor : nil

        // [实测] §3.9：`mixing.hidden` 绑`!mixingAvailable`。Amber 的`mixingAvailable` 恒 true。
        mixingButton.isHidden = !mixingAvailable
        let title = mixingType == .crossfade ? PlayQueueStrings.crossfadeTitle
                                             : PlayQueueStrings.automixTitle
        if mixingButton.title != title {
            mixingButton.title = title
            mixingButton.toolTip = title
            widestButtonWidth = measureWidestButtonWidth()
            updateButtonAppearance(forWidth: frame.width)
        }
        mixingButton.state = mixingEnabled ? .on : .off
        mixingButton.contentTintColor = mixingEnabled ? .controlAccentColor : nil
    }

    /// [实测] §3.9 `setFrameSize:` 两件事：窄了换外观、高度变了报回去。
    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if abs(newSize.width - old.width) > 0.5 { updateButtonAppearance(forWidth: newSize.width) }
        if abs(newSize.height - old.height) > 0.5 { heightChangedBlock?(newSize.height) }
    }

    private func updateButtonAppearance(forWidth width: CGFloat) {
        let count = CGFloat(max(1, stack.arrangedSubviews.count))
        // [实测] §3.9：`(新宽 − kMargin − kMargin − kSpacing) / 按钮数`
        let available = (width - M.settingsMargin * 2 - M.settingsSpacing) / count
        let position: NSControl.ImagePosition = available >= widestButtonWidth ? .imageLeading
                                                                              : .imageOnly
        for button in [autoplayButton, mixingButton] where button.imagePosition != position {
            button.imagePosition = position
        }
    }

    /// 给测试看的：当前这一档外观（图＋字 / 只剩图标）。
    var currentImagePosition: NSControl.ImagePosition { autoplayButton.imagePosition }
    /// 给测试看的：三者取最大之后的那个宽度门槛。
    var widestButtonWidthForTesting: CGFloat { widestButtonWidth }

    @objc private func doAutoplayClicked() {
        onAutoplayToggled?(autoplayButton.state == .on)
    }

    @objc private func doMixingClicked() {
        onMixingToggled?(mixingButton.state == .on)
    }
}
