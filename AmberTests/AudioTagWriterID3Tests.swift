import AppKit
import XCTest
@testable import Amber

/// MP3 这一路没法拿真编码器验（机器上没有 lame，`afconvert` 也不产 MP3），
/// 所以夹具是「ID3 头 + 几个假 MPEG 帧」的桩文件，读回来用**测试自己写的**解析器
/// 逐字节对帧布局——这样写错 synchsafe、写错 UTF-8 编码字节、把旧标签叠加而不是替换，
/// 都会当场翻车，而不是等到用户在 Finder 里看到一堆无名文件才发现。
final class AudioTagWriterID3Tests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioTagWriterID3Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - 写

    func testWritesTextFramesAsUTF8() throws {
        let audio = fakeMPEGFrames()
        let url = try fixture(prefix: Data(), audio: audio)
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
        try ID3TagWriter.write(tags, to: url)

        let parsed = try parse(url)
        XCTAssertEqual(parsed.major, 4, "写的是 v2.4——frame size 是 synchsafe 就靠这个版本号声明")
        XCTAssertEqual(parsed.flags, 0, "不开 unsynchronisation、不写 footer")
        XCTAssertEqual(parsed.text("TIT2"), "夜曲")
        XCTAssertEqual(parsed.text("TPE1"), "周杰伦")
        XCTAssertEqual(parsed.text("TPE2"), "周杰伦")
        XCTAssertEqual(parsed.text("TALB"), "十一月的萧邦")
        XCTAssertEqual(parsed.text("TRCK"), "3/12")
        XCTAssertEqual(parsed.text("TPOS"), "1/2")
        XCTAssertEqual(parsed.text("TDRC"), "2005")
        XCTAssertEqual(parsed.text("TCON"), "流行")
        // 编码字节 3 才是 UTF-8；写成 0（Latin-1）中文就全成乱码
        XCTAssertEqual(parsed.frame("TIT2")?.first, 3)
        XCTAssertEqual(parsed.audio, audio, "音频帧必须原样搬过去")
    }

    func testTrackWithoutTotalOmitsSlash() throws {
        let url = try fixture(prefix: Data(), audio: fakeMPEGFrames())
        var tags = AudioTags()
        tags.trackNumber = 7
        try ID3TagWriter.write(tags, to: url)
        let parsed = try parse(url)
        XCTAssertEqual(parsed.text("TRCK"), "7")
        XCTAssertNil(parsed.frame("TPOS"), "没有碟号就别写 TPOS")
        XCTAssertNil(parsed.frame("APIC"), "没有封面就别写 APIC")
    }

    func testLyricsAndArtworkRoundTrip() throws {
        let url = try fixture(prefix: Data(), audio: fakeMPEGFrames())
        let artwork = try makePNG()
        var tags = AudioTags()
        tags.lyrics = "为你弹奏萧邦的夜曲\n第二行"
        tags.artwork = artwork
        tags.artworkMIME = "image/png"
        try ID3TagWriter.write(tags, to: url)

        let parsed = try parse(url)
        // USLT：编码(1) + 语言(3) + 描述(0 结尾) + 歌词
        let uslt = try XCTUnwrap(parsed.frame("USLT"))
        XCTAssertEqual(uslt.first, 3)
        XCTAssertEqual(String(data: uslt.subdata(in: 1..<4), encoding: .isoLatin1), "und")
        XCTAssertEqual(uslt[uslt.startIndex + 4], 0, "描述为空，就只有一个终止符")
        XCTAssertEqual(String(data: uslt.subdata(in: 5..<uslt.count), encoding: .utf8),
                       "为你弹奏萧邦的夜曲\n第二行")

        // APIC：编码(1) + MIME(Latin-1，0 结尾) + 图片类型(1) + 描述(0 结尾) + 图片字节
        let apic = try XCTUnwrap(parsed.frame("APIC"))
        XCTAssertEqual(apic.first, 3)
        let mimeEnd = try XCTUnwrap(apic.dropFirst().firstIndex(of: 0))
        XCTAssertEqual(String(data: apic.subdata(in: 1..<mimeEnd), encoding: .isoLatin1), "image/png")
        XCTAssertEqual(apic[mimeEnd + 1], 3, "picture type 3 = Front Cover")
        XCTAssertEqual(apic[mimeEnd + 2], 0, "空描述")
        XCTAssertEqual(apic.subdata(in: (mimeEnd + 3)..<apic.count), artwork)
    }

    func testFrameAndTagSizesAreSynchsafe() throws {
        let url = try fixture(prefix: Data(), audio: fakeMPEGFrames())
        var tags = AudioTags()
        // 撑到 128 字节以上，普通 32 位整数和 synchsafe 才会分出差别
        tags.title = String(repeating: "长", count: 200)
        try ID3TagWriter.write(tags, to: url)

        let raw = try Data(contentsOf: url)
        // 标签长度和每条 frame 长度的 4 个字节最高位都必须是 0，
        // 否则 MPEG 扫描器会在标签里找到假的帧同步字
        for offset in 6..<10 { XCTAssertEqual(raw[offset] & 0x80, 0, "tag size 第 \(offset) 字节") }
        let parsed = try parse(url)
        let sizeBytes = try XCTUnwrap(parsed.rawFrameSize("TIT2"))
        XCTAssertTrue(sizeBytes.allSatisfy { $0 & 0x80 == 0 })
        XCTAssertEqual(parsed.text("TIT2"), String(repeating: "长", count: 200))
        // 200 个「长」是 600 字节 UTF-8，加编码字节 601——正好越过 synchsafe 的第一个进位
        XCTAssertEqual(try XCTUnwrap(parsed.frame("TIT2")).count, 601)
    }

    // MARK: - 替换而不是叠加

    func testReplacesExistingTagInsteadOfPrepending() throws {
        let audio = fakeMPEGFrames()
        // 先放一块 2000 字节的旧 v2.3 标签
        let url = try fixture(prefix: legacyTag(payload: 2_000, footer: false), audio: audio)
        var tags = AudioTags()
        tags.title = "新的"
        try ID3TagWriter.write(tags, to: url)

        let raw = try Data(contentsOf: url)
        let parsed = try parse(url)
        XCTAssertEqual(parsed.text("TIT2"), "新的")
        XCTAssertEqual(parsed.audio, audio, "旧标签整块换掉，音频一个字节不动")
        // 全文件只许有一处 "ID3" 起头的标签：新标签后面不许还跟着旧的那 2010 字节
        XCTAssertNil(range(of: Data("ID3".utf8), in: raw, from: 3),
                     "旧标签没被替换掉，而是被顶到后面去了")
    }

    func testFooterFlagAccountsForTenExtraBytes() throws {
        let audio = fakeMPEGFrames()
        // footer 那 10 字节不算在 header 的 size 里，漏掉就会把 "3DI" 当成音频留下来
        let url = try fixture(prefix: legacyTag(payload: 64, footer: true), audio: audio)
        var tags = AudioTags()
        tags.title = "带 footer"
        try ID3TagWriter.write(tags, to: url)

        let parsed = try parse(url)
        XCTAssertEqual(parsed.audio, audio)
        XCTAssertNil(range(of: Data("3DI".utf8), in: try Data(contentsOf: url), from: 0))
    }

    func testRawMP3WithoutTagKeepsEveryAudioByte() throws {
        let audio = fakeMPEGFrames()
        let url = try fixture(prefix: Data(), audio: audio)
        var tags = AudioTags()
        tags.title = "裸流"
        try ID3TagWriter.write(tags, to: url)
        XCTAssertEqual(try parse(url).audio, audio)
        // 写完还得是「ID3 开头」——容器判定就是照这三个字节认 mp3 的
        XCTAssertEqual(try Data(contentsOf: url).prefix(3), Data("ID3".utf8))
    }

    // MARK: - 分派

    /// 真 mp3 照旧走 ID3 这条路。
    ///
    /// 有必要单验一条：分派器现在读到 `ID3` 时会先整块跳过去看后面的魔数
    ///（别的工具会给 FLAC 前面加一块 ID3 换 Finder 的封面，见 `FLACTagWriter.write`）。
    /// 跳过之后是 MPEG 帧、不是 `fLaC`/`OggS`，就该原样当 mp3 交给 `ID3TagWriter`。
    func testDispatcherStillRoutesRealMP3ToID3() throws {
        let audio = fakeMPEGFrames()
        let url = try fixture(prefix: legacyTag(payload: 2_000, footer: false), audio: audio,
                              ext: "bin")  // 扩展名故意不对：分派只看头字节
        var tags = AudioTags()
        tags.title = "还是 mp3"

        XCTAssertTrue(try AudioTagWriter.write(tags, to: url))

        let parsed = try parse(url)
        XCTAssertEqual(parsed.text("TIT2"), "还是 mp3")
        XCTAssertEqual(parsed.audio, audio, "旧标签整块换掉，音频一个字节不动")
    }

    // MARK: - 夹具

    private func fixture(prefix: Data, audio: Data, ext: String = "mp3") throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).\(ext)")
        try (prefix + audio).write(to: url)
        return url
    }

    /// 几帧「长得像 MPEG 帧」的字节：帧同步 0xFFFB + 可辨认的填充。
    /// 不需要真能解码，这一路验的是标签块的边界，不是音频。
    private func fakeMPEGFrames(count: Int = 3) -> Data {
        var data = Data()
        for frame in 0..<count {
            data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
            data.append(Data((0..<414).map { UInt8(truncatingIfNeeded: $0 &+ frame) }))
        }
        return data
    }

    /// 一块旧标签。`footer` 打开时尾部还有 10 字节 `3DI...`，且不计入 header 的 size。
    private func legacyTag(payload: Int, footer: Bool) -> Data {
        var data = Data("ID3".utf8)
        data.append(contentsOf: [3, 0])                      // v2.3
        data.append(footer ? 0x10 : 0x00)
        data.append(ID3TagWriter.synchsafeBytes(payload))
        data.append(Data(repeating: 0, count: payload))
        if footer {
            data.append(Data("3DI".utf8))
            data.append(contentsOf: [3, 0, 0x10])
            data.append(ID3TagWriter.synchsafeBytes(payload))
        }
        return data
    }

    private func makePNG() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - 独立的解析器（故意不复用实现里那套）

    private struct Tag {
        var major: UInt8
        var flags: UInt8
        var frames: [(id: String, size: Data, body: Data)]
        var audio: Data

        func frame(_ id: String) -> Data? { frames.first { $0.id == id }?.body }
        func rawFrameSize(_ id: String) -> Data? { frames.first { $0.id == id }?.size }

        /// 文本 frame：第 1 字节是编码，剩下才是正文。
        func text(_ id: String) -> String? {
            guard let body = frame(id), body.count > 1 else { return nil }
            return String(data: body.subdata(in: 1..<body.count), encoding: .utf8)
        }
    }

    private func parse(_ url: URL) throws -> Tag {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.subdata(in: 0..<3), Data("ID3".utf8))
        let size = synchsafe(data, 6)
        var frames: [(id: String, size: Data, body: Data)] = []
        var offset = 10
        while offset + 10 <= 10 + size {
            guard data[offset] != 0 else { break }  // 进 padding 了
            let id = try XCTUnwrap(String(data: data.subdata(in: offset..<(offset + 4)),
                                          encoding: .isoLatin1))
            let sizeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
            let length = synchsafe(data, offset + 4)
            guard length > 0, offset + 10 + length <= 10 + size else { break }
            frames.append((id, sizeBytes,
                           data.subdata(in: (offset + 10)..<(offset + 10 + length))))
            offset += 10 + length
        }
        // padding 之后剩下的就是音频
        return Tag(major: data[3], flags: data[5], frames: frames,
                   audio: data.subdata(in: (10 + size)..<data.count))
    }

    private func synchsafe(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 7 | Int(data[offset + $1] & 0x7F) }
    }

    private func range(of needle: Data, in haystack: Data, from: Int) -> Int? {
        guard needle.count > 0, haystack.count >= needle.count,
              from <= haystack.count - needle.count else { return nil }
        for start in from...(haystack.count - needle.count)
        where haystack.subdata(in: start..<(start + needle.count)) == needle {
            return start
        }
        return nil
    }
}
