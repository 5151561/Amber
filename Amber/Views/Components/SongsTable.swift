import AppKit
import SwiftUI

// 资料库「歌曲」页表格之外的三个模型：筛选、列、排序。
//
// Music.app 这一页（`AMPTrackDisplayController` + `TrackDisplayTableView`）就是一张
// **NSTableView**：紧凑 22pt 行、斑马纹底色、常驻列头；列宽拖分隔线可调、
// 列头右键可增删列、拖列头能整列换位，度量里的宽度只是默认值。
// 页面自身没有大标题——标题在标题栏，表格从内容列顶端直接铺开。
//
// 页面 VC（滚动容器、空态、筛选/搜索/排序管线、刷新驱动、工具栏）在
// `Amber/Views/Shell/LibrarySongsViewController.swift`；表格骨架（行、列、选择、键盘、拖放、
// 自动调宽的量法）在 `SongsTableView.swift`。本文件只剩下面这三个模型。
//
// 与专辑页音轨行的行为差异（2026-08-15 实机采样，度量见 MusicMetrics.SongsTable）：
// - 悬浮**不改行底色**，只让云端下载键、空心心水星、空心评分星显形；
// - ••• 常显且常为品牌红（专辑页是灰色、悬浮才转红）；
// - 正在播放的曲目不把标题染红，而是在最左那条独立空栏里画一个纯白喇叭；
//   这条栏永远占位，出现喇叭时不会把歌名往右顶。

// MARK: - 筛选

enum SongsTableFilter: String, CaseIterable, Identifiable {
    case all, favorites

    var id: String { rawValue }
    var title: String { self == .all ? "所有歌曲" : "仅喜爱" }
}

// MARK: - 列

/// 表格的列定义、当前列宽、显隐与顺序。
///
/// 这 40 项可选列与 Music 表头右键菜单一一对应（2026-08-15 从 Music 1.7 的 AX 菜单实录，
/// 名称照抄它的中文；宽度、最小宽度与对齐取自 Music.app 自带的
/// `zh_CN.lproj/ColumnWidths.plist`，默认显示的那几列仍用 AX 实测值）。
///
/// 音源填不上的列（文件属性、购买信息、分类排序名等）照样列出来并可勾选，
/// 勾上就是一整列空白——Music 遇到没有标签的曲目也是这个样子。
struct SongsTableColumns: Equatable {
    enum Key: String, CaseIterable, Codable {
        /// 设置 › 通用 ›「歌曲列表复选框」开出来的勾选列。
        ///
        /// [AX] 参照图里它夹在编号与云端之间（`编号 | ✓ | ☁ | 时长`），列头是一枚 ✓，
        /// 而且**和别的列一样能拖着换位**——不是钉死在最左的那种。所以它只保留
        /// 「不能排序、不能拖宽」两条，`fixed` 为假。
        ///
        /// 出厂位摆在标题之后、云端之前：编号与标题两条都是 `fixed`，夹在它们中间的列
        /// 会被 `canReorder` 的区间判定锁死（起点到落点之间不许有固定列），
        /// 那就又成了「拖不动」。
        ///
        /// 照旧不在列头右键菜单与「显示选项」窗口里（那两处只列可增删的字段列），
        /// 显隐只听那一条应用级偏好。
        case checked
        /// 「显示插图」开出来的专辑插图列（Music 的字段 **126**，按专辑跨行）。
        /// 它不在列头右键菜单里，显隐由显示选项那颗勾选框管
        case artwork
        /// 逐行的曲目封面列（Music 的字段 **37**）。与上面那条是两回事：
        /// 126 是一组一块跨行的专辑封面，37 是**每一行自己**的一张小封面。
        /// `[实测]` loadColumnsFromSet: 起：宽 50、`hidden = !showTrackArtwork`、
        /// `mMoveable = false`、`resizingMask = []`（不可缩放）。同样不进列头右键菜单。
        case trackArtwork
        // 默认显示（Music 的出厂勾选项 + 播放指示与标题两条固定列）
        case nowPlaying, title, cloud, duration, artist, album, genre, favorite, rating, playCount
        // 音源或本地资料库填得上的
        case albumArtist, year, releaseDate, trackNumber, discNumber, albumRating
        case dateAdded, lastPlayed, skips, lastSkipped, kind, cloudStatus
        // Amber 拿不到数据，勾上是空列
        case composer, grouping, work, movementName, movementNumber, category
        case description, comments, bpm, equalizer, bitRate, sampleRate, size
        case dateModified, purchaseDate
        case sortName, sortAlbum, sortArtist, sortAlbumArtist, sortComposer
    }

