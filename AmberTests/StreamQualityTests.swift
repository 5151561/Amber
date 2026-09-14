import XCTest
@testable import Amber

/// 档位表本身。取流文件名 = 档位码 + media_mid + **该档真实的容器扩展名**——
/// 扩展名写错 CDN 直接 404，而服务端照样回一个 purl，所以这条最容易错又最不容易被发现。
/// 表里的码与容器都是 2026-09-05 对着线上逐个取回文件、解析容器头验过的。
final class StreamQualityTests: XCTestCase {

    func testLadderStartsAtTheChosenTierAndGoesDown() {
        XCTAssertEqual(StreamQuality.atmos.ladder, StreamQuality.allCases)
        XCTAssertEqual(StreamQuality.lossless.ladder.first, .lossless)
        XCTAssertEqual(StreamQuality.aac48.ladder, [.aac48])
        // 选了低档就不该往上够
        XCTAssertFalse(StreamQuality.standard.ladder.contains(.lossless))
        XCTAssertFalse(StreamQuality.standard.ladder.contains(.high))
    }

    func testEveryTierHasRungsAndADottedExtension() {
        for quality in StreamQuality.allCases {
            XCTAssertFalse(quality.rungs.isEmpty, "\(quality.rawValue) 没有档位码")
            for rung in quality.rungs {
                XCTAssertEqual(rung.code.count, 4, "\(rung.code) 不是四位档位码")
                XCTAssertTrue(rung.ext.hasPrefix("."), "\(quality.rawValue) 的扩展名少了点")
            }
        }
    }

    func testExtensionMatchesTheRealContainer() {
        let expected: [StreamQuality: String] = [
            .atmos: ".mp4",                                        // E-AC-3 JOC
            .surround: ".flac", .master: ".flac",                  // 6ch / 24bit·192k
            .premium: ".flac", .lossless: ".flac",
            .ogg640: ".ogg", .ogg192: ".ogg", .ogg96: ".ogg",
            .high: ".mp3", .standard: ".mp3",
            .aac192: ".m4a", .aac96: ".m4a", .aac48: ".m4a",
        ]
        XCTAssertEqual(Set(expected.keys), Set(StreamQuality.allCases), "有档位没写进期望表")
        for (quality, ext) in expected {
            for rung in quality.rungs {
                XCTAssertEqual(rung.ext, ext, "\(quality.rawValue) 的扩展名对不上容器")
            }
        }
    }

    func testDolbyLadderIsEAC3Only() {
        // D004/D008/D009 是 AC-4，macOS 解不了，不能混进来
        XCTAssertEqual(StreamQuality.atmos.rungs.map(\.code), ["D003", "D002", "D005"])
    }

    func testUndecodableTiersAreNotOffered() {
        // DTS:X 与 360RA（MPEG-H）线上有，但 macOS 没有解码器，实测只会空转不出声
        let codes = StreamQuality.allCases.flatMap { $0.rungs.map(\.code) }
        for absent in ["DT03", "RA01", "RA02", "RA03", "RA04"] {
            XCTAssertFalse(codes.contains(absent), "\(absent) 不该出现在档位表里")
        }
    }

    func testStoredPreferenceOfOlderVersionsStillResolves() {
        // 老版本只有这两档，UserDefaults 里存的是它们的 rawValue
        XCTAssertEqual(StreamQuality(rawValue: "320"), .high)
        XCTAssertEqual(StreamQuality(rawValue: "128"), .standard)
        XCTAssertNil(StreamQuality(rawValue: "dtsx"))
    }

    func testPickerGroupsKeepLadderOrder() {
        XCTAssertEqual(StreamQuality.groups.flatMap(\.qualities), StreamQuality.allCases)
        XCTAssertEqual(StreamQuality.groups.map(\.name), ["沉浸声", "无损", "有损"])
    }
}
