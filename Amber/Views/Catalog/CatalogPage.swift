import SwiftUI

// MARK: - 目录页模型（CatalogPagePresenter / MappedSection / MappedItem 的复刻）

/// 目录页（主页/新发现/广播）的一个条目，对应 Music 的 MappedItem → *LockupComponentItem
/// 一张卡片（`lockup 规格` §1 的组件家族）。Music 的样式由服务端 MappedItem 字段决定；
/// Amber 数据源固定，由各页的组装函数直接落 kind（HomePages.swift，标 [推]）。
struct CatalogItem: Identifiable, Sendable {
    enum Kind {
        /// 3:4 海报，白字压图（主页「专属推荐」的 Flowcase/Poster 卡）
        case poster
        /// 方图 + 图下两行文字（最近播放/本週新發行的 Square 卡）
        case square
        /// 探新顶部 hero：三行文字在上、图在下（HorizontalPoster 卡）
        case hero
        /// 整宽大横幅：一张图铺满内容列，一句描述居中压在图底（super-hero 卡）
        case banner
        /// 广播电台瓷砖：方图台名压图（LiveRadioGrid 卡）
        case station
        /// 广播节目宽卡：方图贴左 + 标题 + •••（Horizontal 卡）
        case episode
        /// 16:9 视频卡：图下两行（新发现「观看艺人分享」的 vertical-video 卡）
        case video
        /// 纯文字链接格（新发现「探索更多」的 link-box）
        case link
        /// 艺人页顶上那张**满幅大图**：图从窗口顶（穿过标题栏）铺满整个内容列，
        /// 下半程糊进黑底，艺人名 40pt 白字压在图上居中，名字下面一行三枚圆键
        /// （ⓘ 45 / 白底 ▶ 69 / ★ 45）。对应 Music 的
        /// `LegacyArtistDetailHeaderLockupComponentItem`（`artistpage 规格` §1：
        /// 一个 `ArtworkView` 塞 4~5 层`Contents` + 一层渐变）。
        case artistHero
        /// 艺人页「最新發行」卡：162 方封面贴左 + 右侧三行（发行日期 / 专辑名 /「N 首歌曲」）
        /// + 一枚 ＋ 圆键。对应 Music 的 `ArtistLatestReleaseSection`
        /// （`artistpage 规格` §0 边界那一段点名的下一批组件）。
        case release
        /// 搜索结果页「热门搜索结果」的横卡：方缩略图（艺人切圆）贴左 + 右侧两行
        /// （标题 / 「类型 · 副标题」）+ 尾标。对应 Music 的
        /// `TopSearchLockupComponentItem`（`search-musicui 规格` §2），
        /// 只出现在 `.topResults` 那种网格段里。
        case topResult
    }

    let id: String
    let kind: Kind
    var title: String
    var artworkURL: String? = nil
    /// hero / poster 的眉行（Music 的 eyebrow，如「專屬推薦」「NEW ALBUM」）
    var eyebrow: String? = nil
    /// hero 第三行副标题
    var subtitle: String? = nil
    /// hero 图内 / poster 图上的描述行
    var description: String? = nil
    /// 瓷砖没有封面时的品牌渐变（Amber 无 Apple Music 台标图，用色块替代）
    var fallbackColors: [Color]? = nil
    /// 封面切成圆的（艺人卡）。Music 里艺人一律是圆头像 + 名字，别处一律是圆角方图；
    /// 这是同一张方卡（`.square`）的一档样子，不是另一种卡，所以做成开关而不是新`Kind`。
    var isCircularArtwork = false
    /// 点击落点；nil 的条目不可点
    var route: Route? = nil
    /// 副标题（如艺人）的独立点击落点；支持点击直接进入艺人详情
    var subtitleRoute: Route? = nil
    /// 悬浮播放键
    var onPlay: (@MainActor @Sendable () -> Void)? = nil
    /// 没有 `Route` 可推、点了却要跳转的卡的落点（资料库派生的艺人：跳回资料库
    /// 「艺人」页并选中那一行）。与 `onPlay` 分开是因为`onPlay` 会让卡片悬浮时
    /// 浮出一颗播放键，而艺人卡本来就不该有播放键。主点击顺序：`route` → `onOpen` → `onPlay`。
    var onOpen: (@MainActor @Sendable () -> Void)? = nil
    /// `onOpen` 那一路在右键菜单里的项名（如「前往艺人」）。没有`route` 的卡
    /// 菜单本来是空的，这一条把同一个落点也摆进菜单。
    var openMenuTitle: String? = nil
    /// 最近播放卡片的曲目上下文（心水星 / 右键菜单）
    var track: Track? = nil
    /// 视频卡的 MV 上下文（右键菜单的「下载」「在网页中打开」）
    var mv: MV? = nil
    var isFavorite = false
    /// Explicit 脏标或特殊标记
    var isExplicit = false
    /// 角标文字（如 Lossless、Spatial 等）。视频卡（`.video`）把它画在缩略图右下角：
    /// 搜索结果的 MV 卡在这里放时长（旧版 `MVCard` 那颗），主页/新发现的视频卡不给，
    /// 那两页照旧一个角标都不画。
    var badge: String? = nil
}

