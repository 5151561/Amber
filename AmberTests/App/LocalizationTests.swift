import XCTest
@testable import Amber

/// 钉住「系统自己那些串跟着中文走」。
///
/// 为什么值得一条测试：Amber 的界面文案全是硬编码中文，很容易以为「反正是中文 App，
/// 本地化与我无关」。但**系统框架那些串不经过本 App 的代码**——⌘Z 的完整标题由
/// Foundation 按格式串「撤销%@」拼（zh_CN 那条没有空格），全屏那条由 AppKit 提供。
/// 审查单 §3-1 担心的是：bundle 里一个 `.lproj` 都没有时，系统会按「这个 App 不支持
/// 用户的语言」处理，那两条就读成 "Undo 删除播放列表" / "Enter Full Screen"。
///
/// **[实测 2026-09-17] 这个担心不成立，而且补 `.lproj` 是空头。** 试过三种形态：
///
/// | 形态 | `Bundle.localizations` | `undoMenuItemTitle` |
/// | --- | --- | --- |
/// | 产物里有 `zh-Hans.lproj` | `["zh-Hans"]` | 撤销删除播放列表 |
/// | 把它从产物里删掉 | `["zh-Hans"]` | 撤销删除播放列表 |
/// | 换个 main bundle 没中文的进程（`xcrun swift` 跑探针） | — | Undo 删除播放列表 |
///
/// 前两行说明 `Support/Info.plist` 的 `CFBundleDevelopmentRegion = zh-Hans` **一条就够**
/// ——这一门是它供的，不需要真有那个目录。所以曾经加过的 `Amber/Resources/zh-Hans.lproj/`
/// 又删掉了：留着就是一道没人验证过、看着像在起作用的护身符。
/// 第三行是反例，证明这条路确实跟着 main bundle 的本地化走，不是「反正都会是中文」。
///
/// 这条测试因此不是钉那个目录，是钉**结论**：谁哪天动了 `CFBundleDevelopmentRegion`，
/// 或者哪次升级改了系统的回退规则，这里会先红。
///
/// 全量本地化（把几千处硬编码中文抽进 String Catalog）是另一件事，审查单 §5 单列着。
final class LocalizationTests: XCTestCase {

    /// 测试宿主就是 Amber 本身，所以 `Bundle.main` 就是装出来的那份 App。
    func testBundleDeclaresSimplifiedChinese() {
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"),
                      "bundle 里没有 zh-Hans.lproj；实际有的是 \(Bundle.main.localizations)")
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "zh-Hans",
                       "系统为本 App 选中的语言不是 zh-Hans")
        XCTAssertEqual(Bundle.main.developmentLocalization, "zh-Hans")
    }

    /// 端到端验那条真正会被看到的串：撤销项的完整标题。
    ///
    /// 这一条以前只能实机看一眼（审查单 §7「等用户定夺」里就这么写的）——但测试宿主
    /// 是 App 本身，`Bundle.main` 的本地化解析与实机同一条路，所以离线就能自证。
    /// 格式串是 zh_CN 的「撤销%@」，**没有空格**，所以断言用 `hasPrefix` 而不是拼字符串。
    func testUndoMenuItemTitleIsLocalized() {
        let undo = UndoManager()
        undo.setActionName("删除播放列表")

        XCTAssertTrue(undo.undoMenuItemTitle.hasPrefix("撤销"),
                      "撤销项读成了「\(undo.undoMenuItemTitle)」——系统串退成英文了")
        XCTAssertTrue(undo.undoMenuItemTitle.contains("删除播放列表"))
        XCTAssertTrue(undo.redoMenuItemTitle.hasPrefix("重做"),
                      "重做项读成了「\(undo.redoMenuItemTitle)」")
    }
}
