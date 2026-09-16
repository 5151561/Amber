import AppKit
import SwiftUI

// MARK: - 详情页头部（AppKit）—— 计划阶段 4 批 B
//
// 旧版（`DetailViews.swift` 的`PlaylistMusicHeader` / `AlbumMusicHeader`）为了判横竖排
// 得在外面套一层 `GeometryReader` 量**容器**宽——量头部自己会形成
// 「量宽 → 改状态 → 换排布 → 再量宽」的回环，SwiftUI 的多轮试探性排布会让它反复翻转，
// 主线程卡死在排布里（「点开歌单转圈不动」就是这么来的）。
//
// AppKit 侧这件事根本不存在：表格的 `heightOfRow` 拿**表宽**问头部一次
// `fittingHeight(forWidth:)`，头部再在`layout()` 里按同一个`bounds.width` 排一遍。
// 判据是入参，不是自己的排布结果，所以不存状态、不回环（计划 §1.1 那条病就此消掉）。
//
// 像素规格一律照旧版逐条搬（计划 §2 铁律 5「换骨架，像素一个不改」），
// 每个数的 [AX]/[PX]/[实测] 出处都在 `MusicMetrics.Detail` 里。
// 两处顺着 Music 的实测收敛了旧版的自由流动：
// 1. **操作键行底边贴封面底边**（[AX] 专辑/歌单同为按钮行 285…323、封面 52…322）。
//    旧版歌单头是 `Spacer(minLength: 8)` 顶到底，专辑头是自然流动恰好落在那里；
//    这里统一写成 `max(文字块底 + 间距, 封面高 − 38)`：文字短就贴封面底，
//    简介展开撑高了就顺势下移，两种情形与旧版都一致。
// 2. 星级与「无损」两枚是 SwiftUI 叶子（`RatingStars` / `LosslessBadge`），
//    按铁律 2 装进**定尺寸**的 `NSHostingView` 槽（星级本身是可点的控件）。

// MARK: - 基类

/// 详情页头部的公共壳：持有 `appState`、按宽度算高、简介展开时通知表格重问行高。
@MainActor
class DetailHeaderView: NSView {

    let appState: AppState
    /// 简介展开 / 收起后调一次，页面据此 `noteHeightOfRows(withIndexesChanged:)`。
    var onHeightChanged: (() -> Void)?

    /// 头部按「从上往下」排：与 `MusicMetrics.Detail` 里那串 [AX] 数（窗口坐标、原点左上）
    /// 直接对得上，不用每处再翻一次 y 轴。
    override var isFlipped: Bool { true }

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 给定宽度下这块头部的高度。**只看入参**，不看自己现在多宽。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat { 0 }

    /// 资料库状态（喜爱 / 入库 / 评分）变了，重画依赖它的那几件。
    func refreshLibraryState() {}
}

// MARK: - 操作键

/// 头部那三枚键：圆 38 / 胶囊 132×38 / 圆 38。
/// 底色 `labelColor` 的一档浓度（歌单 8%、专辑 6.5%，与旧版`Color.primary.opacity(…)` 同值——
/// SwiftUI 的 `.primary` 就是`labelColor`），图标与文字品牌红。
final class DetailActionButton: NSButton {

    private let backgroundOpacity: CGFloat

    init(symbol: String?, title: String?, width: CGFloat, height: CGFloat,
         backgroundOpacity: CGFloat, iconSize: CGFloat, titleSize: CGFloat) {
        self.backgroundOpacity = backgroundOpacity
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        isBordered = false
        bezelStyle = .shadowlessSquare
        imageScaling = .scaleNone
        contentTintColor = NSColor(Color.amberKey)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold))
        }
        if let title {
            imagePosition = symbol == nil ? .noImage : .imageLeading
            // `imageHugsTitle` 不开的话，AppKit 把图钉在按钮**前沿**、标题在剩下的地方居中
            // （NSButton 文档：设为 true 才是「图紧挨着标题」而不是贴按钮边）。
            // Music 的「▶ 播放」是图与字连成一组一起居中、中间约 3pt
            // （[PX] playlist-detail.png：胶囊 132 宽，墨迹 42→87.5，正好对称）。
            imageHugsTitle = true
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: titleSize, weight: .semibold),
                             .foregroundColor: NSColor(Color.amberKey)])
        } else {
            imagePosition = .imageOnly
            self.title = ""
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(backgroundOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
        super.draw(dirtyRect)
    }

    /// 语义色随外观变，重画一次。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        contentTintColor = NSColor(Color.amberKey)
        if let attributedTitle = attributedTitle.mutableCopy() as? NSMutableAttributedString {
            attributedTitle.addAttribute(.foregroundColor, value: NSColor(Color.amberKey),
                                         range: NSRange(location: 0, length: attributedTitle.length))
            self.attributedTitle = attributedTitle
        }
        needsDisplay = true
    }
}

// MARK: - 可展开简介

/// 旧版 `ExpandableText` 的 AppKit 版：折行到`lineLimit`，末行右端压一枚「更多」，
/// 展开后正文全显、底下再摆一枚「收起」。
///
/// 是否被截断用 `NSAttributedString.boundingRect` 量全文高、除以行高得行数再和`lineLimit` 比
/// （旧版是拿一份不限行数的隐形副本 + `PreferenceKey` 回传高度，同一条判据）。
final class ExpandableTextView: NSView {

    private let text: String
    private let font: NSFont
    private let actionFont: NSFont
    private let lineSpacing: CGFloat
    private let lineLimit: Int

    private let field = NSTextField(wrappingLabelWithString: "")
    private let moreButton = NSButton()
    private let lessButton = NSButton()

    private(set) var expanded = false
    /// 展开 / 收起后调；宿主头部据此重算高度。
    var onToggle: (() -> Void)?
    /// 给了这一条，「更多」就**不在原地展开**，而是把这一下交给宿主去弹介绍面板
    /// （专辑页头就是这么接的，见 `AlbumHeaderView.presentAbout()`）。
    /// 歌单页头不给，照旧就地展开。
    var onMore: (() -> Void)?

    override var isFlipped: Bool { true }

    init(text: String, fontSize: CGFloat, actionFontSize: CGFloat,
         lineSpacing: CGFloat, lineLimit: Int) {
        self.text = text
        self.font = .systemFont(ofSize: fontSize)
        self.actionFont = .systemFont(ofSize: actionFontSize, weight: .semibold)
        self.lineSpacing = lineSpacing
        self.lineLimit = lineLimit
        super.init(frame: .zero)

        field.font = font
        field.textColor = .secondaryLabelColor
        field.attributedStringValue = attributed(truncating: true)
        field.maximumNumberOfLines = lineLimit
        field.cell?.truncatesLastVisibleLine = true
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)

        for (button, title, action) in [(moreButton, "更多", #selector(expand)),
                                        (lessButton, "收起", #selector(collapse))] {
            button.isBordered = false
            button.bezelStyle = .shadowlessSquare
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: actionFont, .foregroundColor: NSColor.labelColor])
            button.target = self
            button.action = action
            button.sizeToFit()
            addSubview(button)
        }
        lessButton.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 度量

    /// 一行的行高（含 `lineSpacing`）。`NSParagraphStyle.lineSpacing` 与 SwiftUI 的
    /// `.lineSpacing()` 同义：都是加在行与行之间。
    private var lineHeight: CGFloat {
        ceil(font.ascender - font.descender + font.leading) + lineSpacing
    }