/// 目录页的一个分段。Music 的「货架还是网格、几行」是服务端下发的 presentation 字段
/// （`lockup 规格` §0：shelf(numberOfRows:)/grid/adaptive/list 四 case）；
/// Amber 由各页组装时直接定。多行货架在 Music 里是列优先排（radio.json：同列三行连续）。
struct CatalogSection: Identifiable, Sendable {
    enum Layout {
        case posters
        /// rows = 货架行数（列优先填充）
        case squares(rows: Int)
        case heroes
        /// 整宽大横幅：段里只有一张卡，不横滚
        case banner
        case stations
        case episodes(rows: Int)
        /// 必聽新歌式多列曲目行；rows = 每列行数
        case trackColumns(rows: Int)
        /// 16:9 视频卡货架（单行）
        case videos
        /// 链接组：三列网格、列优先，不横滚
        case links
        /// 横卡网格（搜索结果页的「热门搜索结果」）：**不是货架**、不横滚，
        /// 按内容列宽能塞几列就几列（列宽下限 `topResultMinWidth`），铺满换行、**行优先**。
        /// 对应 Music 的 `TopSearchGridLayoutConfiguration`（`search-musicui 规格` §2）。
        case topResults
        /// 艺人页的满幅 hero：段里只有一件（kind `.artistHero`），
        /// **无段头、不横滚、左右一点边距都不让**（图要铺满内容列并穿过标题栏）。
        case artistHero
        /// 艺人页的「并排带」：一段里同时摆两样东西——
        /// x=0 是一张「最新發行」卡（`items` 的第一件，kind`.release`；音源交不出专辑时可以没有），
        /// 右边接 `tracks` 的多列曲目货架（每列`rows` 行、列优先，就是`.trackColumns` 那一套）。
        /// 段头是**双标题**：左「最新發行」、右「熱門歌曲 ›」。整条带一起横滚。
        case artistBand(rows: Int)

        /// 不是货架、铺满内容列的几种段（不套横向 ScrollView）
        var isFullWidth: Bool {
            switch self {
            case .banner, .links, .artistHero, .topResults: return true
            default: return false
            }
        }
    }

    let id: String
    var layout: Layout
    /// 段标题；nil = 无标题段（探新 hero、广播首段）
    var title: String? = nil
    /// 种子头的小字（Music 的 `headline`，如「更多类似作品」）。有它时段标题是种子名本身。
    var headline: String? = nil
    /// 种子头左侧的 40 缩略图（种子的封面）
    var seedArtworkURL: String? = nil
    /// 并排带（`artistBand`）段头右半那个标题（艺人页的「熱門歌曲 ›」）。
    /// 它才是带 `destination` / › 的那一个，左半的`title`（「最新發行」）只是块标签。
    var trailingTitle: String? = nil
    /// 段标题落点（Music 的段标题是「查看全部」AXButton）；有落点才显示 ›
    var destination: Route? = nil
    var showsChevron = false
    /// 卡片。`artistBand` 段的第一件是那张`.release` 卡（没有就留空数组）。
    var items: [CatalogItem] = []
    /// `trackColumns` / `artistBand` 布局的曲目
    var tracks: [Track] = []
}

/// CatalogPagePresenter.State 的三 case（`catalogpage 规格` §2.1 [TYPE]：
/// content / error / loading，AppKit 宿主用 overlayViewController 呈现后两态）。
enum CatalogPageState: Sendable {
    case loading
    case content(title: String, sections: [CatalogSection])
    case error(String)
}
