import AppKit
import AVFoundation
import Foundation

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
    /// 正在离线扫描的曲目，防止同一首被排两次。
    private var measuring: Set<String> = []

    private static let saveDebounce: UInt64 = 500_000_000
    private static let writeQueue = DispatchQueue(label: "Amber.LoudnessStore.write", qos: .utility)
    /// 离线扫描的并发度：1。扫描是纯 IO + 定点运算，开多路只会和取流抢带宽。
    private static let offlineQueue = DispatchQueue(label: "Amber.LoudnessStore.scan", qos: .utility)

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
            MainActor.assumeIsolated { self?.flushNow() }
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
    /// 已有条目、或者正在量的跳过。
    func measureIfNeeded(track: Track, fileURL url: URL) {
        guard entries[track.id] == nil, !measuring.contains(track.id) else { return }
        measuring.insert(track.id)
        let id = track.id
        Task.detached(priority: .utility) {
            let entry = await withCheckedContinuation { (continuation: CheckedContinuation<LoudnessEntry?, Never>) in
                Self.offlineQueue.async {
                    continuation.resume(returning: Self.scan(url))
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.measuring.remove(id)
                guard let entry else { return }
                self.entries[id] = entry
                self.save()
            }
        }
    }

    /// 用 `AVAudioFile` 一段一段读进来量。4096 帧一读：够摊薄每次读的开销，
    /// 又不会为一首歌一次性拿几十 MB 的 PCM。
    nonisolated static func scan(_ url: URL) -> LoudnessEntry? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { return nil }
        var accumulator = LoudnessMeter.Accumulator(sampleRate: format.sampleRate,
                                                    channels: channels)
        let capacity: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        while true {
            do { try file.read(into: buffer, frameCount: capacity) } catch { return nil }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            let block = (0..<channels).map { c in
                Array(UnsafeBufferPointer(start: data[c], count: frames))
            }
            accumulator.append(block)
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