    struct Column: Identifiable {
        let key: Key
        var id: Key { key }
        /// 列头文字；图标列与播放指示列为 nil
        var title: String?
        var icon: String?
        /// 数字与日期列右对齐（对齐方式取自 ColumnWidths.plist 的 justification）
        var trailing = false
        var minWidth: CGFloat = 40
        /// 播放指示列与标题列在 Music 里既不能隐藏也不能拖动换位
        var fixed = false
        var defaultWidth: CGFloat = 100
        /// 默认不显示，可在列头右键菜单里打开
        var hiddenByDefault = true
        /// 图标列没有可读文字，排序时另有取值，但列头点击一样能排
        var sortable = true
        /// 对应 NSTableColumn 的 `resizingMask`：为空就既不能拖宽，也不参与自动调宽
        /// （`[实测]` `autosizeColumnAtIndex:ignoreResizingMask:` 头一件事就是
        /// 「mask 为空且不忽略 mask 就直接返回」）。
        ///
        /// 谁该为空：`makeTableColumnForField:withInfo:` 是按字段信息表里的
        /// 一个字节决定「给算出来的 mask 还是给 0」的，那张表不在转储里，只有曲目封面列
        /// 有明文（字段 37「不可移动不可缩放」）。另外三条是内容宽度定死的图标/星级列
        /// （云端下载、喜爱、评分），按同样的规矩收进来——**这三条尚未在 Music 上实拖验证**。
        var resizable = true
    }

    private typealias M = MusicMetrics.SongsTable

