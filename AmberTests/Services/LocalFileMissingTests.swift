import XCTest
@testable import Amber

/// 本地文件失联（`library 规格` §10.1，`[实测]`）：懒判定的标记、批量查找
/// 那一遍扫描、以及「重新指路」。照 Music.app：条目留着，只打一枚 `!`。
///
/// **本地性只有一处真值源**：`DownloadStore`（落库是主库的 `local_file` 表）。
/// 所以这一整份用例里，「这首歌在本机有文件」一律写成 `downloads.adoptLocalFile(…)`，
/// 而不是往 `Track` 上挂一个路径字段——那个字段已经没有了，它是第二份会腐败的真相。
///
/// 两处宿主环境的坑，都按仓库里已有的写法躲开：
/// - `LibraryStore` 与`DownloadStore` 都注入临时目录（后者的主库显式指到同一个目录，
///   两个 store 才共用同一条连接），绝不碰真实的`~/Library/Application Support/Amber/`；
/// - `noteStarted` 受「使用听歌历史记录」开关管，而那条开关读的是**真实**偏好
///   （测试宿主就是 Amber 本身），所以整份存下来、跑完原样还回去，同 `LibrarySyncSettingsTests`。
@MainActor
final class LocalFileMissingTests: XCTestCase {

    private var directory: URL!
    /// 放「音频文件」的地方，跟主库分开：卷保护那几条要把它整个删掉再造回来。
    /// 它同时是 `DownloadStore` 的「媒体」文件夹。
    private var mediaDirectory: URL!
    private var savedValues: SettingsValues!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileMissingTests-\(UUID().uuidString)", isDirectory: true)
        mediaDirectory = directory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        savedValues = AppSettings.shared.values
        AppSettings.shared.values.useListeningHistory = true
    }

    override func tearDownWithError() throws {
        AppSettings.shared.values = savedValues
        try? FileManager.default.removeItem(at: directory)
    }

    /// 两个 store 共用一条连接：`DownloadStore` 的主库显式指到`directory`
    /// （它的 `directory` 是媒体夹，生产路径上两者本来就不在一起）。
    /// `legacyDirectory` 指回媒体夹自己，把「首次启动从老落点搬家」那一段闸掉——
    /// 不闸的话它会去看开发者本机真实的 `~/Library/Application Support/Amber/Downloads/`。
    private func makeDownloads() -> DownloadStore {
        DownloadStore(directory: mediaDirectory, legacyDirectory: mediaDirectory,
                      databaseDirectory: directory)
    }

    private func makeStores() -> (library: LibraryStore, downloads: DownloadStore) {
        (LibraryStore(directory: directory), makeDownloads())
    }

    /// 造一个真文件，返回它的 URL。内容无所谓——校验只问路径在不在。
    @discardableResult
    private func writeFile(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? mediaDirectory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func makeLocalTrack(_ suffix: String) -> Track {
        Track(id: "\(Track.localIDPrefix)\(suffix)", kind: .qq, title: "曲 \(suffix)",
              artistName: "某人", artistId: nil, albumName: "某碟", albumId: nil,
              artworkURL: nil, duration: 200)
    }

    /// 「这首歌在本机有一份文件，在这儿」——本地性唯一的写入口。
    ///
    /// `external` 照 `DownloadStore.adoptLocalFile` 的语义自己算：媒体夹之外的
    /// 就是「文件 › 导入…」没勾拷贝时的原地引用，索引里存绝对路径。
    private func adopt(_ track: Track, at url: URL, in downloads: DownloadStore) {
        let base = mediaDirectory.standardizedFileURL.path
        let external = !url.standardizedFileURL.path.hasPrefix(base + "/")
        downloads.adoptLocalFile(at: url, for: track, external: external)
    }

    // MARK: - 懒判定：标记只由「用它的那一刻」写

    /// 判定是懒的：文件早没了，只要没人拿它去用、也没人跑过批量查找，就没有标记。
    /// 这条钉的是 spec §10.1 第 1 条——判定挂在播放（使用）路径上、没有后台全量扫描
    /// （§10.1.2 实测，`[实测]`），Amber 也不许偷偷加一条。
    func testNothingIsMarkedUntilSomethingUsesIt() throws {
        let url = try writeFile("a.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("a")
        store.addToLibrary(track)
        adopt(track, at: url, in: downloads)
        try FileManager.default.removeItem(at: url)

        XCTAssertFalse(store.isFileMissing(track.id), "没人用过它，不该凭空冒出标记")

        // 取流那一步发现文件没了（`AppState.providerResolver` 里的那一下）。
        store.markFileMissing(track.id)
        XCTAssertTrue(store.isFileMissing(track.id))
    }

    /// 撤标记：重新指路成功、或批量查找找回来了。
    func testClearFileMissing() throws {
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("b")
        store.addToLibrary(track)
        adopt(track, at: try writeFile("b.m4a"), in: downloads)
        store.markFileMissing(track.id)
        store.clearFileMissing(track.id)
        XCTAssertFalse(store.isFileMissing(track.id))
    }

    // MARK: - 批量查找那一遍扫描

    /// 删歌的**常态**形状：文件连同它的专辑目录、艺人目录一起没了。必须算进缺失清单。
    ///
    /// 这条钉的是一个真出过的错：早先拿「文件的上级目录在不在」当卷保护的锚点，
    /// 于是中间目录一空掉就被当成「路没通」跳过。[实测 2026-09-10] 用户库里 11 条
    /// 失效路径有 10 条是这个形状，那版判据一条都报不出来。
    /// 「媒体」文件夹按 `艺人/专辑/曲目` 摆，删完一张碟目录就空了、跟着被清掉——
    /// 中间目录消失是删除的**伴生现象**，不是「路没通」。
    func testMissingDirectoriesStillCount() throws {
        let url = try writeFile("告五人/带你飞/又到天黑.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("c1")
        store.addToLibrary(track)
        adopt(track, at: url, in: downloads)
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty)

        // 连艺人目录一起端掉，就像用户在 Finder 里删完这张碟之后的样子。
        try FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent("告五人"))
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).map(\.track.id), [track.id],
                       "卷通着、文件不在，就是真缺失——中间目录在不在无所谓")
        XCTAssertTrue(store.isFileMissing(track.id), "扫完要把标记对齐到结果上")
    }

    /// 文件被放回原处：下一次扫描要把标记**撤掉**，而不是只加不减。
    func testRestoredFileClearsTheMark() throws {
        let url = try writeFile("d.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("d")
        store.addToLibrary(track)
        adopt(track, at: url, in: downloads)

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).count, 1)
        XCTAssertTrue(store.isFileMissing(track.id))

        try writeFile("d.m4a")
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty)
        XCTAssertFalse(store.isFileMissing(track.id), "修好了界面就不该还红着")
    }

    /// 卷保护：卷本身没挂载时**一条都不许新标**。
    /// 这就是「拔一次移动硬盘 ＝ 一屏红」的那条线，写错了等于误报一整片。
    ///
    /// 不用真去挂一个盘：macOS 上外接卷与网络卷都挂在 `/Volumes/<名字>`，
    /// 卷一走那一层整个消失、只剩 `/Volumes` 空壳，而那正是判据要认的现场。
    /// 指一个必然不存在的卷名，形状与拔了盘完全一样。
    func testUnmountedVolumeMarksNothing() throws {
        let onVolume = URL(fileURLWithPath:
            "/Volumes/AmberTestVolumeThatIsNotMounted/媒体/歌.m4a")
        let local = try writeFile("e.m4a")

        let (store, downloads) = makeStores()
        let far = makeLocalTrack("e1")
        let near = makeLocalTrack("e2")
        store.addToLibrary(far)
        store.addToLibrary(near)
        adopt(far, at: onVolume, in: downloads)
        adopt(near, at: local, in: downloads)
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty,
                      "卷没挂载，那不是文件没了，是路还没通")

        // 同一轮里另一条在通着的卷上的歌照常判——卷保护是按卷分的，不是一票否决全库。
        try FileManager.default.removeItem(at: local)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).map(\.track.id),
                       ["\(Track.localIDPrefix)e2"])
    }

    /// 已经标过的，在卷走掉之后要「维持原状」——不是趁机撤掉，也仍旧算在「缺少的文件」里
    ///（那份清单就是标记的镜像，批量查找照样该试着找回它）。
    func testExistingMarkSurvivesVolumeGoingAway() throws {
        let (store, downloads) = makeStores()
        let onVolume = URL(fileURLWithPath:
            "/Volumes/AmberTestVolumeThatIsNotMounted/媒体/歌.m4a")
        let track = makeLocalTrack("f")
        store.addToLibrary(track)
        adopt(track, at: onVolume, in: downloads)
        store.markFileMissing(track.id)

        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).map(\.track.id), [track.id],
                       "路不通时维持原状：标过的继续标着")
        XCTAssertTrue(store.isFileMissing(track.id))
    }

    /// 上级目录被同名**文件**顶了位。卷仍旧通着（`/Volumes` 空壳才是不通的证据），
    /// 文件确实不在那条路径上，所以照常算缺失。
    func testParentReplacedByFileStillCounts() throws {
        let url = try writeFile("g.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("g")
        store.addToLibrary(track)
        adopt(track, at: url, in: downloads)

        try FileManager.default.removeItem(at: mediaDirectory)
        try Data("not a folder".utf8).write(to: mediaDirectory)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).count, 1)
    }

    /// 本机**没有**文件的曲目永远不该被卷进来。
    ///
    /// 从前这条写的是「在线曲目没有 `localPath`」——判据是曲目的来路。现在判据只有一个：
    /// `local_file` 里有没有它那一行。来路是 `local:` 还是音源，与这件事无关
    ///（下面那条正好是反过来的证明）。
    func testTrackWithoutLocalFileIsNeverCounted() throws {
        let (store, downloads) = makeStores()
        let remote = Track(id: "qq:123", kind: .qq, title: "在线", artistName: "某人",
                           artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil,
                           duration: 200)
        store.addToLibrary(remote)
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty)
        XCTAssertFalse(store.isFileMissing("qq:123"))
    }

    /// **有意的行为变化**：在线曲目下载到本机之后文件被删，现在**也**算失联。
    ///
    /// 从前判据是 `track.isLocal`（「文件 › 导入…」进来的才算），于是一首下载过的歌
    /// 把文件删掉之后，表格里一切正常、点一下才静默失败一次；而它与本地导入的歌
    /// 处境完全一样——本机曾经有过一份文件，现在没了。
    ///
    /// 这是**修 bug**，不是回归。取流那一刻的判据同源（`AppState.providerResolver`：
    /// `fileURL` 拿不到、`absoluteURL` 却记着一条路径 ⇒ 打标记），一并钉在这里。
    func testDownloadedRemoteTrackAlsoGetsMarked() throws {
        let url = try writeFile("qq-123.m4a")
        let (store, downloads) = makeStores()
        let remote = Track(id: "qq:123", kind: .qq, title: "在线", artistName: "某人",
                           artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil,
                           duration: 200)
        store.addToLibrary(remote)
        adopt(remote, at: url, in: downloads)
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty)

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).map(\.track.id), ["qq:123"])
        XCTAssertTrue(store.isFileMissing("qq:123"))

        XCTAssertNil(downloads.fileURL(for: "qq:123"), "文件没了就不许再当能播的那一份")
        XCTAssertNotNil(downloads.absoluteURL(for: "qq:123"),
                        "但索引里记着的那条路径还在——正是靠它判出「曾经有过」")
    }

    /// 只在「最近播放」里出现、根本没进资料库的那种也要扫到
    ///（[实测 2026-09-10] 用户库里有 5 条这样的）。
    func testRecentsOnlyTrackAlsoCounts() throws {
        let url = try writeFile("h.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("h")
        store.noteStarted(track)
        adopt(track, at: url, in: downloads)
        XCTAssertFalse(store.recentTracks.isEmpty, "听歌历史开关已在 setUp 里打开")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).map(\.track.id), [track.id])
    }

    /// 同一首歌同时在资料库、心水、最近播放、播放列表里时，清单里只能出现一次——
    /// 「共 N 个」那句要报的是歌数，不是副本数。
    ///
    /// 从前这是靠「四处合起来再按 id 去重」保证的；现在是 `track` 表的主键天然保证的
    ///（`local_file` JOIN `track`，一首歌就是一行）。这条留着是因为它守的是那句文案，
    /// 不是某一版实现。
    func testMissingListIsDeduplicated() throws {
        let url = try writeFile("i.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("i")
        store.addToLibrary(track)
        store.toggleFavorite(track)
        store.noteStarted(track)
        _ = store.createPlaylist(name: "本地列表", tracks: [track])
        adopt(track, at: url, in: downloads)

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.missingLocalTracks(downloads: downloads).count, 1)
    }

    // MARK: - 重新指路

    /// **一次改路径就是一次写。**
    ///
    /// 从前这条用例有四行断言，逐个查「资料库、心水、最近播放、播放列表里那四份副本
    /// 的 `localPath` 都改到新位置了没有」——那四行存在的理由，就是曲目是值类型、
    /// 四处各存各的副本，漏掉哪一处那一处就还指着老路。
    ///
    /// 四行现在收成一行：本地性只有 `local_file` 一处，没有第二份要同步的真相。
    /// 这正是这次要证明的事。
    func testRelocateIsASingleWrite() throws {
        let old = try writeFile("j.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("j")
        let id = track.id

        store.addToLibrary(track)
        store.toggleFavorite(track)
        store.noteStarted(track)
        _ = store.createPlaylist(name: "本地列表", tracks: [track])
        adopt(track, at: old, in: downloads)

        try FileManager.default.removeItem(at: old)
        store.markFileMissing(id)

        // 用户在「查找」面板里指了一份新文件：`MissingFileLocator.relocate` 现在就这两句。
        let moved = directory.appendingPathComponent("Moved", isDirectory: true)
        let new = try writeFile("j.m4a", in: moved)
        adopt(track, at: new, in: downloads)
        store.clearFileMissing(id)

        XCTAssertEqual(downloads.fileURL(for: id), new)
        XCTAssertFalse(store.isFileMissing(id), "指完路就该当场恢复，不等下一次扫描")

        // 再扫一遍仍是好的：说明写回去的是真路径，不只是把标记抹了。
        XCTAssertTrue(store.missingLocalTracks(downloads: downloads).isEmpty)
    }

    /// 指完路要落盘：重开一个 `DownloadStore`（同一套目录）读到的应当是新路径。
    func testRelocatePersists() throws {
        let old = try writeFile("k.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("k")
        store.addToLibrary(track)
        adopt(track, at: old, in: downloads)

        let moved = directory.appendingPathComponent("Moved2", isDirectory: true)
        let new = try writeFile("k.m4a", in: moved)
        adopt(track, at: new, in: downloads)
        store.flushNow()

        let reopened = makeDownloads()
        XCTAssertEqual(reopened.fileURL(for: track.id), new)
    }

    /// 失踪标记**不**落盘：重开之后是一张白纸。
    /// 存了才会出「上次退出时盘没插、这次插着却还标着」的陈旧假象。
    func testMissingMarkIsNotPersisted() throws {
        let url = try writeFile("l.m4a")
        let (store, downloads) = makeStores()
        let track = makeLocalTrack("l")
        store.addToLibrary(track)
        adopt(track, at: url, in: downloads)
        try FileManager.default.removeItem(at: url)
        store.markFileMissing(track.id)
        store.flushNow()

        let reopened = LibraryStore(directory: directory)
        XCTAssertFalse(reopened.isFileMissing(track.id))
    }

    // MARK: - 「用这个位置找回其余的」

    /// 整个「媒体」文件夹被搬走/改名：用户指完其中一首，剩下的按同一段位移全找得回来。
    /// 这是 res 143 idx 25「可以找到所有缺少的文件」那条分支的形状。
    func testBatchLocateFollowsTheSameShift() throws {
        let oldRoot = directory.appendingPathComponent("旧媒体", isDirectory: true)
        let newRoot = directory.appendingPathComponent("新媒体", isDirectory: true)
        let anchorOld = oldRoot.appendingPathComponent("告五人/带你飞/又到天黑.m4a")
        let anchorNew = try writeFile("告五人/带你飞/又到天黑.m4a", in: newRoot)
        let otherOld = oldRoot.appendingPathComponent("茄子蛋/我着数/浪流连.m4a")
        try writeFile("茄子蛋/我着数/浪流连.m4a", in: newRoot)

        let found = MissingFileLocator.candidates(
            for: [(id: "\(Track.localIDPrefix)m", from: otherOld.path)],
            anchor: anchorNew, replacing: anchorOld)

        XCTAssertEqual(found.map(\.0), ["\(Track.localIDPrefix)m"])
        XCTAssertEqual(found.first?.1.standardizedFileURL.path,
                       newRoot.appendingPathComponent("茄子蛋/我着数/浪流连.m4a")
                           .standardizedFileURL.path)
    }

    /// 第二趟兜底：文件原本散在各处，现在被一股脑收进了同一个文件夹。
    /// 前缀改写推不出来（老路径不在同一棵树下），靠同名命中。
    func testBatchLocateFallsBackToSameName() throws {
        let anchorOld = URL(fileURLWithPath: "/tmp/AmberTestNotThere/一首.m4a")
        let anchorNew = try writeFile("一首.m4a")
        try writeFile("另一首.m4a")

        let found = MissingFileLocator.candidates(
            for: [(id: "\(Track.localIDPrefix)n",
                   from: "/tmp/AmberTestSomewhereElse/另一首.m4a")],
            anchor: anchorNew, replacing: anchorOld)

        XCTAssertEqual(found.first?.1.standardizedFileURL.path,
                       mediaDirectory.appendingPathComponent("另一首.m4a")
                           .standardizedFileURL.path)
    }

    /// 推出来的路径上没有文件就不要——宁可报「找不到」，也不能把条目指到一份不相干的文件上。
    /// 这是 res 143 idx 23「找不到任何缺少的文件」那条分支。
    func testBatchLocateNeverGuesses() throws {
        let anchorOld = URL(fileURLWithPath: "/tmp/AmberTestOld/一首.m4a")
        let anchorNew = try writeFile("一首.m4a")

        let found = MissingFileLocator.candidates(
            for: [(id: "\(Track.localIDPrefix)o", from: "/tmp/AmberTestOld/没造出来的.m4a")],
            anchor: anchorNew, replacing: anchorOld)

        XCTAssertTrue(found.isEmpty)
    }
}
