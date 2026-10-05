import XCTest
@testable import Amber

/// 大资料库扩展性基准：200 / 1 万 / 5 万首下，几条「用户点一下」的路径在主线程上花多久。
///
/// **默认跳过**（`AMBER_BENCH=1` 才跑）：5 万首的合成库光灌就要十来秒，不该进日常测试时长。
/// 复跑：
///
///     AMBER_BENCH=1 DEVELOPER_DIR=… xcodebuild test … \
///       -only-testing:AmberTests/LibraryScaleBenchmarkTests
///
/// `TEST_RUNNER_AMBER_BENCH=1` 也行（xcodebuild 会把 `TEST_RUNNER_` 前缀剥掉转给测试进程）。
/// 结果打在标准输出，每行以 `BENCH` 开头，`grep BENCH` 即得。可选 `AMBER_BENCH_SIZES=200,10000`
/// 只跑其中几档。
///
/// 合成库的形状（2026-10-06 定）：专辑每 12 首一张、艺人每 40 首一位（按专辑归属，同碟同艺人）；
/// 每 10 张碟里 3 张是本地导入（`local:` / `local:album:` 前缀）；每 6 首里 1 首**不带 albumId**、
/// 靠 `fallbackKey` 归碟（音源单曲没给专辑节点的那种）。曲目与专辑的先后同序，与真实
///「整张碟一起入库」的顺序一致。名字全是 ASCII：拼音那一列不进任何被测路径，换成汉字只会让灌库变慢。
///
/// **全程临时目录**：`LibraryStore(directory:)` / `DownloadStore(directory:)` 都注入临时目录，
/// 不碰真实资料库，也不写 `UserDefaults`。
@MainActor
final class LibraryScaleBenchmarkTests: XCTestCase {