    private func attributed(truncating: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = truncating ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(string: text,
                                  attributes: [.font: font,
                                               .paragraphStyle: style,
                                               .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func lineCount(forWidth width: CGFloat) -> Int {
        guard width > 1 else { return 1 }
        let box = attributed(truncating: false).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(1, Int(ceil(box.height / lineHeight - 0.01)))
    }

    /// 「收起」那一行与正文之间的留白（旧版 `.padding(.top, 4)`）。
    private static let lessTop: CGFloat = 4

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let lines = lineCount(forWidth: width)
        if expanded {
            return lineHeight * CGFloat(lines) + Self.lessTop + ceil(lessButton.fittingSize.height)
        }
        return lineHeight * CGFloat(min(lines, lineLimit))
    }

    override func layout() {
        super.layout()
        let lines = lineCount(forWidth: bounds.width)
        let shown = expanded ? lines : min(lines, lineLimit)
        let textHeight = lineHeight * CGFloat(shown)
        field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: textHeight)

        // 「更多」压在末行右端，不另起一行（Music 就是这么排的）。
        let moreSize = moreButton.fittingSize
        moreButton.isHidden = expanded || lines <= lineLimit
        moreButton.frame = NSRect(x: bounds.width - ceil(moreSize.width),
                                  y: textHeight - ceil(moreSize.height),
                                  width: ceil(moreSize.width), height: ceil(moreSize.height))

        let lessSize = lessButton.fittingSize
        lessButton.isHidden = !expanded
        lessButton.frame = NSRect(x: 0, y: textHeight + Self.lessTop,
                                  width: ceil(lessSize.width), height: ceil(lessSize.height))
    }

    // MARK: 展开态（自己持有，不经 @Published —— 铁律 3）

    @objc private func expand() {
        if let onMore {
            onMore()
            return
        }
        setExpanded(true)
    }
    @objc private func collapse() { setExpanded(false) }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        field.attributedStringValue = attributed(truncating: !value)
        field.maximumNumberOfLines = value ? 0 : lineLimit
        needsLayout = true
        onToggle?()
    }
}

// MARK: - 封面

/// 封面 + 阴影。`CatalogArtworkView` 自己`masksToBounds`，阴影只能挂在外面这层。
/// 旧版：`.shadow(color: .black.opacity(0.28), radius: 12, y: 6)`（AppKit 的 y 轴向上，取负）。
final class DetailArtworkView: NSView {

    let artwork = CatalogArtworkView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.masksToBounds = false
        artwork.cornerRadius = MusicMetrics.Detail.artworkCornerRadius
        artwork.hoverScrimOpacity = 0
        addSubview(artwork)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        artwork.frame = bounds
    }
}

// MARK: - 歌单 / 榜单头部

/// 歌单头右下角第三枚键：目录歌单是「添加到资料库 / 下载」，
/// 资料库里的播放列表换成 ••• 菜单（`PlaylistHeaderView.collectionActions()` 那份`MenuSpec`，
/// 与页头右键、标题栏那颗 ••• 同一个项集）。
enum PlaylistHeaderAction {
    case addToLibrary
    case libraryMenu(LibraryPlaylist)
    /// 心水歌曲那一页：曲目本来就在资料库里，第三枚键只剩下载（[AX] 「下载」38×38）。
    case download
}

/// 「心水歌曲」的封面：Music 不给这一页封面地址，是一张画出来的卡。
///
/// [PX] `design-ref/ui-spec/pages/favorite-songs.png` 逐像素量（封面 270）：
/// 底色 rgb(237,238,240) 纯色不带渐变；红星宽 144（0.533×边长）、水平居中，
/// 垂直方向上留白 64.5 / 下留白 68.5 —— 比几何中心高 2。
/// 卡在深色外观下同样是浅底浅卡（截图就是深色模式拍的），所以两色都写死。
enum FavoriteSongsArtwork {

    private static let background = NSColor(srgbRed: 237 / 255, green: 238 / 255,
                                            blue: 240 / 255, alpha: 1)
    /// 浅底上用 `Color.amberKey` 的浅色档 #FA233B（卡不随外观变，红也不跟着变）。
    private static let star = NSColor(srgbRed: 0xFA / 255, green: 0x23 / 255,
                                      blue: 0x3B / 255, alpha: 1)
    private static let starWidthRatio: CGFloat = 144 / 270
    private static let starRiseRatio: CGFloat = 2 / 270

    static func image(size: CGFloat = MusicMetrics.Detail.playlistArtworkSize) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            background.setFill()
            rect.fill()
            guard let symbol = NSImage(systemSymbolName: "star.fill",
                                       accessibilityDescription: "心水歌曲")?
                .withSymbolConfiguration(.init(pointSize: size * starWidthRatio,
                                               weight: .regular)
                    .applying(.init(paletteColors: [star])))
            else { return true }
            let width = size * starWidthRatio
            let height = width * symbol.size.height / symbol.size.width
            symbol.draw(in: NSRect(x: (size - width) / 2,
                                   y: (size - height) / 2 + size * starRiseRatio,
                                   width: width, height: height))
            return true
        }
    }
}

/// 歌单与榜单头部：封面 270（竖排 200）+ 标题 26 bold / 策展人 18 medium /
/// 更新说明 12 / 可展开简介 + 操作键行（底边贴封面底边）。
@MainActor
final class PlaylistHeaderView: DetailHeaderView {

    private typealias M = MusicMetrics.Detail

    struct Content {
        var playlist: Playlist
        var tracks: [Track]
        var artworkURL: String?
        /// 画出来的封面（心水歌曲的白底红星卡）。给了就压过 `artworkURL`。
        var artworkImage: NSImage?
        var title: String
        var curator: String
        var description: String?
        var callout: String?
        var isEmpty: Bool
        /// 标题后面跟一颗小红星（[AX] 心水歌曲页的标题是「心水歌曲 ￼」）。
        var titleStar: Bool = false
        var action: PlaylistHeaderAction = .addToLibrary
    }

    private var content: Content
    /// 播放 / 随机播放。换一批曲目时页面会重挂（闭包捕获的是那一批）。
    var play: () -> Void
    var shuffle: () -> Void

    private let artworkView = DetailArtworkView()
    private let titleLabel = CatalogCardKit.label(size: M.playlistTitleSize, weight: .bold,
                                                  color: .labelColor, lines: 2)
    private let curatorLabel = CatalogCardKit.label(size: M.playlistCuratorSize, weight: .medium,
                                                    color: .secondaryLabelColor, lines: 1)
    private let calloutLabel = CatalogCardKit.label(size: M.playlistMetaSize,
                                                    color: .secondaryLabelColor, lines: 1)
    private var descriptionView: ExpandableTextView?
    /// 头部就这三枚键，**没有独立的分享键**。
    ///
    /// [AX] `design-ref/ui-spec/pages/playlist-detail.json` 实测：随机播放 38×38 @543.5、
    /// 播放 132×38 @587.5、添加到资料库 38×38 @725.5——到此为止。
    /// [实测] macOS 27（26A5425a）基线 §6.0 末尾 / §6.7 与之吻合：
    /// `-[PlaylistHeaderModel hasShareMenu]` 是——**恒 NO**。
    ///
    /// **旧 spec 那句「`storeID.length != 0` 时出现分享」记串了类**，那是
    /// `-[ITPrettyPlaylistModel hasShareMenu]` 的实现——
    /// 别照着它在这里加第四枚分享键。分享只作为 ⋯ 菜单里的**条件子项**存在
    /// （`actionMenuFromSender:` 里返回 **0** 才插那一段，注意极性），
    /// Amber 对应的是 `CollectionActions.shareURL`：没有`webShareURL` 就不摆，`MenuSpec` 把空段并掉。
    /// （标题栏右端那颗「共享」是另一回事，[AX] 确实有，由页控制器接。）
    private let shuffleButton: DetailActionButton
    private let playButton: DetailActionButton
    private let trailingButton: DetailActionButton
    private var playlistAction: LibraryDownloadAction = .addToLibrary

