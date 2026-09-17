import AppKit
import XCTest
@testable import Amber

/// 歌曲表的列模型与插图列的行类型分类器。
///
/// 表格骨架换成 NSTableView 之后，选择、键盘、滚动、整列拖动都归 AppKit 了，
/// 这边只剩下「Amber 自己说了算」的那几条判定：哪些列能显示、能不能拖着换位、
/// 存档怎么迁移，以及插图列是怎么按专辑切块的。
@MainActor
final class SongsTableColumnsTests: XCTestCase {

    private func track(_ id: String, album: String, albumId: String? = nil,
                       artist: String = "艺人", trackNumber: Int? = nil,
                       discNumber: Int? = nil, title: String? = nil) -> Track {
        Track(id: id, kind: .netease, title: title ?? "曲 \(id)", artistName: artist,
              artistId: nil, albumName: album, albumId: albumId, artworkURL: nil, duration: 200,
              trackNumber: trackNumber, discNumber: discNumber)
    }

    // MARK: 显隐与宽度

    /// 出厂显示的就是 Music 的默认那几列，插图两列要开关打开才出现。
    func testDefaultVisibleColumns() {
        var columns = SongsTableColumns()
        XCTAssertEqual(columns.visible.map(\.key),
                       [.nowPlaying, .title, .cloud, .duration, .artist, .album, .genre,
                        .favorite, .rating, .playCount])
        columns.showsArtwork = true
        columns.showsTrackArtwork = true
        XCTAssertEqual(columns.visible.first?.key, .artwork)
        XCTAssertEqual(columns.visible.dropFirst().first?.key, .trackArtwork)
    }

    /// 固定列（播放指示、标题）在增删菜单里点不动。
    func testFixedColumnsCannotBeHidden() {
        var columns = SongsTableColumns()
        columns.toggleVisible(.title)
        columns.toggleVisible(.nowPlaying)
        XCTAssertTrue(columns.isVisible(.title))
        XCTAssertTrue(columns.isVisible(.nowPlaying))
        columns.toggleVisible(.genre)
        XCTAssertFalse(columns.isVisible(.genre))
    }

    /// 列宽下限是列自己的 minWidth，拖到比它还窄要被兜住。
    func testWidthClampedToMinimum() {
        var columns = SongsTableColumns()
        columns.setWidth(1, for: .title)
        XCTAssertEqual(columns[.title], SongsTableColumns.column(.title).minWidth)
    }

    /// 开插图列时「状态」那条槽要放曲目编号，取值由 26 顶到 56。
    func testStatusColumnWidensWithArtwork() {
        var columns = SongsTableColumns()
        XCTAssertEqual(columns[.nowPlaying], MusicMetrics.SongsTable.nowPlayingWidth)
        columns.showsArtwork = true
        XCTAssertEqual(columns[.nowPlaying], MusicMetrics.SongsTable.artworkStatusWidth)
    }

    /// 开曲目封面列时行高直接顶到 54，不再按列表尺寸分档。
    func testRowHeightFollowsTrackArtwork() {
        var columns = SongsTableColumns()
        XCTAssertEqual(columns.rowHeight(base: 22), 22)
        columns.showsTrackArtwork = true
        XCTAssertEqual(columns.rowHeight(base: 22), MusicMetrics.SongsTable.trackArtworkRowHeight)
    }

    // MARK: 换位

