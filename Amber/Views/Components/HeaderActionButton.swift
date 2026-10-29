import AppKit

// MARK: - 页面头部操作键（共享组件）

/// 头部操作键：胶囊主操作键（「▶ 播放」）与圆形辅助操作键（「随机播放」、「入库」、「更多」等）。
///
/// 遵循 macOS Music 规范配色：
/// - 主操作胶囊（「▶ 播放」，`isProminent == true`）：
///   实心浅底 `rgb(243,243,243)`（浅色外观下反相为深底 `rgb(28,28,30)`）+ 反相前景字/图标；
///   开启 `imageHugsTitle = true`，使图标与文本紧凑居中对称，彻底避免图标贴边 bug。
/// - 辅助圆钮（随机播放、添加等）：
///   `labelColor` 低浓度半透明底（专辑 6.5%、歌单 8% 等）+ `labelColor` 单色图标。
@MainActor
class HeaderActionButton: NSButton {

    private let backgroundOpacity: CGFloat
    private let isProminent: Bool
    private let fixedWidth: CGFloat
    private let fixedHeight: CGFloat
    private let horizontalPadding: CGFloat

    /// [PX] 主胶囊深色外观下实测底色 rgb(243,243,243)、前景 rgb(0,0,0)；浅色外观对称反相。
    private static let prominentFillColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 243 / 255, green: 243 / 255, blue: 243 / 255, alpha: 1)
            : NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    }

    private static let prominentForegroundColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .black : .white
    }

    private var foregroundColor: NSColor {
        isProminent ? Self.prominentForegroundColor : .labelColor
    }

    /// - Parameters:
    ///   - symbol: SF Symbol 名称
    ///   - title: 按钮标题，给非 nil 即为主操作高亮胶囊（Prominent）
    ///   - width: 指定固定宽度；若传 0 则根据内容及内边距自适应（`intrinsicContentSize`）
    ///   - height: 指定高度（圆角为 height / 2）
    ///   - backgroundOpacity: 次操作圆钮的背景透明度（默认 0.08）
    ///   - iconSize: 图标字号
    ///   - titleSize: 标题字号
    ///   - horizontalPadding: 自适应宽度时左右各内缩的留白
    init(symbol: String?,
         title: String?,
         width: CGFloat = 0,
         height: CGFloat,
         backgroundOpacity: CGFloat = 0.08,
         iconSize: CGFloat = 14,
         titleSize: CGFloat = 14,
         horizontalPadding: CGFloat = 16) {
        self.backgroundOpacity = backgroundOpacity
        self.isProminent = title != nil
        self.fixedWidth = width
        self.fixedHeight = height
        self.horizontalPadding = horizontalPadding

        let initialFrame = NSRect(x: 0, y: 0, width: width > 0 ? width : height, height: height)
        super.init(frame: initialFrame)

        isBordered = false
        bezelStyle = .shadowlessSquare
        imageScaling = .scaleNone
        contentTintColor = foregroundColor

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
                             .foregroundColor: foregroundColor])
        } else {
            imagePosition = .imageOnly
            self.title = ""
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        if fixedWidth > 0 {
            return NSSize(width: fixedWidth, height: fixedHeight)
        }
        let superSize = super.intrinsicContentSize
        let contentWidth = ceil(superSize.width) + horizontalPadding * 2
        return NSSize(width: max(contentWidth, fixedHeight), height: fixedHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let baseFill = isProminent
            ? Self.prominentFillColor
            : NSColor.labelColor.withAlphaComponent(backgroundOpacity)
        let fill = isHighlighted
            ? (isProminent ? baseFill.withAlphaComponent(0.85) : NSColor.labelColor.withAlphaComponent(backgroundOpacity * 1.8))
            : baseFill
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
        super.draw(dirtyRect)
    }

    /// 语义色随外观变，重画一次。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let fg = foregroundColor
        contentTintColor = fg
        if let attributedTitle = attributedTitle.mutableCopy() as? NSMutableAttributedString,
           attributedTitle.length > 0 {
            attributedTitle.addAttribute(.foregroundColor, value: fg,
                                         range: NSRange(location: 0, length: attributedTitle.length))
            self.attributedTitle = attributedTitle
        }
        needsDisplay = true
    }
}

typealias DetailActionButton = HeaderActionButton
