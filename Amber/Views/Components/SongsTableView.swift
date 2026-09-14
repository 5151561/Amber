import AppKit
import SwiftUI

// 资料库「歌曲」页的表格骨架：**一张真的 NSTableView**。
//
// Music 那一页（`AMPTrackDisplayController` + `TrackDisplayTableView`）就是 NSTableView，
// Amber 早先是在 SwiftUI 里手搓的（LazyVStack 排行、列头自己画、拖列/拖列宽自己接 NSEvent）。
// 三件事因此一直做不对，换成原生表格后全部由 AppKit 负责：
// 1. 整列拖动的高亮（`NSTableHeaderView` 的 slide-reorder 路径，被拖的列是个真视图）；
// 2. 插图列是**每行一个格子 + 一个行类型**拼成的一块，不是一个跨行的大视图
//    （见 `SongsAlbumArt`，对应`rebuildAlbumArtTypes`）；
// 3. 有些列不该能拖宽——那是 `NSTableColumn.resizingMask` 的原生能力。
//
// 换的是骨架，**像素一个不改**：条纹/选中底色、列头配色、字号行高、插图格排布
// 仍然照实测值自己画（`MusicMetrics.SongsTable` / `MusicColors`）。
//
// 页面本身（滚动容器、空态、刷新驱动、工具栏）在
// `Amber/Views/Shell/LibrarySongsViewController.swift`。

// MARK: - 控制器

