import XCTest
@testable import Amber

/// 网易云 weapi（网页身份）通道的加密。
///
/// 和 eapi 那组测试一个道理：这几步一旦算错，服务端的表现是一句笼统的错误，
/// 从返回里看不出是「AES 写错」还是「RSA 写错」还是「编码写错」，所以必须有
/// 能脱离网络定位到具体环节的黄金样本。
///
/// **向量怎么来的**：主会话先用 Python 把这条通道验通了
/// （脚本 `scratchpad/weapi.py`，用 `cryptography` 实现同一套算法，实际打通过
/// `POST /weapi/w/login/cellphone` 与 `/weapi/cellphone/existence/check`）。
/// 下面的期望值就是拿那份脚本、用**固定的 `secretKey`** 跑出来的输出原样贴进来的：
///
/// ```python
/// sk = "0123456789abcdef"
/// plain = '{"a":1,"b":"中文"}'
/// params    = aes_cbc_b64(aes_cbc_b64(plain.encode(), PRESET), sk.encode()).decode()
/// encSecKey = rsa_raw(sk[::-1])
/// ```
///
/// `secretKey` 之所以能从外面传，就是为了这组测试——线上那个是随机的，随机的对不了向量。
final class NeteaseWeapiCryptoTests: XCTestCase {

    // MARK: - 黄金向量

    /// 含非 ASCII 的明文，长度不是 16 的倍数（走普通 PKCS7 填充这一支）。
    /// `params` 与 `encSecKey` 两个字段都比——它们是两条独立的算法链，
    /// 只对其中一个，另一个错了照样发得出去、照样只回一句看不懂的错误。
    func testWeapiVectorMatchesPythonProbe() {
        let result = NeteaseCrypto.weapiParams(json: "{\"a\":1,\"b\":\"中文\"}",
                                               secretKey: "0123456789abcdef")
        XCTAssertEqual(result.params,
                       "A3xivfGJixyEaDsoukTkAQIh2FrQfVayvp0RHgMAqixbO+EArVVylzliLuWyb1Wi")
        XCTAssertEqual(result.encSecKey, """
        35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b9\
        49debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de9\
        48206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520e\
        a826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52
        """)
    }

    /// 第二组向量，两个作用：
    ///
    /// 1. 明文**正好 16 字节**——PKCS7 这时要多补满一整块，密文因此是 32 字节而不是 16。
    ///    这个坑只在特定长度的请求体上才炸，不钉死就等着某天某条接口莫名其妙 400。
    /// 2. 它的 `encSecKey` 是 `09` 开头的——RSA 的结果比模长短时必须**左侧补零**到 256 位
    ///    十六进制。自己拼 hex 很容易把这个前导零丢掉，丢了就是 255 个字符，服务端直接不认。
    func testWeapiVectorWithBlockAlignedPlaintextAndLeadingZero() {
        let json = "{\"abcdefghij\":1}"
        XCTAssertEqual(json.utf8.count, 16)
        let result = NeteaseCrypto.weapiParams(json: json, secretKey: "AAAAAAAAAAAAAAAA")
        XCTAssertEqual(result.params,
                       "3nWMC3JgmFiDezcH4Zqd+W1ydPoLVpljmrE6XafBC5rycrdUnb9Xb4sM6dGiWv16")
        XCTAssertTrue(result.encSecKey.hasPrefix("09"), "前导零丢了")
        XCTAssertEqual(result.encSecKey, """
        093601d1eae1e2c4478ba94b7f407da4b5feb00ff5e5383e4710bceac5f56773\
        9a5708c19e13f4d286a106720ec6d8af850b90d442aa623810a2c42fe43a66a8\
        79bde7031b99ab059bd28ad193501406923db7748b59468a13402bf65a0dedbf\
        36351d15175067d722db5bb386b7dd079c1d76ddd194cb342d307705264608dd
        """)
    }

