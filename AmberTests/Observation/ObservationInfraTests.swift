import Observation
import XCTest
@testable import Amber

/// `TaskBag` 与 `EventChannel` —— 剥离 Combine 之后所有订阅都架在这两件上，
/// 它们的语义差一点，上面几百处订阅就会一起歪。
///
/// 这里特意把**与 Combine 不同**的那几条钉住（合并、去重、时序），
/// 免得迁移时按 `$prop.sink` 的老直觉写。
@MainActor
final class ObservationInfraTests: XCTestCase {

    @Observable final class Model {
        var count = 0
        var name = "a"
    }

    /// 让订阅任务有机会跑起来／把值送到。
    private func settle(_ rounds: Int = 6) async {
        for _ in 0..<rounds { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: TaskBag

    func testObserveDropsCurrentValueButObserveNowDoesNot() async {
        let model = Model()
        let bag = TaskBag()
        var dropped: [Int] = []
        var immediate: [Int] = []
        bag.observe({ model.count }) { dropped.append($0) }
        bag.observeNow({ model.count }) { immediate.append($0) }
        await settle()

        XCTAssertEqual(dropped, [], "observe 丢掉当前值，对应 $prop.dropFirst()")
        XCTAssertEqual(immediate, [0], "observeNow 立刻发一次当前值")

        model.count = 1
        await settle()
        XCTAssertEqual(dropped, [1])
        XCTAssertEqual(immediate, [0, 1])
    }

    /// **与 `$prop.sink` 不同**：同一 tick 连写只收到最后一个值。
    func testSameTickWritesCoalesceToLastValue() async {
        let model = Model()
        let bag = TaskBag()
        var seen: [Int] = []
        bag.observe({ model.count }) { seen.append($0) }
        await settle()

        model.count = 1
        model.count = 2
        model.count = 3
        await settle()

        XCTAssertEqual(seen, [3], "Combine 会收到 1、2、3 三次；这里只有 3")
    }

    /// **与 `$prop.sink` 不同**：Equatable 自带相邻去重，`.removeDuplicates()` 可以删。
    func testEquatableValuesAreDeduplicated() async {
        let model = Model()
        let bag = TaskBag()
        var seen: [String] = []
        bag.observe({ model.name }) { seen.append($0) }
        await settle()

        model.name = "b"; await settle()
        model.name = "b"; await settle()
        model.name = "b"; await settle()
        model.name = "c"; await settle()

        XCTAssertEqual(seen, ["b", "c"], "写三次 b 只发一次；是相邻去重，不是集合去重")

        model.name = "b"; await settle()
        XCTAssertEqual(seen, ["b", "c", "b"], "换回 b 会再发——相邻去重不记历史")
    }

    /// **登记之后、任务跑起来之前**改的那一下不能丢。
    ///
    /// 这是 `observe` 里那道基线保护挡的坑：`Observations` 的首个元素是「订阅时的当前值」，
    /// 而任务要过一跳才开始迭代——中间改了的话首个元素已经是新值，简单的 `dropFirst()`
    /// 会把这条改动整个吞掉。Combine 的 `.sink` 是同步登记的，没有这段窗口，
    /// 所以迁移时不补这一手就是静默丢事件（实测：DownloadStore 改媒体夹那两条测试全红）。
    func testChangeBetweenSubscribeAndFirstTurnIsNotSwallowed() async {
        let model = Model()
        let bag = TaskBag()
        var seen: [Int] = []
        bag.observe({ model.count }) { seen.append($0) }
        // 故意不 settle：这一行就落在那道窗口里。
        model.count = 42
        await settle()

        XCTAssertEqual(seen, [42], "登记到首次迭代之间的改动必须照发")
    }

    // MARK: TaskBag.observeAny

    /// `observeAny` 与 `observe` 的**首值口径必须一致**：当前值不发。
    /// 21 个调用点都按「页面自己在 `viewDidLoad` 里读初值」写的，多发一次就是多重排一次。
    func testObserveAnyDropsTheCurrentValue() async {
        let model = Model()
        let bag = TaskBag()
        var fires = 0
        bag.observeAny({ (model.count, model.name) }) { fires += 1 }
        await settle()

        XCTAssertEqual(fires, 0, "当前值不发，与 observe 同口径")

        model.count = 1
        await settle()
        XCTAssertEqual(fires, 1)

        model.name = "b"
        await settle()
        XCTAssertEqual(fires, 2, "快照里任意一项变了都算一次")
    }

    /// **登记之后、任务跑起来之前**改的那一下，`observeAny` 同样不能丢。
    ///
    /// 这条与 `testChangeBetweenSubscribeAndFirstTurnIsNotSwallowed` 是同一个坑，只是
    /// `observeAny` 收的是元组、没有 Equatable 可比，所以基线换了一种问法：登记那一刻挂一个
    /// 一次性的 `withObservationTracking`，问的是「有没有人改过」而不是「改成了什么」。
    /// 从前这里写的是 `dropFirst()`，这一下会被整个吞掉、等多久都不来
    ///（`Player/PlayQueueModel.swift` 与 `Lyrics/InspectorLyricsViewController.swift`
    /// 那两处消费方不是幂等的 `setNeedsRefresh()`，丢了就是真丢）。
    func testObserveAnyChangeBetweenSubscribeAndFirstTurnIsNotSwallowed() async {
        let model = Model()
        let bag = TaskBag()
        var fires = 0
        bag.observeAny({ (model.count, model.name) }) { fires += 1 }
        // 故意不 settle：这一行就落在那道窗口里（`Task` 要过一跳才开始迭代）。
        model.count = 42
        await settle()

        XCTAssertEqual(fires, 1, "登记到首次迭代之间的改动必须照发")
    }

    func testCancelAllStopsDelivery() async {
        let model = Model()
        let bag = TaskBag()
        var seen: [Int] = []
        bag.observe({ model.count }) { seen.append($0) }
        await settle()

        model.count = 1
        await settle()
        XCTAssertEqual(seen, [1])

        bag.cancelAll()
        await settle()
        model.count = 2
        await settle()
        XCTAssertEqual(seen, [1], "收摊之后不再送")
    }

    /// 袋子没了订阅就停——对应 `AnyCancellable.deinit` 退订。
    func testDroppingBagStopsDelivery() async {
        let model = Model()
        var seen: [Int] = []
        do {
            let bag = TaskBag()
            bag.observe({ model.count }) { seen.append($0) }
            await settle()
            model.count = 1
            await settle()
            XCTAssertEqual(seen, [1])
        }
        await settle()
        model.count = 2
        await settle()
        XCTAssertEqual(seen, [1], "袋子析构后循环该停")
    }

    // MARK: EventChannel

    func testChannelFansOutToEverySubscriber() async {
        let channel = EventChannel<Int>()
        var a: [Int] = [], b: [Int] = []
        let bag = TaskBag()
        let sa = channel.stream(), sb = channel.stream()
        bag.add(Task { @MainActor in for await v in sa { a.append(v) } })
        bag.add(Task { @MainActor in for await v in sb { b.append(v) } })
        await settle()

        channel.send(1)
        channel.send(2)
        await settle()

        XCTAssertEqual(a, [1, 2])
        XCTAssertEqual(b, [1, 2], "多订阅方各收一份，这是 AsyncStream 单独给不了的")
    }

    func testChannelFiltersPerSubscriber() async {
        let channel = EventChannel<Int>()
        var odd: [Int] = []
        let bag = TaskBag()
        let stream = channel.stream { $0 % 2 == 1 }
        bag.add(Task { @MainActor in for await v in stream { odd.append(v) } })
        await settle()

        for v in 1...6 { channel.send(v) }
        await settle()

        XCTAssertEqual(odd, [1, 3, 5], "对应 changes(affecting:) 的掩码过滤")
    }

    /// `send` 必须是同步的：`LibraryStore.notify(_:)` 那条写入路径不能被订阅方拖住。
    func testSendDoesNotBlockOnSlowSubscriber() async {
        let channel = EventChannel<Int>()
        let bag = TaskBag()
        let stream = channel.stream()
        bag.add(Task { @MainActor in
            for await _ in stream { try? await Task.sleep(for: .milliseconds(50)) }
        })
        await settle()

        let start = ContinuousClock.now
        for v in 1...20 { channel.send(v) }
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .milliseconds(50),
                          "20 次 send 必须立刻返回；AsyncChannel 的 async send 会挂在这里")
    }

    /// 缓冲有上界，而且丢的是**最早的**那几条。
    ///
    /// 换掉 `.unbounded` 的前提是「消费方都不读元素、收到就整份重算」（理由写在
    /// `EventChannel` 的类型注释里），那前提下唯一必须保住的就是**最后一条**——
    /// 这条用例钉的正是它。顺带钉住 `droppedCount`：丢弃不许是静默的。
    func testChannelBoundsItsBufferAndKeepsTheNewest() async {
        let channel = EventChannel<Int>()
        let limit = EventChannel<Int>.bufferLimit
        let total = limit * 3
        let stream = channel.stream()   // 只订不取，让它堆起来

        for v in 1...total { channel.send(v) }
        channel.finish()

        var seen: [Int] = []
        for await v in stream { seen.append(v) }

        XCTAssertEqual(seen.count, limit, "缓冲有上界")
        XCTAssertEqual(seen.last, total, "最后一条永远保得住——合批重算靠的就是它")
        XCTAssertEqual(seen.first, total - limit + 1, "丢的是最早的那几条")
        #if DEBUG
        // 两个观测口只在 DEBUG 编（`.unbounded` 时代连「堆了多深」都问不出来）。
        XCTAssertEqual(channel.droppedCount, total - limit, "丢了几条要数得出来")
        XCTAssertEqual(channel.deepestDepth, limit, "堆了多深也要数得出来")
        #endif
    }

    func testSubscriberDeregistersWhenTaskCancelled() async {
        let channel = EventChannel<Int>()
        var seen: [Int] = []
        let task = Task { @MainActor in
            for await v in channel.stream() { seen.append(v) }
        }
        await settle()
        channel.send(1)
        await settle()
        XCTAssertEqual(seen, [1])

        task.cancel()
        await settle()
        channel.send(2)
        await settle()
        XCTAssertEqual(seen, [1], "取消之后不再送")
    }
}
