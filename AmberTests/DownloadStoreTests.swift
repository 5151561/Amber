import XCTest
@testable import Amber

/// 下载索引与扩展名判定。真下载要网络，这里只验证「判容器」和「索引来回」两件本地逻辑。
final class DownloadStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 扩展名只看头字节：URL 上那个是档位码约定的名字，降级取到别的容器时就是错的。
    func testFileExtensionFromHeaderBytes() {
        func head(_ bytes: [UInt8]) -> [UInt8] { bytes }
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: Array("fLaC".utf8)), "flac")
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: Array("OggS".utf8)), "ogg")
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: Array("ID3\u{03}".utf8)), "mp3")
        // 裸 MPEG 帧同步（11 位全 1），没有 ID3 头
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: head([0xFF, 0xFB, 0x90, 0x00])), "mp3")
        // ISO BMFF：前 4 字节是 box 长度，'ftyp' 在偏移 4
        XCTAssertEqual(
            DownloadStore.fileExtension(ofHeader: [0, 0, 0, 0x20] + Array("ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: head([0x00, 0x01, 0x02, 0x03])), "bin")
        XCTAssertEqual(DownloadStore.fileExtension(ofHeader: []), "bin", "空文件不该猜")
    }

    /// 文件名用 track.id 安全化，冒号换下划线。
    func testSafeNameReplacesSeparators() {
        XCTAssertEqual(DownloadStore.safeName("qq:0039MnYb"), "qq_0039MnYb")
        XCTAssertEqual(DownloadStore.safeName("ne:djradio:123"), "ne_djradio_123")
        XCTAssertEqual(DownloadStore.safeName("a/b\\c"), "a_b_c")
    }

    /// 启动时按索引恢复；文件还在的算已下载。
    @MainActor
    func testIndexRestoresExistingFiles() throws {
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"])

        let store = DownloadStore(directory: directory)

        XCTAssertTrue(store.isDownloaded("qq:1"))
        XCTAssertEqual(store.state(for: "qq:1"),
                       .downloaded(directory.appendingPathComponent("qq_1.flac")))
        XCTAssertEqual(store.state(for: "qq:2"), .none)
    }

    /// 文件被用户在 Finder 里删掉时，那条索引要一并清掉并重新落盘。
    @MainActor
    func testIndexDropsMissingFiles() throws {
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac", "qq:2": "qq_2.flac"])

        let store = DownloadStore(directory: directory)

        XCTAssertTrue(store.isDownloaded("qq:1"))
        XCTAssertEqual(store.state(for: "qq:2"), .none, "文件不在了就不算已下载")

        // 重新落盘过：再造一份也不会把丢失的那条读回来
        let reopened = DownloadStore(directory: directory)
        XCTAssertEqual(reopened.state(for: "qq:2"), .none)
        XCTAssertTrue(reopened.isDownloaded("qq:1"))
    }

    /// 移除下载：文件删掉、状态回到 none、索引里也不再有它。
    @MainActor
    func testRemoveDeletesFileAndEntry() throws {
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"])
        let store = DownloadStore(directory: directory)

        store.remove(ids: ["qq:1"])

        XCTAssertEqual(store.state(for: "qq:1"), .none)
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("qq_1.flac").path))
        XCTAssertEqual(DownloadStore(directory: directory).state(for: "qq:1"), .none)
    }

    // MARK: - 命名（保持「媒体」文件夹有序）

    /// 关着「保持有序」时是扁平的 `<安全化 id>.ext`（老形状，不变）。
    func testFlatNamingKeepsIDFileName() {
        let track = makeTrack("qq:0039MnYb", title: "傻鱼", artist: "告五人", album: "运气来得若有似无")
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "flac", organized: false),
                       "qq_0039MnYb.flac")
    }

    /// 开着时就是 `艺人/专辑/编号 标题.ext`，一个字符都不多——
    /// 末尾那截 id 短后缀（`-39MnYb`）是老解法，用户在 Finder 里天天看着它。
    func testOrganizedNamingUsesArtistAlbumTrackNumber() {
        var track = makeTrack("qq:0039MnYb", title: "傻鱼", artist: "告五人", album: "运气来得若有似无")
        track.trackNumber = 3
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "flac", organized: true),
                       "告五人/运气来得若有似无/03 傻鱼.flac")
    }

    /// 没有音轨号就不写编号；路径分隔符逐段安全化，不能让一首歌自己造出子目录。
    func testOrganizedNamingSanitizesEachComponent() {
        let track = makeTrack("qq:1", title: "A/B", artist: "AC/DC", album: "../etc")
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "mp3", organized: true),
                       "AC_DC/.._etc/A_B.mp3")
    }

    /// 音源常常不给专辑节点（QQ 搜索结果就没有），空的用「未知」顶，不能落成空目录名。
    func testOrganizedNamingFallsBackForMissingArtistAndAlbum() {
        var track = makeTrack("qq:1", title: "无名", artist: "", album: "")
        track.trackNumber = nil
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "m4a", organized: true),
                       "未知艺人/未知专辑/无名.m4a")
    }

    /// 撞名依次让位到 ` 1` / ` 2`（Finder、Music 的词汇）。名字不带后缀之后，
    /// 同一张碟里两首同名同编号的歌只能靠这条分开。
    func testCollidingNamesGetNumberedSuffixes() {
        var taken: Set<String> = []
        func claim(_ path: String) -> String {
            let free = DownloadStore.availablePath(path, isTaken: taken.contains)
            taken.insert(free)
            return free
        }
        XCTAssertEqual(claim("周杰伦/范特西/03 简单爱.flac"), "周杰伦/范特西/03 简单爱.flac")
        XCTAssertEqual(claim("周杰伦/范特西/03 简单爱.flac"), "周杰伦/范特西/03 简单爱 1.flac")
        XCTAssertEqual(claim("周杰伦/范特西/03 简单爱.flac"), "周杰伦/范特西/03 简单爱 2.flac")
        // 序号加在扩展名前面，别加到扩展名后面去
        XCTAssertFalse(taken.contains("周杰伦/范特西/03 简单爱.flac 1"))
    }

    /// 盘上那些索引不认得的文件也算「被占」（用户自己往「媒体」文件夹里拖过东西），
    /// **但自己那条除外**：重下要盖回自己上次落的地方，按「文件存在」一刀切
    /// 会让同一首歌每下一次多长一个 ` 1`。
    func testPlacementStepsAsideForUnindexedFileOnDisk() {
        let wanted = "周杰伦/叶惠美/03 晴天.flac"
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1", occupied: [:],
                                               exists: { $0 == wanted }),
                       "周杰伦/叶惠美/03 晴天 1.flac")
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1",
                                               occupied: ["qq:1": wanted],
                                               exists: { _ in true }),
                       wanted, "自己那份要盖回去，不能长出 ` 1`")
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1", occupied: [:],
                                               exists: { _ in false }),
                       wanted)
    }

    /// 让位的判据是**索引**不是「文件存在」：同一首歌重下要盖回自己那份，
    /// 每下一次多长一个 ` 1` 是最容易犯的那个错。
    func testPlacementOnlyStepsAsideForOtherTracks() {
        let wanted = "周杰伦/范特西/03 简单爱.flac"
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1",
                                               occupied: ["qq:1": wanted]),
                       wanted, "索引里那条就是它自己，重下盖回去")
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1",
                                               occupied: ["qq:2": wanted]),
                       "周杰伦/范特西/03 简单爱 1.flac", "被别的曲目占着才让位")
        XCTAssertEqual(DownloadStore.placement(
            of: wanted, for: "qq:1",
            occupied: ["qq:2": wanted, "qq:3": "周杰伦/范特西/03 简单爱 1.flac"]),
                       "周杰伦/范特西/03 简单爱 2.flac")
        XCTAssertEqual(DownloadStore.placement(of: wanted, for: "qq:1", occupied: [:]), wanted)
    }

    /// 走完整条落地路的对照：别的曲目已经占着这个名字，新下的这首排到 ` 1`。
    @MainActor
    func testDownloadStepsAsideForAnotherTracksName() async throws {
        let media = try makeDirectory("media")
        try write(file: "艺人/碟/歌.flac", index: ["qq:other": "艺人/碟/歌.flac"], in: media)
        let store = try makeFLACStore(organized: true, media: media)

        let placed = try await downloadOne(with: store)

        XCTAssertEqual(placed.lastPathComponent, "歌 1.flac")
        XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent("艺人/碟/歌.flac")),
                       Data("fLaC-test".utf8), "别人那份一个字节都不能动")
    }

    /// 索引快照是「文件 › 导入…」那条路的撞名判据（塞进 `ImportOptions.occupied`）。
    /// 下载来的与导入认领的混在同一份索引里，两条路才不会各占各的名字。
    @MainActor
    func testIndexedPathsCoversDownloadsAndAdoptedFiles() throws {
        let media = try makeDirectory("media")
        try write(file: "艺人/碟/歌.flac", index: ["qq:other": "艺人/碟/歌.flac"], in: media)
        let store = DownloadStore(directory: media, legacyDirectory: try makeDirectory("legacy"))
        XCTAssertEqual(store.indexedPaths, ["qq:other": "艺人/碟/歌.flac"])

        // 拷进「媒体」文件夹的导入产物：存相对路径，与下载来的同一套规矩。
        let copied = media.appendingPathComponent("艺人/碟/歌 1.flac")
        try Data("fLaC-copied".utf8).write(to: copied)
        store.adoptLocalFile(at: copied, for: makeTrack("local:a", title: "歌", artist: "艺人",
                                                        album: "碟"), external: false)
        // 原地引用的外部文件：存绝对路径，它不归「媒体」文件夹管。
        let outside = directory.appendingPathComponent("用户自己的歌.flac")
        try Data("fLaC-outside".utf8).write(to: outside)
        store.adoptLocalFile(at: outside, for: makeTrack("local:b", title: "歌", artist: "艺人",
                                                         album: "碟"), external: true)

        XCTAssertEqual(store.indexedPaths["local:a"], "艺人/碟/歌 1.flac")
        XCTAssertEqual(store.indexedPaths["local:b"], outside.standardizedFileURL.path)
    }

    // MARK: - 去掉老文件名里的 id 后缀

    /// 用户手上已经下好的那些还带着 `-<后缀>`，启动时原地改名，索引跟着更新。
    @MainActor
    func testRenameStripsLegacySuffixAndUpdatesIndex() throws {
        try write(file: "周杰伦/范特西/03 简单爱-1nRaad.flac",
                  index: ["qq:00xx1nRaad": "周杰伦/范特西/03 简单爱-1nRaad.flac"])
        let store = DownloadStore(directory: directory)

        store.renameLegacySuffixedFiles()

        XCTAssertTrue(exists("周杰伦/范特西/03 简单爱.flac", in: directory))
        XCTAssertFalse(exists("周杰伦/范特西/03 简单爱-1nRaad.flac", in: directory))
        XCTAssertEqual(store.state(for: "qq:00xx1nRaad"),
                       .downloaded(directory.appendingPathComponent("周杰伦/范特西/03 简单爱.flac")))
        XCTAssertEqual(try readIndex()["qq:00xx1nRaad"]?["path"] as? String,
                       "周杰伦/范特西/03 简单爱.flac", "索引要一起存盘，否则下次启动这首就没了")
        // 再跑一遍是空转（改完就没有条目再满足判据了）
        store.renameLegacySuffixedFiles()
        XCTAssertTrue(exists("周杰伦/范特西/03 简单爱.flac", in: directory))
    }

    /// 判据是「尾巴正好等于自己 id 的末 6 位」，不是「短横线 + 6 位」这个形状：
    /// 歌名里本来就带短横线的不能被切掉半截。
    func testStrippingSuffixLeavesRealHyphensAlone() {
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "巴赫/组曲/05 Rondo - II.flac",
                                                       id: "qq:0039Mn"),
                       nil, "歌名自带的短横线不是后缀")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "人/碟/歌-abcdef.flac",
                                                       id: "qq:00xxabcdef"),
                       "人/碟/歌.flac")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "人/碟/歌-abcdef.flac",
                                                       id: "qq:00xxABCDEF"),
                       nil, "尾巴跟这条的 id 对不上，那就不是我们加的")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "人/碟/-abcdef.flac",
                                                       id: "qq:00xxabcdef"),
                       nil, "改完只剩个空名字")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "qq_1-abcdef.flac",
                                                       id: "qq:1-abcdef"),
                       nil, "扁平模式按 id 命名本来就是设计，何况这里切下去只剩半截 id")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "MV/片子-abcdef.mp4",
                                                       id: DownloadStore.mvKey("00xxabcdef")),
                       nil, "MV 的落点照旧带后缀")
        XCTAssertEqual(DownloadStore.strippingIDSuffix(from: "/Users/me/Music/我的-abcdef.flac",
                                                       id: "local:00xxabcdef"),
                       nil, "外部条目是用户自己的文件，连名字都不能替他改")
    }

    /// 外部条目（「导入…」没勾拷贝的原地引用）连改名都不碰。
    @MainActor
    func testRenameSkipsExternalEntries() throws {
        let outside = try makeDirectory("用户自己的音乐")
        let external = outside.appendingPathComponent("原文件-abcdef.flac")
        try Data("fLaC-untouched".utf8).write(to: external)
        try writeIndex(["local:00xxabcdef": ["path": external.path, "bytes": 14, "date": 0]])
        let store = DownloadStore(directory: directory)

        store.renameLegacySuffixedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path),
                      "用户自己的文件一个字节都不能动，名字也是")
        XCTAssertEqual(store.state(for: "local:00xxabcdef"), .downloaded(external))
    }

    /// `mv:` 的键不参与：MV 的落点照旧带后缀。
    @MainActor
    func testRenameSkipsMVEntries() throws {
        let key = DownloadStore.mvKey("00xxabcdef")
        try write(file: "MV/片子-abcdef.mp4", index: [key: "MV/片子-abcdef.mp4"])
        let store = DownloadStore(directory: directory)

        store.renameLegacySuffixedFiles()

        XCTAssertTrue(exists("MV/片子-abcdef.mp4", in: directory))
    }

    /// 新名字已经被别人占着：留着旧名，谁都不覆盖。
    @MainActor
    func testRenameKeepsOldNameWhenTargetIsTaken() throws {
        try write(file: "人/碟/歌.flac", index: ["qq:other": "人/碟/歌.flac"])
        try write(file: "人/碟/歌-abcdef.flac", index: ["qq:00xxabcdef": "人/碟/歌-abcdef.flac"])
        try Data("别人的".utf8).write(to: directory.appendingPathComponent("人/碟/歌.flac"))
        let store = DownloadStore(directory: directory)

        store.renameLegacySuffixedFiles()

        XCTAssertTrue(exists("人/碟/歌-abcdef.flac", in: directory), "让不了位就留着旧名")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("人/碟/歌.flac")),
                       Data("别人的".utf8), "别人那份一个字节都不能动")
        XCTAssertEqual(try readIndex()["qq:00xxabcdef"]?["path"] as? String, "人/碟/歌-abcdef.flac")
    }

    /// 改名失败（文件压根不在）时索引不动：指向一个不存在的文件的话，
    /// 下次启动 `loadIndex` 会把那条清掉，那首歌就凭空变成「没下载」。
    @MainActor
    func testRenameFailureLeavesIndexUntouched() throws {
        try write(file: "人/碟/歌-abcdef.flac", index: ["qq:00xxabcdef": "人/碟/歌-abcdef.flac"])
        let store = DownloadStore(directory: directory)
        // store 已经认下这条了；绕过它把文件抽走，`moveItem` 必然失败
        try FileManager.default
            .removeItem(at: directory.appendingPathComponent("人/碟/歌-abcdef.flac"))

        store.renameLegacySuffixedFiles()

        XCTAssertEqual(try readIndex()["qq:00xxabcdef"]?["path"] as? String, "人/碟/歌-abcdef.flac")
        XCTAssertEqual(store.state(for: "qq:00xxabcdef"),
                       .downloaded(directory.appendingPathComponent("人/碟/歌-abcdef.flac")))
    }

    // MARK: - 换「媒体」文件夹

    /// 改路径：文件、index.json 一起搬过去，状态里的绝对 URL 跟着换，并回一句 toast。
    @MainActor
    func testChangingMediaFolderMovesEverything() throws {
        let source = try makeDirectory("A")
        let target = try makeDirectory("B")
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"], in: source)
        let settings = makeSettings(mediaFolder: source)
        let store = DownloadStore(directory: nil, legacyDirectory: try makeDirectory("legacy"),
                                  settings: settings)
        XCTAssertTrue(store.isDownloaded("qq:1"))
        var message: String?
        store.onMediaFolderChanged = { message = $0 }

        settings.values.mediaFolderPath = target.path

        XCTAssertEqual(store.state(for: "qq:1"),
                       .downloaded(target.appendingPathComponent("qq_1.flac")))
        XCTAssertTrue(exists("qq_1.flac", in: target))
        XCTAssertFalse(exists("qq_1.flac", in: source))
        XCTAssertTrue(exists("index.json", in: target))
        XCTAssertFalse(exists("index.json", in: source))
        XCTAssertNotNil(message, "搬完要有回音，否则只能去 Finder 里翻")
        // 新目录自己也认得这份索引（下次启动走的就是这条路）
        XCTAssertTrue(DownloadStore(directory: target).isDownloaded("qq:1"))
    }

    /// 有序命名下的子目录也要一起搬（索引里存的是带 `/` 的相对路径）。
    @MainActor
    func testChangingMediaFolderMovesNestedFiles() throws {
        let source = try makeDirectory("A")
        let target = try makeDirectory("B")
        try write(file: "告五人/某碟/03 傻鱼-9MnYb.flac",
                  index: ["qq:1": "告五人/某碟/03 傻鱼-9MnYb.flac"], in: source)
        let settings = makeSettings(mediaFolder: source)
        let store = DownloadStore(directory: nil, legacyDirectory: try makeDirectory("legacy"),
                                  settings: settings)

        settings.values.mediaFolderPath = target.path

        XCTAssertTrue(exists("告五人/某碟/03 傻鱼-9MnYb.flac", in: target))
        XCTAssertTrue(store.isDownloaded("qq:1"))
    }

    /// 首次启动的搬家：老落点（Application Support）有索引、新的没有，就整份搬过来一次。
    @MainActor
    func testLegacyDownloadsMoveIntoMediaFolder() throws {
        let legacy = try makeDirectory("legacy")
        let media = try makeDirectory("media")
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"], in: legacy)

        let store = DownloadStore(directory: nil, legacyDirectory: legacy,
                                  settings: makeSettings(mediaFolder: media))

        XCTAssertEqual(store.state(for: "qq:1"),
                       .downloaded(media.appendingPathComponent("qq_1.flac")))
        XCTAssertFalse(exists("qq_1.flac", in: legacy))
        XCTAssertFalse(exists("index.json", in: legacy), "老目录的索引也一并带走，不留第二份真值")
    }

    /// 新目录已经有索引了就不再碰老目录——搬家只做一次。
    @MainActor
    func testLegacyDownloadsIgnoredWhenMediaFolderHasIndex() throws {
        let legacy = try makeDirectory("legacy")
        let media = try makeDirectory("media")
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"], in: legacy)
        try write(file: "qq_2.flac", index: ["qq:2": "qq_2.flac"], in: media)

        let store = DownloadStore(directory: nil, legacyDirectory: legacy,
                                  settings: makeSettings(mediaFolder: media))

        XCTAssertTrue(store.isDownloaded("qq:2"))
        XCTAssertEqual(store.state(for: "qq:1"), .none)
        XCTAssertTrue(exists("qq_1.flac", in: legacy))
    }

    // MARK: - 落地回调

    /// 一首下完之后 `onDownloaded` 要带着**落地后的绝对路径**叫一次。
    /// `AppState` 就是靠它把新文件交给`LoudnessStore` 离线量响度的，
    /// 少这一声，已下载的歌就得先完整听一遍才有响度值。
    ///
    /// 「远端」用一条 `file://`：下载这条路只认 URL，不在乎它是不是 http。
    @MainActor
    func testOnDownloadedFiresWithPlacedURL() async throws {
        let remote = directory.appendingPathComponent("remote.bin")
        try Data("fLaC-payload".utf8).write(to: remote)
        let settings = makeSettings(mediaFolder: try makeDirectory("media"))
        settings.values.keepMediaFolderOrganized = false
        let store = DownloadStore(directory: nil, legacyDirectory: try makeDirectory("legacy"),
                                  settings: settings)
        store.resolveRemoteURL = { _ in remote }
        let placed = expectation(description: "onDownloaded")
        var received: (String, URL)?
        store.onDownloaded = { track, url in
            received = (track.id, url)
            placed.fulfill()
        }

        store.download([makeTrack("qq:1", title: "歌", artist: "艺人", album: "碟")])

        await fulfillment(of: [placed], timeout: 5)
        XCTAssertEqual(received?.0, "qq:1")
        // 扩展名按头字节判，落点是扁平命名（这次关掉了「保持有序」）
        XCTAssertEqual(received?.1.lastPathComponent, "qq_1.flac")
        XCTAssertEqual(store.state(for: "qq:1"), .downloaded(received!.1),
                       "回调里的 URL 就是索引里那一份，不是临时文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: received!.1.path))
    }

    // MARK: - 标签回填

    /// 挑条目的规矩：已补到当前版本的、`mv:` 的、外部引用的，一条都不碰。
    func testNeedsTagBackfillSkipsTaggedMVAndExternal() {
        let current = DownloadStore.tagWriterVersion
        XCTAssertTrue(DownloadStore.needsTagBackfill(key: "qq:1", path: "qq_1.flac",
                                                     tagged: nil, tagVersion: nil))
        XCTAssertFalse(DownloadStore.needsTagBackfill(key: "qq:1", path: "qq_1.flac",
                                                      tagged: true, tagVersion: current))
        XCTAssertFalse(DownloadStore.needsTagBackfill(key: DownloadStore.mvKey("1"),
                                                      path: "MV/x-1.mp4",
                                                      tagged: nil, tagVersion: nil),
                       "mv: 是视频，不走曲目这条路")
        XCTAssertFalse(DownloadStore.needsTagBackfill(key: "local:abc",
                                                      path: "/Users/me/Music/我的.flac",
                                                      tagged: nil, tagVersion: nil),
                       "外部条目是用户自己的文件，绝不能替他改")
    }

    /// 写入器升级之后，「补过但版本更老」的要重新排队——不重排的话用户手上那些
    /// 老文件永远等不到新加的那一层。
    func testNeedsTagBackfillRequeuesOlderWriterVersions() {
        func needs(_ tagged: Bool?, _ version: Int?) -> Bool {
            DownloadStore.needsTagBackfill(key: "qq:1", path: "qq_1.flac",
                                           tagged: tagged, tagVersion: version)
        }
        XCTAssertTrue(needs(true, nil), "老索引只有 tagged: true、没有版本号，那是版本 1 补的")
        XCTAssertTrue(needs(true, DownloadStore.tagWriterVersion - 1), "版本更老，要重排")
        XCTAssertFalse(needs(true, DownloadStore.tagWriterVersion), "已经是当前版本，别白改用户的文件")
        XCTAssertTrue(needs(nil, DownloadStore.tagWriterVersion),
                      "压根没补过，版本号是脏数据也不影响判定")
    }

    /// 没有写入器的容器不排队。挡在这里而不是等 `AudioTagWriter.write` 返回 false：
    /// 那时 `retag` 已经把整份文件复制成备份了，一份都写不成还每次启动白搬一遍磁盘。
    func testNeedsTagBackfillSkipsContainersWithoutAWriter() {
        for ext in ["flac", "ogg", "mp3", "m4a"] {
            XCTAssertTrue(DownloadStore.needsTagBackfill(key: "qq:1", path: "qq_1.\(ext)",
                                                         tagged: nil, tagVersion: nil),
                          "\(ext) 有写入器，该排队")
        }
        XCTAssertFalse(DownloadStore.needsTagBackfill(key: "qq:1", path: "qq_1.bin",
                                                      tagged: nil, tagVersion: nil),
                       "头字节认不出的容器落地成 .bin，没有写入器")
        XCTAssertTrue(DownloadStore.needsTagBackfill(key: "qq:1", path: "周杰伦/叶惠美/晴天-1.M4A",
                                                     tagged: nil, tagVersion: nil),
                      "扩展名大小写不该影响判定")
    }

    /// 外部条目（绝对路径 ＝「导入…」没勾拷贝的原地引用）一条都不排队。
    /// 对照组是同一份索引里的普通条目：它排上了，说明这条断言分得清两者。
    @MainActor
    func testBackfillSkipsExternalEntries() async throws {
        let outside = try makeDirectory("用户自己的音乐")
        let external = outside.appendingPathComponent("原文件.flac")
        try Data("fLaC-untouched".utf8).write(to: external)
        try writeIndex(["local:1": ["path": external.path, "bytes": 14, "date": 0]])
        let store = DownloadStore(directory: directory)

        store.backfillTags(for: [makeTrack("local:1", title: "歌", artist: "人", album: "碟")])

        XCTAssertNil(store.backfillTask, "外部条目不排队，压根不该起任务")
        XCTAssertEqual(try Data(contentsOf: external), Data("fLaC-untouched".utf8),
                       "用户自己的文件一个字节都不能动")

        // 对照：媒体文件夹里的普通条目就该排上队
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"])
        let normal = DownloadStore(directory: directory)
        normal.backfillTags(for: [makeTrack("qq:1", title: "歌", artist: "人", album: "碟")])
        XCTAssertNotNil(normal.backfillTask)
        await normal.backfillTask?.value
    }

    /// `mv:` 开头的键（视频跟曲目共用一份索引）不走回填。
    @MainActor
    func testBackfillSkipsMVEntries() throws {
        let key = DownloadStore.mvKey("1")
        try write(file: "MV/x-1.mp4", index: [key: "MV/x-1.mp4"])
        let store = DownloadStore(directory: directory)

        // 键长得跟 MV 一样的「曲目」：真实曲目 id 不会是这个形状，
        // 这里就是要验证那条 guard 拦不拦得住。
        store.backfillTags(for: [makeTrack(key, title: "片子", artist: "人", album: "")])

        XCTAssertNil(store.backfillTask)
    }

    /// `tagged` / `tagVersion` 都是后加的键：老索引（JSON 里没有它们）要照旧能解，
    /// 写回去时又不能把它们弄丢。
    @MainActor
    func testTaggedDecodesFromOldIndexAndRoundTrips() throws {
        try write(file: "qq_1.flac", index: ["qq:1": "qq_1.flac"])
        XCTAssertTrue(DownloadStore(directory: directory).isDownloaded("qq:1"),
                      "老索引缺 tagged 键也要解得出来，所以它必须是 Optional")

        // 「补过标签、但那是加版本号之前补的」——用户手上最常见的那种老条目
        try write(file: "qq_2.flac", index: ["qq:2": "qq_2.flac"], tagged: true)
        XCTAssertTrue(DownloadStore(directory: directory).isDownloaded("qq:2"),
                      "缺 tagVersion 键同样要解得出来")

        try write(file: "qq_3.flac", index: ["qq:3": "qq_3.flac"],
                  tagged: true, tagVersion: DownloadStore.tagWriterVersion)
        let store = DownloadStore(directory: directory)
        store.remove(ids: ["qq:none"])  // 借一次删除触发落盘

        XCTAssertEqual(try readIndex()["qq:2"]?["tagged"] as? Bool, true,
                       "已经补过的标记不能在下一次存盘时丢掉，否则每次启动都白补一遍")
        XCTAssertEqual(try readIndex()["qq:3"]?["tagVersion"] as? Int,
                       DownloadStore.tagWriterVersion,
                       "版本号也要原样写回去，否则下次启动又把它当老条目重排一遍")
    }

    /// 写标签砸了**不能**把下载标成失败：音频本身是好的。
    /// 「远端」是一段头字节像 FLAC、结构其实不成立的假文件，写入器一定抛错，正好走通这条路。
    @MainActor
    func testTagWriteFailureKeepsDownloadedState() async throws {
        let remote = directory.appendingPathComponent("remote.bin")
        try Data("fLaC 这不是一个真的 FLAC".utf8).write(to: remote)
        let media = try makeDirectory("media")
        let settings = makeSettings(mediaFolder: media)
        settings.values.keepMediaFolderOrganized = false
        let store = DownloadStore(directory: nil, legacyDirectory: try makeDirectory("legacy"),
                                  settings: settings)
        store.resolveRemoteURL = { _ in remote }
        let done = expectation(description: "onDownloaded")
        var placed: URL?
        store.onDownloaded = { _, url in
            placed = url
            done.fulfill()
        }

        store.download([makeTrack("qq:1", title: "歌", artist: "艺人", album: "碟")])

        await fulfillment(of: [done], timeout: 10)
        let url = try XCTUnwrap(placed)
        XCTAssertEqual(store.state(for: "qq:1"), .downloaded(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotEqual(try readIndex(in: media)["qq:1"]?["tagged"] as? Bool, true,
                          "没写成就不置位，下次启动的回填还要挑到它")
        XCTAssertNil(try readIndex(in: media)["qq:1"]?["tagVersion"],
                     "没写成就更不该留版本号：留着等于声称已经补到当前版本")
    }

    /// 新下的歌落地就记下当前写入器版本，下次启动的回填才不会把它们再挑一遍。
    @MainActor
    func testDownloadRecordsCurrentTagWriterVersion() async throws {
        let store = try makeFLACStore()

        _ = try await downloadOne(with: store)

        let entry = try XCTUnwrap(readIndex(in: try makeDirectory("media"))["qq:1"])
        XCTAssertEqual(entry["tagged"] as? Bool, true)
        XCTAssertEqual(entry["tagVersion"] as? Int, DownloadStore.tagWriterVersion)
    }

    // MARK: - 标签里的歌词

    /// 注入了 `resolveLyrics` 就把 LRC 写进标签里的歌词那一格。
    ///
    /// 这一条是**读回真文件**来验的：组 tags 那段不写进容器就等于没做，
    /// 而 FLAC 的 `LYRICS=` 是纯文本，把整份文件按 UTF-8 读回来就能找到它。
    @MainActor
    func testDownloadWritesLyricsIntoTags() async throws {
        let store = try makeFLACStore()
        store.resolveLyrics = { _ in
            [LyricLine(index: 0, time: 1, end: 3, text: "第一行"),
             LyricLine(index: 1, time: 3, end: 6, text: "第二行", translation: "line two")]
        }

        let url = try await downloadOne(with: store)

        let text = try fileText(at: url)
        XCTAssertTrue(text.contains("LYRICS=[00:01.00]第一行\n[00:03.00]第二行\n[00:03.00]line two"),
                      "正文与同时间戳的译文都要写进去")
        XCTAssertTrue(text.contains("TITLE=歌"), "歌词是加写的一格，别的标签照旧")
    }

    /// 没接 resolver：歌词那一格不写，下载照常成功。
    @MainActor
    func testDownloadWithoutLyricsResolverWritesNoLyricsTag() async throws {
        let store = try makeFLACStore()

        let url = try await downloadOne(with: store)

        let text = try fileText(at: url)
        XCTAssertFalse(text.contains("LYRICS="), "没有词就不该留一格空的")
        XCTAssertTrue(text.contains("TITLE=歌"))
        XCTAssertEqual(store.state(for: "qq:1"), .downloaded(url))
    }

    /// resolver 说「这首确认没有词」（空数组）也一样：不写这一格，状态照旧是已下载。
    @MainActor
    func testEmptyLyricsLeaveTagUnwritten() async throws {
        let store = try makeFLACStore()
        var asked = false
        store.resolveLyrics = { _ in
            asked = true
            return []
        }

        let url = try await downloadOne(with: store)

        XCTAssertTrue(asked, "问还是要问一次，只是这首没有词")
        XCTAssertFalse(try fileText(at: url).contains("LYRICS="))
        XCTAssertEqual(store.state(for: "qq:1"), .downloaded(url))
    }

    /// 取词慢（或干脆取不到，那条路上就是慢完返回空数组）不影响下载：
    /// 文件还是落地了，状态还是 `.downloaded`。歌词不该有权把一次成功的下载拖成失败。
    @MainActor
    func testSlowLyricsResolverKeepsDownloadedState() async throws {
        let store = try makeFLACStore()
        store.resolveLyrics = { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return []
        }

        let url = try await downloadOne(with: store)

        XCTAssertEqual(store.state(for: "qq:1"), .downloaded(url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 下载档位

    /// 下载走的是自己那一档，与流播放各夹各的；「下载杜比全景声」关掉＝跳过沉浸声。
    func testDownloadQualityClampsWithItsOwnSwitches() {
        var values = SettingsValues()
        values.downloadQuality = .atmos
        values.losslessEnabled = true
        values.downloadDolbyAtmos = true
        XCTAssertEqual(values.downloadStreamQuality, .atmos)

        values.downloadDolbyAtmos = false
        XCTAssertEqual(values.downloadStreamQuality, .surround,
                       "关掉下载杜比＝阶梯从无损那一侧的最高档起")

        values.losslessEnabled = false
        XCTAssertEqual(values.downloadStreamQuality.group, "有损",
                       "「启用无损音频」是全局封顶，下载这条路也受它管")

        // 流播放的杜比开关不参与下载的夹取（两个选择器在 Music 里本来就是分开的）
        values.losslessEnabled = true
        values.downloadDolbyAtmos = true
        values.dolbyAtmos = .off
        XCTAssertEqual(values.downloadStreamQuality, .atmos)
    }

    // MARK: - 造数据

    @MainActor
    private func makeSettings(mediaFolder: URL, _ name: String = #function) -> AppSettings {
        let suite = "DownloadStoreTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.values.mediaFolderPath = mediaFolder.path
        return settings
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ path: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    /// 造一台「远端给的是一份最小合法 FLAC」的下载 store。
    ///
    /// 别的用例给几个字节就够（它们只看落点与状态），歌词这一格却必须真写进容器才验得出来，
    /// 所以远端要能让 `FLACTagWriter` 走完整条路：魔数 + 一块 STREAMINFO（末块标志 + 34 字节）
    /// + 一点音频。写完把文件当文本读回来找 `LYRICS=`。
    ///
    /// `organized` / `media` 给验落点命名的那几条用：它们要的是有序摆法，
    /// 还要能先在媒体文件夹里放一条「别人的」索引条目。
    @MainActor
    private func makeFLACStore(_ name: String = #function, organized: Bool = false,
                              media: URL? = nil) throws -> DownloadStore {
        var flac = Data("fLaC".utf8)
        flac.append(contentsOf: [0x80, 0x00, 0x00, 0x22])
        flac.append(Data(repeating: 0, count: 34))
        flac.append(Data("audio".utf8))
        let remote = directory.appendingPathComponent("remote.flac")
        try flac.write(to: remote)

        let settings = makeSettings(mediaFolder: try media ?? makeDirectory("media"), name)
        settings.values.keepMediaFolderOrganized = organized
        let store = DownloadStore(directory: nil, legacyDirectory: try makeDirectory("legacy"),
                                  settings: settings)
        store.resolveRemoteURL = { _ in remote }
        return store
    }

    /// 下一首并等它落地，返回落点（`onDownloaded` 带的就是索引里那一份）。
    @MainActor
    private func downloadOne(with store: DownloadStore) async throws -> URL {
        let done = expectation(description: "onDownloaded")
        var placed: URL?
        store.onDownloaded = { _, url in
            placed = url
            done.fulfill()
        }
        store.download([makeTrack("qq:1", title: "歌", artist: "艺人", album: "碟")])
        await fulfillment(of: [done], timeout: 10)
        return try XCTUnwrap(placed)
    }

    /// 整份文件按 UTF-8 读回来。Vorbis comment 是纯文本，夹在二进制数据里也照样能找到；
    /// 解不出的字节交给 `String(decoding:as:)` 换成替换符，不影响找子串。
    private func fileText(at url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func makeTrack(_ id: String, title: String, artist: String, album: String) -> Track {
        Track(id: id, kind: .qq, title: title, artistName: artist, artistId: nil,
              albumName: album, albumId: "album", artworkURL: nil, duration: 200)
    }

    /// 造一份索引 + 其中一个文件。索引的形状与 `DownloadStore.Entry` 对齐
    /// （path / bytes / date / quality / tagged / tagVersion，date 走 JSONEncoder 的默认策略
    /// ＝参考日期秒数）。
    ///
    /// `tagged` / `tagVersion` 默认不写这两个键——用户手上的老索引就是这个样子，
    /// 大部分用例正好要的是那种形状。
    private func write(file: String, index: [String: String], in folder: URL? = nil,
                       tagged: Bool? = nil, tagVersion: Int? = nil) throws {
        let base = folder ?? directory!
        let target = base.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("fLaC-test".utf8).write(to: target)
        var entries = (try? readIndex(in: base)) ?? [:]
        for (id, path) in index {
            var entry: [String: Any] = ["path": path, "bytes": 9, "date": 0,
                                        "quality": "无损 · 44.1 kHz 16 位 FLAC"]
            if let tagged { entry["tagged"] = tagged }
            if let tagVersion { entry["tagVersion"] = tagVersion }
            entries[id] = entry
        }
        try writeIndex(entries, in: base)
    }

    /// 直接落一份索引 JSON。外部条目存的是绝对路径、文件也不在「媒体」文件夹里，
    /// 上面那个 helper 的「顺手造文件」帮不上忙。
    private func writeIndex(_ entries: [String: [String: Any]], in folder: URL? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: (folder ?? directory!).appendingPathComponent("index.json"))
    }

    private func readIndex(in folder: URL? = nil) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: (folder ?? directory!).appendingPathComponent("index.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }
}
