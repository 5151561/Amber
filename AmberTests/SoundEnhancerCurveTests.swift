import XCTest
@testable import Amber

/// 声音增强器：滑杆映射、三节滤波器的幅度、以及末级软限幅。
final class SoundEnhancerCurveTests: XCTestCase {

    func testOffAndZeroAreFlat() {
        XCTAssertEqual(SoundEnhancerCurve.gains(level: -1), .flat, "开关关着")
        XCTAssertEqual(SoundEnhancerCurve.gains(level: 0), .flat, "滑到最左")
    }

    /// 满档就是文档里那一套：低架 +6 @100 Hz、高架 +7.5 @4 kHz、
    /// 临场感 +2.5 @2.5 kHz、前级 −2、侧信号 ×1.7。
    func testFullScale() {
        let g = SoundEnhancerCurve.gains(level: 255)
        XCTAssertEqual(g.lowDB, 6, accuracy: 0.001)
        XCTAssertEqual(g.highDB, 7.5, accuracy: 0.001)
        XCTAssertEqual(g.presenceDB, 2.5, accuracy: 0.001)
        XCTAssertEqual(g.preampDB, -2, accuracy: 0.001)
        XCTAssertEqual(g.sideGain, 1.7, accuracy: 0.001)
    }

    /// 量程线性：AX 里滑杆本身就是 0–255 的线性量程，没有非线性的证据。
    func testMidpointIsHalf() {
        let g = SoundEnhancerCurve.gains(level: 127)
        let t = 127.0 / 255
        XCTAssertEqual(g.lowDB, 6 * t, accuracy: 0.001)
        XCTAssertEqual(g.highDB, 7.5 * t, accuracy: 0.001)
        XCTAssertEqual(g.presenceDB, 2.5 * t, accuracy: 0.001)
        XCTAssertEqual(g.sideGain, 1 + 0.7 * t, accuracy: 0.001)
    }

    /// 滑杆推上去，每一条都只增不减（前级只减不增），中间不许有拐点。
    func testMonotonic() {
        var previous = SoundEnhancerCurve.gains(level: 0)
        for level in stride(from: Int32(1), through: 255, by: 1) {
            let g = SoundEnhancerCurve.gains(level: level)
            XCTAssertGreaterThan(g.lowDB, previous.lowDB, "档位 \(level) 的低架")
            XCTAssertGreaterThan(g.highDB, previous.highDB, "档位 \(level) 的高架")
            XCTAssertGreaterThan(g.presenceDB, previous.presenceDB, "档位 \(level) 的临场感")
            XCTAssertLessThan(g.preampDB, previous.preampDB, "档位 \(level) 的前级")
            XCTAssertGreaterThan(g.sideGain, previous.sideGain, "档位 \(level) 的展宽")
            previous = g
        }
        XCTAssertEqual(SoundEnhancerCurve.gains(level: 300), SoundEnhancerCurve.gains(level: 255),
                       "超出量程按满档夹住")
    }

    /// 满档时高架 + 前级的净抬升仍落在音量平衡的 +6 dB 限幅之内；
    /// 再往上叠的那部分交给末级软限幅接住（`testSoftClipCeiling`）。
    func testWorstCaseBoostStaysUnderSoundCheckCap() {
        let g = SoundEnhancerCurve.gains(level: 255)
        XCTAssertLessThanOrEqual(g.highDB + g.preampDB, LoudnessMeter.maxBoostDB)
    }

    /// 低架：直流处正好是设定的架高量，奈奎斯特处回到 0 dB。
    func testLowShelfEnds() {
        let fs: Double = 48_000
        let c = Biquad.lowShelf(frequency: SoundEnhancerCurve.lowFrequency,
                                sampleRate: fs, gainDB: 6)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: 0, sampleRate: fs), 6, accuracy: 0.05)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: fs / 2, sampleRate: fs), 0, accuracy: 0.05)
    }

    /// 高架：奈奎斯特处是架高量，直流处回到 0 dB。
    func testHighShelfEnds() {
        let fs: Double = 48_000
        let c = Biquad.highShelf(frequency: SoundEnhancerCurve.highFrequency,
                                 sampleRate: fs, gainDB: 7.5)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: fs / 2, sampleRate: fs), 7.5, accuracy: 0.05)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: 0, sampleRate: fs), 0, accuracy: 0.05)
    }

    /// 转折频率上是架高量的一半（架滤波器的定义）。
    func testShelfCornerIsHalfGain() {
        let fs: Double = 48_000
        let c = Biquad.highShelf(frequency: SoundEnhancerCurve.highFrequency,
                                 sampleRate: fs, gainDB: 6)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: SoundEnhancerCurve.highFrequency,
                                          sampleRate: fs), 3, accuracy: 0.2)
    }

    /// 临场感峰值：中心频率上就是设定的增益，两端（直流 / 奈奎斯特）回到 0。
    func testPeakingCenterAndEnds() {
        let fs: Double = 48_000
        let f = SoundEnhancerCurve.presenceFrequency
        let c = Biquad.peaking(frequency: f, sampleRate: fs, gainDB: 2.5,
                               q: SoundEnhancerCurve.presenceQ)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: f, sampleRate: fs), 2.5, accuracy: 0.02)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: 0, sampleRate: fs), 0, accuracy: 0.05)
        XCTAssertEqual(Biquad.magnitudeDB(c, frequency: fs / 2, sampleRate: fs), 0, accuracy: 0.05)
        // 离中心两个八度以外基本听不出来（Q ≈ 1 就是这个宽度）。
        XCTAssertLessThan(Biquad.magnitudeDB(c, frequency: f / 4, sampleRate: fs), 0.3)
        XCTAssertLessThan(Biquad.magnitudeDB(c, frequency: f * 4, sampleRate: fs), 0.3)
    }

    func testZeroGainIsIdentity() {
        XCTAssertEqual(Biquad.lowShelf(frequency: 100, sampleRate: 48_000, gainDB: 0), .identity)
        XCTAssertEqual(Biquad.peaking(frequency: 2500, sampleRate: 48_000, gainDB: 0, q: 1),
                       .identity)
    }

    /// 软限幅：0.8 以下原样通过，一点非线性都不引入。
    func testSoftClipIsIdentityBelowThreshold() {
        for x in stride(from: Float(-0.8), through: 0.8, by: 0.05) {
            XCTAssertEqual(SoundEnhancerCurve.softClip(x), x, accuracy: 1e-6)
        }
    }

    /// 单调、奇对称，且无论推多大都不过 1.0。
    func testSoftClipMonotonicAndCapped() {
        var previous = SoundEnhancerCurve.softClip(-4)
        for i in stride(from: Float(-4), through: 4, by: 0.01) {
            let y = SoundEnhancerCurve.softClip(i)
            XCTAssertGreaterThanOrEqual(y, previous, "在 \(i) 处不单调")
            XCTAssertLessThanOrEqual(abs(y), 1.0, "在 \(i) 处过了满刻度")
            previous = y
        }
        XCTAssertEqual(SoundEnhancerCurve.softClip(-1.5), -SoundEnhancerCurve.softClip(1.5),
                       accuracy: 1e-6)
    }

    func testSoftClipCeiling() {
        XCTAssertEqual(SoundEnhancerCurve.softClip(1.0), 0.8 + 0.2 * tanhf(1), accuracy: 1e-6)
        XCTAssertLessThanOrEqual(SoundEnhancerCurve.softClip(100), 1.0)
        XCTAssertGreaterThan(SoundEnhancerCurve.softClip(100), 0.99)
    }
}
