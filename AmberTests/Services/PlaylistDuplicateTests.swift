import XCTest
@testable import Amber

/// 加入播放列表撞重的判定（spec §10.4 第二条链，res 9008 idx 36/37/38 `[RES]`）。
///
/// 只测**不需要弹窗**的那一半：谁算重复、「跳过」那一支最终加哪些。
/// 真起 `NSAlert` 的那半截不进测试——模态窗在 `xcodebuild test` 里是会挂住的
///（与 `ImportReplaceTests` 同一条）。
final class PlaylistDuplicateTests: XCTestCase {

    private func makeTrack(_ id: String) -> Track {
        Track(id: id, kind: .qq, title: "曲 \(id)", artistName: "某人", artistId: nil,
              albumName: "某碟", albumId: "album", artworkURL: nil, duration: 200)
    }

    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id) }

    // MARK: - 不撞就不问

    /// 一条都不重复：两支结果一模一样，`hasDuplicates` 为 false ——界面据此**一句不问**直接加。
    func testNoOverlapAsksNothing() {
        let plan = PlaylistDuplicatePlan.plan(adding: [makeTrack("qq:a"), makeTrack("qq:b")],
                                              existing: [makeTrack("qq:x")])
        XCTAssertFalse(plan.hasDuplicates)
        XCTAssertEqual(plan.duplicateCount, 0)
        XCTAssertEqual(ids(plan.skippingDuplicates), ["qq:a", "qq:b"])
        XCTAssertEqual(ids(plan.addingAll), ids(plan.skippingDuplicates))
    }

    /// 空列表：谁也撞不着。
    func testEmptyPlaylistNeverCollides() {
        let plan = PlaylistDuplicatePlan.plan(adding: [makeTrack("qq:a")], existing: [])
        XCTAssertFalse(plan.hasDuplicates)
    }

    // MARK: - 部分重复

    /// 撞了一条：「跳过」只把那一条剔掉，其余照加，**顺序不变**；
    /// 「添加」那一支原样全加（`LibraryStore.addTracks` 本来的行为）。
    func testPartialOverlapSkipsOnlyTheCollidingOnes() {
        let plan = PlaylistDuplicatePlan.plan(
            adding: [makeTrack("qq:a"), makeTrack("qq:b"), makeTrack("qq:c")],
            existing: [makeTrack("qq:b")])
        XCTAssertTrue(plan.hasDuplicates)
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(ids(plan.skippingDuplicates), ["qq:a", "qq:c"])
        XCTAssertEqual(ids(plan.addingAll), ["qq:a", "qq:b", "qq:c"])
    }

    /// 判据是 `Track.id` 不是曲名：同名不同源（`ne:` / `qq:`）是两首歌，各占各的行。
    /// 与 §10.3「显示重复项目」那一档（按字段比、只过滤显示）不是一回事。
    func testIdentityIsTrackIdNotTitle() {
        func sameSong(_ id: String, _ kind: ProviderKind) -> Track {
            Track(id: id, kind: kind, title: "Emily", artistName: "某人", artistId: nil,
                  albumName: "某碟", albumId: "album", artworkURL: nil, duration: 200)
        }
        let plan = PlaylistDuplicatePlan.plan(adding: [sameSong("qq:1", .qq)],
                                              existing: [sameSong("ne:1", .netease)])
        XCTAssertFalse(plan.hasDuplicates)
    }

    // MARK: - 全部重复

    /// 整批都已经在列表里：「跳过」一条也不加（界面据此不报「已加入」），
    /// 「添加」那一支仍然是整批——Music 允许同一首在一份列表里出现多次。
    func testFullOverlapSkipsEverything() {
        let tracks = [makeTrack("qq:a"), makeTrack("qq:b")]
        let plan = PlaylistDuplicatePlan.plan(adding: tracks, existing: tracks)
        XCTAssertTrue(plan.hasDuplicates)
        XCTAssertEqual(plan.duplicateCount, 2)
        XCTAssertTrue(plan.skippingDuplicates.isEmpty)
        XCTAssertEqual(ids(plan.addingAll), ["qq:a", "qq:b"])
    }

    // MARK: - 批内自己重复（`[推]`）

    /// 同一批里同一个 id 出现两次，列表里原本没有：**算重复**，只留第一份。
    /// `[推]`：spec 没有证据，这里按「一首一首往列表里放」的模型定
    ///（第一份落进去之后，后面那份就是列表里已有那首的重复）。
    func testWithinBatchRepeatCountsAsDuplicate() {
        let plan = PlaylistDuplicatePlan.plan(
            adding: [makeTrack("qq:a"), makeTrack("qq:a"), makeTrack("qq:b")],
            existing: [])
        XCTAssertTrue(plan.hasDuplicates)
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(ids(plan.skippingDuplicates), ["qq:a", "qq:b"])
    }

    /// 批内重复 + 与列表原有重复同时发生：两种都剔，剩下的仍保持原顺序。
    func testWithinBatchAndExistingCollisionsBothSkipped() {
        let plan = PlaylistDuplicatePlan.plan(
            adding: [makeTrack("qq:a"), makeTrack("qq:b"), makeTrack("qq:a"), makeTrack("qq:c")],
            existing: [makeTrack("qq:b")])
        XCTAssertEqual(plan.duplicateCount, 2)
        XCTAssertEqual(ids(plan.skippingDuplicates), ["qq:a", "qq:c"])
    }

    /// 列表里原本就有重复项（用户此前选过「添加」）不会把这次的判定带偏：
    /// 判的是「这次要加的这些在不在里面」，不是去给列表做体检。
    func testExistingDuplicatesInPlaylistDoNotInflateCount() {
        let plan = PlaylistDuplicatePlan.plan(
            adding: [makeTrack("qq:a"), makeTrack("qq:z")],
            existing: [makeTrack("qq:a"), makeTrack("qq:a")])
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(ids(plan.skippingDuplicates), ["qq:z"])
    }
}
