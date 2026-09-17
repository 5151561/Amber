import AppKit
import XCTest
@testable import Amber

/// 独立迷你播放器窗里「算」出来的那几件事。
///
/// 规格：miniplayer 规格 §3（尺寸与形态状态机）、
/// §5（工具条三张标识符列表）、§6（持久化与偏好），跳表与谓词的真值表在
/// `inspector 规格` §4.3。窗壳里凡是能写成纯函数的都写成了纯函数，
/// 这里逐条对着规格的表核。
@MainActor
final class MiniPlayerWindowTests: XCTestCase {

    private typealias Controller = MiniPlayerWindowController
    private typealias M = MusicMetrics.MiniPlayerWindow

    // MARK: - 三张跳表（inspector spec §4.3）

    /// `lyricsClicked` 的跳表（索引`state − 1`，`state ∈ 1…8`，越界→1）。
    func testAfterLyricsClickTable() {
        let expected: [Int: Int] = [1: 0, 2: 1, 3: 5, 4: 5, 5: 3, 6: 8, 7: 8, 8: 6]
        for (state, next) in expected {
            XCTAssertEqual(MiniPlayerStates.afterLyricsClick(state), next, "state \(state)")
        }
    }

    func testAfterLyricsClickOutOfRangeGivesOne() {
        for state in [-1, 0, 9, 10, 99] {
            XCTAssertEqual(MiniPlayerStates.afterLyricsClick(state), 1, "state \(state)")
        }
    }

    /// `queueClicked` 的跳表（索引`state − 2`，`state ∈ 2…8`，越界→2）。
    func testAfterQueueClickTable() {
        let expected: [Int: Int] = [2: 0, 3: 4, 4: 3, 5: 4, 6: 7, 7: 6, 8: 7]
        for (state, next) in expected {
            XCTAssertEqual(MiniPlayerStates.afterQueueClick(state), next, "state \(state)")
        }
    }

    func testAfterQueueClickOutOfRangeGivesTwo() {
        for state in [-1, 0, 1, 9, 99] {
            XCTAssertEqual(MiniPlayerStates.afterQueueClick(state), 2, "state \(state)")
        }
    }

    /// 第三张跳表 `[5, 4, 0, 2, 1]`：**1↔5、2↔4、3↔0 两两互换**，
    /// 也就是「组 I ⇄ 组 II 互转且保持面板不变」——「大封面」那条动作走的就是它。
    func testToggleGroupTableIsPairwiseSwap() {
        let expected: [Int: Int] = [1: 5, 2: 4, 3: 0, 4: 2, 5: 1]
        for (state, next) in expected {
            XCTAssertEqual(MiniPlayerStates.toggleGroup(state), next, "state \(state)")
        }
        // 互换 = 走两遍回到原地。
        for state in 1...5 {
            XCTAssertEqual(MiniPlayerStates.toggleGroup(MiniPlayerStates.toggleGroup(state)), state)
        }
    }

    func testToggleGroupOutOfRangeGivesThree() {
        for state in [-1, 0, 6, 7, 8, 9] {
            XCTAssertEqual(MiniPlayerStates.toggleGroup(state), 3, "state \(state)")
        }
    }

    // MARK: - 五个谓词的位掩码

    func testLyricsOpenIsOneFiveEight() {
        assertPredicate(MiniPlayerStates.isLyricsOpen, equals: [1, 5, 8])
    }

    func testQueueOpenIsTwoFourSeven() {
        assertPredicate(MiniPlayerStates.isQueueOpen, equals: [2, 4, 7])
    }

    /// 502 = 0b111110110 = 全集减 {0, 3}。
    func testIsBigIsFiveOhTwoMask() {
        assertPredicate(MiniPlayerStates.isBig, equals: [1, 2, 4, 5, 6, 7, 8])
    }

    func testIsWindowedIsThreeThroughEight() {
        assertPredicate(MiniPlayerStates.isWindowed, equals: [3, 4, 5, 6, 7, 8])
    }

    func testIsFullWindowIsSixSevenEight() {
        assertPredicate(MiniPlayerStates.isFullWindow, equals: [6, 7, 8])
    }

    /// [实测] miniplayer spec §11.7 尾段那一行：队列面板的 `displayStyle` 三档。
    /// 全窗口 {6,7,8} → 3、窗口化 {3,4,5} → 1、迷你横条 {0,1,2} → 2。
    func testQueueDisplayStyleHasThreeTiers() {
        for state in 0...2 {
            XCTAssertEqual(MiniPlayerStates.queueDisplayStyle(state), 2, "state \(state)")
        }
        for state in 3...5 {
            XCTAssertEqual(MiniPlayerStates.queueDisplayStyle(state), 1, "state \(state)")
        }
        for state in 6...8 {
            XCTAssertEqual(MiniPlayerStates.queueDisplayStyle(state), 3, "state \(state)")
        }
    }

