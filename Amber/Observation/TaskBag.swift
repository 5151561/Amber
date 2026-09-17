import Foundation
import Observation

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
    /// 用法：`observers.observeAny({ (model.items, model.sort, model.filter) }) { … }`
    ///
    /// 元组没有 Equatable，所以：**不会去重**（与 `objectWillChange` 同口径），
    /// 也**没有** `observe` 那道基线保护——登记到首次跑起来之间的改动会被当成「当前值」丢掉。
    /// 这里的消费方都是 `setNeedsRefresh()` 这种幂等合批入口，页面自己的首次加载另有其路，
    /// 漏掉启动那一下没有后果；要是哪天用在别处，先想清楚这一条。
    func observeAny<Snapshot: Sendable>(
        _ snapshot: @escaping @MainActor @Sendable () -> Snapshot,
        onChange: @escaping @MainActor () -> Void
    ) {
        add(Task { @MainActor in
            for await _ in Observations(snapshot).dropFirst() {
                if Task.isCancelled { return }
                onChange()
            }
        })
    }
}
