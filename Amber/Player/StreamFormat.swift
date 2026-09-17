import AVFoundation

/// 当前这一路音频流的真实规格，取自 `AVAssetTrack` 的格式描述，不是设置里选的档位。
///
/// 迷你播放器上的波形键点开就是它（对齐 Music.app 的音质气泡：一行「无损」、
/// 一行「44.1 kHz ALAC」）。设置里选的是「想要哪一档」，而这里报的是**实际拿到的**——
/// 阶梯会降级（选了臻品母带、这首只有 FLAC），两者常常对不上，气泡必须说实话。
struct StreamFormat: Equatable, Sendable {
    /// kAudioFormatID，四字符码（'flac' / '.mp3' / 'aac ' / 'ec-3' …）
    let formatID: AudioFormatID
    /// 采样率，Hz。压缩格式也有，0 表示未知
    let sampleRate: Double
    /// 源位深。压缩格式通常报 0
    let bitDepth: Int
    let channels: Int
    /// 平均码率，bit/s。无损档没有意义（随内容浮动），只给有损档用
    let dataRate: Double

    init(formatID: AudioFormatID, sampleRate: Double, bitDepth: Int, channels: Int, dataRate: Double) {
        self.formatID = formatID
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.dataRate = dataRate
    }

    /// 无损：解出来和源文件逐比特一致的那几种
    var isLossless: Bool {
        switch formatID {
        case kAudioFormatFLAC, kAudioFormatAppleLossless,
             kAudioFormatLinearPCM: return true
        default: return false
        }
    }

    /// 沉浸声：杜比的两种（AC-3 / E-AC-3，臻品全景声那档取回来的是 E-AC-3 JOC）
    var isSpatial: Bool {
        formatID == kAudioFormatAC3 || formatID == kAudioFormatEnhancedAC3
    }

    /// 气泡第一行。Music.app 用的就是这套词：无损 / 高解析度无损 / 杜比全景声 / 高音质
    var tierName: String {
        if isSpatial { return "杜比全景声" }
        guard isLossless else { return "高音质" }
        // Music 的分界线：超过 CD 规格（48 kHz / 16 位）才叫高解析度
        return sampleRate > 48_000 || bitDepth > 16 ? "高解析度无损" : "无损"
    }

    /// 气泡第二行：「44.1 kHz FLAC」。无损补位深，有损补码率，多声道补声道数。
    var detail: String {
        var parts: [String] = []
        if sampleRate > 0 { parts.append(Self.kHzText(sampleRate)) }
        if isLossless, bitDepth > 0 { parts.append("\(bitDepth) 位") }
        if !isLossless, dataRate > 0 { parts.append("\(Int((dataRate / 1000).rounded())) kbps") }
        parts.append(Self.codecName(formatID))
        if channels > 2 { parts.append("\(channels) 声道") }
        return parts.joined(separator: " ")
    }

    /// 44100 → "44.1 kHz"，48000 → "48 kHz"
    ///
    /// `String(format:)` 走 `CVarArg`，是不安全的；`RemoteDMAP.hexValue` 那条
    /// `%02X` 能换成 `String(_:radix:)`，**这条换不掉**，差分跑过：`%.1f` 舍入的是
    /// 这个 `Double` 的**二进制精确值**，而 `Decimal`/`FormatStyle` 舍入的是它的
    /// 最短十进制表示，两者在半分点上分家。最扎眼的是 22050 Hz——22.05 的双精度值是
    /// 22.0500000000000007…，`%.1f` 进位成 22.1，`.number.precision(.fractionLength(1))`
    /// 无论配哪种 `rounded(rule:)` 都给 22.0。整数 Hz 侧的「四舍五入」同样对不上：
    /// 半分点朝哪边进完全由二进制表示决定（50 Hz 进、150 Hz 退、450 Hz 进…），
    /// 没有规律可抓，只能逐值拟合——那不是等价替换。
    /// 1…400000 Hz 全扫 + 15 个真实采样率，三种候选写法分别错 1603/2000/1603 条。
    ///
    /// 所以走共用的 `fixed(_:)` 外壳（`Models.swift` 的「数字成串」一节）：里面仍是
    /// `String(format:)`，但格式串与实参在那一行里锁死，不安全点收在外壳内部，
    /// 调用点这里回到普通 Swift。
    private static func kHzText(_ rate: Double) -> String {
        let kHz = rate / 1000
        let text = kHz == kHz.rounded() ? String(Int(kHz)) : kHz.fixed(1)
        return "\(text) kHz"
    }

    /// 四字符码转成人看的编码名。表外的格式直接把码原样显示，不猜。
    static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEGLayer1: return "MP1"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_Spatial:
            return "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3, kAudioFormatEnhancedAC3: return "Dolby"
        default: return fourCC(id)
        }
    }

    private static func fourCC(_ id: AudioFormatID) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((id >> UInt32($0)) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "未知格式" : text
    }
}

extension StreamFormat {
    /// 从播放中的 item 读真实规格。asset 的音轨要异步加载，所以整个是 async 的。
    /// 拿不到音轨（还没就绪、或者取流失败）时返回 nil，气泡就显示「读取中」。
    ///
    /// `@MainActor` 不是为了这段代码，是因为 `AVPlayerItem.asset` 在 SDK 里就是主 actor 的。
    /// 两个调用点（`PlayerController.readStreamFormat`、`DownloadStore.readFormat`）本来
    /// 就在主 actor 上，标上只是把既有事实写明。
    @MainActor
    static func read(from item: AVPlayerItem) async -> StreamFormat? {
        await read(from: item.asset)
    }

    /// 从磁盘上的一份文件读真实规格（「显示简介 › 文件」页的种类 / 位速率 /
    /// 采样速率 / 声道走这条）。**解析要花时间，调用方必须在主线程之外 await。**
    static func read(from url: URL) async -> StreamFormat? {
        await read(from: AVURLAsset(url: url))
    }

    static func read(from asset: AVAsset) async -> StreamFormat? {
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await audio.load(.formatDescriptions).first,
              let asbd = description.audioStreamBasicDescription
        else { return nil }
        let dataRate = (try? await audio.load(.estimatedDataRate)).map(Double.init) ?? 0
        return StreamFormat(formatID: asbd.mFormatID,
                            sampleRate: asbd.mSampleRate,
                            bitDepth: sourceBitDepth(asbd),
                            channels: Int(asbd.mChannelsPerFrame),
                            dataRate: dataRate)
    }

    /// FLAC / ALAC 的 ASBD 把源位深放在 `mFormatFlags` 里，`mBitsPerChannel` 是 0
    /// （CoreAudioTypes 的 `kAppleLosslessFormatFlag_*SourceData` 两种格式共用）。
    static func sourceBitDepth(_ asbd: AudioStreamBasicDescription) -> Int {
        if asbd.mBitsPerChannel > 0 { return Int(asbd.mBitsPerChannel) }
        guard asbd.mFormatID == kAudioFormatFLAC
                || asbd.mFormatID == kAudioFormatAppleLossless else { return 0 }
        switch asbd.mFormatFlags {
        case UInt32(kAppleLosslessFormatFlag_16BitSourceData): return 16
        case UInt32(kAppleLosslessFormatFlag_20BitSourceData): return 20
        case UInt32(kAppleLosslessFormatFlag_24BitSourceData): return 24
        case UInt32(kAppleLosslessFormatFlag_32BitSourceData): return 32
        default: return 0
        }
    }
}