    /// 旧版 `Color.primary.opacity(0.08)`（`.primary` 即`labelColor`）。
    private static let backgroundOpacity: CGFloat = 0.08
    /// 旧版 `HStack(spacing: 8)`
    private static let actionSpacing: CGFloat = 8
    /// 旧版 `Spacer(minLength: 8)`：文字块与操作键行之间至少这么多。
    private static let actionsMinTop: CGFloat = 8
    /// 旧版 `Image(systemName:).font(.system(size: 15, weight: .semibold))`
    private static let iconSize: CGFloat = 15
    private static let playLabelSize: CGFloat = 14

    init(appState: AppState, content: Content,
         play: @escaping () -> Void, shuffle: @escaping () -> Void) {
        self.content = content
        self.play = play
        self.shuffle = shuffle
        shuffleButton = DetailActionButton(symbol: "shuffle", title: nil,
                                           width: M.playlistActionSize, height: M.playlistActionSize,
                                           backgroundOpacity: Self.backgroundOpacity,
                                           iconSize: Self.iconSize, titleSize: 0)
        playButton = DetailActionButton(symbol: "play.fill", title: "播放",
                                        width: M.playlistPlayWidth, height: M.playlistActionSize,
                                        backgroundOpacity: Self.backgroundOpacity,
                                        iconSize: Self.playLabelSize,
                                        titleSize: Self.playLabelSize)
        trailingButton = DetailActionButton(symbol: "plus", title: nil,
                                            width: M.playlistActionSize, height: M.playlistActionSize,
                                            backgroundOpacity: Self.backgroundOpacity,
                                            iconSize: Self.iconSize, titleSize: 0)
        super.init(appState: appState)

        addSubview(artworkView)
        for label in [titleLabel, curatorLabel, calloutLabel] { addSubview(label) }
        for button in [shuffleButton, playButton, trailingButton] { addSubview(button) }

        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleTapped)
        shuffleButton.toolTip = "随机播放"
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.toolTip = "播放"