/// 数据源 + 代理 + 列同步。对应 Music 的 `AMPTrackDisplayController`。
@MainActor
final class SongsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private typealias M = MusicMetrics.SongsTable
    typealias Key = SongsTableColumns.Key

    let settings: SongsTableSettings
    let listSize: ListViewSizeStore
    let appState: AppState

    weak var tableView: TrackDisplayTableView?
    /// 页面交下来的曲目（筛选 → 搜索 → 排序之后）。播放队列按它建。
    private(set) var rows: [Track] = []
    /// 表格实际的行：`nil` 是「始终显示插图」给短块补的空行，它不是曲目。
    private(set) var items: [Track?] = []
    /// 插图列的行类型与由它切出来的块（开「显示插图」时才有内容）
    private(set) var artwork = SongsAlbumArt.Layout.empty

    /// 我们自己往 NSTableView 上写东西时置位，免得代理回调再把它回灌进模型。
    private var isSyncing = false
    /// 列头正被按住（换位或拖宽）：这期间不拿模型里的宽度去盖 AppKit 正在改的值。
    private var isTrackingHeader = false
    /// 列头按住的这一段里 AppKit 有没有真的改过列（收到过 columnDidResize / columnDidMove）。
    /// 只是点一下列头排序时它一直是 false，松手就不落盘（见 `endHeaderTracking`）。
    private var headerChangedColumns = false
    /// 上一次同步到表上的列状态，用来判断要不要重建列。
    private var appliedColumns: SongsTableColumns?
    private var appliedRowHeight: CGFloat = 0
    /// 「始终显示」不在列状态里（它只影响补白行），得单独记一份，否则勾了没反应。
    private var appliedAlwaysShowsArtwork = false

    init(settings: SongsTableSettings, listSize: ListViewSizeStore, appState: AppState) {
        self.settings = settings
        self.listSize = listSize
        self.appState = appState
        super.init()
    }

    // MARK: 同步

    func update(rows newRows: [Track]) {
        guard let table = tableView else { return }
        // 选中集按 id 记，重排/筛选之后还能找回来（`performPreservingSelection:`）
        let selected = selectedTrackIDs()

        let columnsChanged = settings.columns != appliedColumns
            || settings.alwaysShowArtwork != appliedAlwaysShowsArtwork
        let rowHeight = settings.columns.rowHeight(base: listSize.rowHeight)
        let heightChanged = abs(rowHeight - appliedRowHeight) > 0.01
        let rowsChanged = newRows != rows
        appliedAlwaysShowsArtwork = settings.alwaysShowArtwork
        rows = newRows

        if columnsChanged { syncColumns() }
        if heightChanged {
            appliedRowHeight = rowHeight
            table.rowHeight = rowHeight
            // 插图档位在 `columns` 里、走上面的`columnsChanged`；行高（列表尺寸）不在，
            // 而封面边长是从行高推的，所以这一支也得把插图列的下限重算一遍。
            if !columnsChanged { updateArtworkColumnMinimum() }
        }
        syncSortDescriptors()
        syncAlbumModeTitles()

        guard rowsChanged || columnsChanged || heightChanged else {
            // 行没变，但资料库里的播放次数/添加日期这类值可能变了。
            // 富单元格是 SwiftUI，自己会跟着 appState 重画；纯文本格得手动刷。
            refreshTextCells()
            return
        }
        rebuildLayout()
        table.reloadData()
        restore(selection: selected, scroll: rowsChanged)
    }

    /// 某一行上的曲目；补白行没有曲目。
    func track(at row: Int) -> Track? {
        items.indices.contains(row) ? items[row] : nil
    }

    private func selectedTrackIDs() -> Set<String> {
        guard let table = tableView else { return [] }
        return Set(table.selectedRowIndexes.compactMap { track(at: $0)?.id })
    }

    /// 重排 / 换筛选 / 改搜索词之后把选中找回来，并**滚回第一个选中行**
    /// （`performPreservingSelection:`，`[实测]`）。
    private func restore(selection ids: Set<String>, scroll: Bool) {
        guard let table = tableView, !ids.isEmpty else { return }
        var found = IndexSet()
        for index in items.indices {
            if let track = items[index], ids.contains(track.id) { found.insert(index) }
        }
        isSyncing = true
        table.selectRowIndexes(found, byExtendingSelection: false)
        isSyncing = false
        if scroll, let first = found.first { table.scrollRowToVisible(first) }
    }

    /// 按 `SongsTableColumns` 的顺序/显隐/宽度增删并重排 NSTableColumn。
    private func syncColumns() {
        guard let table = tableView else { return }
        isSyncing = true
        defer {
            isSyncing = false
            appliedColumns = settings.columns
        }
        let wanted = settings.columns.visible
        let keep = Set(wanted.map(\.key.rawValue))
        for column in table.tableColumns where !keep.contains(column.identifier.rawValue) {
            table.removeTableColumn(column)
        }
        for (index, spec) in wanted.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier(spec.key.rawValue)
            let column: NSTableColumn
            if let existing = table.tableColumns.first(where: { $0.identifier == identifier }) {
                column = existing
            } else {
                column = NSTableColumn(identifier: identifier)
                column.headerCell = SongsHeaderCell(textCell: "")
                table.addTableColumn(column)
            }
            configure(column, spec)
            if let current = table.tableColumns.firstIndex(of: column), current != index {
                table.moveColumn(current, toColumn: index)
            }
        }
        table.headerView?.needsDisplay = true
    }

    private func configure(_ column: NSTableColumn, _ spec: SongsTableColumns.Column) {
        let width = settings.columns[spec.key]
        let minimum = minimumWidth(spec)
        // [实测 probe] 2026-09-07：`setMinWidth:` 会顺带把已有的`width` 钳上来
        // （裸列与挂在 NSTableView 上的列都是；反过来给比 minWidth 还小的 width 也会被钳住），
        // 所以下面那行按存档宽度回写也不会把列压回下限以下，不用再补一次显式抬高。
        column.minWidth = minimum
        // `resizingMask` 为空的列既拖不动，也不参与自动调宽——这是 NSTableColumn 自带的，
        // Music 的 `makeTableColumnForField:withInfo:` 就是按列信息给或不给。
        column.resizingMask = spec.resizable ? .userResizingMask : []
        column.maxWidth = spec.resizable ? .greatestFiniteMagnitude : max(width, minimum)
        if !isTrackingHeader, abs(column.width - width) > 0.01 { column.width = width }
        column.title = spec.title ?? ""
        column.sortDescriptorPrototype = spec.sortable
            ? NSSortDescriptor(key: spec.key.rawValue, ascending: true) : nil
        guard let cell = column.headerCell as? SongsHeaderCell else { return }
        cell.key = spec.key
        cell.icon = spec.icon
        cell.trailing = spec.trailing
        // Music 的 10 个 AXSortButton 连没有可见文字的列也带标题，照抄这套命名
        cell.setAccessibilityLabel(SongsTableColumns.accessibilityTitle(for: spec.key))
    }

    /// 列的**有效**最小宽度。除插图列外就是列自己登记的 `minWidth`
    /// （ColumnWidths.plist 的 `minimum-column-width`，插图列那条是 40）。
    ///
    /// 插图列另有一条跟着封面走的动态下限（见 `artworkMinWidth(rowHeight:)`）：
    /// 静态的 40 只保证不压到别的列，保不住封面本身。
    private func minimumWidth(_ spec: SongsTableColumns.Column) -> CGFloat {
        guard spec.key == .artwork else { return spec.minWidth }
        // 行高的取法与 `syncColumns` / `rebuildLayout` 同一套：开曲目封面列时顶到 54，
        // 否则是列表尺寸那三档。
        let rowHeight = settings.columns.rowHeight(base: listSize.rowHeight)
        return max(spec.minWidth, settings.columns.artworkMinWidth(rowHeight: rowHeight))
    }

    /// 行高变了就重算插图列的下限：封面边长是从行高推的（`artworkCoverSize(rowHeight:)`），
    /// 行高一变封面就变，下限必须跟着变，否则「列表尺寸」调到「大」时封面（270）
    /// 会比上一档留下的列宽还宽，又被裁回去。
    ///
    /// 只动这一列的 minWidth，不整份重建列：`update(rows:)` 的`heightChanged` 那一支
    /// 本来就不走 `syncColumns()`（列的顺序／显隐没变，重建只会白白丢掉 AppKit 侧的状态）。
    private func updateArtworkColumnMinimum() {
        guard let table = tableView,
              let column = table.tableColumns.first(where: { $0.identifier.rawValue == Key.artwork.rawValue })
        else { return }
        // 抬高 minWidth 时 AppKit 自己会把偏窄的 width 一起钳上来（[实测 probe] 2026-09-07）；
        // 往下调时不必动 width——用户拖出来的宽度该留着。
        column.minWidth = minimumWidth(SongsTableColumns.column(.artwork))
    }

    /// 排序状态是双向的：菜单/显示选项改了要推给表头，点表头改了要写回菜单。
    private func syncSortDescriptors() {
        guard let table = tableView else { return }
        let current = table.sortDescriptors.first
        if current?.key != settings.sort.column.rawValue || current?.ascending != settings.sort.ascending {
            isSyncing = true
            table.sortDescriptors = [NSSortDescriptor(key: settings.sort.column.rawValue,
                                                      ascending: settings.sort.ascending)]
            isSyncing = false
        }
        var changed = false
        for column in table.tableColumns {
            guard let cell = column.headerCell as? SongsHeaderCell else { continue }
            let ascending = cell.key == settings.sort.column ? settings.sort.ascending : nil
            if cell.sortAscending != ascending {
                cell.sortAscending = ascending
                changed = true
            }
        }
        if changed { table.headerView?.needsDisplay = true }
    }

    /// 「专辑」列头与插图列头的文字＝**当前的专辑排序模式名**（Music 的插图列头写的
    /// 就是「按艺人排列专辑」这一档的名字，见 `SongsTableSort.AlbumSortMode`）。
    /// 模式是排序状态的一部分，不进 `columns`，所以不能只在重建列时写一次。
    private func syncAlbumModeTitles() {
        guard let table = tableView else { return }
        let title = settings.sort.albumMode.title
        var changed = false
        for column in table.tableColumns {
            guard let key = Key(rawValue: column.identifier.rawValue),
                  key == .album || key == .artwork, column.title != title else { continue }
            column.title = title
            (column.headerCell as? SongsHeaderCell)?.setAccessibilityLabel(title)
            changed = true
        }
        if changed { table.headerView?.needsDisplay = true }
    }

    /// 排出表格实际要画的行，并把插图列切成块。
    private func rebuildLayout() {
        guard settings.showArtwork else {
            items = rows
            artwork = .empty
            return
        }
        // 跨行数是「插图大小」那三档的本体，与行高无关：3 / 5 / 7
        // （`[实测]` `currArtworkRowSpan`）。封面边长反过来由它 × 行高推出来。
        let rowSpan = settings.columns.artworkRowSpan
        // 「始终显示」＝短块补空行占满整块（见 SongsAlbumArt.padded）；
        // 不开就照曲目行排，块不够高时插图格自己不画封面。
        items = settings.alwaysShowArtwork ? SongsAlbumArt.padded(rows, rowSpan: rowSpan) : rows
        artwork = SongsAlbumArt.layout(for: items, rowSpan: rowSpan)
    }

    private func refreshTextCells() {
        guard let table = tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<visible.upperBound where items.indices.contains(row) {
            guard let track = track(at: row) else { continue }
            for index in table.tableColumns.indices {
                guard let key = Key(rawValue: table.tableColumns[index].identifier.rawValue),
                      let cell = table.view(atColumn: index, row: row, makeIfNecessary: false)
                else { continue }
                if let text = cell as? SongsTextCellView {
                    text.text = SongsTableColumns.text(for: key, track: track,
                                                       library: appState.library,
                                                       downloads: appState.downloads)
                    continue
                }
                // 勾选列同理：它是 AppKit 的格子，不像富单元格那样自己跟着重画。
                // 菜单「勾选所选项」一次改一批，改完由 `LibraryStore.objectWillChange`
                // 走到这里，把可见行的勾重新落一遍。
                if let checkbox = cell as? SongsCheckboxCellView {
                    let library = appState.library
                    checkbox.configure(checked: library.isChecked(track)) { [weak library] checked in
                        library?.setChecked(track, checked)
                    }
                }
            }
        }
    }

    // MARK: 列头交互

    /// 列头一按下就进 AppKit 的嵌套事件循环（换位或拖宽），松手才返回。
    func beginHeaderTracking() {
        isTrackingHeader = true
        headerChangedColumns = false
    }

    /// 表格收到 `columnDidResize` / `columnDidMove` 时转告一声：这一按真的动了列。
    func noteColumnLayoutChanged() { headerChangedColumns = true }

    /// 松手落盘。Music 的 `tableView:didDragTableColumn:` 与`tableDidEndLiveResize`
    /// 都是 `saveColumnInfo` 的转发壳（各 1 条指令的尾调用）。
    ///
    /// 但**只在这一按真的改过列时才落盘**：`mouseDown` 分不清「拖宽/换位」和「点一下排序」，
    /// 排序点击照样会走到这里，把 AppKit 当前的所有列宽整份写回存档。
    /// 曾在存档里见过插图列 44.5、艺人列 84.5 这种半点值（模型这一侧全是整数：出厂宽、
    /// minWidth、自动调宽的 `ceil(…) + 4.5×2` 都落在整点上），只有 AppKit 现拖出来的宽度
    /// 才带 .5 —— 也就是说表上的宽度可能早已不是用户这一下想改的东西，
    /// 一次无关的排序点击就把它固化进存档了。有改动才写，就不会替用户做这个决定。
    func endHeaderTracking() {
        isTrackingHeader = false
        guard headerChangedColumns else { return }
        saveColumnInfo()
    }

    func saveColumnInfo() {
        guard let table = tableView else { return }
        var columns = settings.columns
        let keys = table.tableColumns.compactMap { Key(rawValue: $0.identifier.rawValue) }
        columns.applyVisibleOrder(keys)
        for column in table.tableColumns {
            guard let key = Key(rawValue: column.identifier.rawValue) else { continue }
            // 开插图列时「状态」列由 26 撑到 56，那是取值时顶上去的，别把它写回存档
            if key == .nowPlaying, settings.columns.showsArtwork { continue }
            columns.setWidth(column.width, for: key)
        }
        guard columns != settings.columns else { return }
        settings.columns = columns
        // 这一份是我们自己写上去的，不必再同步回表
        appliedColumns = columns
        settings.save()
    }

    /// 列头右键菜单：调宽 + 增删列（对照 Music 的同一份菜单）。
    func headerMenu(forColumn index: Int) -> NSMenu? {
        guard let table = tableView else { return nil }
        let key = table.tableColumns.indices.contains(index)
            ? Key(rawValue: table.tableColumns[index].identifier.rawValue) : nil
        let menu = NSMenu()
        // 文案照 loadView 里建菜单那两条（`[实测]`）：
        // 是「自动调整列宽」「自动调整所有列宽」，不是「列大小」。
        if let key {
            let item = NSMenuItem(title: "自动调整列宽", action: #selector(autoFitColumn(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            menu.addItem(item)
        }
        // `autosizeAllColumns:` 是`for i in 0..<numberOfColumns { autosizeColumnAtIndex(i) }`
        // （`[实测]`）——**所有列**，不挑有没有列头文字。
        let all = NSMenuItem(title: "自动调整所有列宽", action: #selector(autoFitAllColumns),
                             keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.addItem(.separator())
        // 「显示 › 星级评分」关掉时，评分那两项连菜单项都不出现（同「显示选项」窗口）
        for key in SongsTableColumns.toggleMenuOrder.filter(settings.columns.isListed) {
            let item = NSMenuItem(title: SongsTableColumns.title(for: key),
                                  action: #selector(toggleColumnVisible(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = settings.columns.isVisible(key) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func autoFitColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Key else { return }
        autoFit([key])
    }

    @objc private func autoFitAllColumns() {
        autoFit(settings.columns.visible.map(\.key))
    }

    @objc private func toggleColumnVisible(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Key else { return }
        settings.toggleVisible(key)
    }

    /// 「自动调整列宽」。`resizingMask` 为空的列直接跳过——
    /// `autosizeColumnAtIndex:ignoreResizingMask:`（`[实测]`）进门第一件事就是这个判断。
    func autoFit(_ keys: [Key]) {
        guard let table = tableView else { return }
        for key in keys {
            guard SongsTableColumns.column(key).resizable,
                  let column = table.tableColumns.first(where: { $0.identifier.rawValue == key.rawValue })
            else { continue }
            column.width = autoFitWidth(for: key, in: rows)
        }
        saveColumnInfo()
    }

    // MARK: 自动调宽的量法

    /// 「自动调整列大小」（Music 的 `calcAutosizeColumnAtIndex:`，`[实测]`）。
    ///
    /// 它量的是**单元格**，不是列头：拿该列的模板单元装上待测曲目、`fittingSize` 取宽，
    /// 所以列头文字再长也不参与——「播放次数」收紧后会窄过它自己的标题，
    /// 兜住它的是列的最小宽度（ColumnWidths.plist 的 minWidth），不是标题宽。
    ///
    /// 什么时候调宽由上面那几处定（分隔线双击、空白区双击、列头右键菜单），
    /// `resizingMask` 为空的列在那边就被挡掉了，这里只管量。
    private func autoFitWidth(for key: Key, in rows: [Track]) -> CGFloat {
        // 专辑封面跨行列固定 200 —— 这是它自己的定值，不是别的列的上限
        if key == .artwork { return M.albumArtworkAutoFitWidth }

        let font = NSFont.systemFont(ofSize: listSize.fontSize)
        // 时长列与音轨编号列不扫全表：Music 先挑出「最长的那首 / 号码最大的那首」
        // （findPlaylistItemWithLongestDuration / findPlaylistItemWithLargestTrackNumber），
        // 只把它装进模板单元测一次。
        let sampled: [Track]
        switch key {
        case .duration: sampled = [rows.max { $0.duration < $1.duration }].compactMap { $0 }
        case .trackNumber:
            sampled = [rows.max { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }].compactMap { $0 }
        default: sampled = rows
        }

        var width: CGFloat = 0
        for track in sampled {
            width = max(width, measure(
                SongsTableColumns.text(for: key, track: track, library: appState.library,
                                       downloads: appState.downloads), font))
        }
        // 量到东西就是「文字实宽 + 单元格左右内缩」，下限 16；一点都量不出来才回退 10。
        guard width > 0 else { return M.autoFitFallbackWidth }
        return max(ceil(width) + M.cellInset * 2, M.autoFitMinWidth)
    }

    private func measure(_ text: String, _ font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: 行操作

    /// 表里的每一种「播放」都是**从列表播放**：从这一行起播，后面按当前排序与筛选接着放
    /// （Music 的双击 / 回车 / ••• / 右键「播放」是同一件事）。
    /// 队列按曲目排（补白行不在里头），起播下标要换算回曲目序。
    func playContext(at row: Int) -> TrackPlayContext? {
        guard let track = track(at: row),
              let index = rows.firstIndex(where: { $0.id == track.id }) else { return nil }
        return TrackPlayContext(tracks: rows, index: index)
    }

    func play(at row: Int) {
        guard let context = playContext(at: row) else { return }
        // 记账（最近播放/播放次数）由播放器回调完成，视图层不再自己记一笔
        appState.player.play(context.tracks, startAt: context.index)
    }

    /// 回车播放：**取第一个选中行，从它开始播整份列表**。
    /// 多选也一样——Music 里选中集只决定从哪一首起播，不会把队列缩成这几首。
    @discardableResult
    func playSelection() -> Bool {
        guard let table = tableView,
              let row = table.selectedRowIndexes.first(where: { track(at: $0) != nil })
        else { return false }
        play(at: row)
        return true
    }

    /// ⌫ / ⌘⌫ 把选中的曲目移出资料库（Music 的 `doDeleteTracksFromLibrary:`）。
    ///
    /// 两张对话框（确认 + 「文件去哪」）整段在 `LibraryDeleteAlert` 里，理由见那边的
    /// 类型注释（spec §10.2）。都是窗口页签（sheet），所以真正的删除落在回调里；
    /// 返回 true 只表示这一下按键已经被接住了，不该再往 super 传
    /// （否则 ⌫ 会被当成别的操作）。
    @discardableResult
    func deleteSelection() -> Bool {
        guard let table = tableView else { return false }
        let picked = table.selectedRowIndexes.compactMap { track(at: $0) }
        guard !picked.isEmpty else { return false }
        LibraryDeleteAlert.confirm(tracks: picked, in: table.window,
                                   appState: appState) { [weak self, weak table] in
            guard let self else { return }
            for track in picked { self.appState.library.removeFromLibrary(track) }
            table?.deselectAll(nil)
        }
        return true
    }

    /// 菜单的作用集：点在选中行上就是整份选中集，点在选区外就只作用于这一行
    /// （Music 的 `specListForSelectedItemsOrRow:`）。
    func menuTracks(forRow row: Int) -> [Track] {
        guard let table = tableView, let track = track(at: row) else { return [] }
        guard table.selectedRowIndexes.contains(row), table.selectedRowIndexes.count > 1 else {
            return [track]
        }
        return table.selectedRowIndexes.compactMap { self.track(at: $0) }
    }

    /// 当前选中的曲目（按行序）。插图块的补白行没有曲目，自动滤掉。
    /// 「文件 ▸ 显示简介」（⌘I）走这条——它没有「被点的那一行」，只有选中集。
    func selectedTracks() -> [Track] {
        guard let table = tableView else { return [] }
        return table.selectedRowIndexes.compactMap { self.track(at: $0) }
    }

    func menuTracks(forCell cell: NSView) -> [Track] {
        guard let table = tableView else { return [] }
        return menuTracks(forRow: table.row(for: cell))
    }

    /// ••• / 右键菜单里的「播放」也是**从列表播放**：队列是整份可见行，
    /// 起播的是被点的那一行（多选时同样以被点那一行为准，不是选中集的第一首）。
    func playContext(forCell cell: NSView) -> TrackPlayContext? {
        guard let table = tableView else { return nil }
        return playContext(at: table.row(for: cell))
    }

    func rowMenu(for row: Int) -> NSMenu? {
        let picked = menuTracks(forRow: row)
        guard !picked.isEmpty else { return nil }
        // 从前这里是 `NSHostingMenu`（还得手工注三个环境对象）。菜单本来就是 AppKit 的东西，
        // 换成直接装配的 `NSMenu` 后少一层宿主，也不用再照看环境注入。
        return MenuSpec.makeMenu(
            TrackActions(tracks: picked, appState: appState,
                         playContext: playContext(at: row)).libraryRow())
    }

    /// 表格空白区双击（clickedRow == -1、clickedColumn 有效）＝自动调该列宽；
    /// 落在行上就是播放（`tableDoubleClicked:`，`[实测]`）。
    @objc func tableDoubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow < 0 else {
            play(at: sender.clickedRow)
            return
        }
        let index = sender.clickedColumn
        guard sender.tableColumns.indices.contains(index),
              let key = Key(rawValue: sender.tableColumns[index].identifier.rawValue) else { return }
        autoFit([key])
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// 补白行不是曲目，选不中（方向键也会自己跳过去）。
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        track(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let tableView = tableView as? TrackDisplayTableView else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SongsRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsTableRowView
            ?? {
                let fresh = SongsTableRowView()
                fresh.identifier = identifier
                return fresh
            }()
        // 行视图是复用的：上一次它可能正挂着悬浮态，装到别的行上会显形在错的一行。
        view.rollover = row == tableView.rolloverRow
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let key = Key(rawValue: tableColumn.identifier.rawValue),
              items.indices.contains(row) else { return nil }
        // 插图列画的是整块，内容取块首那一首；补白行除了插图列什么都不画。
        let track = key == .artwork ? self.track(at: artwork.start(of: row)) : self.track(at: row)
        guard let track else { return nil }
        let spec = SongsTableColumns.column(key)
        switch key {
        case .checked:
            let identifier = NSUserInterfaceItemIdentifier("SongsCheckbox")
            let view = tableView.makeView(withIdentifier: identifier, owner: self)
                as? SongsCheckboxCellView ?? SongsCheckboxCellView(identifier: identifier)
            let library = appState.library
            view.configure(checked: library.isChecked(track)) { [weak library] checked in
                library?.setChecked(track, checked)
            }
            return view
        case .artwork, .trackArtwork, .nowPlaying, .title, .cloud, .favorite, .rating:
            let identifier = NSUserInterfaceItemIdentifier("rich." + key.rawValue)
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsRichCellView
                ?? SongsRichCellView(key: key, appState: appState, identifier: identifier)
            view.configure(track: track, data: cellData(key: key, track: track, row: row),
                           controller: self)
            return view
        default:
            let identifier = NSUserInterfaceItemIdentifier("SongsText")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SongsTextCellView
                ?? {
                    let fresh = SongsTextCellView()
                    fresh.identifier = identifier
                    return fresh
                }()
            // 数字列用等宽数字字体，右对齐时逐位对齐（`setupListFontFromPrefs:` 配的第三把字体）
            view.font = spec.trailing
                ? .monospacedDigitSystemFont(ofSize: listSize.fontSize, weight: .regular)
                : .systemFont(ofSize: listSize.fontSize)
            view.trailing = spec.trailing
            view.text = SongsTableColumns.text(for: key, track: track, library: appState.library,
                                               downloads: appState.downloads)
            return view
        }
    }

    private func cellData(key: Key, track: Track, row: Int) -> SongsCellData {
        var data = SongsCellData()
        data.key = key
        data.track = track
        data.rowHeight = settings.columns.rowHeight(base: listSize.rowHeight)
        data.fontSize = listSize.fontSize
        data.showsArtworkColumn = settings.columns.showsArtwork
        if key == .artwork {
            data.blockIndex = artwork.index(of: row)
            data.blockLength = artwork.length(of: row)
            data.alwaysShowsCover = settings.alwaysShowArtwork
            data.rowSpan = artwork.rowSpan
            // 封面边长与文字左沿都是从**行高**推的（见 `artworkCoverSize(rowHeight:)`）
            data.coverSize = settings.columns.artworkCoverSize(rowHeight: data.rowHeight)
            data.textLeading = settings.columns.artworkTextLeading(rowHeight: data.rowHeight)
        }
        return data
    }

    /// 拖列换位：**区间内每一列都可移动**才准（`[实测]`）。
    /// 播放指示、标题、两条插图列的 `mMoveable` 为假，所以别的列也插不到它们前面。
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int,
                   toColumn newColumnIndex: Int) -> Bool {
        SongsTableColumns.canReorder(visible: settings.columns.visible,
                                     from: columnIndex, to: newColumnIndex)
    }

    /// 条纹是表格自己在 `drawBackground(inClipRect:)` 里画的，选中行要跳过条纹，
    /// 所以选中一变就得把背景整块重画一遍——行视图自己的重绘管不到表格的背景。
    func tableViewSelectionDidChange(_ notification: Notification) {
        tableView?.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, didDrag tableColumn: NSTableColumn) {
        saveColumnInfo()
    }

    /// 列头分隔线双击＝按内容收紧这一列。
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard tableView.tableColumns.indices.contains(column),
              let key = Key(rawValue: tableView.tableColumns[column].identifier.rawValue)
        else { return tableView.tableColumns[column].width }
        return autoFitWidth(for: key, in: rows)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncing, let descriptor = tableView.sortDescriptors.first,
              let name = descriptor.key, let key = Key(rawValue: name) else { return }
        // 插图列不是一条能排的字段：点它＝按专辑排 + 轮换专辑排序模式。
        // 表上的 descriptor 随后由 `syncSortDescriptors` 拨回专辑列。
        guard key != .artwork else {
            var sort = settings.sort
            sort.cycleAlbumMode()
            settings.sort = sort
            return
        }
        guard settings.sort.column != key || settings.sort.ascending != descriptor.ascending else { return }
        settings.sort = SongsTableSort(column: key, ascending: descriptor.ascending,
                                       albumMode: settings.sort.albumMode)
    }

    /// 输入字母跳行只比**当前排序列**的文本
    /// （`tableView:typeSelectStringForTableColumn:row:`）。
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?,
                   row: Int) -> String? {
        guard let tableColumn, tableColumn.identifier.rawValue == settings.sort.column.rawValue,
              let track = track(at: row) else { return nil }
        return SongsTableColumns.text(for: settings.sort.column, track: track,
                                      library: appState.library, downloads: appState.downloads)
    }

    // MARK: 拖曲目

    /// 一行一个 `NSPasteboardItem`：**返回 nil 的行不参与拖拽**，一行都写不出来时
    /// NSTableView 就不开拖拽会话，转而做范围选择（拖起来「选中区跟着鼠标扩」就是这个样子）。
    /// 所以这里只依赖两件确定的事：这一行有曲目、JSON 编得出来；类型直接写字符串常量，
    /// 不在拖拽这条热路径上碰 `UTType(exportedAs:)`（它要查一次 LaunchServices）。
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let track = track(at: row),
              let data = try? JSONEncoder().encode(TrackTransfer(tracks: [track]))
        else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: TrackTransfer.pasteboardType)
        return item
    }

    /// 多首一起拖是**层叠**形态（`setDraggingFormation(3)`）。
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        session.draggingFormation = .stack
    }

    /// 拖拽结束（可选实现）。落点没接住（operation 为空）时也走这里——
    /// 拖走的这一路上表格收不到 mouseExited，悬浮态会停在按下的那一行上，这里收干净。
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        (tableView as? TrackDisplayTableView)?.clearRollover()
    }
}

