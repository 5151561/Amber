import AppKit
import Combine
import SwiftUI

// MARK: - 单元格状态

/// 一格要画的东西。与 Track 一样是值，比对相等就能省掉一次 SwiftUI 重画。
struct SongsCellData: Equatable {
    var key: SongsTableColumns.Key = .title
    var track: Track?
    var rowHeight: CGFloat = MusicMetrics.SongsTable.rowHeight
    var fontSize: CGFloat = MusicMetrics.SongsTable.fontSize
    /// 开「显示插图」时「状态」那条槽要放曲目编号
    var showsArtworkColumn = false
    // 以下几项只有插图列用：本行是所属块的第几片、块有多少行、封面能铺几行
    var blockIndex = 0
    var blockLength = 1
    var rowSpan = 3
    /// 占位默认值：中档行高 22 下的 3 行档（22×3 − 5×2 = 56）。实际值由控制器按行高灌进来。
    var coverSize: CGFloat = 56
    var textLeading: CGFloat = 0
    var alwaysShowsCover = false
    /// 单元格自己的宽度，由 `SongsRichCellView.layout()` 量了回灌（0 ＝ 还没量到，走老路）。
    ///
    /// 富单元格的 `NSHostingView` 是`sizingOptions = []`，Apple 文档原话是「帧比内容小时
    /// **内容居中**」（AGENTS 铁律 2）。插图块里文字那一支的左内缩是硬性的 `textLeading`
    /// （7 + 封面 + 8），把列拖到下限（7 + 封面）时这块内容的最小宽度就比列宽还大，
    /// 于是整块被居中——**封面的左边被切掉**。要躲开居中，内容就得永远不超过单元格宽度，
    /// 所以这里把宽度从 AppKit 递给 SwiftUI，让它照着排、超出的从右边裁。
    var cellWidth: CGFloat = 0
}

/// 单元格与 SwiftUI 内容之间的那根线。
///
/// 选中/悬浮是行视图推下来的（＝Music 的 `tableView:setRollover:forRow:` 与
/// `setRolloverState:`），内容是控制器在`viewFor` 里推下来的。
@MainActor
@Observable
final class SongsCellState {
    var data = SongsCellData()
    var selected = false
    var rollover = false
    /// ••• 菜单的作用集：点在选中行上就是整份选中集，否则只有这一行。
    /// 菜单内容是打开时才求值的，所以这里放闭包而不是快照。
    ///
    /// 闭包标 `@ObservationIgnored`：它不是「状态」，参与观察只会白记一次依赖。
    @ObservationIgnored var menuTracks: () -> [Track] = { [] }
    /// ••• 菜单里的「播放」＝从列表播放：队列是整份可见行，起播的是这一行。
    @ObservationIgnored var menuPlayContext: () -> TrackPlayContext? = { nil }
}

// MARK: - 富单元格

/// 装 SwiftUI 的那几格：播放指示、标题（含 •••）、云端下载、心水、评分、曲目封面、专辑插图。
///
/// 其余列一律走 `SongsTextCellView`——一屏十来列乘四十行，全套 NSHostingView 太重，
/// 只有真的带控件的格子才值得。
final class SongsRichCellView: NSTableCellView {
    private typealias M = MusicMetrics.SongsTable

    let state = SongsCellState()
    private let key: SongsTableColumns.Key

