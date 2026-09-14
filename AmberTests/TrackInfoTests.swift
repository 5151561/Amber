import XCTest
@testable import Amber

/// 「显示简介」数据层的纯逻辑单测。
///
/// **不碰真实存档路径**：每个用例把 `TrackInfoStore` / `LibraryStore` 指到一个临时目录
/// （两个 store 的 `init(directory:)` 都是为此留的），跑完删掉。测试宿主就是 Amber 本身，
/// 走默认路径等于改用户真实资料库（见 memory `am-tests-share-real-defaults`）。
@MainActor
final class TrackInfoTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackInfoTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    private func makeTrack(id: String = "ne:1", title: String = "标题",
                           artist: String = "艺人", album: String = "专辑",
                           trackNumber: Int? = 3, discNumber: Int? = 1) -> Track {
        Track(id: id, kind: .netease, title: title, artistName: artist, artistId: nil,
              albumName: album, albumId: nil, artworkURL: nil, duration: 200,
              trackNumber: trackNumber, discNumber: discNumber)
    }

    // MARK: - TrackInfo 的编解码

    func testCodableRoundTrip() throws {
        var info = TrackInfo()
        info.title = "标题"
        info.artist = "艺人"
        info.album = "专辑"
        info.albumArtist = "专辑艺人"
        info.composer = "作曲者"
        info.showComposerInAllViews = true
        info.grouping = "归类"
        info.genre = "Mandopop"
        info.year = 2020
        info.trackNumber = 3
        info.trackCount = 12
        info.discNumber = 1
        info.discCount = 2
        info.isCompilation = true
        info.bpm = 128
        info.comments = "注释\n第二行"
        info.useWorkAndMovement = true
        info.workName = "作品名称"
        info.movementName = "乐章名称"
        info.movementNumber = 2
        info.movementCount = 4
        info.mediaKind = .audiobook
        info.startTimeEnabled = true
        info.startTime = 12.5
        info.stopTimeEnabled = true
        info.stopTime = 159.962
        info.rememberPlaybackPosition = true
        info.skipWhenShuffling = true
        info.volumeAdjustment = -102
        info.equalizerPreset = "摇滚乐"
        info.sortTitle = "sort 标题"
        info.sortAlbum = "sort 专辑"
        info.sortAlbumArtist = "sort 专辑艺人"
        info.sortArtist = "sort 艺人"
        info.sortComposer = "sort 作曲者"
        info.customLyrics = "第一句\n第二句"

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TrackInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    /// 手写 `init(from:)` 的用意：缺键要回落默认值，而不是整份解不出来。
    func testDecodeTolerAtesMissingKeys() throws {
        let data = Data(#"{"title":"只有标题","volumeAdjustment":51}"#.utf8)
        let decoded = try JSONDecoder().decode(TrackInfo.self, from: data)
        XCTAssertEqual(decoded.title, "只有标题")
        XCTAssertEqual(decoded.volumeAdjustment, 51)
        XCTAssertEqual(decoded.comments, "")
        XCTAssertEqual(decoded.mediaKind, .music)
        XCTAssertFalse(decoded.skipWhenShuffling)
        XCTAssertNil(decoded.stopTime)
        XCTAssertNil(decoded.customLyrics)
    }

    /// 空的 `{}` 也要能解出一份全默认的（旧存档、被截断的文件）。
    func testDecodeEmptyObject() throws {
        let decoded = try JSONDecoder().decode(TrackInfo.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TrackInfo())
    }

    // MARK: - info(for:) 现填

    func testInfoFallsBackToTrackFields() {
        let store = TrackInfoStore(directory: directory)
        let track = makeTrack()
        let info = store.info(for: track)
        XCTAssertEqual(info.title, "标题")
        XCTAssertEqual(info.artist, "艺人")
        XCTAssertEqual(info.album, "专辑")
        XCTAssertEqual(info.trackNumber, 3)
        XCTAssertEqual(info.discNumber, 1)
        XCTAssertEqual(info.comments, "")
        XCTAssertEqual(info.mediaKind, .music)
    }

    /// 编辑过之后，那五项仍然照资料库里的现值来（别处改过标题也得看得见）。
    func testInfoTakesTrackFieldsFromLiveTrack() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)

        var edited = store.info(for: track)
        edited.comments = "手打的注释"
        store.update(edited, for: track, library: library)

        let renamed = makeTrack(title: "改过的标题")
        XCTAssertEqual(store.info(for: renamed).title, "改过的标题")
        XCTAssertEqual(store.info(for: renamed).comments, "手打的注释")
    }

    // MARK: - update 的「没变就不写」

    func testUpdateWritesNothingWhenUnchanged() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)

        store.update(store.info(for: track), for: track, library: library)
        XCTAssertTrue(store.infos.isEmpty, "与 info(for:) 完全一致时不该落下任何一条")
    }

    func testUpdateSplitsTrackFieldsAndPanelFields() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)
        library.toggleFavorite(track)

        var edited = store.info(for: track)
        edited.title = "新标题"
        edited.album = "新专辑"
        edited.trackNumber = 7
        edited.comments = "注释"
        edited.volumeAdjustment = 153
        store.update(edited, for: track, library: library)

        // ① Track 本体那几项进了资料库
        XCTAssertEqual(library.libraryTracks.first?.title, "新标题")
        XCTAssertEqual(library.libraryTracks.first?.albumName, "新专辑")
        XCTAssertEqual(library.libraryTracks.first?.trackNumber, 7)
        // ② 其余落在自己的存档里
        XCTAssertEqual(store.infos[track.id]?.comments, "注释")
        XCTAssertEqual(store.infos[track.id]?.volumeAdjustment, 153)
    }

    /// 清空标题会把资料库里那一行变成空白，所以留了一道空值闸。[推]
    func testEmptyTitleKeepsOldTitle() {
        var track = makeTrack()
        var info = TrackInfo(track: track)
        info.title = "   "
        info.apply(to: &track)
        XCTAssertEqual(track.title, "标题")
    }

    // MARK: - updateTrack 四处同步

    func testUpdateTrackTouchesAllFourPlaces() {
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)
        library.toggleFavorite(track)
        library.noteStarted(track)
        let playlist = library.createPlaylist(name: "单子")
        library.addTracks([track], toPlaylist: playlist.id)

        let changed = library.updateTrack(id: track.id) { $0.title = "四处都要改" }
        XCTAssertTrue(changed)

        XCTAssertEqual(library.libraryTracks.first(where: { $0.id == track.id })?.title, "四处都要改")
        XCTAssertEqual(library.favoriteTracks.first(where: { $0.id == track.id })?.title, "四处都要改")
        XCTAssertEqual(library.recentTracks.first(where: { $0.id == track.id })?.title, "四处都要改")
        XCTAssertEqual(library.playlists.first?.tracks.first?.title, "四处都要改")
    }

    func testUpdateTrackIsNoOpWhenTransformChangesNothing() {
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)
        XCTAssertFalse(library.updateTrack(id: track.id) { $0.title = track.title })
        XCTAssertFalse(library.updateTrack(id: "不存在的 id") { $0.title = "x" })
    }

    // MARK: - 音量调整换算

    func testVolumeAdjustmentGain() {
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: 255),
                       PlaybackOverrides.fullScaleDB, accuracy: 1e-9)
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: -255),
                       -PlaybackOverrides.fullScaleDB, accuracy: 1e-9)
        // 线性：吸附档 51（= 20%）正好是满量程的五分之一
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: 51),
                       PlaybackOverrides.fullScaleDB / 5, accuracy: 1e-9)
        // 量程外夹住，别让手打进来的值把增益推上天
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: 9999),
                       PlaybackOverrides.fullScaleDB, accuracy: 1e-9)
        XCTAssertEqual(PlaybackOverrides.gainDB(forAdjustment: -9999),
                       -PlaybackOverrides.fullScaleDB, accuracy: 1e-9)
    }

    // MARK: - playbackOverrides 的取值

    func testPlaybackOverridesNilWhenNothingRelevant() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)

        var edited = store.info(for: track)
        edited.comments = "只改了注释"
        edited.sortArtist = "还有分类"
        store.update(edited, for: track, library: library)

        XCTAssertNil(store.playbackOverrides(for: track.id),
                     "播放这条路上与没编辑过等价时必须回 nil，播放器才走原来那条路")
    }

    func testPlaybackOverridesHonourCheckboxes() {
        var info = TrackInfo()
        info.startTime = 12
        info.stopTime = 100
        info.equalizerPreset = EqualizerPreset.none
        // 勾没勾上是开关：没勾时值一概不算数
        XCTAssertNil(PlaybackOverrides(info).startTime)
        XCTAssertNil(PlaybackOverrides(info).stopTime)
        XCTAssertNil(PlaybackOverrides(info).equalizerPreset)
        XCTAssertEqual(PlaybackOverrides(info), .neutral)

        info.startTimeEnabled = true
        info.stopTimeEnabled = true
        XCTAssertEqual(PlaybackOverrides(info).startTime, 12)
        XCTAssertEqual(PlaybackOverrides(info).stopTime, 100)
    }

    // MARK: - 随机播放时跳过（剔除逻辑）

    /// `PlayerController.buildShuffleOrder` 那条剔除规则的纯逻辑复刻：
    /// 剔完一首不剩时整份退回不剔的那一版。
    func testShuffleExclusion() {
        let ids = ["a", "b", "c"]
        func kept(_ skipped: Set<String>) -> [String] {
            let remaining = ids.filter { !skipped.contains($0) }
            return remaining.isEmpty ? ids : remaining
        }
        XCTAssertEqual(kept([]), ["a", "b", "c"])
        XCTAssertEqual(kept(["b"]), ["a", "c"])
        XCTAssertEqual(kept(["a", "b", "c"]), ["a", "b", "c"], "一首不剩时退回全量")
    }

    func testShuffleSkipFlagReachesOverrides() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)

        var edited = store.info(for: track)
        edited.skipWhenShuffling = true
        store.update(edited, for: track, library: library)

        XCTAssertEqual(store.playbackOverrides(for: track.id)?.skipWhenShuffling, true)
        XCTAssertNil(store.playbackOverrides(for: "别的 id"))
    }

    // MARK: - 记住播放位置

    func testResumePositionRoundTrip() {
        let store = TrackInfoStore(directory: directory)
        XCTAssertNil(store.resumePosition(for: "ne:1"))
        store.setResumePosition(42, for: "ne:1")
        XCTAssertEqual(store.resumePosition(for: "ne:1"), 42)
        // 播完整首报 nil ＝ 清掉
        store.setResumePosition(nil, for: "ne:1")
        XCTAssertNil(store.resumePosition(for: "ne:1"))
        // 非法值当清掉处理，别把 NaN 存进去
        store.setResumePosition(.nan, for: "ne:1")
        XCTAssertNil(store.resumePosition(for: "ne:1"))
    }

    /// 断点是状态不是设置：它不进 `TrackInfo`，所以不会把面板的「改了没有」搅浑。
    func testResumePositionIsNotPartOfTrackInfo() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)
        store.setResumePosition(42, for: track.id)

        store.update(store.info(for: track), for: track, library: library)
        XCTAssertTrue(store.infos.isEmpty)
    }

    // MARK: - 存档

    func testPersistsAcrossInstances() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)

        var edited = store.info(for: track)
        edited.comments = "落盘"
        edited.customLyrics = "自定义歌词"
        store.update(edited, for: track, library: library)
        store.setResumePosition(88, for: track.id)
        store.flushNow()

        let reopened = TrackInfoStore(directory: directory)
        XCTAssertEqual(reopened.infos[track.id]?.comments, "落盘")
        XCTAssertEqual(reopened.customLyrics(for: track.id), "自定义歌词")
        XCTAssertEqual(reopened.resumePosition(for: track.id), 88)
    }

    /// 存档另开一份 `trackinfo.json`，不塞进`library.json`。
    func testArchiveIsItsOwnFile() {
        let store = TrackInfoStore(directory: directory)
        let library = LibraryStore(directory: directory)
        let track = makeTrack()
        library.addToLibrary(track)
        var edited = store.info(for: track)
        edited.comments = "落盘"
        store.update(edited, for: track, library: library)
        store.flushNow()

        XCTAssertTrue(FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("trackinfo.json").path))
    }

    // MARK: - 均衡器预设名

    /// [AX] 实测 24 项 ＝ 首项「无」+ 一条分隔线 + 22 条预设。
    func testEqualizerPresetNames() {
        XCTAssertEqual(EqualizerPreset.names.count, 23)
        XCTAssertEqual(EqualizerPreset.names.first, "无")
        XCTAssertEqual(EqualizerPreset.names.last, "R&B")
        XCTAssertTrue(EqualizerPreset.isKnown("小型扬声器"))
        XCTAssertFalse(EqualizerPreset.isKnown("并不存在的预设"))
        XCTAssertEqual(Set(EqualizerPreset.names).count, EqualizerPreset.names.count)
    }

    func testMediaKindDisplayNames() {
        // [RES] 清单与顺序照 Music 自己那张 `res 241` 的前 9 条单选面板标题
        //（歌曲/电影/本地视频/电视节目/有声书/图书/播客/视频播客/音乐视频）。
        // 原先那 5 条是照 spec §4.4 一句散文写的，少了四种。
        XCTAssertEqual(TrackInfo.MediaKind.allCases.map(\.displayName),
                       ["音乐", "电影", "本地视频", "电视节目", "有声书",
                        "图书", "播客", "视频播客", "音乐视频"])
        // 每一种都有一份对应的面板标题（`res 241` 1–9），换媒体种类时窗口标题跟着换
        XCTAssertEqual(TrackInfo.MediaKind.music.panelTitle, "歌曲信息")
        XCTAssertEqual(TrackInfo.MediaKind.musicVideo.panelTitle, "音乐视频信息")
        XCTAssertEqual(Set(TrackInfo.MediaKind.allCases.map(\.panelTitle)).count,
                       TrackInfo.MediaKind.allCases.count)
    }
}