// MARK: - 表格

/// 条纹、组分隔线、键盘与悬浮跟踪。对应 Music 的 `TrackDisplayTableView`。
final class TrackDisplayTableView: NSTableView {
    private typealias M = MusicMetrics.SongsTable

    weak var controller: SongsTableController?
    /// 光标当前落在哪一行（没有就是 -1）。行视图会被复用，装配时得照它重置一次。
    private(set) var rolloverRow = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 拖列宽/换位时条纹与组分隔线要跟着走。它们是表格自己在 drawBackground 里画的，
        // AppKit 改列宽只会重排单元格、不会把表格背景标脏，不接这两条通知的话
        // 条纹会停在原地，直到别的原因触发一次重绘。
        for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(columnLayoutDidChange), name: name, object: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func columnLayoutDidChange(_ notification: Notification) {
        // 顺带告诉控制器「列真的动了」：它靠这条把「拖宽/换位」和「点列头排序」分开，
        // 只有前者松手时才把列宽写回存档。
        controller?.noteColumnLayoutChanged()
        needsDisplay = true
        // 选中底色是行视图自己画的（左沿也钉在插图列右边界上），一并标脏
        enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    /// 列头拖宽的**跟踪过程中**唯一每步都到的钩子。
    ///
    /// [实测 probe] 2026-09-07，独立探针（scratchpad，`NSScrollView + NSTableView`
    /// 照抄本类的配置，进程内合成事件送进 `NSTableHeaderView` 自己的
    /// `NSEventTrackingRunLoopMode` 跟踪循环，8 步每步 +10pt）：
    ///
    /// - `columnDidResizeNotification` **整个拖拽只发一次，在松手那一刻**，
    ///   所以上面那条通知这一路在拖的过程中根本没被叫到，管不了跟手。
    /// - 列宽之和 < 可视宽时（歌曲页的常态），`NSTableView` 的 frame 宽被钳在
    ///   clip 宽上不动，**行视图的 frame 一步都不变**（探针里 `row.setFrameSize`
    ///   零次）——所以在行视图里重写 `setFrameSize` 也接不到，白搭。
    ///   反过来列宽之和 > 可视宽时行视图确实每步 resize，AppKit 自己就会重画，
    ///   那种情形本来就不瘸。
    /// - 层的重绘策略不是原因：把行视图 `wantsLayer = true` 配
    ///   `.duringViewResize` / `.onSetNeedsDisplay` 两档都试过，跟踪期间
    ///   `drawSelection` 依旧**一次都没被调用**——是压根没标脏，不是画了被拉伸。
    /// - 每步都到的只有 `tile()`（表格背景每步也确实重画，条纹因此才跟手）。
    ///   挂在这里之后：基线 0 次 → 8 步各 4 行、每次拿到的都是当步的新边界。
    ///
    /// 只有插图列右边界真的挪了才标脏：选中底色的左沿只钉在这条竖线上，
    /// 别的列怎么拖都不影响它，逐帧全表重画太贵。
    override func tile() {
        super.tile()
        let edge = artworkColumnEdge
        guard edge != lastArtworkColumnEdge else { return }
        lastArtworkColumnEdge = edge
        enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    private var lastArtworkColumnEdge: CGFloat = -1

    /// 插图列的右边界——**现场从表格取**，不读模型。
    ///
    /// 模型里的列宽只在松手（`endHeaderTracking`）时才回写，拖的过程中它还是旧值；
    /// 条纹与选中底色的左沿都钉在这条竖线上，读模型就会「背景停在原地、单元格已经跟着动」。
    var artworkColumnEdge: CGFloat {
        guard let index = tableColumns.firstIndex(where: {
            $0.identifier.rawValue == SongsTableColumns.Key.artwork.rawValue
        }) else { return 0 }
        return rect(ofColumn: index).maxX
    }

    /// 隔行底色。曲目排完之后继续往下铺（Music 的空表格区同样有条纹），
    /// 但**不进插图列**：同一张专辑的插图是「一整块」，条纹横穿过去就散成一行一行了。
    /// 2026-08-16 与 Music 1.7 同屏取色核对：一块插图从头到尾恒为内容底色 rgb(43)，
    /// 右边的曲目列照常隔行 43/53。曲目排完之后那片空白没有单元格，条纹整宽铺。
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        let height = rowHeight
        guard height > 0 else { return }
        // 列宽之和超过可视区时表格的 bounds 就是整条 document 宽，条纹按它铺满；
        // 列填不满时 bounds 已经被 NSScrollView 撑到可视宽，两种情形都不会留白边。
        let width = max(bounds.width, clipRect.maxX)
        let artwork = artworkColumnEdge
        NSColor.textColor.withAlphaComponent(M.stripeOpacity).setFill()
        var index = max(0, Int(floor(clipRect.minY / height)))
        var y = CGFloat(index) * height
        while y < clipRect.maxY {
            // 选中行不铺条纹：实测「选中行 rgb(68)」是 11.8% 白压在**内容底色**上，
            // 压在条纹上会亮成 77。条纹与选中是二选一，不是叠加。
            if !index.isMultiple(of: 2), !selectedRowIndexes.contains(index) {
                let x = index < numberOfRows ? artwork : 0
                NSRect(x: x, y: y, width: width - x, height: height)
                    .intersection(clipRect).fill()
            }
            y += height
            index += 1
        }
        drawGroupDividers(in: clipRect, width: width, rowHeight: height)
    }

    /// 插图列的组与组之间那条线**贯穿整行宽**，不是只画在插图列里。
    private func drawGroupDividers(in clipRect: NSRect, width: CGFloat, rowHeight: CGFloat) {
        guard let starts = controller?.artwork.blockStarts, !starts.isEmpty else { return }
        NSColor.amberGroupDivider.setFill()
        for row in starts where row > 0 {
            let y = CGFloat(row) * rowHeight
            guard y >= clipRect.minY - rowHeight, y <= clipRect.maxY else { continue }
            NSRect(x: 0, y: y, width: width, height: M.separatorWidth).fill()
        }
    }

    /// 点一下要把第一响应者抢过来。
    ///
    /// AppKit 自己那套「点表格就获得焦点」在 SwiftUI 的宿主视图里不生效——
    /// 旧实现当年正是因此才改用 `NSEvent.addLocalMonitorForEvents` 收键盘
    /// （见 git 历史里的 `TableKeyMonitor`）。抢过来之后方向键、⌘A、输入跳行
    /// 才轮得到 NSTableView 自己处理。
    ///
    /// 但要放在 `super.mouseDown` **之后**：`super` 一进去就是 AppKit 的嵌套事件循环
    /// （在里头判定这一下是选择、拖拽还是双击，松手才返回）。
    /// [推] 「整行拖不动、只会范围选择」的根因就在这儿：先 `makeFirstResponder` 会让
    /// SwiftUI 的焦点状态在同一拍变化，随之而来的那次视图更新落进这个嵌套循环里，
    /// 打断了拖拽判定。AppKit 那一侧的前提都验过没问题——数据源的
    /// `tableView:pasteboardWriterForRow:` 确实暴露给了 ObjC、`canDragRowsWithIndexes:atPoint:`
    /// 默认返回 YES、`verticalMotionCanBeginDrag` 默认也是 YES，剩下能拦住它的只有
    /// 「按下这一下没被完整交给 super」。焦点晚一次 mouseUp 才拿到，键盘操作没有差别。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleArtworkClick(event, at: point) { return }
        super.mouseDown(with: event)
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    /// 点插图块：[推] 选中这张专辑的整块行，双击块播这张专辑（从块首起）。
    /// Music 的插图列是一整块的形，块里没有「单独一行」的语义。
    /// ⇧/⌘ 扩选照 AppKit 原样走（交回 super），否则用户没法在块之间加减选。
    private func handleArtworkClick(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let controller,
              event.modifierFlags.isDisjoint(with: [.shift, .command]) else { return false }
        let column = self.column(at: point)
        guard tableColumns.indices.contains(column),
              tableColumns[column].identifier.rawValue == SongsTableColumns.Key.artwork.rawValue
        else { return false }
        let row = self.row(at: point)
        guard row >= 0 else { return false }
        let start = controller.artwork.start(of: row)
        let length = controller.artwork.length(of: row)
        // 「始终显示」补出来的空行不是曲目，选不中，跳过
        let rows = (start..<(start + length)).filter { controller.track(at: $0) != nil }
        guard !rows.isEmpty else { return false }
        selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if event.clickCount == 2 { controller.play(at: start) }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return true
    }

    /// 方向键、⌘A、输入跳行都归 AppKit；这里只接 Music 另外接管的那几条。
    ///
    /// esc 清空选中这一条没了：它在 SwiftUI 那层就被当成 key equivalent 吃掉，
    /// `performKeyEquivalent` / `keyDown` / `cancelOperation:` 三个入口一个都收不到
    /// （旧实现是靠 `NSEvent.addLocalMonitorForEvents` 抢在窗口派发之前才拿到的）。
    /// 原生表格本来也不清选中，点空白区一样能清，不值得为它把事件监视器再装回来。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:                                    // Return / Enter
            if controller?.playSelection() == true { return }
        // 空格＝「控制 ▸ 播放/暂停」，转发给菜单这件事已经上移到 `AmberApplication.sendEvent`
        // （无修饰等价键在 AppKit 里排在第一响应者之后，表格会先把它吃掉——那份实测在
        // `AmberApplication` 的类型注释里）。这里只剩**没有正在播的曲目**那一档：菜单项被
        // `validateMenuItem` 判成禁用，`performKeyEquivalent` 返回 false，事件才落到这儿，
        // 语义与回车一致——播选中的这一首。带 ⌘/⌥/⌃ 的空格不接，那些是别人的等价键。
        case 49:                                        // Space
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isDisjoint(with: [.command, .option, .control]),
               controller?.playSelection() == true { return }
        // ⌫ 与 ⌘⌫ 走同一条：菜单里没有 ⌘⌫ 的等价键，命令键事件没人接就照常派发成 keyDown，
        // 这里不看修饰键，两下都落到同一个「先弹确认再删」上。
        case 51:                                        // ⌫ / ⌘⌫
            if controller?.deleteSelection() == true { return }
        default: break
        }
        super.keyDown(with: event)
    }

    /// ⌘A 只圈真曲目：`selectRowIndexes` 不问`shouldSelectRow:`，
    /// 不挑一遍的话插图块的补白行也会跟着高亮。
    override func selectAll(_ sender: Any?) {
        guard let controller else { return super.selectAll(sender) }
        selectRowIndexes(IndexSet((0..<numberOfRows).filter { controller.track(at: $0) != nil }),
                         byExtendingSelection: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return controller?.rowMenu(for: row)
    }

    // MARK: 悬浮

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// 从别处（边栏、列头）一步跨进表格时只有 mouseEntered，没有 mouseMoved——
    /// 光标没有在表格内部动过。两个入口都得认，不然「进来第一下」不显形。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setRollover(-1)
    }

    /// 拖拽走了之后收悬浮态：拖的这一路上没有 mouseExited。
    func clearRollover() { setRollover(-1) }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateRollover(at: convert(event.locationInWindow, from: nil))
    }

    private func updateRollover(at point: NSPoint) {
        setRollover(row(at: point))
    }

    /// ＝ Music 的 `tableView:setRollover:forRow:`：悬浮**不改行底色**，
    /// 只让云端下载键、空心心水星、空心评分星显形。
    private func setRollover(_ row: Int) {
        guard row != rolloverRow else { return }
        // 行号必须先判掉 -1（光标不在任何一行上）：拿 -1 去问 `rowView(atRow:)`
        // 会把这一趟 mouseMoved 整个中断掉，表现是悬浮**一次都不显形**。
        if rolloverRow >= 0 {
            (rowView(atRow: rolloverRow, makeIfNecessary: false) as? SongsTableRowView)?.rollover = false
        }
        rolloverRow = row
        guard row >= 0 else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? SongsTableRowView)?.rollover = true
    }
}

