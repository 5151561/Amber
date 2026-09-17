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
/// ## 缓冲上界（原来是 `.unbounded`）
///
/// 从前的理由是「事件带的是掩码，丢中间一条就等于丢一次刷新」。**回读消费方之后这条
/// 不成立**：现存全部消费方都是
///
/// ```swift
/// for await _ in changes { setNeedsRefresh() }
/// ```
///
/// 这个形状——资料库五页（`LibrarySongs` / `LibraryArtists` / `LibraryAlbums` /
/// `LibraryAllPlaylists` / `LibraryRecentlyAdded`）加 `PlayQueueModel` 的两条
/// `EventChannel<Void>`，**一个都不读元素本身**，收到就整份重算、再合批到下一轮 runloop。
/// 对这种消费方，「丢掉中间那条」与「收到它」是同一个结果——**只要最后一条不丢**，
/// 而 `.bufferingNewest` 保的正是最后一条。
///
/// （唯一读元素的是 `AmberTests/Services/LibraryStorePersistenceTests` 那条按位核对的
/// 用例，一次只发一条，够不着上界。哪天真出现「按掩码分支处理」的消费方，
/// 先回来改这里：那时丢中间一条就是真丢语义了。）
///
/// 上界取 64：一次批量入库 `LibraryStore.notify` 能连发上百条，而消费方一轮 runloop
/// 只重算一次；堆到 64 已经说明消费方被拖住了，再堆下去只是替它攒内存。
/// 丢弃也不再是静默的——`send` 收 `yield` 的回执，DEBUG 下记在 `droppedCount` /
/// `deepestDepth` 上（`.unbounded` 时代连「堆了多深」都问不出来，只有内存知道）。
@MainActor
final class EventChannel<Element: Sendable> {
    private struct Subscriber {
        let continuation: AsyncStream<Element>.Continuation
        let isInteresting: (@Sendable (Element) -> Bool)?
    }

    /// 每个订阅者的缓冲上界。理由见类型注释。
    /// 写成计算属性不是随手：泛型类型里不许有 `static let` 存储属性。
    static var bufferLimit: Int { 64 }

    private var subscribers: [Int: Subscriber] = [:]
    private var nextToken = 0

    #if DEBUG
    /// 观测口，只在 DEBUG 编：这条通道上堆得最深的一次、以及一共丢过几条。
    /// 平时只是两个计数器，不参与任何判断——它们存在的意义是「堆过」这件事
    /// 从此问得出来，而不是像 `.unbounded` 那样只能事后猜。
    private(set) var deepestDepth = 0
    private(set) var droppedCount = 0
    #endif

    init() {}

    /// 开一条新的订阅流。`isInteresting` 为 nil 时全收。
    ///
    /// 流在订阅者的 `Task` 被取消时自动注销（`onTermination`），不用手工退订。
    func stream(where isInteresting: (@Sendable (Element) -> Bool)? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>
            .makeStream(bufferingPolicy: .bufferingNewest(Self.bufferLimit))
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
            let result = subscriber.continuation.yield(element)
            #if DEBUG
            switch result {
            case .enqueued(let remaining): deepestDepth = max(deepestDepth, Self.bufferLimit - remaining)
            case .dropped: droppedCount += 1
            case .terminated: break
            @unknown default: break
            }
            #endif
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
