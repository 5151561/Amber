import Foundation

/// 多订阅方的事件通道——`PassthroughSubject` 的对位物。
///
/// 为什么不用现成的两个：
///
/// - **`AsyncChannel`（AsyncAlgorithms）的 `send` 是 `async`**，有背压：没人取就挂在那儿。
///   而 `LibraryStore.notify(_:)` 这类发声点是同步方法、被几十处同步调用，换过去等于
///   把 `await` 传染进整条写入路径，还会让「写库」和「界面消费得多快」耦合起来。
/// - **`AsyncStream` 是单消费者**。`changes(affecting:)` 的整个设计就是每个页面各订各的
///   （见 `LibraryChange` 的文档），一条流不够分。
///
/// 所以这里自己攥一把 continuation：`send` 同步、不阻塞、一次喂给所有在听的。
///
/// 缓冲用 `.unbounded`：事件带的是「这一次动了哪几份」的掩码，丢中间一条就等于丢掉
/// 一次刷新。变更事件本来就是低频的（一次用户操作一条），不存在堆积风险。
@MainActor
final class EventChannel<Element: Sendable> {
    private struct Subscriber {
        let continuation: AsyncStream<Element>.Continuation
        let isInteresting: (@Sendable (Element) -> Bool)?
    }

    private var subscribers: [Int: Subscriber] = [:]
    private var nextToken = 0

    init() {}

    /// 开一条新的订阅流。`isInteresting` 为 nil 时全收。
    ///
    /// 流在订阅者的 `Task` 被取消时自动注销（`onTermination`），不用手工退订。
    func stream(where isInteresting: (@Sendable (Element) -> Bool)? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        nextToken += 1
        let token = nextToken
        subscribers[token] = Subscriber(continuation: continuation, isInteresting: isInteresting)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[token] = nil }
        }
        return stream
    }

    /// 发一次。同步，不阻塞，不等任何订阅方。
    func send(_ element: Element) {
        for subscriber in subscribers.values {
            if let isInteresting = subscriber.isInteresting, !isInteresting(element) { continue }
            subscriber.continuation.yield(element)
        }
    }

    /// 关掉所有订阅流。
    func finish() {
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers.removeAll()
    }

    deinit {
        for subscriber in subscribers.values { subscriber.continuation.finish() }
    }
}
