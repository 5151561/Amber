import XCTest
@testable import Amber

/// 响度缓存的读写与落盘。
final class LoudnessStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoudnessStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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
}
