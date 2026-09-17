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
    /// 3. **Equatable 自带相邻去重**，`.removeDuplicates()` 可以直接删。
    ///    非 Equatable 不去重，那些要自己用 AsyncAlgorithms 的 `removeDuplicates(by:)`。
    ///
    /// 首个当前值按 `dropFirst()` 丢掉，对应 Combine 那边到处写的 `$prop.dropFirst()`：
    /// AppKit 侧初值一律在 `viewDidLoad` 里直接读，不靠订阅补。要初值就用 `observeNow`。
    func observe<Value: Sendable>(
        _ value: @escaping @MainActor @Sendable () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        add(Task { @MainActor in
            for await next in Observations(value).dropFirst() {
                if Task.isCancelled { return }
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
}
