import AVFoundation
import XCTest
@testable import Amber

/// 音质气泡显示的是**实际拿到的**规格，不是设置里选的档位。这里锁住从 ASBD
/// 到那两行字的换算：FLAC/ALAC 的位深藏在 mFormatFlags 里、无损与有损补的字段不同、
/// 采样率整数不带小数点。
final class StreamFormatTests: XCTestCase {

    private func format(_ id: AudioFormatID, rate: Double = 44_100, bits: Int = 16,
                        channels: Int = 2, dataRate: Double = 0) -> StreamFormat {
        StreamFormat(formatID: id, sampleRate: rate, bitDepth: bits,
                     channels: channels, dataRate: dataRate)
    }

    func testLosslessTierNames() {
        XCTAssertEqual(format(kAudioFormatFLAC).tierName, "无损")
        XCTAssertEqual(format(kAudioFormatAppleLossless).tierName, "无损")
        // 超过 CD 规格才叫高解析度，两个条件各自都够
        XCTAssertEqual(format(kAudioFormatFLAC, rate: 192_000, bits: 24).tierName, "高解析度无损")
        XCTAssertEqual(format(kAudioFormatFLAC, rate: 44_100, bits: 24).tierName, "高解析度无损")
        XCTAssertEqual(format(kAudioFormatFLAC, rate: 48_000, bits: 16).tierName, "无损")
    }

    func testLossyAndSpatialTierNames() {
        XCTAssertEqual(format(kAudioFormatMPEGLayer3, bits: 0).tierName, "高音质")
        XCTAssertEqual(format(kAudioFormatMPEG4AAC, bits: 0).tierName, "高音质")
        // 杜比全景声档取回来的是 E-AC-3 JOC，别被「位深 0、采样率 48k」判成有损文案
        XCTAssertEqual(format(kAudioFormatEnhancedAC3, rate: 48_000, bits: 0, channels: 6).tierName,
                       "杜比全景声")
    }

    func testDetailLine() {
        XCTAssertEqual(format(kAudioFormatFLAC).detail, "44.1 kHz 16 位 FLAC")
        // 整数千赫兹不留 ".0"
        XCTAssertEqual(format(kAudioFormatFLAC, rate: 192_000, bits: 24).detail,
                       "192 kHz 24 位 FLAC")
        // 有损档报码率而不是位深——位深对压缩流没有意义
        XCTAssertEqual(format(kAudioFormatMPEGLayer3, bits: 0, dataRate: 320_000).detail,
                       "44.1 kHz 320 kbps MP3")
        // 多声道才补声道数
        XCTAssertEqual(format(kAudioFormatEnhancedAC3, rate: 48_000, bits: 0,
                              channels: 6, dataRate: 768_000).detail,
                       "48 kHz 768 kbps Dolby 6 声道")
    }

    func testUnknownCodecFallsBackToTheFourCharacterCode() {
        // 表里没有的格式原样显示四字符码，不猜也不说谎
        let mpegH = AudioFormatID(0x6D686D31) // 'mhm1'
        XCTAssertEqual(StreamFormat.codecName(mpegH), "mhm1")
    }

    func testSourceBitDepthComesFromFormatFlagsWhenBitsPerChannelIsZero() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatFLAC
        asbd.mBitsPerChannel = 0
        asbd.mFormatFlags = UInt32(kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(StreamFormat.sourceBitDepth(asbd), 24)

        asbd.mFormatFlags = UInt32(kAppleLosslessFormatFlag_16BitSourceData)
        XCTAssertEqual(StreamFormat.sourceBitDepth(asbd), 16)

        // 压缩格式没有源位深，也没有这套标志位，别把 mFormatFlags 当位深读
        asbd.mFormatID = kAudioFormatMPEG4AAC
        asbd.mFormatFlags = 2
        XCTAssertEqual(StreamFormat.sourceBitDepth(asbd), 0)

        // mBitsPerChannel 有值时以它为准
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 32
        XCTAssertEqual(StreamFormat.sourceBitDepth(asbd), 32)
    }
}
