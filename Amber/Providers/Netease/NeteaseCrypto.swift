import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 网易云 eapi 与 weapi 两条加密通道的算法。
///
/// eapi 是客户端身份（伪装成 iPhone 客户端），weapi 是**网页身份**——两者是并列关系，
/// 不是新旧替换：weapi 要不到 `level` / `yrc` 这些客户端字段，只在登录那条路上用
/// （见文件末尾的 `weapiParams`）。
///
/// 为什么非走 eapi 不可：明文 `/api/*` 那条路只能拿到 128k、且没有逐字歌词、没有登录态，
/// 而客户端自己用的 eapi 通道免登录就能取到 320k（`exhigh`）与`yrc`。
/// 协议本身没有签名与时间戳校验，只是把「路径 + 请求体 + 一段 md5」拿固定密钥
/// AES-128-ECB 加密后当 form 字段发出去——所以这里全是纯函数，可以脱离网络单测。
///
/// AES-ECB 只有 CommonCrypto 有（CryptoKit 只给 GCM/ChaChaPoly 这类带认证的模式，
/// 故意不暴露 ECB）；MD5 反过来只用 CryptoKit 的 `Insecure.MD5`——CommonCrypto 的
/// `CC_MD5` 从 10.15 起就带 deprecated 标注，用它会平白多一条编译警告。
enum NeteaseCrypto {

    /// eapi 的固定密钥，客户端里写死的，历年未变
    static let eapiKey = "e82ckenh8dichen8"
    /// 明文里分隔「路径 / 请求体 / 摘要」的魔法串
    private static let separator = "-36cd479b6b5-"
    /// 匿名注册用的异或密钥（`cloudmusic_dll_encode_id`）
    private static let anonymousXorKey = "3go8&$8*3*3h0k(2)2"

    // MARK: - 摘要

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func md5Hex(_ text: String) -> String {
        md5(Data(text.utf8)).hexString()
    }

    // MARK: - AES-128-ECB

