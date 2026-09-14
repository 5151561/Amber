import AppKit

// MARK: - 曲目表的契约（阶段 4 两批并行的接口）

/// 详情页（歌单 / 专辑 / 艺人 / 本地列表）换成 `NSTableView` 后，**行**（批 A：
/// `NSTableRowView` + 三种形态的格子、右键`NSMenu`）与**表**（批 B：表格控制器、
/// 第 0 行头部、页面）分两批并行做，两边只通过这个文件说话：
/// - 批 B 只用 `TrackRowRegistry` 造行、拿行高、拿菜单与歌单列头；
/// - 批 A 只改 `TrackRowRegistry` 里的工厂实现，把`TrackRowPlaceholderView` 换成真的。
///
/// 行的三种形态与像素出处见 `MusicMetrics.TrackRow`（Music 1.7 实测 + ASM）。

/// 曲目行的形态。原先在 `TrackList.swift`（SwiftUI），随表格换 AppKit 挪到这里。
enum TrackListStyle: Hashable {
    /// 目录专辑与艺人详情：喜爱 / 序号 / 标题 / 加号 / 时长 / 更多（无星级列）
    case detail
    /// 已加入资料库的专辑：喜爱 / 序号 / 标题 / 星级 / 下载 / 时长 / 更多
    case libraryAlbum
    /// Apple Music 歌单：喜爱 / 封面 / 序号与歌曲 / 艺人 / 专辑 / 时长 / 更多
    case playlist
    /// 搜索结果：封面、艺人、专辑和来源
    case search
    /// 本地资料库：Music.app 表格式丰富行
    case library

    /// 专辑形态的两种紧凑行（含序号列、无封面）
    var isAlbumTable: Bool { self == .detail || self == .libraryAlbum }
    /// 带封面的丰富行
    var isRich: Bool { !isAlbumTable }
    /// 只有资料库形态才排星级列；目录形态把这 72pt 让给标题列。
    var showsRating: Bool { self == .libraryAlbum }
}

/// 一行要知道的全部东西。表格每次 `viewFor` 都重新交一份。
struct TrackRowConfiguration {
    var track: Track
    /// 1 起的序号（专辑形态画在序号列；榜单形态画在封面右边）
    var index: Int
    var style: TrackListStyle
    var isChart = false
    /// 整份可见行 + 本行下标：••• 里的「播放」= 从这一行起播、后面接着放（与双击同义）
    var playContext: TrackPlayContext
    /// 行菜单里的「移除」项（资料库播放列表用「从播放列表中删除」），nil 不摆
    var removeTitle: String? = nil
    var remove: (() -> Void)? = nil
    /// 末行不画分隔线
    var showsDivider = true
}

/// 曲目行。选中态由 `NSTableView` 管（`isSelected`），悬浮态由行自己的 tracking area 管，
/// 都由行视图推给格子；表格不参与。
@MainActor
protocol TrackRowViewConfigurable: NSTableRowView {
    /// 每次复用都会重新调；实现要把上一次的图/文/悬浮态全部清掉再装。
    func configure(_ configuration: TrackRowConfiguration, appState: AppState)
}

@MainActor
enum TrackRowRegistry {

    private typealias M = MusicMetrics.TrackRow

    static let rowIdentifier = NSUserInterfaceItemIdentifier("TrackRowView")

    /// 行高 [AX]/[实测]：专辑紧凑 45、丰富行 54、歌单 56。分隔线画在行内最底一线
    /// （SwiftUI 版把 `Divider` 摆在行外、整行实占 46/55/57；表格里行 pitch 必须等于行高）。
    static func rowHeight(for style: TrackListStyle) -> CGFloat {
        switch style {
        case .playlist: return M.playlistRowHeight
        case .detail, .libraryAlbum: return M.compactHeight
        case .search, .library: return M.richHeight
        }
    }

    /// 歌单形态那条 32pt 的列头「歌曲 / 艺人 / 专辑 / 时长」（`PlaylistTrackHeader`），
    /// 表格把它当浮动的 group row 用。
    static var playlistHeaderHeight: CGFloat { M.playlistHeaderHeight }

    /// 造一行（`makeView(withIdentifier:owner:)` 复用不到时才新建）。
    ///
    /// 行按「行 = 内容列整宽」排，页面左右留白由行自己让（与批 B 的头部同一条）：
    /// 默认值按形态给（歌单 0、专辑详情 40、搜索与本地列表 34，逐页核过旧版调用点，
    /// 见 `TrackRowView.contentInset`），表格实现`TrackRowContentInsetProviding`
    /// 就按表格说的来（艺人页的 `.detail` 是 34；表格若已经自己内缩过就给 0）。
    static func makeRow(in tableView: NSTableView) -> TrackRowViewConfigurable {
        let row = (tableView.makeView(withIdentifier: rowIdentifier, owner: nil) as? TrackRowView)
            ?? {
                let created = TrackRowView()
                created.identifier = rowIdentifier
                return created
            }()
        if let provider = tableView as? TrackRowContentInsetProviding {
            row.contentInset = provider.trackRowContentInset
        }
        return row
    }

    /// 歌单列头视图，宽度随表；列宽算法与歌单行一致。
    static func makePlaylistHeader(isChart: Bool) -> NSView {
        // 列头与榜单无关：`isChart` 只影响行里名次那条窄列，四个列头文字与列位都不变
        // （SwiftUI 版 `PlaylistTrackHeader` 同样没用到这个参数）。
        TrackPlaylistHeaderView()
    }

    /// 曲目的右键 / ••• 菜单。多选时 `tracks` 是整份选中集。
    /// 项序走 `TrackActions.libraryRow()`（资料库表格那一份）。
    static func menu(for tracks: [Track], playContext: TrackPlayContext?,
                     removeTitle: String? = nil, remove: (() -> Void)? = nil,
                     appState: AppState) -> NSMenu {
        let actions = TrackActions(
            tracks: tracks, appState: appState, playContext: playContext,
            remove: removeTitle.flatMap { title in remove.map { (title: title, run: $0) } })
        return MenuSpec.makeMenu(actions.libraryRow())
    }
}

/// 批 A 落地前的占位行：一行标题 + 时长，行高由表给。
final class TrackRowPlaceholderView: NSTableRowView, TrackRowViewConfigurable {

    private let titleField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 13)
        durationField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationField.textColor = .secondaryLabelColor
        durationField.alignment = .right
        for field in [titleField, durationField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            durationField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: durationField.leadingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ configuration: TrackRowConfiguration, appState: AppState) {
        titleField.stringValue = "\(configuration.index). \(configuration.track.title)"
        durationField.stringValue = configuration.track.duration.mmss
    }
}
