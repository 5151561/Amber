import AVFoundation
import Foundation
import Synchronization
import os

/// 每首歌量到的响度（音量平衡 / Sound Check 用）。
///
/// **不是** `ObservableObject`：这份表是给播放器实时读的，一首歌播完写一条，
/// 界面上没有任何东西显示它。做成 `@Published` 只会让整个界面跟着换歌重画一次
/// （`LibraryStore` 那几本字典的教训）。
///
/// 落在主库的 `loudness` 表里（从前是 `loudness.json` 整份重写 + 500 ms 防抖）：
/// 量完一首写一条单行 UPSERT。离线扫描一首接一首地出结果，正是「每次改一条、
/// 却要把整份重写一遍」最吃亏的那种负载。
///
/// ## 「离线扫描吃满一核」这条**已经修过了**（2026-09-17 核对）
///
/// modernization-review §5 的「单列」里还挂着「`LoudnessStore.scan` 吃满一核，
/// 仍未处理」——那一条是陈旧的。它由 reactive-ui-review 那一轮的**批 L** 修完了，
/// 落在这个文件与 `Player/LoudnessMeter.swift` 上，三样东西现在都在场：
///
/// - **并发度 1**：`offlineQueue` 是一条串行队列，全 App 只有一份 store（见它的注释）；
/// - **首内节流**：`LoudnessScanPace.throttled` 算 20 ms 睡 30 ms，占一个核的四成；
/// - **首间让步**：`trackGap` 0.25 s。
///
/// 而真根因也不是节流——是 `AVAudioFile.read` 读到文件尾抛 `eofErr` 让**每一首都整首
/// 作废**（见 `scan` 的注释）。批 L 实机复量：CPU 99–163% → 13–22%，RSS 从 174→280 MB
/// 的爬升变成平稳 174 MB。所以这一轮**没有再动节流**：再压只会让「300 首要六分钟」
/// 变成更久，而那正是 `scan` 里明写过的取舍。这一轮只补了批 L 自己留下的那条尾巴
/// ——刚下完的歌不该排在启动补量队列后面，见 `ScanPriority`。
@MainActor
final class LoudnessStore {

    /// 读库失败与落库失败两条。与 `LibraryStore.log` 同解（都是降级路径，不弹界面）。
    private static let log = AmberDiagnostics.logger("loudness")

    private(set) var entries: [String: LoudnessEntry] = [:]

    /// 主库连接。**nil ＝ 开库这一步就失败了**：内存这一份照常能用，只是这一程量出来的
    /// 落不了盘。与 `LibraryStore.database` 同解。
    private let database: AmberDatabase?
    /// 载入成功了没有。没成功就一个字都不许往回写（见 `LibraryStore.isLoaded`）。
    private var isLoaded = false

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

    /// 离线扫描的并发度：1。扫描是纯 IO + 定点运算，开多路只会和取流抢带宽。
    ///
    /// 每份 store 一条，不是全类共用一条：App 里本来就只有一份 store（并发度还是 1），
    /// 而测试里会另起注入临时目录的 store——共用一条的话，它得排在测试宿主（也就是 Amber
    /// 自己）启动时灌进来的整个资料库后面，一条 3 秒的用例要等 19 秒。
    private let offlineQueue = DispatchQueue(label: "Amber.LoudnessStore.scan", qos: .utility)
    /// 两首之间的间隔。见 `scan` 里对节流的说明。
    private static let trackGap: UInt64 = 250_000_000

    /// `directory` 供测试注入临时目录；默认落 `~/Library/Application Support/Amber/`。
    /// 解析规则由 `AmberDatabase.shared(directory:)` 一处管着——同一个目录拿到同一条连接。
    init(directory: URL? = nil) {
        // 开库之前先把迁移跑到，理由与 `TrackInfoStore.init` 逐字相同：
        // **谁先开库谁负责迁移**，一个都不许在旧 JSON 还没搬完之前把空库建出来。
        _ = try? AmberDatabaseMigration.runIfNeeded(directory: directory, mediaFolder: directory,
                                                    renameLegacyOnSuccess: true)
        database = try? AmberDatabase.shared(directory: directory)
        load()
        // **没有自己的 willTerminate 观察者了**（全 App 只剩 `AmberDatabase` 那一个）。
        // 量出来的当场落库，没有「还没写的」；退出前剩下的只有「先叫停扫描」这一件——
        // 不然还有一条线程在读文件、算 DSP，而它算完那一下正好落在 checkpoint 之后。
        database?.addTerminationTask { [weak self] in self?.cancelAllMeasurements() }
    }