// MARK: - 行视图

final class SongsTableRowView: NSTableRowView {
    private typealias M = MusicMetrics.SongsTable

    /// 插图列的右边界（没开插图列就是 0）。选中底色从这条竖线起画。
    /// **现场问表格要**，不缓存也不读模型——拖列宽时模型还是旧值，缓存的那份也不会更新，
    /// 两者都会让选中底色停在原来的位置上。
    private var artworkColumnWidth: CGFloat {
        var view: NSView? = superview
        while let current = view {
            if let table = current as? TrackDisplayTableView { return table.artworkColumnEdge }
            view = current.superview
        }
        return 0
    }

    var rollover = false {
        didSet {
            guard rollover != oldValue else { return }
            pushState()
        }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            pushState()
            needsDisplay = true
        }
    }

    /// 选中底色用实测的浓度自己画，并在插图列显示时把矩形左沿顶到插图列右边界
    /// （`_highlightRectForRow:`：`x = MaxX(第0列)`、`width = MaxX(super) - MaxX(第0列)`）。
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        var rect = bounds
        let edge = artworkColumnWidth
        if edge > 0 {
            rect.origin.x = edge
            rect.size.width = max(0, bounds.maxX - edge)
        }
        NSColor.textColor.withAlphaComponent(M.selectedOpacity).setFill()
        rect.intersection(dirtyRect).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SongsRichCellView)?.setState(selected: isSelected, rollover: rollover)
    }

    private func pushState() {
        for view in subviews {
            (view as? SongsRichCellView)?.setState(selected: isSelected, rollover: rollover)
        }
    }
}

