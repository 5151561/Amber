// 校准工具：列出本机每一台音频输出设备公布的物理 / 虚拟流格式。
//
// 用法：swift Tools/audio-probe.swift [-v]
//   -v 连虚拟格式（AvailableVirtualFormats）一起打印，默认只打物理格式。
//
// 为什么要它：Amber 的「HDMI直通」这一项能不能做，取决于 CoreAudio 有没有向第三方 App
// 公布**编码格式**的物理流。Apple 的支持文档说杜比直通只对 Music / QuickTime / TV 开放，
// 公开 SDK 里也只有 `kAudioFormat60958AC3`（'cac3'，AC-3），E-AC-3 连 IEC-60958 的
// 传输格式 ID 都没有。所以先在真硬件（Mac mini / 拓展坞 + HDMI 功放）上跑一遍这个探针：
//   · 一个 'cac3' 都没有  → 无直通路径，Amber 的「首选HDMI直通」只记偏好、不改路由。
//   · 只有 'cac3'（预期） → 也只能走 AC-3；Amber 的沉浸声档是 E-AC-3 JOC，
//                          macOS 没有 E-AC-3→AC-3 编码器，音源也没有 AC-3 档，仍然无解。
//   · 出现 E-AC-3 的 IEC ID → 意外收获，值得单独立项（独占 + 位流 IOProc）。
//
// 把整份输出贴回会话里即可决定分支。

import CoreAudio
import Foundation

let verbose = CommandLine.arguments.contains("-v")

func fourCC(_ id: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((id >> UInt32($0)) & 0xFF) }
    let text = String(decoding: bytes, as: UTF8.self)
    return text.allSatisfy { $0.isASCII && !$0.isNewline } ? "'\(text)'" : String(id)
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func dataSize(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
        return nil
    }
    return size
}

func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              empty: T) -> [T] {
    guard var size = dataSize(object, selector, scope) else { return [] }
    var values = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.size)
    var addr = address(selector, scope)
    let ok = values.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) == noErr
    }
    return ok ? values : []
}

func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
               empty: T) -> T? {
    var value = empty
    var size = UInt32(MemoryLayout<T>.size)
    var addr = address(selector, scope)
    let ok = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) == noErr
    }
    return ok ? value : nil
}

func name(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = address(selector)
    let ok = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) == noErr
    }
    guard ok, let value else { return "" }
    return value.takeRetainedValue() as String
}

func describe(_ format: AudioStreamBasicDescription, _ range: AudioValueRange) -> String {
    var parts = [fourCC(format.mFormatID)]
    if format.mSampleRate > 0 {
        parts.append(String(format: "%.0f Hz", format.mSampleRate))
    } else if range.mMinimum != range.mMaximum {
        parts.append(String(format: "%.0f–%.0f Hz", range.mMinimum, range.mMaximum))
    }
    parts.append("\(format.mChannelsPerFrame) ch")
    if format.mBitsPerChannel > 0 { parts.append("\(format.mBitsPerChannel) bit") }
    parts.append(String(format: "flags 0x%02X", format.mFormatFlags))
    if format.mFramesPerPacket > 1 { parts.append("\(format.mFramesPerPacket) fpp") }
    return parts.joined(separator: "  ")
}

func formats(_ stream: AudioStreamID, _ selector: AudioObjectPropertySelector)
    -> [AudioStreamRangedDescription] {
    array(stream, selector, empty: AudioStreamRangedDescription())
}

// MARK: - 枚举

let devices: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject),
                                     kAudioHardwarePropertyDevices, empty: AudioDeviceID(0))
let defaultOutput = scalar(AudioObjectID(kAudioObjectSystemObject),
                           kAudioHardwarePropertyDefaultOutputDevice,
                           empty: AudioDeviceID(0)) ?? 0

var encodedHits: [String] = []

for device in devices {
    let streams: [AudioStreamID] = array(device, kAudioDevicePropertyStreams,
                                         kAudioDevicePropertyScopeOutput, empty: AudioStreamID(0))
    guard !streams.isEmpty else { continue }   // 只看输出设备

    let deviceName = name(device, kAudioObjectPropertyName)
    let transport = scalar(device, kAudioDevicePropertyTransportType, empty: UInt32(0)) ?? 0
    let source = scalar(device, kAudioDevicePropertyDataSource,
                        kAudioDevicePropertyScopeOutput, empty: UInt32(0))
    let hog = scalar(device, kAudioDevicePropertyHogMode,
                     kAudioDevicePropertyScopeOutput, empty: pid_t(-1)) ?? -1
    let uid = name(device, kAudioDevicePropertyDeviceUID)

    print("")
    print("=== \(deviceName)\(device == defaultOutput ? "  [默认输出]" : "")")
    print("    uid        \(uid)")
    print("    transport  \(fourCC(transport))")
    print("    dataSource \(source.map(fourCC) ?? "—")")
    print("    hog pid    \(hog)")

    for stream in streams {
        let channels = scalar(stream, kAudioStreamPropertyTerminalType, empty: UInt32(0)) ?? 0
        print("    -- stream \(stream)  terminal \(fourCC(channels))")
        for ranged in formats(stream, kAudioStreamPropertyAvailablePhysicalFormats) {
            let line = describe(ranged.mFormat, ranged.mSampleRateRange)
            print("       phys  \(line)")
            let id = ranged.mFormat.mFormatID
            // 'c' 开头的编码 ID 就是 IEC-60958 那一族（cac3 / cpcm / cpaa …）
            if (id >> 24) == UInt32(UInt8(ascii: "c")) {
                encodedHits.append("\(deviceName): \(line)")
            }
        }
        guard verbose else { continue }
        for ranged in formats(stream, kAudioStreamPropertyAvailableVirtualFormats) {
            print("       virt  \(describe(ranged.mFormat, ranged.mSampleRateRange))")
        }
    }
}

print("")
print("=== 汇总")
if encodedHits.isEmpty {
    print("    没有任何输出设备公布编码格式（'c…' 一族）。")
    print("    → 无可行的直通路径；Amber 的「首选HDMI直通」只记偏好、不改变输出方式。")
} else {
    print("    公布了编码格式的设备：")
    for hit in encodedHits { print("      \(hit)") }
    print("    → 'cac3' = AC-3 直通；Amber 的沉浸声档是 E-AC-3 JOC，仍需确认有无 E-AC-3 的 IEC ID。")
}
