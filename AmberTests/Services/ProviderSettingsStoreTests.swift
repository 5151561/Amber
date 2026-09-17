import XCTest
@testable import Amber

/// 设置 › 音乐源 的来源管理规则
final class ProviderSettingsStoreTests: XCTestCase {

    @MainActor
    private func makeStore(_ name: String = #function) -> (ProviderSettingsStore, UserDefaults) {
        let suite = "ProviderSettingsStoreTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (ProviderSettingsStore(defaults: defaults), defaults)
    }

    /// 网易云没有登录，匿名下几乎取不到流，首次启动只开 QQ 音乐
    @MainActor
    func testFreshInstallEnablesQQOnly() {
        let (store, _) = makeStore()

        XCTAssertEqual(store.orderedEnabled, [.qq])
        XCTAssertFalse(store.isEnabled(.netease))
        XCTAssertEqual(store.defaultProvider, .qq)
    }

    @MainActor
    func testTogglePersistsAcrossLaunches() {
        let (store, defaults) = makeStore()

        store.setEnabled(true, for: .netease)
        XCTAssertEqual(store.orderedEnabled, [.netease, .qq])

        let reopened = ProviderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.orderedEnabled, [.netease, .qq])
        XCTAssertEqual(reopened.defaultProvider, .qq)
    }

    @MainActor
    func testLastEnabledProviderCannotBeDisabled() {
        let (store, _) = makeStore()

        XCTAssertFalse(store.canDisable(.qq))
        store.setEnabled(false, for: .qq)

        XCTAssertEqual(store.orderedEnabled, [.qq])
    }

    /// 关掉的源如果正好是默认源，默认源要落到还开着的源上
    @MainActor
    func testDisablingDefaultProviderMovesDefault() {
        let (store, defaults) = makeStore()

        store.setEnabled(true, for: .netease)
        store.defaultProvider = .netease
        store.setEnabled(false, for: .netease)

        XCTAssertEqual(store.defaultProvider, .qq)
        XCTAssertEqual(ProviderSettingsStore(defaults: defaults).defaultProvider, .qq)
    }
}