    private var directories: [URL] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["AMBER_BENCH"] == "1", "基准测试，AMBER_BENCH=1 才跑")
    }

    override func tearDown() async throws {
        // 清单是异步写的：等排着的写完再删目录，免得写到一半的临时文件落进已删的目录。
        DownloadStore.flushManifestWrites()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private var sizes: [Int] {
        ProcessInfo.processInfo.environment["AMBER_BENCH_SIZES"]?
            .split(separator: ",").compactMap { Int($0) } ?? [200, 10_000, 50_000]
    }

    private func makeDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberBench-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    // MARK: - 计时

    /// best of `runs`，毫秒。`body` 收第几次（0 起），好让每次删不同的歌。
    private func best(_ runs: Int, _ body: (Int) throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for run in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body(run)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            best = min(best, elapsed)
        }
        return best
    }

    private func report(_ name: String, _ size: Int, _ ms: Double, _ note: String = "") {
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        print(String(format: "BENCH %@ %@ N=%d %.3f ms %@", config, name, size, ms, note))
    }

    // MARK: - 合成库

    private struct Shape {
        var tracks: [Track] = []
        var albums: [Album] = []
    }

    private static func shape(_ count: Int) -> Shape {
        var shape = Shape()
        let albumCount = (count + 11) / 12
        for a in 0..<albumCount {
            let local = a % 10 < 3
            let artist = "Artist \(a * 12 / 40)"
            let album = Album(id: local ? Album.localIDPrefix + "a\(a)" : "qqalbum:\(a)",
                              kind: .qq, name: "Album \(a)", artistName: artist, artistId: nil,
                              artworkURL: nil, publishDate: nil, trackCount: 12, description: nil)
            shape.albums.append(album)
            for i in (a * 12)..<min(count, a * 12 + 12) {
                let id = local ? Track.localIDPrefix + "t\(i)" : "qq:\(i)"
                shape.tracks.append(Track(id: id, kind: .qq, title: "Song \(i)",
                                          artistName: artist, artistId: nil,
                                          albumName: album.name,
                                          albumId: i % 6 == 5 ? nil : album.id,
                                          artworkURL: nil, duration: 200))
            }
        }
        return shape
    }

    /// 直接往库里灌（逐首 `addToLibrary` 是 O(N²) 的 `position + 1`，5 万首灌不完），
    /// 再整张重建搜索索引——于是被测的 store 开库时看到的是一份「早就在那儿」的库，
    /// 与用户机器上的状态一样：索引里艺人那一档已经齐了，对账不会第一次就全量补写。
    private func seedLibrary(_ count: Int) throws -> (URL, Shape) {
        let directory = try makeDirectory("lib\(count)")
        _ = try AmberDatabaseMigration.runIfNeeded(directory: directory, mediaFolder: directory,
                                                   renameLegacyOnSuccess: true)
        let database = try AmberDatabase.shared(directory: directory)
        let db = database.sqlite
        let shape = Self.shape(count)
        try db.transaction {
            for (position, track) in shape.tracks.enumerated() {
                _ = try db.run("""
                    INSERT INTO track (id, kind, title, artist_name, artist_id, album_name, album_id,
                                       artwork_url, duration, album_key)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [track.id, track.kind.rawValue, track.title, track.artistName, nil as String?,
                          track.albumName, track.albumId, nil as String?, track.duration,
                          LibraryStore.fallbackKey(for: track)])
                _ = try db.run("INSERT INTO library_track (track_id, position) VALUES (?,?)",
                               [track.id, position])
            }
            for (position, album) in shape.albums.enumerated() {
                _ = try db.run("""
                    INSERT INTO library_album (id, kind, name, artist_name, track_count, position,
                                               album_key)
                    VALUES (?,?,?,?,?,?,?)
                    """, [album.id, album.kind.rawValue, album.name, album.artistName,
                          album.trackCount, position,
                          LibraryStore.fallbackKey(name: album.name, artist: album.artistName,
                                                   kind: album.kind, isLocal: album.isLocal)])
            }
            try LibrarySearchIndex.rebuild(in: db)
        }
        // `shared` 按目录记忆化、弱引用：这里放手之前 store 还没建，连接会被关掉重开，无妨。
        return (directory, shape)
    }

    /// `LibraryStore.belongs` 是 `private`，这里照抄一份——只为单独给「空碟检查」那一段计时。
    /// 与原函数逐字同解（改原函数时这里要跟着改，否则量的是另一件事）。
    private static func belongs(_ track: Track, to album: Album) -> Bool {
        if let albumId = track.albumId { return albumId == album.id }
        guard !album.name.isEmpty, !track.albumName.isEmpty else { return false }
        return LibraryStore.fallbackKey(for: track)
            == LibraryStore.fallbackKey(name: album.name, artist: album.artistName,
                                        kind: album.kind, isLocal: album.isLocal)
    }

    // MARK: - 1 & 2：退库、入库、艺人对账

    func testLibraryScale() throws {
        for size in sizes {
            let (directory, shape) = try seedLibrary(size)

            let loadMs = try best(3) { _ in _ = LibraryStore(directory: directory) }
            report("load(init)", size, loadMs)

            let store = LibraryStore(directory: directory)
            XCTAssertEqual(store.libraryTracks.count, size)

            // 改前形状的两段（照抄原表达式）：空碟检查、载入时的孤儿本地碟检查。
            let pruneScanMs = best(3) { _ in
                _ = store.libraryAlbums.filter { album in
                    !store.libraryTracks.contains { Self.belongs($0, to: album) }
                }
            }
            report("pruneEmptyAlbums-scan(旧表达式)", size, pruneScanMs)

            // 艺人对账单独量：另起一份索引、从同一个库读指纹，什么都没变时对一遍账。
            let db = try AmberDatabase.shared(directory: directory).sqlite
            let index = LibrarySearchIndex()
            try index.load(from: db)
            let derivedMs = try best(5) { _ in _ = try LibrarySearchIndex.derivedArtists(in: db) }
            report("derivedArtists", size, derivedMs)
            let idsMs = best(5) { _ in _ = index.ids(of: .artist) }
            report("ids(of:.artist)", size, idsMs)
            let reconcileMs = try best(5) { _ in
                try db.transaction {
                    try index.reconcileArtists(LibrarySearchIndex.derivedArtists(in: db), in: db)
                }
            }
            report("reconcileArtists(全程)", size, reconcileMs)

            // 单首退库：每次删一首不同的、所在碟不会因此变空的歌（每碟第 1 首）。
            // 从后半段挑：空碟检查对每张碟从头扫到第一首成员，越靠后的碟越贵，后半段是代表值。
            let albumsForSingles = shape.albums.indices.suffix(shape.albums.count / 2)
            var singleQueue = albumsForSingles.map { shape.tracks[$0 * 12] }.makeIterator()
            let singleRuns = size >= 50_000 ? 2 : 5
            let removeOneMs = best(singleRuns) { _ in
                guard let track = singleQueue.next() else { return }
                store.removeFromLibrary(track)
            }
            report("removeFromLibrary×1", size, removeOneMs, "runs=\(singleRuns)")

            // 批量删，照界面那条路的写法（`SongsTableView.deleteSelection`）。
            // 每碟第 2…12 首里挑，不让碟变空（与上面不撞）。
            // 批量大小默认 100；改前 5 万首删 100 首要半个多小时，那一次用
            // `AMBER_BENCH_BATCH=10` 量 10 首、报告里按线性外推，写明是外推。
            let wanted = Int(ProcessInfo.processInfo.environment["AMBER_BENCH_BATCH"] ?? "") ?? 100
            let batchCount = min(wanted, size / 10)
            var cursor = 0  // 每碟第 2…12 首，与上面单首删的「后半段每碟第 1 首」不撞
            func nextBatch() -> [Track] {
                var picked: [Track] = []
                while picked.count < batchCount, cursor < shape.albums.count {
                    for offset in 1..<12 {
                        let i = cursor * 12 + offset
                        if i < shape.tracks.count, i % 6 != 5, picked.count < batchCount {
                            picked.append(shape.tracks[i])
                        }
                    }
                    cursor += 1
                }
                return picked
            }
            let batchRuns = size >= 50_000 ? 1 : (size >= 10_000 ? 2 : 3)
            var loopMs = Double.infinity
            var batchMs = Double.infinity
            for _ in 0..<batchRuns {
                // 逐首调（改前界面的写法）。
                let looped = nextBatch()
                if looped.count == batchCount {
                    loopMs = min(loopMs, best(1) { _ in
                        store.withUndoGrouping("从资料库中删除") {
                            for track in looped { store.removeFromLibrary(track) }
                        }
                    })
                }
                // 批量 API（改后界面的写法）。
                let batched = nextBatch()
                if batched.count == batchCount {
                    batchMs = min(batchMs, best(1) { _ in
                        store.withUndoGrouping("从资料库中删除") {
                            store.removeFromLibrary(batched)
                        }
                    })
                }
            }
            report("removeFromLibrary×\(batchCount)(逐首)", size, loopMs, "runs=\(batchRuns)")
            report("removeFromLibrary×\(batchCount)(批量API)", size, batchMs, "runs=\(batchRuns)")

            // 单首入库：新歌、新艺人名不出现，走的是「前插 + 对账」那一套。
            let addMs = best(5) { run in
                store.addToLibrary(Track(id: "bench:add:\(run)", kind: .qq, title: "New \(run)",
                                         artistName: "Artist 0", artistId: nil,
                                         albumName: "Album 0", albumId: shape.albums[0].id,
                                         artworkURL: nil, duration: 200))
            }
            report("addToLibrary×1", size, addMs)
        }
    }

    // MARK: - 3 & 4：下载清单与排队

    /// 一份媒体夹里有 `count` 条条目的清单（下载来的 / 拷进媒体夹的导入）。文件不必真在：
    /// `loadIndex` 对找不到文件的条目是「记录留着、不进 states」，清单照样整份重写。
    private func seedManifest(_ count: Int) throws -> URL {
        let directory = try makeDirectory("dl\(count)")
        var entries: [String: Any] = [:]
        for i in 0..<count {
            entries["qq:\(i)"] = [
                "path": "Artist \(i / 40)/Album \(i / 12)/\(i % 12 + 1) Song \(i).flac",
                "bytes": 31_000_000 + i, "date": 780_000_000.0 + Double(i),
                "mtime": 780_000_000.0 + Double(i),
                "quality": "无损 · 44.1 kHz 16 位 FLAC", "codec": "flac",
                "sampleRate": 44_100.0, "bitDepth": 16, "tier": "lossless",
                "tagged": true, "tagVersion": 3,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["manifestVersion": 1,
                                                               "entries": entries])
        try data.write(to: directory.appendingPathComponent("index.json"))
        return directory
    }

    func testDownloadScale() throws {
        for size in sizes {
            let directory = try seedManifest(size)
            let store = DownloadStore(directory: directory,
                                      legacyDirectory: directory.appendingPathComponent("none"))
            XCTAssertEqual(store.indexedPaths.count, size)

            // 一次 `save`：认领一份本机文件（导入每首两次、每下完一首一次、回填每首一次）。
            let file = directory.appendingPathComponent("adopt.m4a")
            try Data("x".utf8).write(to: file)
            let adoptMs = best(5) { run in
                store.adoptLocalFile(at: file, for: Track(id: "local:bench\(run)", kind: .qq,
                                                          title: "x", artistName: "x",
                                                          artistId: nil, albumName: "x",
                                                          albumId: nil, artworkURL: nil,
                                                          duration: 1),
                                     external: false)
            }
            report("adoptLocalFile×1(主线程)", size, adoptMs)
            let drainMs = best(1) { _ in DownloadStore.flushManifestWrites() }
            report("清单写入排空(后台,上面5次之后)", size, drainMs)

            // 导入那种连写：200 首背靠背认领，主线程总时长 + 之后后台排空要多久。
            let burstMs = best(1) { _ in
                for i in 0..<200 {
                    store.adoptLocalFile(at: file, for: Track(id: "local:burst\(i)", kind: .qq,
                                                              title: "x", artistName: "x",
                                                              artistId: nil, albumName: "x",
                                                              albumId: nil, artworkURL: nil,
                                                              duration: 1),
                                         external: false)
                }
            }
            report("adoptLocalFile×200连写(主线程总)", size, burstMs)
            let burstDrainMs = best(1) { _ in DownloadStore.flushManifestWrites() }
            report("清单写入排空(后台,连写之后)", size, burstDrainMs)

            // 一次退下载（退库经 `onTracksRemoved` 走到这里）。
            let removeMs = best(5) { run in store.remove(ids: ["qq:\(run)"]) }
            report("DownloadStore.remove×1", size, removeMs)
        }
    }

    /// `checkForMissingDownloads`：启动时把整库丢给 `download(_:)`。
    func testDownloadEnqueueScale() throws {
        for size in sizes {
            let tracks = Self.shape(size).tracks
            // 取流永远不回来：头两首占住并发闸门，其余全留在队里，量的就只是排队本身。
            // （那两条睡着的任务随测试进程一起走，不清。）
            func makeStore() throws -> DownloadStore {
                let directory = try makeDirectory("q\(size)")
                let store = DownloadStore(directory: directory,
                                          legacyDirectory: directory.appendingPathComponent("none"))
                store.resolveRemoteURL = { _ in
                    try await Task.sleep(for: .seconds(3600))
                    throw CancellationError()
                }
                return store
            }
            let runs = size >= 50_000 ? 1 : 3
            var enqueueMs = Double.infinity
            var store: DownloadStore!
            for _ in 0..<runs {
                store = try makeStore()
                let start = DispatchTime.now().uptimeNanoseconds
                store.download(tracks)
                enqueueMs = min(enqueueMs,
                                Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            report("download(整库排队)", size, enqueueMs)
            // 再丢一次整库（启动任务又跑一遍、队里还满着）：全是「已在队里」的去重判断。
            let againMs = best(runs) { _ in store.download(tracks) }
            report("download(整库再排一次·全去重)", size, againMs)
            // 退库时 `remove(ids:)` 要把排着队的那首摘掉。
            let cancelMs = best(5) { run in store.remove(ids: [tracks[size / 2 + run].id]) }
            report("DownloadStore.remove×1(队里有整库)", size, cancelMs)
            let cancelBatchMs = best(1) { _ in
                store.remove(ids: tracks[(size / 2 + 10)..<min(size, size / 2 + 110)].map(\.id))
            }
            report("DownloadStore.remove×100(队里有整库)", size, cancelBatchMs)
        }
    }
}
