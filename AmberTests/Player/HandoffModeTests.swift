import XCTest
@testable import Amber

/// 两首之间怎么接：关掉过渡与单曲循环走老路，同专辑无缝，其余交叉淡入淡出。
final class HandoffModeTests: XCTestCase {

    private func track(_ id: String, album: String?, kind: ProviderKind = .qq) -> Track {
        Track(id: id, kind: kind, title: id, artistName: "艺人", artistId: nil,
              albumName: album ?? "", albumId: album, artworkURL: nil, duration: 200)
    }

    func testCrossfadeOffKeepsOldPath() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: "A"), to: track("b", album: "B"),
            duration: 200, repeatMode: .off, crossfadeEnabled: false)
        XCTAssertEqual(mode, .none)
    }

    func testRepeatOneNeverCrossfades() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: "A"), to: track("b", album: "B"),
            duration: 200, repeatMode: .one, crossfadeEnabled: true)
        XCTAssertEqual(mode, .none)
    }

    /// Music：同一张专辑内的歌曲之间不做过渡。
    func testSameAlbumIsGapless() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: "A"), to: track("b", album: "A"),
            duration: 200, repeatMode: .off, crossfadeEnabled: true)
        XCTAssertEqual(mode, .gapless)
    }

    /// 专辑 id 一样但音源不同，那就不是同一张专辑。
    func testSameAlbumIDAcrossProvidersIsNotGapless() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: "A", kind: .qq), to: track("b", album: "A", kind: .netease),
            duration: 200, repeatMode: .off, crossfadeEnabled: true)
        XCTAssertEqual(mode, .crossfade(seconds: 6))
    }

    func testMissingAlbumFallsBackToCrossfade() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: nil), to: track("b", album: nil),
            duration: 200, repeatMode: .off, crossfadeEnabled: true)
        XCTAssertEqual(mode, .crossfade(seconds: 6))
    }

    func testShortTrackIsNotCrossfaded() {
        let mode = PlayerController.handoffMode(
            from: track("a", album: "A"), to: track("b", album: "B"),
            duration: 8, repeatMode: .off, crossfadeEnabled: true)
        XCTAssertEqual(mode, .none)
    }
}