    private func assertPredicate(_ predicate: (Int) -> Bool, equals members: Set<Int>,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for state in 0...9 {
            XCTAssertEqual(predicate(state), members.contains(state),
                           "state \(state)", file: file, line: line)
        }
    }

    // MARK: - §3.2 高度阶梯

    /// 分支 B 的四档。第三档的上界是 **宽度 + 200**，不是常数 400（spec §3.2 的订正）。
    func testHeightLadderBranchB() {
        let width: CGFloat = 320
        func state(_ height: CGFloat) -> Int {
            Controller.formState(width: width, height: height, startingState: 3,
                                 miniBarPanelState: 1, windowedPanelState: 5).state
        }
        XCTAssertEqual(state(0), 0)
        XCTAssertEqual(state(M.collapseHeight - 1), 0)          // < 200 收起
        XCTAssertEqual(state(M.collapseHeight), 3)              // 200…250 过渡带
        XCTAssertEqual(state(M.expandHeight - 1), 3)
        XCTAssertEqual(state(M.expandHeight), 3)                // 250…宽+200 方形态
        XCTAssertEqual(state(width + M.panelHeightOffset), 3)   // 上界含等号
        XCTAssertEqual(state(width + M.panelHeightOffset + 1), 5) // 再高就展开面板列
    }

    /// 第四档返回的是**内容视图报的窗口化面板态**（歌词 5 / 队列 4），不是常数。
    func testHeightLadderTallGivesWindowedPanelState() {
        let tall = 320 + M.panelHeightOffset + 1
        XCTAssertEqual(Controller.formState(width: 320, height: tall, startingState: 3,
                                            miniBarPanelState: 1, windowedPanelState: 5).state, 5)
        XCTAssertEqual(Controller.formState(width: 320, height: tall, startingState: 3,
                                            miniBarPanelState: 2, windowedPanelState: 4).state, 4)
    }

    /// 分支 A —— 起始态 ∈ {1,2}：只看 400 这一条线，`progress` 恒 0。
    func testHeightLadderBranchA() {
        for startingState in [1, 2] {
            let panel = startingState   // 迷你横条面板态与起始态同列
            let above = Controller.formState(width: 320, height: M.miniBarPanelHeight,
                                             startingState: startingState,
                                             miniBarPanelState: panel, windowedPanelState: 5)
            XCTAssertEqual(above.state, panel)
            XCTAssertEqual(above.progress, 0)

            let below = Controller.formState(width: 320, height: M.miniBarPanelHeight - 1,
                                             startingState: startingState,
                                             miniBarPanelState: panel, windowedPanelState: 5)
            XCTAssertEqual(below.state, 0)
            XCTAssertEqual(below.progress, 0)
        }
    }

    /// 分支 A 不看「宽度 + 200」那条线：同一个高度换到起始态 3 会走进分支 B。
    func testBranchAIgnoresWidthThreshold() {
        let height: CGFloat = 600      // > 320 + 200
        XCTAssertEqual(Controller.formState(width: 320, height: height, startingState: 1,
                                            miniBarPanelState: 1, windowedPanelState: 5).state, 1)
        XCTAssertEqual(Controller.formState(width: 320, height: height, startingState: 3,
                                            miniBarPanelState: 1, windowedPanelState: 5).state, 5)
    }

