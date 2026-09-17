import XCTest
@testable import Amber

/// 钉住「本 App 声明了 zh-Hans 这门本地化」。
///
/// 为什么值得一条测试：Amber 的界面文案全是硬编码中文，很容易以为「反正是中文 App，
/// 本地化与我无关」。但**系统框架自己那些串不经过本 App 的代码**——⌘Z 的完整标题由
/// Foundation 按格式串「撤销%@」拼（zh_CN 那条没有空格），全屏那条由 AppKit 提供。
/// bundle 里一个 `.lproj` 都没有时，`Bundle.main.localizations` 是空的，系统会按
/// 「这个 App 不支持用户的语言」处理，那两条就可能读成 "Undo 删除播放列表" /
/// "Enter Full Screen"（审查单 §3-1、§8 验收第 13 条）。
///
/// `Support/Info.plist` 的 `CFBundleDevelopmentRegion = zh-Hans` 只说明「源语言是中文」，
/// 不等于「装出来的 bundle 里有 zh-Hans 这门」。后者靠 `Amber/Resources/zh-Hans.lproj/`
/// 存在，而这里就是钉它没被误删、也真的进了产物。
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
