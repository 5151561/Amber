import XCTest
@testable import Amber

/// 响度缓存的读写与落盘。
final class LoudnessStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoudnessStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(_ id: String) -> Track {
        Track(id: id, kind: .qq, title: id, artistName: "艺人", artistId: nil,
              albumName: "", albumId: nil, artworkURL: nil, duration: 200)
    }

    @MainActor
    func testRecordAndReload() {
        let store = LoudnessStore(directory: directory)
        let entry = LoudnessEntry(lufs: -22, peakDB: -1.5, measuredAt: Date())
        store.record(entry, for: track("qq:1"))
        store.flushNow()

        let reloaded = LoudnessStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: track("qq:1"))?.lufs, -22)
        XCTAssertNil(reloaded.entry(for: track("qq:2")))
        // 并进主库之后不再另开 loudness.json。
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("loudness.json").path))
        XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("library.sqlite").path))
    }

    /// 缓存里的条目直接给出该用的增益（−16 目标、+6 上限、峰值留 1 dB）。
    @MainActor
    func testEntryGain() {
        let quiet = LoudnessEntry(lufs: -30, peakDB: -20, measuredAt: Date())
        XCTAssertEqual(quiet.gainDB, 6, accuracy: 0.001)
        let loud = LoudnessEntry(lufs: -8, peakDB: -0.2, measuredAt: Date())
        XCTAssertEqual(loud.gainDB, -8, accuracy: 0.001)
    }

    @MainActor
    func testEmptyDirectoryStartsEmpty() {
        XCTAssertTrue(LoudnessStore(directory: directory).entries.isEmpty)
    }

    // MARK: - 离线扫描

    /// **回归**：扫到文件末尾要有结论。
    ///
    /// `AVAudioFile.read(into:frameCount:)` 读到末尾是抛 `eofErr`（−39）而不是回 0 帧的
    /// （m4a / flac / wav 实测都一样），从前那版读循环靠「读到 0 帧」收、`catch` 里
    /// 直接 `return nil`，于是每一首都在最后一步把整首量好的结果丢掉——扫了等于白扫，
    /// 下次启动还得从头再扫一遍。那才是「启动就烧一个核、而且永远收敛不了」的根因。
    func testScanReachesEndOfFileAndReturnsAnEntry() throws {
        let url = try LoudnessTestSignal.writeWAV(seconds: 3, sampleRate: 44_100, to: directory)
        let entry = try XCTUnwrap(LoudnessStore.scan(url, pace: .unthrottled))
        XCTAssertEqual(entry.lufs, -12.43502943496377, accuracy: 1e-9)
        XCTAssertEqual(entry.peakDB, -9.1211934721470467, accuracy: 1e-9)
    }

    /// 文件那条路与内存那条路是同一套数：按同样的 4096 帧分段喂，结果**逐位**相同。
    func testScanMatchesInMemoryMeasurementBitForBit() throws {
        let fs: Double = 44_100
        let url = try LoudnessTestSignal.writeWAV(seconds: 3, sampleRate: fs, to: directory)
        let entry = try XCTUnwrap(LoudnessStore.scan(url, pace: .unthrottled))
        let inMemory = LoudnessTestSignal.measure(
            LoudnessTestSignal.channels(seconds: 3, sampleRate: fs), sampleRate: fs, chunk: 4096)
        XCTAssertEqual(entry.lufs.bitPattern, try XCTUnwrap(inMemory.integratedLUFS).bitPattern)
        XCTAssertEqual(entry.peakDB.bitPattern, inMemory.peakDB.bitPattern)
    }

    /// 取消旗标一举起来就收手（曲目被删、App 退出走的都是这条）。
    func testScanHonoursCancellation() throws {
        let url = try LoudnessTestSignal.writeWAV(seconds: 3, sampleRate: 44_100, to: directory)
        let cancel = LoudnessScanCancellation()
        cancel.cancel()
        XCTAssertNil(LoudnessStore.scan(url, pace: .unthrottled, cancel: cancel))
    }

    /// 整条流水线：排队 → 唯一那个消费者量完 → 写进表。重复排队要被挡掉。
    @MainActor
    func testMeasureIfNeededRecordsThroughThePipeline() async throws {
        let url = try LoudnessTestSignal.writeWAV(seconds: 3, sampleRate: 44_100, to: directory)
        let store = LoudnessStore(directory: directory)
        let song = track("qq:1")
        store.measureIfNeeded(track: song, fileURL: url)
        store.measureIfNeeded(track: song, fileURL: url)
        let deadline = Date().addingTimeInterval(30)
        while store.entry(for: song) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let entry = try XCTUnwrap(store.entry(for: song), "30 秒内没量出来")
        XCTAssertEqual(entry.lufs, -12.43502943496377, accuracy: 1e-9)
    }

    /// 排了队还没开工就被叫停：队要清空，表里不该出现条目。
    @MainActor
    func testCancelAllClearsTheQueue() async throws {
        let url = try LoudnessTestSignal.writeWAV(seconds: 3, sampleRate: 44_100, to: directory)
        let store = LoudnessStore(directory: directory)
        let song = track("qq:1")
        store.measureIfNeeded(track: song, fileURL: url)
        store.cancelAllMeasurements()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(store.entry(for: song))
    }
}
