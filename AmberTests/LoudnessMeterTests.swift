import XCTest
@testable import Amber

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
