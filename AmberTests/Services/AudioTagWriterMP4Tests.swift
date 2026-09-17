import AVFoundation
import AppKit
import XCTest
@testable import Amber

/// 下载落地的是音源 CDN 的裸流，`moov/udta/meta/ilst` 里只有一条 `----`/`iTunSMPB`。
/// 这里锁住补写标签这一步的三件事：写进去的东西 AVFoundation 读得回来、文件还能正常打开、
/// 以及**别人的东西不许动**——已有的 atom 要留着，重复写不许叠加，
/// `moov` 在 `mdat` 前面时 `stco`/`co64` 的绝对偏移要跟着修正。
///
/// 夹具全部自己造：机器上没有 ffmpeg/lame，只有 `/usr/bin/afconvert` 和 AVFoundation，
/// 更不能去读用户 ~/Music 里的文件。
final class AudioTagWriterMP4Tests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioTagWriterMP4Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - 真文件

    func testWritesTagsIntoRealM4A() async throws {
        let url = try makeM4A()
        let before = try await AVURLAsset(url: url).load(.duration)
        // afconvert 出来的 m4a 是 moov 在前、mdat 在后（见 topLevelTypes 断言），
        // 所以这条用例顺带就是「chunk 偏移修正做对了没有」的实机验收：
        // 修错了 AVFoundation 会读不到样本、时长直接变 0。
        XCTAssertLessThan(try index(of: "moov", in: url), try index(of: "mdat", in: url))

        let artwork = try makePNG()
        var tags = AudioTags()
        tags.title = "夜曲"
        tags.artist = "周杰伦"
        tags.albumArtist = "周杰伦"
        tags.album = "十一月的萧邦"
        tags.trackNumber = 3
        tags.trackTotal = 12
        tags.discNumber = 1
        tags.discTotal = 2
        tags.year = "2005"
        tags.genre = "流行"
        tags.lyrics = "为你弹奏萧邦的夜曲"
        tags.artwork = artwork
        tags.artworkMIME = "image/png"
        try MP4TagWriter.write(tags, to: url)

        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata)
        let title = try await string(items, .iTunesMetadataSongName)
        let artist = try await string(items, .iTunesMetadataArtist)
        let albumArtist = try await string(items, .iTunesMetadataAlbumArtist)
        let album = try await string(items, .iTunesMetadataAlbum)
        let year = try await string(items, .iTunesMetadataReleaseDate)
        let genre = try await string(items, .iTunesMetadataUserGenre)
        let lyrics = try await string(items, .iTunesMetadataLyrics)
        let track = try await pair(items, .iTunesMetadataTrackNumber)
        let disc = try await pair(items, .iTunesMetadataDiscNumber)
        let cover = try await data(items, .iTunesMetadataCoverArt)
        XCTAssertEqual(title, "夜曲")
        XCTAssertEqual(artist, "周杰伦")
        XCTAssertEqual(albumArtist, "周杰伦")
        XCTAssertEqual(album, "十一月的萧邦")
        XCTAssertEqual(year, "2005")
        XCTAssertEqual(genre, "流行")
        XCTAssertEqual(lyrics, "为你弹奏萧邦的夜曲")
        XCTAssertEqual(track?.0, 3)
        XCTAssertEqual(track?.1, 12)
        XCTAssertEqual(disc?.0, 1)
        XCTAssertEqual(disc?.1, 2)
        XCTAssertEqual(cover, artwork)

        // 文件还得是能播的：时长一秒不差，音轨还在
        let after = try await asset.load(.duration)
        XCTAssertTrue(after.isNumeric && after.seconds > 0)
        XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    func testSecondWriteReplacesInsteadOfAppending() async throws {
        let url = try makeM4A()
        // afconvert（Apple 的 AAC 编码器）一定会写这条：编码器前后填充的样本数，
        // 播放器靠它做无缝拼接。我们不认识它，就必须原样留着。
        XCTAssertTrue(try ilstTypes(of: url).contains("----"))

        var tags = AudioTags()
        tags.title = "第一次"
        tags.artist = "甲"
        try MP4TagWriter.write(tags, to: url)
        tags.title = "第二次"
        try MP4TagWriter.write(tags, to: url)

        let types = try ilstTypes(of: url)
        XCTAssertEqual(types.filter { $0 == "\u{A9}nam" }.count, 1, "同名 atom 只许留一份")
        XCTAssertEqual(types.filter { $0 == "\u{A9}ART" }.count, 1)
        XCTAssertTrue(types.contains("----"), "不认识的 atom（iTunSMPB）不许被冲掉")

        let items = try await AVURLAsset(url: url).load(.metadata)
        let title = try await string(items, .iTunesMetadataSongName)
        XCTAssertEqual(title, "第二次")
        XCTAssertEqual(AVMetadataItem.metadataItems(from: items,
                                                    filteredByIdentifier: .iTunesMetadataSongName)
            .count, 1)
    }

    func testWithoutArtworkWritesTextOnly() async throws {
        let url = try makeM4A()
        var tags = AudioTags()
        tags.title = "只有字"
        try MP4TagWriter.write(tags, to: url)

        let types = try ilstTypes(of: url)
        XCTAssertTrue(types.contains("\u{A9}nam"))
        XCTAssertFalse(types.contains("covr"), "没有封面就不该凭空造一个空 covr")
        XCTAssertFalse(types.contains("trkn"), "曲序为空时不写 trkn，别写成 0/0")
    }

    // MARK: - 手工夹具：moov 在前 / co64 / 分片

    func testMoovBeforeMdatShiftsChunkOffsets() throws {
        let url = directory.appendingPathComponent("moov-first.mp4")
        let (fixture, stcoValue, co64Value) = makeMoovFirstFixture()
        try fixture.write(to: url)
        let oldMoovSize = try boxSize(of: "moov", in: url)

        var tags = AudioTags()
        tags.title = "把 moov 撑长"
        tags.album = "这样 mdat 就得后移"
        try MP4TagWriter.write(tags, to: url)

        let newMoovSize = try boxSize(of: "moov", in: url)
        let delta = newMoovSize - oldMoovSize
        XCTAssertGreaterThan(delta, 0)
        let (stco, co64) = try chunkOffsets(of: url)
        XCTAssertEqual(stco, [stcoValue + delta], "stco 的 32 位偏移要跟着 moov 的增量走")
        XCTAssertEqual(co64, [co64Value + delta], "co64 的 64 位偏移同理")
        // 偏移改完之后确实还落在 mdat 正文上
        XCTAssertEqual(try index(of: "mdat", in: url) + 8, stcoValue + delta)
    }

    func testFragmentedMP4IsUnsupported() throws {
        let url = directory.appendingPathComponent("fragmented.mp4")
        var data = box("ftyp", Data("isomiso2".utf8))
        data.append(box("moov", box("mvhd", Data(repeating: 0, count: 100))))
        data.append(box("moof", Data(repeating: 0, count: 32)))
        data.append(box("mdat", Data(repeating: 7, count: 64)))
        try data.write(to: url)

        var tags = AudioTags()
        tags.title = "分片"
        XCTAssertThrowsError(try MP4TagWriter.write(tags, to: url)) { error in
            guard case AudioTagWriteError.unsupported = error else {
                return XCTFail("分片 MP4 应当报 unsupported，实际是 \(error)")
            }
        }
        // 报错的那条路不许留下半个文件，也不许动原文件
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       ["fragmented.mp4"])
    }

    // MARK: - 夹具

    /// 用 `/usr/bin/afconvert` 把手工拼的 WAV 转成真 m4a。机器上没有别的编码器可用。
    private func makeM4A() throws -> URL {
        let converter = "/usr/bin/afconvert"
        guard FileManager.default.isExecutableFile(atPath: converter) else {
            throw XCTSkip("这台机器上没有 afconvert，造不出真 m4a 夹具")
        }
        let wav = directory.appendingPathComponent("fixture.wav")
        try makeWAV().write(to: wav)
        let m4a = directory.appendingPathComponent("fixture.m4a")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: converter)
        process.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: m4a.path) else {
            throw XCTSkip("afconvert 转码失败（退出码 \(process.terminationStatus)）")
        }
        try FileManager.default.removeItem(at: wav)
        return m4a
    }

    /// 1 秒 44.1 kHz 单声道 16 位正弦波。全静音也行，但给点信号更像真文件。
    private func makeWAV() -> Data {
        let rate = 44_100
        var samples = Data()
        for index in 0..<rate {
            let value = Int16(8_000 * sin(2 * .pi * 440 * Double(index) / Double(rate)))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        var data = Data("RIFF".utf8)
        data.append(le32(UInt32(36 + samples.count)))
        data.append(Data("WAVEfmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))            // PCM
        data.append(le16(1))            // 单声道
        data.append(le32(UInt32(rate)))
        data.append(le32(UInt32(rate * 2)))
        data.append(le16(2))
        data.append(le16(16))
        data.append(Data("data".utf8))
        data.append(le32(UInt32(samples.count)))
        data.append(samples)
        return data
    }

    private func makePNG() throws -> Data {
        let rep = unsafe try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// `ftyp + moov(两条 trak，一条用 stco 一条用 co64) + mdat`，moov 排在 mdat 前面。
    /// 不求能播，只求偏移表是真的指着 mdat 正文——这是 chunk 偏移修正唯一要验的东西。
    private func makeMoovFirstFixture() -> (data: Data, stco: Int, co64: Int) {
        let ftyp = box("ftyp", Data("isomiso2avc1mp41".utf8))
        func moov(stco stcoValue: Int, co64 co64Value: Int) -> Data {
            var stcoBody = Data([0, 0, 0, 0]); stcoBody.append(be32(1))
            stcoBody.append(be32(UInt32(stcoValue)))
            var co64Body = Data([0, 0, 0, 0]); co64Body.append(be32(1))
            co64Body.append(be32(UInt32(co64Value >> 32))); co64Body.append(be32(UInt32(co64Value & 0xFFFF_FFFF)))
            func trak(_ table: Data) -> Data {
                box("trak", box("mdia", box("minf", box("stbl", table))))
            }
            var payload = box("mvhd", Data(repeating: 0, count: 100))
            payload.append(trak(box("stco", stcoBody)))
            payload.append(trak(box("co64", co64Body)))
            return box("moov", payload)
        }
        // 先用占位值量出 moov 的长度，再把真正的 mdat 正文偏移填回去（长度不受数值影响）
        let probe = moov(stco: 0, co64: 0)
        let dataOffset = ftyp.count + probe.count + 8
        var file = ftyp
        file.append(moov(stco: dataOffset, co64: dataOffset))
        file.append(box("mdat", Data(repeating: 0x5A, count: 512)))
        return (file, dataOffset, dataOffset)
    }

    // MARK: - 独立的解析器（故意不复用实现里那套）

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = be32(UInt32(payload.count + 8))
        data.append(type.data(using: .isoLatin1)!)
        data.append(payload)
        return data
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
              UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF),
              UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private func read32(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(data[data.startIndex + offset + $1]) }
    }

    private func type(_ data: Data, _ offset: Int) -> String {
        String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .isoLatin1) ?? ""
    }

    /// 顶层 box 的 (类型, 起点, 长度)。
    private func topBoxes(_ data: Data) -> [(type: String, offset: Int, size: Int)] {
        var result: [(String, Int, Int)] = []
        var offset = 0
        while offset + 8 <= data.count {
            var size = read32(data, offset)
            if size == 1 { size = (0..<8).reduce(0) { $0 << 8 | Int(data[offset + 8 + $1]) } }
            if size == 0 { size = data.count - offset }
            guard size >= 8, offset + size <= data.count else { break }
            result.append((type(data, offset), offset, size))
            offset += size
        }
        return result
    }

    private func index(of type: String, in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(topBoxes(data).first { $0.type == type }?.offset)
    }

    private func boxSize(of type: String, in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(topBoxes(data).first { $0.type == type }?.size)
    }

    /// 逐层钻到 `moov/udta/meta/ilst`，列出它下面每个 atom 的类型。
    private func ilstTypes(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let moov = try XCTUnwrap(topBoxes(data).first { $0.type == "moov" })
        var range = (moov.offset + 8)..<(moov.offset + moov.size)
        for (name, header) in [("udta", 8), ("meta", 12)] {
            var found: Range<Int>?
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                let size = read32(data, offset)
                guard size >= 8, offset + size <= range.upperBound else { break }
                if type(data, offset) == name { found = (offset + header)..<(offset + size); break }
                offset += size
            }
            range = try XCTUnwrap(found, "moov 里找不到 \(name)")
        }
        var offset = range.lowerBound
        var ilst: Range<Int>?
        while offset + 8 <= range.upperBound {
            let size = read32(data, offset)
            guard size >= 8, offset + size <= range.upperBound else { break }
            if type(data, offset) == "ilst" { ilst = (offset + 8)..<(offset + size); break }
            offset += size
        }
        let body = try XCTUnwrap(ilst, "meta 里找不到 ilst")
        var types: [String] = []
        offset = body.lowerBound
        while offset + 8 <= body.upperBound {
            let size = read32(data, offset)
            guard size >= 8, offset + size <= body.upperBound else { break }
            types.append(type(data, offset))
            offset += size
        }
        return types
    }

    /// 把 moov 里所有 stco / co64 的条目读出来。
    private func chunkOffsets(of url: URL) throws -> (stco: [Int], co64: [Int]) {
        let data = try Data(contentsOf: url)
        var stco: [Int] = []
        var co64: [Int] = []
        func walk(_ range: Range<Int>) {
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                let size = read32(data, offset)
                guard size >= 8, offset + size <= range.upperBound else { return }
                let name = type(data, offset)
                let body = (offset + 8)..<(offset + size)
                if ["moov", "trak", "mdia", "minf", "stbl"].contains(name) {
                    walk(body)
                } else if name == "stco" || name == "co64" {
                    let count = read32(data, body.lowerBound + 4)
                    let wide = name == "co64"
                    for entry in 0..<count {
                        let at = body.lowerBound + 8 + entry * (wide ? 8 : 4)
                        let value = wide
                            ? (0..<8).reduce(0) { $0 << 8 | Int(data[at + $1]) }
                            : read32(data, at)
                        if wide { co64.append(value) } else { stco.append(value) }
                    }
                }
                offset += size
            }
        }
        if let moov = topBoxes(data).first(where: { $0.type == "moov" }) {
            walk(moov.offset..<(moov.offset + moov.size))
        }
        return (stco, co64)
    }

    // MARK: - 读元数据

    private func string(_ items: [AVMetadataItem],
                        _ identifier: AVMetadataIdentifier) async throws -> String? {
        let matched = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        return try await matched.first?.load(.stringValue)
    }

    private func data(_ items: [AVMetadataItem],
                      _ identifier: AVMetadataIdentifier) async throws -> Data? {
        let matched = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        return try await matched.first?.load(.dataValue)
    }

    /// `trkn` / `disk` 是一小段二进制：`reserved(2) | 序号(2) | 总数(2) | ...`。
    private func pair(_ items: [AVMetadataItem],
                      _ identifier: AVMetadataIdentifier) async throws -> (Int, Int)? {
        guard let raw = try await data(items, identifier), raw.count >= 6 else { return nil }
        let bytes = [UInt8](raw)
        return (Int(bytes[2]) << 8 | Int(bytes[3]), Int(bytes[4]) << 8 | Int(bytes[5]))
    }
}
