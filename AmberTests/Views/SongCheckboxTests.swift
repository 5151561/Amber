import Combine
import XCTest
@testable import Amber

/// 设置 › 通用 ›「歌曲列表复选框」这条开关的三件事：
/// 勾选状态的存取与落盘、勾选列的显隐、以及自动连播时跳过没勾的那几首。
///
/// `LibraryStore` 注入临时目录，绝不碰真实的 `~/Library/Application Support/Amber/`。
@MainActor
final class SongCheckboxTests: XCTestCase {

    private var directory: URL!
    private var savedValues: SettingsValues!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongCheckboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedValues = AppSettings.shared.values
    }

    override func tearDown() async throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> LibraryStore { LibraryStore(directory: directory) }

    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map {
            Track(id: "check:\($0)", kind: .qq, title: "歌 \($0)", artistName: "艺人",
                  artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil, duration: 200)
        }
    }

    // MARK: - 勾选状态

    /// 没有记录就是勾着的：新歌一进资料库默认参加顺播，
    /// 存的是「取消勾选」的那一小撮（见 `uncheckedTrackIDs`）。
    func testTracksAreCheckedByDefault() {
        let store = makeStore()
        let tracks = makeTracks(3)
        XCTAssertTrue(tracks.allSatisfy { store.isChecked($0) })
    }

    func testSetCheckedRoundTripsThroughDisk() {
        let tracks = makeTracks(3)
        let store = makeStore()
        store.setChecked(tracks[0], false)
        store.setChecked([tracks[1], tracks[2]], false)
        store.setChecked(tracks[2], true)
        store.flushNow()

        let restored = makeStore()
        XCTAssertFalse(restored.isChecked(tracks[0]))
        XCTAssertFalse(restored.isChecked(tracks[1]))
        XCTAssertTrue(restored.isChecked(tracks[2]))
    }

    /// 这份集合不是 `@Published`，改动要自己发一声，歌曲页才会重画勾选列。
    /// 一批只发一次；没有真的改到东西时一声都不发。
    func testBatchChangeNotifiesOnce() {
        let store = makeStore()
        let tracks = makeTracks(3)
        var notifications = 0
        let token = store.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        store.setChecked(tracks, false)
        XCTAssertEqual(notifications, 1)
        store.setChecked(tracks, false)          // 已经是这个状态了
        XCTAssertEqual(notifications, 1)
        store.setChecked([], true)               // 空批
        XCTAssertEqual(notifications, 1)
    }

    /// 歌从资料库出去时勾选记录一起清掉，否则同一首歌重新加进来会带着上次的取消勾选。
    func testRemovingFromLibraryClearsCheckState() {
        let store = makeStore()
        let track = makeTracks(1)[0]
        store.addToLibrary(track)
        store.setChecked(track, false)
        XCTAssertFalse(store.isChecked(track))
        store.removeFromLibrary(track)
        XCTAssertTrue(store.isChecked(track))
    }

    // MARK: - 勾选列

    /// 开关关着时勾选列不存在；打开就出现在**云端那一列之前**（参照图 `编号 | ✓ | ☁ | 时长`）。
    /// 它不进列头右键菜单，也不进「显示选项」窗口的勾选框列表。
    func testCheckedColumnVisibilityFollowsSetting() {
        var columns = SongsTableColumns()
        XCTAssertFalse(columns.showsCheckboxes)
        XCTAssertFalse(columns.visible.contains { $0.key == .checked })

        columns.showsCheckboxes = true
        let keys = columns.visible.map(\.key)
        XCTAssertNotEqual(keys.first, .checked, "它不再是钉在最左的那一列")
        XCTAssertEqual(keys.firstIndex(of: .checked).map { $0 + 1 },
                       keys.firstIndex(of: .cloud), "出厂位应当紧挨在云端列之前")

        XCTAssertFalse(SongsTableColumns.toggleMenuOrder.contains(.checked))
        XCTAssertFalse(SongsTableColumns.sortMenuOrder.contains(.checked))
        XCTAssertFalse(SongsTableColumns.optionGroups.contains { $0.keys.contains(.checked) })
        XCTAssertFalse(columns.sortableColumns.contains(.checked))
    }

    /// 是一条**普通列**：能拖着换位，但不排序、也不拖宽（空 `resizingMask`）。
    func testCheckedColumnIsOrdinaryButNotSortableOrResizable() {
        let spec = SongsTableColumns.column(.checked)
        XCTAssertFalse(spec.fixed, "钉死就拖不动了")
        XCTAssertFalse(spec.sortable)
        XCTAssertFalse(spec.resizable)
        XCTAssertEqual(spec.icon, "checkmark", "列头是一枚 ✓")
        XCTAssertEqual(spec.defaultWidth, spec.minWidth, "定宽列，两头同一个数")

        var columns = SongsTableColumns()
        columns.showsCheckboxes = true
        let visible = columns.visible
        let index = visible.firstIndex { $0.key == .checked }!
        // 往右拖：右边全是可移动的列，准。
        XCTAssertTrue(SongsTableColumns.canReorder(visible: visible, from: index, to: index + 2))
        // 往左拖会跨过固定的标题列，按 Music 的区间规则不准。
        XCTAssertFalse(SongsTableColumns.canReorder(visible: visible, from: index, to: 0))
        // 显隐只听应用级偏好，右键菜单那条路碰不到它。
        columns.toggleVisible(.checked)
        XCTAssertTrue(columns.visible.contains { $0.key == .checked })
    }

    /// 旧存档里勾选列排在标题之前（那时它是钉在最左的固定列）。
    /// 读回来要搬到出厂位，否则它看着还是钉死的。
    func testLegacyPinnedOrderIsMigrated() {
        var keys = SongsTableColumns.Key.allCases.filter { $0 != .checked }.map(\.rawValue)
        keys.insert(SongsTableColumns.Key.checked.rawValue, at: 0)
        let archive: [String: Any] = [
            "widths": [String: CGFloat](),
            "hidden": [String](),
            "order": keys,
            "known": SongsTableColumns.Key.allCases.map(\.rawValue),
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: archive),
                          as: UTF8.self)

        var stale = SongsTableColumns()
        stale.showsCheckboxes = true
        stale.decode(json)
        let visible = stale.visible.map(\.key)
        XCTAssertNotEqual(visible.first, .checked, "旧存档的钉死位置没被搬走")
        XCTAssertEqual(visible.firstIndex(of: .checked).map { $0 + 1 },
                       visible.firstIndex(of: .cloud))
    }

    /// 开关是从 `AppSettings` 镜像进来的，改了要转成列变化（表格靠列前后相等与否重建）。
    func testSettingsMirrorsCheckboxSwitch() async {
        let suite = "SongCheckboxTests.mirror"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        AppSettings.shared.values.songListCheckboxes = false

        let settings = SongsTableSettings(defaults: defaults)
        XCTAssertFalse(settings.columns.showsCheckboxes)

        AppSettings.shared.values.songListCheckboxes = true
        await settleObservations()
        XCTAssertTrue(settings.columns.showsCheckboxes)
        XCTAssertTrue(settings.columns.visible.contains { $0.key == .checked })

        // 出厂就开着时 init 也要镜像到
        let fresh = SongsTableSettings(defaults: defaults)
        XCTAssertTrue(fresh.columns.showsCheckboxes)
    }

    // MARK: - 播放时跳过

    /// 顺播：没勾的直接跳过去。
    func testLinearSkipsUncheckedTracks() {
        let unchecked: Set<Int> = [1, 2]
        let step = PlayerController.nextStep(
            count: 5, currentIndex: 0, isShuffled: false, shuffleOrder: [], shuffleCursor: 0,
            repeatMode: .off, isChecked: { !unchecked.contains($0) })
        XCTAssertEqual(step, .play(index: 3, reshuffle: false))
    }

    /// 后面全是没勾的：与「队列到头」同解——不循环就停。
    func testLinearStopsWhenRestIsUnchecked() {
        let step = PlayerController.nextStep(
            count: 4, currentIndex: 1, isShuffled: false, shuffleOrder: [], shuffleCursor: 0,
            repeatMode: .off, isChecked: { $0 <= 1 })
        XCTAssertEqual(step, .stop)
    }

    /// 循环全部：绕回队首继续找，仍旧只找到当前这一首为止。
    func testLinearWrapsToCheckedTrackWithRepeatAll() {
        let step = PlayerController.nextStep(
            count: 4, currentIndex: 2, isShuffled: false, shuffleOrder: [], shuffleCursor: 0,
            repeatMode: .all, isChecked: { $0 == 1 })
        XCTAssertEqual(step, .play(index: 1, reshuffle: false))
    }

    /// 一首都没勾：循环全部也得停，不然会在队列里空转。
    func testAllUncheckedStopsEvenWithRepeatAll() {
        for shuffled in [false, true] {
            let step = PlayerController.nextStep(
                count: 3, currentIndex: 0, isShuffled: shuffled,
                shuffleOrder: shuffled ? [0, 1, 2] : [], shuffleCursor: 0,
                repeatMode: .all, isChecked: { _ in false })
            XCTAssertEqual(step, .stop, shuffled ? "随机" : "顺播")
        }
    }

    /// 随机序：按洗好的次序往后找第一个勾着的。
    func testShuffleSkipsUncheckedTracks() {
        let step = PlayerController.nextStep(
            count: 4, currentIndex: 3, isShuffled: true, shuffleOrder: [3, 1, 0, 2],
            shuffleCursor: 0, repeatMode: .off, isChecked: { $0 != 1 })
        XCTAssertEqual(step, .play(index: 0, reshuffle: false))
    }

    /// 随机序走到头：没勾的不算「还有下一首」，照旧按循环模式决定重洗还是停。
    func testShuffleWrapStillNeedsReshuffle() {
        let step = PlayerController.nextStep(
            count: 3, currentIndex: 2, isShuffled: true, shuffleOrder: [2, 0, 1],
            shuffleCursor: 0, repeatMode: .all, isChecked: { $0 == 2 })
        XCTAssertEqual(step, .play(index: -1, reshuffle: true))
    }

    /// 不给 `isChecked` 时行为与没有这条开关时逐字一致。
    func testDefaultIsCheckedKeepsOldBehaviour() {
        XCTAssertEqual(
            PlayerController.nextStep(count: 3, currentIndex: 0, isShuffled: false,
                                      shuffleOrder: [], shuffleCursor: 0, repeatMode: .off),
            .play(index: 1, reshuffle: false))
    }

    // MARK: - 与播放器一致

    private func makePlayer() -> PlayerController {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        return player
    }

    /// 自动连播跳过没勾的；随机游标也要跟着跳过的那几首一起推，
    /// 不然下一次判断会从错的位置起算。
    func testAutomaticAdvanceSkipsUnchecked() {
        let player = makePlayer()
        let tracks = makeTracks(4)
        let unchecked: Set<String> = [tracks[1].id, tracks[2].id]
        player.isTrackChecked = { !unchecked.contains($0.id) }
        player.play(tracks)
        XCTAssertEqual(player.currentIndex, 0)

        player.next(userInitiated: false)
        XCTAssertEqual(player.currentIndex, 3, "中间两首没勾，自动连播该直接跳到第 4 首")
        player.next(userInitiated: false)
        XCTAssertEqual(player.nextStep(skippingUnchecked: true), .stop)
    }

    /// 用户主动按下一首不认那个勾（Music 语义：双击/下一首照放）。
    func testManualNextIgnoresCheckState() {
        let player = makePlayer()
        let tracks = makeTracks(3)
        player.isTrackChecked = { _ in false }
        player.play(tracks)
        player.next(userInitiated: true)
        XCTAssertEqual(player.currentIndex, 1)
    }

    /// 随机序里跳过之后，游标要落在**真正播的那一首**上。
    ///
    /// 游标要是照旧只 `+= 1`，它会停在被跳过的那一首上，下一次判断从错的位置起算：
    /// 于是刚播过的那首会被再挑一次。这里只留两首勾着，两跳必须是**不同的两首**，
    /// 第三跳到头。
    func testShuffleCursorFollowsSkips() {
        let player = makePlayer()
        let tracks = makeTracks(8)
        let checked: Set<String> = [tracks[2].id, tracks[5].id]
        player.isTrackChecked = { checked.contains($0.id) }
        player.play(tracks)
        player.toggleShuffle()

        player.next(userInitiated: false)
        guard let first = player.currentIndex else { return XCTFail("第一跳没落位") }
        XCTAssertTrue([2, 5].contains(first), "跳到了没勾的那一首")

        player.next(userInitiated: false)
        guard let second = player.currentIndex else { return XCTFail("第二跳没落位") }
        XCTAssertNotEqual(second, first, "游标没跟着跳过的那几首推，刚播过的又被挑了一次")
        XCTAssertTrue([2, 5].contains(second))

        XCTAssertEqual(player.nextStep(skippingUnchecked: true), .stop, "两首都放过了")
    }
}
