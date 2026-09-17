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
