import XCTest
@testable import Amber

/// 歌曲表设置的落盘与回读。
///
/// 排序列/方向与筛选在 Music 里都是持久状态（见 SongsTableSettings 上的 `[实测]` 出处），
/// 关掉 App 再开不该回到出厂的「艺人升序 / 所有歌曲」。
@MainActor
final class SongsTableSettingsTests: XCTestCase {

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SongsTableSettingsTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testSortAndFilterSurviveRelaunch() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        XCTAssertEqual(settings.sort.column, .artist)
        XCTAssertTrue(settings.sort.ascending)

        settings.sort.toggle(.playCount)        // 换列 → 升序
        settings.sort.toggle(.playCount)        // 再点一下 → 降序
        settings.filter = .favorites

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertEqual(restored.sort.column, .playCount)
        XCTAssertFalse(restored.sort.ascending)
        XCTAssertEqual(restored.filter, .favorites)
    }

    /// 专辑排序模式（插图列头轮换的那三档）跟排序列/方向存在同一条里，一起回来。
    func testAlbumSortModeSurvivesRelaunch() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        // 出厂是「专辑」；打开「显示插图」那一下抬到「按艺人排列专辑」（两次实测合起来的结论，[推]）
        XCTAssertEqual(settings.sort.albumMode, .album)
        settings.showArtwork = true
        XCTAssertEqual(settings.sort.albumMode, .byArtist)

        settings.sort.toggle(.album)
        var sort = settings.sort
        sort.cycleAlbumMode()                   // 已经在专辑列上，这一下换档
        settings.sort = sort
        XCTAssertEqual(settings.sort.albumMode, .byArtistYear)

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertEqual(restored.sort.column, .album)
        XCTAssertEqual(restored.sort.albumMode, .byArtistYear)
    }

    /// 排序列被藏起来要退回默认列，但模式是排序状态里独立的一档，不跟着回出厂值。
    func testAlbumSortModeSurvivesSortColumnFallback() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        var sort = SongsTableSort(column: .genre, ascending: true, albumMode: .byArtistYear)
        settings.sort = sort
        settings.toggleVisible(.genre)          // 把排序列藏起来
        sort = settings.sort

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertEqual(restored.sort.column, SongsTableSort().column)
        XCTAssertEqual(restored.sort.albumMode, .byArtistYear)
    }

    /// 排序依据被藏起来之后，下次启动要退回默认列——否则表面上没有任何列在排序。
    func testHiddenSortColumnFallsBackToDefault() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        settings.sort.toggle(.genre)
        settings.toggleVisible(.genre)          // 把这一列藏起来（会连带落盘）

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertFalse(restored.columns.isVisible(.genre))
        XCTAssertEqual(restored.sort.column, SongsTableSort().column)
    }

    /// 插图那四个开关照旧一起存一起读。
    func testArtworkFlagsRoundTrip() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        settings.showArtwork = true
        settings.alwaysShowArtwork = true
        settings.artworkSize = 2
        settings.showTrackArtwork = true

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertTrue(restored.showArtwork)
        XCTAssertTrue(restored.alwaysShowArtwork)
        XCTAssertEqual(restored.artworkSize, 2)
        XCTAssertTrue(restored.showTrackArtwork)
        XCTAssertTrue(restored.columns.showsArtwork)
        XCTAssertEqual(restored.columns.rowHeight(base: 22),
                       MusicMetrics.SongsTable.trackArtworkRowHeight)
    }

    /// 列宽/显隐/顺序仍旧走 save()，别被新加的两把钥匙串了。
    func testColumnsStillPersistSeparately() {
        let defaults = makeDefaults()
        let settings = SongsTableSettings(defaults: defaults)
        settings.columns.setWidth(321, for: .artist)
        settings.save()

        let restored = SongsTableSettings(defaults: defaults)
        XCTAssertEqual(restored.columns[.artist], 321)
    }
}
