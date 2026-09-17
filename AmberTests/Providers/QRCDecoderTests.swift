import XCTest
@testable import Amber

/// QRC 解码。
///
/// 分组密码用黄金样本对齐：密文取自 `GetPlayLyricInfo`（`qrc=1`）真实返回的前 6 个分组，
/// 明文是同一份数据用 QQMusicApi 的参考实现解出来的结果。取的是 zlib 流的开头，
/// 不含任何歌词文字，所以样本本身只是一串字节。
final class QRCDecoderTests: XCTestCase {

    /// 前 6 个分组（48 字节）。ECB 逐块独立，覆盖到这里就足以证明密钥编排和 S 盒都对。
    private let cipherHex = """
    E5D94A70C91F702238E3DD4AEC7EC2A6247F320388EA1F8FE34EFF03FEE92F31\
    62F7FB86BE0BF323723C21013978A282
    """
    private let expectedPlainHex = """
    789C4D9A5BAF56D77586EFF91588ABF5495F9A35CF735A71A328BD68ABDCB489\
    7A83B62A1AE314C981CAC6517D67871A
    """

    func testTripleDESMatchesGoldenVector() throws {
        let cipher = try QRCDecoder.bytes(fromHex: cipherHex)
        let plain = QRCDecoder.tripleDESDecrypt(cipher)
        let expected = try QRCDecoder.bytes(fromHex: expectedPlainHex)
        XCTAssertEqual(plain, expected)
    }

    /// 解出来的头两个字节必须是 zlib 魔数，否则后面 inflate 一定失败。
    func testPlaintextStartsWithZlibHeader() throws {
        let plain = QRCDecoder.tripleDESDecrypt(try QRCDecoder.bytes(fromHex: cipherHex))
        XCTAssertEqual(plain[0], 0x78)
        XCTAssertEqual(plain[1], 0x9C)
    }

    func testHexParsingRejectsOddLengthAndNonHex() {
        XCTAssertThrowsError(try QRCDecoder.bytes(fromHex: "ABC"))
        XCTAssertThrowsError(try QRCDecoder.bytes(fromHex: "ZZ"))
    }

    /// 正文是带真实换行的属性值，交给 XMLParser 会被折成空格，所以这里必须逐字保留。
    func testLyricContentKeepsNewlines() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <QrcInfos>
        <QrcHeadInfo SaveTime="269" Version="100"/>
        <LyricInfo LyricCount="1">
        <Lyric_1 LyricType="1" LyricContent="[ti:\u{6674}\u{5929}]
        [0,2250]\u{6674}(0,160)\u{5929}(160,160)
        [2250,2250]\u{8BCD}(2250,450)
        "/>
        </LyricInfo>
        </QrcInfos>
        """
        let content = QRCDecoder.lyricContent(in: xml)
        XCTAssertNotNil(content)
        let lines = content!.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "[ti:\u{6674}\u{5929}]")
        XCTAssertTrue(content!.contains("[0,2250]\u{6674}(0,160)\u{5929}(160,160)"))
    }

    func testLyricContentUnescapesEntities() {
        let xml = #"<Lyric_1 LyricContent="a &amp; b &lt;c&gt;"/>"#
        XCTAssertEqual(QRCDecoder.lyricContent(in: xml), "a & b <c>")
    }

    func testDecodePayloadFallsBackToBase64() {
        let lrc = "[00:01.00]hello\n[00:02.00]world"
        let b64 = Data(lrc.utf8).base64EncodedString()
        XCTAssertEqual(QRCDecoder.decodePayload(b64), lrc)
    }

    func testDecodePayloadRejectsGarbage() {
        XCTAssertNil(QRCDecoder.decodePayload(""))
        XCTAssertNil(QRCDecoder.decodePayload("not base64 and not hex !!!"))
    }

    /// 解出来的逐字格式要能被 LyricParser 直接吃下，并且真的产出音节。
    func testParserAcceptsDecodedQRC() {
        let qrc = """
        [ti:\u{6674}\u{5929}]
        [0,2250]\u{6674}(0,800)\u{5929}(800,800)
        [3000,2000]\u{6545}(3000,1000)\u{4E8B}(4000,1000)
        """
        let lines = LyricParser.parse(qrc).filter { $0.kind == .lyric }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].syllables.count, 2)
        XCTAssertEqual(lines[0].syllables[1].time, 0.8, accuracy: 0.001)
        XCTAssertEqual(lines[1].time, 3.0, accuracy: 0.001)
    }
}