    init(key: SongsTableColumns.Key, appState: AppState,
         identifier: NSUserInterfaceItemIdentifier) {
        self.key = key
        super.init(frame: .zero)
        self.identifier = identifier
        // 单元格读的是播放器、资料库与下载态；AppState 本体只为 ••• 菜单里的
        // 前往专辑/新建播放列表。四件各自注入，谁变了刷谁。
        let host = NSHostingView(rootView: SongsTableCellContent(state: state)
            .environmentObject(appState)
            .environment(appState.player)
            .environment(appState.library)
            .environment(appState.downloads))
        host.translatesAutoresizingMaskIntoConstraints = false
        // 一格只准画自己那块矩形。NSTableCellView 默认不裁剪，SwiftUI 那边算出来的内容
        // 比当前列宽宽时就直接画到右边那一列上去了——插图格最明显：列拖窄之后
        // 专辑名/艺人/星级会压在「状态」列上，拖的过程中还会甩进列头那一条。
        // （拖宽时 AppKit 先改单元格 frame，SwiftUI 的重排要晚一拍，这一拍里必然溢出。）
        // 裁在 layer 上，像素一个不动。
        wantsLayer = true
        layer?.masksToBounds = true
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: Track, data: SongsCellData, controller: SongsTableController) {
        var data = data
        // `cellWidth` 归本视图所有（在`layout()` 里量），控制器灌数据时并不知道它。
        // 不接过来的话每次 `viewFor` 都会先把它冲成 0、再被下一次`layout()` 改回去，来回抖。
        // 复用是按列分桶的（identifier 带 key），同一个桶里的单元格宽度必然相同，接得住。
        data.cellWidth = state.data.cellWidth
        if state.data != data { state.data = data }
        state.menuTracks = { [weak controller, weak self] in
            guard let controller, let self else { return [] }
            return controller.menuTracks(forCell: self)
        }
        state.menuPlayContext = { [weak controller, weak self] in
            guard let controller, let self else { return nil }
            return controller.playContext(forCell: self)
        }
    }

    /// 把单元格宽度回灌给 SwiftUI。拖列宽时 AppKit 会重新布局单元格，这条才跟得上。
    ///
    /// 两处防抖：
    /// 1. **先比对再赋值**。`state.data` 是`@Published`，无条件写会在每次布局都发一次变更，
    ///    SwiftUI 重排完又可能回头请求一次布局，两边来回打架。宽度没变就直接返回，
    ///    于是「布局 → 发布 → 重排 → 再布局」这条环第二圈就断了（第二圈宽度必然相同：
    ///    `sizingOptions = []` 的宿主视图尺寸由约束定，SwiftUI 内容量出来多宽都不回推）。
    /// 2. **只有插图列写**。别的富单元格没人读 `cellWidth`，写了只是白发一轮`objectWillChange`；
    ///    一屏几十格乘七列，拖一次列宽就是几百次空重排。写成通用的当然也能跑，
    ///    但 AGENTS 铁律 3 的取向就是「能不经过 `@Published` 就别经过」，这里照着收窄。
    override func layout() {
        super.layout()
        guard key == .artwork else { return }
        let width = bounds.width
        guard state.data.cellWidth != width else { return }
        state.data.cellWidth = width
    }

    func setState(selected: Bool, rollover: Bool) {
        if state.selected != selected { state.selected = selected }
        if state.rollover != rollover { state.rollover = rollover }
    }

    /// 只有真的有控件的那一小块收鼠标，其余让给表格——不然点在歌名上选不中行。
    /// SwiftUI 的宿主视图是一整块，命中范围只能在这儿按列切。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        guard interactiveRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    private var interactiveRect: NSRect {
        switch key {
        // 整格都是控件
        case .cloud, .favorite, .rating:
            return bounds
        // 标题列只有右端那枚 ••• 收事件
        case .title:
            let width = M.moreWidth + M.cellInset * 2
            return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        // 插图格里只有星级那一行能点（专辑评分 + 专辑心水），它落在块内第 3 片上
        case .artwork:
            guard state.data.blockIndex == 2 else { return .zero }
            let leading = state.data.textLeading
            return NSRect(x: leading, y: bounds.minY,
                          width: max(0, bounds.width - leading), height: bounds.height)
        // 播放指示与曲目封面不收事件，点它们就是选中这一行
        default:
            return .zero
        }
    }
}

// MARK: - 勾选单元格

/// 「歌曲列表复选框」那一列的格子。
///
/// 这里**不挂 `NSHostingView`**（AGENTS 铁律 2：滚动容器里的格子只有真需要 SwiftUI
/// 才独有的控件时才值得）。
///
/// 也**不用 `NSButton(checkboxWithTitle:)`**：系统复选框是 22pt 见方、勾上之后填主题色
/// （强调色）、聚焦还带一圈焦点环，参照图里那枚不是这样——它只有一行文字那么高，
/// 勾上是**中灰圆角方块 + 白勾**、没勾是**深一号的灰方块**，主题色一点不沾，
/// 窗口失焦也不变浅。系统控件没有这一档外观（`.bezelColor` 只染 bezel、
/// `controlAccentColor` 换不掉），所以整格自己画。
///
/// 状态由控制器在 `configure` 里推下来，点击经闭包回给`LibraryStore`，
/// 中间不经过 `@Published`（铁律 3）。整格都是命中区（`mouseDown` 落在 cell 上），
/// 不是只有那枚小方块能点。
final class SongsCheckboxCellView: NSTableCellView {