    private func load() {
        guard let db = database?.sqlite else { return }
        do {
            var loaded: [String: LoudnessEntry] = [:]
            for row in try db.query(
                "SELECT track_id, lufs, peak_db, measured_at FROM loudness", [],
                { (id: $0.text(0),
                   entry: LoudnessEntry(lufs: $0.double(1), peakDB: $0.double(2),
                                        measuredAt: Date(timeIntervalSinceReferenceDate: $0.double(3)))) }
            ) {
                loaded[row.id] = row.entry
            }
            entries = loaded
            isLoaded = true
        } catch {
            Self.log.error("""
                读库失败，这一程只读不写（库里那份一个字没动）：\
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    subscript(trackID: String) -> LoudnessEntry? { entries[trackID] }

    func entry(for track: Track) -> LoudnessEntry? { entries[track.id] }

    func record(_ entry: LoudnessEntry, for track: Track) {
        entries[track.id] = entry
        persist(entry, for: track.id)
    }

    // MARK: - 离线扫描（已下载的文件）

    /// 排在队里的两档。
    ///
    /// 这一队是**先进先出**的，而启动时 `AppState.measureDownloadedTracks()` 会一次性
    /// 把整个资料库里已下载的曲目全丢进来。刚下完的那一首要是也走 `.backlog`，
    /// 就得排在那几百首后面——按现在的节流（首内 40% 占空比 + 首间 0.25 s，见 `scan`）
    /// 一个 300 首的库要六分钟才轮得到它，而用户刚点的那一下就是奔着「这首」去的。
    enum ScanPriority {
        /// 启动补量那一批：按加入顺序排在队尾。
        case backlog
        /// 用户刚触发的这一首：插队到队首，下一个就是它。
        ///
        /// 插队**不打断正在量的那一首**——扫描是一条串行流水线，掐掉半首等于把已经
        /// 算过的那几分钟音频白扔了，而它最多再占 0.9 s（同上，实测数在 `scan` 那边）。
        case next
    }

    /// 已经落地的文件直接离线量一遍，不用等用户把整首听完。
    /// 已有条目、已经在队里、或者正在量的跳过。
    ///
    /// 这里只排队，不起活：真正干活的是唯一那条消费者（`startScanningIfNeeded`）。
    ///
    /// `priority` 带默认值，所以启动补量那条路（以及测试里的调用点）一个字不用改——
    /// 只有 `AppState.onDownloaded` 那一行传 `.next`。
    func measureIfNeeded(track: Track, fileURL url: URL, priority: ScanPriority = .backlog) {
        guard entries[track.id] == nil,
              !pendingIDs.contains(track.id),
              current?.id != track.id else { return }
        pendingIDs.insert(track.id)
        switch priority {
        case .backlog: pending.append((id: track.id, url: url))
        // 连着下好几首时，后下完的排在先下完的**前面**：两首都是刚点的，
        // 谁的封面还在屏幕上谁先量，比严格按点击顺序更贴用户此刻在看什么。
        case .next: pending.insert((id: track.id, url: url), at: 0)
        }
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
                    self.persist(entry, for: next.id)
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
        // 这一段三处 `unsafe` 是同一条契约：`AVAudioPCMBuffer` 的样本只能经
        // `floatChannelData`（`UnsafePointer<UnsafeMutablePointer<Float>>?`）拿到，
        // AVFoundation 没给出借 `Span` 的安全口子。
        //
        // 谁保证它安全：`buffer` 是这个函数的局部强引用，活到 `scan` 返回，指针不会悬垂；
        // 缓冲在 `init` 时按 `frameCapacity` 一次分好，`read(into:)` 只往里填不重分配，
        // 所以指针表在循环外取一次就够。读的范围由 `frames = buffer.frameLength` 界定，
        // 它永远 ≤ `capacity`，是 AVFoundation 自己回报的已填帧数。
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let data = unsafe buffer.floatChannelData else {
            return nil
        }
        let pointers = unsafe (0..<channels).map { unsafe UnsafePointer(data[$0]) }
        var busySince = DispatchTime.now().uptimeNanoseconds
        while file.framePosition < total {
            if cancel?.isCancelled == true { return nil }
            let want = AVAudioFrameCount(min(Int64(capacity), total - file.framePosition))
            // 这里的 catch 是真出错（文件被删、解码坏帧）：把已经量到的那部分交出去，
            // 比整首作废强——门限只认满 400 ms 的块，缺一截尾巴不会让结论跑偏。
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            pointers.withUnsafeBufferPointer { unsafe accumulator.append($0, frames: frames) }
            if pace.idleNanoseconds > 0,
               DispatchTime.now().uptimeNanoseconds &- busySince >= pace.busyNanoseconds {
                Thread.sleep(forTimeInterval: Double(pace.idleNanoseconds) / 1e9)
                busySince = DispatchTime.now().uptimeNanoseconds
            }
        }
        return accumulator.entry
    }

    // MARK: - 落库

    /// 一首一条 UPSERT。出错只记一笔：量响度是后台尽力而为的活，磁盘满的时候没有
    /// 任何界面处置可言，内存那份照常能用，下一次量到同一首自会把它补上。
    ///
    /// `gainDB` 不落列（它是按目标 −16 LUFS、+6 上限、峰值留 1 dB 现算的派生量，
    /// 存下来就等着改参数那天全变陈旧值），见 schema 注释。
    private func persist(_ entry: LoudnessEntry, for id: String) {
        guard isLoaded, let db = database?.sqlite else { return }
        do {
            try db.run("""
                INSERT INTO loudness (track_id, lufs, peak_db, measured_at) VALUES (?,?,?,?)
                ON CONFLICT(track_id) DO UPDATE SET
                  lufs = excluded.lufs, peak_db = excluded.peak_db,
                  measured_at = excluded.measured_at
                """, [id, entry.lufs, entry.peakDB, entry.measuredAt])
        } catch {
            Self.log.error("响度落库失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 退出前把 wal 并回主库。
    ///
    /// **名字与全部调用点保留。** 从前它是「立刻把防抖中的那份 JSON 同步写下去」；
    /// 现在量完一首当场落库，没有「还没写的」，剩下要收的只有 WAL 旁文件
    /// （见 `AmberDatabase.checkpoint()`）。
    func flushNow() { database?.checkpoint() }
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