    /// 勾选框的边长＝**一行正文的行高**（参照图里那枚方框正好和文字一样高，
    /// 不是 22pt 的系统复选框）。用系统字体自己报的行高推，辅助功能字号变了也跟着走
    /// （AGENTS §6 第一问：能问系统就问系统）。
    static let checkboxSide: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return (font.ascender - font.descender + font.leading).rounded()
    }()

    /// 勾选列的宽度。`[推]`：Music 1.7 这一列没有 AX 样本，而它不是 Music 自己的
    /// 设计常量、也不是补 SwiftUI 偏移的数（AGENTS §6 的三问），所以不进
    /// `MusicMetrics` 立一条 token，就近放在列定义旁边。
    /// 方框左右各留 3，与云端/心水两条图标列的 `minWidth`（22）同档。
    static let checkedColumnWidth: CGFloat = checkboxSide + 6

    /// 排列顺序＝表格从左到右的出厂顺序：先是 Music 默认显示的那几列（AX 实测宽度），
    /// 其余按 ColumnWidths.plist 的登记顺序排在后面。
    static let all: [Column] = [
        // 列头写的是「按艺人排列专辑」——不是「插图」（2026-08-16 与 Music 1.7 同屏核对）。
        // 那不是一个死标签，而是**专辑列当前的排序模式名**（三档见 `SongsTableSort.AlbumSortMode`）：
        // 点这条列头＝按专辑排 + 轮换模式，所以它 `sortable`；但照旧不可隐藏、不可换位。
        // 实际显示的文字由 `SongsTableController.syncAlbumModeTitles` 按当前模式写上去。
        Column(key: .artwork, title: SongsTableSort.AlbumSortMode.byArtist.title, minWidth: 40,
               fixed: true, defaultWidth: M.artworkWidth, hiddenByDefault: true),
        // `[实测]` 装列的顺序就是「先专辑封面列(126)，再曲目封面列(37)，然后才轮到集合里的其它列」
        Column(key: .trackArtwork, minWidth: M.trackArtworkWidth, fixed: true,
               defaultWidth: M.trackArtworkWidth, hiddenByDefault: true, sortable: false,
               resizable: false),
        Column(key: .nowPlaying, minWidth: M.nowPlayingWidth, fixed: true,
               defaultWidth: M.nowPlayingWidth, hiddenByDefault: false, sortable: false),
        Column(key: .title, title: "标题", minWidth: 170, fixed: true,
               defaultWidth: M.titleWidth, hiddenByDefault: false),
        // 勾选列：列头一枚 ✓，不排序也不拖宽，但**可以拖着换位**（见 `Key.checked`）。
        Column(key: .checked, icon: "checkmark", minWidth: Self.checkedColumnWidth,
               defaultWidth: Self.checkedColumnWidth, hiddenByDefault: true, sortable: false,
               resizable: false),
        Column(key: .cloud, icon: "icloud", minWidth: 22, defaultWidth: M.cloudWidth,
               hiddenByDefault: false, resizable: false),
        Column(key: .duration, title: "时长", trailing: true, minWidth: 40,
               defaultWidth: M.durationWidth, hiddenByDefault: false),
        Column(key: .artist, title: "艺人", minWidth: 60, defaultWidth: M.artistWidth,
               hiddenByDefault: false),
        Column(key: .album, title: "专辑", defaultWidth: M.albumWidth, hiddenByDefault: false),
        Column(key: .genre, title: "类型", defaultWidth: M.genreWidth, hiddenByDefault: false),
        Column(key: .favorite, icon: "star", minWidth: 22, defaultWidth: M.favoriteWidth,
               hiddenByDefault: false, resizable: false),
        Column(key: .rating, title: "评分", minWidth: 79, defaultWidth: M.ratingWidth,
               hiddenByDefault: false, resizable: false),
        Column(key: .playCount, title: "播放次数", trailing: true, minWidth: 68,
               defaultWidth: M.playCountWidth, hiddenByDefault: false),

        Column(key: .albumArtist, title: "专辑艺人", defaultWidth: 125),
        Column(key: .year, title: "年份", defaultWidth: 50),
        Column(key: .releaseDate, title: "发布日期", defaultWidth: 94),
        Column(key: .trackNumber, title: "音轨编号", trailing: true, defaultWidth: 70),
        Column(key: .discNumber, title: "光盘编号", trailing: true, defaultWidth: 91),
        Column(key: .albumRating, title: "专辑评分", minWidth: 79, defaultWidth: 100),
        Column(key: .dateAdded, title: "添加日期", defaultWidth: 125),
        Column(key: .lastPlayed, title: "上次播放时间", defaultWidth: 125),
        Column(key: .skips, title: "跳过次数", trailing: true, minWidth: 60, defaultWidth: 65),
        Column(key: .lastSkipped, title: "上次跳过时间", defaultWidth: 125),
        Column(key: .kind, title: "种类", defaultWidth: 100),
        Column(key: .cloudStatus, title: "云端状态", defaultWidth: 100),

        Column(key: .composer, title: "作曲者", defaultWidth: 125),
        Column(key: .grouping, title: "归类", defaultWidth: 125),
        Column(key: .work, title: "作品", defaultWidth: 125),
        Column(key: .movementName, title: "乐章名称", defaultWidth: 125),
        Column(key: .movementNumber, title: "乐章编号", trailing: true, minWidth: 64,
               defaultWidth: 76),
        Column(key: .category, title: "类别", defaultWidth: 80),
        Column(key: .description, title: "描述", defaultWidth: 250),
        Column(key: .comments, title: "注释", defaultWidth: 250),
        Column(key: .bpm, title: "每分钟拍数", trailing: true, defaultWidth: 88),
        Column(key: .equalizer, title: "均衡器", minWidth: 60, defaultWidth: 125),
        Column(key: .bitRate, title: "位速率", trailing: true, defaultWidth: 80),
        Column(key: .sampleRate, title: "采样速率", trailing: true, defaultWidth: 91),
        Column(key: .size, title: "大小", trailing: true, defaultWidth: 60),
        Column(key: .dateModified, title: "修改日期", defaultWidth: 125),
        Column(key: .purchaseDate, title: "购买日期", defaultWidth: 125),
        Column(key: .sortName, title: "标题分类", defaultWidth: 125),
        Column(key: .sortAlbum, title: "专辑分类", defaultWidth: 125),
        Column(key: .sortArtist, title: "艺人分类", defaultWidth: 125),
        Column(key: .sortAlbumArtist, title: "专辑艺人分类", defaultWidth: 125),
        Column(key: .sortComposer, title: "作曲者分类", defaultWidth: 125),
    ]

    /// 列头右键菜单的排列：Music 按中文拼音排这 40 项（实录顺序照搬），
    /// 播放指示与标题两条固定列不在菜单里。
    static let toggleMenuOrder: [Key] = [
        .sortName, .playCount, .sampleRate, .size, .releaseDate, .purchaseDate, .discNumber,
        .grouping, .equalizer, .movementNumber, .movementName, .category, .genre, .bpm,
        .description, .year, .rating, .lastPlayed, .lastSkipped, .duration, .dateAdded,
        .skips, .bitRate, .favorite, .dateModified, .artist, .sortArtist, .trackNumber,
        .cloud, .cloudStatus, .kind, .comments, .album, .sortAlbum, .albumRating,
        .albumArtist, .sortAlbumArtist, .work, .composer, .sortComposer,
    ]

    /// 「排序选项」子菜单的排列。Music 也是按拼音排（2026-08-15 AX 实录，当时显示的九列是
    /// 标题 播放次数 类型 评分 时长 喜爱 艺人 云端下载 专辑），只列**当前显示且能排序**的列。
    /// 标题是固定列、不在增删菜单里，但排序菜单里有它，且「标题」(biaoti) 排在
    /// 「标题分类」(biaotifenlei) 之前，故直接接在最前面。
    static let sortMenuOrder: [Key] = [.title] + toggleMenuOrder

    /// 「显示选项」窗口里的一组勾选框。
    struct OptionGroup: Identifiable {
        let title: String
        /// 组内排列＝拼音序（与增删菜单同一套序）
        let keys: [Key]
        var id: String { title }
        /// Music 是**按列填**的：左列先放 ⌈n/2⌉ 项，余下的进右列
        var leading: [Key] { Array(keys.prefix((keys.count + 1) / 2)) }
        var trailing: [Key] { Array(keys.dropFirst((keys.count + 1) / 2)) }
        /// 「音乐」组没有折叠三角，永远展开；其余五组都能折叠
        var collapsible: Bool { title != "音乐" }
    }

    /// 「显示选项」窗口的分组（2026-08-15 从 Music 1.7 的 AX 逐项实录，含折叠起来的三组）。
    /// 40 项可选列在这里被分成六组，正好覆盖增删菜单里的同一批列。
    static let optionGroups: [OptionGroup] = [
        OptionGroup(title: "音乐", keys: pinyin([
            .releaseDate, .discNumber, .equalizer, .movementNumber, .movementName, .genre,
            .bpm, .year, .duration, .artist, .trackNumber, .cloud, .cloudStatus, .album,
            .albumArtist, .work, .composer,
        ])),
        OptionGroup(title: "个人", keys: pinyin([
            .grouping, .description, .rating, .favorite, .comments, .albumRating,
        ])),
        OptionGroup(title: "统计数据", keys: pinyin([
            .playCount, .purchaseDate, .lastPlayed, .lastSkipped, .dateAdded, .skips, .dateModified,
        ])),
        OptionGroup(title: "文件", keys: pinyin([.sampleRate, .size, .bitRate, .kind])),
        OptionGroup(title: "分类", keys: pinyin([
            .sortName, .sortArtist, .sortAlbum, .sortAlbumArtist, .sortComposer,
        ])),
        OptionGroup(title: "其他", keys: pinyin([.category])),
    ]

    /// 按增删菜单那套拼音序排一组列，免得每处再抄一遍顺序。
    private static func pinyin(_ keys: [Key]) -> [Key] {
        toggleMenuOrder.filter(keys.contains)
    }

    static func column(_ key: Key) -> Column { all.first { $0.key == key } ?? all[0] }

    /// 菜单与排序里都要用的列名；图标列没有列头文字，另给一个。
    static func title(for key: Key) -> String {
        switch key {
        case .cloud: return "云端下载"
        case .favorite: return "喜爱"
        default: return column(key).title ?? ""
        }
    }

    /// 列头对 AX 播报的名字。Music 的 10 个 AXSortButton 连没有可见文字的列也带标题
    /// （状态／云端下载／喜爱），照抄这套命名，两边的列宽才能逐列对上。
    static func accessibilityTitle(for key: Key) -> String {
        switch key {
        case .nowPlaying: return "状态"
        // 勾选列没有列头文字，但列头本身仍是一颗可聚焦的按钮，得有个名字。
        case .checked: return "勾选"
        default: return title(for: key)
        }
    }

    private var widths: [Key: CGFloat] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key, $0.defaultWidth) })
    private var hidden: Set<Key> = Set(all.filter(\.hiddenByDefault).map(\.key))
    /// 当前的左右顺序。Music 的列头可以拖着换位（`tableView:shouldReorderColumn:toColumn:`），
    /// 所以顺序是可变状态，`all` 的排列只是出厂默认。
    private var order: [Key] = all.map(\.key)

    /// 「显示插图」是否打开。插图列不受右键菜单管，只听这一处。
    var showsArtwork = false
    /// 「显示曲目插图」是否打开——对应 `showTrackArtwork`，管的是每行那张小封面。
    var showsTrackArtwork = false
    /// 通用页「显示 › 星级评分」是否打开（由 `SongsTableSettings` 从`AppSettings` 镜像过来）。
    /// 关掉时下面那两条星级列整个不存在：既不出现在表里，也不出现在增删菜单／显示选项里。
    ///
    /// 它**不进存档**：这是一条应用级偏好，跟 `showsArtwork` 一样只是镜像，
    /// 存档里的列宽／显隐／顺序原样不动——开关再打开时那两列回到用户原来的样子。
    var showsStarRatings = true
    /// 通用页「显示 › 歌曲列表复选框」是否打开（同样由 `SongsTableSettings` 镜像过来）。
    /// 与 `showsArtwork` 同性质：这一列不受列头右键菜单管，只听这一处，也不进存档。
    var showsCheckboxes = false

    /// 归「星级评分」这条开关管的列。
    static let starRatingKeys: Set<Key> = [.rating, .albumRating]

    /// 当前显示的列，按当前顺序。
    var visible: [Column] {
        order.filter { key in
            switch key {
            case .checked: return showsCheckboxes
            case .artwork: return showsArtwork
            case .trackArtwork: return showsTrackArtwork
            case .rating, .albumRating: return showsStarRatings && !hidden.contains(key)
            default: return !hidden.contains(key)
            }
        }
        .map(Self.column)
    }

    /// 这一列现在该不该出现在增删菜单／「显示选项」窗口里。
    /// 星级评分关掉时那两项连勾选框都不列出来——留着一个勾了也不出列的框只会让人以为坏了。
    func isListed(_ key: Key) -> Bool {
        showsStarRatings || !Self.starRatingKeys.contains(key)
    }

    /// 「显示选项」窗口里一组勾选框去掉当前不该出现的项之后的样子。
    /// 左右两栏按**剩下的**项重新对半分，否则藏掉一项会在栏里留个空洞。
    func listed(_ group: OptionGroup) -> OptionGroup {
        OptionGroup(title: group.title, keys: group.keys.filter(isListed))
    }

    /// 实际行高。开曲目封面列时 Music 把行高顶到 **54**
    /// （`[实测]` `desiredRowHeight`：`showTrackArtwork` 为真直接返回 54，
    /// 不再按列表尺寸分档），否则就是全局偏好那三档。
    func rowHeight(base: CGFloat) -> CGFloat {
        showsTrackArtwork ? M.trackArtworkRowHeight : base
    }

    /// 拖列换位准不准：**从起点到落点这一段里，每一列都得是可移动的**
    /// （`[实测]` 的区间判定）。播放指示、标题与两条插图列的`mMoveable` 为假，
    /// 所以它们既不能被拖走，别的列也插不到它们前面——区间一旦盖住它们就整体不准。
    ///
    /// 落点索引用的是 NSTableView 的语义：`to` 是这一列**将要落到的**可见列序，
    /// 可以等于列数（拖到最右端之后）。
    ///
    /// 起手那一问 `to == -1` 必须放行：AppKit 一按下就先拿 -1 问一次
    /// 「这一列到底能不能拖」（`tableView:shouldReorderColumn:toColumn:` 的约定），
    /// 这一问答 false，整场拖动根本不会开始——列头看着毫无反应。
    static func canReorder(visible: [Column], from: Int, to: Int) -> Bool {
        guard visible.indices.contains(from), !visible[from].fixed else { return false }
        guard to >= 0 else { return true }
        guard to <= visible.count, from != to else { return false }
        let lower = min(from, to)
        let upper = min(max(from, to), visible.count - 1)
        return visible[lower...upper].allSatisfy { !$0.fixed }
    }

    /// 把可见列的左右顺序整份换成 `keys`。隐藏列不在拖动范围里，仍旧留在它原来的槽位上。
    mutating func applyVisibleOrder(_ keys: [Key]) {
        let shown = Set(visible.map(\.key))
        guard keys.count == shown.count, Set(keys) == shown else { return }
        var result = order
        var next = keys.makeIterator()
        for (index, key) in order.enumerated() where shown.contains(key) {
            guard let replacement = next.next() else { break }
            result[index] = replacement
        }
        order = result
    }

    /// 排序菜单里可选的列：当前显示且能排序的，按拼音序（与 Music 的子菜单一致，
    /// **不是**表格从左到右的顺序）。
    var sortableColumns: [Key] {
        Self.sortMenuOrder.filter {
            isListed($0) && !hidden.contains($0) && Self.column($0).sortable
        }
    }

    subscript(key: Key) -> CGFloat {
        // 开插图列时「状态」那条槽要放曲目编号，Music 实测由 26 撑到 56
        if key == .nowPlaying, showsArtwork { return M.artworkStatusWidth }
        return widths[key] ?? 60
    }

    /// 「插图大小」滑杆的三档＝**封面铺几行**（`[实测]` `currArtworkRowSpan`）。
    var artworkRowSpan: Int {
        M.artworkRowSpans[min(max(artworkSize, 0), M.artworkRowSpans.count - 1)]
    }

    /// 封面边长由行高推出来，不是写死的三个数
    /// （`[实测]` `currArtworkDimension`：行高 × 跨行数 − 边距 × 2）。
    /// 列表尺寸一变（行高 18/22/40），封面跟着变。
    func artworkCoverSize(rowHeight: CGFloat) -> CGFloat {
        rowHeight * CGFloat(artworkRowSpan) - M.albumArtMargin * 2
    }

    /// 插图格里文字的左沿：内缩 + 封面 + 间距。
    /// **不管封面画不画都用这个值**——Music 里组太矮没画封面时，那段宽度照样空着，
    /// 每组的专辑名左沿因此永远在同一条竖线上。
    func artworkTextLeading(rowHeight: CGFloat) -> CGFloat {
        M.artworkInset + artworkCoverSize(rowHeight: rowHeight) + M.artworkCoverGap
    }

    /// 插图列拖窄时的**动态下限**：左右各一份内缩 + 封面。
    ///
    /// 出处是**用户实机对照 Music 的观察**（2026-09-07），不是 `[实测]`：Music 里把插图列
    /// 往窄拖，拖不过一个下限，**封面始终完整**，先被挤掉的是右边那三行附带信息
    /// （专辑名／艺人截断成「帶…」「告…」、星星被裁）。而 plist 里的
    /// `minimum-column-width` 只有 40，`setAlbumArtworkSize:` 也只做失效重载、
    /// 不碰列宽——所以保住封面的那条线不是静态的 40，是跟着当前封面边长走的。
    ///
    /// 左右**各一份** `artworkInset`（7），封面在最窄那一档是居中的：只算左边那份的话
    /// 右边就贴着列的分隔线、比左边还窄，看着是歪的（用户 2026-09-07 实机指出）。
    /// 仍**不含** `artworkCoverGap` 那 8——那是封面与文字之间的间距，拖到底时文字那一侧
    /// 已经被完全挤掉，不该再为它留位置。
    func artworkMinWidth(rowHeight: CGFloat) -> CGFloat {
        M.artworkInset * 2 + artworkCoverSize(rowHeight: rowHeight)
    }

    /// 「插图大小」滑杆的档位 0/1/2
    var artworkSize = 0

    var totalWidth: CGFloat { visible.reduce(0) { $0 + self[$1.key] } }

    func isVisible(_ key: Key) -> Bool { !hidden.contains(key) }

    mutating func toggleVisible(_ key: Key) {
        guard !Self.column(key).fixed else { return }
        if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
    }

    mutating func setWidth(_ width: CGFloat, for key: Key) {
        widths[key] = max(Self.column(key).minWidth, width)
    }

    /// 列宽、显隐与顺序跨启动保留，与 Music 一致。
    private struct Storage: Codable {
        var widths: [String: CGFloat] = [:]
        var hidden: [String] = []
        var order: [String]?
        /// 存档时一共有哪些列。只记 hidden 的话，版本升级新增的列会被当成「没被藏起来」
        /// 而全部冒出来；有了这份清单，存档里没见过的列就按它自己的出厂显隐走。
        var known: [String]?
    }

    var encoded: String {
        let storage = Storage(
            widths: widths.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            hidden: hidden.map(\.rawValue),
            order: order.map(\.rawValue),
            known: Key.allCases.map(\.rawValue))
        guard let data = try? JSONEncoder().encode(storage) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func decode(_ json: String) {
        guard let data = json.data(using: .utf8),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        for (name, width) in storage.widths {
            guard let key = Key(rawValue: name) else { continue }
            widths[key] = max(Self.column(key).minWidth, width)
        }
        let known = Set((storage.known ?? storage.hidden).compactMap(Key.init(rawValue:)))
        let archived = Set(storage.hidden.compactMap(Key.init(rawValue:)))
        hidden = Set(Key.allCases.filter { key in
            guard !Self.column(key).fixed else { return false }
            // 存档见过的列听存档的，没见过的（新增列，或旧版存档）按出厂显隐
            return known.contains(key) ? archived.contains(key) : Self.column(key).hiddenByDefault
        })
        if let stored = storage.order?.compactMap(Key.init(rawValue:)) {
            // 版本升级新增的列不会出现在存档里，得按出厂顺序**插回原位**。
            // 早先是往末尾一追了事，结果新加的曲目封面列（出厂时排在最左第二）
            // 一读旧存档就跑到了最右边——开了开关也看不见它。
            var merged = stored
            let factory = Self.all.map(\.key)
            for (index, key) in factory.enumerated() where !stored.contains(key) {
                // 找它在出厂序里前面、且已经排进来的那一列，插在它后头
                let previous = factory.prefix(index).last { merged.contains($0) }
                if let previous, let at = merged.firstIndex(of: previous) {
                    merged.insert(key, at: at + 1)
                } else {
                    merged.insert(key, at: 0)
                }
            }
            order = merged
            normalizeCheckedPosition()
        }
    }

    /// 勾选列曾经是钉在最左的固定列，那一版的存档里它排在标题之前。
    /// 新规则下它落不到标题左边（标题是固定列，`canReorder` 的区间判定过不去），
    /// 存档里留着的那个位置只会让它继续看着像钉死的——一律搬回出厂位。
    private mutating func normalizeCheckedPosition() {
        guard let checked = order.firstIndex(of: .checked),
              let title = order.firstIndex(of: .title), checked < title
        else { return }
        order.remove(at: checked)
        let factory = Self.all.map(\.key)
        guard let slot = factory.firstIndex(of: .checked),
              let previous = factory.prefix(slot).last(where: order.contains),
              let at = order.firstIndex(of: previous)
        else { return order.insert(.checked, at: 0) }
        order.insert(.checked, at: at + 1)
    }

    /// 日期列的写法跟 Music 一致：年/月/日 + 时:分。
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// 单元格文字。行绘制与「自动调整列大小」的测宽共用一份，免得两边算得不一样。
    @MainActor
    static func text(for key: Key, track: Track, library: LibraryStore,
                     downloads: DownloadStore) -> String {
        func date(_ value: Date?) -> String { value.map { dateFormatter.string(from: $0) } ?? "" }
        func count(_ value: Int) -> String { value > 0 ? "\(value)" : "" }

        switch key {
        case .title: return track.title
        case .duration: return track.duration.mmss
        case .artist: return track.artistName
        case .album: return track.albumName
        case .albumArtist: return library.albumArtist(for: track) ?? ""
        case .genre: return library.genre(for: track) ?? ""
        case .year: return library.year(for: track) ?? ""
        case .releaseDate: return library.releaseDate(for: track) ?? ""
        case .trackNumber: return track.trackNumber.map(String.init) ?? ""
        case .discNumber: return track.discNumber.map(String.init) ?? ""
        case .playCount: return count(library.playCount(for: track.id))
        case .skips: return count(library.skipCount(for: track.id))
        case .dateAdded: return date(library.addedAt[track.id])
        case .lastPlayed: return date(library.lastPlayedAt[track.id])
        case .lastSkipped: return date(library.lastSkippedAt[track.id])
        // Music 的「种类」写的是文件格式（如「已购买的 AAC 音频文件」）；
        // Amber 的在线曲目写成音源 + 在线音频，本地导入的写文件本身的容器。
        case .kind:
            if track.isLocal {
                // **只读内存那份 `states`，一次库查询、一次 stat 都不做**：这段在表格
                // 单元格的逐行绘制里跑（同一份实现还兼「自动调整列大小」的测宽，
                // 一屏能调上百次）。`state(for:)` 是一次字典查找，`fileURL(for:)`
                // 会 stat 文件——那一条给取流与信息面板用，不能下到这里。
                guard case .downloaded(let url) = downloads.state(for: track.id) else {
                    return "音频文件"
                }
                let ext = url.pathExtension.uppercased()
                return ext.isEmpty ? "音频文件" : "\(ext) 音频文件"
            }
            return "\(track.kind.displayName)在线音频"
        // 「云端状态」在 Music 里是 iCloud 音乐资料库的状态，Amber 用音源顶上；
        // 已经下载到本地的写「已下载」。
        // **Music 这一列上其实只有图标、没有文字**：那 14 条状态文案（res 9000 idx 76–89）
        // 在原版里一个取用点都没有（library spec §10.5 批次 45 的负结论，131 处
        // `movk #9000` 逐处核过）。Amber 这一列给文字是自己的选择，不是照它抄的。
        case .cloudStatus:
            // 本地导入的歌本来就在本机，不是「从云端下载过」。
            if track.isLocal { return "本地文件" }
            if downloads.isDownloaded(track.id) { return "已下载" }
            return library.isInLibrary(track) ? track.kind.displayName : ""
        // 以下几列音源都不提供：文件属性（大小/位速率/采样速率/修改日期）、
        // 购买信息、古典乐的作品与乐章、以及 Music 那套「分类用名」标签。
        // 列保留是为了跟 Music 的菜单对齐，勾上就是空列。
        case .composer, .grouping, .work, .movementName, .movementNumber, .category,
             .description, .comments, .bpm, .equalizer, .bitRate, .sampleRate, .size,
             .dateModified, .purchaseDate,
             .sortName, .sortAlbum, .sortArtist, .sortAlbumArtist, .sortComposer:
            return ""
        case .checked, .nowPlaying, .cloud, .favorite, .rating, .albumRating,
             .artwork, .trackArtwork:
            return ""
        }
    }

    /// 排序取值：数字列按数字比，其余按文本比（空值排在前，与 Music 一致）。
    @MainActor
    static func sortValue(for key: Key, track: Track, library: LibraryStore,
                          downloads: DownloadStore) -> SortValue {
        func stamp(_ value: Date?) -> SortValue { .number(value?.timeIntervalSince1970 ?? 0) }

        switch key {
        case .duration: return .number(track.duration)
        case .playCount: return .number(Double(library.playCount(for: track.id)))
        case .skips: return .number(Double(library.skipCount(for: track.id)))
        case .rating: return .number(Double(library.rating(for: track.id)))
        case .albumRating: return .number(Double(library.albumRating(for: track)))
        case .trackNumber: return .number(Double(track.trackNumber ?? 0))
        case .discNumber: return .number(Double(track.discNumber ?? 0))
        case .favorite: return .number(library.isFavorite(track) ? 1 : 0)
        // 云端下载列按下载态排：已下载 > 下载中 > 未下载（失败按未下载算，它本来就还没下来）。
        case .cloud:
            switch downloads.state(for: track.id) {
            case .downloaded: return .number(2)
            case .downloading: return .number(1)
            case .none, .failed: return .number(0)
            }
        case .dateAdded: return stamp(library.addedAt[track.id])
        case .lastPlayed: return stamp(library.lastPlayedAt[track.id])
        case .lastSkipped: return stamp(library.lastSkippedAt[track.id])
        default: return .text(text(for: key, track: track, library: library, downloads: downloads))
        }
    }

    enum SortValue: Equatable {
        case number(Double)
        case text(String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.number(a), .number(b)): return a < b
            case let (.text(a), .text(b)): return a.localizedStandardCompare(b) == .orderedAscending
            default: return false
            }
        }
    }
}

