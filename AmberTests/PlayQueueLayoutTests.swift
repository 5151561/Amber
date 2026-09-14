import AppKit
import XCTest
@testable import Amber

/// 待播清单面板的版式（[实测] `playqueue 规格` §3）。
///
/// 测的是「照规格落了没有」——常量、快照形状、行高分档、窄面板那一档外观。
/// 鼠标类交互（悬浮、拖拽、右键）不在这里测，按记忆里的口径交给用户实机验收。
final class PlayQueueLayoutTests: XCTestCase {

    // MARK: §3.1 三条特殊 identifier

    /// 照抄字面量：**空状态那条只有两条下划线**，另外两条是三条。
    /// 这不是笔误，是 Music 实测的样子，写错了空状态行就走进曲目行那一支。
    @MainActor
    func testSpecialCellIdentifiersMatchSpec() {
        XCTAssertEqual(PlayQueueViewController.repeatingCellIdentifier, "___repeatingInfoCell___")
        XCTAssertEqual(PlayQueueViewController.moreCountCellIdentifier, "___moreCountInfoCell___")
        XCTAssertEqual(PlayQueueViewController.emptyMessageCellIdentifier, "__emptyMessageCell__")
    }

    // MARK: §3.5 行高分档

    func testRowHeightConstantsMatchSpec() {
        let M = MusicMetrics.PlayQueue.self
        XCTAssertEqual(M.rowHeight, 48)
        XCTAssertEqual(M.headerHeight, 44)
        XCTAssertEqual(M.headerWithSourceHeight, 58)
        XCTAssertEqual(M.emptyRowHeightInset, 58)
        XCTAssertEqual(M.emptyRowMinHeight, 55)
        XCTAssertEqual(M.autoplayHeaderFallbackWidth, 270)
        // 兜底 rowHeight 照抄 46——delegate 对每一行都给值，它一行都不生效。
        XCTAssertEqual(M.fallbackRowHeight, 46)
    }

    func testSettingsAndScrollConstantsMatchSpec() {
        let M = MusicMetrics.PlayQueue.self
        XCTAssertEqual(M.settingsMargin, 10)
        XCTAssertEqual(M.settingsSpacing, 8)
        XCTAssertEqual(M.settingsTopInset, 8)
        // `.defaultHigh - 10`，Music 是现算出来的，值 490。
        XCTAssertEqual(M.settingsEqualWidthPriority.rawValue, 490)
        XCTAssertEqual(M.scrollBackInterval, 5)
        XCTAssertEqual(M.snapThresholdLimit, 200)
        XCTAssertEqual(M.gridLineWidthThreshold, 600)
    }

    func testTrackRowConstantsMatchSpec() {
        let M = MusicMetrics.PlayQueue.self
        XCTAssertEqual(M.artworkSize, 34)
        XCTAssertEqual(M.artworkToTitleSpacing, 12)
        XCTAssertEqual(M.moreButtonSize, 28)
        XCTAssertEqual(M.moreButtonTrailingInset, 2)
    }

    // MARK: §3.4 空状态复用「继续播放」分区