        apply(content)
    }

    // MARK: 内容

    func apply(_ content: Content) {
        self.content = content
        if let image = content.artworkImage {
            artworkView.artwork.setLocalArtwork(image)
        } else {
            artworkView.artwork.setArtwork(url: content.artworkURL, points: ArtworkSize.header)
        }
        if content.titleStar {
            titleLabel.attributedStringValue = Self.titleWithStar(content.title)
        } else {
            titleLabel.stringValue = content.title
        }
        curatorLabel.stringValue = content.curator
        curatorLabel.isHidden = content.curator.isEmpty
        calloutLabel.stringValue = content.callout ?? ""
        calloutLabel.isHidden = (content.callout ?? "").isEmpty

        descriptionView?.removeFromSuperview()
        descriptionView = nil
        if let description = content.description, !description.isEmpty {
            let view = ExpandableTextView(text: description,
                                          fontSize: M.playlistMetaSize,
                                          actionFontSize: M.playlistMetaSize,
                                          lineSpacing: Self.descriptionLineSpacing,
                                          lineLimit: Self.descriptionLines)
            view.onToggle = { [weak self] in
                self?.needsLayout = true
                self?.onHeightChanged?()
            }
            addSubview(view)
            descriptionView = view
        }

        // 播放 / 随机：判据是「有没有条目」，与 `playButtonState` 一致。
        // [实测] macOS 27（26A5425a）基线 §6.0/§6.1，`-[PlaylistHeaderModel playButtonState]`
        // `playlist == nil → 3`，否则条目数`== 0 ? 3 : 0`——
        // **值域只有 {0,3}，3 = 不可用**。随机键与播放键读的是同一个 state（§6.0 表前两行），
        // 所以这里一起判。
        //
        // **这不是播放/暂停两态**：它纯粹是可用性，不反映运行态。曲目行那套 1/2/3
        // 三态（§8.2 `PlaylistItemModel`）是另一回事，别日后拿这一枚当播放态图标开关使。
        // 第三枚键不在这个循环里——它按来源各有各的判据，见 `refreshLibraryState()`。
        for button in [shuffleButton, playButton] {
            button.isEnabled = !content.isEmpty
        }
        refreshLibraryState()
        needsLayout = true
    }

    /// 旧版 `ExpandableText(lineSpacing: 3, lineLimit: 2)`
    private static let descriptionLineSpacing: CGFloat = 3
    private static let descriptionLines = 2

    /// [PX] 心水歌曲页标题后那颗小红星约 13 宽，跟在标题后空一格。
    private static let titleStarSize: CGFloat = 13

    private static func titleWithStar(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: title + " ",
            attributes: [.font: NSFont.systemFont(ofSize: M.playlistTitleSize, weight: .bold),
                         .foregroundColor: NSColor.labelColor])
        guard let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: titleStarSize, weight: .regular)
                .applying(.init(paletteColors: [NSColor(Color.amberKey)])))
        else { return text }
        let attachment = NSTextAttachment()
        attachment.image = symbol
        text.append(NSAttributedString(attachment: attachment))
        return text
    }

    /// 第三枚键的形态与使能。
    ///
    /// **下载这一枚在 Music 里的实现**（[实测] macOS 27（26A5425a）基线 §6.0/§6.2，记着备查，
    /// Amber 不照抄）：
    /// - `downloadState` 遍历条目建数组问
    ///   `+[NSObject(ITNSMessageReceiverUtils) downloadStateForPlaylistItemList:]`，
    ///   值域 **{1,3,7}**（1=有条目在下载队列、3=下载中、7=空或无事可做）；
    ///   **`== 3` 时才起 0.125s（8Hz）NSTimer 轮询**，否则 invalidate。
    /// - 进度是**加权聚合**：`(完成数 + Σ单条分数) / 总条目数`（单条分数取`bytesReceived/bytesTotal`）。
    /// - `doDownloadAction`**先再读一次当前下载态、再切**——
    ///   是个「读态再切」的开关，不是单向下载。
    ///
    /// Amber 这边是**事件驱动**：`DownloadStore` 的`@Published` 一变就重刷这里，
    /// 不需要那条 8Hz 轮询，也就没有对应的 NSTimer。`[Amber]`
    /// 进度环本批不做（Amber 现在只换图标，没有环）。
    override func refreshLibraryState() {
        let symbol: String
        switch content.action {
        case .addToLibrary:
            let inLibrary = appState.library.isPlaylistInLibrary(content.playlist)
            playlistAction = appState.downloads.action(inLibrary: inLibrary, tracks: content.tracks)
            symbol = playlistAction.symbol
            trailingButton.toolTip = playlistAction.label
            // 空歌单没什么可加可下——§6.0 那张表里下载键的判据其实**没有**这一条
            // （只有播放/随机看条目数），这是 Amber 自己的取舍。`[Amber]`
            trailingButton.isEnabled = !content.isEmpty
        case .libraryMenu:
            symbol = "ellipsis"
            trailingButton.toolTip = "更多"
            // [实测] §6.0：`-[PlaylistHeaderModel hasActionMenu]` 是
            // ——**恒 YES，不做任何条件判断**。所以这一枚不跟着
            // `isEmpty` 禁用：空歌单照样要能重命名、刷新、删除。
            trailingButton.isEnabled = true
        case .download:
            // 心水的歌本来就在资料库里，形态直接从下载状态来。
            playlistAction = appState.downloads.action(inLibrary: true, tracks: content.tracks)
            symbol = playlistAction.symbol
            trailingButton.toolTip = playlistAction.label
            trailingButton.isEnabled = !content.isEmpty
        }
        trailingButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.iconSize, weight: .semibold))
        trailingButton.target = self
        trailingButton.action = #selector(trailingTapped)
    }

    // MARK: 动作菜单

    /// 页头的右键菜单：**每次弹之前现造**，不存成 `menu` 属性。
    ///
    /// [实测] macOS 27（26A5425a）基线 §6.0：
    /// - `-[PlaylistHeaderModel hasActionMenu]` =——**恒 YES**，
    ///   头部**永远**有动作菜单，**不分目录歌单/资料库歌单**，没有任何条件判断。
    /// - 无 sender 的 `actionMenu` =——**恒 nil**，
    ///   菜单只由 `actionMenuFromSender:` 按 sender 现场构建，
    ///   **没有缓存那一份**。`menu(for:)` 正是这个语义。
    ///
    /// 与页头那颗 •••、标题栏那颗 ••• 同一份项序（`moreMenuEntries()`）——三处一致。
    /// 这一点现在有出处：[RES] §6.0.1，Music 的「页头 ⋯」与「右键」**本来就是同一个
    /// `NSMenu` 实例**（全局共享的`NSApp.trackContextMenu`），只是 processingData 不同。
    override func menu(for event: NSEvent) -> NSMenu? {
        MenuSpec.makeMenu(moreMenuEntries())
    }

    /// 标题栏右端那颗 ••• 弹什么（页控制器的 `pageMoreEntries`）。
    /// 与页头右键、页头那颗 ••• 同一份能力袋、同一份项序——三处项集一致。
    /// 项序走 `CollectionActions.playlistPageEntries`（[实机截图 2026-09-09 23:49]，
    /// 见那份的头注）。签名与 `AlbumHeaderView.moreMenuEntries()` 同形。
    func moreMenuEntries() -> [MenuSpec.Entry] { collectionActions().playlistPageEntries }

    /// 页头菜单的「能力袋」：给了闭包就是能做，排在哪由 `CollectionActions` 说了算。
    ///
    /// **项序见 `CollectionActions.playlistPageEntries` 的头注**（实机截图 +`MainMenu.nib`
    /// 的 73 项全集，[RES] §6.0.1）。曾经以为「菜单是 C++ 描述符拼的、逐项内容读不出来」
    /// （§12-10），那是找错了地方：`actionMenuFromSender:` 前面那段 C++ 拼的是
    /// 「当前选中了什么」的 objectSpec，最后一步直接把全局共享的
    /// `NSApp.trackContextMenu` 还回去，菜单项静态躺在 nib 里。
    ///
    /// 页头上已经摆着播放/随机两颗键，所以菜单里**不再摆**这两条——
    /// 与 `LibraryPlaylistMenu(includesPlayback: false)`、`AlbumHeaderView` 同一条道理。
    private func collectionActions() -> CollectionActions {
        var actions = CollectionActions()

        // 三种来源共有的那几条：整份列表一起进队列、一起下载、一起勾选。
        // 截图那一页（心水歌曲）就有「插播 / 下载 / 移除下载 / 取消勾选所选」，
        // 说明这几条不挑歌单来源。
        let tracks = content.tracks
        let downloads = appState.downloads
        let library = appState.library
        if !tracks.isEmpty {
            let player = appState.player
            actions.playNext = { player.playNext(tracks) }
            actions.addToQueue = { player.playLast(tracks) }
            // 「下载」与「移除下载」**不是二选一**：截图那一页部分曲目已下载，两条同时在。
            if !tracks.allSatisfy({ downloads.isDownloaded($0.id) }) {
                actions.download = { [weak self] in
                    downloads.download(tracks)
                    self?.refreshLibraryState()
                }
            }
            if tracks.contains(where: { downloads.isDownloaded($0.id) }) {
                actions.removeDownload = { [weak self] in
                    downloads.removeDownload(tracks)
                    self?.refreshLibraryState()
                }
            }
            // 勾选列关着时这一条整个不摆（那一列不存在，勾了也看不见——
            // 与 `TrackActions.checkSelectedEntry`、专辑页那份同解）。
            if AppSettings.shared.values.songListCheckboxes {
                let allChecked = tracks.allSatisfy { library.isChecked($0) }
                actions.check = (isAllChecked: allChecked,
                                 run: { library.setChecked(tracks, !allChecked) })
            }
        }

        switch content.action {
        case .addToLibrary:
            // 目录歌单：入库前只有「添加到资料库」，入库后换成「从资料库中删除」
            // （`CollectionActions` 里这两条是两个字段、隔着整份菜单，不是一条可切换项）。
            let playlist = content.playlist
            actions.shareURL = playlist.webShareURL
            if appState.library.isPlaylistInLibrary(playlist) {
                actions.deleteFromLibrary = { [weak self] in
                    guard let self else { return }
                    deletePlaylistFromLibrary(id: playlist.id, name: playlist.name)
                    refreshLibraryState()
                }
            } else {
                actions.addToLibrary = { [weak self] in self?.trailingTapped() }
            }
        case .libraryMenu(let playlist):
            // 资料库歌单：原先这三条走 SwiftUI 的 `LibraryPlaylistMenu`，改成同一份`MenuSpec`
            // 后「页头右键 / 页头 ••• / 标题栏 •••」三处才是同一个项集
            //（`LibraryPlaylistMenu` 本身保留——侧栏行还在用）。
            actions.shareURL = playlist.webShareURL
            if playlist.isEditable {
                // 改名弹窗由 `RootViewController` 统一挂着：菜单一关这份菜单树就没了，
                // alert 挂在菜单里根本弹不出来（与卡片那份、侧栏那份同一条）。
                let appState = appState
                actions.rename = { appState.playlistNamePrompt = .rename(playlistID: playlist.id) }
            }
            if playlist.origin == .account {
                let appState = appState
                actions.syncAccount = { Task { await appState.syncAccountPlaylists(manual: true) } }
            }
            actions.deleteFromLibrary = { [weak self] in
                self?.deletePlaylistFromLibrary(id: playlist.id, name: playlist.name)
            }
        case .download:
            // 心水歌曲：改不了名、删不掉、也没有音源网页版那一页可分享，所以这一路
            // 一条专属的都不加——但**菜单不是空的**，上面那几条共有的就是截图里那一份
            // （[实机截图 2026-09-09 23:49] 拍的正是这一页）。
            break
        }
        return actions
    }

    /// 删之前若侧栏正停在这一项，先切回「所有播放列表」，否则删完侧栏指着一份不存在的列表。
    private func deletePlaylistFromLibrary(id: String, name: String) {
        if appState.sidebarSelection == .playlist(id: id, name: name) {
            appState.sidebarSelection = .allPlaylists
        }
        appState.library.deletePlaylist(id: id)
    }

    // MARK: 动作

    @objc private func playTapped() { play() }
    @objc private func shuffleTapped() { shuffle() }

    @objc private func trailingTapped() {
        switch content.action {
        case .addToLibrary:
            if playlistAction == .addToLibrary {
                appState.library.addPlaylistToLibrary(content.playlist)
                appState.showToast("已将《\(content.playlist.name)》添加到资料库")
            } else if playlistAction == .done {
                // 点 ✓ ＝移除整个歌单的下载，先问一句（`DownloadRemovalAlert`）
                let tracks = content.tracks
                let downloads = appState.downloads
                DownloadRemovalAlert.confirm(count: tracks.count, in: window) { [weak self] in
                    downloads.removeDownload(tracks)
                    self?.refreshLibraryState()
                }
                return
            } else {
                appState.downloads.perform(playlistAction, tracks: content.tracks)
            }
            refreshLibraryState()
        case .libraryMenu:
            // 与页头右键、标题栏那颗 ••• 同一份 `MenuSpec` 菜单（AGENTS 铁律：AppKit 骨架，
            // 菜单走 `MenuSpec`，SwiftUI 只作叶子）。从前这里弹的是`NSHostingMenu(LibraryPlaylistMenu…)`
            // ——那份保留给侧栏行用，但页面上这三处得是同一个项集。
            // 现造不缓存，同 `menu(for:)`（[实测] §6.0`actionMenu` 恒 nil）。
            collectionActions().makeMenu()?
                .popUp(positioning: nil,
                       at: NSPoint(x: 0, y: trailingButton.bounds.height),
                       in: trailingButton)
        case .download:
            let tracks = content.tracks
            let downloads = appState.downloads
            guard playlistAction != .done else {
                DownloadRemovalAlert.confirm(count: tracks.count, in: window) { [weak self] in
                    downloads.removeDownload(tracks)
                    self?.refreshLibraryState()
                }
                return
            }
            appState.downloads.perform(playlistAction, tracks: tracks)
            refreshLibraryState()
        }
    }

    // MARK: 排布

    /// 窄于断点就竖排（[实测] `AlbumHeaderLockup` 拿宽度和 600 比）。判据是**入参宽度**。
    private func isVertical(forWidth width: CGFloat) -> Bool {
        width - M.playlistContentHorizontal * 2 < M.playlistHeaderVerticalBreakpoint
    }

    private func artworkSize(forWidth width: CGFloat) -> CGFloat {
        isVertical(forWidth: width) ? M.playlistArtworkSizeCompact : M.playlistArtworkSize
    }

    /// 文字列的宽度与左沿。
    private func textColumn(forWidth width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inset = M.playlistContentHorizontal
        if isVertical(forWidth: width) {
            return (inset, max(1, width - inset * 2))
        }
        let x = inset + artworkSize(forWidth: width) + M.playlistHeaderSpacing
        return (x, max(1, width - inset - x))
    }

    /// 文字块自己的高（不含操作键行）。返回值是「操作键行最早能落在哪」。
    private func textStackHeight(forWidth width: CGFloat) -> CGFloat {
        let column = textColumn(forWidth: width).width
        var y: CGFloat = isVertical(forWidth: width) ? 0 : M.playlistHeaderTopPadding
        y += labelHeight(titleLabel, width: column)
        y += Self.curatorTop + labelHeight(curatorLabel, width: column)
        if !calloutLabel.isHidden {
            y += Self.calloutTop + labelHeight(calloutLabel, width: column)
        }
        if let descriptionView {
            y += Self.descriptionTop + descriptionView.fittingHeight(forWidth: column)
        }
        return y
    }

    /// 旧版 `.padding(.top, 2 / 4 / 6)`
    private static let curatorTop: CGFloat = 2
    private static let calloutTop: CGFloat = 4
    private static let descriptionTop: CGFloat = 6

    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let artwork = artworkSize(forWidth: width)
        let actionsY = actionsTop(forWidth: width)
        let columnHeight = actionsY + M.playlistActionSize
        if isVertical(forWidth: width) {
            return artwork + M.albumHeaderVerticalSpacing + columnHeight
        }
        return max(artwork, columnHeight)
    }

    /// 操作键行的顶边（相对文字列顶）。文字短就贴封面底边，简介展开撑高了就顺势下移。
    private func actionsTop(forWidth width: CGFloat) -> CGFloat {
        let natural = textStackHeight(forWidth: width) + Self.actionsMinTop
        guard !isVertical(forWidth: width) else { return natural }
        return max(natural, artworkSize(forWidth: width) - M.playlistActionSize)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let vertical = isVertical(forWidth: width)
        let artwork = artworkSize(forWidth: width)
        let inset = M.playlistContentHorizontal

        if vertical {
            // 竖排：封面居中在上、文字块在下（旧版 `VStack(alignment: .center)`）。
            artworkView.frame = NSRect(x: (width - artwork) / 2, y: 0,
                                       width: artwork, height: artwork)
        } else {
            artworkView.frame = NSRect(x: inset, y: 0, width: artwork, height: artwork)
        }

        let column = textColumn(forWidth: width)
        let columnTop = vertical ? artwork + M.albumHeaderVerticalSpacing : 0
        var y: CGFloat = vertical ? 0 : M.playlistHeaderTopPadding

        let titleHeight = labelHeight(titleLabel, width: column.width)
        titleLabel.frame = NSRect(x: column.x, y: columnTop + y,
                                  width: column.width, height: titleHeight)
        y += titleHeight

        y += Self.curatorTop
        let curatorHeight = labelHeight(curatorLabel, width: column.width)
        curatorLabel.frame = NSRect(x: column.x, y: columnTop + y,
                                    width: column.width, height: curatorHeight)
        y += curatorHeight

        if !calloutLabel.isHidden {
            y += Self.calloutTop
            let calloutHeight = labelHeight(calloutLabel, width: column.width)
            calloutLabel.frame = NSRect(x: column.x, y: columnTop + y,
                                        width: column.width, height: calloutHeight)
            y += calloutHeight
        }

        if let descriptionView {
            y += Self.descriptionTop
            let height = descriptionView.fittingHeight(forWidth: column.width)
            descriptionView.frame = NSRect(x: column.x, y: columnTop + y,
                                           width: column.width, height: height)
        }

        let actionsY = columnTop + actionsTop(forWidth: width)
        var x = column.x
        for button in [shuffleButton, playButton, trailingButton] {
            button.frame = NSRect(x: x, y: actionsY,
                                  width: button.frame.width, height: M.playlistActionSize)
            x += button.frame.width + Self.actionSpacing
        }
    }
}

