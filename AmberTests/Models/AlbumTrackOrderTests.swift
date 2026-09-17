import SwiftUI
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

/// `Array.amberRemove(atOffsets:)` / `amberMove(fromOffsets:toOffset:)` 与 SwiftUI 自带
/// 那两个的**差分测试**。
///
/// 起因：`LibraryStore` 是服务层，为这两个方法 `import SwiftUI` 不合适（打开
/// `MemberImportVisibility` 之后这条依赖还会明着写在文件头），于是手写了一份。
/// 手写就得证明它跟原版逐位相同——尤其 `move` 的 `toOffset` 是**原数组**下标，
/// 摘出再插回时落点要减掉「摘走的元素里有几个排在它前面」，差一位就是静默错序。
///
/// 这里不编样例，直接拿 SwiftUI 那份当参照跑随机对拍。
final class IndexSetEditingParityTests: XCTestCase {

    func testRemoveAtOffsetsMatchesSwiftUI() {
        for count in 0...12 {
            for _ in 0..<40 {
                let base = Array(0..<count)
                let offsets = IndexSet((0..<count).filter { _ in Bool.random() })
                var mine = base, theirs = base
                mine.amberRemove(atOffsets: offsets)
                theirs.remove(atOffsets: offsets)
                XCTAssertEqual(mine, theirs, "count=\(count) offsets=\(offsets.map { $0 })")
            }
        }
    }

    func testMoveFromOffsetsMatchesSwiftUI() {
        for count in 0...12 {
            let base = Array(0..<count)
            for destination in 0...count {
                for _ in 0..<40 {
                    let offsets = IndexSet((0..<count).filter { _ in Bool.random() })
                    var mine = base, theirs = base
                    mine.amberMove(fromOffsets: offsets, toOffset: destination)
                    theirs.move(fromOffsets: offsets, toOffset: destination)
                    XCTAssertEqual(mine, theirs,
                                   "count=\(count) offsets=\(offsets.map { $0 }) dest=\(destination)")
                }
            }
        }
    }

    /// 几条手算过的边界，免得随机用例恰好都没覆盖到。
    func testKnownEdgeCases() {
        var a = ["a", "b", "c", "d", "e"]
        a.amberMove(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(a, ["b", "c", "a", "d", "e"], "往后挪：落点要减掉摘走的那一个")

        var b = ["a", "b", "c", "d", "e"]
        b.amberMove(fromOffsets: IndexSet(integer: 3), toOffset: 1)
        XCTAssertEqual(b, ["a", "d", "b", "c", "e"], "往前挪：落点不用减")

        var c = ["a", "b", "c", "d", "e"]
        c.amberMove(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        XCTAssertEqual(c, ["c", "d", "a", "b", "e"], "不连续的多个一起挪，相对顺序保留")

        var d = ["a", "b", "c"]
        d.amberRemove(atOffsets: IndexSet([0, 2]))
        XCTAssertEqual(d, ["b"])

        var e = ["a", "b", "c"]
        e.amberMove(fromOffsets: IndexSet(), toOffset: 2)
        XCTAssertEqual(e, ["a", "b", "c"], "空集合是恒等变换")
    }
}
