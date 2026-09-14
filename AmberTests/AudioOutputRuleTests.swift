import AVFoundation
import CoreAudio
import XCTest
@testable import Amber

/// 输出设备 → 要不要走沉浸声。纯规则，不碰真设备。
final class AudioOutputRuleTests: XCTestCase {

    func testBuiltInAndBluetoothPreferAtmos() {
        XCTAssertTrue(AudioOutputRules.prefersAtmos(transport: AudioOutputRules.builtIn,
                                                    channelCount: 2))
        XCTAssertTrue(AudioOutputRules.prefersAtmos(transport: AudioOutputRules.bluetooth,
                                                    channelCount: 2))
    }

    /// USB 耳机（双声道）要，USB 多声道接口不要——后面接的是什么无从知道。
    func testUSBDependsOnChannelCount() {
        XCTAssertTrue(AudioOutputRules.prefersAtmos(transport: AudioOutputRules.usb,
                                                    channelCount: 2))
        XCTAssertFalse(AudioOutputRules.prefersAtmos(transport: AudioOutputRules.usb,
                                                     channelCount: 8))
    }

    /// HDMI / DisplayPort / 雷雳 / 聚合 / 虚拟 / AirPlay 一律走无损，不取沉浸声。
    func testWiredAndVirtualOutputsDoNotPreferAtmos() {
        for transport in [AudioOutputRules.hdmi, AudioOutputRules.displayPort,
                          AudioOutputRules.thunderbolt, AudioOutputRules.aggregate,
                          AudioOutputRules.virtual, AudioOutputRules.airPlay, 0] {
            XCTAssertFalse(AudioOutputRules.prefersAtmos(transport: transport, channelCount: 2),
                           "transport \(transport)")
        }
    }

    func testSpatializationFormats() {
        XCTAssertEqual(AudioOutputRules.spatializationFormats(for: .off), [])
        XCTAssertEqual(AudioOutputRules.spatializationFormats(for: .automatic), .multichannel)
        XCTAssertEqual(AudioOutputRules.spatializationFormats(for: .alwaysOn),
                       .monoStereoAndMultichannel)
    }

    /// 「自动」按输出设备折算；「始终打开」「关闭」是用户的明确表态，设备说什么都不改。
    func testDolbyAtmosResolvedAgainstOutput() {
        var atmosOutput = AudioOutput()
        atmosOutput.transport = AudioOutputRules.builtIn
        var wiredOutput = AudioOutput()
        wiredOutput.transport = AudioOutputRules.hdmi
        XCTAssertTrue(atmosOutput.prefersAtmos)
        XCTAssertFalse(wiredOutput.prefersAtmos)

        XCTAssertEqual(DolbyAtmosMode.automatic.resolved(for: atmosOutput), .alwaysOn)
        XCTAssertEqual(DolbyAtmosMode.automatic.resolved(for: wiredOutput), .off)
        XCTAssertEqual(DolbyAtmosMode.alwaysOn.resolved(for: atmosOutput), .alwaysOn)
        XCTAssertEqual(DolbyAtmosMode.alwaysOn.resolved(for: wiredOutput), .alwaysOn)
        XCTAssertEqual(DolbyAtmosMode.off.resolved(for: atmosOutput), .off)
        XCTAssertEqual(DolbyAtmosMode.off.resolved(for: wiredOutput), .off)
    }

    /// 折算之后再喂 `StreamQuality.clamped`：接 HDMI 时「自动」就该把沉浸声那一档让开。
    func testResolvedAutomaticDropsSpatialTierOnWiredOutput() {
        var wiredOutput = AudioOutput()
        wiredOutput.transport = AudioOutputRules.hdmi
        let resolved = DolbyAtmosMode.automatic.resolved(for: wiredOutput)
        XCTAssertEqual(StreamQuality.atmos.clamped(losslessEnabled: true, dolbyAtmos: resolved),
                       .surround)
    }

    func testOutputStructUsesTheRule() {
        var output = AudioOutput()
        output.transport = AudioOutputRules.hdmi
        XCTAssertFalse(output.prefersAtmos)
        output.transport = AudioOutputRules.builtIn
        XCTAssertTrue(output.prefersAtmos)
    }
}