    /// 区间内每一列都可移动才准换位（`[实测]`）。
    func testReorderNeedsWholeRangeMovable() {
        let visible = SongsTableColumns().visible
        // 云端下载(2) → 时长(3)：中间没有钉住的列
        XCTAssertTrue(SongsTableColumns.canReorder(visible: visible, from: 2, to: 3))
        // 拖到最右端之后：落点索引可以等于列数
        XCTAssertTrue(SongsTableColumns.canReorder(visible: visible, from: 2, to: visible.count))
        // 往左越过标题/播放指示这两条钉住的列：整段不准
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: 5, to: 0))
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: 5, to: 1))
        // 钉住的列自己也拖不走
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: 1, to: 4))
        // 原地不动不算换位
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: 3, to: 3))
        // AppKit 起手先拿 -1 问一次「这一列能不能拖」：可移动的列必须放行，
        // 答 false 的话整场拖动根本不会开始
        XCTAssertTrue(SongsTableColumns.canReorder(visible: visible, from: 5, to: -1))
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: 1, to: -1))
    }

    /// 换完位把可见列的新顺序整份写回；隐藏列留在原来的槽位上，不跟着漂。
    func testApplyVisibleOrderKeepsHiddenColumnsInPlace() {
        var columns = SongsTableColumns()
        var keys = columns.visible.map(\.key)
        let moved = keys.remove(at: 2)          // 云端下载
        keys.append(moved)                      // 挪到最右
        columns.applyVisibleOrder(keys)
        XCTAssertEqual(columns.visible.map(\.key), keys)

        // 隐藏列没被换位打乱：把「年份」显示出来之后，已见列彼此的先后原样不动
        columns.toggleVisible(.year)
        let shown = columns.visible.map(\.key)
        XCTAssertTrue(shown.contains(.year))
        XCTAssertEqual(shown.filter { $0 != .year }, keys)
    }

    /// 数量对不上就整份不动，免得把列弄丢。
    func testApplyVisibleOrderRejectsMismatchedSet() {
        var columns = SongsTableColumns()
        let before = columns.visible.map(\.key)
        columns.applyVisibleOrder([.title, .artist])
        XCTAssertEqual(columns.visible.map(\.key), before)
    }

    // MARK: 存档

    /// 版本升级新增的列不在旧存档里，要按出厂顺序插回原位，而不是一律追到最右。
    func testDecodeInsertsNewColumnsAtFactoryPosition() {
        var saved = SongsTableColumns()
        saved.setWidth(321, for: .artist)
        var json = saved.encoded
        // 摹拟一份「还不知道曲目封面列」的旧存档
        json = json.replacingOccurrences(of: "\"trackArtwork\",", with: "")
        var restored = SongsTableColumns()
        restored.decode(json)
        restored.showsTrackArtwork = true
        XCTAssertEqual(restored[.artist], 321)
        XCTAssertEqual(restored.visible.first?.key, .trackArtwork)
    }

    // MARK: 插图列的行类型

    /// `rebuildAlbumArtTypes`：0 独行 / 1 块首 / 2,3… 第 n 片 / 8 超出封面跨度 / 9 块尾。
    func testAlbumArtRowTypes() {
        let tracks = [track("1", album: "A"), track("2", album: "A"), track("3", album: "A"),
                      track("4", album: "B"),
                      track("5", album: "C"), track("6", album: "C")]
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: tracks, rowSpan: 3), [1, 2, 9, 0, 1, 9])
    }

    /// 铺满封面跨度之后的行是 8（封面已铺完），块尾照样回填成 9。
    func testAlbumArtRowTypesBeyondRowSpan() {
        let tracks = (1...6).map { track("\($0)", album: "A") }
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: tracks, rowSpan: 3), [1, 2, 3, 8, 8, 9])
        // 封面拉大档能铺更多行，第 n 片就一路排下去
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: tracks, rowSpan: 5), [1, 2, 3, 4, 5, 9])
    }

    /// 独行块就是 0，不带块首块尾。
    func testAlbumArtSingleRowBlocks() {
        let tracks = [track("1", album: "A"), track("2", album: "B")]
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: tracks, rowSpan: 3), [0, 0])
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: [], rowSpan: 3), [])
    }

    /// 同名不同碟（albumId 不同）不算一块。
    func testAlbumArtKeyUsesAlbumIdentity() {
        let tracks = [track("1", album: "同名", albumId: "x"), track("2", album: "同名", albumId: "y")]
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: tracks, rowSpan: 3), [0, 0])
    }

    /// 由行类型切出来的块：每行属于哪一块、块有多长。
    func testAlbumArtLayoutSlicesBlocks() {
        let tracks = [track("1", album: "A"), track("2", album: "A"), track("3", album: "A"),
                      track("4", album: "B")]
        let layout = SongsAlbumArt.layout(for: tracks, rowSpan: 3)
        XCTAssertEqual(layout.blockStarts, [0, 3])
        XCTAssertEqual((0..<4).map(layout.index(of:)), [0, 1, 2, 0])
        XCTAssertEqual((0..<4).map(layout.length(of:)), [3, 3, 3, 1])
    }

    /// 「始终显示」时短块要补空行：一首歌的专辑照样占满 3 行，右边空两行。
    func testAlbumArtPadsShortBlocks() {
        let tracks = [track("1", album: "A"), track("2", album: "B"), track("3", album: "B")]
        let padded = SongsAlbumArt.padded(tracks, rowSpan: 3)
        XCTAssertEqual(padded.map { $0?.albumName }, ["A", nil, nil, "B", "B", nil])
        // 补出来的行算在上面那一块里，块因此正好铺满封面跨度
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: padded, rowSpan: 3), [1, 2, 9, 1, 2, 9])
        let layout = SongsAlbumArt.layout(for: padded, rowSpan: 3)
        XCTAssertEqual(layout.blockStarts, [0, 3])
        XCTAssertEqual((0..<6).map(layout.length(of:)), [3, 3, 3, 3, 3, 3])
    }

    /// 够长的块不补；块比跨度还长也只是照常往下排。
    func testAlbumArtPaddingLeavesFullBlocksAlone() {
        let tracks = (1...4).map { track("\($0)", album: "A") }
        XCTAssertEqual(SongsAlbumArt.padded(tracks, rowSpan: 3).count, 4)
        XCTAssertEqual(SongsAlbumArt.padded([], rowSpan: 3).count, 0)
    }

    /// 「插图大小」三档的本体是**跨行数** 3/5/7（`[实测]` `currArtworkRowSpan`），
    /// 封面边长反过来由行高推出来（`currArtworkDimension`：行高 × 跨行 − 边距 × 2）。
    func testAlbumArtRowSpanAndCoverSize() {
        var columns = SongsTableColumns()
        XCTAssertEqual(columns.artworkRowSpan, 3)
        // 中档行高 22：三档封面 56 / 100 / 144
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 22), 56)
        XCTAssertEqual(columns.artworkTextLeading(rowHeight: 22), 71)
        columns.artworkSize = 1
        XCTAssertEqual(columns.artworkRowSpan, 5)
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 22), 100)
        XCTAssertEqual(columns.artworkTextLeading(rowHeight: 22), 115)
        columns.artworkSize = 2
        XCTAssertEqual(columns.artworkRowSpan, 7)
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 22), 144)
        // 列表尺寸一变封面跟着变：小 18 → 44/80/116，大 40 → 110/190/270
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 18), 116)
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 40), 270)
        columns.artworkSize = 0
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 18), 44)
        XCTAssertEqual(columns.artworkCoverSize(rowHeight: 40), 110)
        // 档位越界照旧夹取
        columns.artworkSize = 9
        XCTAssertEqual(columns.artworkRowSpan, 7)
        columns.artworkSize = -3
        XCTAssertEqual(columns.artworkRowSpan, 3)
    }

    /// 插图列拖窄的下限跟着封面边长走（= 左右各一份内缩 7 + 封面，不含右边那 8 的间距），
    /// 静态的 40（ColumnWidths.plist 的 `minimum-column-width`）只在封面小到 26 以下才当家。
    func testArtworkMinWidthFollowsCoverSize() {
        var columns = SongsTableColumns()
        // 中档行高 22：三档封面 56/100/144 → 下限 70/114/158（封面左右各留 7）
        XCTAssertEqual(columns.artworkMinWidth(rowHeight: 22), 70)
        columns.artworkSize = 1
        XCTAssertEqual(columns.artworkMinWidth(rowHeight: 22), 114)
        columns.artworkSize = 2
        XCTAssertEqual(columns.artworkMinWidth(rowHeight: 22), 158)
        // 下限减去封面，左右两份内缩相等——最窄那一档封面是居中的
        for rowHeight in [CGFloat(18), 22, 40] {
            let margin = columns.artworkMinWidth(rowHeight: rowHeight)
                - columns.artworkCoverSize(rowHeight: rowHeight)
            XCTAssertEqual(margin, MusicMetrics.SongsTable.artworkInset * 2)
        }
        // 列表尺寸调到「大」（行高 40）时最大档封面 270 → 下限 284，比默认列宽 230 还宽
        XCTAssertEqual(columns.artworkMinWidth(rowHeight: 40), 284)
        XCTAssertGreaterThan(columns.artworkMinWidth(rowHeight: 40),
                             MusicMetrics.SongsTable.artworkWidth)
        // 任何一档都不会低于列自己登记的 40
        for size in 0...2 {
            columns.artworkSize = size
            for rowHeight in [CGFloat(18), 22, 40] {
                XCTAssertGreaterThanOrEqual(columns.artworkMinWidth(rowHeight: rowHeight),
                                            SongsTableColumns.column(.artwork).minWidth)
            }
        }
    }

    // MARK: 专辑排序模式

    /// 排序要用到资料库（年份来自专辑）与下载态（云端列），两份都落在临时目录里。
    private func makeStores() throws -> (LibraryStore, DownloadStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongsTableSortTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (LibraryStore(directory: directory), DownloadStore(directory: directory))
    }

    private func album(_ id: String, name: String, artist: String, year: String) -> Album {
        Album(id: id, kind: .netease, name: name, artistName: artist, artistId: nil,
              artworkURL: nil, publishDate: "\(year)-01-01", trackCount: 2, description: nil)
    }

    /// 三张碟，故意打乱着交进来。名字一律用拉丁字母：中文的次序要看当前语系的排序规则
    /// （`localizedStandardCompare`），换台机器就可能对不上。
    /// - Anna 的 Bravo（2010）与 Charlie（2001）：**专辑名的先后与年份的先后正好相反**，
    ///   三档模式才分得出来；
    /// - Bob 的 Alpha（2020）：专辑名排在最前，但按艺人排时要落到最后。
    private func sortFixture(_ library: LibraryStore) -> [Track] {
        let bravo = album("a1", name: "Bravo", artist: "Anna", year: "2010")
        let charlie = album("b1", name: "Charlie", artist: "Anna", year: "2001")
        let alpha = album("a2", name: "Alpha", artist: "Bob", year: "2020")
        let tracks = [
            track("1", album: bravo.name, albumId: bravo.id, artist: bravo.artistName,
                  trackNumber: 2, title: "Echo"),
            track("2", album: alpha.name, albumId: alpha.id, artist: alpha.artistName,
                  trackNumber: 1, title: "Delta"),
            track("3", album: charlie.name, albumId: charlie.id, artist: charlie.artistName,
                  trackNumber: 1, title: "Bravo"),
            track("4", album: bravo.name, albumId: bravo.id, artist: bravo.artistName,
                  trackNumber: 1, discNumber: 2, title: "Alpha"),
            track("5", album: bravo.name, albumId: bravo.id, artist: bravo.artistName,
                  trackNumber: 1, title: "Charlie"),
        ]
        for item in [bravo, charlie, alpha] {
            library.addAlbumToLibrary(item, tracks: tracks.filter { $0.albumId == item.id })
        }
        return tracks
    }

    /// 「专辑」：专辑名 → 光盘号 → 音轨号，不看艺人。
    func testAlbumModeSortsByAlbumThenDiscThenTrack() throws {
        let (library, downloads) = try makeStores()
        let tracks = sortFixture(library)
        let sort = SongsTableSort(column: .album, ascending: true, albumMode: .album)
        XCTAssertEqual(sort.apply(to: tracks, library: library, downloads: downloads).map(\.id),
                       // Alpha → Bravo（1 碟 1 号、1 碟 2 号、2 碟 1 号）→ Charlie
                       ["2", "5", "1", "4", "3"])
    }

    /// 「按艺人排列专辑」：艺人 → 专辑名 → 光盘号 → 音轨号。
    /// Bob 的 Alpha 专辑名最靠前，按艺人排就得排到最后。
    func testByArtistModeGroupsAlbumsUnderArtist() throws {
        let (library, downloads) = try makeStores()
        let tracks = sortFixture(library)
        let sort = SongsTableSort(column: .album, ascending: true, albumMode: .byArtist)
        XCTAssertEqual(sort.apply(to: tracks, library: library, downloads: downloads).map(\.id),
                       ["5", "1", "4", "3", "2"])
    }

    /// 「按艺人/年份排列专辑」：同一位艺人里改按年份排，老碟在前。
    func testByArtistYearModeOrdersAlbumsByYear() throws {
        let (library, downloads) = try makeStores()
        let tracks = sortFixture(library)
        let sort = SongsTableSort(column: .album, ascending: true, albumMode: .byArtistYear)
        XCTAssertEqual(sort.apply(to: tracks, library: library, downloads: downloads).map(\.id),
                       // Anna：2001 的 Charlie 排在 2010 的 Bravo 之前
                       ["3", "5", "1", "4", "2"])
    }

    /// 排序模式只管专辑列：按标题排时三档给出的次序完全一样。
    func testAlbumModeOnlyAppliesToAlbumColumn() throws {
        let (library, downloads) = try makeStores()
        let tracks = sortFixture(library)
        let byTitle = SongsTableSort(column: .title, ascending: true, albumMode: .album)
            .apply(to: tracks, library: library, downloads: downloads).map(\.id)
        let byTitleOther = SongsTableSort(column: .title, ascending: true, albumMode: .byArtistYear)
            .apply(to: tracks, library: library, downloads: downloads).map(\.id)
        XCTAssertEqual(byTitle, ["4", "3", "5", "2", "1"])
        XCTAssertEqual(byTitle, byTitleOther)
    }

    /// 插图列是**按连续行**切块的：开插图不再重排行，
    /// 按标题排就是一首一块，按专辑排才连成整块。
    func testArtworkBlocksFollowRowOrder() throws {
        let (library, downloads) = try makeStores()
        let tracks = sortFixture(library)
        let byTitle = SongsTableSort(column: .title, ascending: true)
            .apply(to: tracks, library: library, downloads: downloads)
        XCTAssertEqual(SongsAlbumArt.rowTypes(for: byTitle, rowSpan: 3), [0, 0, 0, 0, 0],
                       "按标题排：相邻两行不同碟，每行自成一块")
        let byAlbum = SongsTableSort(column: .album, ascending: true, albumMode: .byArtist)
            .apply(to: tracks, library: library, downloads: downloads)
        let layout = SongsAlbumArt.layout(for: byAlbum, rowSpan: 3)
        XCTAssertEqual(layout.blockStarts, [0, 3, 4], "Bravo 3 首、Charlie 1 首、Alpha 1 首")
    }

    /// 点插图列头：切到专辑列 → 三档轮一圈 → 轮完才翻升降序。
    func testCycleAlbumModeWrapsBeforeFlippingDirection() {
        var sort = SongsTableSort()                       // 出厂：艺人升序、专辑列模式「专辑」
        XCTAssertEqual(sort.albumMode, .album)
        sort.cycleAlbumMode()                             // 先把排序接管到专辑列，模式不动
        XCTAssertEqual(sort.column, .album)
        XCTAssertEqual(sort.albumMode, .album)
        XCTAssertTrue(sort.ascending)
        sort.cycleAlbumMode()
        XCTAssertEqual(sort.albumMode, .byArtist)
        XCTAssertTrue(sort.ascending)
        sort.cycleAlbumMode()
        XCTAssertEqual(sort.albumMode, .byArtistYear)
        XCTAssertTrue(sort.ascending)
        sort.cycleAlbumMode()                             // 轮回第一档，这一下才翻方向
        XCTAssertEqual(sort.albumMode, .album)
        XCTAssertFalse(sort.ascending)
    }
}