    /// 点了这一格：参数是复选框的新状态。
    var onToggle: ((Bool) -> Void)?

    /// 就是系统标准的复选框（Music 用的也是它），不自绘。
    /// 必须是 NSButton 这种**控件**：`NSTableView` 只把鼠标事件交给格子里的 NSControl
    ///（`validateProposedFirstResponder` 默认只放行控件），普通 NSView 的`mouseDown`
    /// 永远轮不到——上一版自绘的 NSView 就是这么「点不动」的。
    private let button: NSButton

    init(identifier: NSUserInterfaceItemIdentifier) {
        button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        super.init(frame: .zero)
        self.identifier = identifier
        // [PX] 参照图里那枚与正文同高，是小号的标准复选框；颜色跟系统走，不另配。
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setAccessibilityLabel("勾选")
        button.target = self
        button.action = #selector(toggled)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(checked: Bool, onToggle: @escaping (Bool) -> Void) {
        // 复用来的格子可能还带着上一行的状态，无条件写一次。
        button.state = checked ? .on : .off
        self.onToggle = onToggle
    }

    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                              y: ((bounds.height - size.height) / 2).rounded(),
                              width: size.width, height: size.height)
    }

    @objc private func toggled() {
        onToggle?(button.state == .on)
    }
}

// MARK: - 纯文本单元格

