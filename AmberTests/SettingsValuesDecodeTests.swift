import XCTest
@testable import Amber

/// `SettingsValues.decode`：设置整份按 JSON 存一个键，每加一个字段都不能把用户已存的设置清掉。
///
/// 只测这个纯函数，不碰 `AppSettings`——测试宿主就是 Amber 本身，
/// `UserDefaults.standard` 是开发者本人那份真实偏好（见 `SettingsDraftTests` 里的同款注意）。
final class SettingsValuesDecodeTests: XCTestCase {

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// 缺键 = 新加的字段：在场的键照读回来，缺的键落该字段的出厂值。
    func testMissingKeysFallBackToFactoryDefaults() {
        let factory = SettingsValues()
        // 出厂值：syncLibrary true / losslessEnabled true / playQueueAutoplay false
        XCTAssertTrue(factory.syncLibrary)
        XCTAssertTrue(factory.losslessEnabled)
        XCTAssertFalse(factory.playQueueAutoplay)

        // 一份「playQueueAutoplay 这个字段还不存在」时存下来的设置
        let decoded = SettingsValues.decode(json([
            "syncLibrary": false,
            "losslessEnabled": false,
            "soundEnhancerLevel": 200,
            "downloadQuality": "128",   // StreamQuality.standard 的 rawValue
            "largerText": "lyrics"
        ]))

        // 在场的键 = 存的值
        XCTAssertFalse(decoded.syncLibrary)
        XCTAssertFalse(decoded.losslessEnabled)
        XCTAssertEqual(decoded.soundEnhancerLevel, 200)
        XCTAssertEqual(decoded.downloadQuality, .standard)
        XCTAssertEqual(decoded.largerText, .lyrics)

        // 缺的键 = 出厂值，而不是整份回落
        XCTAssertEqual(decoded.playQueueAutoplay, factory.playQueueAutoplay)
        XCTAssertEqual(decoded.crossfadeStyle, factory.crossfadeStyle)
        XCTAssertEqual(decoded.videoDownloadQuality, factory.videoDownloadQuality)
        XCTAssertEqual(decoded.useToolbarInMiniPlayer, factory.useToolbarInMiniPlayer)
        XCTAssertNil(decoded.mediaFolderPath)
    }

    /// 只存了一个键的极端情形：其余全是出厂值，等价于「只改过一项」。
    func testSingleKeyJSONKeepsEverythingElseFactory() {
        var expected = SettingsValues()
        expected.soundCheck = true
        XCTAssertEqual(SettingsValues.decode(json(["soundCheck": true])), expected)
    }

    /// 存的 JSON 里留着删掉过的旧键：合并后多出来的键没人认，解码照样成功。
    func testUnknownKeysAreIgnored() {
        let decoded = SettingsValues.decode(json([
            "soundCheck": true,
            "someRemovedFlag": true,
            "anotherOldKey": "whatever",
            "oldNestedThing": ["a": 1]
        ]))
        XCTAssertTrue(decoded.soundCheck)
        XCTAssertEqual(decoded.losslessEnabled, SettingsValues().losslessEnabled)
    }

    /// 整份存回去再读出来必须一模一样——合并这条路不能把已存的值读歪。
    func testRoundTripPreservesEveryField() {
        var values = SettingsValues()
        values.syncLibrary = false
        values.automaticDownloads = true
        values.largerText = .lyrics
        values.crossfade = true
        values.crossfadeStyle = .smart
        values.playQueueAutoplay = true
        values.soundEnhancerLevel = 42
        values.downloadQuality = .high
        values.dolbyAtmos = .off
        values.videoStreamQuality = .good
        values.importEncoder = .mp3
        values.importPreset = .spokenPodcast
        values.mediaFolderPath = "/tmp/am-media-folder"
        values.useToolbarInMiniPlayer = false

        let data = try! JSONEncoder().encode(values)
        XCTAssertEqual(SettingsValues.decode(data), values)
    }

    /// 空数据 / 坏数据 / 不是对象的 JSON：回落出厂值。
    func testEmptyOrCorruptDataFallsBackToFactory() {
        let factory = SettingsValues()
        XCTAssertEqual(SettingsValues.decode(Data()), factory)
        XCTAssertEqual(SettingsValues.decode(Data("not json at all".utf8)), factory)
        XCTAssertEqual(SettingsValues.decode(Data("[1,2,3]".utf8)), factory)
        XCTAssertEqual(SettingsValues.decode(Data("{}".utf8)), factory)
    }

    /// 值类型对不上（enum 的 rawValue 改了名、Bool 换成了别的类型）**仍会整份回落出厂值**。
    /// 这是现状，不是遗漏：一个键的值坏掉时没法只把这个键判死，真要改 rawValue 得写迁移。
    func testTypeMismatchStillFallsBackWholesale() {
        let factory = SettingsValues()
        let decoded = SettingsValues.decode(json([
            "soundCheck": true,               // 这个键本来是好的
            "downloadQuality": "no-such-tier" // 但这个 rawValue 不认识
        ]))
        XCTAssertEqual(decoded, factory)
        XCTAssertFalse(decoded.soundCheck)
    }
}