// MARK: - 专辑头部

/// Music.app 专辑详情头：大封面贴内容区左沿，右侧自上而下为标题（已喜爱时后面带 ★）、
/// 红色艺人、「曲风 · 年份」信息行（含无损徽标与星级）、可展开简介与操作键行。
@MainActor
final class AlbumHeaderView: DetailHeaderView {

    private typealias M = MusicMetrics.Detail

    struct Content {
        var album: Album
        var tracks: [Track]
        var artworkURL: String?
        var title: String
        var artist: String
        var metadata: String
        var description: String?
        var hasLossless: Bool
        var isEmpty: Bool
    }

    private var content: Content
    /// 播放 / 随机播放。换一批曲目时页面会重挂（闭包捕获的是那一批）。
    var play: () -> Void
    var shuffle: () -> Void

    private let artworkView = DetailArtworkView()
    private let titleLabel = CatalogCardKit.label(size: M.albumTitleSize, weight: .bold,
                                                  color: .labelColor, lines: 2)
    private let favoriteStar = NSButton()
    private let artistLabel = CatalogCardKit.label(size: M.albumArtistSize, weight: .medium,
                                                   color: NSColor(Color.amberKey), lines: 1)
    /// 艺人名那一行是**链接**：Music 点它进艺人页。`CatalogLabel` 自己不接点击
    /// （`hitTest` 返回 nil），而表格只把点击转给 `NSControl`（见`SongsRichCellView` 那条），
    /// 所以摆一枚 `isTransparent` 的按钮盖在**字形**上——不画任何东西、只收这一下，
    /// 标签那边一个像素不动。
    private let artistButton = NSButton()
    private let metadataLabel = CatalogCardKit.label(size: M.albumMetaSize,
                                                     color: .secondaryLabelColor, lines: 1)
    private let losslessDot = CatalogCardKit.label(size: M.albumMetaSize,
                                                   color: .secondaryLabelColor, lines: 1)
    private var losslessHost: NSView?
    private var ratingHost: NSView?
    private var descriptionView: ExpandableTextView?
    private let shuffleButton: DetailActionButton
    private let playButton: DetailActionButton
    private let trailingButton: DetailActionButton
    private var albumAction: LibraryDownloadAction = .addToLibrary

