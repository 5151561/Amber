import XCTest
@testable import Amber

final class QQCookieParserTests: XCTestCase {

    func testBasicCookie() throws {
        let cred = try parseQQCookie("qqmusic_key=abc123; qqmusic_uin=123456789")
        XCTAssertEqual(cred.uin, "123456789")
        XCTAssertTrue(cred.cookie.contains("qqmusic_key=abc123"))
    }

    func testKeystCookie() throws {
        let cred = try parseQQCookie("qm_keyst=xyz789; uin=88888888")
        XCTAssertEqual(cred.uin, "88888888")
        // 自动补上 qqmusic_uin
        XCTAssertTrue(cred.cookie.contains("qqmusic_uin=88888888"))
    }

    func testUinWithOPrefix() throws {
        let cred = try parseQQCookie("qqmusic_key=abc; qqmusic_uin=o123456789")
        XCTAssertEqual(cred.uin, "123456789")
    }

    func testPlainUinWithOPrefix() throws {
        let cred = try parseQQCookie("qqmusic_key=abc; uin=o987654321")
        XCTAssertEqual(cred.uin, "987654321")
    }

    func testCookiePrefixStripped() throws {
        let cred = try parseQQCookie("Cookie: qqmusic_key=abc; qqmusic_uin=123456789")
        XCTAssertEqual(cred.uin, "123456789")
        XCTAssertFalse(cred.cookie.lowercased().hasPrefix("cookie:"))
    }

    func testMultilineTakesFirstLine() throws {
        let cred = try parseQQCookie("qqmusic_key=abc; qqmusic_uin=11111111\nsecond line junk")
        XCTAssertEqual(cred.uin, "11111111")
        XCTAssertFalse(cred.cookie.contains("second"))
    }

    func testMissingSessionKeyThrows() {
        XCTAssertThrowsError(try parseQQCookie("uin=123456789")) { error in
            XCTAssertEqual(error as? CookieParseError, .missingSessionKey)
        }
    }

    func testMissingUinThrows() {
        XCTAssertThrowsError(try parseQQCookie("qqmusic_key=abc")) { error in
            XCTAssertEqual(error as? CookieParseError, .missingUin)
        }
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try parseQQCookie("   ")) { error in
            XCTAssertEqual(error as? CookieParseError, .empty)
        }
    }
}
