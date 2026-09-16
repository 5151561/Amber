import AppKit
import AVFoundation
import Foundation
import Synchronization

/// 每首歌量到的响度（音量平衡 / Sound Check 用）。
///
/// **不是** `ObservableObject`：这份表是给播放器实时读的，一首歌播完写一条，
/// 界面上没有任何东西显示它。做成 `@Published` 只会让整个界面跟着换歌重画一次
/// （`LibraryStore` 那几本字典的教训）。
///
/// 落盘照抄 `LibraryStore.save()`：500 ms 防抖 + 串行写盘队列 + 退出前同步兜底。
@MainActor
final class LoudnessStore {

    private(set) var entries: [String: LoudnessEntry] = [:]

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?

    /// 等着量的曲目。队里只放 `(id, url)` 这两件轻的——启动时
    /// `AppState.measureDownloadedTracks()` 会把整个资料库里已下载的曲目一次性丢进来，
    /// 从前那版给每一首起一个 `Task.detached` 再挂在同一条串行队列上等，
    /// 有多少首就挂多少个任务和多少个续体，全在那儿排队空等。
    private var pending: [(id: String, url: URL)] = []
    /// 队里已有哪些 id，防止同一首排两次。
    private var pendingIDs: Set<String> = []
    /// 唯一的消费者：一首一首取，队空了自己收摊。
    private var scanner: Task<Void, Never>?
    /// 消费者的世代号：`cancelAllMeasurements()` 之后旧消费者不能再把新消费者的登记抹掉。
    private var scannerGeneration = 0
    /// 正在量的那首 + 它的取消旗标。
    private var current: (id: String, cancel: LoudnessScanCancellation)?

    private static let saveDebounce: UInt64 = 500_000_000
    private static let writeQueue = DispatchQueue(label: "Amber.LoudnessStore.write", qos: .utility)
    /// 离线扫描的并发度：1。扫描是纯 IO + 定点运算，开多路只会和取流抢带宽。
    ///
    /// 每份 store 一条，不是全类共用一条：App 里本来就只有一份 store（并发度还是 1），
    /// 而测试里会另起注入临时目录的 store——共用一条的话，它得排在测试宿主（也就是 Amber
    /// 自己）启动时灌进来的整个资料库后面，一条 3 秒的用例要等 19 秒。
    private let offlineQueue = DispatchQueue(label: "Amber.LoudnessStore.scan", qos: .utility)
    /// 两首之间的间隔。见 `scan` 里对节流的说明。
    private static let trackGap: UInt64 = 250_000_000

