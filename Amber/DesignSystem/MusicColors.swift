import AppKit
import SwiftUI

/// 颜色 token。优先级：Music.app 自带资源目录 > Mac 端实测 > 网页版 CSS。
/// 网页版与 Mac Music.app 共享设计语言，网页 token 用于补齐资源目录里没有的语义灰阶。
///
/// 出处标注：
/// - [资源] Music.app `Assets.car` 里的命名颜色（assetutil 静态解析，规格笔记）
/// - [Web] design-ref/web/tokens-{light,dark}.txt 中的同名 token
extension Color {

    /// [资源] 品牌红。取自 Music.app 自带 `Assets.car` 的命名颜色`KeyColor`，
    /// 四个外观变体齐全（music-static-assets 笔记「命名颜色」）：
    ///   any（浅色）           #FA233B
    ///   NSAppearanceNameDarkAqua                    #FA2D48
    ///   NSAppearanceNameAccessibilitySystem（浅+增强对比）#D60017
    ///   NSAppearanceNameAccessibilityDarkAqua       #FA586A
    /// 早前浅色态用的 #FA586A 其实是「深色+增强对比」那一档，浅色下偏粉、对比不足。
    /// 当前歌曲高亮、收藏心形、操作按钮等全部品牌色场景用它。
    ///
    /// [HIG] 「增强对比度」在 AppKit 里是一档 **外观（appearance）**，不是一个全局布尔：
    /// `NSAppearance.Name` 备有 accessibilityHighContrast{Aqua,DarkAqua,VibrantLight,VibrantDark}
    /// 四个名字。所以浅/深与普通/高对比一律交给 `bestMatch` 一次判完——值跟着当前解析上下文
    /// （哪个视图、哪次绘制）走。原先在 provider 里读 `NSWorkspace` 的全局开关，
    /// 拿到的是「绘制那一刻的系统设置」，与被解析的 appearance 无关，
    /// 视图局部覆盖外观时会取错档。
    static let amberKey = Color(nsColor: NSColor(name: nil) { appearance in
        let name = appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) ?? .aqua
        switch name {
        case .darkAqua:                          return NSColor(srgbRed: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255, alpha: 1)
        case .accessibilityHighContrastAqua:     return NSColor(srgbRed: 0xD6 / 255, green: 0x00 / 255, blue: 0x17 / 255, alpha: 1)
        case .accessibilityHighContrastDarkAqua: return NSColor(srgbRed: 0xFA / 255, green: 0x58 / 255, blue: 0x6A / 255, alpha: 1)
        default:                                 return NSColor(srgbRed: 0xFA / 255, green: 0x23 / 255, blue: 0x3B / 255, alpha: 1)
        }
    })

    /// [Web] keyColor 深色值 #FA2D48 的固定版本：
    /// 全屏播放器背景永远是深色封面取色，控件不跟系统外观走，需要写死深色变体。
    static let amberKeyDark = Color(red: 250 / 255, green: 45 / 255, blue: 72 / 255)

    /// [PX] 歌曲表列头背景。2026-08-16 与 Music 1.7 同屏取色：列头 rgb(37,40,42)，
    /// 内容区 rgb(43,43,43)——列头比内容**更暗**，还带一点冷味，不是同色。
    /// SwiftUI 的 `.bar` 与 AppKit 的`.headerView` 材质在这儿量出来都是 43,43,43
    /// （材质拿窗口背景去混，而表格背景本来就是窗口背景），所以只能上死值。
    /// 深色是实测值；浅色态还没同屏量过，先按同样的「比内容略暗」关系给一个近似值，
    /// 等浅色下再取一次色补准。
    static let amberTableHeader = Color(nsColor: .amberTableHeader)

    /// [PX] 插图列分组之间那条横线：贯穿整行宽，压在行底色上量出来 rgb(83) / rgb(74)，
    /// 折回去是白 15%，比普通分隔线（白 10%）更实一点。
    static let amberGroupDivider = Color(nsColor: .amberGroupDivider)

    /// [Web] 分隔线 labelDivider：深白 10% / 浅黑 15%（网页为 0.5px 发丝线）
    static let amberLabelDivider = Color(nsColor: .amberLabelDivider)
}

/// 歌曲表的骨架是 AppKit（NSTableView）画的，条纹、列头、分隔线都要拿 NSColor。
/// 这三条与上面的 `Color` 是同一份值——`Color` 那边只是包一层。
///
/// [HIG] 三条都按 `Color.amberKey` 那套四档`bestMatch` 写（浅／深 × 普通／高对比），
/// 让「增强对比度」跟着解析上下文的 appearance 走，而不是绘制那一刻的全局开关。
/// [推] TODO：这三条的高对比档还没在 Music 里实测过（[PX]/[Web] 只量到普通档），
/// 不瞎编值——高对比暂时与对应的普通档同值，量到再把两行分开填。
extension NSColor {
    /// 见 `Color.amberTableHeader`
    static let amberTableHeader = NSColor(name: nil) { appearance in
        let name = appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) ?? .aqua
        switch name {
        case .darkAqua, .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 37 / 255, green: 40 / 255, blue: 42 / 255, alpha: 1)
        default:
            return NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 246 / 255, alpha: 1)
        }
    }

    /// 见 `Color.amberGroupDivider`
    static let amberGroupDivider = NSColor(name: nil) { appearance in
        let name = appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) ?? .aqua
        switch name {
        case .darkAqua, .accessibilityHighContrastDarkAqua:
            return NSColor(white: 1, alpha: 0.15)
        default:
            return NSColor(white: 0, alpha: 0.15)
        }
    }

    /// 见 `Color.amberLabelDivider`
    static let amberLabelDivider = NSColor(name: nil) { appearance in
        let name = appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) ?? .aqua
        switch name {
        case .darkAqua, .accessibilityHighContrastDarkAqua:
            return NSColor(white: 1, alpha: 0.10)
        default:
            return NSColor(white: 0, alpha: 0.15)
        }
    }
}

