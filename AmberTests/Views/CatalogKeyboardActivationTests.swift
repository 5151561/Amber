import AppKit
import XCTest
@testable import Amber

/// 目录侧四页的键盘落点（审查单 §2.5-1）。
///
/// 那四页的回车**不另写一份落点**：页面拿到选中那一件之后调的是它自己的
/// `accessibilityPerformPress()`（见 `CatalogPageViewController.activateSelection`、
/// `CatalogRoomViewController`、`SearchLandingViewController` 三处同名方法）。
/// 所以「键盘能不能打开」这件事，等价于「每张卡的 press 是不是它的主落点」——
/// 这里钉的就是这条等价关系：哪天卡片那边改了落点顺序、或者把 press 摘了，
/// 键盘那条会跟着悄悄失灵，由这几条用例先喊出来。
final class CatalogKeyboardActivationTests: XCTestCase {

    /// `CatalogItem.onPlay` / `onOpen` 是 `@MainActor @Sendable` 闭包，
    /// 计数得放在一个主 actor 隔离的盒子里（隔离类型自带 `Sendable`）。
    @MainActor
    private final class Counter {
        var count = 0
    }

    /// 测试宿主就是 Amber 本身，`UserDefaults.standard` 是开发者真实的偏好——
    /// 照 `AppStateForwardingTests` 的办法落进隔离的 suite。
    @MainActor
    private func makeState(_ name: String = #function) -> AppState {
        let suite = "CatalogKeyboardActivationTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return AppState(defaults: UserDefaults(suiteName: suite)!)
    }

    @MainActor
    private func makeCard(_ item: CatalogItem, _ state: AppState) -> CatalogSquareCardView {
        let card = CatalogSquareCardView(frame: NSRect(x: 0, y: 0, width: 180, height: 220))
        card.configure(with: item, appState: state)
        return card
    }

    /// 既没有 `route` 也没有`onOpen` 的卡：press 落到`onPlay`（Apple 的电台卡就是这样）。
    @MainActor
    func testPressFallsBackToPlay() {
        let state = makeState()
        let played = Counter()
        let card = makeCard(CatalogItem(id: "station", kind: .station, title: "猜你喜欢",
                                        onPlay: { played.count += 1 }), state)

        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(played.count, 1)
    }

    /// 有 `onOpen` 时它**排在** `onPlay` 前面（资料库派生的艺人卡：点开进艺人页，
    /// 不是当场播）。主点击顺序是 route → onOpen → onPlay，这里钉后两档。
    @MainActor
    func testPressPrefersOpenOverPlay() {
        let state = makeState()
        let opened = Counter()
        let played = Counter()
        let card = makeCard(CatalogItem(id: "artist", kind: .square, title: "艺人",
                                        onPlay: { played.count += 1 },
                                        onOpen: { opened.count += 1 }), state)

        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(played.count, 0)
    }

    /// 三样落点一个都没有的卡不可交互：press 报 false，键盘那颗回车也就什么都不做
    /// （页面不用再判一次，闸门在 `CatalogCardContentView.isInteractive` 上）。
    @MainActor
    func testPressDoesNothingWithoutAnyDestination() {
        let state = makeState()
        let card = makeCard(CatalogItem(id: "plain", kind: .square, title: "没有落点"), state)

        XCTAssertFalse(card.accessibilityPerformPress())
    }
}