    /// `encSecKey` 的形状：固定 256 个**小写**十六进制字符，随机 key 也一样。
    /// 写成大写或者长度不定，服务端一律不认，而错误话跟「验证码错了」长得一样。
    func testEncSecKeyShapeIsStable() {
        for _ in 0..<8 {
            let key = NeteaseCrypto.randomSecretKey()
            XCTAssertEqual(key.count, 16)
            XCTAssertTrue(key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
            let hex = NeteaseCrypto.weapiEncSecKey(secretKey: key)
            XCTAssertEqual(hex.count, 256)
            XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    /// 随机 key 每次都该不一样——它是一次一换的会话密钥，退化成常量等于白写。
    func testRandomSecretKeyIsNotConstant() {
        XCTAssertNotEqual(NeteaseCrypto.randomSecretKey(), NeteaseCrypto.randomSecretKey())
    }

    // MARK: - AES-128-CBC 本身

    /// PKCS7 的边界：明文正好一整块时**多补一整块**，密文 32 字节；
    /// 差一个字节时才是补到 16。这两条一起看才说明填充是对的。
    func testAESCBCPKCS7BlockBoundary() throws {
        let full = try XCTUnwrap(NeteaseCrypto.aesCBC(Data("0123456789abcdef".utf8),
                                                      key: NeteaseCrypto.weapiPresetKey,
                                                      iv: NeteaseCrypto.weapiIV, encrypt: true))
        XCTAssertEqual(full.count, 32)
        XCTAssertEqual(full.base64EncodedString(), "+s1cweq9MeCjimX+ZgluybzHbmuzT4s/M590yGxxOIU=")

        let short = try XCTUnwrap(NeteaseCrypto.aesCBC(Data("0123456789abcde".utf8),
                                                       key: NeteaseCrypto.weapiPresetKey,
                                                       iv: NeteaseCrypto.weapiIV, encrypt: true))
        XCTAssertEqual(short.count, 16)
        XCTAssertEqual(short.base64EncodedString(), "Lw5NcSyTmLG7t0xDE+PPTA==")
    }

    /// 解密能原样解回明文（含多字节字符），说明填充是被正确剥掉的。
    func testAESCBCRoundTrip() throws {
        let plain = "{\"phone\":\"13800138000\",\"名\":\"值\"}"
        let cipher = try XCTUnwrap(NeteaseCrypto.aesCBC(Data(plain.utf8),
                                                        key: NeteaseCrypto.weapiPresetKey,
                                                        iv: NeteaseCrypto.weapiIV, encrypt: true))
        let back = try XCTUnwrap(NeteaseCrypto.aesCBC(cipher, key: NeteaseCrypto.weapiPresetKey,
                                                      iv: NeteaseCrypto.weapiIV, encrypt: false))
        XCTAssertEqual(String(data: back, encoding: .utf8), plain)
    }

    /// key / iv 长度不对时返回 nil，而不是拿一段截断的密钥算出一串没人看得懂的密文。
    func testAESCBCRejectsWrongKeyOrIVLength() {
        let data = Data("hello".utf8)
        XCTAssertNil(NeteaseCrypto.aesCBC(data, key: "短了", iv: NeteaseCrypto.weapiIV, encrypt: true))
        XCTAssertNil(NeteaseCrypto.aesCBC(data, key: NeteaseCrypto.weapiPresetKey,
                                          iv: "0102", encrypt: true))
    }

    // MARK: - 常量

    /// 三个照抄 [api-enhanced] `util/crypto.js` 的常量。改一个字节请求就废，
    /// 而废的表现是服务端一句笼统的错误——所以钉在这里。
    func testWeapiConstantsMatchReference() {
        XCTAssertEqual(NeteaseCrypto.weapiIV, "0102030405060708")
        XCTAssertEqual(NeteaseCrypto.weapiPresetKey, "0CoJUm6Qyw8W8jud")
        XCTAssertEqual(NeteaseCrypto.weapiIV.utf8.count, 16)
        XCTAssertEqual(NeteaseCrypto.weapiPresetKey.utf8.count, 16)
    }
}
