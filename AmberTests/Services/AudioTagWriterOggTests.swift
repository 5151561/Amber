import XCTest
@testable import Amber

/// 给 Ogg（Vorbis / Opus）补标签。
///
/// AVFoundation 压根不认 ogg，验不了，所以这里全靠自己解析回来：
/// 页头字段、每页 CRC、页号连续性、音频页字节有没有被动过。
/// 夹具也是手拼的——机器上没有 oggenc / opusenc，也不能拿用户的歌当样本。
final class AudioTagWriterOggTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberOggTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - CRC

    /// Ogg 的 CRC 跟 zlib/PNG 那个 CRC-32 不是一回事：不反射、初值 0、末尾不异或。
    /// 查表实现拿逐位实现当标尺——两份独立写法算出同一个数，才说明表没打错。
    func testCRC32MatchesBitwiseReference() {
        func bitwise(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0
            for byte in data {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 {
                    crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1
                }
            }
            return crc
        }
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 7, 255, 4096] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            XCTAssertEqual(OggCRC32.checksum(data), bitwise(data), "长度 \(length) 对不上")
        }
        // 定值锚：初值 0 的这版 CRC 对 "123456789" 的结果
        XCTAssertEqual(OggCRC32.checksum(Data("123456789".utf8)), 0x89A1_897F)
        XCTAssertEqual(OggCRC32.checksum(Data()), 0)
    }

    // MARK: - Vorbis

    /// 基本盘：comment 换成我们的，识别头 / setup 头与音频页原样不动。
    func testRewritesVorbisComment() throws {
        let fixture = Self.vorbisFixture()
        let url = try write(fixture: fixture.data)

        try OggTagWriter.write(Self.fullTags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        try Self.assertWellFormed(pages)
        XCTAssertEqual(pages.map(\.serial), Array(repeating: fixture.serial, count: pages.count),
                       "serial 不该变")

        let packets = Self.packets(in: pages)
        XCTAssertEqual(packets[0], fixture.identification, "识别头一个字节都不该动")
        XCTAssertEqual(packets[2], fixture.setup, "setup 头一个字节都不该动")

        let comment = packets[1]
        XCTAssertEqual(comment.prefix(7), Data([0x03] + Array("vorbis".utf8)))
        XCTAssertEqual(comment.last, 0x01, "Vorbis I §4.2.2：comment 包末尾要有 framing bit")
        let parsed = Self.parseComment(comment.dropFirst(7).dropLast())
        XCTAssertEqual(parsed.vendor, fixture.vendor, "vendor 是编码器签名，不该被我们改")
        XCTAssertEqual(Self.value("TITLE", in: parsed.fields), "Emily")
        XCTAssertEqual(Self.value("ARTIST", in: parsed.fields), "梁静茹")
        XCTAssertEqual(Self.value("ALBUM", in: parsed.fields), "亲亲")
        XCTAssertEqual(Self.value("TRACKNUMBER", in: parsed.fields), "3")
        XCTAssertEqual(Self.value("TRACKTOTAL", in: parsed.fields), "12")
        XCTAssertEqual(Self.value("LYRICS", in: parsed.fields), "第一句\n第二句")
    }

    /// 音频页：正文、granule、EOS 位都要原样带过来（只有页号和 CRC 允许变）。
    func testAudioPagesSurviveUnchanged() throws {
        let fixture = Self.vorbisFixture()
        let url = try write(fixture: fixture.data)

        try OggTagWriter.write(Self.fullTags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        let audio = pages.filter { $0.granule > 0 }
        XCTAssertEqual(audio.map(\.body), fixture.audioBodies)
        XCTAssertEqual(audio.map(\.granule), [44_100, 88_200])
        XCTAssertEqual(audio.last?.headerType, 0x04, "EOS 位要留着")
        let original = try Self.parse(fixture.data)
        XCTAssertEqual(pages.first?.raw, original.first?.raw, "识别头独占 BOS 页，整页原样抄过去")
    }

    /// 已经有标签的再写一次是替换：同名字段只留一条，旧字段不残留。
    func testReplacesExistingComment() throws {
        let fixture = Self.vorbisFixture(fields: [("TITLE", "旧标题"), ("COMMENT", "旧备注")])
        let url = try write(fixture: fixture.data)

        try OggTagWriter.write(Self.fullTags, to: url)

        let parsed = Self.parseComment(
            Self.packets(in: try Self.parse(Data(contentsOf: url)))[1].dropFirst(7).dropLast())
        XCTAssertEqual(parsed.fields.filter { $0.0 == "TITLE" }.count, 1)
        XCTAssertEqual(Self.value("TITLE", in: parsed.fields), "Emily")
        XCTAssertNil(Self.value("COMMENT", in: parsed.fields))
    }

    /// 封面在 Ogg 里没有独立块：走 `METADATA_BLOCK_PICTURE`（base64 的 FLAC PICTURE 块），
    /// 解回来图片字节要一个不差。
    func testArtworkRoundTripsAsMetadataBlockPicture() throws {
        let url = try write(fixture: Self.vorbisFixture().data)
        var tags = Self.fullTags
        tags.artwork = AudioTagWriterFLACTests.pngArtwork
        tags.artworkMIME = "image/png"

        try OggTagWriter.write(tags, to: url)

        let parsed = Self.parseComment(
            Self.packets(in: try Self.parse(Data(contentsOf: url)))[1].dropFirst(7).dropLast())
        let encoded = try XCTUnwrap(Self.value("METADATA_BLOCK_PICTURE", in: parsed.fields))
        let block = try XCTUnwrap(Data(base64Encoded: encoded))
        let picture = try XCTUnwrap(AudioTagWriterFLACTests.parsePicture(block))
        XCTAssertEqual(picture.kind, 3)
        XCTAssertEqual(picture.mime, "image/png")
        XCTAssertEqual(picture.width, 2)
        XCTAssertEqual(picture.data, AudioTagWriterFLACTests.pngArtwork)
    }

    /// 封面超过 PICTURE 块的长度上限就不写，文字标签照写。
    func testOversizedArtworkSkipsPictureButKeepsText() throws {
        let url = try write(fixture: Self.vorbisFixture().data)
        var tags = Self.fullTags
        tags.artwork = Data(repeating: 0x5A, count: 0x100_0000)  // 16 MiB > 2^24−1

        try OggTagWriter.write(tags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        try Self.assertWellFormed(pages)
        let parsed = Self.parseComment(Self.packets(in: pages)[1].dropFirst(7).dropLast())
        XCTAssertNil(Self.value("METADATA_BLOCK_PICTURE", in: parsed.fields))
        XCTAssertEqual(Self.value("TITLE", in: parsed.fields), "Emily")
    }

    /// comment 长到一页装不下（一页最多 255 段 = 65025 字节）时要拆页，
    /// 续页得置 continuation 位，后面所有页的页号跟着顺延。
    func testLongCommentSpillsToContinuationPageAndRenumbers() throws {
        let fixture = Self.vorbisFixture()
        let url = try write(fixture: fixture.data)
        var tags = Self.fullTags
        tags.lyrics = String(repeating: "这是一句很长的歌词。", count: 8000)  // 远超一页

        try OggTagWriter.write(tags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        try Self.assertWellFormed(pages)
        XCTAssertGreaterThan(pages.count, fixture.pageCount, "该多出续页")
        XCTAssertTrue(pages.contains { $0.headerType & 0x01 != 0 }, "续页要置 continuation 位")
        let parsed = Self.parseComment(Self.packets(in: pages)[1].dropFirst(7).dropLast())
        XCTAssertEqual(Self.value("LYRICS", in: parsed.fields), tags.lyrics)
        XCTAssertEqual(pages.filter { $0.granule > 0 }.map(\.body), fixture.audioBodies,
                       "音频页正文还是原来那些")
    }

    // MARK: - Opus

    /// Opus 的 comment 包是 `OpusTags`，没有 framing bit（RFC 7845 §5.2）。
    func testRewritesOpusTags() throws {
        let fixture = Self.opusFixture()
        let url = try write(fixture: fixture.data)

        try OggTagWriter.write(Self.fullTags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        try Self.assertWellFormed(pages)
        let packets = Self.packets(in: pages)
        XCTAssertEqual(packets[0], fixture.identification, "OpusHead 一个字节都不该动")
        XCTAssertEqual(packets[1].prefix(8), Data("OpusTags".utf8))
        let parsed = Self.parseComment(packets[1].dropFirst(8))
        XCTAssertEqual(parsed.vendor, fixture.vendor)
        XCTAssertEqual(Self.value("TITLE", in: parsed.fields), "Emily")
        XCTAssertEqual(pages.filter { $0.granule > 0 }.map(\.body), fixture.audioBodies)
    }

    // MARK: - 多路复用与异常

    /// 同一个文件里多条码流时只动音频那一路，别人的页一个字节都不碰。
    func testLeavesOtherLogicalStreamsAlone() throws {
        let other = Self.page(headerType: 0x02, granule: 0, serial: 0x7777_7777, sequence: 0,
                              packets: [Data("fishead\0".utf8) + Data(repeating: 0x11, count: 56)])
        let fixture = Self.vorbisFixture(foreign: other)
        let url = try write(fixture: fixture.data)

        try OggTagWriter.write(Self.fullTags, to: url)

        let pages = try Self.parse(Data(contentsOf: url))
        let foreign = pages.filter { $0.serial == 0x7777_7777 }
        XCTAssertEqual(foreign.count, 1)
        XCTAssertEqual(foreign[0].raw, other, "别人的页要原样保留（页号是按 serial 各算各的）")
        try Self.assertWellFormed(pages.filter { $0.serial == fixture.serial })
    }

    /// 认得出是 Ogg，但里面不是我们会写的码流——这是 unsupported 不是 malformed。
    func testUnknownCodecThrowsUnsupported() throws {
        let speex = Self.page(headerType: 0x02, granule: 0, serial: 1, sequence: 0,
                              packets: [Data("Speex   ".utf8) + Data(repeating: 0, count: 72)])
        let url = try write(fixture: speex)

        XCTAssertThrowsError(try OggTagWriter.write(Self.fullTags, to: url)) { error in
            guard case AudioTagWriteError.unsupported = error else {
                return XCTFail("该报 unsupported，实际 \(error)")
            }
        }
    }

    func testBadCapturePatternThrowsMalformed() throws {
        var broken = Self.vorbisFixture().data
        broken[0] = 0x58  // OggS -> XggS，capture pattern 就废了
        let url = try write(fixture: broken)

        XCTAssertThrowsError(try OggTagWriter.write(Self.fullTags, to: url)) { error in
            guard case AudioTagWriteError.malformed = error else {
                return XCTFail("该报 malformed，实际 \(error)")
            }
        }
    }

    /// 截断的下载文件：页头声称的正文比剩下的字节多。
    func testTruncatedPageThrowsMalformed() throws {
        let fixture = Self.vorbisFixture().data
        let url = try write(fixture: fixture.prefix(fixture.count - 40))

        XCTAssertThrowsError(try OggTagWriter.write(Self.fullTags, to: url)) { error in
            guard case AudioTagWriteError.malformed = error else {
                return XCTFail("该报 malformed，实际 \(error)")
            }
        }
    }

    /// 空标签不写，也不算错。
    func testEmptyTagsWriteNothing() throws {
        let fixture = Self.vorbisFixture().data
        let url = try write(fixture: fixture)

        XCTAssertFalse(try AudioTagWriter.write(AudioTags(), to: url))
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }

    /// 分派只看头字节：`OggS` 就走 Ogg，不管文件叫什么。
    func testDispatcherRoutesByMagic() throws {
        let url = try write(fixture: Self.vorbisFixture().data, name: "x.bin")

        XCTAssertTrue(try AudioTagWriter.write(Self.fullTags, to: url))

        let parsed = Self.parseComment(
            Self.packets(in: try Self.parse(Data(contentsOf: url)))[1].dropFirst(7).dropLast())
        XCTAssertEqual(Self.value("TITLE", in: parsed.fields), "Emily")
    }

    // MARK: - 夹具

    private func write(fixture: Data, name: String = "fixture.ogg") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try fixture.write(to: url)
        return url
    }

    static let fullTags = AudioTagWriterFLACTests.fullTags

    struct Fixture {
        var data: Data
        var serial: UInt32
        var vendor: String
        var identification: Data
        var setup: Data
        var audioBodies: [Data]
        var pageCount: Int
    }

    /// 最小 Vorbis 流：识别头独占 BOS 页，comment + setup 一页，然后两页音频（末页带 EOS）。
    /// 这个排布就是 Vorbis I §4.2 规定的样子，也是 oggenc 实际写出来的样子。
    static func vorbisFixture(fields: [(String, String)] = [], foreign: Data? = nil) -> Fixture {
        let serial: UInt32 = 0x1234_5678
        let vendor = "Xiph.Org libVorbis I 20200704"
        // 识别头 30 字节：包类型+"vorbis"、版本、声道、采样率、三档码率、块大小、framing bit
        var identification = Data([0x01] + Array("vorbis".utf8))
        identification.append(contentsOf: [0, 0, 0, 0])
        identification.append(2)
        identification.append(contentsOf: [0x44, 0xAC, 0x00, 0x00])  // 44100
        identification.append(Data(repeating: 0, count: 12))
        identification.append(0xB8)
        identification.append(0x01)
        var comment = Data([0x03] + Array("vorbis".utf8))
        comment.append(AudioTagWriterFLACTests.commentBlock(vendor: vendor, fields: fields))
        comment.append(0x01)
        let setup = Data([0x05] + Array("vorbis".utf8)) + Data(repeating: 0x33, count: 120)
        let audioBodies = [Data(repeating: 0xA1, count: 300), Data(repeating: 0xB2, count: 180)]

        var data = page(headerType: 0x02, granule: 0, serial: serial, sequence: 0,
                        packets: [identification])
        if let foreign { data.append(foreign) }
        data.append(page(headerType: 0, granule: 0, serial: serial, sequence: 1,
                         packets: [comment, setup]))
        data.append(page(headerType: 0, granule: 44_100, serial: serial, sequence: 2,
                         packets: [audioBodies[0]]))
        data.append(page(headerType: 0x04, granule: 88_200, serial: serial, sequence: 3,
                         packets: [audioBodies[1]]))
        return Fixture(data: data, serial: serial, vendor: vendor, identification: identification,
                       setup: setup, audioBodies: audioBodies,
                       pageCount: foreign == nil ? 4 : 5)
    }

    /// 最小 Opus 流：OpusHead（19 字节，RFC 7845 §5.1）+ OpusTags + 一页音频。
    static func opusFixture() -> Fixture {
        let serial: UInt32 = 0x0BAD_F00D
        let vendor = "libopus 1.4"
        var identification = Data("OpusHead".utf8)
        identification.append(contentsOf: [1, 2])          // 版本、声道
        identification.append(contentsOf: [0x38, 0x01])    // pre-skip 312
        identification.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])  // 48000
        identification.append(contentsOf: [0, 0, 0])       // 输出增益、mapping family
        var comment = Data("OpusTags".utf8)
        comment.append(AudioTagWriterFLACTests.commentBlock(vendor: vendor, fields: []))
        let audioBodies = [Data(repeating: 0xC3, count: 240)]

        var data = page(headerType: 0x02, granule: 0, serial: serial, sequence: 0,
                        packets: [identification])
        data.append(page(headerType: 0, granule: 0, serial: serial, sequence: 1, packets: [comment]))
        data.append(page(headerType: 0x04, granule: 48_000, serial: serial, sequence: 2,
                         packets: audioBodies))
        return Fixture(data: data, serial: serial, vendor: vendor, identification: identification,
                       setup: Data(), audioBodies: audioBodies, pageCount: 3)
    }

    /// 造一页。段表按 lacing 规则铺（255 表示包还没完），CRC 用被测的查表实现算
    /// ——它自己已经拿逐位实现校过了。
    static func page(headerType: UInt8, granule: UInt64, serial: UInt32, sequence: UInt32,
                     packets: [Data]) -> Data {
        var segments: [UInt8] = []
        var body = Data()
        for packet in packets {
            var offset = 0
            repeat {
                let length = min(255, packet.count - offset)
                segments.append(UInt8(length))
                offset += length
            } while offset < packet.count || segments.last == 255
            body.append(packet)
        }
        var out = Data("OggS".utf8)
        out.append(0)
        out.append(headerType)
        for shift in stride(from: 0, through: 56, by: 8) {
            out.append(UInt8((granule >> UInt64(shift)) & 0xFF))
        }
        for value in [serial, sequence, 0] {
            for shift in stride(from: 0, through: 24, by: 8) {
                out.append(UInt8((value >> UInt32(shift)) & 0xFF))
            }
        }
        out.append(UInt8(segments.count))
        out.append(contentsOf: segments)
        out.append(body)
        let crc = OggCRC32.checksum(out)
        for offset in 0..<4 { out[22 + offset] = UInt8((crc >> UInt32(offset * 8)) & 0xFF) }
        return out
    }

    // MARK: - 自己的解析器

    struct ParsedPage {
        var headerType: UInt8
        var granule: UInt64
        var serial: UInt32
        var sequence: UInt32
        var crc: UInt32
        var segments: [UInt8]
        var body: Data
        var raw: Data
    }

    static func parse(_ data: Data) throws -> [ParsedPage] {
        let bytes = [UInt8](data)
        var offset = 0
        var pages: [ParsedPage] = []
        while offset < bytes.count {
            guard bytes.count >= offset + 27, Array(bytes[offset..<(offset + 4)]) == Array("OggS".utf8)
            else { throw AudioTagWriteError.malformed("页头截断或 capture pattern 不对") }
            func le(_ start: Int, _ count: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in (0..<count).reversed() {
                    value = value << 8 | UInt64(bytes[offset + start + index])
                }
                return value
            }
            let segmentCount = Int(bytes[offset + 26])
            let segments = Array(bytes[(offset + 27)..<(offset + 27 + segmentCount)])
            let length = segments.reduce(0) { $0 + Int($1) }
            let start = offset + 27 + segmentCount
            guard bytes.count >= start + length else {
                throw AudioTagWriteError.malformed("页正文截断")
            }
            pages.append(ParsedPage(headerType: bytes[offset + 5], granule: le(6, 8),
                                    serial: UInt32(le(14, 4)), sequence: UInt32(le(18, 4)),
                                    crc: UInt32(le(22, 4)), segments: segments,
                                    body: Data(bytes[start..<(start + length)]),
                                    raw: Data(bytes[offset..<(start + length)])))
            offset = start + length
        }
        return pages
    }

    /// 页号连续、每页 CRC 自洽——这两条是「文件还能放」的底线。
    static func assertWellFormed(_ pages: [ParsedPage],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(pages.map(\.sequence), Array(0..<UInt32(pages.count)),
                       "页号要连续", file: file, line: line)
        for page in pages {
            var raw = page.raw
            for offset in 0..<4 { raw[22 + offset] = 0 }
            XCTAssertEqual(OggCRC32.checksum(raw), page.crc,
                           "第 \(page.sequence) 页的 CRC 对不上", file: file, line: line)
        }
    }

    /// 按 lacing 把页里的包拼回来。
    static func packets(in pages: [ParsedPage]) -> [Data] {
        var packets: [Data] = []
        var pending = Data()
        for page in pages {
            var offset = 0
            for lace in page.segments {
                pending.append(page.body.subdata(in: offset..<(offset + Int(lace))))
                offset += Int(lace)
                if lace < 255 {
                    packets.append(pending)
                    pending = Data()
                }
            }
        }
        return packets
    }

    static func parseComment(_ body: Data) -> (vendor: String, fields: [(String, String)]) {
        AudioTagWriterFLACTests.parseComment(Data(body))
    }

    static func value(_ name: String, in fields: [(String, String)]) -> String? {
        AudioTagWriterFLACTests.value(name, in: fields)
    }
}