    /// `directory` 供测试注入临时目录；默认落 `~/Library/Application Support/Amber/`。
    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Amber", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("loudness.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: LoudnessEntry].self, from: data) {
            entries = decoded
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 先叫停扫描再落盘：不然退出时还有一条线程在读文件、算 DSP。
                self?.cancelAllMeasurements()
                self?.flushNow()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    subscript(trackID: String) -> LoudnessEntry? { entries[trackID] }

    func entry(for track: Track) -> LoudnessEntry? { entries[track.id] }

    func record(_ entry: LoudnessEntry, for track: Track) {
        entries[track.id] = entry
        save()
    }

    // MARK: - 离线扫描（已下载的文件）

    /// 已经落地的文件直接离线量一遍，不用等用户把整首听完。
    /// 已有条目、已经在队里、或者正在量的跳过。
    ///
    /// 这里只排队，不起活：真正干活的是唯一那条消费者（`startScanningIfNeeded`）。
    func measureIfNeeded(track: Track, fileURL url: URL) {
        guard entries[track.id] == nil,
              !pendingIDs.contains(track.id),
              current?.id != track.id else { return }
        pendingIDs.insert(track.id)
        pending.append((id: track.id, url: url))
        startScanningIfNeeded()
    }

    /// 这些曲目不用量了（从资料库删了、文件没了）。正在量的那首当场停。
    func cancelMeasurements(for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pending.removeAll { ids.contains($0.id) }
        pendingIDs.subtract(ids)
        if let current, ids.contains(current.id) { current.cancel.cancel() }
    }

    /// 全停：退出时用。正在量的那首在下一段（4096 帧，≈93 ms 的音频）就收手。
    func cancelAllMeasurements() {
        pending.removeAll()
        pendingIDs.removeAll()
        current?.cancel.cancel()
        scanner?.cancel()
        scanner = nil
        scannerGeneration += 1
    }

    /// 一条流水线：从队里取一首、量完、写进表，再取下一首。
    ///
    /// 让步用的是「每首之间 `Task.sleep`」+「扫描线程自己按占空比歇」（见 `scan`）。
    /// 为什么不是「等主线程空」：离线量响度不跟任何一帧界面绑着，没有「空了就该我上」
    /// 的时机；而 `.utility` 的 QoS 只降优先级不限 CPU——机器闲着的时候
    /// 「优先级最低的那个」照样能把一个核吃满，这正是今天这幅样子的由来。
    private func startScanningIfNeeded() {
        guard scanner == nil, !pending.isEmpty else { return }
        scannerGeneration += 1
        let generation = scannerGeneration
        scanner = Task { [weak self] in
            while true {
                guard !Task.isCancelled, let self, let next = self.takeNextPending() else { break }
                let cancel = LoudnessScanCancellation()
                self.current = (id: next.id, cancel: cancel)
                let queue = self.offlineQueue
                let entry = await withCheckedContinuation {
                    (continuation: CheckedContinuation<LoudnessEntry?, Never>) in
                    queue.async {
                        continuation.resume(returning: Self.scan(next.url, cancel: cancel))
                    }
                }
                self.current = nil
                if let entry {
                    self.entries[next.id] = entry
                    self.save()
                }
                // 两首之间再空一手：连着量几百首时，这一下让主线程有整段的空窗，
                // 也给磁盘缓存喘口气。
                try? await Task.sleep(nanoseconds: Self.trackGap)
            }
            guard let self, self.scannerGeneration == generation else { return }
            self.scanner = nil
        }
    }

    private func takeNextPending() -> (id: String, url: URL)? {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            pendingIDs.remove(next.id)
            // 排队期间可能已经被「整首播完」那条路量出来了。
            if entries[next.id] == nil { return next }
        }
        return nil
    }

    /// 用 `AVAudioFile` 一段一段读进来量。4096 帧一读：够摊薄每次读的开销，
    /// 又不会为一首歌一次性拿几十 MB 的 PCM。
    ///
    /// **读循环按 `file.length` 收口，不靠「读到 0 帧」收**：`read(into:frameCount:)`
    /// 读到文件末尾是抛 `eofErr`（OSStatus −39）而不是回 0 帧的（m4a / flac / wav 实测
    /// 都一样），从前那版的 `catch { return nil }` 于是在最后一步把整首量好的结果全丢了
    /// ——扫了等于白扫，下次启动还得从头再来。「启动就烧一个核、而且永远收敛不了」
    /// 的真根因是这一条，不是 DSP 慢。
    ///
    /// 节流：连续算 `pace` 规定的那么久就让线程睡一小会儿。睡的是
    /// `offlineQueue` 这条我们自己的串行队列的线程——它背后没有别人排队，睡着不占 CPU，
    /// 也不会像 `Task.yield()` 那样把协作线程池的一个线程一直攥在手里。
    /// 代价：开着「音量平衡」的用户要多等。按实测（Debug，见本次改动的基准）
    /// 一首 3 分钟的歌纯算约 0.35 s，40% 占空比下变成约 0.9 s，加两首之间的 0.25 s，
    /// 一个 300 首的资料库大约 6 分钟才全部有数——而在这之前它是**永远没有数**。
    nonisolated static func scan(_ url: URL,
                                 pace: LoudnessScanPace = .throttled,
                                 cancel: LoudnessScanCancellation? = nil) -> LoudnessEntry? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = file.length
        guard channels > 0, format.sampleRate > 0, total > 0 else { return nil }
        var accumulator = LoudnessMeter.Accumulator(sampleRate: format.sampleRate,
                                                    channels: channels)
        let capacity: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let data = buffer.floatChannelData else {
            return nil
        }
        // 各声道的指针在 buffer 的一生里不变（缓冲在 init 时就分好了，read 只往里填），
        // 所以指针表在循环外取一次就够，不用每读一段就造一份新数组。
        let pointers = (0..<channels).map { UnsafePointer(data[$0]) }
        var busySince = DispatchTime.now().uptimeNanoseconds
        while file.framePosition < total {
            if cancel?.isCancelled == true { return nil }
            let want = AVAudioFrameCount(min(Int64(capacity), total - file.framePosition))
            // 这里的 catch 是真出错（文件被删、解码坏帧）：把已经量到的那部分交出去，
            // 比整首作废强——门限只认满 400 ms 的块，缺一截尾巴不会让结论跑偏。
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            pointers.withUnsafeBufferPointer { accumulator.append($0, frames: frames) }
            if pace.idleNanoseconds > 0,
               DispatchTime.now().uptimeNanoseconds &- busySince >= pace.busyNanoseconds {
                Thread.sleep(forTimeInterval: Double(pace.idleNanoseconds) / 1e9)
                busySince = DispatchTime.now().uptimeNanoseconds
            }
        }
        return accumulator.entry
    }

    // MARK: - 落盘

    private func save() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            let snapshot = self.entries
            let url = self.fileURL
            Self.writeQueue.async { Self.write(snapshot, to: url) }
        }
    }

    func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let url = fileURL
        Self.writeQueue.sync { Self.write(snapshot, to: url) }
    }

    private nonisolated static func write(_ entries: [String: LoudnessEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 离线扫描的占空比。`busy` 算完就歇 `idle`，两者之比就是这条线程最多占一个核的几成。
///
/// 20 / 30 是这么来的：30 ms 的停顿足够让主线程把一轮事件（一次布局、一次绘制）走完，
/// 20 ms 又不至于把一首歌拖到几秒才量完。这不是对着某一首歌调出来的系数——
/// 它跟音频内容无关，只跟「一帧界面多久」有关。
struct LoudnessScanPace: Sendable {
    var busyNanoseconds: UInt64
    var idleNanoseconds: UInt64

    /// 正常用：最多占一个核的四成。
    static let throttled = LoudnessScanPace(busyNanoseconds: 20_000_000,
                                            idleNanoseconds: 30_000_000)
    /// 不节流：单元测试和一次性基准用，别在 App 里用。
    static let unthrottled = LoudnessScanPace(busyNanoseconds: .max, idleNanoseconds: 0)
}

/// 扫描线程上看得见的取消旗标。
///
/// 为什么不直接用 `Task.isCancelled`：扫描跑在 `LoudnessStore.offlineQueue` 这条 GCD
/// 串行队列的线程上，那里没有 task 上下文，`Task.isCancelled` 恒为 false。
final class LoudnessScanCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    init() {}

    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}
