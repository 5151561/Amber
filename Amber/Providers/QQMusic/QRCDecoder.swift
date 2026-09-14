import Compression
import Foundation

/// QQ 音乐逐字歌词（QRC）解码。
///
/// `GetPlayLyricInfo` 的参数里带上 `qrc=1` 时，`lyric` / `trans` / `roma` 三个字段
/// 从「base64 的行级 LRC」变成「十六进制的密文」，匿名身份也给（不需要登录）。
/// 密文的处理链是：
///
/// ```
/// hex → 3DES-ECB（QQ 的变体）→ zlib inflate → <QrcInfos> XML → LyricContent
/// ```
///
/// 里面的 `LyricContent` 就是 `LyricParser` 已经认识的逐字格式：
/// `[行起点ms,行时长ms]字(起点ms,时长ms)…`。
///
/// **这不是标准 3DES。** 两处不一样，少一处都解不出来：
///
/// 1. **密钥编排是 D-E-D 且逆序**：解密方向用
///    `schedule(k3, 解) → schedule(k2, 加) → schedule(k1, 解)`，
///    密钥 24 字节切三段 `!@#)(*$%` / `123ZXC!@` / `!@#)(NHL`。
/// 2. **S 盒里有两个抄错的值**（S2[23] 应为 14 实为 15、S4[37] 应为 1 实为 10）。
///    源头是那份流传很广的 public-domain `des.c`，QQ 直接用了，于是错值成了协议的一部分——
///    这里必须原样照抄，改成教科书上的正确值反而解不开。
///
/// 算法出处：QQMusicApi（github.com/L-1124/QQMusicApi）的 `algorithms/tripledes.py`，
/// 它又来自 WXRIW/QQMusicDecoder 的 `DESHelper.cs`。这里是按算法重写的 Swift 实现，
/// 用 `AmberTests/QRCDecoderTests` 的黄金样本对齐过。
enum QRCDecoder {

    enum Failure: Error {
        case notHex
        case inflateFailed
        case notUTF8
        case noLyricContent
    }

    /// 24 字节 = 三段 8 字节子密钥
    private static let key: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    /// 密文（十六进制字符串）→ QRC 正文。
    static func decode(hex: String) throws -> String {
        let cipher = try bytes(fromHex: hex)
        let plain = tripleDESDecrypt(cipher)
        guard let inflated = inflate(plain) else { throw Failure.inflateFailed }
        guard let xml = String(data: inflated, encoding: .utf8) else { throw Failure.notUTF8 }
        guard let content = lyricContent(in: xml) else { throw Failure.noLyricContent }
        return content
    }

    /// 接口返回的字段可能是密文 hex，也可能是老的 base64 明文（不带 `qrc=1` 时）。
    /// 两种都收，认不出来就返回 nil。
    static func decodePayload(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if looksHex(raw) {
            if let text = try? decode(hex: raw), !text.isEmpty { return text }
        }
        if let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return nil
    }

    private static func looksHex(_ s: String) -> Bool {
        guard s.count >= 16, s.count % 2 == 0 else { return false }
        return s.allSatisfy(\.isHexDigit)
    }