/// 常暗背景（玻璃胶囊、全屏播放器）上的灰阶，对网页版 onDark 系列 token。
/// 网页语义：primary 主文字/已播进度，secondary 副文字，tertiary 音量轨道，quaternary 静止进度轨道。
enum MusicGrays {
    /// [Web] systemPrimary-onDark：白 85%
    static let primary: CGFloat = 0.85
    /// [Web] systemTertiary-onDark：白 25%（chromeVolumeTrack 音量轨道用）
    static let tertiary: CGFloat = 0.25
}

// MARK: - 显示简介面板

extension NSColor {
    /// [PX] 「显示简介」面板头部那一块的背景。整扇窗里**只有这一条**需要 token：
    /// sample §6 的 13 条取样自己就写着「是当前外观下 NSColor 语义色解析后的值，
    /// 不是资源常量，复刻时应当用对应的语义色，把数值只当校验基准」——
    /// 内容区 `#29292A` 对上`underPageBackgroundColor`（深色实测`#282828`，差 1/255），
    /// 文本框、按钮、勾选框全部用标准控件自带的色；唯独「头部比内容区亮一档」
    /// （`#323233` vs `#29292A`，+9/255）是这个面板自己的设计，系统没有对应语义色。
    ///
    /// 浅色模式**没采过**（sample §9 #2）。这里按深色量到的「比内容亮一档」
    /// 关系给值：浅色内容区是 `underPageBackgroundColor` = `#F6F6F6`，再亮一档即纯白。
    /// 等浅色下真取一次色再订正。
    static let amberInfoPanelHeader = NSColor(name: nil) { appearance in
        let name = appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) ?? .aqua
        switch name {
        case .darkAqua, .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 0x32 / 255, green: 0x32 / 255, blue: 0x33 / 255, alpha: 1)
        default:
            // 浅色未实测，见上。
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

extension NSColor {
    /// 见 `Color.amberKey`。AppKit 骨架要拿这支品牌红时用它（简介面板头部那颗喜爱星）。
    /// 直接桥 `Color.amberKey`——那支本来就是`Color(nsColor:)` 包出来的动态色，
    /// 桥回去还是同一个 provider，四档 appearance 照走，不用把值再抄一遍。
    static let amberKey = NSColor(Color.amberKey)
}

// MARK: - 没有封面时的灰底

/// 「这首歌/这张碟没有封面」时铺的那块底。
///
/// 从前铺的是品牌红 0.85 → 紫 0.55 的渐变，一屏里十几张没封面的条目就是十几块
/// 红紫，比真封面还抢眼。design-ref/DESIGN_BRIEF.md §6.4 给的两条路是「封面平均色
/// 或**中性灰**」——没有封面时自然只剩中性灰这一条。
///
/// 值走系统灰阶（systemGray5/6 那一档）：浅 #EAEAEC → #DCDCDF，深 #3A3A3C → #2C2C2E，
/// 仍是左上 → 右下的两端，形不变、只换色。上面那枚音符交给 `secondaryLabelColor`，
/// 浅深两档由系统自己折。
extension NSColor {
    /// 灰底渐变的起点（左上）。
    static let amberArtworkPlaceholderTop = NSColor(name: "amberArtworkPlaceholderTop") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
            : NSColor(srgbRed: 234 / 255, green: 234 / 255, blue: 236 / 255, alpha: 1)
    }

    /// 灰底渐变的终点（右下）。
    static let amberArtworkPlaceholderBottom = NSColor(name: "amberArtworkPlaceholderBottom") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(srgbRed: 220 / 255, green: 220 / 255, blue: 223 / 255, alpha: 1)
    }

    /// 灰底上那枚音符。铁律 6：这个色系统自己就有，别另起一支。
    static let amberArtworkPlaceholderGlyph = NSColor.secondaryLabelColor
}

extension Color {
    /// 见 `NSColor.amberArtworkPlaceholderTop`
    static let amberArtworkPlaceholderTop = Color(nsColor: .amberArtworkPlaceholderTop)
    /// 见 `NSColor.amberArtworkPlaceholderBottom`
    static let amberArtworkPlaceholderBottom = Color(nsColor: .amberArtworkPlaceholderBottom)
}

/// 灰底铺给 `CAGradientLayer` 的那一步。
///
/// 层收的是 `CGColor`：动态色在交出去那一刻就被解析成固定值了，浅深切换时不会自己变
/// （`LibraryFavoritesCardView.applyPlaceholder` 的头注写的正是这件事）。所以每个用它的
/// 视图都要在 `viewDidChangeEffectiveAppearance` 里再调一遍这个方法。
enum ArtworkPlaceholder {
    /// 左上 → 右下。`startPoint`/`endPoint` 由各视图自己摆（它们本来就摆好了）。
    static func fill(_ layer: CAGradientLayer, for view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.colors = [NSColor.amberArtworkPlaceholderTop.cgColor,
                            NSColor.amberArtworkPlaceholderBottom.cgColor]
        }
    }
}
