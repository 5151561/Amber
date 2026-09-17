import XCTest
@testable import Amber

/// 专辑曲序（`sortedByAlbumOrder`）。
///
/// 起因：QQ 的 `GetAlbumSongList` 回的顺序不是曲序，专辑页跟原专辑对不上。
/// 样本是 [实测 2026-09-08 curl] 抓的真返回顺序，不是编的。
final class AlbumTrackOrderTests: XCTestCase {

    private func makeTrack(_ title: String, disc: Int? = nil, number: Int? = nil) -> Track {
        Track(id: "qq:\(title)", kind: .qq, title: title, artistName: "五月天",
              artistId: nil, albumName: "自传", albumId: "qq:002fRO0N4FftzY",
              artworkURL: nil, duration: 200, trackNumber: number, discNumber: disc)
    }

    /// 《自传》整张回来的 `index_album` 是 2,9,13,11,4,7,10,12,5,3,6,1,8。
    func testQQAlbumOrderIsRestored() {
        let received = [2, 9, 13, 11, 4, 7, 10, 12, 5, 3, 6, 1, 8]
        let sorted = received.map { makeTrack("第\($0)首", disc: 0, number: $0) }
            .sortedByAlbumOrder()
        XCTAssertEqual(sorted.map { $0.trackNumber }, Array(1...13))
    }

    /// 双碟（QQ 的 `index_cd` 从 0 起，`index_album` 跨碟连续）：先碟号后音轨号。
    func testMultiDiscOrdersByDiscThenTrack() {
        let sorted = [makeTrack("b", disc: 1, number: 25),
                      makeTrack("a", disc: 0, number: 3),
                      makeTrack("c", disc: 1, number: 14),
                      makeTrack("d", disc: 0, number: 1)].sortedByAlbumOrder()
        XCTAssertEqual(sorted.map(\.title), ["d", "a", "c", "b"])
    }

    /// 音源没给序号的（搜索接口来的曲目就没有）保持原有先后，并排在有序号的之后——
    /// 不按标题猜顺序。
    func testTracksWithoutNumbersKeepIncomingOrder() {
        let sorted = [makeTrack("无序二"),
                      makeTrack("有序", disc: 0, number: 4),
                      makeTrack("无序一")].sortedByAlbumOrder()
        XCTAssertEqual(sorted.map(\.title), ["有序", "无序二", "无序一"])
    }
}
