import XCTest
@testable import Amber

/// QRC 解码。
///
/// **两份黄金样本，各盯一截。**
///
/// 一份盯**分组密码**：密文取自 `GetPlayLyricInfo`（`qrc=1`）真实返回的前 6 个分组，
/// 明文是同一份数据用 QQMusicApi 的参考实现解出来的结果。取的是 zlib 流的开头，
/// 不含任何歌词文字，所以样本本身只是一串字节。
///
/// 另一份盯**整条链**（`realCipherHex` / `expectedLyric`，见下面的「端到端黄金样本」）：
/// 一首短儿歌的完整密文与它解出来的完整正文。上一份只走到 3DES 出口为止，`inflate`
/// 之后的三段（zlib、XML 切分、实体反转义）在它下面一条覆盖都没有——换 `inflate` 实现
/// 时才发现这个洞，所以补在这里。
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

    // MARK: - 端到端黄金样本

    /// 一份**真密文**：`GetPlayLyricInfo`（`songMid=002rAxad3E6yJJ`、`qrc=1`、`crypt=0`，
    /// 匿名，[取于 2026-09-17 curl]）返回的 `lyric` 字段原文，720 字节 = 90 个 3DES 分组。
    ///
    /// 挑这首儿歌只因为它是手边最短的一份**完整**密文。不截长歌的原因是这条链的两截
    /// 断法不同：3DES 是 ECB，砍一半照样解得动分组；zlib 流砍一刀就不再是一条流，
    /// 那验的就不是解码而是「半截流怎么办」了（那个另有一条测试，见下）。
    private let realCipherHex = """
    BD004366E8FDB7B45DC198D4DF7BE69592F56954D349F867050DAB4FEB812221\
    47D8CF88B8947FDFD48D0582CC5B6318D33AF813F4041B98F3A9F8E305B9815F\
    DD5AA649518DA95FCD0962C3EE799369724C4EDB8156871C2B8C88EFBA1D2E49\
    B85DE0CA8AC7DE53517C90A7746BDF1E414ACFE3501590B352DE78253796168E\
    F15A96372E1E8A2DE6E030C4805972D6976CB904C6EFAFE1B6A1D24533C1E6FC\
    307AF8C04420F5CC81157B399215410CDB235CDDEBA87A5DB13924DFEAE08905\
    22D8270677A622AD1AC81AFB5CB542F76CDDF2E457EF62AF9D3B7ECC280A8A5D\
    0C201469A661AE7B5FCFA8C33B6A2A1B1DD6F65939249D5870EFD0EEA7DE5644\
    DAFF29876955295767CA28B20209161C27605954ACC8CE6078D27DC0801CE50C\
    6FD62C3E5643B7483E5AFB30ABBB08063FB4D3B6AA99C7BA7AE2D21A68DDC237\
    87AE4010FE1F249F3D9936AB01D7E9841C13BE8D1994B726A9CD8D29997726B9\
    422C2E42519766F642DCA3B0DE7B158643C48AC1BA6D79726584AAFEAD401D2B\
    0BCCA0B9B89B2BB1056C2442DEDF8F374863A42EB269AB87BF7AA271ACBEA25C\
    CB17D839341E8BC88A5D011D5B1702E7FADC0615DF0F77E22187EBF2FD4B5485\
    8792394A53EA33094043C0368E3070C83E4C44FD79116EA7DA398B497E17ECF6\
    870DBC68546328D25E8DDB7A451FD2C52FF3026A57BD2EF827B000C186FDEB6B\
    ED85E2571C56783E79A9F0A6D8A3543208D18705FF7AFB79F435C6A603C93407\
    4CD6B45984B68A929A31EC51FA779755A629D758010E8FB3D10C5F70F8119F2F\
    860BB3586AA522C21A9540CC5551C69558E2C8C6C4814352614CE347D6A555F7\
    F57167DD436F0C1AC02ED19C8E18E82F62CDB2E575F52BB2FAD39A7FB814E06B\
    0AA5003146C7725C15ACBDCCCCDCABF9C4DE45769584E6C2E2554FB3E3BA633E\
    3E615965F83FD8FD0DDA98CD7C1C2120242E0CCCF6C3FB8DF2E71D6D2028A8DF\
    95D7A6AE2443E47CE54ACA68C3765F56
    """

    /// 上面那份密文解出来的正文，**逐字节**存档（1014 字节 UTF-8、13 行，末尾带换行）。
    ///
    /// 这条黄金样本是为换 `inflate` 实现立的标尺：从手写 `compression_stream` 循环换成
    /// `NSData.decompressed(using: .zlib)` 前后，这里一个字节都不许动。前 5 行是 QRC 的
    /// 元信息行（`LyricParser` 会当标签跳过），后 8 行是逐字正文——注意最后三行的音节时长
    /// 长得离谱（一个字 22 秒），那是源数据本来就这样，不是解错了。
    private let expectedLyric = """
    [ti:小星星 (一闪一闪亮晶晶)]
    [ar:宝宝儿歌 快乐启蒙]
    [al:]
    [by:krc转qrc工具]
    [offset:0]
    [8920,3850]一(8920,420)闪(9340,720)一(10060,300)闪(10360,630)亮(10990,510)晶(11500,500)晶(12000,770)
    [13070,3750]满(13070,480)天(13550,560)都(14110,420)是(14530,490)小(15020,550)星(15570,530)星(16100,720)
    [17140,3800]挂(17140,550)在(17690,490)天(18180,510)上(18690,540)放(19230,550)光(19780,520)明(20300,640)
    [21240,3850]好(21240,540)像(21780,500)许(22280,580)多(22860,420)小(23280,670)眼(23950,510)睛(24460,630)
    [25520,3700]一(25520,390)闪(25910,710)一(26620,320)闪(26940,640)亮(27580,490)晶(28070,540)晶(28610,610)
    [29600,8832]满(29600,530)天(30130,520)都(30650,420)是(31070,530)小(31600,510)星(32110,5292)星(37402,1030)
    [41362,35440]挂(41362,8920)在(50282,14890)天(65172,4210)上(69382,3620)放(73002,2630)光(75632,520)明(76152,650)
    [77162,50302]好(77162,480)像(77642,9270)许(86912,22932)多(109844,3580)小(113424,9870)眼(123294,3120)睛(126414,1050)

    """

    /// 端到端：密文 → 3DES → inflate → XML → 正文。整条链只有这一条测试跑全。
    func testDecodesRealCiphertextToGoldenLyric() throws {
        XCTAssertEqual(try QRCDecoder.decode(hex: realCipherHex), expectedLyric)
    }

    /// `decodePayload` 认出是 hex 之后走的就是上面那条链，结果必须一模一样。
    func testDecodePayloadTakesTheSameRouteForHex() {
        XCTAssertEqual(QRCDecoder.decodePayload(realCipherHex), expectedLyric)
    }

    /// 解出来的正文交给 `LyricParser` 要真能变成逐字行（8 行、每行 7 个音节）。
    func testGoldenLyricFeedsParser() throws {
        let lines = LyricParser.parse(try QRCDecoder.decode(hex: realCipherHex))
            .filter { $0.kind == .lyric }
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines.map(\.syllables.count), [7, 7, 7, 7, 7, 7, 7, 7])
        XCTAssertEqual(lines[0].time, 8.92, accuracy: 0.001)
        XCTAssertEqual(lines[0].syllables.map(\.text).joined(), "一闪一闪亮晶晶")
    }

    // MARK: - inflate 的失败路径

    /// 解不开的密文一律**抛**，不崩、不返回空串、也不交半截正文。
    /// 抛的都是 `.inflateFailed`：这几种输入 3DES 照样出得来 720 个字节，
    /// 只是解出来的头一个字节不是 `0x78`、或者后面那段不是 DEFLATE。
    func testUninflatableCiphertextThrows() {
        let cases: [(String, String)] = [
            ("空串", ""),
            ("一个全零分组", String(repeating: "0", count: 16)),
            ("八个全零分组", String(repeating: "0", count: 128)),
            ("八个全 F 分组", String(repeating: "F", count: 128)),
            ("伪随机 128 字节",
             (0..<128).map { String(format: "%02X", ($0 &* 37) & 0xFF) }.joined()),
            // crypt=1 匿名下回的那种 20 字节残片（见 QQAPI+Lyric 文件头的警告）
            ("20 字节残片", String(repeating: "A", count: 40)),
        ]
        for (name, hex) in cases {
            XCTAssertThrowsError(try QRCDecoder.decode(hex: hex), name) { error in
                XCTAssertEqual(error as? QRCDecoder.Failure, .inflateFailed, name)
            }
        }
    }

    /// **截断的密文必须失败，不许把半截正文当成功交出去。**
    ///
    /// 这一条是 `inflate` 从手写循环换成 `NSData.decompressed(using:)` 时**有意改掉**的行为，
    /// 立在这里免得哪天被「修」回去：老写法拿 `COMPRESSION_STREAM_FINALIZE` 跑一轮，
    /// 流中途断掉时 libcompression 回的是 `OK` 而不是 `ERROR`，循环分不出「收尾了」和
    /// 「输入不够了」，于是把解到一半的字节当成功返回。绝大多数截断点上下游照样报错
    /// （半截 XML 里没有收尾的 `"/>`，只是抛 `.noLyricContent` 而不是 `.inflateFailed`），
    /// 但**去掉末尾 1 个分组**这个窄窗例外：丢掉的字节恰好只编码了 `</LyricInfo></QrcInfos>`，
    /// 老写法会把完整正文捞回来，装作什么都没发生。现在这三种一律 `.inflateFailed`。
    func testTruncatedCiphertextFailsInsteadOfYieldingPartialText() {
        for dropBlocks in [1, 8, 45] {
            let cut = String(realCipherHex.prefix(realCipherHex.count - dropBlocks * 16))
            XCTAssertThrowsError(try QRCDecoder.decode(hex: cut), "去掉末尾 \(dropBlocks) 块") { error in
                XCTAssertEqual(error as? QRCDecoder.Failure, .inflateFailed)
            }
            XCTAssertNil(QRCDecoder.decodePayload(cut), "去掉末尾 \(dropBlocks) 块")
        }
    }
}