    /// 旧版 `Color.primary.opacity(0.065)`
    private static let backgroundOpacity: CGFloat = 0.065
    /// 旧版 `Spacer(minLength: 0)` + `.padding(.top, albumActionsTop)`：操作键行贴封面底边，
    /// 简介展开时才由 `albumActionsTop` 顶下去。
    private static let actionsMinTop = M.albumActionsTop
    /// [AX] 「无损」徽标 50×15、星级 74.5×17。SwiftUI 叶子装进定尺寸槽（铁律 2）。
    private static let losslessSlot = NSSize(width: 52, height: 17)
    private static let ratingSlot = NSSize(
        width: MusicMetrics.Rating.headerStarSize * 5
            + MusicMetrics.Rating.headerStarSpacing * 4 + 17.5,
        height: 17)

    init(appState: AppState, content: Content,
         play: @escaping () -> Void, shuffle: @escaping () -> Void) {
        self.content = content
        self.play = play
        self.shuffle = shuffle
        shuffleButton = DetailActionButton(symbol: "shuffle", title: nil,
                                           width: M.albumActionSize, height: M.albumActionSize,
                                           backgroundOpacity: Self.backgroundOpacity,
                                           iconSize: M.albumActionIconSize, titleSize: 0)
        playButton = DetailActionButton(symbol: "play.fill", title: "播放",
                                        width: M.albumPlayWidth, height: M.albumActionSize,
                                        backgroundOpacity: Self.backgroundOpacity,
                                        iconSize: M.albumPlayLabelSize,
                                        titleSize: M.albumPlayLabelSize)
        trailingButton = DetailActionButton(symbol: "plus", title: nil,
                                            width: M.albumActionSize, height: M.albumActionSize,
                                            backgroundOpacity: Self.backgroundOpacity,
                                            iconSize: M.albumActionIconSize, titleSize: 0)
        super.init(appState: appState)

        addSubview(artworkView)
        for label in [titleLabel, artistLabel, metadataLabel, losslessDot] { addSubview(label) }
        artistButton.isBordered = false
        artistButton.isTransparent = true   // 文档原话：仍然跟踪鼠标、发 action，但不画
        artistButton.title = ""
        artistButton.target = self
        artistButton.action = #selector(artistTapped)
        addSubview(artistButton)
        favoriteStar.isBordered = false
        favoriteStar.bezelStyle = .shadowlessSquare
        favoriteStar.imagePosition = .imageOnly
        favoriteStar.imageScaling = .scaleNone
        favoriteStar.title = ""
        favoriteStar.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.albumFavoriteStarSize, weight: .regular))
        favoriteStar.contentTintColor = NSColor(Color.amberKey)
        favoriteStar.toolTip = "取消喜爱"
        favoriteStar.target = self
        favoriteStar.action = #selector(toggleFavorite)
        addSubview(favoriteStar)

        losslessDot.stringValue = "·"

        for button in [shuffleButton, playButton, trailingButton] { addSubview(button) }
        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleTapped)
        shuffleButton.toolTip = "随机播放"
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.toolTip = "播放"
        trailingButton.target = self
        trailingButton.action = #selector(trailingTapped)

        // 头部右键菜单（旧版 `.contextMenu`）由`refreshLibraryState()` 按当前状态重建，
        // 项序走 `CollectionActions`。
        apply(content)
    }

    // MARK: 内容

    func apply(_ content: Content) {
        self.content = content
        artworkView.artwork.setArtwork(url: content.artworkURL, points: ArtworkSize.header)
        titleLabel.stringValue = content.title
        artistLabel.stringValue = content.artist
        metadataLabel.stringValue = content.metadata
        // 艺人 id / 名字缺一个就打不开艺人页（判据与曲目行、卡片副标题同一条
        // ——`Route.artist(of:)`），那就干脆别摆这枚透明键，省得点了没反应。
        artistButton.isHidden = artistRoute == nil
        artistButton.setAccessibilityLabel(content.artist)
        artistButton.toolTip = content.artist

        descriptionView?.removeFromSuperview()
        descriptionView = nil
        if let description = content.description, !description.isEmpty {
            let view = ExpandableTextView(text: description,
                                          fontSize: M.albumDescriptionSize,
                                          actionFontSize: M.albumMoreSize,
                                          lineSpacing: M.albumDescriptionLineSpacing,
                                          lineLimit: M.albumDescriptionLines)
            view.onToggle = { [weak self] in
                self?.needsLayout = true
                self?.onHeightChanged?()
            }
            // 专辑的简介不在原地展开：「更多」弹那张介绍卡（与艺人页 ⓘ 同一张）。
            view.onMore = { [weak self] in self?.presentAbout() }
            addSubview(view)
            descriptionView = view
        }

        losslessHost?.removeFromSuperview()
        losslessHost = nil
        if content.hasLossless {
            let host = appState.hostingView { LosslessBadge() }
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            losslessHost = host
        }
        losslessDot.isHidden = !content.hasLossless

        for button in [shuffleButton, playButton, trailingButton] {
            button.isEnabled = !content.isEmpty
        }
        refreshLibraryState()
        needsLayout = true
    }

    override func refreshLibraryState() {
        let library = appState.library
        let isFavorite = library.isFavoriteAlbum(content.album)
        let isInLibrary = library.isAlbumInLibrary(content.album)
        favoriteStar.isHidden = !isFavorite

        // 这一枚的形态走 `DownloadStore.action(inLibrary:tracks:)`——与资料库艺人页的
        // 专辑块、艺人目录页的 release 卡同一套词汇（+ / ↓ / ⏹ / ✓）。
        albumAction = appState.downloads.action(inLibrary: isInLibrary, tracks: content.tracks)
        trailingButton.image = NSImage(
            systemSymbolName: albumAction.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.albumActionIconSize, weight: .semibold))
        trailingButton.toolTip = albumAction.label

        // 目录形态的信息行没有星级（Music 实测：只有「曲风 • 年份」+ Lossless）。
        ratingHost?.removeFromSuperview()
        ratingHost = nil
        if isInLibrary {
            let album = content.album
            let host = appState.hostingView {
                RatingStars(rating: library.rating(for: album.id),
                            starSize: MusicMetrics.Rating.headerStarSize,
                            spacing: MusicMetrics.Rating.headerStarSpacing,
                            setRating: { library.setRating($0, for: album.id) })
            }
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host)
            ratingHost = host
        }

        menu = collectionActions(isFavorite: isFavorite, isInLibrary: isInLibrary).makeMenu()
        // 艺人名上盖着那枚透明键，右键落在它身上：`NSView.menu(for:)` 默认只报自己那份，
        // 不给就是「名字上右键不弹菜单」。同一份挂过去，页头哪儿右键都一样。
        artistButton.menu = menu

        needsLayout = true
    }

    /// 标题栏右端那颗 ••• 弹什么（`AlbumDetailViewController.pageMoreEntries`）。
    ///
    /// 能力袋与页头右键那份是同一个，**项序不是**：Music 这两处自己就排得不一样
    /// （见 `CollectionActions.albumPageEntries` 的头注，[实机截图 2026-09-09]）。
    /// 资料库里的碟走截图那份，目录里的碟没有截图，退回页头那份 `entries`。`[推]`
    /// 现取当前状态，不用 `refreshLibraryState()` 缓存的那一份。
    func moreMenuEntries() -> [MenuSpec.Entry] {
        let isInLibrary = appState.library.isAlbumInLibrary(content.album)
        let actions = collectionActions(
            isFavorite: appState.library.isFavoriteAlbum(content.album),
            isInLibrary: isInLibrary)
        return isInLibrary ? actions.albumPageEntries : actions.entries
    }

    /// 页头右键菜单的「能力袋」：给了闭包就是能做，排在哪由 `CollectionActions` 说了算。
    ///
    /// 与旧版的两处不同：
    /// - 旧版「从资料库中删除」接的是 `trailingTapped`——可那一枚在已入库时走的是
    ///   下载/停止/移除下载，点了根本删不掉库。这里接回 `removeAlbumFromLibrary`。
    /// - 旧版没有「下载 / 移除下载」（专辑网格卡同样漏了，艺人页那颗 ••• 却有）。
    ///   Music 的这两条只对已在资料库里的对象出现
    ///   （`doDownloadCloudTrackSelection:` 的 validateMenuItem: 就这么摘的，见`DownloadStore` 头注），
    ///   整张下完后 ↓ 那一枚会收成 ✓，没有这一条就再也删不掉本地那份。
    private func collectionActions(isFavorite: Bool, isInLibrary: Bool) -> CollectionActions {
        var actions = CollectionActions()
        let album = content.album
        let tracks = content.tracks
        let library = appState.library
        let downloads = appState.downloads
        actions.shareURL = album.webShareURL
        // 「前往艺人」：与点艺人名那一下同一个落点（从前这一条一直空着，那段就整个不摆）。
        if artistRoute != nil {
            actions.goToArtist = { [weak self] in self?.artistTapped() }
        }
        // Music 那条「在 Apple Music 中显示」的位置，Amber 摆的是音源网页版那一页。
        if let web = album.webShareURL {
            actions.openOnWeb = { NSWorkspace.shared.open(web) }
        }
        // 「插播 / 加入待播」：整张碟一起进队列。目录里的碟同样有（[实测] 页头那份就有这一段），
        // 从前这两条一直没接上，于是那一段整个不摆。
        if !tracks.isEmpty {
            let player = appState.player
            actions.playNext = { player.playNext(tracks) }
            actions.addToQueue = { player.playLast(tracks) }
        }

        if isFavorite {
            actions.undoFavorite = { [weak self] in self?.toggleFavorite() }
        } else {
            actions.favorite = { [weak self] in self?.toggleFavorite() }
        }

        guard isInLibrary else {
            actions.addToLibrary = { [weak self] in self?.trailingTapped() }
            return actions
        }
        actions.deleteFromLibrary = { [weak self] in
            guard let self else { return }
            // 「文件去哪」那一问（spec §10.2）；碟里没有媒体文件夹里的文件时直通。
            let appState = self.appState
            LibraryDeleteAlert.askFileDisposition(tracks: tracks, in: self.window,
                                                  appState: appState) { [weak self] in
                library.removeAlbumFromLibrary(album, tracks: tracks)
                appState.showToast("已将《\(album.name)》从资料库中删除")
                self?.refreshLibraryState()
            }
        }
        guard !tracks.isEmpty else { return actions }
        // 「添加到播放列表 ▸」用曲目那份现成的子菜单（本机列表 + 账号歌单两段）。
        actions.addToPlaylist = TrackActions(tracks: tracks, appState: appState).addToPlaylistEntry
        // 「评分 ▸」评的是整张碟——与页头那排星读写同一份。
        actions.rating = (current: library.rating(for: album.id),
                          set: { [weak self] value in
                              library.setRating(value, for: album.id)
                              self?.refreshLibraryState()
                          })
        // 「勾选 / 取消勾选」对整张碟的曲目一起来；勾选列关着时这一条整个不摆
        // （那一列不存在，勾了也看不见——与 `TrackActions.checkSelectedEntry` 同解）。
        if AppSettings.shared.values.songListCheckboxes {
            let allChecked = tracks.allSatisfy { library.isChecked($0) }
            actions.check = (isAllChecked: allChecked,
                             run: { library.setChecked(tracks, !allChecked) })
        }
        if tracks.allSatisfy({ downloads.isDownloaded($0.id) }) {
            actions.removeDownload = { [weak self] in
                downloads.removeDownload(tracks)
                self?.refreshLibraryState()
            }
        } else {
            actions.download = { [weak self] in
                downloads.download(tracks)
                self?.refreshLibraryState()
            }
        }
        return actions
    }

    // MARK: 动作

    @objc private func playTapped() { play() }
    @objc private func shuffleTapped() { shuffle() }

    /// 这张碟的艺人页落点；id 或名字缺一个就没有（`Route.artist(of:)` 的判据）。
    private var artistRoute: Route? { Route.artist(of: content.album) }

    /// 点艺人名 = 进艺人页。右键菜单里的「前往艺人」走同一条。
    @objc private func artistTapped() {
        guard let artistRoute else { return }
        appState.push(artistRoute)
    }

    /// 简介末行那枚「更多」：弹介绍卡（`AboutPanel.swift`），与艺人页 hero 的 ⓘ 同一张。
    ///
    /// 事实行填的是专辑自己有、而卡上又看得见价值的三样：艺人、发行日期（比页头信息行
    /// 那个只有年份的版本全）、曲风。曲风摆成胶囊——与艺人面板的「类型」同款。
    private func presentAbout() {
        let album = content.album
        var facts: [AboutFact] = []
        if !album.artistName.isEmpty { facts.append(AboutFact(label: "艺人", value: album.artistName)) }
        if let date = album.publishDate, !date.isEmpty {
            facts.append(AboutFact(label: "发行日期", value: date))
        }
        if let genre = album.genre, !genre.isEmpty {
            facts.append(AboutFact(label: "曲风", value: genre, isChip: true))
        }
        findAboutPanelPresenter()?.presentAboutPanel(
            AboutContent(name: content.title,
                         artworkURL: content.artworkURL,
                         facts: facts,
                         body: content.description))
    }

    #if DEBUG
    /// 实机验收用：`-albumdemo -albumabout` 直接弹介绍卡，走的就是「更多」的这条路。
    func debugPresentAbout() { presentAbout() }
    #endif

    @objc private func toggleFavorite() {
        appState.library.toggleFavoriteAlbum(content.album)
        refreshLibraryState()
    }

    /// 入库 / 下载 / 停止 / 移除下载，四态照 `LibraryDownloadAction` 走。
    @objc private func trailingTapped() {
        if albumAction == .addToLibrary {
            appState.library.addAlbumToLibrary(content.album, tracks: content.tracks)
            appState.showToast("已将《\(content.album.name)》添加到资料库")
        } else if albumAction == .done {
            // 点 ✓ ＝移除整张碟的下载，先问一句（`DownloadRemovalAlert`）
            let tracks = content.tracks
            let downloads = appState.downloads
            DownloadRemovalAlert.confirm(count: tracks.count, in: window) { [weak self] in
                downloads.removeDownload(tracks)
                self?.refreshLibraryState()
            }
            return
        } else {
            appState.downloads.perform(albumAction, tracks: content.tracks)
        }
        refreshLibraryState()
    }

    // MARK: 排布

    private func isVertical(forWidth width: CGFloat) -> Bool {
        width - M.albumContentHorizontal * 2 < M.albumHeaderVerticalBreakpoint
    }

    private func artworkSize(forWidth width: CGFloat) -> CGFloat {
        isVertical(forWidth: width) ? M.albumArtworkSizeCompact : M.albumArtworkSize
    }

    private func textColumn(forWidth width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inset = M.albumContentHorizontal
        if isVertical(forWidth: width) {
            return (inset, max(1, width - inset * 2))
        }
        let x = inset + artworkSize(forWidth: width) + M.albumHeaderSpacing
        return (x, max(1, width - inset - x))
    }

    private func labelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private var metaRowHeight: CGFloat {
        var height = ceil(metadataLabel.fittingSize.height)
        if losslessHost != nil { height = max(height, Self.losslessSlot.height) }
        if ratingHost != nil { height = max(height, Self.ratingSlot.height) }
        return height
    }

    private func textStackHeight(forWidth width: CGFloat) -> CGFloat {
        let column = textColumn(forWidth: width).width
        // 标题后那颗 ★ 不进标题的可用宽度（旧版是 `HStack` 里的第二件，标题吃剩下的宽）。
        let titleWidth = favoriteStar.isHidden
            ? column
            : max(1, column - M.albumFavoriteGap - ceil(favoriteStar.fittingSize.width))
        var y: CGFloat = isVertical(forWidth: width) ? 0 : M.albumTitleTop
        y += labelHeight(titleLabel, width: titleWidth)
        y += M.albumArtistTop + labelHeight(artistLabel, width: column)
        y += M.albumMetaTop + metaRowHeight
        if let descriptionView {
            y += M.albumDescriptionTop + descriptionView.fittingHeight(forWidth: column)
        }
        return y
    }

    private func actionsTop(forWidth width: CGFloat) -> CGFloat {
        let natural = textStackHeight(forWidth: width) + Self.actionsMinTop
        guard !isVertical(forWidth: width) else { return natural }
        return max(natural, artworkSize(forWidth: width) - M.albumActionSize)
    }

    override func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let artwork = artworkSize(forWidth: width)
        let columnHeight = actionsTop(forWidth: width) + M.albumActionSize
        if isVertical(forWidth: width) {
            return artwork + M.albumHeaderVerticalSpacing + columnHeight
        }
        return max(artwork, columnHeight)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let vertical = isVertical(forWidth: width)
        let artwork = artworkSize(forWidth: width)
        let inset = M.albumContentHorizontal

        // 竖排时封面与文字都靠左沿（旧版 `VStack(alignment: .leading)`）。
        artworkView.frame = NSRect(x: inset, y: 0, width: artwork, height: artwork)

        let column = textColumn(forWidth: width)
        let columnTop = vertical ? artwork + M.albumHeaderVerticalSpacing : 0
        var y: CGFloat = vertical ? 0 : M.albumTitleTop

        let starWidth = favoriteStar.isHidden ? 0 : ceil(favoriteStar.fittingSize.width)
        let titleWidth = favoriteStar.isHidden
            ? column.width : max(1, column.width - M.albumFavoriteGap - starWidth)
        let titleHeight = labelHeight(titleLabel, width: titleWidth)
        titleLabel.frame = NSRect(x: column.x, y: columnTop + y,
                                  width: titleWidth, height: titleHeight)
        if !favoriteStar.isHidden {
            // 旧版是 `HStack(alignment: .firstTextBaseline)` 里的第二件：★ 紧跟标题**字形**右沿
            // （[PX] 标题右沿 815.5 → ★ 起点 824.5，间距 9）。标题折到两行时字形占满整列，
            // ★ 就落在列右端——与 SwiftUI 的 HStack 行为一致。
            // `NSTextField` 的 cell 左右各留 2pt，字形从 frame.x + 2 起（`CatalogCardKit.labelInset`）。
            let glyphWidth = min(CatalogCardKit.textWidth(titleLabel), titleWidth)
            let starHeight = ceil(favoriteStar.fittingSize.height)
            favoriteStar.frame = NSRect(
                x: column.x + CatalogCardKit.labelInset + glyphWidth + M.albumFavoriteGap,
                y: columnTop + y + M.albumFavoriteStarOffsetY,
                width: starWidth, height: starHeight)
        }
        y += titleHeight

        y += M.albumArtistTop
        let artistHeight = labelHeight(artistLabel, width: column.width)
        artistLabel.frame = NSRect(x: column.x, y: columnTop + y,
                                   width: column.width, height: artistHeight)
        // 透明键只盖住**字形**那一截（标签是整列宽的，盖满了等于名字右边一大片空白也能点）：
        // 字形从 frame.x + 2 起（`CatalogCardKit.labelInset`），名字长到要截断时封顶在列宽。
        artistButton.frame = NSRect(
            x: column.x + CatalogCardKit.labelInset,
            y: columnTop + y,
            width: min(CatalogCardKit.textWidth(artistLabel), column.width),
            height: artistHeight)
        y += artistHeight

        y += M.albumMetaTop
        let metaHeight = metaRowHeight
        let metaY = columnTop + y
        var metaX = column.x
        let metadataWidth = ceil(metadataLabel.fittingSize.width)
        metadataLabel.frame = NSRect(x: metaX, y: metaY + (metaHeight - ceil(metadataLabel.fittingSize.height)) / 2,
                                     width: min(metadataWidth, column.width), height: ceil(metadataLabel.fittingSize.height))
        metaX += min(metadataWidth, column.width)
        if let losslessHost {
            metaX += M.albumMetaSpacing
            let dotWidth = ceil(losslessDot.fittingSize.width)
            losslessDot.frame = NSRect(x: metaX,
                                       y: metaY + (metaHeight - ceil(losslessDot.fittingSize.height)) / 2,
                                       width: dotWidth, height: ceil(losslessDot.fittingSize.height))
            metaX += dotWidth + M.albumMetaSpacing
            losslessHost.frame = NSRect(x: metaX, y: metaY + (metaHeight - Self.losslessSlot.height) / 2,
                                        width: Self.losslessSlot.width, height: Self.losslessSlot.height)
            metaX += Self.losslessSlot.width
        }
        if let ratingHost {
            metaX += M.albumMetaSpacing
            ratingHost.frame = NSRect(
                x: metaX,
                y: metaY + (metaHeight - Self.ratingSlot.height) / 2
                    + MusicMetrics.Rating.headerStarOffsetY,
                width: Self.ratingSlot.width, height: Self.ratingSlot.height)
        }
        y += metaHeight

        if let descriptionView {
            y += M.albumDescriptionTop
            let height = descriptionView.fittingHeight(forWidth: column.width)
            descriptionView.frame = NSRect(x: column.x, y: columnTop + y,
                                           width: column.width, height: height)
        }

        let actionsY = columnTop + actionsTop(forWidth: width)
        var x = column.x
        for button in [shuffleButton, playButton, trailingButton] {
            button.frame = NSRect(x: x, y: actionsY,
                                  width: button.frame.width, height: M.albumActionSize)
            x += button.frame.width + M.albumActionSpacing
        }
    }
}

