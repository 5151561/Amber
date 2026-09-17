import AVFoundation
import XCTest
@testable import Amber

/// 两个响度测试类共用的确定性信号：固定种子 LCG 噪声 + 1 kHz 正弦（每 10 秒留 1 秒静音）。
///
/// 「确定性」在这里是硬要求：`LoudnessMeterTests.testPinnedLoudness…` 把它的 LUFS / 峰值
/// 钉成了常量，信号只要变一个样本，钉子就失效了。别往里加随机数、别改种子、别改幅度。
enum LoudnessTestSignal {

    static func channels(seconds: Double, sampleRate: Double) -> [[Float]] {
        let count = Int(seconds * sampleRate)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for i in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max) * 0.05
            let tone = 0.3 * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate))
            let silent = (Double(i) / sampleRate).truncatingRemainder(dividingBy: 10) >= 9
            left[i] = silent ? 0 : noise + tone
            right[i] = silent ? 0 : noise * 0.8 - tone * 0.5
        }
        return [left, right]
    }

    /// 把同一段信号写成 float32 的 WAV：读回来与内存里那份逐位相同（不经过任何量化），
    /// 「文件那条路」和「内存那条路」才能拿来对。
    static func writeWAV(seconds: Double, sampleRate: Double, to directory: URL) throws -> URL {
        let data = channels(seconds: seconds, sampleRate: sampleRate)
        let url = directory.appendingPathComponent("loudness-signal-\(Int(seconds))s.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: data.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(data[0].count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: frames))
        buffer.frameLength = frames
        let target = try unsafe XCTUnwrap(buffer.floatChannelData)
        for (c, samples) in data.enumerated() {
            samples.withUnsafeBufferPointer { source in
                if let start = source.baseAddress { unsafe target[c].update(from: start, count: samples.count) }
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// 按 `chunk` 帧一段喂进累加器——离线扫描就是这么喂的（4096 帧一读）。
    ///
    /// 这段里的 `unsafe` 说的是同一条契约：`flat` 是本函数自己 `allocate` 的一块连续内存，
    /// `defer` 里配对 `deinitialize` + `deallocate`，中途不逃逸；每轮现搭的指针表只在
    /// `withUnsafeBufferPointer` 的闭包里借给 `append`，`append` 自己不留存
    /// （契约见 `LoudnessMeter.Accumulator.append` 的文档）。
    static func measure(_ data: [[Float]], sampleRate: Double,
                        chunk: Int) -> LoudnessMeter.Accumulator {
        var accumulator = LoudnessMeter.Accumulator(sampleRate: sampleRate, channels: data.count)
        let length = data[0].count
        let count = data.count
        let flat = UnsafeMutablePointer<Float>.allocate(capacity: count * length)
        unsafe flat.initialize(repeating: 0, count: count * length)
        defer { unsafe flat.deinitialize(count: count * length); unsafe flat.deallocate() }
        for (c, samples) in data.enumerated() {
            samples.withUnsafeBufferPointer { source in
                if let start = source.baseAddress { unsafe (flat + c * length).update(from: start, count: length) }
            }
        }
        var offset = 0
        while offset < length {
            let n = min(chunk, length - offset)
            let table = unsafe (0..<count).map { unsafe UnsafePointer(flat + $0 * length + offset) }
            table.withUnsafeBufferPointer { unsafe accumulator.append($0, frames: n) }
            offset += n
        }
        return accumulator
    }
}

/// BS.1770 响度测量：正弦标定、门限、采样率无关性，以及归一化增益的取值。
final class LoudnessMeterTests: XCTestCase {

    /// 双声道 1 kHz 正弦，峰值幅度 `amplitude`，长 `seconds` 秒。
    private func sine(amplitude: Float, seconds: Double, sampleRate: Double,
                      silentPrefix: Double = 0) -> [[Float]] {
        let silent = Int(silentPrefix * sampleRate)
        let tone = Int(seconds * sampleRate)
        var channel = [Float](repeating: 0, count: silent)
        channel.reserveCapacity(silent + tone)
        for i in 0..<tone {
            channel.append(amplitude * Float(sin(2 * Double.pi * 1000 * Double(i) / sampleRate)))
        }
        return [channel, channel]
    }

    /// K 加权在 1 kHz 处的增益（两节串起来）。标定的期望值由它推出来，不是拍的。
    private func kGainAt1kHz(_ sampleRate: Double) -> Double {
        Biquad.magnitudeDB(LoudnessMeter.kWeightingHighShelf(sampleRate: sampleRate),
                           frequency: 1000, sampleRate: sampleRate)
        + Biquad.magnitudeDB(LoudnessMeter.kWeightingHighPass(sampleRate: sampleRate),
                             frequency: 1000, sampleRate: sampleRate)
    }

    /// 双声道正弦的解析响度：`−0.691 + 10·log10(Σ_c 幅度²/2) + K(1kHz)`。
    private func expectedLUFS(amplitude: Float, sampleRate: Double) -> Double {
        let meanSquare = Double(amplitude) * Double(amplitude) / 2
        return LoudnessMeter.offset + 10 * log10(2 * meanSquare) + kGainAt1kHz(sampleRate)
    }

    private func measure(_ channels: [[Float]], sampleRate: Double) -> Double? {
        var accumulator = LoudnessMeter.Accumulator(sampleRate: sampleRate, channels: channels.count)
        accumulator.append(channels)
        return accumulator.integratedLUFS
    }

    /// 1 kHz −20 dBFS（峰值）正弦，双声道。
    func testSineCalibration48k() {
        let fs: Double = 48_000
        let measured = measure(sine(amplitude: 0.1, seconds: 5, sampleRate: fs), sampleRate: fs)
        XCTAssertNotNil(measured)
        XCTAssertEqual(measured!, expectedLUFS(amplitude: 0.1, sampleRate: fs), accuracy: 0.3)
    }

    /// 换采样率结论不变（K 加权按 fs 做双线性变换，不是写死 48k 的系数）。
    func testSineCalibration44k() {
        let fs: Double = 44_100
        let measured = measure(sine(amplitude: 0.1, seconds: 5, sampleRate: fs), sampleRate: fs)
        XCTAssertNotNil(measured)
        XCTAssertEqual(measured!, expectedLUFS(amplitude: 0.1, sampleRate: fs), accuracy: 0.3)
        let at48k = measure(sine(amplitude: 0.1, seconds: 5, sampleRate: 48_000), sampleRate: 48_000)
        XCTAssertEqual(measured!, at48k!, accuracy: 0.2)
    }

    /// 前半段静音被门限剔除：结论和只有后半段正弦时一样。
    func testSilenceIsGatedOut() {
        let fs: Double = 48_000
        let withSilence = measure(sine(amplitude: 0.1, seconds: 5, sampleRate: fs, silentPrefix: 5),
                                  sampleRate: fs)
        let toneOnly = measure(sine(amplitude: 0.1, seconds: 5, sampleRate: fs), sampleRate: fs)
        XCTAssertNotNil(withSilence)
        XCTAssertEqual(withSilence!, toneOnly!, accuracy: 0.2,
                       "静音块要被 −70 LUFS 的绝对门限挡掉，不能把整首拉低")
    }

    /// 不够一个 400 ms 块就没有结论（宁可没有，也不给一个从 50 ms 猜出来的数）。
    func testTooShortHasNoResult() {
        let fs: Double = 48_000
        XCTAssertNil(measure(sine(amplitude: 0.1, seconds: 0.2, sampleRate: fs), sampleRate: fs))
    }

    func testPeakIsTracked() {
        var accumulator = LoudnessMeter.Accumulator(sampleRate: 48_000, channels: 2)
        accumulator.append(sine(amplitude: 0.5, seconds: 1, sampleRate: 48_000))
        XCTAssertEqual(accumulator.peakDB, 20 * log10(0.5), accuracy: 0.1)
    }

    // MARK: 数值不许飘

    /// **钉子**：一段确定性信号的积分响度与峰值。
    ///
    /// 这两个数是 2026-09-17「热循环改成指针 + 三件事融成一趟」**那次改动之前**跑出来的
    /// （`-Onone` 与 `-O` 一致，逐位 0xc028debc2d97eefa / 0xc0223e0d121eb873），改动之后
    /// 逐位相同。以后谁再动 `Accumulator.append`、`Biquad` 的递推式或者 K 加权系数，
    /// 只要结论变了就会在这里绊倒。
    ///
    /// 误差上界 1e-9 只留给 libm：系数里有 `tan` / `pow`，换个系统版本可能差最后一个 ulp。
    /// 算法层面的走样（少一节滤波、跳块、换 `Float` 累加平方和）差的是 0.01 LU 以上，
    /// 这个上界挡得住。
    func testPinnedLoudnessOfDeterministicSignal() {
        let fs: Double = 44_100
        var accumulator = LoudnessMeter.Accumulator(sampleRate: fs, channels: 2)
        accumulator.append(LoudnessTestSignal.channels(seconds: 3, sampleRate: fs))
        XCTAssertEqual(try XCTUnwrap(accumulator.integratedLUFS), -12.43502943496377, accuracy: 1e-9)
        XCTAssertEqual(accumulator.peakDB, -9.1211934721470467, accuracy: 1e-9)
    }

    /// 数组入口只是「先拷进连续缓冲、再走指针入口」，两条路必须**逐位**相同。
    /// 用位型比而不是 `accuracy:`：这里没有任何可以容忍的误差，一个 ulp 都不行。
    func testArrayEntryMatchesPointerEntryBitForBit() {
        let fs: Double = 44_100
        let signal = LoudnessTestSignal.channels(seconds: 1, sampleRate: fs)
        var arrayPath = LoudnessMeter.Accumulator(sampleRate: fs, channels: 2)
        arrayPath.append(signal)
        let pointerPath = LoudnessTestSignal.measure(signal, sampleRate: fs, chunk: signal[0].count)
        XCTAssertEqual(try XCTUnwrap(arrayPath.integratedLUFS).bitPattern,
                       try XCTUnwrap(pointerPath.integratedLUFS).bitPattern)
        XCTAssertEqual(arrayPath.peak.bitPattern, pointerPath.peak.bitPattern)
        XCTAssertEqual(arrayPath.framesSeen, pointerPath.framesSeen)
    }

    /// 手动跑的基准（默认跳过）。热循环退回 `for i in 0..<n` / `[[Float]]` 那种写法时，
    /// 每样本的耗时会翻十几倍——这条用来复量，不进常规测试。
    /// 跑法：`TEST_RUNNER_AMBER_LOUDNESS_BENCH=1 xcodebuild … -only-testing:AmberTests/LoudnessMeterTests/testAppendThroughputBenchmark`
    func testAppendThroughputBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMBER_LOUDNESS_BENCH"] == "1",
                          "手动基准，默认不跑")
        let fs: Double = 44_100
        let signal = LoudnessTestSignal.channels(seconds: 60, sampleRate: fs)
        let start = Date()
        let accumulator = LoudnessTestSignal.measure(signal, sampleRate: fs, chunk: 4096)
        let elapsed = -start.timeIntervalSinceNow
        let samples = Double(accumulator.framesSeen * signal.count)
        print(unsafe String(format: "append: %.3f s / 60 s 音频（%.0f× 实时），%.1f ns/样本",
                     elapsed, 60 / elapsed, elapsed / samples * 1e9))
    }

    // MARK: 归一化增益

    /// 安静的曲目提升到上限就打住，还要给峰值留 1 dB。
    func testGainIsCappedByBoostLimit() {
        XCTAssertEqual(LoudnessMeter.gainDB(lufs: -30, peakDB: -20), 6, accuracy: 0.001)
    }

    func testGainIsCappedByPeakHeadroom() {
        XCTAssertEqual(LoudnessMeter.gainDB(lufs: -30, peakDB: -3), 2, accuracy: 0.001)
    }

    /// 响的曲目往下拉不设限。
    func testAttenuationIsUnlimited() {
        XCTAssertEqual(LoudnessMeter.gainDB(lufs: -6, peakDB: -0.1), -10, accuracy: 0.001)
    }
}