// MARK: - 排序

/// 列头点一下按该列升序，再点一下降序（与 Music.app 一致）。
struct SongsTableSort: Equatable {
    /// 「专辑」这一列有三种排法。Music 的插图列头写着「按艺人排列专辑」，
    /// 那不是插图列的名字，而是**专辑列当前的排序模式**（2026-08-16 同屏核对到的那一档）。
    /// 三档只在排序列是专辑时才有意义，别的列在排时它只是个待命的状态。
    enum AlbumSortMode: Int, CaseIterable, Codable {
        case album, byArtist, byArtistYear

        var title: String {
            switch self {
            case .album: return "专辑"
            case .byArtist: return "按艺人排列专辑"
            case .byArtistYear: return "按艺人/年份排列专辑"
            }
        }

        var next: AlbumSortMode {
            AlbumSortMode(rawValue: rawValue + 1) ?? .album
        }
    }

    /// Music 的默认排序就是「艺人」升序（参照页的方向箭头挂在艺人列上）。
    var column: SongsTableColumns.Key = .artist
    var ascending = true
    /// 专辑列的排序模式。出厂是「专辑」：参照页（songs.png，未开插图、按艺人排）的专辑列头
    /// 写的就是「专辑」；而开着插图时同屏核对到的列头是「按艺人排列专辑」——两次实测合起来
    /// 就是：打开「显示插图」那一下把模式抬到「按艺人排列专辑」（见 SongsTableSettings.showArtwork）。[推]
    var albumMode: AlbumSortMode = .album

