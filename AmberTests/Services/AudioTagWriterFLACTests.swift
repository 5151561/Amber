import AVFoundation
import AppKit
import ImageIO
import XCTest
@testable import Amber

/// 给 FLAC 补标签。
///
/// 夹具全是手拼的：这台机器上没有 ffmpeg / flac / metaflac，
/// 也不能拿用户 ~/Music 里的文件当样本（跑一次测试就改了人家的歌）。
/// 手拼的最小 FLAC = `fLaC` + STREAMINFO + 几个假帧，够验证「块怎么排、字段写没写对」。
final class AudioTagWriterFLACTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberFLACTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 文字标签

    /// 基本盘：写进去的字段能原样读回来，音频帧一个字节没动。
    func testWritesVorbisComment() throws {
        let audio = Self.fakeFrames
        let url = try write(fixture: Self.flac(blocks: [], audio: audio))

        try FLACTagWriter.write(Self.fullTags, to: url)

        let file = try Self.parse(Data(contentsOf: url))
        XCTAssertEqual(file.audio, audio, "音频帧不该被动过")
        let fields = try XCTUnwrap(file.comment).fields
        XCTAssertEqual(Self.value("TITLE", in: fields), "Emily")
        XCTAssertEqual(Self.value("ARTIST", in: fields), "梁静茹")
        XCTAssertEqual(Self.value("ALBUM", in: fields), "亲亲")
        XCTAssertEqual(Self.value("ALBUMARTIST", in: fields), "梁静茹")
        XCTAssertEqual(Self.value("DATE", in: fields), "2002")
        XCTAssertEqual(Self.value("GENRE", in: fields), "华语流行")
        XCTAssertEqual(Self.value("LYRICS", in: fields), "第一句\n第二句")
    }

    /// 曲序/碟序在 Vorbis comment 里没有 `3/12` 那种合并写法，共几首要单独一条。
    func testWritesTotalsAsSeparateFields() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))

        try FLACTagWriter.write(Self.fullTags, to: url)

        let fields = try XCTUnwrap(Self.parse(Data(contentsOf: url)).comment).fields
        XCTAssertEqual(Self.value("TRACKNUMBER", in: fields), "3")
        XCTAssertEqual(Self.value("TRACKTOTAL", in: fields), "12")
        XCTAssertEqual(Self.value("DISCNUMBER", in: fields), "1")
        XCTAssertEqual(Self.value("DISCTOTAL", in: fields), "2")
    }

    /// 已经有标签的文件再写一次，是**替换**不是追加——不然同一个键会出现两条，
    /// 读的人拿到哪一条全看实现，Music.app 与 foobar2000 就会显示不同的标题。
    func testReplacesExistingCommentInsteadOfAppending() throws {
        let old = Self.commentBlock(vendor: "reference libFLAC 1.4.3",
                                    fields: [("TITLE", "旧标题"), ("COMMENT", "旧备注")])
        let url = try write(fixture: Self.flac(blocks: [(4, old)], audio: Self.fakeFrames))

        try FLACTagWriter.write(Self.fullTags, to: url)

        let file = try Self.parse(Data(contentsOf: url))
        XCTAssertEqual(file.blocks.filter { $0.type == 4 }.count, 1, "只该有一个 VORBIS_COMMENT")
        let comment = try XCTUnwrap(file.comment)
        XCTAssertEqual(comment.fields.filter { $0.0 == "TITLE" }.count, 1)
        XCTAssertEqual(Self.value("TITLE", in: comment.fields), "Emily")
        XCTAssertNil(Self.value("COMMENT", in: comment.fields), "旧字段整块换掉，不留残留")
        XCTAssertEqual(comment.vendor, "reference libFLAC 1.4.3", "vendor 是编码器签名，不该被我们改")
    }

    /// STREAMINFO 必须仍是第一块，SEEKTABLE 这类别人写的块要留着，PADDING 可以丢。
    func testKeepsStreamInfoFirstAndPreservesOtherBlocks() throws {
        let seekTable = Data(repeating: 0xAB, count: 18)
        let padding = Data(repeating: 0, count: 4096)
        let url = try write(fixture: Self.flac(blocks: [(3, seekTable), (1, padding)],
                                               audio: Self.fakeFrames))

        try FLACTagWriter.write(Self.fullTags, to: url)

        let file = try Self.parse(Data(contentsOf: url))
        XCTAssertEqual(file.blocks.first?.type, 0)
        XCTAssertEqual(file.blocks.first?.body, Self.streamInfo)
        XCTAssertEqual(file.blocks.first(where: { $0.type == 3 })?.body, seekTable)
        XCTAssertNil(file.blocks.first(where: { $0.type == 1 }), "PADDING 重排之后没必要留")
        XCTAssertEqual(file.blocks.filter(\.isLast).count, 1, "last 位只能有一个")
        XCTAssertTrue(file.blocks.last?.isLast == true, "last 位必须落在最后一块上")
    }

    // MARK: - 封面

    /// 封面按原始字节整块塞进 PICTURE 块，读回来要一个字节不差。
    func testArtworkRoundTripsByteForByte() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))
        var tags = Self.fullTags
        tags.artwork = Self.pngArtwork
        tags.artworkMIME = "image/png"

        try FLACTagWriter.write(tags, to: url)

        let picture = try XCTUnwrap(Self.parse(Data(contentsOf: url)).picture)
        XCTAssertEqual(picture.kind, 3, "3 = Front Cover")
        XCTAssertEqual(picture.mime, "image/png")
        XCTAssertEqual(picture.data, Self.pngArtwork)
        // 宽高走 ImageIO：真读得出来就该是真值，不是占位的 0
        XCTAssertEqual(picture.width, 2)
        XCTAssertEqual(picture.height, 2)
    }

    /// 再写一次不会变成两张封面。
    func testReplacesExistingFrontCover() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))
        var tags = Self.fullTags
        tags.artwork = Self.pngArtwork
        tags.artworkMIME = "image/png"
        try FLACTagWriter.write(tags, to: url)

        tags.artwork = Self.jpegArtwork
        tags.artworkMIME = "image/jpeg"
        try FLACTagWriter.write(tags, to: url)

        let file = try Self.parse(Data(contentsOf: url))
        XCTAssertEqual(file.blocks.filter { $0.type == 6 }.count, 1)
        XCTAssertEqual(file.picture?.data, Self.jpegArtwork)
    }

    /// 单块长度字段只有 3 字节，装不下的封面就不写——文字标签照写，别写出越界的块。
    func testOversizedArtworkSkipsPictureButKeepsText() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))
        var tags = Self.fullTags
        tags.artwork = Data(repeating: 0x5A, count: 0x100_0000)  // 16 MiB > 2^24−1
        tags.artworkMIME = "image/jpeg"

        try FLACTagWriter.write(tags, to: url)

        let file = try Self.parse(Data(contentsOf: url))
        XCTAssertNil(file.picture, "越界的封面宁可不写")
        XCTAssertEqual(Self.value("TITLE", in: try XCTUnwrap(file.comment).fields), "Emily")
        for block in file.blocks {
            XCTAssertLessThanOrEqual(block.body.count, 0xFF_FFFF)
        }
    }

    // MARK: - 别的工具加的 ID3 前缀

    /// 落地的 FLAC 是**标准形状**：第一个字节就是 `fLaC`，前面不多一块 ID3。
    ///
    /// 曾经为了让 Finder 显示封面在前面前置过一块带 APIC 的 ID3v2，现在不做了：
    /// Finder 那头改走以后的 QuickLook 缩略图扩展，不为它改文件格式。
    func testNeverPrependsID3() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))
        var tags = Self.fullTags
        tags.artwork = Self.jpegArtwork
        tags.artworkMIME = "image/jpeg"

        try FLACTagWriter.write(tags, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(4), Data("fLaC".utf8), "文件开头就该直接是 fLaC")
        let file = try Self.parse(data)
        XCTAssertEqual(file.picture?.data, Self.jpegArtwork, "封面走 PICTURE 块")
        XCTAssertEqual(file.audio, Self.fakeFrames, "音频帧不该被动过")
    }

    /// 同一份标签写两遍要逐字节相同——重排是幂等的，回填每次启动都跑一遍，
    /// 每跑一次就长胖一点的话用户的磁盘迟早被吃光。
    func testSecondWriteIsByteIdentical() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames))
        var tags = Self.fullTags
        tags.artwork = Self.jpegArtwork
        tags.artworkMIME = "image/jpeg"
        try FLACTagWriter.write(tags, to: url)
        let firstPass = try Data(contentsOf: url)

        try FLACTagWriter.write(tags, to: url)

        XCTAssertEqual(try Data(contentsOf: url), firstPass, "同一份标签写两遍该得到一模一样的文件")
    }

    /// 输入本来就带着一块 ID3 前缀（别的工具为了 Finder 封面加的）也得写得动：
    /// 整块跳过去从 `fLaC` 读起，重写之后那块前缀自然不在了（顺带结果，不是主动清理）。
    func testHandlesInputWithExistingID3Prefix() throws {
        let url = try write(fixture: Self.id3Prefix + Self.flac(blocks: [], audio: Self.fakeFrames))

        try FLACTagWriter.write(Self.fullTags, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(4), Data("fLaC".utf8), "重写之后开头就是 fLaC")
        let file = try Self.parse(data)
        let fields = try XCTUnwrap(file.comment).fields
        XCTAssertEqual(Self.value("TITLE", in: fields), "Emily")
        XCTAssertEqual(Self.value("ARTIST", in: fields), "梁静茹")
        XCTAssertEqual(Self.value("LYRICS", in: fields), "第一句\n第二句")
        XCTAssertEqual(file.audio, Self.fakeFrames, "音频帧不该被动过")
    }

    /// 分派器认得「ID3 + fLaC」：不认的话这份文件会被判成 mp3 交给 `ID3TagWriter`，
    /// Vorbis comment 那份从此再也不更新、文件还会被写坏。
    func testDispatcherRoutesID3PrefixedFLACToFLACWriter() throws {
        // 扩展名故意不对：分派只看头字节
        let url = try write(fixture: Self.id3Prefix + Self.flac(blocks: [], audio: Self.fakeFrames),
                            name: "x.bin")
        var tags = Self.fullTags
        tags.title = "分派之后"

        XCTAssertTrue(try AudioTagWriter.write(tags, to: url))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(4), Data("fLaC".utf8))
        XCTAssertEqual(Self.value("TITLE", in: try XCTUnwrap(Self.parse(data).comment).fields),
                       "分派之后", "走的是 FLAC 写入器，Vorbis 那份要跟着更新")
    }

    // MARK: - 分派与异常

    /// 空标签不写，也不算错：下载本身是成功的。
    func testEmptyTagsWriteNothing() throws {
        let fixture = Self.flac(blocks: [], audio: Self.fakeFrames)
        let url = try write(fixture: fixture)

        XCTAssertFalse(try AudioTagWriter.write(AudioTags(), to: url))
        XCTAssertEqual(try Data(contentsOf: url), fixture, "一个字节都不该动")
    }

    /// 分派只看头字节（扩展名是档位码约定的，降级取到别的容器时那个名字就是错的）。
    func testDispatcherRoutesByMagic() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames), name: "x.bin")

        XCTAssertTrue(try AudioTagWriter.write(Self.fullTags, to: url))

        XCTAssertNotNil(try Self.parse(Data(contentsOf: url)).comment)
    }

    func testMagicMismatchThrowsMalformed() throws {
        let url = try write(fixture: Data("fLaX".utf8) + Data(repeating: 0, count: 64))

        XCTAssertThrowsError(try FLACTagWriter.write(Self.fullTags, to: url)) { error in
            guard case AudioTagWriteError.malformed = error else {
                return XCTFail("该报 malformed，实际 \(error)")
            }
        }
    }

    /// 块头声称的长度比文件剩下的还长——截断的下载文件就长这样。
    func testTruncatedBlockThrowsMalformed() throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames).prefix(4 + 4 + 10))

        XCTAssertThrowsError(try FLACTagWriter.write(Self.fullTags, to: url)) { error in
            guard case AudioTagWriteError.malformed = error else {
                return XCTFail("该报 malformed，实际 \(error)")
            }
        }
    }

    // MARK: - AVFoundation 还认这份文件

    /// 写完之后 macOS 自己还得读得动：时长（STREAMINFO）与标签（`vorb/` 前缀）都要在。
    /// 这条是「我们没把文件写坏」的独立佐证——前面的断言用的是我们自己的解析器。
    func testAVFoundationStillReadsDurationAndTags() async throws {
        let url = try write(fixture: Self.flac(blocks: [], audio: Self.fakeFrames), name: "a.flac")
        try FLACTagWriter.write(Self.fullTags, to: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.05, "STREAMINFO 里写的是 44100 个采样")

        let items = try await asset.load(.metadata)
        func string(_ name: String) async throws -> String? {
            let identifier = AVMetadataIdentifier(rawValue: "vorb/" + name)
            let matched = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            return try await matched.first?.load(.stringValue)
        }
        let title = try await string("TITLE")
        let artist = try await string("ARTIST")
        let track = try await string("TRACKNUMBER")
        XCTAssertEqual(title, "Emily")
        XCTAssertEqual(artist, "梁静茹")
        XCTAssertEqual(track, "3")
    }

    // MARK: - 夹具

    private func write(fixture: Data, name: String = "fixture.flac") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try fixture.write(to: url)
        return url
    }

    static let fullTags: AudioTags = {
        var tags = AudioTags()
        tags.title = "Emily"
        tags.artist = "梁静茹"
        tags.album = "亲亲"
        tags.albumArtist = "梁静茹"
        tags.trackNumber = 3
        tags.trackTotal = 12
        tags.discNumber = 1
        tags.discTotal = 2
        tags.year = "2002"
        tags.genre = "华语流行"
        tags.lyrics = "第一句\n第二句"
        return tags
    }()

    /// 别的工具（Mp3tag 那类）为了让 Finder 显示封面加在 `fLaC` 前面的那块 ID3。
    /// 借实现里那份拼字节：这里要的是「一块结构合规的 ID3v2.4」，不是它的内容。
    static let id3Prefix: Data = {
        var tags = AudioTags()
        tags.title = "别的工具写的"
        tags.artwork = jpegArtwork
        tags.artworkMIME = "image/jpeg"
        return ID3TagWriter.tagData(tags)
    }()

    /// 假帧：写标签这一路不解码音频，只要求这段字节原样搬过去。
    static let fakeFrames = Data([0xFF, 0xF8, 0x69, 0x18]) + Data(repeating: 0x42, count: 512)

    /// 34 字节 STREAMINFO：最小/最大块大小、最小/最大帧长，然后是
    /// 采样率(20) + 声道数−1(3) + 位深−1(5) + 总采样数(36) 这 64 位，最后 16 字节 MD5（全 0 = 未知）。
    static let streamInfo: Data = {
        var out = Data([0x10, 0x00, 0x10, 0x00])  // block size 4096
        out.append(contentsOf: [0, 0, 0, 0, 0, 0])  // 帧长未知
        let packed = UInt64(44_100) << 44 | UInt64(2 - 1) << 41 | UInt64(16 - 1) << 36
            | UInt64(44_100)  // 1 秒
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((packed >> UInt64(shift)) & 0xFF))
        }
        out.append(Data(repeating: 0, count: 16))
        return out
    }()

    static func flac(blocks: [(UInt8, Data)], audio: Data) -> Data {
        let all: [(UInt8, Data)] = [(0, streamInfo)] + blocks
        var out = Data("fLaC".utf8)
        for (index, block) in all.enumerated() {
            let isLast = index == all.count - 1
            out.append(block.0 | (isLast ? 0x80 : 0))
            out.append(contentsOf: [UInt8((block.1.count >> 16) & 0xFF),
                                    UInt8((block.1.count >> 8) & 0xFF),
                                    UInt8(block.1.count & 0xFF)])
            out.append(block.1)
        }
        out.append(audio)
        return out
    }

    static func commentBlock(vendor: String, fields: [(String, String)]) -> Data {
        func le32(_ value: Int) -> Data {
            Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                  UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
        }
        var out = le32(vendor.utf8.count)
        out.append(Data(vendor.utf8))
        out.append(le32(fields.count))
        for (name, value) in fields {
            let entry = Data("\(name)=\(value)".utf8)
            out.append(le32(entry.count))
            out.append(entry)
        }
        return out
    }

    /// 2×2 的真 PNG / JPEG：ImageIO 得能从里面读出宽高，否则「填真值」那条断言没意义。
    static let pngArtwork: Data = image(type: "public.png")
    static let jpegArtwork: Data = image(type: "public.jpeg")

    private static func image(type: String) -> Data {
        let data = NSMutableData()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: - 自己的解析器（断言不复用被测代码的写法）

    struct Block {
        var type: UInt8
        var isLast: Bool
        var body: Data
    }

    struct Picture {
        var kind: UInt32
        var mime: String
        var width: UInt32
        var height: UInt32
        var data: Data
    }

    struct ParsedFLAC {
        var blocks: [Block]
        var audio: Data
        var comment: (vendor: String, fields: [(String, String)])?
        var picture: Picture?
    }

    static func parse(_ data: Data) throws -> ParsedFLAC {
        let bytes = [UInt8](data)
        guard bytes.count > 4, Array(bytes[0..<4]) == Array("fLaC".utf8) else {
            throw AudioTagWriteError.malformed("魔数不对")
        }
        var offset = 4
        var blocks: [Block] = []
        while true {
            guard bytes.count >= offset + 4 else { throw AudioTagWriteError.malformed("块头截断") }
            let isLast = bytes[offset] & 0x80 != 0
            let type = bytes[offset] & 0x7F
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard bytes.count >= offset + length else {
                throw AudioTagWriteError.malformed("块正文截断")
            }
            blocks.append(Block(type: type, isLast: isLast,
                                body: Data(bytes[offset..<(offset + length)])))
            offset += length
            if isLast { break }
        }
        return ParsedFLAC(
            blocks: blocks,
            audio: Data(bytes[offset...]),
            comment: blocks.first { $0.type == 4 }.map { parseComment($0.body) },
            picture: blocks.first { $0.type == 6 }.flatMap { parsePicture($0.body) })
    }

    static func parseComment(_ body: Data) -> (vendor: String, fields: [(String, String)]) {
        let bytes = [UInt8](body)
        var offset = 0
        func le32() -> Int {
            defer { offset += 4 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let vendorLength = le32()
        let vendor = String(bytes: bytes[offset..<(offset + vendorLength)], encoding: .utf8) ?? ""
        offset += vendorLength
        var fields: [(String, String)] = []
        for _ in 0..<le32() {
            let length = le32()
            let entry = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) ?? ""
            offset += length
            guard let separator = entry.firstIndex(of: "=") else { continue }
            fields.append((String(entry[entry.startIndex..<separator]),
                           String(entry[entry.index(after: separator)...])))
        }
        return (vendor, fields)
    }

    static func parsePicture(_ body: Data) -> Picture? {
        let bytes = [UInt8](body)
        var offset = 0
        func be32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        guard bytes.count >= 32 else { return nil }
        let kind = be32()
        let mimeLength = Int(be32())
        let mime = String(bytes: bytes[offset..<(offset + mimeLength)], encoding: .utf8) ?? ""
        offset += mimeLength
        offset += Int(be32())  // 描述：4 字节长度（be32 已经跨过）再跳过正文
        let width = be32()
        let height = be32()
        _ = be32()  // 色深
        _ = be32()  // 索引色数
        let length = Int(be32())
        guard bytes.count >= offset + length else { return nil }
        return Picture(kind: kind, mime: mime, width: width, height: height,
                       data: Data(bytes[offset..<(offset + length)]))
    }

    static func value(_ name: String, in fields: [(String, String)]) -> String? {
        fields.first { $0.0 == name }?.1
    }
}