// MARK: - 列头

/// 列头本体。整列拖动的高亮、分隔线双击、拖宽全归 AppKit；
/// 这里只补两件：把高度钉在实测的 23、以及右键菜单。
final class TrackDisplayNSHeader: NSTableHeaderView {
    private typealias M = MusicMetrics.SongsTable

    weak var controller: SongsTableController?

    /// NSScrollView 按 headerView 的 frame 高度摆表头，行高变了它也会重摆——只能在 setter 里钉住。
    override var frame: NSRect {
        get { super.frame }
        set {
            var fixed = newValue
            fixed.size.height = M.headerHeight
            super.frame = fixed
        }
    }

    /// 列头底色：Music 实测 rgb(37,40,42)，比内容区 rgb(43,43,43) **更暗**且带一点冷味。
    /// 原生 NSTableHeaderView 在这个外观下画出来的不是这个值，仍旧上实测死值。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.amberTableHeader.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        // 列填不满时右侧补一条空栏（底色照旧），整条列头下沿再收一根线
        let end = tableView?.tableColumns.reduce(0) { $0 + $1.width } ?? 0
        if bounds.maxX > end {
            NSColor.amberTableHeader.setFill()
            NSRect(x: end, y: bounds.minY, width: bounds.maxX - end, height: bounds.height)
                .intersection(dirtyRect).fill()
        }
        NSColor.amberLabelDivider.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - M.separatorWidth,
               width: bounds.width, height: M.separatorWidth).fill()
    }

    /// 按下就进 AppKit 的嵌套事件循环（slide-reorder 或拖宽），松手才返回。
    override func mouseDown(with event: NSEvent) {
        controller?.beginHeaderTracking()
        super.mouseDown(with: event)
        controller?.endHeaderTracking()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return controller?.headerMenu(forColumn: column(at: point))
    }
}