    static func title(for column: SongsTableColumns.Key) -> String {
        SongsTableColumns.title(for: column)
    }

    mutating func toggle(_ column: SongsTableColumns.Key) {
        if self.column == column {
            ascending.toggle()
        } else {
            self.column = column
            ascending = true
        }
    }

    /// 点插图列头：按专辑排，并轮换专辑排序模式。
    ///
    /// [推] 三档轮完一圈才翻升降序——插图列头本身不显示方向箭头（箭头挂在专辑列上），
    /// 一次点击既换模式又翻方向的话，六种组合里有一半永远点不到。
    /// 本来在排别的列时，头一下只是把排序接管到专辑上，模式不动。
    mutating func cycleAlbumMode() {
        guard column == .album else {
            column = .album
            ascending = true
            return
        }
        albumMode = albumMode.next
        if albumMode == .album { ascending.toggle() }
    }

    /// 排序键在比较器里现算的话，一次排序要算 n log n 次（每次都查一遍资料库、
    /// 拼一次字符串）。改成 decorate-sort-undecorate：每条先算一次键再排，
    /// 比较器只比现成的值——次序与逐次现算完全一致。
    @MainActor
    func apply(to tracks: [Track], library: LibraryStore, downloads: DownloadStore) -> [Track] {
        let decorated = tracks.map {
            (track: $0, values: sortKeys(for: $0, library: library, downloads: downloads))
        }
        let sorted = decorated.sorted { lhs, rhs in
            for (left, right) in zip(lhs.values, rhs.values) where left != right {
                return left < right
            }
            return tieBreak(lhs.track, rhs.track, library: library)
        }
        .map(\.track)
        return ascending ? sorted : sorted.reversed()
    }