    /// 队列是空的时候：**只有一个分区（继续播放）＋ 一条空状态行**，
    /// 不另开空状态分区、历史那一段也不装。表格因此恰好两行（分区头 + 空状态行）。
    @MainActor
    func testEmptyQueueReusesContinuePlayingSection() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.theTable.numberOfRows, 2,
                       "空队列应当只有「继续播放」分区头 + 一条空状态行")
        let delegate = controller as NSTableViewDelegate
        // 第 0 行是分区头（没有「来自…」→ 44），第 1 行是空状态行（撑满剩余高）。
        XCTAssertEqual(delegate.tableView?(controller.theTable, heightOfRow: 0),
                       MusicMetrics.PlayQueue.headerHeight)
        XCTAssertEqual(delegate.tableView?(controller.theTable, heightOfRow: 1),
                       controller.emptyRowHeight)
    }

    /// 空状态行高 = `max(可视高 − 上下内缩 − 58, 55)`，且**永不低于 55**。
    @MainActor
    func testEmptyRowHeightNeverGoesBelowFloor() {
        let controller = makeLoadedController()
        XCTAssertGreaterThanOrEqual(controller.emptyRowHeight,
                                    MusicMetrics.PlayQueue.emptyRowMinHeight)

        // 面板被压到没高度时（收起的那一瞬）也不能给出负高。
        controller.view.frame = NSRect(x: 0, y: 0, width: MusicMetrics.Inspector.width, height: 0)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.emptyRowHeight, MusicMetrics.PlayQueue.emptyRowMinHeight)
    }

    /// 自动连播分区头是懒测出来的，不是写死的档：至少要量出一个正数，
    /// 而且比单行分区头高（它是两行 ＋ 上下各 11 的内缩）。
    @MainActor
    func testAutoplayHeaderHeightIsMeasuredAndTallerThanSingleLine() {
        let controller = makeLoadedController()
        let height = controller.autoplayHeaderHeight
        XCTAssertGreaterThan(height, MusicMetrics.PlayQueue.headerHeight)
    }

    // MARK: §3.9 窄了就把文字丢掉

    /// 实机截图里 258 宽的面板正是「只剩图标」那一档；
    /// 宽到放得下两颗完整按钮时回到「图 + 字」。
    @MainActor
    func testSettingsHeaderDropsTitlesWhenNarrow() {
        let header = PlayQueueSettingsExtraHeader(frame: .zero)
        let widest = header.widestButtonWidthForTesting
        XCTAssertGreaterThan(widest, 0)

        header.setFrameSize(NSSize(width: MusicMetrics.Inspector.width, height: 36))
        XCTAssertEqual(header.currentImagePosition, .imageOnly,
                       "258 宽的面板放不下两颗带字的按钮，应当只剩图标")

        // `(w − 10 − 10 − 8) / 2 >= widest` 的最小宽度，再宽 1pt。
        let wide = widest * 2 + MusicMetrics.PlayQueue.settingsMargin * 2
            + MusicMetrics.PlayQueue.settingsSpacing + 1
        header.setFrameSize(NSSize(width: wide, height: 36))
        XCTAssertEqual(header.currentImagePosition, .imageLeading)
    }

    // MARK: 文案

    /// 全部实测自 Music zh_CN 的 `UserInterface.strings`。
    func testLocalizedStringsMatchMusic() {
        XCTAssertEqual(PlayQueueStrings.historyTitle, "历史记录")
        XCTAssertEqual(PlayQueueStrings.upNextTitle, "队列")
        XCTAssertEqual(PlayQueueStrings.continuePlayingTitle, "继续播放")
        XCTAssertEqual(PlayQueueStrings.continuePlayingSubtitle("某专辑"), "来自：某专辑")
        XCTAssertEqual(PlayQueueStrings.clearButtonTitle, "清除")
        XCTAssertEqual(PlayQueueStrings.autoplayTitle, "自动连播")
        XCTAssertEqual(PlayQueueStrings.autoplaySubtitle, "将播放类似歌曲")
        XCTAssertEqual(PlayQueueStrings.crossfadeTitle, "交叉渐入渐出")
        XCTAssertEqual(PlayQueueStrings.automixTitle, "自动过渡")
        XCTAssertEqual(PlayQueueStrings.repeating("某专辑"), "重复播放“某专辑”")
        XCTAssertEqual(PlayQueueStrings.repeatingNoSource, "重复")
        XCTAssertEqual(PlayQueueStrings.moreItems("12"), "其他12首歌曲")
        XCTAssertEqual(PlayQueueStrings.emptyLabel, "队列中无音乐。")
        XCTAssertEqual(PlayQueueStrings.removeSwipeAction, "移除")
        XCTAssertEqual(PlayQueueStrings.containerAXLabel, "播放队列")
    }

    /// 曲目行副行照实机截图是「艺人 — 专辑」；没有专辑名时只剩艺人，不留悬着的破折号。
    func testTrackSubtitleShape() {
        let withAlbum = Track(id: "test:1", kind: .qq, title: "歌", artistName: "宇多田光",
                              artistId: nil, albumName: "40代はいろいろ", albumId: nil,
                              artworkURL: nil, duration: 200)
        XCTAssertEqual(playQueueSubtitle(for: withAlbum), "宇多田光 — 40代はいろいろ")

        let noAlbum = Track(id: "test:2", kind: .qq, title: "歌", artistName: "宇多田光",
                            artistId: nil, albumName: "", albumId: nil,
                            artworkURL: nil, duration: 200)
        XCTAssertEqual(playQueueSubtitle(for: noAlbum), "宇多田光")
    }

    // MARK: §1 侧栏容器

    /// [实测] inspector spec §1.5：`mode` 没有显式赋值 → **默认站在歌词**；
    /// 两个面板都是启动即建、都进子控制器。
    @MainActor
    func testInspectorContainerDefaultsToLyricsWithBothPanelsBuilt() {
        let container = InspectorContainerViewController(appState: AppState())
        XCTAssertEqual(container.mode, .lyrics)
        XCTAssertEqual(container.children.count, 2)
        XCTAssertTrue(container.children.contains { $0 === container.queue })
        XCTAssertTrue(container.children.contains { $0 === container.lyrics })
        // [实测] §1.2：主窗这条路 `includeBackdrop = false` → 根视图是**素面 NSView**，
        // 不是 `NSVisualEffectView`（背景由窗口根那层玻璃给）。
        XCTAssertFalse(container.view is NSVisualEffectView)
    }

    /// 切档是交叉淡入：新面板插在旧面板**底下**，动画走完旧的才摘掉。
    /// 非动画那条立刻摘旧的，容器里只剩一张。
    @MainActor
    func testInspectorContainerSwapsPanelWithoutAnimation() {
        let container = InspectorContainerViewController(appState: AppState())
        container.loadView()
        XCTAssertEqual(container.view.subviews.count, 1)
        container.setMode(.queue, animated: false)
        XCTAssertEqual(container.mode, .queue)
        XCTAssertEqual(container.view.subviews.count, 1)
        XCTAssertTrue(container.view.subviews.first === container.queue.view)
    }

    // MARK: §3.1/§3.3 重入保护（`updateLock` + `updatesPending`）

    /// 不起 App 就能测：门闩是纯状态机。
    ///
    /// 这一组挡的正是实机那次栈溢出（`Amber-2026-09-09-042558.ips`）的形状——
    /// 「更新过程中又被要求更新」。要求是：**不递归加深**，而是记账、等这一轮做完再补跑。
    func testUpdateGateDefersReentrantRequestInsteadOfRecursing() {
        let gate = PlayQueueUpdateGate()
        var depths: [Int] = []
        var runs = 0
        gate.perform(.data) { _ in
            runs += 1
            depths.append(gate.lockCount)
            // 第一轮里再来一次：这一发必须只记账，不能就地再跑一层。
            if runs == 1 {
                gate.perform(.data) { _ in
                    XCTFail("重入的那一次不该就地执行")
                }
                XCTAssertTrue(gate.dataPending, "重入时应只置 updatesPending")
            }
        }
        XCTAssertEqual(runs, 2, "补跑一次，且只补一次")
        XCTAssertEqual(depths, [1, 1], "补跑走的是循环不是递归，重入计数不加深")
        XCTAssertEqual(gate.lockCount, 0)
        XCTAssertFalse(gate.dataPending)
        XCTAssertFalse(gate.sourcePending)
    }

    /// 两条通道各记各的账：数据与来源互不吞并，且数据优先补跑。
    func testUpdateGateKeepsDataAndSourcePendingSeparately() {
        let gate = PlayQueueUpdateGate()
        var order: [PlayQueueUpdateGate.Kind] = []
        gate.perform(.source) { kind in
            order.append(kind)
            if order.count == 1 {
                gate.mark(.source)
                gate.mark(.data)
            }
        }
        XCTAssertEqual(order, [.source, .data, .source])
        XCTAssertEqual(gate.lockCount, 0)
    }

    /// 锁外的调用照常同步执行，别把正常路径也拖成异步。
    func testUpdateGateRunsImmediatelyWhenUnlocked() {
        let gate = PlayQueueUpdateGate()
        var ran = false
        gate.perform(.source) { kind in
            ran = true
            XCTAssertEqual(kind, .source)
            XCTAssertEqual(gate.lockCount, 1)
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(gate.lockCount, 0)
    }

    // MARK: §3.11 收起面板要停掉 5 秒回滚

    /// 主窗那一路（`NSSplitViewItem` 收起分栏列）会把宿主`isHidden = true`，
    /// `viewDidHide()` 沿视图树往下发到`PlayQueuePanelRootView`，面板自己停表。
    /// 这样两个宿主共用一条驱动，`MainSplitViewController` 不用改。
    @MainActor
    func testCollapsingHostStopsScrollBackTimer() {
        let controller = makeLoadedController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 258, height: 900))
        host.addSubview(controller.view)

        controller.resetScrollBackTimer()
        XCTAssertTrue(controller.isScrollBackTimerArmed)

        // 收起的是**宿主**，不是面板自己——`viewDidHide()` 要能沿树发下来。
        host.isHidden = true
        XCTAssertFalse(controller.isScrollBackTimerArmed, "宿主收起后 5 秒回滚不该继续空转")
    }

    // MARK: §3.8 ••• 的 28×28

    /// `NSButton` 的`alignmentRectInsets` 纵向是负数，约束钉的又是 alignment rect，
    /// 所以直接拿 `NSButton` 写`pinSize(28×28)` 量出来是`28 × 23.5`。
    /// `PlayQueueFlushButton` 把 insets 归零，约束钉的就是 frame。
    @MainActor
    func testMoreButtonIsTwentyEightSquareInTheTrackCell() {
        XCTAssertEqual(PlayQueueFlushButton().alignmentRectInsets.top, 0)
        XCTAssertEqual(PlayQueueFlushButton().alignmentRectInsets.bottom, 0)

        // 端到端量实际 frame：上一轮实测是 `[1423, 102, 28, 23.5]`——宽对、高少了 4.5，
        // 就是 alignment rect 与 frame 差的那 `2 + 2.5`。
        let cell = PlayQueueCell(frame: NSRect(x: 0, y: 0, width: 258,
                                               height: MusicMetrics.PlayQueue.rowHeight))
        cell.layoutSubtreeIfNeeded()
        let button = cell.moreButtonAnchor
        XCTAssertEqual(button.frame.width, MusicMetrics.PlayQueue.moreButtonSize)
        XCTAssertEqual(button.frame.height, MusicMetrics.PlayQueue.moreButtonSize)
        // 右沿 offset −2（§3.8）。
        XCTAssertEqual(cell.frame.maxX - button.frame.maxX,
                       MusicMetrics.PlayQueue.moreButtonTrailingInset)
    }

    // MARK: 工具

    @MainActor
    private func makeLoadedController() -> PlayQueueViewController {
        let controller = PlayQueueViewController(appState: AppState())
        controller.loadView()
        controller.viewDidLoad()
        // 面板列恒 258 宽（[AX] `[1212, 33, 258, 923]`）。
        controller.view.frame = NSRect(x: 0, y: 0,
                                       width: MusicMetrics.Inspector.width, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }
}
