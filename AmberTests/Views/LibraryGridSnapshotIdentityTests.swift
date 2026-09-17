import XCTest
@testable import Amber

/// 资料库三张网格页的**快照身份**（审查单 §2.6-3，批 E）。
///
/// 三页从「订阅 → 全量重排 → `reloadData()` 整表销毁重建」换成了
/// `NSCollectionViewDiffableDataSource`。换完之后**身份就是成败所在**：
/// 身份错了，增量快照比 `reloadData()` 更糟——后者只是慢，前者会**错位**
/// （`design-ref/reactive-ui-review.md §2.2` 点名的两类坑：掺下标、掺会变的内容）。
///
/// 所以这几条钉的不是「界面长什么样」，而是身份规则本身：段身份是语义档不是段序号、
/// 件身份在整份快照里全局唯一、同一张碟只落进一段、重复身份不会把 diffable 喂炸。
/// 规则的正本在 `LibraryGridIdentity`（`Views/Shell/LibraryGridCards.swift`），
/// 是纯函数——不建窗口、不起 `AppState`，所以这一组跑起来不碰真实资料库。
final class LibraryGridSnapshotIdentityTests: XCTestCase {

    // MARK: - 取样

    private func album(_ id: String, name: String = "某碟") -> Album {
        Album(id: id, kind: .netease, name: name, artistName: "某人", artistId: nil,
              artworkURL: nil, publishDate: nil, trackCount: 1, description: nil)
    }

    /// 三个**与今天的星期几无关**的落档时刻，用来把段序钉死：
    /// 此刻永远是「今天」；此刻减一天永远是「昨天」；减 400 天必定早于今年年初，
    /// 永远是「更早」（一年最多 366 天）。`RecentAddedBucket` 自己的判档规则
    /// 不在这一组的测试范围里，这里只借它的三个确定档位。
    private var today: Date { Date() }
    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }
    private var longAgo: Date {
        Calendar.current.date(byAdding: .day, value: -400, to: Date())!
    }

    /// 同一个 id 交两次时按**第一次**的日期算——与 `deduplicated` 留第一份一致，
    /// 这样 `testRecentSectionsDropDuplicateIDs` 问的才是「留哪一份」而不是「查表查到谁」。
    private func sections(_ pairs: [(Album, Date?)]) -> [(RecentAddedBucket, [Album])] {
        let dates = Dictionary(pairs.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        return LibraryGridIdentity.recentSections(pairs.map(\.0)) { dates[$0.id] ?? nil }
    }

    // MARK: - 「最近添加」的段身份

    /// **段序由 `RecentAddedBucket.allCases` 定，不随输入顺序漂移。**
    /// 这是「段身份是语义档、不是段序号」的可观察后果：同一档无论这次排第几，
    /// 交出来的都是同一位身份，diffable 就不会把它判成「删了再加」。
    func testSectionOrderFollowsBucketOrderNotInputOrder() {
        let result = sections([(album("a"), longAgo),
                               (album("b"), today),
                               (album("c"), yesterday)])

        XCTAssertEqual(result.map(\.0), [.today, .yesterday, .earlier])
        XCTAssertEqual(result.map { $0.1.map(\.id) }, [["b"], ["c"], ["a"]])
    }

    /// 空档整段不出现（段数跟着内容走，不是恒定七段）。
    func testEmptyBucketsAreDropped() {
        let result = sections([(album("a"), today)])

        XCTAssertEqual(result.map(\.0), [.today])
    }

    /// **分档是一次划分**：同一张碟只落进一段，所以 `Album.id` 在整份快照里天然
    /// 全局唯一——diffable 要的正是全局唯一，不是段内唯一。
    func testAlbumIDsAreGloballyUniqueAcrossSections() {
        let albums = ["a", "b", "c", "d"].map { album($0) }
        let result = LibraryGridIdentity.recentSections(albums) { album in
            switch album.id {
            case "a", "b": return self.today
            case "c": return self.yesterday
            default: return self.longAgo
            }
        }

        let ids = result.flatMap { $0.1.map(\.id) }
        XCTAssertEqual(ids.count, albums.count)
        XCTAssertEqual(Set(ids).count, albums.count)
    }

    /// 旧存档没有 `albumAddedAt` 时 `albumAddedDate(for:)` 会交 nil，落「更早」档。
    /// 落不出档的碟要有个去处，否则它会整张从页面上消失。
    func testAlbumsWithoutDateFallIntoEarlier() {
        let result = sections([(album("a"), nil), (album("b"), today)])

        XCTAssertEqual(result.map(\.0), [.today, .earlier])
        XCTAssertEqual(result.last?.1.map(\.id), ["a"])
    }

    /// 段内保持输入顺序（`libraryAlbums` 自己的次序就是「最近加的在前」）。
    func testAlbumsKeepInputOrderWithinASection() {
        let result = sections([(album("a"), today), (album("b"), today), (album("c"), today)])

        XCTAssertEqual(result.first?.1.map(\.id), ["a", "b", "c"])
    }

    // MARK: - 去重（别把 diffable 喂炸）

    /// 重复身份在 `reloadData()` 下只是照画两遍，在 diffable 下是**抛异常**。
    /// 留第一份、保持原序。
    func testDeduplicatedKeepsFirstAndPreservesOrder() {
        let albums = [album("a", name: "先来的"), album("b"), album("a", name: "后来的")]

        let result = LibraryGridIdentity.deduplicated(albums)

        XCTAssertEqual(result.map(\.id), ["a", "b"])
        XCTAssertEqual(result.first?.name, "先来的")
    }

    /// 去重也管着分段那一路：重复的碟不会在两段里各占一格。
    func testRecentSectionsDropDuplicateIDs() {
        let result = sections([(album("a"), today), (album("a"), longAgo)])

        XCTAssertEqual(result.map(\.0), [.today])
        XCTAssertEqual(result.flatMap { $0.1.map(\.id) }, ["a"])
    }

    /// 同一条规则也服务「所有播放列表」页（两种 id 都是 `String`）。
    func testDeduplicatedWorksForPlaylists() {
        let first = LibraryPlaylist.local(name: "甲")
        let second = LibraryPlaylist.local(name: "乙")

        let result = LibraryGridIdentity.deduplicated([first, second, first])

        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    // MARK: - 「所有播放列表」那一格的身份

    /// 「心水歌曲」是**合成**的一张卡，库里没有它的行。它的身份做成枚举而不是
    /// `"favorites"` 这个约定字符串：真有人建了一份 id 是 `favorites` 的歌单就会撞，
    /// 而撞上的后果是 diffable 抛异常。这一条钉的就是「撞不上」。
    func testFavoritesCardIdentityCannotCollideWithAPlaylist() {
        XCTAssertNotEqual(LibraryGridIdentity.PlaylistEntry.favorites,
                          .playlist("favorites"))
        // diffable 认的是 `Hashable`，所以哈希也得分得开。
        XCTAssertEqual(Set([LibraryGridIdentity.PlaylistEntry.favorites,
                            .playlist("favorites")]).count, 2)
    }

    /// 身份只认 `playlist.id`：改名、换封面、增删曲目都不改它，
    /// 那几件只该就地重配、不该整张卡重建。
    func testPlaylistIdentityIgnoresMutableContent() {
        var playlist = LibraryPlaylist.local(name: "改名前")
        let before = LibraryGridIdentity.PlaylistEntry.playlist(playlist.id)
        playlist.name = "改名后"
        playlist.coverURL = "https://example.invalid/cover.jpg"

        XCTAssertEqual(before, .playlist(playlist.id))
    }
}
