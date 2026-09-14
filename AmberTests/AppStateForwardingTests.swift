import Combine
import XCTest
@testable import Amber

/// 验证 AppState 与嵌套 ObservableObject 的边界：子 store 的变化**不再**转发到 AppState
///（各子 store 自己作为 environmentObject 注入，需要谁的视图就观察谁）。
final class AppStateForwardingTests: XCTestCase {

    /// 测试宿主就是 Amber 本身，`UserDefaults.standard` 是开发者真实的偏好。
    /// 这里改音质／音源只该落进隔离的 suite（从前会把音质写回 128k / 320k）。
    @MainActor
    private func makeState(_ name: String = #function) -> AppState {
        let suite = "AppStateForwardingTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return AppState(defaults: UserDefaults(suiteName: suite)!)
    }

    @MainActor
    func testMainWindowDefaultsMatchMusicNavigation() {
        let state = makeState()

        XCTAssertEqual(state.sidebarSelection, .home)
        // 选中的源来自设置里的默认源，且必须是启用中的源
        XCTAssertEqual(state.selectedProvider, state.providerSettings.defaultProvider)
        XCTAssertTrue(state.enabledProviders.contains(state.selectedProvider))
        XCTAssertNil(state.playerInspector)
    }

    func testSidebarDestinationsHaveStableIdentityAndTitles() {
        let destinations: [(SidebarItem, String, String)] = [
            (.search, "search", "搜索"),
            (.home, "home", "主页"),
            (.discovery, "discovery", "新发现"),
            (.radio, "radio", "广播"),
            (.recentlyAdded, "recently-added", "最近添加"),
            (.artists, "artists", "艺人"),
            (.albums, "albums", "专辑"),
            (.songs, "songs", "歌曲"),
            (.store, "store", "iTunes Store"),
            (.allPlaylists, "all-playlists", "所有播放列表"),
            (.favorites, "favorites", "心水歌曲"),
            // 资料库里的每份播放列表也是一个侧栏落点，id 带列表 id、标题就是列表名
            (.playlist(id: "local:abc", name: "开车听的"), "playlist:local:abc", "开车听的"),
        ]

        for (item, id, title) in destinations {
            XCTAssertEqual(item.id, id)
            XCTAssertEqual(item.title, title)
        }
    }

    @MainActor
    func testInspectorButtonsAreMutuallyExclusiveAndToggleClosed() {
        let state = makeState()

        state.toggleInspector(.lyrics)
        XCTAssertEqual(state.playerInspector, .lyrics)

        state.toggleInspector(.queue)
        XCTAssertEqual(state.playerInspector, .queue)

        state.toggleInspector(.queue)
        XCTAssertNil(state.playerInspector)
    }

    @MainActor
    func testProviderSelectionIsGlobalState() {
        let state = makeState()
        state.selectedProvider = .qq
        XCTAssertEqual(state.selectedProvider, .qq)
    }

    /// 设置里关掉正在浏览的源时要自动换源，否则页面会一直请求一个已关闭的源
    @MainActor
    func testDisablingSelectedProviderFallsBackToAnEnabledOne() {
        let state = makeState()
        state.providerSettings.setEnabled(true, for: .netease)
        state.providerSettings.setEnabled(true, for: .qq)
        state.selectedProvider = .netease

        state.providerSettings.setEnabled(false, for: .netease)

        XCTAssertEqual(state.selectedProvider, .qq)
        XCTAssertEqual(state.enabledProviders, [.qq])
    }

    /// 子 store 的变化不惊动 AppState：一条 objectWillChange 从前会把所有
    /// `@EnvironmentObject var appState` 的视图整棵重画。改名/播放/心水各自的观察者
    /// 现在只订阅自己那份 store。
    @MainActor
    func testSubStoreChangesDoNotForwardToAppState() {
        let state = makeState()
        let leaked = expectation(description: "子 store 的变化不该惊动 AppState")
        leaked.isInverted = true
        let cancellable = state.objectWillChange.sink { _ in leaked.fulfill() }

        state.qqLogin.quality = .high
        state.player.repeatMode = .one
        state.library.noteStarted(Track(id: "test:1", kind: .qq, title: "t",
                                       artistName: "a", artistId: nil, albumName: "",
                                       albumId: nil, artworkURL: nil, duration: 1))

        wait(for: [leaked], timeout: 0.5)
        cancellable.cancel()
    }

    /// 子 store 仍然各自发自己的通知（视图靠这个刷新）
    @MainActor
    func testSubStoresStillPublishOnTheirOwn() {
        let state = makeState()
        let published = expectation(description: "qqLogin 自己要发")
        let cancellable = state.qqLogin.objectWillChange.sink { _ in published.fulfill() }

        state.qqLogin.quality = .high

        wait(for: [published], timeout: 2)
        cancellable.cancel()
    }

    /// 播放进度**不能**走 AppState。
    ///
    /// 进度 10 Hz 一跳，一旦并进 `player.objectWillChange`，AppState 就把它转发给全体
    /// 订阅者——整个界面每秒重画十次，实测光这一条就吃掉 40% CPU。
    /// 所以它单独挂在 `PlaybackClock` 上，只有真正显示时间的那几块订阅。
    @MainActor
    func testPlaybackProgressDoesNotForwardToAppState() {
        let state = makeState()
        let leaked = expectation(description: "进度不该惊动 AppState")
        leaked.isInverted = true
        let onState = state.objectWillChange.sink { _ in leaked.fulfill() }

        let ticked = expectation(description: "clock 自己要发")
        let onClock = state.player.clock.objectWillChange.sink { _ in ticked.fulfill() }

        state.player.currentTime = 12.5

        wait(for: [leaked, ticked], timeout: 0.5)
        XCTAssertEqual(state.player.currentTime, 12.5, accuracy: 0.001)
        onState.cancel()
        onClock.cancel()
    }
}
