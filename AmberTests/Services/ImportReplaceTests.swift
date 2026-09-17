import XCTest
@testable import Amber

/// 导入撞名的三分支（spec §10.4，res 500 idx 124/125/126 `[RES]`）。
///
/// 只测**不需要弹窗**的那一半：分支怎么选、时间取不到时怎么回落、那句话填出来长什么样。
/// 真起 `NSAlert` 的那半截不进测试——模态窗在 `xcodebuild test` 里是会挂住的。
final class ImportReplaceTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 分支判定

    /// 资料库里那份**更旧** → idx 125。
    func testExistingOlderPicksOlderBranch() {
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: epoch,
                                                  incomingModified: epoch.addingTimeInterval(60)),
                       .existingIsOlder)
    }

    /// 资料库里那份**更新** → idx 126（拿旧的覆盖新的，措辞升级成「确定要」）。
    func testExistingNewerPicksNewerBranch() {
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: epoch.addingTimeInterval(60),
                                                  incomingModified: epoch),
                       .existingIsNewer)
    }

    /// 两边一样新：谁也不比谁旧，回落到中性的 idx 124。
    func testEqualTimestampsFallBackToUnversioned() {
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: epoch, incomingModified: epoch),
                       .unversioned)
    }

    /// 任意一边取不到时间就回落 124——「谁新谁旧」没结论时不许硬猜一个方向，
    /// 猜错就会把「确定要」那句强措辞念到不该念的人头上。
    func testMissingTimestampFallsBackToUnversioned() {
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: nil, incomingModified: epoch),
                       .unversioned)
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: epoch, incomingModified: nil),
                       .unversioned)
        XCTAssertEqual(ImportReplacePrompt.branch(existingModified: nil, incomingModified: nil),
                       .unversioned)
    }

    // MARK: - 文案

    /// 三句各念各的，且 `%1$S` 真被曲目名填上了（别留一个占位符在界面上）。
    func testMessagesMatchBranchWording() {
        let unversioned = ImportReplacePrompt.message(for: .unversioned, title: "Emily")
        let older = ImportReplacePrompt.message(for: .existingIsOlder, title: "Emily")
        let newer = ImportReplacePrompt.message(for: .existingIsNewer, title: "Emily")
        XCTAssertEqual(unversioned, "音乐资料库中已经存在项目“Emily”。你想使用正在移动的项目进行替换吗？")
        XCTAssertEqual(older, "音乐资料库中已经存在项目“Emily”的较旧版本。你想使用正在移动的项目进行替换吗？")
        XCTAssertEqual(newer, "音乐资料库中已经存在项目“Emily”的较新版本。确定要使用正在移动的项目进行替换吗？")
        for text in [unversioned, older, newer] { XCTAssertFalse(text.contains("%1$S")) }
    }

    /// 曲目名里带个 `%` 也不能出事——这正是不走 `String(format:)` 的理由。
    func testPercentInTitleSurvives() {
        XCTAssertEqual(ImportReplacePrompt.message(for: .unversioned, title: "100% Pure Love"),
                       "音乐资料库中已经存在项目“100% Pure Love”。你想使用正在移动的项目进行替换吗？")
    }

    /// 批量那句（res 9003 idx 3）不带占位符：它本来就是「一首或多首」的说法。
    func testBatchMessageHasNoPlaceholder() {
        XCTAssertFalse(ImportReplacePrompt.batchMessage.contains("%1$S"))
        XCTAssertEqual(ImportReplacePrompt.batchMessage,
                       "一首或多首要导入的所选歌曲已经导入。你想替换现有歌曲并重新导入这些文件吗？")
    }

    // MARK: - 判据的来源

    /// 判据取的是文件修改时间：读得出的文件给得出时间，路径为空／文件不在就给 `nil`
    /// （`branch` 靠这个 `nil` 回落到 124）。
    func testModificationDateReadsFileOrReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberImportReplace-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let date = try XCTUnwrap(ImportService.modificationDate(atPath: url.path))
        XCTAssertEqual(date.timeIntervalSinceNow, 0, accuracy: 60)
        XCTAssertNil(ImportService.modificationDate(atPath: nil))
        XCTAssertNil(ImportService.modificationDate(atPath: url.path + ".missing"))
    }
}