    /// `progress` 是大封面的`alphaValue`：200→250 这 50pt 里线性淡入。
    func testProgressIsLinearAcrossFadeBand() {
        func progress(_ height: CGFloat) -> CGFloat {
            Controller.formState(width: 320, height: height, startingState: 3,
                                 miniBarPanelState: 1, windowedPanelState: 5).progress
        }
        XCTAssertEqual(progress(M.collapseHeight), 0, accuracy: 0.0001)
        XCTAssertEqual(progress(M.collapseHeight + M.fadeBand / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress(M.expandHeight), 1, accuracy: 0.0001)
        XCTAssertEqual(progress(M.collapseHeight - 1), 0, accuracy: 0.0001)
        XCTAssertEqual(progress(1000), 1, accuracy: 0.0001)
    }

    // MARK: - §3.3 方形锁

    /// 掩码 5 = bit0(`.minX`) | bit2(`.maxX`)：横拖锁正方。
    func testSquareLockOnHorizontalDrag() {
        let locked = Controller.squareLocked(proposed: NSSize(width: 500, height: 380),
                                             startingState: 3, newState: 3, edges: .minX)
        XCTAssertEqual(locked, NSSize(width: 500, height: 500))

        let byMaxX = Controller.squareLocked(proposed: NSSize(width: 340, height: 420),
                                             startingState: 3, newState: 3, edges: .maxX)
        XCTAssertEqual(byMaxX, NSSize(width: 420, height: 420))
    }

    /// 纵拖不锁。
    func testSquareLockNotAppliedOnVerticalDrag() {
        let size = NSSize(width: 500, height: 380)
        XCTAssertEqual(Controller.squareLocked(proposed: size, startingState: 3, newState: 3,
                                               edges: [.minY, .maxY]), size)
        XCTAssertEqual(Controller.squareLocked(proposed: size, startingState: 3, newState: 3,
                                               edges: []), size)
    }

    /// 起始态或显示态不是 3（窗口化空态）就不锁。
    func testSquareLockRequiresBothStatesThree() {
        let size = NSSize(width: 500, height: 380)
        XCTAssertEqual(Controller.squareLocked(proposed: size, startingState: 0, newState: 3,
                                               edges: .horizontal), size)
        XCTAssertEqual(Controller.squareLocked(proposed: size, startingState: 3, newState: 0,
                                               edges: .horizontal), size)
        XCTAssertEqual(Controller.squareLocked(proposed: size, startingState: 5, newState: 5,
                                               edges: .horizontal), size)
    }

    /// 拖的是哪条边由「这一帧宽/高有没有变」推断（`liveResizeEdges` 不是公开 API）。
    func testResizeEdgesInferredFromDelta() {
        let current = NSSize(width: 400, height: 300)
        XCTAssertTrue(Controller.resizeEdges(proposed: NSSize(width: 420, height: 300),
                                             current: current).contains(.minX))
        XCTAssertTrue(Controller.resizeEdges(proposed: NSSize(width: 400, height: 320),
                                             current: current).intersection(.horizontal).isEmpty)
        XCTAssertFalse(Controller.resizeEdges(proposed: NSSize(width: 420, height: 320),
                                              current: current).intersection(.horizontal).isEmpty)
        XCTAssertTrue(Controller.resizeEdges(proposed: current, current: current).isEmpty)
    }

    // MARK: - §3.3 升 / 降表（Amber 里走不到，但表是规格实测的）

    func testFullWindowPromotionTable() {
        let expected: [Int: Int] = [0: 6, 1: 8, 2: 7, 3: 6, 4: 7, 5: 8]
        for (state, promoted) in expected {
            XCTAssertEqual(MiniPlayerStates.promotedToFullWindow(state), promoted, "state \(state)")
        }
    }

    func testFullWindowDemotionIsMinusThree() {
        for state in [6, 7, 8] {
            XCTAssertEqual(MiniPlayerStates.demotedFromFullWindow(state), state - 3)
        }
    }

    /// 两张表在组 II ⇄ 组 III 之间互逆；组 I 升上去再降下来落到同一列的组 II 态。
    func testPromotionAndDemotionAreInverse() {
        for state in [3, 4, 5] {
            let round = MiniPlayerStates.demotedFromFullWindow(
                MiniPlayerStates.promotedToFullWindow(state))
            XCTAssertEqual(round, state, "state \(state)")
        }
        for state in [6, 7, 8] {
            let round = MiniPlayerStates.promotedToFullWindow(
                MiniPlayerStates.demotedFromFullWindow(state))
            XCTAssertEqual(round, state, "state \(state)")
        }
        // 空/歌词/队列三列在组 I 与组 II 里升到同一个全窗口态。
        XCTAssertEqual(MiniPlayerStates.promotedToFullWindow(0),
                       MiniPlayerStates.promotedToFullWindow(3))
        XCTAssertEqual(MiniPlayerStates.promotedToFullWindow(1),
                       MiniPlayerStates.promotedToFullWindow(5))
        XCTAssertEqual(MiniPlayerStates.promotedToFullWindow(2),
                       MiniPlayerStates.promotedToFullWindow(4))
    }

    // MARK: - §3.4 绿灯

    /// `isBig` 为真 → 一律允许。
    func testShouldZoomAllowsBigStates() {
        let current = NSRect(x: 0, y: 0, width: 400, height: 300)
        let smaller = NSRect(x: 0, y: 0, width: 320, height: 100)
        for state in [1, 2, 4, 5, 6, 7, 8] {
            XCTAssertTrue(Controller.shouldZoom(currState: state, newFrame: smaller,
                                                currentFrame: current), "state \(state)")
        }
    }

    /// 窗口化空态（3）= 方形态：只有正方形的目标才允许。
    func testShouldZoomRequiresSquareInWindowedEmptyState() {
        let current = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertTrue(Controller.shouldZoom(currState: 3,
                                            newFrame: NSRect(x: 0, y: 0, width: 500, height: 500),
                                            currentFrame: current))
        XCTAssertFalse(Controller.shouldZoom(currState: 3,
                                             newFrame: NSRect(x: 0, y: 0, width: 500, height: 501),
                                             currentFrame: current))
    }

    /// 迷你横条空态（0 / 9）：只允许往高了长。
    func testShouldZoomRequiresTallerInCompactStates() {
        let current = NSRect(x: 0, y: 0, width: 400, height: 300)
        for state in [0, 9] {
            XCTAssertTrue(Controller.shouldZoom(currState: state,
                                                newFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                                currentFrame: current), "state \(state)")
            XCTAssertTrue(Controller.shouldZoom(currState: state,
                                                newFrame: NSRect(x: 0, y: 0, width: 400, height: 600),
                                                currentFrame: current), "state \(state)")
            XCTAssertFalse(Controller.shouldZoom(currState: state,
                                                 newFrame: NSRect(x: 0, y: 0, width: 400, height: 299),
                                                 currentFrame: current), "state \(state)")
        }
    }

    /// 标准尺寸：宽先夹到 600；大形态减掉 chrome、窗口化取方形、组 {0,9} 不加高度约束。
    func testStandardContentSize() {
        let wide = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let chrome: CGFloat = 28

        let big = Controller.standardContentSize(currState: 5, defaultFrame: wide,
                                                 chromeHeight: chrome)
        XCTAssertEqual(big.width, M.maxWidth)
        XCTAssertEqual(big.height, 900 - chrome)

        let windowed = Controller.standardContentSize(currState: 3, defaultFrame: wide,
                                                      chromeHeight: chrome)
        XCTAssertEqual(windowed.width, M.maxWidth)
        XCTAssertEqual(windowed.height, M.maxWidth)          // 方形：min(900, 600) = 600

        let short = Controller.standardContentSize(
            currState: 3, defaultFrame: NSRect(x: 0, y: 0, width: 1200, height: 400),
            chromeHeight: chrome)
        XCTAssertEqual(short.width, 400)
        XCTAssertEqual(short.height, 400)

        for state in [0, 9] {
            let compact = Controller.standardContentSize(currState: state, defaultFrame: wide,
                                                         chromeHeight: chrome)
            XCTAssertEqual(compact.width, M.maxWidth)
            XCTAssertNil(compact.height, "state \(state)")
        }
    }

    /// ★ 上边固定：新 frame 的 maxY 与旧的一致，左边也不动。
    func testStandardFrameKeepsTopEdge() {
        let current = NSRect(x: 120, y: 300, width: 320, height: 200)
        let frame = Controller.standardFrame(currentFrame: current,
                                             size: NSSize(width: 600, height: 640))
        XCTAssertEqual(frame.maxY, current.maxY)
        XCTAssertEqual(frame.minX, current.minX)
        XCTAssertEqual(frame.size, NSSize(width: 600, height: 640))
    }

    // MARK: - §5 工具条的三张标识符列表

    func testDefaultToolbarIdentifiers() {
        XCTAssertEqual(Controller.defaultToolbarIdentifiers, [
            .flexibleSpace,
            Controller.ToolbarID.action,
            .space,
            Controller.ToolbarID.lyrics,
            Controller.ToolbarID.queue,
            Controller.ToolbarID.airplay,
            Controller.ToolbarID.volume,
        ])
    }

    /// allowed = default 在 `volume` 前多插一个`volumeSlider`。
    func testAllowedToolbarIdentifiers() {
        XCTAssertEqual(Controller.allowedToolbarIdentifiers, [
            .flexibleSpace,
            Controller.ToolbarID.action,
            .space,
            Controller.ToolbarID.lyrics,
            Controller.ToolbarID.queue,
            Controller.ToolbarID.airplay,
            Controller.ToolbarID.volumeSlider,
            Controller.ToolbarID.volume,
        ])
        XCTAssertEqual(Controller.allowedToolbarIdentifiers.count,
                       Controller.defaultToolbarIdentifiers.count + 1)
        XCTAssertEqual(Controller.allowedToolbarIdentifiers.filter {
            $0 != Controller.ToolbarID.volumeSlider
        }, Controller.defaultToolbarIdentifiers)
    }

    /// 音量条一展开，歌词 / 队列 / AirPlay 三件直接从条上撤掉。
    func testVolumeExpandedToolbarIdentifiers() {
        XCTAssertEqual(Controller.volumeExpandedToolbarIdentifiers, [
            .flexibleSpace,
            Controller.ToolbarID.action,
            .space,
            Controller.ToolbarID.volumeSlider,
            Controller.ToolbarID.volume,
        ])
        for dropped in [Controller.ToolbarID.lyrics,
                        Controller.ToolbarID.queue,
                        Controller.ToolbarID.airplay] {
            XCTAssertFalse(Controller.volumeExpandedToolbarIdentifiers.contains(dropped))
        }
    }

    /// 规格 §5 已坐实 `maximize` / `platter` / `modeSelect` 不在任何一张列表里，Amber 不实现。
    func testDeadToolbarIdentifiersAreAbsent() {
        let all = Controller.defaultToolbarIdentifiers
            + Controller.allowedToolbarIdentifiers
            + Controller.volumeExpandedToolbarIdentifiers
        for dead in ["maximize", "platter", "modeSelect"] {
            XCTAssertFalse(all.contains(NSToolbarItem.Identifier(dead)), dead)
        }
    }

    // MARK: - §6 偏好

    func testOnTopMapsToFloatingLevel() {
        XCTAssertEqual(Controller.level(onTop: true), .floating)
    }

    func testOffMapsToNormalLevel() {
        XCTAssertEqual(Controller.level(onTop: false), .normal)
    }

    /// 默认不置顶（Music 那条偏好默认也是关的）。
    func testDefaultSettingIsNotOnTop() {
        XCTAssertFalse(SettingsValues().miniPlayerOnTop)
        XCTAssertEqual(Controller.level(onTop: SettingsValues().miniPlayerOnTop), .normal)
    }

    /// `use_toolbar_in_miniplayer` 出厂是开着的。
    func testToolbarSwitchDefaultsOn() {
        XCTAssertTrue(SettingsValues().useToolbarInMiniPlayer)
    }

    // MARK: - §7 三个动作的可用性

    /// 大封面 / 待播清单在全窗口态 {6,7,8} 下失效；**实例为 nil 时按有效处理**。
    func testMiniPlayerActionValidity() {
        XCTAssertTrue(AppDelegate.miniPlayerActionIsValid(nil))
        for state in 0...5 {
            XCTAssertTrue(AppDelegate.miniPlayerActionIsValid(state), "state \(state)")
        }
        for state in [6, 7, 8] {
            XCTAssertFalse(AppDelegate.miniPlayerActionIsValid(state), "state \(state)")
        }
        XCTAssertTrue(AppDelegate.miniPlayerActionIsValid(9))
    }

    // MARK: - §11 内容视图的形变体系

    /// §11.3 的：小封面（连同紧挨它的标题行）只在
    /// 「迷你横条 + 没在 rollover + 有内容」三个合取项都成立时露脸。
    func testSmallArtworkVisibilityTruthTable() {
        // 组 I：三条都要成立。
        for state in 0...2 {
            XCTAssertTrue(MiniPlayerStates.showsSmallArtwork(
                state: state, rolloverVisible: false, hasContent: true), "state \(state)")
            XCTAssertFalse(MiniPlayerStates.showsSmallArtwork(
                state: state, rolloverVisible: true, hasContent: true), "state \(state)")
            XCTAssertFalse(MiniPlayerStates.showsSmallArtwork(
                state: state, rolloverVisible: false, hasContent: false), "state \(state)")
        }
        // 组 II / III（`big`）一律没有小封面——那两组是大封面的地盘。
        for state in 3...8 {
            XCTAssertFalse(MiniPlayerStates.showsSmallArtwork(
                state: state, rolloverVisible: false, hasContent: true), "state \(state)")
        }
    }

    /// §11.5 ③：过渡带里三条纵向偏移是**线性插值**过去的，两端与 [PX] 实测的两组一致。
    func testOverlayOffsetsInterpolateAcrossTheFadeBand() {
        let collapsed = MiniPlayerStates.overlayOffsets(progress: 0)
        XCTAssertEqual(collapsed.transport, M.collapsedTransportCenterFromBottom)
        XCTAssertEqual(collapsed.scrubber, M.collapsedScrubberCenterFromBottom)
        XCTAssertEqual(collapsed.time, M.collapsedTimeRowCenterFromBottom)

        let expanded = MiniPlayerStates.overlayOffsets(progress: 1)
        XCTAssertEqual(expanded.transport, M.transportCenterFromBottom)
        XCTAssertEqual(expanded.scrubber, M.scrubberCenterFromBottom)
        XCTAssertEqual(expanded.time, M.timeRowCenterFromBottom)

        let half = MiniPlayerStates.overlayOffsets(progress: 0.5)
        XCTAssertEqual(half.transport, (collapsed.transport + expanded.transport) / 2, accuracy: 0.001)
        XCTAssertEqual(half.scrubber, (collapsed.scrubber + expanded.scrubber) / 2, accuracy: 0.001)
        XCTAssertEqual(half.time, (collapsed.time + expanded.time) / 2, accuracy: 0.001)
    }

    /// 越界的 `progress` 夹回两端（`windowWillResize` 那条路只保证 200…250 之间的值）。
    func testOverlayOffsetsClampOutOfRangeProgress() {
        XCTAssertEqual(MiniPlayerStates.overlayOffsets(progress: -1).transport,
                       MiniPlayerStates.overlayOffsets(progress: 0).transport)
        XCTAssertEqual(MiniPlayerStates.overlayOffsets(progress: 2).transport,
                       MiniPlayerStates.overlayOffsets(progress: 1).transport)
    }

    // MARK: - 松手之后没有中间态

    /// 开着面板时，拖出来的高度就是新的抽屉高——所以自然高等于当前帧高，不会被弹回去。
    func testDraggedDrawerHeightIsRemembered() {
        let contents = MiniPlayerContentView(appState: AppState())
        contents.apply(state: 5, animated: false)          // 窗口化 + 歌词
        contents.rememberDrawerHeight(contentHeight: 700, width: 320)
        XCTAssertEqual(contents.drawerHeight, 700 - 320)   // 顶块是方形封面（边长 = 窗宽）
        XCTAssertEqual(contents.naturalContentSize(forWidth: 320).height, 700)
    }

    /// 抽屉高有下限 200：算出来比它小就按下限记（`setDrawerHeight:` 的常量）。
    func testDraggedDrawerHeightClampsToMinimum() {
        let contents = MiniPlayerContentView(appState: AppState())
        contents.apply(state: 5, animated: false)
        contents.rememberDrawerHeight(contentHeight: 400, width: 320)
        XCTAssertEqual(contents.drawerHeight, M.drawerMinHeight)
    }

    /// 没开面板的两档没有抽屉，自然高是唯一的：横条 154、窗口化方形 = 窗宽。
    /// 拖到中间（封面下面空一条灰）松手就会被收回这个高度。
    func testEmptyStatesHaveASingleNaturalHeight() {
        let contents = MiniPlayerContentView(appState: AppState())
        contents.apply(state: 3, animated: false)
        contents.rememberDrawerHeight(contentHeight: 460, width: 320)   // 没面板 → 不记
        XCTAssertEqual(contents.naturalContentSize(forWidth: 320).height, 320)
        contents.apply(state: 0, animated: false)
        XCTAssertEqual(contents.naturalContentSize(forWidth: 320).height, M.collapsedContentHeight)
    }

    /// §11.1 的实测值。这几条是「照抄」型常量，写个测试是为了改动时有人喊一声。
    func testContentViewConstantsMatchSpec() {
        XCTAssertEqual(M.artworkSize, 42)
        XCTAssertEqual(M.artworkMargin, 16)
        XCTAssertEqual(M.outerMargin, 18)
        XCTAssertEqual(M.drawerInitialHeight, 600)
        XCTAssertGreaterThan(M.drawerInitialHeight, M.drawerMinHeight)
        XCTAssertEqual(M.mouseInterestTimeout, 3.75)
        XCTAssertEqual(M.mouseInterestExitingWindowTimeout, 0.3)
        XCTAssertEqual(M.delayBeforeStartingRolloverMin, 0.1)
        XCTAssertEqual(M.delayBeforeStartingRolloverMax, 0.3)
    }

    // MARK: - 底衬第二支：Metal 动态背景
    //
    // 规格 backdrop 规格（uniform 的偏移与取值）+
    // `miniplayer 规格` §11.8（谁在换、什么时候换）。
    // 这里只核**纯函数**：不起 App、不碰 GPU，一条都不用建 MTLDevice。

    private typealias B = MusicMetrics.Backdrop

    /// [实测] §11.8.1/§11.8.2：组 III 强制 1 不看偏好；其余读偏好，且工厂只判 `== 1`
    /// ——越界值一律落回毛玻璃。
    func testBackdropStyleResolution() {
        // 组 III：偏好是什么都不看。
        for state in 6...8 {
            for preference in [-1, 0, 1, 2, 99] {
                XCTAssertEqual(MiniPlayerStates.backdropStyle(state: state, preference: preference),
                               1, "state \(state) pref \(preference)")
            }
        }
        // 组 I / 组 II：读偏好，只有 1 是 Metal。
        for state in 0...5 {
            XCTAssertEqual(MiniPlayerStates.backdropStyle(state: state, preference: 0), 0)
            XCTAssertEqual(MiniPlayerStates.backdropStyle(state: state, preference: 1), 1)
            for preference in [-1, 2, 3, 99] {
                XCTAssertEqual(MiniPlayerStates.backdropStyle(state: state, preference: preference),
                               0, "state \(state) pref \(preference)")
            }
        }
    }

    /// [实测] §2.2 入口一：`σ = floor(hypot(drawable 像素) × 0.04539470697716646)`。
    /// **稳态下生效的就是它**——每次重建纹理都无条件重算，覆盖 `setBlur:` 定的那个。
    func testBackdropSigmaFromCanvasDiagonal() {
        XCTAssertEqual(B.sigma(diagonalPixels: 1000), 45)   // 45.3947 → floor
        XCTAssertEqual(B.sigma(diagonalPixels: 0), 0)
        XCTAssertEqual(B.sigma(diagonalPixels: -10), 0)     // 退化尺寸不给负 σ
        // 迷你窗最窄那档（320pt @2x 的方形顶块）实际落点，验收时可以对着看。
        let diagonal = (640.0 * 640.0 + 640.0 * 640.0).squareRoot()
        XCTAssertEqual(B.sigma(diagonalPixels: diagonal), 41)
    }

    /// [实测] §2.2 入口二：`blurRadius = clamp(v, 4, 2000)`、`σ = ceil(radius / 3.0348542587702925)`。
    func testBackdropSigmaFromBlurRadiusAndClamp() {
        XCTAssertEqual(B.sigma(blurRadius: B.defaultBlurRadius), 17)   // 默认 50 → 17（spec §2.2）
        XCTAssertEqual(B.sigma(blurRadius: 1000), 330)                 // §11.8.1 的 setBlur(1000)
        XCTAssertEqual(B.sigma(blurRadius: 0), 2)                      // 夹到下界 4 → ceil(1.318)
        XCTAssertEqual(B.sigma(blurRadius: 100_000), 660)              // 夹到上界 2000 → ceil(659.01)
    }

    /// [实测] §3.1/§3.2：三层周期 = `clamp(speed, 0.1, 10) × {120, 90, 70}`。
    /// ★ `timeScale` 是**周期（秒）**不是速率，数越大转得越慢。
    func testBackdropModelPeriodsClampSpeedFirst() {
        XCTAssertEqual(B.modelTimeScales, [120, 90, 70])
        XCTAssertEqual(B.modelPeriods(speed: B.defaultSpeed), [60, 45, 35])
        // 上游 `10.5 − 9p` 的 10.5 端够不到——被 setter 削成 10。
        XCTAssertEqual(B.modelPeriods(speed: 10.5), [1200, 900, 700])
        XCTAssertEqual(B.modelPeriods(speed: 0.001), [12, 9, 7])       // 夹到下界 0.1
    }

    /// 上游那条公式与这里的夹取接上：迷你窗宽度 320…600 ⇒ p ∈ [0, 0.5]。
    func testBackdropAnimationIntervalMeetsTheSpeedClamp() {
        let narrow = MusicMetrics.NowPlaying.backdropAnimationInterval(contentWidth: 320)
        XCTAssertEqual(narrow, 10.5, accuracy: 0.0001)                 // 公式给 10.5
        XCTAssertEqual(B.clampSpeed(Float(narrow)), 10)                // 实际生效 10.0
        let wide = MusicMetrics.NowPlaying.backdropAnimationInterval(contentWidth: 800)
        XCTAssertEqual(B.clampSpeed(Float(wide)), 1.5, accuracy: 0.0001)
        // 纱罩在迷你窗里最淡只到 0.5（宽度上限 600 ⇒ p = 0.5）。
        XCTAssertEqual(MusicMetrics.NowPlaying.backdropScrimAlpha(contentWidth: 600), 0.5,
                       accuracy: 0.0001)
    }

    /// [实测] §3.1：「减弱动态效果」不是停，是把系数顶成 5.0 —— 比默认 0.5 大十倍，
    /// 而 timeScale 是周期 ⇒ **慢十倍**。
    func testBackdropReduceMotionSlowsDownTenfold() {
        XCTAssertEqual(B.reduceMotionSpeed, 5.0)
        XCTAssertEqual(B.reduceMotionSpeed, B.defaultSpeed * 10)
        XCTAssertEqual(B.modelPeriods(speed: B.reduceMotionSpeed), [600, 450, 350])
        // 每帧的 meshWarpTimeScale = speed × 3.5。
        XCTAssertEqual(B.meshWarpTimeScale(speed: B.reduceMotionSpeed), 17.5)
        XCTAssertEqual(B.meshWarpTimeScale(speed: B.defaultSpeed), 1.75)
    }

    /// [实测] §四：浅色支是**两档**（0.38 / 0.08），阈值 `averageLuminosity < 0.3`，
    /// 不是连续函数。
    func testBackdropLightModeFactorIsTwoStepped() {
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: 0), 0.38)
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: 0.2999), 0.38)
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: 0.3), 0.08)   // 严格小于才算暗
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: 1), 0.08)
    }

    /// [实测] §3.3：换封面 0.5 秒线性，`t += (−1/fps) / 0.5`，跌到 0 收尾，无缓动。
    func testBackdropCrossfadeIsHalfASecondLinear() {
        XCTAssertEqual(B.crossfadeDuration, 0.5)
        let fps = B.preferredFramesPerSecond
        let step = Float(1) / Float(fps) / B.crossfadeDuration
        XCTAssertEqual(B.advanceCrossfade(1, framesPerSecond: fps), 1 - step, accuracy: 0.0001)

        // 走满 0.5 秒（= fps/2 帧，向上取整）刚好落到 0，早一帧还在。
        var mix: Float = 1
        let frames = Int((Float(fps) * B.crossfadeDuration).rounded(.up))
        for _ in 0..<(frames - 1) { mix = B.advanceCrossfade(mix, framesPerSecond: fps) }
        XCTAssertGreaterThan(mix, 0)
        mix = B.advanceCrossfade(mix, framesPerSecond: fps)
        XCTAssertEqual(mix, 0)
        XCTAssertEqual(B.advanceCrossfade(0, framesPerSecond: fps), 0)   // 0 就停住，不往负里走
    }

    /// [实测] §八：`avg = Σ / (N × 255)` → [0, 1]，α == 0 的像素整个跳过（计数也不进），
    /// N == 0 时原样返回 Σ。亮度本身走 BT.601 定点式
    /// （**故意不照抄** premulLast 支那条存疑的 `R×255/B`，理由写在
    /// `MiniPlayerBackdropLuminance` 的类型注释里）。
    func testBackdropAverageLuminanceNormalisation() {
        typealias L = MiniPlayerBackdropLuminance
        XCTAssertEqual(L.average(premultipliedRGBA: [255, 255, 255, 255]), 1, accuracy: 0.005)
        XCTAssertEqual(L.average(premultipliedRGBA: [0, 0, 0, 255]), 0, accuracy: 0.0001)
        XCTAssertEqual(L.average(premultipliedRGBA: [128, 128, 128, 255]), 128.0 / 255,
                       accuracy: 0.005)
        // 全透明：N = 0，Σ 原样返回（= 0）。
        XCTAssertEqual(L.average(premultipliedRGBA: [255, 255, 255, 0]), 0, accuracy: 0.0001)
        // 透明像素不拉低平均：跳过而不是当成黑。
        XCTAssertEqual(L.average(premultipliedRGBA: [255, 255, 255, 255, 0, 0, 0, 0]), 1,
                       accuracy: 0.005)
        // BT.601 的权重顺序没搞反：纯绿远亮于纯蓝。
        let green = L.average(premultipliedRGBA: [0, 255, 0, 255])
        let blue = L.average(premultipliedRGBA: [0, 0, 255, 255])
        XCTAssertEqual(green, 0.587, accuracy: 0.01)
        XCTAssertEqual(blue, 0.114, accuracy: 0.01)
        // 两档阈值落在这上面：暗封面进 0.38 档、亮封面进 0.08 档。
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: blue), 0.38)
        XCTAssertEqual(B.lightModeFactor(averageLuminosity: green), 0.08)
    }

    /// [实测] §1.2：`Uniforms` 368 字节，模型 stride 0x50，`0x120 + 0x50 = 0x170` 吃满。
    /// Swift 侧的镜像结构必须逐字段对上 `.metal` 里那份，否则整套 uniform 全是错位的。
    func testBackdropUniformsAre368Bytes() {
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.size, B.uniformsByteLength)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.size, 368)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropModel>.stride, 0x50)
        // 抽查几个实测的偏移。
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.time), 0x40)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.textureTransitionMix),
                       0x44)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.meshWarpTimeScale), 0x48)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.saturation), 0x4c)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.whiteScrimAlpha), 0x50)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.blackScrimAlpha), 0x54)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.factorForDarkMode), 0x58)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.factorForLightMode), 0x5c)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.floorValue), 0x60)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.ceilingValue), 0x64)
        XCTAssertEqual(MemoryLayout<MiniPlayerBackdropUniforms>.offset(of: \.models), 0x80)
    }

    /// 「照抄」型定数。改动时有人喊一声——它们全部有 `[实测]` 出处。
    func testBackdropConstantsMatchSpec() {
        XCTAssertEqual(B.saturation, 2.0)                 // 初值 1.0 被 PinchEncoder 顶掉
        XCTAssertEqual(B.luminanceFloor, 0.07)
        XCTAssertEqual(B.luminanceCeiling, 0.97)
        XCTAssertEqual(B.meshWarpTimeScaleFactor, 3.5)
        XCTAssertEqual(B.defaultSpeed, 0.5)
        XCTAssertEqual(B.speedRange.lowerBound, 0.1)
        XCTAssertEqual(B.speedRange.upperBound, 10)
        XCTAssertEqual(B.defaultBlurRadius, 50)
        XCTAssertEqual(B.blurRadiusRange.lowerBound, 4)
        XCTAssertEqual(B.blurRadiusRange.upperBound, 2000)
        XCTAssertEqual(B.miniPlayerBlurRadius, 1000)
        XCTAssertEqual(B.darkModeFactor, 0.2)
        // 两个 scrim 字段的默认值来自 PinchEncoder init。
        XCTAssertEqual(B.defaultScrimAlpha, 0.25)
        XCTAssertEqual(B.luminosityThreshold, 0.3)
        XCTAssertEqual(B.luminanceDownscaleBox, 300)
        XCTAssertEqual(B.maxTextureDimension, 16384)
        // 三层锚位：居中 / 偏左上 / 偏左下（不是三张同心旋转）。
        XCTAssertEqual(B.modelTranslations[0], SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(B.modelTranslations[1], SIMD3<Float>(-0.5, 0.7, 0))
        XCTAssertEqual(B.modelTranslations[2], SIMD3<Float>(-0.95, -0.7, 0))
    }
}