/// 一格列头：底色、文字或图标、排序箭头、右侧竖线。
final class SongsHeaderCell: NSTableHeaderCell {
    private typealias M = MusicMetrics.SongsTable

    var key: SongsTableColumns.Key = .title
    var icon: String?
    var trailing = false
    /// 当前排序列才有值，nil 表示这一列不带箭头。
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // 底色要一格一格自己铺：NSTableHeaderView 会先给每条列的区域画一层它自己的底
        // （实测 rgb(49)），比列头实测的 rgb(37,40,42) 亮一截，不盖掉就只有右侧空栏是对的。
        NSColor.amberTableHeader.setFill()
        cellFrame.fill()
        NSColor.amberLabelDivider.setFill()
        NSRect(x: cellFrame.maxX - M.separatorWidth, y: cellFrame.minY,
               width: M.separatorWidth, height: cellFrame.height).fill()

        var content = cellFrame
        content.size.width -= M.separatorWidth
        let arrow = sortAscending.flatMap {
            Self.symbol($0 ? "chevron.up" : "chevron.down", size: M.sortArrowSize, weight: .semibold)
        }
        if let icon {
            draw(icon: icon, in: content)
        } else if !stringValue.isEmpty {
            // 方向箭头占的那一段要先扣掉，否则右对齐的列（时长、播放次数…）
            // 标题与箭头会画在同一处，箭头直接压在字上。
            draw(title: stringValue, in: content,
                 reserving: arrow.map { $0.size.width + M.cellInset } ?? 0)
        }
        if let arrow { draw(arrow: arrow, in: content) }
    }

    private func draw(title: String, in frame: NSRect, reserving arrowWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = trailing ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: M.headerFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: frame.minX + M.cellInset,
                          y: frame.midY - size.height / 2,
                          width: max(0, frame.width - M.cellInset * 2 - arrowWidth),
                          height: size.height)
        (title as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func draw(icon name: String, in frame: NSRect) {
        guard let image = Self.symbol(name, size: M.headerFontSize) else { return }
        let size = image.size
        image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    /// 当前排序列在该格右端画方向箭头（图标列一样能排，箭头挂在图标右边）。
    private func draw(arrow image: NSImage, in frame: NSRect) {
        let size = image.size
        image.draw(in: NSRect(x: frame.maxX - M.cellInset - 1 - size.width,
                              y: frame.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    private static func symbol(_ name: String, size: CGFloat,
                               weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

// MARK: - 插图列的行类型

/// 插图列不是一个跨行的大视图，而是**每行一个格子 + 一个「行类型」**，靠切片拼成一块
/// （`rebuildAlbumArtTypes`，`[实测]` 逐指令还原）。
enum SongsAlbumArt {
    /// 同一张专辑的判定键：音源常常不给专辑 id，退回专辑名 + 艺人。
    static func key(for track: Track) -> String {
        "\(track.albumId ?? track.albumName)\u{1}\(track.artistName)"
    }

    /// 「始终显示」时给不满一块的专辑补空行。
    ///
    /// Music 实测（2026-08-16 与 1.7 同屏）：只有一首歌的专辑照样占满 `rowSpan` 行——
    /// 右边空两行，插图那一块才画得下整块封面 + 专辑名 + 艺人 + 星级。
    /// 补出来的行只是块的一部分，不是曲目：不可选、不参与播放与拖拽。
    static func padded(_ tracks: [Track], rowSpan: Int) -> [Track?] {
        var result: [Track?] = []
        var index = 0
        while index < tracks.count {
            let blockKey = key(for: tracks[index])
            var length = 0
            while index + length < tracks.count,
                  key(for: tracks[index + length]) == blockKey { length += 1 }
            result.append(contentsOf: tracks[index..<(index + length)].map { Optional($0) })
            if length < rowSpan {
                result.append(contentsOf: [Track?](repeating: nil, count: rowSpan - length))
            }
            index += length
        }
        return result
    }

    /// 逐行的专辑判定键。补白行算在上面那一块里。
    static func keys(for items: [Track?]) -> [String] {
        var result: [String] = []
        for item in items {
            result.append(item.map(key(for:)) ?? result.last ?? "")
        }
        return result
    }

    /// 逐行比较本行与上一行的专辑，给出行类型：
    /// `0` 独行 /`1` 块首 /`2,3,4…` 第 n 片 /`8` 超出封面跨度 /`9` 块尾。
    static func rowTypes(for items: [Track?], rowSpan: Int) -> [Int] {
        let keys = keys(for: items)
        guard !keys.isEmpty else { return [] }
        var types = [Int](repeating: 0, count: keys.count)
        var run = 0
        for index in keys.indices where index > 0 {
            if keys[index] != keys[index - 1] {
                // 换专辑：上一行若已有 run≥1 就回填成块尾
                if run >= 1 { types[index - 1] = 9 }
                types[index] = 0
                run = 0
            } else if run == 0 {
                types[index - 1] = 1
                types[index] = 2
                run = 1
            } else if run == 1 {
                types[index] = 3
                run = 2
            } else {
                types[index] = run + 1 < rowSpan ? run + 2 : 8
                run += 1
            }
        }
        // 最后一块的块尾在转储里没有对应指令（那段逻辑挂在「下一行换了专辑」上），
        // 按同样的语义收口，免得表末那一块没有块尾。
        if run >= 1, let last = types.indices.last { types[last] = 9 }
        return types
    }

    /// 由行类型切出来的块：每行属于哪一块、块有多长。
    struct Layout {
        var types: [Int] = []
        /// 每行所属块的起始行
        var starts: [Int] = []
        /// 每块的行数，按起始行索引
        var lengths: [Int: Int] = [:]
        var rowSpan = 3

        static let empty = Layout()

        var blockStarts: [Int] { lengths.keys.sorted() }

        /// 本行所属块的起始行
        func start(of row: Int) -> Int {
            starts.indices.contains(row) ? starts[row] : row
        }

        func index(of row: Int) -> Int {
            guard starts.indices.contains(row) else { return 0 }
            return row - starts[row]
        }

        func length(of row: Int) -> Int {
            guard starts.indices.contains(row) else { return 1 }
            return lengths[starts[row]] ?? 1
        }
    }

    static func layout(for items: [Track?], rowSpan: Int) -> Layout {
        let types = rowTypes(for: items, rowSpan: rowSpan)
        var starts = [Int](repeating: 0, count: types.count)
        var lengths: [Int: Int] = [:]
        var start = 0
        for index in types.indices {
            // 块首只可能是 0（独行）或 1（多行块的头一行）
            if types[index] == 0 || types[index] == 1 { start = index }
            starts[index] = start
            lengths[start, default: 0] += 1
        }
        return Layout(types: types, starts: starts, lengths: lengths, rowSpan: rowSpan)
    }
}