    /// 一行的排序键。一般的列就一条；**专辑列**按当前模式多带几条，
    /// 这样同一张碟才会连成一块（插图列就是靠「上下两行是不是同一张专辑」切块的）：
    /// - 专辑：专辑名 → 光盘号 → 音轨号
    /// - 按艺人排列专辑：艺人 → 专辑名 → 光盘号 → 音轨号
    /// - 按艺人/年份排列专辑：艺人 → 年份 → 专辑名 → 光盘号 → 音轨号
    @MainActor
    private func sortKeys(for track: Track, library: LibraryStore,
                          downloads: DownloadStore) -> [SongsTableColumns.SortValue] {
        guard column == .album else {
            return [SongsTableColumns.sortValue(for: column, track: track,
                                                library: library, downloads: downloads)]
        }
        let album = SongsTableColumns.SortValue.text(track.albumName)
        let disc = SongsTableColumns.SortValue.number(Double(track.discNumber ?? 0))
        let number = SongsTableColumns.SortValue.number(Double(track.trackNumber ?? 0))
        switch albumMode {
        case .album:
            return [album, disc, number]
        case .byArtist:
            return [.text(track.artistName), album, disc, number]
        case .byArtistYear:
            return [.text(track.artistName), .text(library.year(for: track) ?? ""),
                    album, disc, number]
        }
    }

