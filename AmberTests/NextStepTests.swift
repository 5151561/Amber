import XCTest
@testable import Amber

/// `nextStep()` 是从 `next()` 里抽出来的纯判断，预取与真正切歌共用它。
/// 这里验两件事：纯函数本身的取值，以及它和 `next()` 走到的地方一致。
final class NextStepTests: XCTestCase {

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

    // MARK: 纯函数

    func testLinearOrder() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 0, isShuffled: false,
                                             shuffleOrder: [], shuffleCursor: 0, repeatMode: .off)
        XCTAssertEqual(step, .play(index: 1, reshuffle: false))
    }

    func testLinearEndStopsWithoutRepeat() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 2, isShuffled: false,
                                             shuffleOrder: [], shuffleCursor: 0, repeatMode: .off)
        XCTAssertEqual(step, .stop)
    }

    func testLinearEndWrapsWithRepeatAll() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 2, isShuffled: false,
                                             shuffleOrder: [], shuffleCursor: 0, repeatMode: .all)
        XCTAssertEqual(step, .play(index: 0, reshuffle: false))
    }

    func testShuffleFollowsOrder() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 2, isShuffled: true,
                                             shuffleOrder: [2, 0, 1], shuffleCursor: 0,
                                             repeatMode: .off)
        XCTAssertEqual(step, .play(index: 0, reshuffle: false))
    }

    /// 随机序整体到头 + 循环全部：要重洗一遍才知道是哪一首，所以不能预取。
    func testShuffleWrapNeedsReshuffle() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 1, isShuffled: true,
                                             shuffleOrder: [2, 0, 1], shuffleCursor: 2,
                                             repeatMode: .all)
        XCTAssertEqual(step, .play(index: -1, reshuffle: true))
    }

    func testShuffleWrapStopsWithoutRepeat() {
        let step = PlayerController.nextStep(count: 3, currentIndex: 1, isShuffled: true,
                                             shuffleOrder: [2, 0, 1], shuffleCursor: 2,
                                             repeatMode: .off)
        XCTAssertEqual(step, .stop)
    }

    func testEmptyQueueStops() {
        let step = PlayerController.nextStep(count: 0, currentIndex: nil, isShuffled: false,
                                             shuffleOrder: [], shuffleCursor: 0, repeatMode: .all)
        XCTAssertEqual(step, .stop)
    }

    // MARK: 与 next() 一致

    @MainActor
    func testMatchesNextInLinearOrder() {
        let player = makePlayer()
        player.play(makeTracks(4))
        for _ in 0..<3 {
            guard case .play(let index, false) = player.nextStep() else {
                return XCTFail("顺播中途不该 stop")
            }
            player.next(userInitiated: false)
            XCTAssertEqual(player.currentIndex, index)
        }
        XCTAssertEqual(player.nextStep(), .stop, "最后一首之后就到头了")
    }

    @MainActor
    func testMatchesNextWithRepeatAll() {
        let player = makePlayer()
        player.play(makeTracks(2))
        player.repeatMode = .all
        player.next(userInitiated: false)
        XCTAssertEqual(player.nextStep(), .play(index: 0, reshuffle: false))
        player.next(userInitiated: false)
        XCTAssertEqual(player.currentIndex, 0)
    }

    @MainActor
    func testMatchesNextWhenShuffled() {
        let player = makePlayer()
        player.play(makeTracks(6))
        player.toggleShuffle()
        for _ in 0..<5 {
            guard case .play(let index, false) = player.nextStep() else {
                return XCTFail("随机序没走完就 stop 了")
            }
            player.next(userInitiated: false)
            XCTAssertEqual(player.currentIndex, index)
        }
        XCTAssertEqual(player.nextStep(), .stop)
    }
}
