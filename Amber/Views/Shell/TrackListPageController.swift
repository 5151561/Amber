import AppKit
import SwiftUI

// MARK: - 一张大标题 + 一列曲目的页面（AppKit）—— 计划阶段 4 批 B
//
// 替代 `MainView.swift` 的 `LocalTrackListView`（本地列表）与
// `CatalogGridPages.swift` 的 `CatalogTrackListPage`（目录二级页）。
// 两者的骨架相同，只有页头与行形态不同：
// - `.pageTitle`：29pt 大标题（纯 AppKit 标签）+ 丰富行（`.library`）；
// - `.room`：`CatalogRoomHeaderView`（标题 + 播放 / 随机键 + 副标题）+ 歌单行（`.playlist`）。
//   阶段 5 批 B 起它是纯 AppKit，与网格类房间页 `CatalogRoomViewController` 共用同一份页头。

@MainActor
final class TrackListPageController: TrackTableViewController {

    enum HeaderKind {
        /// 页面大标题（`MusicMetrics.Page.titleSize` 29pt bold）
        case pageTitle
        /// 目录二级页的 `CatalogRoomHeaderView`（带播放 / 随机键与副标题）
        case room
    }

    private let pageTitle: String
    private let kind: HeaderKind
    private let style: TrackListStyle
    private let emptyText: String
    private let emptyGlyph: String
    private var header: (any TrackTableHeaderView)?

    init(appState: AppState, title: String, tracks: [Track],
         style: TrackListStyle = .library, kind: HeaderKind = .pageTitle,
         emptyMessage: String = "这份列表现在是空的。",
         emptyImage: String = "music.note.list") {
        pageTitle = title
        self.kind = kind
        self.style = style
        emptyText = emptyMessage
        emptyGlyph = emptyImage
        super.init(nativePage: appState)
        pendingTracks = tracks
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `viewDidLoad` 之前先收着，视图搭好再上屏。
    private var pendingTracks: [Track] = []

    // MARK: 形态

    override var trackStyle: TrackListStyle { style }
    /// 目录二级页的行是歌单行（第一格就是 40pt 心水槽，页面留白已经在里面）；
    /// 本地列表是丰富行，左沿与页面大标题对齐（34）。
    override var trackRowContentInset: CGFloat {
        kind == .room ? 0 : MusicMetrics.Page.leadingMargin
    }
    override var showsColumnHeader: Bool { style == .playlist }
    /// 旧版：目录二级页头部 `.padding(.bottom, 16)`；本地列表是 `VStack(spacing: 18)`。
    override var headerBottomSpacing: CGFloat { kind == .room ? 16 : 18 }
    override var footerTopSpacing: CGFloat { MusicMetrics.Detail.footerTop }
    override var emptyMessage: String { emptyText }
    override var emptyImage: String { emptyGlyph }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        show(tracks: pendingTracks)
    }

    private func show(tracks: [Track]) {
        pendingTracks = tracks
        guard isViewLoaded else { return }
        if header == nil { header = makeHeader(tracks: tracks) }
        (header as? CatalogRoomHeaderView)?.update(subtitle: roomSubtitle(tracks),
                                                   hasActions: !tracks.isEmpty)
        invalidateFooter()
        apply(header: header, tracks: tracks)
    }

    private func makeHeader(tracks: [Track]) -> any TrackTableHeaderView {
        switch kind {
        case .pageTitle:
            return PageTitleHeaderView(title: pageTitle, leading: MusicMetrics.Page.leadingMargin)
        case .room:
            // 与网格类房间页同一份页头（`CatalogRoomHeaderView`）。这里它铺满整表宽，
            // 所以左右留白由它自己让（网格页那边是段的 `contentInsets` 让的）。
            let header = CatalogRoomHeaderView(frame: .zero)
            header.horizontalInset = MusicMetrics.Page.leadingMargin
            header.configure(title: pageTitle, subtitle: roomSubtitle(tracks),
                             onPlay: { [weak self] in self?.play(shuffled: false) },
                             onShuffle: { [weak self] in self?.play(shuffled: true) })
            header.update(subtitle: roomSubtitle(tracks), hasActions: !tracks.isEmpty)
            return header
        }
    }

    private func roomSubtitle(_ tracks: [Track]) -> String? {
        tracks.isEmpty ? nil : "\(tracks.count) 首歌曲"
    }

    private func play(shuffled: Bool) {
        let list = shuffled ? tracks.shuffled() : tracks
        guard !list.isEmpty else { return }
        appState.player.play(list, source: queueSource)
    }

    /// 队列面板的「来自《…》」＝这一页的大标题。
    /// **没有 route**：这一页是被 `.localTracks` / `.trackGrid` 两种落点共用的壳，
    /// 构造时只收到标题与曲目，回不去原来那条 `Route`（缺口，要补得从
    /// `PageHosting` 把 route 传进来——那个文件这一批不归本代理动）。
    override var queueSource: PlayerController.QueueSource? { .init(title: pageTitle) }

    // MARK: 页脚

    override func makeFooterView() -> NSView? {
        // 大标题那一档旧版没有页脚；目录二级页有一行「N 首歌曲」。
        guard kind == .room, !pendingTracks.isEmpty else { return nil }
        return DetailFooterView(lines: ["\(pendingTracks.count) 首歌曲"],
                                leading: MusicMetrics.Detail.playlistContentHorizontal)
    }
}

// MARK: - 页头

/// 29pt bold 的页面大标题（旧版 `LocalTrackListView` 那一行）。
private final class PageTitleHeaderView: NSView, TrackTableHeaderView {

    private let label: NSTextField
    private let leading: CGFloat

    override var isFlipped: Bool { true }

    init(title: String, leading: CGFloat) {
        label = CatalogCardKit.label(size: MusicMetrics.Page.titleSize, weight: .bold,
                                     color: .labelColor, lines: 1)
        self.leading = leading
        super.init(frame: .zero)
        label.stringValue = title
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// [旧版] `.padding(.top, MusicMetrics.Page.titleTop)` + 裸标签的自然高。
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        MusicMetrics.Page.titleTop + ceil(label.fittingSize.height)
    }

    override func layout() {
        super.layout()
        let height = ceil(label.fittingSize.height)
        label.frame = NSRect(x: leading - CatalogCardKit.labelInset,
                             y: MusicMetrics.Page.titleTop,
                             width: max(1, bounds.width - leading * 2 + CatalogCardKit.labelInset * 2),
                             height: height)
    }
}
