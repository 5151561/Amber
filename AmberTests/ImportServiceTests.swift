import AVFoundation
import XCTest
@testable import Amber

/// 「文件 › 导入…」。三段分开测：
/// 1. 纯规则（转码与否、编码器 × 预置 → 目标参数、落点命名、结果文案）；
/// 2. 真读一个现造的 AIFF：元数据 → `Track`、按设置落地；
/// 3. 下载索引对本地文件的认领（外部文件不能被「从资料库移除」删掉）。
final class ImportServiceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 转码与否

    /// 源已经是所选编码器的格式就不重转（Music 导入一首 AAC 的 m4a 也不会再转一遍）。
    func testPlanSkipsTranscodeWhenFormatAlreadyMatches() {
        let aac = ImportSourceFormat(formatID: kAudioFormatMPEG4AAC, sampleRate: 44_100,
                                     channels: 2, fileExtension: "m4a")
        XCTAssertEqual(ImportPlan.decide(source: aac, encoder: .aac), .copyOriginal)
        // 同一个 m4a 容器里装的若是 ALAC，选 AAC 就得真转——只看扩展名会判错。
        var alac = aac
        alac.formatID = kAudioFormatAppleLossless
        XCTAssertEqual(ImportPlan.decide(source: alac, encoder: .aac),
                       .transcode(.aac, mp3Fallback: false))
        XCTAssertEqual(ImportPlan.decide(source: alac, encoder: .appleLossless), .copyOriginal)
    }

    /// PCM 还要容器对得上：wav 里的 PCM 选了 AIFF 编码器仍然要换容器。
    func testPlanChecksContainerForPCM() {
        let wav = ImportSourceFormat(formatID: kAudioFormatLinearPCM, sampleRate: 44_100,
                                     channels: 2, fileExtension: "wav")
        XCTAssertEqual(ImportPlan.decide(source: wav, encoder: .wav), .copyOriginal)
        XCTAssertEqual(ImportPlan.decide(source: wav, encoder: .aiff),
                       .transcode(.aiff, mp3Fallback: false))
    }

    /// 读不出 formatID 时回落到扩展名。
    func testPlanFallsBackToFileExtension() {
        let unknown = ImportSourceFormat(formatID: nil, sampleRate: 44_100, channels: 2,
                                         fileExtension: "m4a")
        XCTAssertEqual(ImportPlan.decide(source: unknown, encoder: .aac), .copyOriginal)
    }

    /// **Apple 没有 MP3 编码器**：选 MP3 时，本来就是 MP3 的原样进，其余回落 AAC 并提示。
    func testMP3FallsBackToAACExceptForMP3Sources() {
        let mp3 = ImportSourceFormat(formatID: kAudioFormatMPEGLayer3, sampleRate: 44_100,
                                     channels: 2, fileExtension: "mp3")
        XCTAssertEqual(ImportPlan.decide(source: mp3, encoder: .mp3), .copyOriginal)
        XCTAssertFalse(ImportPlan.decide(source: mp3, encoder: .mp3).mp3Fallback)

        let flac = ImportSourceFormat(formatID: kAudioFormatFLAC, sampleRate: 44_100,
                                      channels: 2, fileExtension: "flac")
        XCTAssertEqual(ImportPlan.decide(source: flac, encoder: .mp3),
                       .transcode(.aac, mp3Fallback: true))
        XCTAssertTrue(ImportPlan.decide(source: flac, encoder: .mp3).mp3Fallback)
    }

    // MARK: - 编码器 × 预置 → 目标参数

    /// 码率照「详细信息」那一框写的规格：iTunes Plus 单声道 128k / 立体声 256k，
    /// 高质量固定 128k，口述播客 64k 单声道。
    func testAACSpecFollowsPresetDetail() {
        let stereo = ImportSourceFormat(formatID: kAudioFormatMPEGLayer3, sampleRate: 48_000,
                                        channels: 2, fileExtension: "mp3")
        let mono = ImportSourceFormat(formatID: kAudioFormatMPEGLayer3, sampleRate: 48_000,
                                      channels: 1, fileExtension: "mp3")

        let plus = ImportOutputSpec.make(encoder: .aac, preset: .iTunesPlus, source: stereo)
        XCTAssertEqual(plus.bitRate, 256_000)
        XCTAssertEqual(plus.channels, 2)
        XCTAssertEqual(plus.sampleRate, 44_100, "AAC 三个预置的规格都写着 44.100 kHz")
        XCTAssertEqual(plus.fileExtension, "m4a")

        XCTAssertEqual(ImportOutputSpec.make(encoder: .aac, preset: .iTunesPlus, source: mono).bitRate,
                       128_000)
        // 「自定义…」在 Amber 里与 iTunes Plus 同规格（`detail(preset:)` 两格写的是同一行）
        XCTAssertEqual(ImportOutputSpec.make(encoder: .aac, preset: .custom, source: stereo),
                       plus)

        let high = ImportOutputSpec.make(encoder: .aac, preset: .highQuality, source: stereo)
        XCTAssertEqual(high.bitRate, 128_000)

        let spoken = ImportOutputSpec.make(encoder: .aac, preset: .spokenPodcast, source: stereo)
        XCTAssertEqual(spoken.bitRate, 64_000)
        XCTAssertEqual(spoken.channels, 1)
    }

    /// 无损/PCM 三档：ALAC 跟着源的采样率，AIFF/WAV 是 16 位 44.1k，端序相反。
    func testLosslessAndPCMSpecs() {
        let source = ImportSourceFormat(formatID: kAudioFormatMPEG4AAC, sampleRate: 48_000,
                                        channels: 2, fileExtension: "m4a")
        let alac = ImportOutputSpec.make(encoder: .appleLossless, preset: .iTunesPlus,
                                         source: source)
        XCTAssertEqual(alac.formatID, kAudioFormatAppleLossless)
        XCTAssertEqual(alac.sampleRate, 48_000, "无损要与源逐比特一致，不能重采样")
        XCTAssertNil(alac.bitRate)

        let aiff = ImportOutputSpec.make(encoder: .aiff, preset: .iTunesPlus, source: source)
        XCTAssertEqual(aiff.formatID, kAudioFormatLinearPCM)
        XCTAssertEqual(aiff.sampleRate, 44_100)
        XCTAssertEqual(aiff.bitDepth, 16)
        XCTAssertTrue(aiff.bigEndian)
        XCTAssertEqual(aiff.fileExtension, "aiff")

        let wav = ImportOutputSpec.make(encoder: .wav, preset: .iTunesPlus, source: source)
        XCTAssertFalse(wav.bigEndian)
        XCTAssertEqual(wav.fileExtension, "wav")

        // 写出去的设置里，端序与位深必须真的带上（否则 AIFF 会写成小端）
        XCTAssertEqual(aiff.writerSettings[AVLinearPCMIsBigEndianKey] as? Bool, true)
        XCTAssertEqual(wav.writerSettings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(plusBitRate(of: ImportOutputSpec.make(encoder: .aac, preset: .highQuality,
                                                             source: source)), 128_000)
    }

    private func plusBitRate(of spec: ImportOutputSpec) -> Int? {
        spec.writerSettings[AVEncoderBitRateKey] as? Int
    }

    // MARK: - 落点命名

    /// 落点与下载共用一套命名（`DownloadStore.relativePath`），两条路落进同一个文件夹，
    /// 摆法不该有两种。
    func testMediaFolderNamingMatchesDownloads() {
        let track = Track(id: "local:abc123def456", kind: .qq, title: "夜曲",
                          artistName: "周杰伦", artistId: nil, albumName: "十一月的萧邦",
                          albumId: nil, artworkURL: nil, duration: 230, trackNumber: 3)
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "m4a", organized: true),
                       "周杰伦/十一月的萧邦/03 夜曲.m4a")
        XCTAssertEqual(DownloadStore.relativePath(for: track, ext: "m4a", organized: false),
                       "local_abc123def456.m4a")
    }

    /// id 由源文件路径定：同一个文件导第二次必然是同一个 id，资料库那头自己挡掉。
    func testLocalIDIsDerivedFromSourcePath() {
        let a = ImportService.localID(forPath: "/Users/me/Music/a.flac")
        XCTAssertEqual(a, ImportService.localID(forPath: "/Users/me/Music/a.flac"))
        XCTAssertNotEqual(a, ImportService.localID(forPath: "/Users/me/Music/b.flac"))
        XCTAssertTrue(a.hasPrefix("local:"))
        XCTAssertEqual(a.count, "local:".count + 40, "SHA-1 十六进制是 40 位")
    }

    /// 归组键与专辑 id：同名不同艺人的专辑不能并到一起。
    func testAlbumGroupingKey() {
        let a = ImportService.albumKey(album: "Greatest Hits", artist: "Queen")
        let b = ImportService.albumKey(album: " greatest hits ", artist: "queen")
        let c = ImportService.albumKey(album: "Greatest Hits", artist: "ABBA")
        XCTAssertEqual(a, b, "大小写与前后空白不该分出两张碟")
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(ImportService.sha1(a), ImportService.sha1(c))
    }

    // MARK: - 音轨号

    func testTrackNumberParsing() {
        // iTunes 的 trkn：00 00 <序号 BE16> <总数 BE16>
        XCTAssertEqual(ImportWorker.number(fromData: Data([0, 0, 0, 3, 0, 12, 0, 0])), 3)
        XCTAssertEqual(ImportWorker.number(fromData: Data([0, 0, 1, 0, 0, 0, 0, 0])), 256)
        XCTAssertNil(ImportWorker.number(fromData: Data([0, 0, 0, 0])), "0 不是音轨号")
        XCTAssertNil(ImportWorker.number(fromData: Data([0, 0])))
        // ID3 的 TRCK："3" 或 "3/12"
        XCTAssertEqual(ImportWorker.number(fromText: "3/12"), 3)
        XCTAssertEqual(ImportWorker.number(fromText: " 7 "), 7)
        XCTAssertNil(ImportWorker.number(fromText: "封面"))
    }

    // MARK: - 结果文案

    func testSummaryMessage() {
        var summary = ImportService.Summary(imported: 3, skipped: 0, failed: 0, mp3Fallback: false)
        XCTAssertEqual(summary.message, "已导入 3 首")
        summary.failed = 1
        summary.skipped = 2
        XCTAssertEqual(summary.message, "已导入 3 首，2 首已在资料库，1 首失败")
        summary = ImportService.Summary(imported: 1, skipped: 0, failed: 0, mp3Fallback: true)
        XCTAssertEqual(summary.message, "已导入 1 首。macOS 没有 MP3 编码器，已按 AAC 导入")
    }

    // MARK: - 选文件

    func testFolderImportPicksAudioFilesRecursively() throws {
        let nested = directory.appendingPathComponent("碟/CD1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let song = try makeAIFF(at: nested.appendingPathComponent("02 第二首.aiff"))
        try Data("不是音频".utf8).write(to: nested.appendingPathComponent("cover.txt"))
        let first = try makeAIFF(at: nested.appendingPathComponent("01 第一首.aiff"))

        let files = ImportWorker.audioFiles(in: [directory])
        XCTAssertEqual(files.map(\.lastPathComponent),
                       [first.lastPathComponent, song.lastPathComponent],
                       "文件夹递归展开、非音频滤掉、按路径排序（曲序才稳）")
    }

    // MARK: - 真读一个文件

    /// 没有内嵌元数据时：标题回落文件名，艺人/专辑回落「未知」，时长从文件读。
    /// 源已经是 AIFF 且选了 AIFF 编码器 → 不转码，按「拷贝到媒体文件夹」落地。
    func testImportsAIFFWithoutMetadata() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("Emily.aiff"))
        let media = directory.appendingPathComponent("媒体", isDirectory: true)
        let options = makeOptions(encoder: .aiff, copy: true, mediaFolder: media)

        let imported = try await ImportWorker.process(source, options: options)
        XCTAssertEqual(imported.track.title, "Emily")
        XCTAssertEqual(imported.track.artistName, "未知艺人")
        XCTAssertEqual(imported.track.albumName, "未知专辑")
        XCTAssertEqual(imported.track.duration, 1, accuracy: 0.05)
        XCTAssertTrue(imported.track.isLocal)
        XCTAssertTrue(imported.track.id.hasPrefix("local:"))
        XCTAssertFalse(imported.external, "勾了「拷贝到媒体文件夹」就该是媒体文件夹里那份")
        XCTAssertTrue(imported.fileURL.path.hasPrefix(media.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "原件不该被搬走")
    }

    /// 不转码 + 不勾「拷贝到媒体文件夹」＝ 原地引用，媒体文件夹里一个文件都不多。
    func testImportKeepsFileInPlaceWhenCopyIsOff() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("在原处.aiff"))
        let media = directory.appendingPathComponent("媒体2", isDirectory: true)
        let options = makeOptions(encoder: .aiff, copy: false, mediaFolder: media)

        let imported = try await ImportWorker.process(source, options: options)
        XCTAssertTrue(imported.external)
        XCTAssertEqual(imported.fileURL.standardizedFileURL, source.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
    }

    /// 转码那条路：AIFF → AAC，产物**一定**落媒体文件夹（哪怕没勾拷贝——
    /// 它是 Amber 新造的文件，源目录里不该多出东西），且真的是 AAC。
    func testTranscodesToAACEvenWhenCopyIsOff() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("转码源.aiff"))
        let media = directory.appendingPathComponent("媒体3", isDirectory: true)
        let options = makeOptions(encoder: .aac, copy: false, mediaFolder: media)

        let imported = try await ImportWorker.process(source, options: options)
        XCTAssertFalse(imported.external)
        XCTAssertEqual(imported.fileURL.pathExtension, "m4a")
        XCTAssertTrue(imported.fileURL.path.hasPrefix(media.path))

        let format = await ImportWorker.sourceFormat(asset: AVURLAsset(url: imported.fileURL),
                                                     url: imported.fileURL)
        XCTAssertEqual(format.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(format.sampleRate, 44_100)
    }

    /// WAV 那一档：容器与端序都得对（AIFF 是大端，写反了播出来是噪音）。
    func testTranscodesToWAV() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("转 wav.aiff"))
        let media = directory.appendingPathComponent("媒体4", isDirectory: true)
        let options = makeOptions(encoder: .wav, copy: true, mediaFolder: media)

        let imported = try await ImportWorker.process(source, options: options)
        XCTAssertEqual(imported.fileURL.pathExtension, "wav")
        let file = try AVAudioFile(forReading: imported.fileURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
    }

    // MARK: - 撞名保护

    /// 落点名字不带 id 后缀之后，同碟同名同曲序的两首歌算出来是同一个落点。
    /// 后一首必须让位到 ` 1`，**前一首那份文件一个字节都不能被动**。
    ///
    /// `CD1`／`CD2` 都不算专辑名（见 `isNameLikeFolder`），两首都落进「未知艺人/未知专辑」。
    func testImportStepsAsideForAnotherTracksFile() async throws {
        let media = directory.appendingPathComponent("媒体10", isDirectory: true)
        let first = try makeAIFF(at: try makeSubdirectory("CD1")
            .appendingPathComponent("01 夜曲.aiff"), frequency: 440)
        let second = try makeAIFF(at: try makeSubdirectory("CD2")
            .appendingPathComponent("01 夜曲.aiff"), frequency: 660)

        var options = makeOptions(encoder: .aiff, copy: true, mediaFolder: media)
        let a = try await ImportWorker.process(first, options: options)
        XCTAssertEqual(a.fileURL.lastPathComponent, "01 夜曲.aiff")

        // 第一首落地之后由 `adoptLocalFile` 进下载索引，第二首拿到的快照里就有它了。
        options.occupied[a.track.id] = relativePath(of: a.fileURL, under: media)
        let b = try await ImportWorker.process(second, options: options)

        XCTAssertNotEqual(a.track.id, b.track.id, "两个源文件路径不同 → 两个 id")
        XCTAssertEqual(b.fileURL.lastPathComponent, "01 夜曲 1.aiff")
        XCTAssertEqual(try Data(contentsOf: a.fileURL), try Data(contentsOf: first),
                       "别人那份一个字节都不能动")
        XCTAssertEqual(try Data(contentsOf: b.fileURL), try Data(contentsOf: second))
    }

    /// 索引不认得、但确实躺在「媒体」文件夹里的文件（用户自己拖进去的那种）同样要让开。
    /// 让位比报错好：用户不会因为文件夹里碰巧有个同名文件就导不进来，
    /// 而人家那份一个字节都不会被动。
    func testImportStepsAsideForUnindexedFileOnDisk() async throws {
        let media = directory.appendingPathComponent("媒体18", isDirectory: true)
        let source = try makeAIFF(at: try makeSubdirectory("CD1")
            .appendingPathComponent("01 夜曲.aiff"), frequency: 660)
        // 先在落点上摆一个 Amber 从不知道的文件
        let squatter = media.appendingPathComponent("未知艺人/未知专辑/01 夜曲.aiff")
        try FileManager.default.createDirectory(at: squatter.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let squatterBytes = Data("我自己拖进来的".utf8)
        try squatterBytes.write(to: squatter)

        let options = makeOptions(encoder: .aiff, copy: true, mediaFolder: media)
        let imported = try await ImportWorker.process(source, options: options)

        XCTAssertEqual(imported.fileURL.lastPathComponent, "01 夜曲 1.aiff")
        XCTAssertEqual(try Data(contentsOf: squatter), squatterBytes,
                       "索引不认得的文件也不能被盖掉")
    }

    /// 同一首歌重导：索引里那条 path 记的就是它自己，盖回自己那份，
    /// **不能每导一次多长一个 ` 1`**（按「文件存在」判就会这样）。
    func testReimportOverwritesItsOwnFile() async throws {
        let media = directory.appendingPathComponent("媒体11", isDirectory: true)
        let source = try makeAIFF(at: try makeSubdirectory("CD1")
            .appendingPathComponent("01 夜曲.aiff"))

        var options = makeOptions(encoder: .aiff, copy: true, mediaFolder: media)
        let first = try await ImportWorker.process(source, options: options)
        options.occupied[first.track.id] = relativePath(of: first.fileURL, under: media)

        for _ in 0..<2 {
            let again = try await ImportWorker.process(source, options: options)
            XCTAssertEqual(again.fileURL, first.fileURL)
        }
        let folder = first.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       ["01 夜曲.aiff"], "重导只该有这一份")
    }

    /// 转码那条路的落点走的是同一层保护。真跑转码只为了证明产物确实落在让位后的名字上，
    /// 别的组合交给下面那条纯算路径的用例，不必一遍遍造大文件。
    func testTranscodeDestinationStepsAsideToo() async throws {
        let media = directory.appendingPathComponent("媒体12", isDirectory: true)
        let first = try makeAIFF(at: try makeSubdirectory("CD1")
            .appendingPathComponent("01 夜曲.aiff"), frequency: 440)
        let second = try makeAIFF(at: try makeSubdirectory("CD2")
            .appendingPathComponent("01 夜曲.aiff"), frequency: 660)

        var options = makeOptions(encoder: .aac, copy: false, mediaFolder: media)
        let a = try await ImportWorker.process(first, options: options)
        XCTAssertEqual(a.fileURL.lastPathComponent, "01 夜曲.m4a")
        let untouched = try Data(contentsOf: a.fileURL)

        options.occupied[a.track.id] = relativePath(of: a.fileURL, under: media)
        let b = try await ImportWorker.process(second, options: options)
        XCTAssertEqual(b.fileURL.lastPathComponent, "01 夜曲 1.m4a")
        XCTAssertEqual(try Data(contentsOf: a.fileURL), untouched,
                       "转码产物不能把别人那份盖了")
    }

    /// 落点这一层单独验：让位只对**别的**曲目发生，自己那条只判「是不是我的」。
    func testMediaFolderDestinationOnlyStepsAsideForOtherTracks() {
        let media = directory.appendingPathComponent("媒体13", isDirectory: true)
        let options = makeOptions(encoder: .aac, copy: true, mediaFolder: media)
        let track = Track(id: "local:a", kind: .qq, title: "夜曲", artistName: "周杰伦",
                          artistId: nil, albumName: "十一月的萧邦", albumId: nil,
                          artworkURL: nil, duration: 230, trackNumber: 3)
        let wanted = "周杰伦/十一月的萧邦/03 夜曲.m4a"

        var mine = options
        mine.occupied = ["local:a": wanted]
        let own = ImportWorker.mediaFolderDestination(for: track, ext: "m4a", options: mine)
        XCTAssertEqual(own.url, media.appendingPathComponent(wanted))
        XCTAssertTrue(own.isOwn, "索引里那条就是它自己 → 准覆盖")

        var others = options
        others.occupied = ["local:b": wanted]
        let stepped = ImportWorker.mediaFolderDestination(for: track, ext: "m4a", options: others)
        XCTAssertEqual(stepped.url.lastPathComponent, "03 夜曲 1.m4a")
        XCTAssertFalse(stepped.isOwn, "让位出来的是个新名字，谁的都不是")

        var empty = options
        empty.occupied = [:]
        let fresh = ImportWorker.mediaFolderDestination(for: track, ext: "m4a", options: empty)
        XCTAssertEqual(fresh.url, media.appendingPathComponent(wanted))
        XCTAssertFalse(fresh.isOwn)
    }

    /// 扁平模式按 id 命名，本来就撞不上：别的曲目占着什么都不该让这一首改名，
    /// 自己那条照旧认得出来。
    func testFlatNamingNeverStepsAside() {
        let media = directory.appendingPathComponent("媒体14", isDirectory: true)
        var options = makeOptions(encoder: .aac, copy: true, mediaFolder: media)
        options.organized = false
        let track = Track(id: "local:a", kind: .qq, title: "夜曲", artistName: "周杰伦",
                          artistId: nil, albumName: "十一月的萧邦", albumId: nil,
                          artworkURL: nil, duration: 230, trackNumber: 3)

        options.occupied = ["local:b": "local_b.m4a", "local:c": "周杰伦/十一月的萧邦/03 夜曲.m4a"]
        let placed = ImportWorker.mediaFolderDestination(for: track, ext: "m4a", options: options)
        XCTAssertEqual(placed.url, media.appendingPathComponent("local_a.m4a"))
        XCTAssertFalse(placed.isOwn)

        options.occupied["local:a"] = "local_a.m4a"
        let again = ImportWorker.mediaFolderDestination(for: track, ext: "m4a", options: options)
        XCTAssertEqual(again.url, media.appendingPathComponent("local_a.m4a"))
        XCTAssertTrue(again.isOwn, "重导盖回自己那份")
    }

    /// AIFF 与 ALAC 两档也要真写得出来：AIFF 是大端 PCM，端序写反了播出来就是噪音；
    /// ALAC 要跟着源的采样率走。源本身就是 AIFF，所以直接调转码器验这两条出口。
    func testExportsAIFFAndAppleLossless() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("出口.aiff"))
        let format = await ImportWorker.sourceFormat(asset: AVURLAsset(url: source), url: source)

        let aiff = directory.appendingPathComponent("out.aiff")
        try await ImportTranscoder.export(
            url: source, to: aiff,
            spec: ImportOutputSpec.make(encoder: .aiff, preset: .iTunesPlus, source: format))
        let written = try AVAudioFile(forReading: aiff)
        XCTAssertEqual(written.fileFormat.sampleRate, 44_100)
        let flags = written.fileFormat.streamDescription.pointee.mFormatFlags
        XCTAssertNotEqual(flags & kAudioFormatFlagIsBigEndian, 0, "AIFF 是大端 PCM")

        let alac = directory.appendingPathComponent("out.m4a")
        try await ImportTranscoder.export(
            url: source, to: alac,
            spec: ImportOutputSpec.make(encoder: .appleLossless, preset: .iTunesPlus,
                                        source: format))
        let alacFormat = await ImportWorker.sourceFormat(asset: AVURLAsset(url: alac), url: alac)
        XCTAssertEqual(alacFormat.formatID, kAudioFormatAppleLossless)
        XCTAssertEqual(alacFormat.sampleRate, 44_100)
    }

    /// 不是音频的文件不进资料库（哪怕扩展名骗人）——`process` 抛错，调用方记一笔失败。
    func testNonAudioFileFailsInsteadOfEnteringLibrary() async throws {
        let fake = directory.appendingPathComponent("其实是文本.aiff")
        try Data("这不是音频".utf8).write(to: fake)
        let options = makeOptions(encoder: .aiff, copy: true,
                                  mediaFolder: directory.appendingPathComponent("媒体7"))
        do {
            _ = try await ImportWorker.process(fake, options: options)
            XCTFail("坏文件不该导入成功")
        } catch {
            // 读不出音轨就该抛，具体是哪种错不重要
        }
    }

    // MARK: - 下载索引认领本地文件

    /// 认领之后歌曲表那几列全都当「已在本地」看；而**原地引用**的文件在「从资料库移除」
    /// 时不能跟着删——那是用户自己的文件。
    @MainActor
    func testAdoptedExternalFileSurvivesRemoval() throws {
        let media = directory.appendingPathComponent("媒体5", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let store = DownloadStore(directory: media, legacyDirectory: media)
        let outside = directory.appendingPathComponent("用户自己的歌.aiff")
        try Data("fake".utf8).write(to: outside)

        let track = Track(id: "local:deadbeef", kind: .qq, title: "歌", artistName: "人",
                          artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil,
                          duration: 1)
        store.adoptLocalFile(at: outside, for: track, external: true)
        XCTAssertTrue(store.isDownloaded(track.id))
        XCTAssertEqual(store.state(for: track.id), .downloaded(outside))

        store.remove(ids: [track.id])
        XCTAssertFalse(store.isDownloaded(track.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "原地引用的文件是用户的，移出资料库不该删它")
    }

    /// 拷进媒体文件夹的那份则照旧跟着删（它是 Amber 造出来的副本）。
    @MainActor
    func testAdoptedCopyIsDeletedWithTheTrack() throws {
        let media = directory.appendingPathComponent("媒体6", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let store = DownloadStore(directory: media, legacyDirectory: media)
        let copied = media.appendingPathComponent("人/碟/01 歌-eadbeef.aiff")
        try FileManager.default.createDirectory(at: copied.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: copied)

        let track = Track(id: "local:deadbeef", kind: .qq, title: "歌", artistName: "人",
                          artistId: nil, albumName: "碟", albumId: nil, artworkURL: nil,
                          duration: 1)
        store.adoptLocalFile(at: copied, for: track, external: false)
        store.remove(ids: [track.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testExternalPathDetection() {
        XCTAssertTrue(DownloadStore.isExternal("/Users/me/Music/a.mp3"))
        XCTAssertFalse(DownloadStore.isExternal("周杰伦/十一月的萧邦/03 夜曲-3def456.m4a"))
        XCTAssertFalse(DownloadStore.isExternal("qq_0039MnYb.flac"))
    }

    // MARK: - 文件名里的元信息

    /// 用户机器上真实存在的三个文件名（从音源下下来的那种，标签是空的）。
    ///
    /// 路径按**本机主目录**拼，`~/Music`、`~/Music/QQ音乐` 这两个落脚点要真的被认出来
    /// （`isNameLikeFolder` 里那条主目录判断认的是当前用户的主目录）。
    func testNameGuessOnRealWorldFilenames() {
        let music = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)

        // 1. QQ 音乐的杜比档：`标题 - 艺人 [音质标记]`。方括号里那个裸横杠要是不先摘掉，
        //    下一步切分就会被它带歪。
        let dolby = ImportNameGuess.guess(
            for: music.appendingPathComponent("月牙湾 - F.I.R.飞儿乐团 [杜比D003-最高码率].mp4"))
        XCTAssertEqual(dolby.title, "月牙湾")
        XCTAssertEqual(dolby.artist, "F.I.R.飞儿乐团")
        XCTAssertNil(dolby.album, "~/Music 是落脚点，不能当专辑名")

        // 2. 第三方下载器：`艺人-标题`（裸横杠）
        let bare = ImportNameGuess.guess(
            for: music.appendingPathComponent("QQ音乐/Imagine Dragons-Next To Me.mp4"))
        XCTAssertEqual(bare.artist, "Imagine Dragons")
        XCTAssertEqual(bare.title, "Next To Me")
        XCTAssertNil(bare.album, "QQ音乐 是下载目录，不是专辑")

        let thunder = ImportNameGuess.guess(
            for: music.appendingPathComponent("QQ音乐/Imagine Dragons-Thunder.flac"))
        XCTAssertEqual(thunder.artist, "Imagine Dragons")
        XCTAssertEqual(thunder.title, "Thunder")

        // 3. 整张碟拖进来：`…/艺人/专辑/01 标题.m4a`
        let inAlbum = ImportNameGuess.guess(
            for: music.appendingPathComponent("告五人/我们就像那些要命的傻瓜/01 城市之丘 Pyramid.m4a"))
        XCTAssertEqual(inAlbum.trackNumber, 1)
        XCTAssertEqual(inAlbum.title, "城市之丘 Pyramid")
        XCTAssertEqual(inAlbum.artist, "告五人")
        XCTAssertEqual(inAlbum.album, "我们就像那些要命的傻瓜")
    }

    /// 括号：方括号整段摘（音质标记），圆括号只摘噪声——`(with 五月天阿信)`、`(Live)`
    /// 是标题的一部分，摘了就丢信息。
    func testNoiseBracketsOnlyDropQualityTags() {
        XCTAssertEqual(ImportNameGuess.stripNoiseBrackets("晴天 [无损]"), "晴天")
        XCTAssertEqual(ImportNameGuess.stripNoiseBrackets("晴天【320K】"), "晴天")
        XCTAssertEqual(ImportNameGuess.stripNoiseBrackets("说好不哭 (with 五月天阿信)"),
                       "说好不哭 (with 五月天阿信)")
        XCTAssertEqual(ImportNameGuess.stripNoiseBrackets("夜曲 (Explicit)"), "夜曲")
    }

    /// 开头的曲序只认 1～3 位数且后面跟分隔符：`1989` 这种整条是标题的不能被啃掉一截。
    func testLeadingTrackNumber() {
        XCTAssertEqual(ImportNameGuess.leadingTrackNumber("01 城市之丘")?.0, 1)
        XCTAssertEqual(ImportNameGuess.leadingTrackNumber("07.夜曲")?.1, "夜曲")
        XCTAssertEqual(ImportNameGuess.leadingTrackNumber("12-Bonus")?.0, 12)
        XCTAssertNil(ImportNameGuess.leadingTrackNumber("1989 之歌"), "四位数是年份")
        XCTAssertNil(ImportNameGuess.leadingTrackNumber("晴天"))
    }

    /// 标签给了艺人时用它定切向；两半都不是艺人（`标题 - 版本`）就整条当标题，
    /// 别把「有梦版」当成艺人切走。
    func testTitleResolutionUsesKnownArtist() {
        let guess = ImportNameGuess.guess(for: URL(fileURLWithPath: "/tmp/我天生 - 有梦版.m4a"))
        XCTAssertEqual(guess.resolvedTitle(knownArtist: "告五人"), "我天生 - 有梦版")
        // 切反了（`艺人 - 标题`）也能纠回来
        let reversed = ImportNameGuess.guess(for: URL(fileURLWithPath: "/tmp/周杰伦 - 晴天.m4a"))
        XCTAssertEqual(reversed.resolvedTitle(knownArtist: "周杰伦"), "晴天")
        // 标签给的艺人正好是右半 → 切对了
        let normal = ImportNameGuess.guess(for: URL(fileURLWithPath: "/tmp/晴天 - 周杰伦.m4a"))
        XCTAssertEqual(normal.resolvedTitle(knownArtist: "周杰伦"), "晴天")
    }

    /// 目录只在「像专辑名」时才用：临时目录、光盘子目录、下载落脚点都不算。
    func testFolderGuessIgnoresGenericFolders() {
        func folder(_ path: String) -> Bool {
            ImportNameGuess.isNameLikeFolder(URL(fileURLWithPath: path))
        }
        XCTAssertTrue(folder("/Users/me/Music/告五人"))
        XCTAssertFalse(folder("/Users/me/Music"))
        XCTAssertFalse(folder("/Users/me/Music/QQ音乐"))
        XCTAssertFalse(folder("/var/folders/xx/T/AmberImportTests-3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        XCTAssertFalse(folder("/Users/me/Music/告五人/带你飞/CD1"))
    }

    /// 一个标签都没有的文件（QQ 的杜比 mp4 就是这样）走完整条导入路：
    /// 标题、艺人从文件名来，不再是「整条文件名 + 未知艺人」。
    func testImportFallsBackToFilenameWhenFileHasNoTags() async throws {
        let name = "月牙湾 - F.I.R.飞儿乐团 [杜比D003-最高码率].aiff"
        let source = try makeAIFF(at: directory.appendingPathComponent(name))
        let options = makeOptions(encoder: .aiff, copy: true,
                                  mediaFolder: directory.appendingPathComponent("媒体8"))
        let imported = try await ImportWorker.process(source, options: options)
        XCTAssertEqual(imported.track.title, "月牙湾")
        XCTAssertEqual(imported.track.artistName, "F.I.R.飞儿乐团")
        XCTAssertEqual(imported.track.albumName, "未知专辑")
    }

    // MARK: - 产物带标签

    /// 转码产物必须把标签与封面写进容器：不写的话文件本身是「无标题 / 未知艺人 / 没封面」，
    /// 访达、Music、别的播放器看到的全是空的（Amber 自己的资料库看着对，是因为那份信息
    /// 记在 library.json 里）。顺带验一遍读那一侧认得出 iTunes keyspace。
    func testTranscodedFileCarriesTagsAndArtwork() async throws {
        let source = try makeAIFF(at: directory.appendingPathComponent("带标签.aiff"))
        let format = await ImportWorker.sourceFormat(asset: AVURLAsset(url: source), url: source)
        let spec = ImportOutputSpec.make(encoder: .aac, preset: .iTunesPlus, source: format)
        let cover = try makeJPEG()
        let destination = directory.appendingPathComponent("tagged.m4a")

        try await ImportTranscoder.export(
            url: source, to: destination, spec: spec,
            metadata: ImportMetadata.items(for: spec.fileType, title: "晴天", artist: "周杰伦",
                                           album: "叶惠美", trackNumber: 7, discNumber: 1,
                                           artwork: cover))

        // 读回来：走导入自己的那套读法（通用键 → iTunes → ID3 → Vorbis）
        let asset = AVURLAsset(url: destination)
        let meta = try await ImportWorker.readMetadata(asset: asset, source: destination,
                                                       attempts: 1)
        XCTAssertEqual(meta.title, "晴天")
        XCTAssertEqual(meta.artist, "周杰伦")
        XCTAssertEqual(meta.album, "叶惠美")
        XCTAssertEqual(meta.trackNumber, 7)
        XCTAssertEqual(meta.discNumber, 1)
        XCTAssertNotNil(meta.artwork, "封面也要跟着进容器")
        XCTAssertTrue(ImportWorker.isImage(meta.artwork ?? Data()))

        // AIFF / WAV 容器不写标签块，塞进去只会让 startWriting 失败
        XCTAssertTrue(ImportMetadata.items(for: .aiff, title: "晴天", artist: "周杰伦",
                                           album: "叶惠美", trackNumber: nil, discNumber: nil,
                                           artwork: nil).isEmpty)
    }

    /// `trkn` / `disk` 那 8 个字节：写出去与读回来是同一套结构。
    func testTrackNumberBoxRoundTrips() {
        XCTAssertEqual(ImportWorker.number(fromData: ImportMetadata.numberBox(7)), 7)
        XCTAssertEqual(ImportWorker.number(fromData: ImportMetadata.numberBox(256)), 256)
    }

    /// FLAC 的 `METADATA_BLOCK_PICTURE`：AVFoundation 一般已经拆好了，
    /// 万一给的是整块，按结构再剥一层也要能剥出图来。
    func testFLACPictureBlockPayload() throws {
        let jpeg = try makeJPEG()
        var block = Data()
        func appendUInt32(_ value: Int) {
            block.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                                      UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        appendUInt32(3)                                   // 图片类型：封面
        let mime = Data("image/jpeg".utf8)
        appendUInt32(mime.count); block.append(mime)
        appendUInt32(0)                                   // 描述为空
        for _ in 0..<4 { appendUInt32(500) }              // 宽高位深色数
        appendUInt32(jpeg.count); block.append(jpeg)

        XCTAssertFalse(ImportWorker.isImage(block), "整块不是图片字节")
        XCTAssertEqual(ImportWorker.flacPicturePayload(block), jpeg)
    }

    /// 面板要能选中 mp4：那是 `public.mpeg-4`（audiovisualContent），
    /// 只列音频类型的话它在面板里是灰的，一首一首挑不了。
    func testPanelAcceptsMP4() {
        XCTAssertTrue(ImportWorker.panelContentTypes.contains(.mpeg4Movie))
        XCTAssertTrue(ImportWorker.panelContentTypes.contains(.audiovisualContent))
        XCTAssertTrue(ImportWorker.isAudioFile(URL(fileURLWithPath: "/tmp/a.mp4")))
    }

    // MARK: - 封面落到专辑那一格

    /// 内嵌封面不能只挂在曲目上：资料库的「专辑」「艺人」两页画的是 `Album.artworkURL`，
    /// 专辑那一格空着的话，导进来的碟在这两页上永远是占位方块。
    ///
    /// 三条一起验：整组取第一张有封面的、后到的那首把先前空着的专辑补上、
    /// 「未知专辑」这个杂物筐一格都不给（不同的歌混在一起，谁的封面都不算数）。
    @MainActor
    func testAlbumTakesTheCoverFromItsTracks() throws {
        let store = LibraryStore(directory: directory.appendingPathComponent("库", isDirectory: true))
        let cover = "file:///tmp/cover.jpg"

        func track(_ id: String, album: String, artwork: String?) -> Track {
            Track(id: "local:" + id, kind: .qq, title: id, artistName: "告五人",
                  artistId: nil, albumName: album, albumId: nil, artworkURL: artwork, duration: 1)
        }
        func album(_ name: String, artwork: String?) -> Album {
            Album(id: Album.localIDPrefix + ImportService.sha1(name), kind: .qq, name: name,
                  artistName: "告五人", artistId: nil, artworkURL: artwork,
                  publishDate: nil, trackCount: 1, description: nil)
        }

        // 1. 第一首没有内嵌图，整张碟先进来
        store.addAlbumToLibrary(album("又到天黑", artwork: nil),
                                tracks: [track("a", album: "又到天黑", artwork: nil)])
        XCTAssertNil(store.libraryAlbums.first { $0.name == "又到天黑" }?.artworkURL)

        // 2. 同一张碟里带内嵌图的那首后到：专辑那一格要被补上，别让它一直空着
        store.addAlbumToLibrary(album("又到天黑", artwork: cover),
                                tracks: [track("b", album: "又到天黑", artwork: cover)])
        XCTAssertEqual(store.libraryAlbums.first { $0.name == "又到天黑" }?.artworkURL, cover)

        // 3. 已经有封面的不被后来的覆盖（用户改过的评分、喜爱都挂在原条目上，整条换掉会丢）
        store.addAlbumToLibrary(album("又到天黑", artwork: "file:///tmp/别的.jpg"),
                                tracks: [track("c", album: "又到天黑", artwork: nil)])
        XCTAssertEqual(store.libraryAlbums.first { $0.name == "又到天黑" }?.artworkURL, cover)
    }

    // MARK: - 工具

    /// 现造一张 8×8 的 JPEG 当封面
    private func makeJPEG() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            throw ImportError.writeFailed("造不出封面")
        }
        return jpeg
    }

    private func makeOptions(encoder: ImportEncoder, copy: Bool,
                             mediaFolder: URL) -> ImportOptions {
        ImportOptions(encoder: encoder, preset: .iTunesPlus, errorCorrection: false,
                      copyToMediaFolder: copy, organized: true, mediaFolder: mediaFolder,
                      artworkFolder: directory.appendingPathComponent("Artwork"), kind: .qq)
    }

    /// 落点折回相对「媒体」文件夹的路径——索引里存的就是这个形状
    /// （见 `DownloadStore.adoptLocalFile`），撞名判据要的也是它。
    private func relativePath(of url: URL, under media: URL) -> String {
        String(url.standardizedFileURL.path
            .dropFirst(media.standardizedFileURL.path.count + 1))
    }

    /// 造一个子目录并返回它（撞名那几条要把同名文件摆进不同目录里）。
    private func makeSubdirectory(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 现造一个 1 秒 44.1k 立体声 AIFF（16 位）：音乐光盘挂上来的就是这种文件。
    ///
    /// `frequency` 只给撞名那几条用：要断言「别人那份没被动过」就得让两个文件的字节
    /// 真的不一样，两份一模一样的正弦谁盖了谁都看不出来。
    @discardableResult
    private func makeAIFF(at url: URL, frequency: Double = 440) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames) else {
            throw ImportError.writeFailed("造不出缓冲区")
        }
        buffer.frameLength = frames
        // 正弦：全零的静音也能过，但编码器对静音的处理与真信号不同，
        // 用真信号才验得到「转出来的还是一首歌」。
        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(frames) {
                let value = Float(sin(2 * Double.pi * frequency * Double(frame) / 44_100)) * 0.5
                for channel in 0..<Int(buffer.format.channelCount) {
                    channels[channel][frame] = value
                }
            }
        }
        try file.write(from: buffer)
        return url
    }
}
