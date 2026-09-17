import XCTest
@testable import Amber

/// 队列面板（[实测] playqueue spec §2 `ITPlayQueueModel`）的模型层。
///
/// 只测两样东西，都不需要起 App、不碰 `AppSettings.shared`、不触网：
/// 1. `PlayQueueModel.sections(queue:origins:currentIndex:)` 这个纯函数的分区推导；
/// 2. `PlayerController` 的队列变换（插入 / 移除 / 重排 / 清除）——口径同`NextStepTests`，
///    `providerResolver` 挂一个永远不返回的桩，全程不会真去取流。
final class PlayQueueModelTests: XCTestCase {

    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map {
            Track(id: "test:\($0)", kind: .qq, title: "歌 \($0)", artistName: "艺人",
                  artistId: nil, albumName: "", albumId: nil, artworkURL: nil, duration: 200)
        }
    }

    @MainActor
    private func makePlayer() -> PlayerController {
        let player = PlayerController()
        player.providerResolver = { _ in
            try await Task.sleep(for: .seconds(600))
            throw ProviderError.api("测试不取流")
        }
        return player
    }

    /// 硬不变式：`queueOrigins` 与`queue` 恒等长。
    @MainActor
    private func assertOriginsAligned(_ player: PlayerController,
                                      _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(player.queueOrigins.count, player.queue.count, message,
                       file: file, line: line)
    }

    // MARK: 1. queueOrigins 与 queue 长度恒等

    @MainActor
    func testOriginsStayAlignedThroughEveryMutation() {
        let player = makePlayer()
        let tracks = makeTracks(6)
        player.play(tracks, startAt: 1)
        assertOriginsAligned(player, "起播之后")
        XCTAssertEqual(player.queueOrigins, .init(repeating: .source, count: 6),
                       "新起播的整份列表都算「继续播放」")

        player.playNext(makeTracks(2).map { rename($0, "next") })
        assertOriginsAligned(player, "playNext 之后")

        player.playLast(makeTracks(2).map { rename($0, "last") })
        assertOriginsAligned(player, "playLast 之后")

        player.removeFromQueue(at: IndexSet([0, 3]))
        assertOriginsAligned(player, "removeFromQueue 之后")

        player.moveInQueue(IndexSet([1]), to: 4)
        assertOriginsAligned(player, "moveInQueue 之后")

        player.insertIntoQueue(makeTracks(1).map { rename($0, "drop") }, at: 2)
        assertOriginsAligned(player, "insertIntoQueue 之后")

        player.clearContinuePlaying()
        assertOriginsAligned(player, "clearContinuePlaying 之后")

        player.stop()
        assertOriginsAligned(player, "stop 之后")
        XCTAssertTrue(player.queueOrigins.isEmpty)
        XCTAssertNil(player.queueSource)
    }

    private func rename(_ track: Track, _ tag: String) -> Track {
        Track(id: "\(tag):\(track.id)", kind: track.kind, title: track.title,
              artistName: track.artistName, artistId: nil, albumName: "", albumId: nil,
              artworkURL: nil, duration: track.duration)
    }

    // MARK: 2. playLast 落到 Up Next 分区的末尾

    /// [实测] playqueue spec §2.1 + §3.4：手动加的项永远排在「继续播放」之前。
    /// 当前曲之后已经有两个 `.manual` 时，新的一批要插在这两个之后、`.source` 之前。
    @MainActor
    func testPlayLastLandsAtEndOfUpNextNotEndOfQueue() {
        let player = makePlayer()
        player.play(makeTracks(4), startAt: 0)
        player.playNext([rename(makeTracks(1)[0], "m1")])
        player.playNext([rename(makeTracks(1)[0], "m0")])   // 插在最前 → 顺序 m0, m1
        XCTAssertEqual(player.queue.map(\.id),
                       ["test:0", "m0:test:0", "m1:test:0", "test:1", "test:2", "test:3"])

        player.playLast([rename(makeTracks(1)[0], "l0")])
        XCTAssertEqual(player.queue.map(\.id),
                       ["test:0", "m0:test:0", "m1:test:0", "l0:test:0",
                        "test:1", "test:2", "test:3"],
                       "应插在那串手动项之后、「继续播放」之前，而不是整队队尾")
        XCTAssertEqual(player.queueOrigins,
                       [.source, .manual, .manual, .manual, .source, .source, .source])

        // 不变式：currentIndex 之后先是一串 .manual，再是 .source / .autoplay。
        assertUpNextRunComesFirst(player)
    }

    @MainActor
    private func assertUpNextRunComesFirst(_ player: PlayerController,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let current = player.currentIndex else { return }
        var sawNonManual = false
        for index in (current + 1)..<player.queueOrigins.count {
            if player.queueOrigins[index] == .manual {
                XCTAssertFalse(sawNonManual, "第 \(index) 项的 .manual 排到了 .source 后面",
                               file: file, line: line)
            } else {
                sawNonManual = true
            }
        }
    }

    /// 队列空时 `playLast` 退化成直接播这一批（老行为不变）。
    @MainActor
    func testPlayLastOnEmptyQueuePlaysImmediately() {
        let player = makePlayer()
        player.playLast(makeTracks(3))
        XCTAssertEqual(player.queue.count, 3)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.queueOrigins, .init(repeating: .source, count: 3))
    }

    // MARK: 3. 分区推导

    @MainActor
    func testSectionsSplitByPositionThenOrigin() {
        let tracks = makeTracks(6)
        let origins: [PlayerController.QueueOrigin] =
            [.source, .manual, .source, .manual, .source, .autoplay]
        let sections = PlayQueueModel.sections(queue: tracks, origins: origins, currentIndex: 2)

        // 历史＝当前曲之前的项，与来源无关（手动加的项播过去了照样落进历史）。
        XCTAssertEqual(sections.history.map(\.queueIndex), [0, 1])
        // 当前曲（下标 2，origin .source）留在它原本的分区里 —— [推]，见 sections 的注释。
        XCTAssertEqual(sections.continuePlaying.map(\.queueIndex), [2, 4])
        XCTAssertEqual(sections.upNext.map(\.queueIndex), [3])
        XCTAssertEqual(sections.autoplay.map(\.queueIndex), [5])

        // 每一项都带着自己所属的分区。
        XCTAssertTrue(sections.history.allSatisfy { $0.section == .history })
        XCTAssertTrue(sections.upNext.allSatisfy { $0.section == .upNext })
        XCTAssertTrue(sections.continuePlaying.allSatisfy { $0.section == .continuePlaying })
        XCTAssertTrue(sections.autoplay.allSatisfy { $0.section == .autoplay })
    }

    /// [实测] §3.4：空数组的分区不进快照。这里验模型这一侧确实给的是空数组。
    @MainActor
    func testEmptySectionsStayEmpty() {
        let tracks = makeTracks(3)
        let sections = PlayQueueModel.sections(
            queue: tracks, origins: .init(repeating: .source, count: 3), currentIndex: 0)
        XCTAssertTrue(sections.history.isEmpty, "当前曲是第一首，没有历史")
        XCTAssertTrue(sections.upNext.isEmpty, "一项手动加的都没有")
        XCTAssertTrue(sections.autoplay.isEmpty, "Amber 不产出自动播放项")
        XCTAssertEqual(sections.continuePlaying.count, 3)
    }

    @MainActor
    func testEmptyQueueYieldsFourEmptySections() {
        let sections = PlayQueueModel.sections(queue: [], origins: [], currentIndex: nil)
        XCTAssertEqual(sections, PlayQueueModel.Sections())
    }

    /// [实测] §1.1：同一首歌在队列里出现两次要是两个不同的 identifier。
    @MainActor
    func testIdentifiersAreUniquePerRepeatedTrack() {
        let track = makeTracks(1)[0]
        let sections = PlayQueueModel.sections(queue: [track, track],
                                               origins: [.source, .source], currentIndex: 0)
        let ids = sections.continuePlaying.map(\.identifier)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(ids, ["test:0:0", "test:0:1"], "曲目 id:第几次出现")
    }

    /// identifier 里**不带队列下标**：同一首歌在不同下标上，只要「第几次出现」一样，
    /// identifier 就一样。这是下面两条 diff 稳定性断言的前提。
    @MainActor
    func testIdentifierDoesNotCarryQueueIndex() {
        let tracks = makeTracks(3)
        let ids = Self.allIdentifiers(of: tracks, currentIndex: 0)
        XCTAssertEqual(ids, ["test:0:0", "test:1:0", "test:2:0"],
                       "三首各自都是第 0 次出现，下标 0/1/2 不该出现在 identifier 里")
    }

    /// 每一项的 identifier，按队列顺序摊平成一个数组（四个分区拼回下标序）。
    @MainActor
    private static func allIdentifiers(of queue: [Track],
                                       origins: [PlayerController.QueueOrigin]? = nil,
                                       currentIndex: Int?) -> [String] {
        let origins = origins ?? .init(repeating: .source, count: queue.count)
        let sections = PlayQueueModel.sections(queue: queue, origins: origins,
                                               currentIndex: currentIndex)
        let all = sections.history + sections.upNext
            + sections.continuePlaying + sections.autoplay
        return all.sorted { $0.queueIndex < $1.queueIndex }.map(\.identifier)
    }

    /// **这次订正的要点**：往队列中间插一项，未被改动的那些项 identifier 必须原样不动。
    ///
    /// 面板是 `NSTableViewDiffableDataSource`，identifier 就是 diff 的身份。要是把队列下标
    /// 编进 identifier，插入点之后每一项的身份都会变，diff 会判成「整批删掉再整批插入」
    /// （表现是插一首歌整个下半张表重刷），而不是一次移动/插入。
    @MainActor
    func testInsertingInTheMiddleKeepsOtherIdentifiersStable() {
        let tracks = makeTracks(5)
        let before = Self.allIdentifiers(of: tracks, currentIndex: 0)

        let inserted = rename(makeTracks(1)[0], "next")   // 「稍后播放」插进下标 2
        var after = tracks
        after.insert(inserted, at: 2)
        var origins: [PlayerController.QueueOrigin] = .init(repeating: .source, count: 5)
        origins.insert(.manual, at: 2)
        let afterIDs = Self.allIdentifiers(of: after, origins: origins, currentIndex: 0)

        XCTAssertEqual(afterIDs.count, before.count + 1)
        XCTAssertEqual(Array(afterIDs[0..<2]), Array(before[0..<2]), "插入点之前原样不动")
        XCTAssertEqual(afterIDs[2], "next:test:0:0", "新项自己的 identifier")
        XCTAssertEqual(Array(afterIDs[3...]), Array(before[2...]),
                       "插入点之后每一项的 identifier 也要原样不动 —— 下标不能进 identifier")
    }

    /// 删除一项后同理：其余项的 identifier 不变。
    @MainActor
    func testRemovingAnItemKeepsOtherIdentifiersStable() {
        let tracks = makeTracks(5)
        let before = Self.allIdentifiers(of: tracks, currentIndex: 0)

        var after = tracks
        after.remove(at: 2)
        let afterIDs = Self.allIdentifiers(of: after, currentIndex: 0)

        XCTAssertEqual(afterIDs, [before[0], before[1], before[3], before[4]],
                       "删掉的那一项之外，identifier 全都原样不动")
    }

    /// 同一首歌重复出现时，删掉靠前的那一次会让后面那次的「第几次出现」前移 ——
    /// 这是 occurrence 方案已知的代价（受影响的只有同名曲目，不是整条队列尾巴）。
    @MainActor
    func testRemovingAnEarlierOccurrenceRenumbersOnlySameTrack() {
        let dup = makeTracks(1)[0]
        let other = rename(makeTracks(1)[0], "x")
        let before = Self.allIdentifiers(of: [dup, other, dup], currentIndex: 0)
        XCTAssertEqual(before, ["test:0:0", "x:test:0:0", "test:0:1"])

        let after = Self.allIdentifiers(of: [other, dup], currentIndex: 0)
        XCTAssertEqual(after, ["x:test:0:0", "test:0:0"],
                       "别的曲目不受影响；同名那首从第 1 次出现变回第 0 次")
    }

    // MARK: 4. removeFromQueue 之后 currentIndex 跟着搬

    @MainActor
    func testRemoveBeforeCurrentShiftsCurrentIndex() {
        let player = makePlayer()
        player.play(makeTracks(5), startAt: 3)
        player.removeFromQueue(at: IndexSet([0, 1]))
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.queue.map(\.id), ["test:2", "test:3", "test:4"])
    }

    @MainActor
    func testRemoveAfterCurrentKeepsCurrentIndex() {
        let player = makePlayer()
        player.play(makeTracks(5), startAt: 1)
        player.removeFromQueue(at: IndexSet([3, 4]))
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.queue.map(\.id), ["test:0", "test:1", "test:2"])
    }

    /// 删的就是正在播的那首 → 跳到下一首活着的项（`[推]`，见`removeFromQueue` 的注释）。
    @MainActor
    func testRemovingCurrentJumpsToNextSurvivor() {
        let player = makePlayer()
        player.play(makeTracks(5), startAt: 2)
        player.removeFromQueue(at: IndexSet([2, 3]))
        XCTAssertEqual(player.queue.map(\.id), ["test:0", "test:1", "test:4"])
        XCTAssertEqual(player.currentIndex, 2, "原 test:4 搬到下标 2，接着播它")
    }

    /// 当前曲连同它后面的项一起被删光：收掉播放器，前面的历史留着。
    @MainActor
    func testRemovingCurrentAndEverythingAfterHalts() {
        let player = makePlayer()
        player.play(makeTracks(4), startAt: 2)
        player.removeFromQueue(at: IndexSet([2, 3]))
        XCTAssertEqual(player.queue.map(\.id), ["test:0", "test:1"])
        XCTAssertNil(player.currentIndex)
        XCTAssertFalse(player.isPlaying)
    }

    /// 队列外的下标一律忽略，不该动到任何东西。
    @MainActor
    func testRemoveOutOfRangeIsNoop() {
        let player = makePlayer()
        player.play(makeTracks(3), startAt: 1)
        player.removeFromQueue(at: IndexSet([7, 9]))
        XCTAssertEqual(player.queue.count, 3)
        XCTAssertEqual(player.currentIndex, 1)
    }

    // MARK: 4b. moveInQueue 搬 currentIndex

    @MainActor
    func testMoveCarriesCurrentIndex() {
        let player = makePlayer()
        player.play(makeTracks(5), startAt: 1)
        // 把当前曲（下标 1）挪到最后
        player.moveInQueue(IndexSet([1]), to: 5)
        XCTAssertEqual(player.queue.map(\.id), ["test:0", "test:2", "test:3", "test:4", "test:1"])
        XCTAssertEqual(player.currentIndex, 4)
        XCTAssertEqual(player.currentTrack?.id, "test:1", "搬完还是同一首")
    }

    @MainActor
    func testMoveKeepsOriginsWithTheirTracks() {
        let player = makePlayer()
        player.play(makeTracks(3), startAt: 0)
        player.playNext([rename(makeTracks(1)[0], "m")])
        XCTAssertEqual(player.queueOrigins, [.source, .manual, .source, .source])
        // 把那一项手动加的挪到队尾：origin 要跟着它走
        player.moveInQueue(IndexSet([1]), to: 4)
        XCTAssertEqual(player.queue.map(\.id), ["test:0", "test:1", "test:2", "m:test:0"])
        XCTAssertEqual(player.queueOrigins, [.source, .source, .source, .manual])
    }

    // MARK: 5. clearContinuePlaying

    @MainActor
    func testClearContinuePlayingKeepsManualAndHistory() {
        let player = makePlayer()
        player.play(makeTracks(5), startAt: 2,
                    source: .init(title: "某歌单", route: nil))
        player.playNext([rename(makeTracks(1)[0], "m")])
        XCTAssertEqual(player.queue.map(\.id),
                       ["test:0", "test:1", "test:2", "m:test:0", "test:3", "test:4"])
        XCTAssertEqual(player.queueSource?.title, "某歌单")

        player.clearContinuePlaying()
        XCTAssertEqual(player.queue.map(\.id),
                       ["test:0", "test:1", "test:2", "m:test:0"],
                       "只清当前曲之后的 .source；历史与手动加的都不动")
        XCTAssertEqual(player.queueOrigins, [.source, .source, .source, .manual])
        XCTAssertEqual(player.currentIndex, 2, "当前曲不动")
        XCTAssertNil(player.queueSource, "「来自…」那行跟着清掉")
    }

    /// 清完之后「继续播放」分区就空了（面板据此不 append 那一段）。
    @MainActor
    func testClearContinuePlayingEmptiesTheSection() {
        let player = makePlayer()
        player.play(makeTracks(4), startAt: 0)
        player.playNext([rename(makeTracks(1)[0], "m")])
        player.clearContinuePlaying()
        let sections = PlayQueueModel.sections(queue: player.queue, origins: player.queueOrigins,
                                               currentIndex: player.currentIndex)
        XCTAssertEqual(sections.continuePlaying.map(\.queueIndex), [0],
                       "当前曲自己还留在这一段里")
        XCTAssertEqual(sections.upNext.map(\.track.id), ["m:test:0"])
        XCTAssertTrue(sections.history.isEmpty)
        XCTAssertTrue(sections.autoplay.isEmpty)
    }
}