    /// internal（非 private）以便 AmberTests 用黄金样本直接打分组密码。
    static func bytes(fromHex hex: String) throws -> [UInt8] {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw Failure.notHex }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: throw Failure.notHex
            }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            out.append(try nibble(chars[i]) << 4 | nibble(chars[i + 1]))
        }
        return out
    }

    // MARK: - XML

    /// `<Lyric_1 LyricType="1" LyricContent="…"/>`
    ///
    /// 不能交给 `XMLParser`：正文是带**真实换行**的属性值，而 XML 规范要求属性值归一化时
    /// 把换行折成空格，解析器一跑歌词就全挤成一行了。所以手工切。
    static func lyricContent(in xml: String) -> String? {
        guard let start = xml.range(of: "LyricContent=\"") else { return nil }
        let rest = xml[start.upperBound...]
        guard let end = rest.range(of: "\"/>", options: .backwards) else { return nil }
        let body = String(rest[..<end.lowerBound])
        return body
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - zlib

    /// `Compression` 的 `COMPRESSION_ZLIB` 实际是**裸 DEFLATE**，
    /// 所以要自己剥掉 zlib 的 2 字节头和 4 字节 adler32 尾。
    private static func inflate(_ data: [UInt8]) -> Data? {
        guard data.count > 6, data[0] == 0x78 else { return nil }
        let payload = Array(data[2..<(data.count - 4)])
        var out = Data()
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        return payload.withUnsafeBufferPointer { src -> Data? in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                switch compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    out.append(buffer, count: bufferSize - stream.dst_size)
                    if stream.dst_size != 0 { return out.isEmpty ? nil : out }
                default:
                    return nil
                }
            }
        }
    }

    // MARK: - 3DES（QQ 变体）

    /// internal（非 private）以便 AmberTests 用黄金样本直接打分组密码。
    static func tripleDESDecrypt(_ cipher: [UInt8]) -> [UInt8] {
        // 解密方向：D(k3) → E(k2) → D(k1)
        let schedules = [
            keySchedule(Array(key[16..<24]), decrypt: true),
            keySchedule(Array(key[8..<16]), decrypt: false),
            keySchedule(Array(key[0..<8]), decrypt: true),
        ]
        var out = [UInt8]()
        out.reserveCapacity(cipher.count)
        var block = [UInt8](repeating: 0, count: 8)
        var index = 0
        while index + 8 <= cipher.count {
            for i in 0..<8 { block[i] = cipher[index + i] }
            for schedule in schedules { block = cryptBlock(block, schedule) }
            out.append(contentsOf: block)
            index += 8
        }
        return out
    }

    private static func cryptBlock(_ input: [UInt8], _ schedule: [[UInt8]]) -> [UInt8] {
        var (s0, s1) = initialPermutation(input)
        for round in 0..<15 {
            let previous = s1
            s1 = feistel(s1, schedule[round]) ^ s0
            s0 = previous
        }
        s0 = feistel(s1, schedule[15]) ^ s0
        return inversePermutation(s0, s1)
    }

    /// 初始置换。字是**小端**装载的（标准 DES 是大端），这是这个变体的第三处不同。
    private static func initialPermutation(_ b: [UInt8]) -> (UInt32, UInt32) {
        let v0 = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let v1 = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        func gather(_ bases: [UInt32]) -> UInt32 {
            var value: UInt32 = 0
            var bit = 31
            for base in bases {
                for source in [v1, v0] {
                    for k in 0..<4 {
                        value |= ((source >> (base + UInt32(8 * k))) & 1) << UInt32(bit)
                        bit -= 1
                    }
                }
            }
            return value
        }
        return (gather([6, 4, 2, 0]), gather([7, 5, 3, 1]))
    }

    private static func inversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        let order: [Int] = [3, 2, 1, 0, 7, 6, 5, 4]
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            var byte: UInt8 = 0
            for j in 0..<4 {
                let shift = UInt32(8 * (3 - j) + i)
                byte |= UInt8((s1 >> shift) & 1) << UInt8(7 - 2 * j)
                byte |= UInt8((s0 >> shift) & 1) << UInt8(6 - 2 * j)
            }
            out[order[i]] = byte
        }
        return out
    }

    /// S 盒查表前要把 6 位下标重排：最高位不动，低 5 位右移一位，最低位挪到第 4 位。
    private static func sboxIndex(_ a: Int) -> Int {
        (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4)
    }

    private static func feistel(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1 = ((state & 1) << 31)
            | ((state & 0xF800_0000) >> 1)
            | ((state & 0x1F80_0000) >> 3)
            | ((state & 0x01F8_0000) >> 5)
            | ((state & 0x001F_8000) >> 7)
        let t2 = ((state & 0x0001_F800) << 15)
            | ((state & 0x0000_1F80) << 13)
            | ((state & 0x0000_01F8) << 11)
            | ((state & 0x0000_001F) << 9)
            | ((state & 0x8000_0000) >> 23)

        let k0 = Int((t1 >> 24) & 0xFF) ^ Int(key[0])
        let k1 = Int((t1 >> 16) & 0xFF) ^ Int(key[1])
        let k2 = Int((t1 >> 8) & 0xFF) ^ Int(key[2])
        let k3 = Int((t2 >> 24) & 0xFF) ^ Int(key[3])
        let k4 = Int((t2 >> 16) & 0xFF) ^ Int(key[4])
        let k5 = Int((t2 >> 8) & 0xFF) ^ Int(key[5])

        var mixed: UInt32 = 0
        mixed |= UInt32(sbox[0][sboxIndex(k0 >> 2)]) << 28
        mixed |= UInt32(sbox[1][sboxIndex(((k0 & 0x03) << 4) | (k1 >> 4))]) << 24
        mixed |= UInt32(sbox[2][sboxIndex(((k1 & 0x0F) << 2) | (k2 >> 6))]) << 20
        mixed |= UInt32(sbox[3][sboxIndex(k2 & 0x3F)]) << 16
        mixed |= UInt32(sbox[4][sboxIndex(k3 >> 2)]) << 12
        mixed |= UInt32(sbox[5][sboxIndex(((k3 & 0x03) << 4) | (k4 >> 4))]) << 8
        mixed |= UInt32(sbox[6][sboxIndex(((k4 & 0x0F) << 2) | (k5 >> 6))]) << 4
        mixed |= UInt32(sbox[7][sboxIndex(k5 & 0x3F)])

        var out: UInt32 = 0
        for (i, shift) in permutationP.enumerated() {
            out |= ((mixed >> UInt32(shift)) & 1) << UInt32(31 - i)
        }
        return out
    }

    private static func keySchedule(_ key: [UInt8], decrypt: Bool) -> [[UInt8]] {
        let shifts: [UInt32] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
        let v0 = UInt32(key[0]) | UInt32(key[1]) << 8 | UInt32(key[2]) << 16 | UInt32(key[3]) << 24
        let v1 = UInt32(key[4]) | UInt32(key[5]) << 8 | UInt32(key[6]) << 16 | UInt32(key[7]) << 24

        func permute(_ table: [Int]) -> UInt32 {
            var value: UInt32 = 0
            for (i, b) in table.enumerated() {
                let bit = b < 32 ? (v0 >> UInt32(31 - b)) & 1 : (v1 >> UInt32(63 - b)) & 1
                value |= bit << UInt32(31 - i)
            }
            return value
        }
        var c = permute(keyPermC)
        var d = permute(keyPermD)

        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        for i in 0..<16 {
            let s = shifts[i]
            c = ((c << s) | (c >> (28 - s))) & 0xFFFF_FFF0
            d = ((d << s) | (d >> (28 - s))) & 0xFFFF_FFF0
            let target = decrypt ? 15 - i : i
            for j in 0..<24 {
                let bit = (c >> UInt32(31 - keyCompression[j])) & 1
                schedule[target][j / 8] |= UInt8(bit) << UInt8(7 - j % 8)
            }
            for j in 24..<48 {
                let bit = (d >> UInt32(31 - (keyCompression[j] - 27))) & 1
                schedule[target][j / 8] |= UInt8(bit) << UInt8(7 - j % 8)
            }
        }
        return schedule
    }

    // MARK: - 表
    //
    // PC-1（拆成 C/D 两半）、PC-2、P 置换都是标准 DES 的表。
    // S 盒是标准表**外加两个抄错的值**（见类型注释），照抄不改。

    private static let keyPermC = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17,
                                   9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let keyPermD = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21,
                                   13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let keyCompression = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3,
                                         25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39,
                                         50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]
    /// F 函数末尾的 P 置换：输出第 31 位取 `mixed >> 16`，第 30 位取 `>> 25`，依此类推。
    private static let permutationP = [16, 25, 12, 11, 3, 20, 4, 15, 31, 17, 9, 6, 27, 14, 1, 22,
                                       30, 24, 8, 18, 0, 5, 29, 23, 13, 19, 2, 26, 10, 21, 28, 7]

    private static let sbox: [[UInt8]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
         0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
         15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        // 下标 23 这里是 15，标准 DES 是 14——QQ 沿用的 des.c 抄错了，必须保留
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
         3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
         13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
         13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
         1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        // 下标 37 这里是 10，标准 DES 是 1——同上，抄错的值是协议的一部分
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
         13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
         3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
         14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
         11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
         10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
         4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
         13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
         6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
         1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
         2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
}
