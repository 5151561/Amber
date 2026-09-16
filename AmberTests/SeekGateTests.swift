import AVFoundation
import XCTest
@testable import Amber

/// seek 落点门控：seek 发出到播放器真正落点之间，时间观察器报上来的还是
/// seek 之前采到的位置。认那几跳，进度条就会「先跳到目标点、往回闪一下、再跳回来」。
///
/// 这里只验 `PlaybackDeck` 自己的记账（发号、对号、清场），不碰真落点——
/// 真落点要真 item 与真解码，那是实机验收的事。
final class SeekGateTests: XCTestCase {

    private func makeTrack() -> Track {
        Track(id: "test:0", kind: .qq, title: "歌", artistName: "艺人",
              artistId: nil, albumName: "", albumId: nil, artworkURL: nil, duration: 200)
    }

    private func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 刚开局没发过 seek，门控不该开着。
    @MainActor
    func testIdleDeckHasNoPendingSeek() {
        let deck = PlaybackDeck()
        XCTAssertFalse(deck.isSeekPending)
        XCTAssertNil(deck.pendingSeekTarget)
    }

    /// 发出去就算未落点，目标点要记下来——门控期间界面显示的就是它。
    @MainActor
    func testSeekOpensGateAndRecordsTarget() {
        let deck = PlaybackDeck()
        deck.seek(to: time(120), tolerance: .zero)
        XCTAssertTrue(deck.isSeekPending)
        XCTAssertEqual(deck.pendingSeekTarget ?? -1, 120, accuracy: 0.001)
    }

    /// 最新那一号回来才清场。
    @MainActor
    func testLatestSeekClosesGate() {
        let deck = PlaybackDeck()
        let id = deck.seek(to: time(120), tolerance: .zero)
        deck.finishSeek(id)
        XCTAssertFalse(deck.isSeekPending)
        XCTAssertNil(deck.pendingSeekTarget)
    }

    /// 被后一次 seek 打断的那一号回来不清场——否则拖动过程中门控会被旧回调提前
    /// 关掉，落点前的 tick 又能把进度打回去。
    @MainActor
    func testSupersededSeekDoesNotCloseGate() {
        let deck = PlaybackDeck()
        let first = deck.seek(to: time(30), tolerance: .zero)
        let second = deck.seek(to: time(120), tolerance: .zero)
        XCTAssertNotEqual(first, second)

        deck.finishSeek(first)
        XCTAssertTrue(deck.isSeekPending, "旧号不该清场")
        XCTAssertEqual(deck.pendingSeekTarget ?? -1, 120, accuracy: 0.001, "目标点该是后一次的")

        deck.finishSeek(second)
        XCTAssertFalse(deck.isSeekPending)
    }

    /// 换 item 就撤门控：旧 item 的 seek 回调回不回来都不该影响新 item，
    /// 也堵死「回调万一不来 → 进度条永久停在目标点」。
    @MainActor
    func testUnloadClearsGate() {
        let deck = PlaybackDeck()
        deck.seek(to: time(120), tolerance: .zero)
        deck.unload()
        XCTAssertFalse(deck.isSeekPending)
        XCTAssertNil(deck.pendingSeekTarget)
    }

    @MainActor
    func testLoadClearsGate() {
        let deck = PlaybackDeck()
        deck.seek(to: time(120), tolerance: .zero)
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        deck.load(item: item, track: makeTrack())
        XCTAssertFalse(deck.isSeekPending)
        XCTAssertNil(deck.pendingSeekTarget)
    }
}