    /// PKCS7 填充的 AES-ECB。key 直接取字符串的 UTF-8 字节（16 字节 = AES-128）。
    ///
    /// **这里的 `unsafe` 标在哪、谁保证它安全**（下面 `aesCBC` 与它逐字同构，不再重复说）：
    /// CommonCrypto 是纯 C 接口，进出都是裸指针加长度，没有安全替代——CryptoKit 只做
    /// AEAD 那几套，不提供 ECB/CBC，而这两个模式是网易那边定死的，换不得。
    /// 三处标记分别是两层 `withUnsafe*Bytes` 借出缓冲、以及 `CCCrypt` 本身。
    ///
    /// 指针有效性由 `withUnsafeBytes` 自己的作用域保证：`CCCrypt` 是同步调用，
    /// 指针不会活过闭包。长度这一侧由我们保证：输出缓冲 `capacity` 是
    /// `data.count + kCCBlockSizeAES128`，这是 PKCS7 最多补满一整块之后的上界，
    /// 递给 `CCCrypt` 的正是同一个 `capacity`，所以它写不出界；真正写了多少由
    /// `moved` 回报，末尾按它截断。`keyBytes.count` 上面刚校过是 16。
    static func aesECB(_ data: Data, key: String, encrypt: Bool) -> Data? {
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { return nil }
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = unsafe out.withUnsafeMutableBytes { outBuffer in
            unsafe data.withUnsafeBytes { inBuffer in
                unsafe CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                               CCAlgorithm(kCCAlgorithmAES),
                               CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                               keyBytes, keyBytes.count,
                               nil,
                               inBuffer.baseAddress, data.count,
                               outBuffer.baseAddress, capacity,
                               &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved...)
        return out
    }

    // MARK: - eapi 请求

    /// 生成 `params` 字段（大写十六进制）。
    ///
    /// `url` 是完整的`/api/xxx`（**不是**真正请求的`/eapi/xxx`），`json` 必须是
    /// 已经序列化好的请求体——密文只取决于明文字节，键序一变密文就变，
    /// 所以调用方得用 `NeteaseJSON` 这种有序结构，不能扔`Dictionary` 进来碰运气。
    static func eapiParams(url: String, json: String) -> String {
        let digest = md5Hex("nobody\(url)use\(json)md5forencrypt")
        let plain = "\(url)\(separator)\(json)\(separator)\(digest)"
        guard let cipher = aesECB(Data(plain.utf8), key: eapiKey, encrypt: true) else { return "" }
        return cipher.hexString(uppercase: true)
    }

    /// 解 eapi 的密文响应（`e_r` 那条路）。
    ///
    /// 实测绝大多数接口直接回明文 JSON，只有少数会回一整串十六进制密文；两种都得认，
    /// 所以调用方是「先按 JSON 解析，失败再交给这里」，而不是看请求参数猜。
    static func decryptResponse(hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cipher = data(fromHex: trimmed) else { return nil }
        return aesECB(cipher, key: eapiKey, encrypt: false)
    }

    static func data(fromHex hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    // MARK: - 设备号与匿名 token

    /// 52 位大写十六进制的设备号，格式照客户端。
    ///
    /// 一个实例固定一个就行：它同时是匿名 token 的种子，换一个就等于换一台设备重新注册。
    static func randomDeviceID() -> String {
        let hex = Array("0123456789ABCDEF")
        return String((0..<52).map { _ in hex.randomElement()! })
    }

    /// 设备号的摘要（`cloudmusic_dll_encode_id`）：按字符逐位异或（密钥循环）后取 MD5 原始
    /// 16 字节再 base64。
    ///
    /// 异或写成「按 Unicode 标量算、再拼回字符串取 UTF-8」是为了跟客户端那份 JS 逐字节对齐
    /// （`charCodeAt` ^ → `fromCharCode` → UTF-8 编码）。设备号只含`[0-9A-F]`、密钥全是 ASCII，
    /// 异或结果必定 < 0x80，所以这里和「直接按字节异或」等价——真正的区别只有在
    /// 设备号含非 ASCII 时才显出来，而那种设备号本身就不合法。
    static func anonymousDigest(deviceID: String) -> String {
        let key = Array(anonymousXorKey.unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for (index, scalar) in deviceID.unicodeScalars.enumerated() {
            let xored = scalar.value ^ key[index % key.count].value
            scalars.append(Unicode.Scalar(xored) ?? scalar)
        }
        return md5(Data(String(scalars).utf8)).base64EncodedString()
    }

    /// `/api/register/anonimous` 的 username 字段：`base64("<deviceId> <摘要>")`
    static func anonymousUsername(deviceID: String) -> String {
        Data("\(deviceID) \(anonymousDigest(deviceID: deviceID))".utf8).base64EncodedString()
    }

    // MARK: - weapi（网页身份）

    /// 以下四个常量全部照抄 [api-enhanced] `util/crypto.js` 的`weapi()`，逐条核对过。
    /// 它们是网页版 JS 里写死的，改一个字节请求就废了，**不要「优化」成别的取值**。

    /// AES-CBC 的初始向量，UTF-8 取字节
    static let weapiIV = "0102030405060708"
    /// 第一层 AES 的固定密钥，UTF-8 取字节
    static let weapiPresetKey = "0CoJUm6Qyw8W8jud"
    /// 随机密钥的字符集：a-zA-Z0-9
    private static let weapiBase62 =
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// RSA 公钥，1024 位，`e = 65537`。
    ///
    /// [api-enhanced] 里给的是 SPKI 的 PEM（`-----BEGIN PUBLIC KEY-----`），而
    /// `SecKeyCreateWithData` 只吃 **PKCS#1 的`RSAPublicKey`**——就是 SPKI 里剥掉算法头那一层
    /// 之后的 140 字节。这里存的是剥好的那份：SPKI 的 base64 从第 22 字节起就是它，
    /// 用 `cryptography` 的`public_bytes(DER, PKCS1)` 导出来的结果与之逐字节相同
    /// [主会话用 `scratchpad/weapi.py` 同目录的 golden.py 核对]。
    private static let weapiPublicKeyPKCS1 = """
        MIGJAoGBAOC1CfYlnfhkLbw1ZikBR33yJnfsFStf9orOYVu3tyUVKzqxeodq6opap20uQXYp7E7j\
        QfVhNfzPaVKAEE4DEuy9qSVXyThwEUr2ydBcT38MNoW3pGvuJVkyV1zOELQk2BPP5IddPoIEe5fd\
        71J0HVRrjiidxpNbPs4EYtsKIrjnAgMBAAE=
        """

    // MARK: AES-128-CBC

    /// PKCS7 填充的 AES-CBC。key 与 iv 都直接取字符串的 UTF-8 字节（各 16 字节）。
    ///
    /// 与上面那个 `aesECB` 分开写而不是合成一个带 mode 参数的：CBC 多一个 iv 要校长度，
    /// 揉在一起的那个版本每次读都得先想清楚「这次到底传没传 iv」。
    ///
    /// PKCS7 是 CommonCrypto 自己补的（`kCCOptionPKCS7Padding`），明文正好是 16 的倍数时
    /// 它会**多补满一整块** 16 个 `0x10`——这一点有单测钉着，因为「刚好整块时不补」是个
    /// 很容易自己写错、而且只在特定长度的请求体上才炸的坑。
    static func aesCBC(_ data: Data, key: String, iv: String, encrypt: Bool) -> Data? {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128, ivBytes.count == kCCBlockSizeAES128 else { return nil }
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        // 三处 `unsafe` 的契约同 `aesECB`，多出来的 `ivBytes` 上面也刚校过是 16 字节。
        let status = unsafe out.withUnsafeMutableBytes { outBuffer in
            unsafe data.withUnsafeBytes { inBuffer in
                unsafe CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                               CCAlgorithm(kCCAlgorithmAES),
                               CCOptions(kCCOptionPKCS7Padding),
                               keyBytes, keyBytes.count,
                               ivBytes,
                               inBuffer.baseAddress, data.count,
                               outBuffer.baseAddress, capacity,
                               &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved...)
        return out
    }

    // MARK: RSA（无填充）

    /// `RSA_NOPADDING`：把 128 字节原样当大整数做一次模幂。
    ///
    /// 用 Security 框架的 `.rsaEncryptionRaw` 而不是自己写大数模幂——1024 位的模幂手写一遍
    /// 就是一份没人复核过的密码学代码，而系统里本来就有一份。
    ///
    /// 输入必须**正好 128 字节**（模长）：短了系统会当成需要填充而报错，长了直接超模。
    /// 左侧补零这件事由调用方（`weapiEncSecKey`）负责，这里只校验、不猜。
    private static func rsaNoPadding(_ message: Data) -> Data? {
        guard message.count == 128,
              let der = Data(base64Encoded: weapiPublicKeyPKCS1) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, message as CFData, nil)
        else { return nil }
        return cipher as Data
    }

    // MARK: 请求参数

    /// 随机 16 个 base62 字符，当第二层 AES 的密钥。
    static func randomSecretKey() -> String {
        String((0..<16).map { _ in weapiBase62.randomElement()! })
    }

    /// `encSecKey`：把`secretKey` **反转**后的 16 字节左侧补零到 128 字节，
    /// 做一次无填充 RSA，输出**小写**十六进制（固定 256 个字符）。
    ///
    /// 「反转」不是笔误，网页版 JS 里就是 `text.split('').reverse().join('')`；
    /// 大小写也不是无所谓的——`%0256x` 出来的是小写，服务端对着这份字符串解，写成大写就对不上。
    static func weapiEncSecKey(secretKey: String) -> String {
        var padded = Data(count: 128 - secretKey.utf8.count)
        padded.append(contentsOf: secretKey.utf8.reversed())
        guard let cipher = rsaNoPadding(padded) else { return "" }
        return cipher.hexString()
    }

    /// weapi 的一对请求字段。
    ///
    /// **两层 AES**，容易看漏的是第二层的明文是第一层的 **base64 字符串**（不是它的原始字节）：
    ///
    /// ```
    /// inner  = base64(AES-CBC(明文JSON, presetKey, iv))
    /// params = base64(AES-CBC(inner,   secretKey, iv))
    /// ```
    ///
    /// `secretKey` 开放给调用方传，是为了单测能拿固定 key 对黄金向量——随机的对不了。
    /// 线上一律走默认的随机值：这个 key 是一次一换的会话密钥，复用它没有任何好处。
    ///
    /// 和 eapi 不同，weapi **对键序不敏感**（服务端把解出来的 JSON 当对象读，不再算摘要），
    /// 但请求体照样用 `NeteaseJSON` 序列化：省得为同一件事再造一套类型。
    static func weapiParams(json: String,
                            secretKey: String = randomSecretKey()) -> (params: String, encSecKey: String) {
        guard let inner = aesCBC(Data(json.utf8), key: weapiPresetKey, iv: weapiIV, encrypt: true),
              let outer = aesCBC(Data(inner.base64EncodedString().utf8),
                                 key: secretKey, iv: weapiIV, encrypt: true)
        else { return ("", "") }
        return (outer.base64EncodedString(), weapiEncSecKey(secretKey: secretKey))
    }
}

// MARK: - 有序 JSON

/// eapi 请求体专用的**有序** JSON 值。
///
/// 用它而不是 `[String: Any]` + `JSONSerialization` 的唯一原因：密文只取决于明文字节，
/// 而 `Dictionary` 的遍历顺序每次进程都不一样——同一个请求会算出不同的`params`，
/// 单测向量对不上，线上出了问题也没法照着复现。
indirect enum NeteaseJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                           ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case bool(Bool)
    case object([(String, NeteaseJSON)])
    /// 真数组。少数接口（云盘按 id 取详情/删除）参考实现发的就是 `[1,2]` 而不是字符串化的
    /// `"[1,2]"`，两者服务端不通用，所以这一档不能省。
    case array([NeteaseJSON])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }

    /// 紧凑序列化（无空格），非 ASCII 原样输出——与客户端的 `JSON.stringify` 一致
    var serialized: String {
        switch self {
        case .string(let value): return Self.quoted(value)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .object(let fields):
            let body = fields.map { "\(Self.quoted($0.0)):\($0.1.serialized)" }.joined(separator: ",")
            return "{\(body)}"
        case .array(let items):
            return "[\(items.map(\.serialized).joined(separator: ","))]"
        }
    }

    static func serialize(_ fields: [(String, NeteaseJSON)]) -> String {
        NeteaseJSON.object(fields).serialized
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + scalar.value.zeroPadded(to: 4, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
