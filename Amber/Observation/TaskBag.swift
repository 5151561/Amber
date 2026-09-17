import Foundation
import Observation
import Synchronization

/// 一袋订阅任务，袋子没了就全部取消——`Set<AnyCancellable>` 的对位物。
///
/// Combine 时代每个控制器揣一个 `Set<AnyCancellable>`，`.store(in:)` 往里塞，
/// 控制器析构时 `AnyCancellable.deinit` 逐个退订。换成 `for await` 之后每条订阅是一个
/// `Task`，同样需要一个「随宿主一起收摊」的容器，否则控制器都没了循环还在跑。
@MainActor
final class TaskBag {
    private var tasks: [Task<Void, Never>] = []

    init() {}

    func add(_ task: Task<Void, Never>) {
        // 顺手扫掉已取消的那几个。从前这里只增不减：一个长命宿主（`AppState`、窗口控制器）
        // 每 `cancelAll()` 一轮再重订一轮，数组就长一截，攒的是一整程不会回收的续体。
        //
        // 只能扫「已取消」这一位：`Task` 没有同步问得出的「跑完了没有」——那要 `await`，
        // 而这里是同步入口。够用了，本类批量释放的入口就是 `cancelAll()` / `deinit`，
        // 两者都走取消这条路。自然跑完（被观察对象没了、流终止）的那几个仍会留着，
        // 它们本来也已经没有续体可跑，留着只占一个引用。
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    /// 提前收摊。宿主还活着但不该再收更新时用（比如分栏列收起）。
    func cancelAll() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    deinit {
        // deinit 是 nonisolated 的，这里只能碰不需要隔离的东西——`Task.cancel()` 是
        // Sendable 且线程安全的，取消本身不回主 actor。
        for task in tasks { task.cancel() }
    }
}

extension TaskBag {
    /// 订一个属性：值**落定之后**收到新值。
    ///
    /// 与 `$prop.sink` 的三处差别，改订阅时逐条对照：
    ///
    /// 1. **时序翻转**。`@Published` 在 willSet 发（值变之前），这里在之后发。
    ///    以前靠「读到的还是旧值」写的代码要重新核对。
    /// 2. **同一 tick 连写会合并**，只收到最后一个值。靠「每次赋值收到一次」
    ///    数事件的消费方会漏；关心「现在是什么」的消费方不受影响。
    /// 3. **自带相邻去重**（Equatable），`.removeDuplicates()` 可以直接删。
    ///
    /// 当前值不发，对应 Combine 那边到处写的 `$prop.dropFirst()`：AppKit 侧初值一律
    /// 在 `viewDidLoad` 里直接读，不靠订阅补。要初值就用 `observeNow`。
    ///
    /// **为什么不是简单的 `dropFirst()`**：订阅登记之后、`Task` 第一次跑起来之前的那段
    /// 窗口里如果值就变了，`Observations` 的首个元素已经是**新值**，`dropFirst()` 会把它
    /// 整个吞掉，这条改动就永久丢了。Combine 的 `.sink` 是同步登记的，没有这段窗口。
    /// 所以这里在**调用点同步**取一份基线，首个元素与基线不同就照发。
    func observe<Value: Sendable & Equatable>(
        _ value: @escaping @MainActor @Sendable () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        let baseline = value()
        add(Task { @MainActor in
            var isFirst = true
            for await next in Observations(value) {
                if Task.isCancelled { return }
                if isFirst {
                    isFirst = false
                    // 与登记那一刻相同 ＝ 期间没人改过，这就是要丢掉的「当前值」。
                    if next == baseline { continue }
                }
                onChange(next)
            }
        })
    }

    /// 同上，但**当前值也会立刻发一次**。对应 Combine 那边不带 `dropFirst()` 的订阅。
    func observeNow<Value: Sendable>(
        _ value: @escaping @MainActor @Sendable () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        add(Task { @MainActor in
            for await next in Observations(value) {
                if Task.isCancelled { return }
                onChange(next)
            }
        })
    }

    /// `objectWillChange.sink { … }` 的对位物：**列出来的这些属性**里任意一个变了就调一次。
    ///
    /// `@Observable` 没有「随便什么变了」这一路信号——这是好事，`objectWillChange` 正是
    /// 「一次入库把资料库四页全量重算一遍」的由来（见 design-ref/reactive-ui-review.md §2.1）。
    /// 迁移时把消费方**真正读的那几项**装成一个元组传进来，行为与原来等价，
    /// 而与它无关的写入不再把它叫醒。
    ///
    /// 元组没有 Equatable，所以**不会去重**（与 `objectWillChange` 同口径）。
    ///
    /// **但「丢首值」这一手不是 `dropFirst()`。** 这里与 `observe` 守的是同一条：
    /// 订阅登记之后、`Task` 第一次跑起来之前的那段窗口里如果值就变了，`Observations`
    /// 的首个元素已经是**新值**，`dropFirst()` 会把这条改动整个吞掉、等多久都不来。
    ///
    /// 元组比不了值，所以基线换了一种问法：登记那一刻同步挂一个一次性的
    /// `withObservationTracking`——它在快照里**任何一项第一次被写**时置位。首个元素到货时
    /// 这一位还是假，就说明期间没人改过，那才是该丢的「当前值」；已经置位了就照发。
    /// 「值变成了什么」问不出来，「有没有人改过」问得出来，而这里要的正是后者。
    ///
    /// 两处代价，都比静默丢事件划算：
    ///
    /// - 那道 `withObservationTracking` 若一直没人触发，它的登记会留在被观察对象的
    ///   registrar 上直到对象析构（没有撤销 API）。每个调用点一份、捕获的只是一个
    ///   `Atomic<Bool>`，21 个调用点合起来不到 2 KB。
    /// - 首个元素到货**之后**才发生的第一次写也会置位，于是极小概率多发一次。
    ///   消费方都是 `setNeedsRefresh()` 这种幂等合批入口，多一次无害；
    ///   少一次才是要命的（那正是这段代码在修的）。
    ///
    /// 用法：`observers.observeAny({ (model.items, model.sort, model.filter) }) { … }`
    func observeAny<Snapshot: Sendable>(
        _ snapshot: @escaping @MainActor @Sendable () -> Snapshot,
        onChange: @escaping @MainActor () -> Void
    ) {
        let baseline = ObservationBaseline()
        withObservationTracking {
            _ = snapshot()
        } onChange: {
            baseline.raise()
        }
        add(Task { @MainActor in
            var isFirst = true
            for await _ in Observations(snapshot) {
                if Task.isCancelled { return }
                if isFirst {
                    isFirst = false
                    // 期间没人改过 ＝ 这就是要丢掉的「当前值」。
                    if !baseline.wasRaised { continue }
                }
                onChange()
            }
        })
    }
}

/// 「登记之后有没有人写过」这一位。`observeAny` 的基线就是它。
///
/// 为什么要个盒子：`Atomic` 是 `~Copyable` 的，进不了逃逸闭包，只能挂在一个引用类型上
///（同形的现成物是 `Services/LoudnessStore.swift` 的 `LoudnessScanCancellation`）。
/// 为什么必须是原子的而不是裸 `var`：`withObservationTracking` 的 `onChange` 由被观察
/// 属性的 `willSet` 调，**谁在写谁就在调**，不保证落在主线程上。
private final class ObservationBaseline: Sendable {
    private let raised = Atomic<Bool>(false)

    init() {}

    func raise() { raised.store(true, ordering: .relaxed) }
    var wasRaised: Bool { raised.load(ordering: .relaxed) }
}
