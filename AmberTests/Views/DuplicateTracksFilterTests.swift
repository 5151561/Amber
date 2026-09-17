import XCTest
@testable import Amber

/// 「显示重复项目」的判定（spec §10.3）。
///
/// 判据本身是 `[推]`（宽松＝曲名+艺人、严格＝再加专辑+时长，见
/// `DuplicateTracksFilter` 的注释：C++ 侧的比较谓词读不到），所以这里测的是
/// **我们选的这条口径有没有被老实执行**：分组、原顺序、规范化、两档的差别。
final class DuplicateTracksFilterTests: XCTestCase {

    /// id 只用来区分是哪一条，判定不看它。
    private func track(_ id: String, title: String, artist: String,
                       album: String = "自传", duration: TimeInterval = 200) -> Track {
        Track(id: "qq:\(id)", kind: .qq, title: title, artistName: artist,
              artistId: nil, albumName: album, albumId: nil,
              artworkURL: nil, duration: duration)
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id) }

    // MARK: - 宽松档

    /// 曲名 + 艺人一致就算一组；组里两条都要留下。
    func testLooseGroupsByTitleAndArtist() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天"),
                      track("2", title: "咸鱼", artist: "五月天", album: "第二人生", duration: 311)]
        XCTAssertEqual(ids(DuplicateTracksFilter.duplicates(in: tracks, match: .loose)),
                       ["qq:1", "qq:2"])
    }

    /// 只出现一次的不入选；同名不同艺人也不是重复。
    func testNonDuplicatesAreDropped() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天"),
                      track("2", title: "咸鱼", artist: "告五人"),
                      track("3", title: "干杯", artist: "五月天")]
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).isEmpty)
    }

    /// 三条一组：不是只留「多出来的那两条」，整组都是重复项。
    func testThreeInOneGroupAllSurvive() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天"),
                      track("2", title: "咸鱼", artist: "五月天"),
                      track("3", title: "咸鱼", artist: "五月天")]
        XCTAssertEqual(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).count, 3)
    }

    /// **保持原顺序**：结果是原表的子序列，不按组聚拢（重排是流水线最后一步的事）。
    func testOriginalOrderIsPreserved() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天"),
                      track("2", title: "干杯", artist: "五月天"),
                      track("3", title: "干杯", artist: "五月天"),
                      track("4", title: "咸鱼", artist: "五月天")]
        XCTAssertEqual(ids(DuplicateTracksFilter.duplicates(in: tracks, match: .loose)),
                       ["qq:1", "qq:2", "qq:3", "qq:4"])
    }

    /// 大小写与首尾空白在比较前被规范化掉——两份记录来自不同音源时这类差别最常见。
    func testCaseAndWhitespaceAreNormalized() {
        let tracks = [track("1", title: " Emily ", artist: "刘惜君"),
                      track("2", title: "emily", artist: " 刘惜君")]
        XCTAssertEqual(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).count, 2)
    }

    // MARK: - 严格档

    /// 严格档：专辑与时长都一致才算重复（时长按秒取整，几十毫秒的差别不该拆组）。
    func testExactNeedsAlbumAndDuration() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天", album: "自传", duration: 311.2),
                      track("2", title: "咸鱼", artist: "五月天", album: "自传", duration: 310.9)]
        XCTAssertEqual(ids(DuplicateTracksFilter.duplicates(in: tracks, match: .exact)),
                       ["qq:1", "qq:2"])
    }

    /// 专辑不同：宽松档算重复，严格档不算。
    func testExactSplitsOnDifferentAlbum() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天", album: "自传"),
                      track("2", title: "咸鱼", artist: "五月天", album: "第二人生")]
        XCTAssertEqual(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).count, 2)
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: tracks, match: .exact).isEmpty)
    }

    /// 时长差到秒：同上，只有宽松档把它们算成一组。
    func testExactSplitsOnDifferentDuration() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天", duration: 200),
                      track("2", title: "咸鱼", artist: "五月天", duration: 245)]
        XCTAssertEqual(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).count, 2)
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: tracks, match: .exact).isEmpty)
    }

    /// 严格档在一堆宽松重复里只挑出真正一模一样的那两条。
    func testExactPicksOnlyTheIdenticalPair() {
        let tracks = [track("1", title: "咸鱼", artist: "五月天", album: "自传", duration: 311),
                      track("2", title: "咸鱼", artist: "五月天", album: "第二人生", duration: 290),
                      track("3", title: "咸鱼", artist: "五月天", album: "自传", duration: 311)]
        XCTAssertEqual(ids(DuplicateTracksFilter.duplicates(in: tracks, match: .exact)),
                       ["qq:1", "qq:3"])
    }

    // MARK: - 边界

    /// 空表进、空表出（`refresh` 里会拿这个结果直接灌快照）。
    func testEmptyInput() {
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: [], match: .loose).isEmpty)
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: [], match: .exact).isEmpty)
    }

    // MARK: - 菜单三态标题

    /// 不在重复视图、没按 Option：res 30500 idx 16。
    func testMenuTitleLoose() {
        XCTAssertEqual(DuplicatesMenuItem.title(showingDuplicates: false, optionDown: false),
                       "显示重复项目")
    }

    /// 按住 Option 换成严格档那一条（idx 17 = idx 16 + 1，ASM 里的 `cinc`）。
    func testMenuTitleExactWithOption() {
        XCTAssertEqual(DuplicatesMenuItem.title(showingDuplicates: false, optionDown: true),
                       "显示完全重复的项目")
    }

    /// 已经在重复视图里：只剩「退出」这一条，**Option 按不按都一样**——
    /// ASM 里那一支是先判 bit7 才轮到修饰键，顺序不能反。
    func testMenuTitleShowingAllIgnoresOption() {
        XCTAssertEqual(DuplicatesMenuItem.title(showingDuplicates: true, optionDown: false),
                       "显示所有项目")
        XCTAssertEqual(DuplicatesMenuItem.title(showingDuplicates: true, optionDown: true),
                       "显示所有项目")
    }

    /// 字段之间不许「串味」：曲名/艺人＝`夜`/`曲人` 与 `夜曲`/`人` 直接拼起来是同一串，
    /// 但显然不是同一首歌（分组键里那个分隔符就是为这个留的）。
    func testFieldsDoNotBleedIntoEachOther() {
        let tracks = [track("1", title: "夜", artist: "曲人"),
                      track("2", title: "夜曲", artist: "人")]
        XCTAssertTrue(DuplicateTracksFilter.duplicates(in: tracks, match: .loose).isEmpty)
    }
}
