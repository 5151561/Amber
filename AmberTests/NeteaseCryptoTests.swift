import XCTest
@testable import Amber

/// 网易云 eapi 加密。
///
/// 向量都是拿参考实现（NeteaseCloudMusicApiEnhanced 的 `util/crypto.js`、
/// `module/register_anonimous.js`）跑出来的黄金样本：这两段东西一旦算错，
/// 表现是服务端一律回 400/需要登录，从返回里看不出是哪一步错了，
/// 所以必须有能脱离网络定位到具体环节的样本。
final class NeteaseCryptoTests: XCTestCase {

    // MARK: - eapi

    /// 摘要单独立一条：`params` 对不上时先看它，能把「MD5 拼串写错」和
    /// 「AES/填充/十六进制大小写写错」两类问题分开。
    func testEapiDigestMatchesReference() {
        XCTAssertEqual(NeteaseCrypto.md5Hex("nobody/api/testuse{\"a\":1}md5forencrypt"),
                       "435f786c66f763a5cead90d96636d9d3")
    }

    func testEapiParamsMatchesReference() {
        let params = NeteaseCrypto.eapiParams(url: "/api/test", json: "{\"a\":1}")
        XCTAssertEqual(params, """
        4DC723619A991588865191FD2F319BAD0918BC9C604E1E84A5C3578922E3A7E8\
        810405B5500AF5BEABA2DEAB687471586CE47DE62C9D523E260A0250C7F3AC28\
        02B572BD7B95623F10A1D55EF99B9A8C
        """)
    }

    /// 密文能原样解回明文，且分隔串与摘要都在里面——服务端就是这么拆的。
    func testEapiParamsRoundTrip() throws {
        let params = NeteaseCrypto.eapiParams(url: "/api/test", json: "{\"a\":1}")
        let plain = try XCTUnwrap(NeteaseCrypto.decryptResponse(hex: params))
        XCTAssertEqual(String(data: plain, encoding: .utf8),
                       "/api/test-36cd479b6b5-{\"a\":1}-36cd479b6b5-435f786c66f763a5cead90d96636d9d3")
    }

    /// 请求体的键序会改变密文，所以序列化必须是有序的，不能退回 Dictionary。
    func testJSONSerializationKeepsFieldOrder() {
        let fields: [(String, NeteaseJSON)] = [
            ("id", .int(1901371647)), ("cp", false), ("tv", 0),
            ("name", .string("孤勇者")), ("quote", .string("a\"b\\c")),
        ]
        XCTAssertEqual(NeteaseJSON.serialize(fields),
                       "{\"id\":1901371647,\"cp\":false,\"tv\":0,\"name\":\"孤勇者\",\"quote\":\"a\\\"b\\\\c\"}")
    }

    // MARK: - 匿名 token

    /// 设备号 → 摘要 → username 三步分别验，错在哪一步一眼能看出来。
    func testAnonymousUsernameMatchesReference() {
        let deviceID = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123"
        XCTAssertEqual(NeteaseCrypto.anonymousDigest(deviceID: deviceID), "XkjHsj9vyWq5Q47Buv2Ucg==")
        XCTAssertEqual(NeteaseCrypto.anonymousUsername(deviceID: deviceID), """
        MDEyMzQ1Njc4OUFCQ0RFRjAxMjM0NTY3ODlBQkNERUYwMTIzNDU2Nzg5QUJDREVGMDEyMyBYa2pIc2o5dnlXcTVRNDdCdXYyVWNnPT0=
        """)
    }

    /// 设备号的形状是服务端认账的前提：52 位大写十六进制，少一位就注册不下来。
    func testRandomDeviceIDShape() {
        let deviceID = NeteaseCrypto.randomDeviceID()
        XCTAssertEqual(deviceID.count, 52)
        XCTAssertTrue(deviceID.allSatisfy { $0.isHexDigit && !$0.isLowercase })
    }

    // MARK: - 音质映射

    /// 映射规则是「不越级」：挑不高于所选档位的最高一档网易档。
    /// 640k 有损落到 320k 而不是往上凑无损，是这条规则唯一容易写反的地方。
    func testStreamQualityMapsWithoutUpgrading() {
        XCTAssertEqual(NeteaseAPI.neteaseLevel(for: .lossless), "lossless")
        XCTAssertEqual(NeteaseAPI.neteaseLevel(for: .ogg640), "exhigh")
        XCTAssertEqual(NeteaseAPI.neteaseLevel(for: .high), "exhigh")
        XCTAssertEqual(NeteaseAPI.neteaseLevel(for: .aac192), "higher")
        // 比网易云最低档还低的几档只能到底为 standard
        XCTAssertEqual(NeteaseAPI.neteaseLevel(for: .aac48), "standard")
    }

    // MARK: - 凭证

    func testCredentialCookieLookup() {
        let cookie = "MUSIC_U=abc123; __csrf=deadbeef"
        XCTAssertEqual(NeteaseCredential.value(of: "MUSIC_U", in: cookie), "abc123")
        XCTAssertEqual(NeteaseCredential.value(of: "__csrf", in: cookie), "deadbeef")
        XCTAssertNil(NeteaseCredential.value(of: "MUSIC_A", in: cookie))
        // 前缀相同的键不能误命中（MUSIC_U vs MUSIC_U_T）
        XCTAssertNil(NeteaseCredential.value(of: "MUSIC_U", in: "MUSIC_U_T=xyz"))
    }
}