/// 艺人/专辑/类型/日期/数字这些列。直接画字符串：比 NSTextField 轻，
/// 左右内缩也能精确落在实测的 4.5 上（NSTextField 自带一点看不见的内缩）。
final class SongsTextCellView: NSTableCellView {
    private typealias M = MusicMetrics.SongsTable

    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var font: NSFont = .systemFont(ofSize: M.fontSize) {
        didSet { if font != oldValue { needsDisplay = true } }
    }
    /// 数字与日期列右对齐（对齐方式取自 ColumnWidths.plist 的 justification）
    var trailing = false {
        didSet { if trailing != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = trailing ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // SwiftUI 的 .primary 就是 labelColor（白 85%），别用纯白
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: M.cellInset, y: bounds.midY - size.height / 2,
                          width: max(0, bounds.width - M.cellInset * 2), height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

// MARK: - 单元格内容

/// 富单元格的 SwiftUI 内容。像素与旧的 `SongsTableRow` 一模一样，只是换了个宿主：
/// 行/列由 NSTableView 排，这里只负责一格里画什么。
struct SongsTableCellContent: View {
    var state: SongsCellState

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    /// 只给 ••• 菜单用（前往专辑 / 新建播放列表这类要 `AppState` 的动作）。
    @EnvironmentObject private var appState: AppState
    /// 单元格是 AppKit 表格里挂出来的 SwiftUI 子树，不在设置窗那棵环境里，走 shared
     private let settings = AppSettings.shared

    private typealias M = MusicMetrics.SongsTable

    private var data: SongsCellData { state.data }
    private var rowHeight: CGFloat { data.rowHeight }
    /// 悬浮与选中都让「操作类」图标显形；但只有选中会改行底色。
    private var revealsActions: Bool { state.rollover || state.selected }

    var body: some View {
        if let track = data.track {
            content(track)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ track: Track) -> some View {
        switch data.key {
        case .artwork: artworkCell(track)
        case .trackArtwork: trackArtworkCell(track)
        case .nowPlaying: nowPlayingCell(track)
        case .title: titleCell(track)
        case .cloud: cloudCell(track)
        case .favorite: favoriteCell(track)
        case .rating: ratingCell(track)
        default: EmptyView()
        }
    }

    // MARK: 逐行的格子

    /// 逐行的曲目封面（Music 字段 37 那一列）。
    /// 封面按行高收进来（`preferredWidthWithAspectRatio:rowHeight:` 的语义，
    /// `artworkAspectRatio` 在`initWithPlaylist:` 里被设成 1.0，所以是正方形）。
    private func trackArtworkCell(_ track: Track) -> some View {
        let size = rowHeight - M.trackArtworkInset * 2
        return ArtworkView(url: track.artworkURL, tint: Color.tint(for: track.kind),
                           points: ArtworkSize.row)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 独立的播放指示栏：永远占位，出现喇叭时不把歌名往右顶。
    /// 开插图列时这条槽还兼着曲目编号（Music 把它从 26 撑到 56 就是为了放号）。
    private func nowPlayingCell(_ track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        return Color.clear.overlay(alignment: data.showsArtworkColumn ? .trailing : .center) {
            if isCurrent {
                // [PX] 纯白（textColor），比 85% 的正文色更亮
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: M.nowPlayingIconSize))
                    .foregroundStyle(Color(nsColor: .textColor))
            } else if data.showsArtworkColumn, let number = track.trackNumber {
                Text("\(number)")
                    .font(.system(size: data.fontSize).monospacedDigit())
                    .padding(.trailing, M.cellInset)
            }
        }
    }

    /// 标题列右端常驻一枚品牌红 •••，标题在它之前截断。
    /// 原始文件找不着的那一行在歌名前面多一枚 `!`（spec §10.1，见下面`missingMark`）。
    private func titleCell(_ track: Track) -> some View {
        HStack(spacing: 0) {
            missingMark(track)
            Text(track.title)
                .font(.system(size: data.fontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu
        }
        .padding(.horizontal, M.cellInset)
    }

    /// 「找不到标有“!”的文件。」（res 143 idx 24）——条目不删，只在行上打这枚标记
    /// （`library 规格` §10.1 第 2 条）。
    ///
    /// **摆在哪、长什么样仍是 `[推]`**：§10.1 整节批次 45 已升到`[实测]`（这句的取串点就在
    /// 收尾里），但那只坐实了「有这么一枚 `!`」，位置与字号一个没量过。
    /// 这里取歌名前面一格、跟着正文字号走的
    /// `exclamationmark.circle`，理由是它必须与歌名同高同基线（行高不能被它撑开），
    /// 而且要在**歌名之前**被读到——这一行的意思是「这首歌现在用不了」，
    /// 摆到右边就成了脚注。哪天量到真值，换这一处即可。
    @ViewBuilder
    private func missingMark(_ track: Track) -> some View {
        if library.isFileMissing(track.id) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: data.fontSize))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .help("找不到这首歌的原始文件。")
        }
    }

    private var moreMenu: some View {
        Menu {
            MenuSpec.Rows(TrackActions(tracks: state.menuTracks(), appState: appState,
                                       playContext: state.menuPlayContext()).libraryRow())
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: M.moreSize))
                .foregroundStyle(Color.amberKey)
                .frame(width: M.moreWidth, height: rowHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    /// 云端列，按 Music 的四种状态画：
    /// - 未下载：下载箭头，**常驻**（这一列整列都是下载状态，不看指针在哪儿）；
    /// - 下载中：一圈进度环，常显、点不动；
    /// - 已下载：灰色实心圆 + 挖空的下箭头（`arrow.down.circle.fill`），常显，点它＝删掉本地那份。
    ///   （早先写的「Music 里这一列就是空的」是错的——2026-09-07 实拍纠正。）
    /// - 失败：常显 `exclamationmark.icloud`，悬浮给出错误文案，点了重试。
    @ViewBuilder
    private func cloudCell(_ track: Track) -> some View {
        // 本地导入的曲目这一格是空的：它没有「云端那份」可下，也不该给一颗
        // 点下去就把用户的文件删掉的键（见 ImportService / DownloadStore.adoptLocalFile）。
        if track.isLocal {
            Color.clear
        } else {
            cloudState(track)
        }
    }

    @ViewBuilder
    private func cloudState(_ track: Track) -> some View {
        switch downloads.state(for: track.id) {
        case .none:
            cloudButton("arrow.down", help: "下载", revealed: true) {
                downloads.download([track])
            }
        case .downloading(let progress):
            // 起步那一下留一小段弧：0% 画出来是一个点，看着像卡住了
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(Color.amberKey, style: StrokeStyle(lineWidth: M.cloudRingWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: M.cloudIconSize, height: M.cloudIconSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("正在下载")
                .accessibilityLabel("正在下载")
        case .downloaded:
            Button {
                // 点它＝删掉本地那份，先问一句（`DownloadRemovalAlert`）。
                // SwiftUI 叶子拿不到宿主窗，用当前主键窗贴 sheet。
                DownloadRemovalAlert.confirm(count: 1, in: NSApp.keyWindow) {
                    downloads.removeDownload([track])
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: M.cloudIconSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("已下载")
        case .failed(let message):
            cloudButton("exclamationmark.icloud", help: message, revealed: true) {
                downloads.download([track])
            }
        }
    }

    private func cloudButton(_ symbol: String, help: String, revealed: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: M.cloudIconSize))
                .foregroundStyle(Color.amberKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .opacity(revealed ? 1 : 0)
        .disabled(!revealed)
        .accessibilityHidden(!revealed)
    }

    /// 心水列：已心水常显实心星；未心水只在悬浮/选中时显形空心星，两态同为品牌红。
    private func favoriteCell(_ track: Track) -> some View {
        let isFavorite = library.isFavorite(track)
        let visible = isFavorite || revealsActions
        return Button {
            library.toggleFavorite(track)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: M.favoriteStarSize))
                .foregroundStyle(Color.amberKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消心水" : "心水")
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .accessibilityHidden(!visible)
    }

    /// 评分列：已评分的星常显；未评分的空心星只在悬浮/选中时显形，且是**满色**空心
    /// （专辑页的未评分星是去饱和实心，两处不同形）。
    private func ratingCell(_ track: Track) -> some View {
        HStack(spacing: 0) {
            RatingStars(rating: library.rating(for: track.id),
                        starSize: M.ratingStarSize,
                        spacing: M.ratingStarSpacing,
                        emptyOpacity: revealsActions ? 1 : 0,
                        setRating: { library.setRating($0, for: track.id) })
            Spacer(minLength: 0)
        }
        .padding(.leading, M.ratingInset)
    }

    // MARK: 专辑插图格

    /// 插图列的一片。
    ///
    /// Music 不画一个跨行的大视图，而是每行一个格子、带一个「行类型」，靠切片拼成一块
    /// （`rebuildAlbumArtTypes`，见`SongsAlbumArt`）。这里就照它来：
    /// 整块内容按块高渲染一次，再按块内序号切出本行那一片。
    /// 超出封面跨度的行（行类型 8）什么也不画。
    @ViewBuilder
    private func artworkCell(_ track: Track) -> some View {
        if data.blockIndex < data.rowSpan {
            let blockHeight = CGFloat(data.blockLength) * rowHeight
            artworkBlock(track, height: blockHeight)
                .frame(height: blockHeight, alignment: .topLeading)
                .offset(y: -CGFloat(data.blockIndex) * rowHeight)
                .frame(height: rowHeight, alignment: .top)
                .clipped()
        }
    }

    /// 一整块插图格。2026-08-16 逐像素量的排布：
    /// - **专辑名 / 艺人 / 星级各占一整行行高**，与右边的曲目行逐行对齐；
    /// - 块只有 1 行就只显示专辑名，2 行才加艺人名，3 行起才有星级；
    /// - 文字左沿恒为 `artworkTextLeading`，封面画不画都不动。
    ///
    /// 排版的宽度基准是单元格宽度 `data.cellWidth`（AppKit 在`layout()` 里量了递进来），
    /// 不是「内容想要多宽就多宽」——内容一旦比单元格宽，`sizingOptions = []` 的宿主视图
    /// 会把整块**居中**，封面左边就被切掉了（AGENTS 铁律 2）。所以这里让内容永远等于
    /// 单元格宽度，多出来的从**右边**裁。`cellWidth` 还是 0（第一次布局前）时走老路。
    private func artworkBlock(_ track: Track, height: CGFloat) -> some View {
        let album = library.album(for: track)
        // 块够高才画封面（实测：3 行 66pt 的块画，2 行 44pt 的块不画，封面 56）。
        // 「始终显示」打开时无条件画。
        let showsCover = data.alwaysShowsCover || height >= data.coverSize + M.artworkTopInset
        let lines = data.blockLength
        // 文字那一支的可用宽度＝单元格宽度 − 左沿 − 右内缩。给的是**明确宽度**而不是像以前
        // 那样用左内缩去挤剩下的：`lineLimit(1)` 只有拿到真实可用宽度，截断点才落在框内
        // （Music 窄列时显示的是「帶…」这种带省略号的截断，不是把字画到框外再切掉）。
        //
        // 拖到列宽下限（＝ `artworkMinWidth`，7 + 封面）时这里正好算出 0：整块只剩封面、
        // 右边文字完全没有。**这是对的**——用户对照的 Music 截图里最窄那一档就是
        // 「列刚好包住封面、右边什么都没有」。别再拿一个 minLength 把文字补回来。
        let textWidth: CGFloat? = data.cellWidth > 0
            ? max(0, data.cellWidth - data.textLeading - M.cellInset)
            : nil
        return ZStack(alignment: .topLeading) {
            if showsCover {
                ArtworkView(url: album?.artworkURL ?? track.artworkURL,
                            points: ArtworkSize.gridItem)
                    .frame(width: data.coverSize, height: data.coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.leading, M.artworkInset)
                    .padding(.top, M.artworkTopInset)
                    // 兜底（Amber 自己加的，不是 [实测]）：插图列自动调宽只有 200
                    // （`albumArtworkAutoFitWidth`），而列表尺寸调到「大」时封面能到 270，
                    // 列比封面窄时封面会横向溢出压到右边的列上。这层满宽框 + 裁切只在
                    // 溢出时起作用：框高恰好等于封面本身（含顶内缩），正常档位一个像素都不动。
                    // 第一道防线现在是列的动态下限（`artworkMinWidth(rowHeight:)`，7 + 封面），
                    // 正常情况下这里永不触发；留着是为了换档的中间态，以及存档里存着
                    // 旧的窄宽度那一帧——那时列宽还没被钳上来。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            if textWidth != 0 {
                VStack(alignment: .leading, spacing: 0) {
                    line { Text(track.albumName)
                        .font(.system(size: M.artworkTitleSize, weight: .semibold)) }
                    if lines >= 2 {
                        line { Text(track.artistName).font(.system(size: M.artworkTitleSize)) }
                    }
                    if lines >= 3 { line { stars(album) } }
                    Spacer(minLength: 0)
                }
                // 宽度已知时由 `frame(width:)` 定死；未知（nil）时这层是穿透的，
                // 仍旧靠右内缩收边——与改动前逐像素一致。
                .frame(width: textWidth, alignment: .leading)
                .padding(.leading, data.textLeading)
                .padding(.trailing, textWidth == nil ? M.cellInset : 0)
            }
        }
        // 内容按单元格宽度排（超出的下面 `clipped()` 从右边裁），而不是让宿主视图居中。
        .frame(width: data.cellWidth > 0 ? data.cellWidth : nil, alignment: .topLeading)
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 插图格里的一行：占满一个行高，内容垂直居中——这样才和右边的曲目行同高同基线。
    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .lineLimit(1)
            .frame(height: rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 专辑星级 + 末尾那颗**专辑**喜爱星（与前面五颗评分星不是一回事）。
    ///
    /// 设置 › 通用 ›「星级评分」关掉时，前面那五颗跟着评分列一起消失，末尾那颗喜爱星留着
    /// ——那条开关管的是**评分**，心水是另一回事。[推]：Music 只实测到它会收走评分列，
    /// 插图块里的星没有实拍证据，但这颗勾选框在「显示：」组里、名字就叫星级评分，
    /// 藏了列却留着五颗可点的评分星是自相矛盾的。
    @ViewBuilder
    private func stars(_ album: Album?) -> some View {
        HStack(spacing: M.ratingStarSpacing) {
            if settings.values.showStarRatings {
                RatingStars(rating: album.map { library.rating(for: $0.id) } ?? 0,
                            starSize: M.artworkStarSize,
                            spacing: M.ratingStarSpacing,
                            setRating: { value in
                                guard let album else { return }
                                library.setRating(value, for: album.id)
                            })
            }
            if let album {
                Button {
                    library.toggleFavoriteAlbum(album)
                } label: {
                    Image(systemName: library.isFavoriteAlbum(album)
                          ? "star.fill" : "star")
                        .font(.system(size: M.artworkStarSize))
                        .foregroundStyle(Color.amberKey)
                }
                .buttonStyle(.plain)
                .padding(.leading, M.artworkCoverGap)
                .help(library.isFavoriteAlbum(album) ? "取消心水专辑" : "心水专辑")
            }
        }
    }
}