    /// 同值时的次序：艺人 → 专辑 → 光盘 → 碟内曲序 → 标题。
    /// Music 就是这么收敛的——按艺人排出来的表，同一位艺人里仍然是一张碟一张碟按曲序排。
    @MainActor
    private func tieBreak(_ lhs: Track, _ rhs: Track, library: LibraryStore) -> Bool {
        if column != .artist, lhs.artistName != rhs.artistName {
            return before(lhs.artistName, rhs.artistName)
        }
        if lhs.albumName != rhs.albumName { return before(lhs.albumName, rhs.albumName) }
        let leftDisc = lhs.discNumber ?? 0, rightDisc = rhs.discNumber ?? 0
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        let leftNumber = lhs.trackNumber ?? 0, rightNumber = rhs.trackNumber ?? 0
        if leftNumber != rightNumber { return leftNumber < rightNumber }
        return before(lhs.title, rhs.title)
    }

    private func before(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

// `SongsSearchField`（NSSearchField 的 NSViewRepresentable 壳）已删除。
// 搜索框现在直接是 AppKit 的一件：`ContentToolbar.swift` 里的`MusicSearchField`
// 沿用同一份「把固有尺寸改成 211×38」的做法（NSSearchField 的固有高度到不了 38，
// SwiftUI 的 .frame(height:) 也拉不动它），接线由 `SearchFieldBinder` 做。
