import XCTest
@testable import Amber

/// 播放记账（播放次数 / 跳过次数 / 最近播放）与「从列表播放」的口径。
///
/// 不真起播：`handleTrackEnded()` 是内部方法，直接调它就能验证结尾那一刻的记账。
/// 取流器给一个永远挂着的实现，队列状态在测试期间不会被失败跳转搅动。
final class PlaybackAccountingTests: XCTestCase {

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

    /// 一首放到结尾：记一次「播完」，**不**记跳过，然后才切下一首。
    @MainActor
    func testTrackEndedCountsPlayAndAdvances() {
        let player = makePlayer()
        let tracks = makeTracks(3)
        var played: [String] = []
        var skipped: [String] = []
        player.onTrackPlayed = { played.append($0.id) }
        player.onSkip = { skipped.append($0.id) }

        player.play(tracks)
        player.handleTrackEnded()

        XCTAssertEqual(played, ["test:0"])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(player.currentIndex, 1)
    }

    /// 单曲循环每绕一遍都算一次播放（Music：循环放十遍，播放次数加十）。
    @MainActor
    func testRepeatOneCountsEveryLoop() {
        let player = makePlayer()
        var played: [String] = []
        player.onTrackPlayed = { played.append($0.id) }

        player.play(makeTracks(2))
        player.repeatMode = .one
        player.handleTrackEnded()
        player.handleTrackEnded()

        XCTAssertEqual(played, ["test:0", "test:0"])
        XCTAssertEqual(player.currentIndex, 0, "单曲循环不该切歌")
    }

    /// 跳过只在「播了 2 秒以上、20 秒以内」这个窗口里记。
    @MainActor
    func testSkipOnlyInsideWindow() {
        let cases: [(TimeInterval, Bool)] = [(0.5, false), (2.5, true), (19.9, true), (45, false)]
        for (elapsed, expected) in cases {
            let player = makePlayer()
            var skipped: [String] = []
            player.onSkip = { skipped.append($0.id) }
            player.play(makeTracks(3))
            player.currentTime = elapsed

            player.next()

            XCTAssertEqual(!skipped.isEmpty, expected, "播了 \(elapsed) 秒切走")
        }
    }

    /// 自动连播（播完接下一首）不算跳过。
    @MainActor
    func testAutoAdvanceIsNotASkip() {
        let player = makePlayer()
        var skipped: [String] = []
        player.onSkip = { skipped.append($0.id) }
        player.play(makeTracks(3))
        player.currentTime = 5

        player.next(userInitiated: false)

        XCTAssertTrue(skipped.isEmpty)
    }

    /// 随机开着时从列表里挑一首播：先放这首，开关**不动**
    /// （从前 `play(_:startAt:)` 一进来就把随机关掉了）。
    @MainActor
    func testPlayFromListKeepsShuffleOn() {
        let player = makePlayer()
        player.play(makeTracks(5))
        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)

        player.play(makeTracks(5), startAt: 3)

        XCTAssertTrue(player.isShuffled, "双击列表某一行不该把随机开关关掉")
        XCTAssertEqual(player.currentIndex, 3, "随机开着也要先放点中的那一首")
    }

    /// 「从列表播放」的上下文就是「整份行 + 起播下标」，播出来的队列是整份列表。
    @MainActor
    func testPlayContextQueuesWholeList() {
        let player = makePlayer()
        let tracks = makeTracks(4)
        let context = TrackPlayContext(tracks: tracks, index: 2)

        player.play(context.tracks, startAt: context.index)

        XCTAssertEqual(player.queue.count, 4)
        XCTAssertEqual(player.currentTrack?.id, "test:2")
    }
}