// MARK: - 页脚

/// 详情页最底下那几行小字（专辑：发行日期 + 「N 首歌曲，X 分钟」；歌单：只有后一行）。
/// 11pt 次要色，左内缩由页面给（表是整宽的，留白自己让，与行、头部同一条）。
final class DetailFooterView: NSView {

    /// [AX] 版权信息 11pt 次要色，两行之间 2。
    private static let fontSize: CGFloat = 11
    private static let lineSpacing: CGFloat = 2

    private let labels: [NSTextField]
    private let leading: CGFloat

    override var isFlipped: Bool { true }

    init(lines: [String], leading: CGFloat) {
        labels = lines.map { text in
            let label = CatalogCardKit.label(size: DetailFooterView.fontSize,
                                             color: .secondaryLabelColor, lines: 1)
            label.stringValue = text
            return label
        }
        self.leading = leading
        super.init(frame: .zero)
        for label in labels { addSubview(label) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var fittingSize: NSSize {
        let height = labels.reduce(0) { $0 + ceil($1.fittingSize.height) }
            + Self.lineSpacing * CGFloat(max(0, labels.count - 1))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for label in labels {
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(x: leading - CatalogCardKit.labelInset, y: y,
                                 width: max(1, bounds.width - leading + CatalogCardKit.labelInset),
                                 height: height)
            y += height + Self.lineSpacing
        }
    }
}
