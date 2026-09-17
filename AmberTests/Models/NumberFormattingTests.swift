import XCTest
@testable import Amber

/// 「数字成串」那三个共用工具（`Models.swift`）。
///
/// 它们是阶段 6 为了躲开 `String(format:)` 的 C 变参而立的安全替代，出口是
/// **签名、密文串、配对码、缓存文件名**——少补一个零就是另一个值，而且当场不报错，
/// 要到服务端验签失败或封面串图时才发作。所以等价性必须钉在测试里，
/// 而不是只靠当初那次一次性的差分跑。
///
/// 对照基准就是被替换掉的那几个格式串：`%02d` / `%03d` / `%04d` / `%02x` / `%02X` / `%.Nf`。
/// 所以这个文件里到处是 `unsafe String(format:)`——它在这里的身份是**被对照的旧实现**，
/// 不是新写的不安全代码。不安全在于 C 变参（格式串与实参没人对），
/// 保证它安全的是：每一处的格式串都是字面量、实参就在同一行，且断言的另一边正是
/// 那个安全替代——真写错了，测试当场红给你看。
final class NumberFormattingTests: XCTestCase {

    // MARK: zeroPadded

    /// `width` 是**最小**宽度：够长就原样给，不截断（`%0Nd` 也不截断）。
    /// `InfoPanelForm.timeString` 靠的就是这条——毫秒万一进位到 1000 得照样显示三位以上。
    func testZeroPaddedKeepsOverlongValues() {
        XCTAssertEqual(1000.zeroPadded(to: 3), "1000")
        XCTAssertEqual(7.zeroPadded(to: 3), "007")
        XCTAssertEqual(0.zeroPadded(to: 2), "00")
    }

    /// 十进制补零与 `%02d` / `%03d` / `%04d` 逐字符一致，负数把零补在负号后面。
    func testZeroPaddedMatchesPrintfDecimal() {
        for value in -2000...2000 {
            unsafe XCTAssertEqual(value.zeroPadded(to: 2), String(format: "%02d", value), "value=\(value)")
            unsafe XCTAssertEqual(value.zeroPadded(to: 3), String(format: "%03d", value), "value=\(value)")
            unsafe XCTAssertEqual(value.zeroPadded(to: 4), String(format: "%04d", value), "value=\(value)")
        }
    }

    /// 十六进制两位与 `%02x` / `%02X` 逐字符一致（全部 256 个字节值）。
    func testZeroPaddedMatchesPrintfHex() {
        for byte in UInt8.min...UInt8.max {
            unsafe XCTAssertEqual(byte.zeroPadded(to: 2, radix: 16), String(format: "%02x", byte))
            unsafe XCTAssertEqual(byte.zeroPadded(to: 2, radix: 16, uppercase: true),
                           String(format: "%02X", byte))
        }
    }

    /// 四位十六进制与 `%04x` 一致（JSON 的 `\uXXXX` 转义走这条）。
    func testZeroPaddedMatchesPrintfFourDigitHex() {
        for value in stride(from: 0, through: 0xFFFF, by: 7) {
            unsafe XCTAssertEqual(value.zeroPadded(to: 4, radix: 16), String(format: "%04x", value))
        }
    }

    // MARK: hexString

    /// 与 `map { String(format: "%02x", $0) }.joined()` 逐字符一致，空序列给空串。
    func testHexStringMatchesPrintf() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0...64, using: &generator))
                .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            XCTAssertEqual(bytes.hexString(),
                           bytes.map { unsafe String(format: "%02x", $0) }.joined())
            XCTAssertEqual(bytes.hexString(uppercase: true),
                           bytes.map { unsafe String(format: "%02X", $0) }.joined())
        }
        XCTAssertEqual([UInt8]().hexString(), "")
    }

    /// 大小写不是无所谓的：网易 `encSecKey` 要小写、eapi `params` 与配对 GUID 要大写，
    /// 写反了对面直接不认。这条钉住两者确实不同。
    func testHexStringCaseIsDistinct() {
        let bytes: [UInt8] = [0x00, 0x0f, 0xab, 0xff]
        XCTAssertEqual(bytes.hexString(), "000fabff")
        XCTAssertEqual(bytes.hexString(uppercase: true), "000FABFF")
    }

    // MARK: fixed

    /// `fixed(_:)` 是外壳不是替换——里面仍是 `String(format:)`，所以它必须与 `%.Nf`
    /// **逐字符**一致，包括那个把 `FormatStyle` 排除掉的半分点：22.05 的双精度值略大于
    /// 22.05，printf 进位成 22.1，而按最短十进制表示舍入会给 22.0。
    func testFixedMatchesPrintf() {
        let samples: [Double] = [0, 1, 22.05, 44.1, 48, 96, 145140.45, 0.0005, -3.14159]
        for value in samples {
            for places in 0...3 {
                unsafe XCTAssertEqual(value.fixed(places),
                               String(format: "%.\(places)f", value),
                               "value=\(value) places=\(places)")
            }
        }
        XCTAssertEqual(22.05.fixed(1), "22.1")
    }
}
