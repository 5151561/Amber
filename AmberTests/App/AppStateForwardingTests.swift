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
        XCTAssertFalse(state.isInspectorOpen)
        // 收起时档位仍然记着（默认档是歌词），见下面那条测试
        XCTAssertEqual(state.inspectorMode, .lyrics)
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
            // 资料库里的每份播放列表也是一个侧栏落点，id 带列表 id。
            // **标题给空串**：列表名不进身份（见下一条测试），那一行的标题由侧栏
            // 直接取 `LibraryPlaylist.name`，不经 `SidebarItem.title`。
            (.playlist(id: "local:abc"), "playlist:local:abc", ""),
        ]

        for (item, id, title) in destinations {
            XCTAssertEqual(item.id, id)
            XCTAssertEqual(item.title, title)
        }
    }

    /// 播放列表改名**不换身份**。
    ///
    /// 从前 `SidebarItem.playlist` 的载荷带着列表名，合成的`Hashable` 把它算进了`==`
    /// 与 `hash`，而它自己的`id` 不含——一个类型上两套身份。后果是改名之后
    /// `appState.sidebarSelection` 还持旧名那一份，侧栏拿新 entries 去找匹配找不到，
    /// 于是 `deselectAll`：内容页还开着这份列表，侧栏却一行都不亮
    /// （design-ref/reactive-ui-review.md 故障 4）。另外三处「删的是不是当前这页」的
    /// 判断（歌单页头、网格卡菜单、侧栏右键）也一起失效。
    func testRenamingPlaylistKeepsSidebarIdentity() {
        let before = SidebarItem.playlist(id: "local:abc")
        let after = SidebarItem.playlist(id: "local:abc")
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.hashValue, after.hashValue)
        XCTAssertEqual(before.id, after.id)
        // 不同的列表仍然是不同的身份
        XCTAssertNotEqual(before, SidebarItem.playlist(id: "local:xyz"))
        // 能当字典键用（`ContentNavigationController.rootPages` 就是这么存的）
        var pages: [SidebarItem: String] = [before: "详情页"]
        pages[after] = "改名之后还是同一页"
        XCTAssertEqual(pages.count, 1)
    }

    /// 主窗那条面板列的两颗键：点当前档 = 收起，点另一档 = 换档并保持展开。
    ///
    /// **收起不忘档位**是这一版的核心：从前「开着没有」与「哪一档」挤在一个
    /// `playerInspector: PlayerInspector?` 里，nil 既表示收起也抹掉了档位，
    /// 于是拖收一次面板就忘了上次看的是哪一档；整窗播放器那两个布尔又与它完全不通，
    /// 后者默认 true ⇒ 第一次开「播放中」永远是歌词抽屉
    /// （design-ref/reactive-ui-review.md §2.1「多份真相」）。
    @MainActor
    func testInspectorKeepsModeWhenToggledClosed() {
        let state = makeState()

        state.toggleInspector(.lyrics)
        XCTAssertTrue(state.isInspectorOpen)
        XCTAssertEqual(state.inspectorMode, .lyrics)

        // 点另一档：换档，仍然开着
        state.toggleInspector(.queue)
        XCTAssertTrue(state.isInspectorOpen)
        XCTAssertEqual(state.inspectorMode, .queue)

        // 点当前档：收起，但档位留着
        state.toggleInspector(.queue)
        XCTAssertFalse(state.isInspectorOpen)
        XCTAssertEqual(state.inspectorMode, .queue, "收起不该把档位一起抹掉")

        // 再点同一档：原样开回去
        state.toggleInspector(.queue)
        XCTAssertTrue(state.isInspectorOpen)
        XCTAssertEqual(state.inspectorMode, .queue)
    }

    @MainActor
    func testProviderSelectionIsGlobalState() {
        let state = makeState()
        state.selectedProvider = .qq
        XCTAssertEqual(state.selectedProvider, .qq)
    }

    /// 设置里关掉正在浏览的源时要自动换源，否则页面会一直请求一个已关闭的源
    @MainActor
    /// **纠正是异步的**：以前 `$enabled.sink` 在写入那一刻同步回调，下一行就已经纠正好；
    /// 换成 `Observations` 之后要过一跳。也就是说切换与纠正之间有一个 tick 的窗口，
    /// `selectedProvider` 仍指向刚被禁用的源。界面上看不出来（同一轮 runloop 内补齐），
    /// 但读这个值的代码不能假设它在 `setEnabled` 返回时就已经合法。
    func testDisablingSelectedProviderFallsBackToAnEnabledOne() async {
        let state = makeState()
        state.providerSettings.setEnabled(true, for: .netease)
        state.providerSettings.setEnabled(true, for: .qq)
        state.selectedProvider = .netease

        state.providerSettings.setEnabled(false, for: .netease)
        await settle()

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

    /// 子 store 仍然各自发自己的通知（视图靠这个刷新）。
    ///
    /// `QQLoginStore` 已经是 `@Observable`，没有 `objectWillChange` 了，改用
    /// `Observations` 观察具体属性——这也正是迁移后视图侧的真实形态。
    @MainActor
    func testSubStoresStillPublishOnTheirOwn() async {
        let state = makeState()
        // 取一个与当前值不同的档位：`Observations` 对 Equatable 自带相邻去重，
        // 写一个和现在一样的值不会发。
        let target = StreamQuality.allCases.first { $0 != state.qqLogin.quality }
        let next = try! XCTUnwrap(target)

        var seen: [StreamQuality] = []
        let bag = TaskBag()
        bag.observe({ state.qqLogin.quality }) { seen.append($0) }
        await settle()

        state.qqLogin.quality = next
        await settle()

        XCTAssertEqual(seen, [next], "qqLogin 自己要发")
    }

    /// 让订阅任务挂上／把值送到。
    @MainActor
    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// 播放进度**不能**惊动 AppState。
    ///
    /// 进度 10 Hz 一跳，一旦读它的人是整棵界面树，整个界面就每秒重画十次
    /// ——实测光这一条就吃掉 40% CPU。所以它单独挂在 `PlaybackClock` 上，
    /// 只有真正显示时间的那几块读。
    ///
    /// `PlaybackClock` 换 `@Observable` 之后没有 `objectWillChange` 了，
    /// 这里改成观察 `time` 本身——顺带把「AppState 不该被惊动」那一半也换成
    /// 观察它自己的属性，比订一条大喇叭更贴近现在的真实形态。
    @MainActor
    func testPlaybackProgressDoesNotForwardToAppState() async {
        let state = makeState()
        var clockTicks: [TimeInterval] = []
        var appStateTouches = 0
        let bag = TaskBag()
        bag.observe({ state.player.clock.time }) { clockTicks.append($0) }
        bag.observe({ state.selectedProvider }) { _ in appStateTouches += 1 }
        await settle()

        state.player.currentTime = 12.5
        await settle()

        XCTAssertEqual(clockTicks, [12.5], "clock 自己要发")
        XCTAssertEqual(appStateTouches, 0, "进度不该惊动 AppState")
        XCTAssertEqual(state.player.currentTime, 12.5, accuracy: 0.001)
    }
}
