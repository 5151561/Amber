import AVFoundation
import Foundation

// 「导入设置」那两个选择器（`importEncoder` / `importPreset`）落成的**转码规格**，
// 以及把一个文件按这份规格写出来的那段 AVFoundation。
//
// 规格与转码分开：规格是纯函数（编码器 × 预置 × 源格式 → 目标参数），可以单测；
// 转码那段要真读文件，只在导入流程里跑。
//
// 目标参数一律取自 `ImportEncoder.detail(preset:)` 里那几行规格文字
// （AAC × iTunes Plus 那格是 [AX] 实测，其余是照 iTunes 老规格补的 `[推]`）——
// 界面上写着多少码率，导出来就是多少，不另立一套数。

// MARK: - 源格式

/// 待导入文件的音频规格。`formatID` 读自音轨的 format description；读不出来就只剩扩展名。
struct ImportSourceFormat: Equatable, Sendable {
    var formatID: AudioFormatID?
    var sampleRate: Double
    var channels: Int
    /// 小写、不带点（"mp3" / "m4a" / "aiff"）
    var fileExtension: String

    static let unknown = ImportSourceFormat(formatID: nil, sampleRate: 44_100, channels: 2,
                                            fileExtension: "")
}

// MARK: - 转码与否

/// 一个文件该怎么落地。
enum ImportPlan: Equatable, Sendable {
    /// 源已经就是所选编码器的格式，原样落地（Music 导入一首已经是 AAC 的 m4a 也不会重转）
    case copyOriginal
    /// 转成这个编码器。`mp3Fallback` ＝ 用户选的是 MP3、但源不是 MP3，
    /// **Apple 没有 MP3 编码器**（AudioToolbox 只给解码器），只能回落 AAC 并提示一次。
    case transcode(ImportEncoder, mp3Fallback: Bool)

    var mp3Fallback: Bool {
        if case .transcode(_, let fallback) = self { return fallback }
        return false
    }
}

extension ImportPlan {

    /// 源格式 + 所选编码器 → 落地方式。
    ///
    /// 判「已经一致」优先看 `formatID`（m4a 里既可能是 AAC 也可能是 ALAC，只看扩展名会判错），
    /// 读不出 formatID 时才回落到扩展名。
    static func decide(source: ImportSourceFormat, encoder: ImportEncoder) -> ImportPlan {
        if matches(source: source, encoder: encoder) { return .copyOriginal }
        guard encoder != .mp3 else { return .transcode(.aac, mp3Fallback: true) }
        return .transcode(encoder, mp3Fallback: false)
    }

    private static func matches(source: ImportSourceFormat, encoder: ImportEncoder) -> Bool {
        if let id = source.formatID {
            switch encoder {
            case .aac: return id == kAudioFormatMPEG4AAC
            case .appleLossless: return id == kAudioFormatAppleLossless
            case .mp3: return id == kAudioFormatMPEGLayer3
            // PCM 还要容器对得上：wav 里的 PCM 选了 AIFF 编码器仍然要换容器。
            case .aiff: return id == kAudioFormatLinearPCM && source.fileExtension.hasPrefix("aif")
            case .wav: return id == kAudioFormatLinearPCM && source.fileExtension == "wav"
            }
        }
        switch encoder {
        case .aac: return ["m4a", "aac", "mp4", "m4b"].contains(source.fileExtension)
        case .appleLossless: return source.fileExtension == "m4a"
        case .mp3: return source.fileExtension == "mp3"
        case .aiff: return source.fileExtension.hasPrefix("aif")
        case .wav: return source.fileExtension == "wav"
        }
    }
}

// MARK: - 目标规格

/// 转码目标：容器 + 音频设置。
struct ImportOutputSpec: Equatable, Sendable {
    var fileType: AVFileType
    /// 落地文件的扩展名
    var fileExtension: String
    var formatID: AudioFormatID
    var sampleRate: Double
    var channels: Int
    /// 有损档的目标码率；无损/PCM 为 nil
    var bitRate: Int?
    /// PCM 位深 / ALAC 的位深提示
    var bitDepth: Int?
    /// AIFF 是大端 PCM，WAV 是小端。
    var bigEndian: Bool

    /// 编码器 × 预置 × 源格式 → 目标规格。
    ///
    /// - AAC：采样率一律 44.1 kHz（三个预置的规格文字都是这么写的）；
    ///   iTunes Plus 保留源的声道数，单声道 128k / 立体声 256k（[AX] 那格原话）；
    ///   高质量固定 128k；口述播客固定单声道 64k。
    /// - Apple 保真压缩：与源逐比特一致，所以采样率与声道跟着源走
    ///   （多声道并到立体声：ALAC 写 >2 声道还要给 `AVChannelLayoutKey`，
    ///   Amber 的导入源都是双声道，为这一档挂一整套声道布局不值当 `[推]`）。
    /// - AIFF / WAV：16 位 / 44.1 kHz 立体声（规格文字写的「自动」那一行）。
    static func make(encoder: ImportEncoder, preset: ImportPreset,
                     source: ImportSourceFormat) -> ImportOutputSpec {
        let sourceChannels = min(max(source.channels, 1), 2)
        switch encoder {
        case .aac, .mp3:
            // MP3 到不了这里（`ImportPlan.decide` 已经把它回落成 .aac），
            // 写在同一格只是为了不留一个 fatalError。
            let channels: Int
            let bitRate: Int
            switch preset {
            case .highQuality:
                channels = sourceChannels
                bitRate = 128_000
            case .iTunesPlus, .custom:
                channels = sourceChannels
                bitRate = channels == 1 ? 128_000 : 256_000
            case .spokenPodcast:
                channels = 1
                bitRate = 64_000
            }
            return ImportOutputSpec(fileType: .m4a, fileExtension: "m4a",
                                    formatID: kAudioFormatMPEG4AAC,
                                    sampleRate: 44_100, channels: channels,
                                    bitRate: bitRate, bitDepth: nil, bigEndian: false)
        case .appleLossless:
            return ImportOutputSpec(fileType: .m4a, fileExtension: "m4a",
                                    formatID: kAudioFormatAppleLossless,
                                    sampleRate: source.sampleRate, channels: sourceChannels,
                                    bitRate: nil, bitDepth: 16, bigEndian: false)
        case .aiff:
            return ImportOutputSpec(fileType: .aiff, fileExtension: "aiff",
                                    formatID: kAudioFormatLinearPCM,
                                    sampleRate: 44_100, channels: 2,
                                    bitRate: nil, bitDepth: 16, bigEndian: true)
        case .wav:
            return ImportOutputSpec(fileType: .wav, fileExtension: "wav",
                                    formatID: kAudioFormatLinearPCM,
                                    sampleRate: 44_100, channels: 2,
                                    bitRate: nil, bitDepth: 16, bigEndian: false)
        }
    }

    /// 交给 `AVAssetWriterInput` 的输出设置。
    var writerSettings: [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
        if formatID == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = bitDepth ?? 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = bigEndian
            settings[AVLinearPCMIsNonInterleaved] = false
        } else if let bitDepth, formatID == kAudioFormatAppleLossless {
            settings[AVEncoderBitDepthHintKey] = bitDepth
        }
        return settings
    }

    /// 交给 `AVAssetReaderAudioMixOutput` 的解码设置：一律解成小端 16 位 PCM，
    /// 采样率与声道数在**读那一侧**就折算好（音频混合输出自带 SRC 与并轨），
    /// 写那一侧就只剩编码这一件事。
    var readerSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

// MARK: - 转码

enum ImportError: LocalizedError {
    case noAudioTrack
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "文件里没有音轨"
        case .readFailed(let message): return "读取失败：\(message)"
        case .writeFailed(let message): return "写入失败：\(message)"
        }
    }
}

// MARK: - 写给产物的标签

/// 转码产物要带的标签。
///
/// 源文件的标签**不会**自己跟过来：`AVAssetReader` 只搬采样，`AVAssetWriter` 不写
/// `metadata` 就只有一条`iTunSMPB`（编码器自己加的间隙信息）。于是导进来的歌在
/// 访达、Music、任何别的播放器里都是「无标题 / 未知艺人 / 没有封面」——Amber 自己的资料库
/// 看着是对的，因为那份信息记在 `library.json` 里，文件本身是空的。
enum ImportMetadata {

    /// 按 iTunes keyspace 造一组 `AVMetadataItem`（m4a 容器认这一套：
    /// `©nam` / `©ART` / `©alb` / `trkn` / `disk` / `covr`）。
    ///
    /// AIFF / WAV 不在此列：那两种容器 `AVAssetWriter` 不写标签块，塞进去只会让
    /// `startWriting` 失败，所以由调用方按`fileType` 决定要不要带（见`items(for:...)`）。
    static func items(title: String, artist: String, album: String,
                      trackNumber: Int?, discNumber: Int?, artwork: Data?) -> [AVMetadataItem] {
        var result: [AVMetadataItem] = []
        func append(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?,
                    dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.dataType = dataType
            item.extendedLanguageTag = "und"
            result.append(item)
        }
        append(.iTunesMetadataSongName, title.isEmpty ? nil : title as NSString)
        append(.iTunesMetadataArtist, artist.isEmpty ? nil : artist as NSString)
        append(.iTunesMetadataAlbumArtist, artist.isEmpty ? nil : artist as NSString)
        append(.iTunesMetadataAlbum, album.isEmpty ? nil : album as NSString)
        if let trackNumber, trackNumber > 0 {
            append(.iTunesMetadataTrackNumber, numberBox(trackNumber) as NSData)
        }
        if let discNumber, discNumber > 0 {
            append(.iTunesMetadataDiscNumber, numberBox(discNumber) as NSData)
        }
        if let artwork, !artwork.isEmpty {
            let isPNG = artwork.starts(with: [0x89, 0x50, 0x4E, 0x47])
            append(.iTunesMetadataCoverArt, artwork as NSData,
                   dataType: isPNG ? kCMMetadataBaseDataType_PNG as String
                                   : kCMMetadataBaseDataType_JPEG as String)
        }
        return result
    }

    /// 这个容器能不能带标签。m4a（AAC / ALAC）能，AIFF / WAV 不能。
    static func items(for fileType: AVFileType, title: String, artist: String, album: String,
                      trackNumber: Int?, discNumber: Int?, artwork: Data?) -> [AVMetadataItem] {
        guard fileType == .m4a || fileType == .mp4 else { return [] }
        return items(title: title, artist: artist, album: album, trackNumber: trackNumber,
                     discNumber: discNumber, artwork: artwork)
    }

    /// `trkn` / `disk` 那 8 个字节：`00 00 <序号 BE16> <总数 BE16> 00 00`。
    /// 读那一侧就是按这个结构拆的（`ImportWorker.number(fromData:)`）。
    static func numberBox(_ value: Int) -> Data {
        let clamped = UInt16(min(max(value, 0), Int(UInt16.max)))
        return Data([0, 0, UInt8(clamped >> 8), UInt8(clamped & 0xFF), 0, 0, 0, 0])
    }
}

enum ImportTranscoder {

    /// 按 `spec` 把`asset` 重新编码到`destination`。
    ///
    /// 用 `AVAssetReader` + `AVAssetWriter` 而不是`AVAssetExportSession`：
    /// 导出会话只有一组预置（`AVAssetExportPresetAppleM4A` 固定 AAC 256k），
    /// 「导入设置」里的码率／声道／PCM 位深它一个都调不了。
    ///
    /// `attempts` 来自设置 › 文件 › 导入设置 ›「读取音乐光盘时使用纠错功能」：
    /// 光盘纠错没有公开 API（cddafs 把音轨挂成普通 AIFF 文件，读它的就是文件系统），
    /// 能做的只有**读失败时重来几遍**——划伤的碟重读一次常常就过去了。
    static func export(url: URL, to destination: URL, spec: ImportOutputSpec,
                       metadata: [AVMetadataItem] = [], attempts: Int = 1) async throws {
        var lastError: any Error = ImportError.readFailed("未知原因")
        for attempt in 0..<max(attempts, 1) {
            do {
                try await exportOnce(url: url, to: destination, spec: spec, metadata: metadata)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destination)
                // 最后一次失败就不必再等了
                if attempt + 1 < max(attempts, 1) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        throw lastError
    }

    private static func exportOnce(url: URL, to destination: URL, spec: ImportOutputSpec,
                                   metadata: [AVMetadataItem] = []) async throws {
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [sourceTrack],
                                                 audioSettings: spec.readerSettings)
        guard reader.canAdd(output) else { throw ImportError.readFailed("解码设置不被支持") }
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: destination, fileType: spec.fileType)
        // 标签必须在 `startWriting` 之前挂上，之后再改就写不进容器了。
        if !metadata.isEmpty { writer.metadata = metadata }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: spec.writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ImportError.writeFailed("编码设置不被支持") }
        writer.add(input)

        guard reader.startReading() else {
            throw ImportError.readFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }
        guard writer.startWriting() else {
            throw ImportError.writeFailed(writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: .zero)

        // 从这一行起，这四个对象加 `finished` 只属于 `session`，只在下面那条队列上被碰。
        let session = TranscodeSession(reader: reader, output: output, writer: writer, input: input)
        let queue = DispatchQueue(label: "Amber.ImportTranscoder")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.input.requestMediaDataWhenReady(on: queue) {
                guard !session.finished else { return }
                while session.input.isReadyForMoreMediaData {
                    guard let buffer = session.output.copyNextSampleBuffer() else {
                        session.finished = true
                        session.input.markAsFinished()
                        if session.reader.status == .failed {
                            session.writer.cancelWriting()
                            continuation.resume(throwing: ImportError.readFailed(
                                session.reader.error?.localizedDescription ?? "读取中断"))
                            return
                        }
                        session.writer.finishWriting {
                            if session.writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ImportError.writeFailed(
                                    session.writer.error?.localizedDescription ?? "写入中断"))
                            }
                        }
                        return
                    }
                    if !session.input.append(buffer) {
                        session.finished = true
                        session.reader.cancelReading()
                        session.writer.cancelWriting()
                        continuation.resume(throwing: ImportError.writeFailed(
                            session.writer.error?.localizedDescription ?? "无法写入采样"))
                        return
                    }
                }
            }
        }
    }
}

/// 一次转码用到的四个 AVFoundation 句柄，加一个「收线了没有」的标记。
///
/// **为什么要这个外壳**（`AGENTS.md`「语言与安全开关」第二档的判据：同一个不安全声明
/// 用 ≥3 次）：这五样都要被 `requestMediaDataWhenReady` 的 `@Sendable` 块捕获，
/// 可它们一个都不是 `Sendable`。从前的写法是五个 `nonisolated(unsafe)` 局部声明，
/// 代价是开了 strict memory safety（SE-0458）之后**每一次使用**都要写 `unsafe`——
/// `exportOnce` 一个函数里 26 处，说的全是同一句话。
///
/// 当时的结论是「这里没有 `@safe` 外壳可做：外壳只能包声明，包不了局部变量」。
/// 那句只对了一半——包不了局部变量，但**可以把这五个局部变量收成一个类型**，
/// 于是契约从「抄 26 遍」变成「写在这里一遍」，`exportOnce` 里 `unsafe` 归零。
///
/// **契约**：这四个对象（连同 `finished`）从递给 `requestMediaDataWhenReady` 那一刻起
/// **只在传给它的那条自建串行队列上被碰**，直到 continuation 收线。队列是串行的，
/// 所以 `finished` 也不需要另加锁。改这段时唯一该盯的就是有没有人违反这一条——
/// 比如在块外再摸一次 `reader`，或者把 `input` 递给另一条队列。
///
/// `@unchecked Sendable` 担保的就是上面这一条；`@safe` 是不让这句担保泄漏到使用点去
///（同 `Player/AudioTap.swift` 的 `TapShared`：自己持有不安全的东西、自己管住，
/// 对外只是安全 API）。
@safe
private final class TranscodeSession: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderAudioMixOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    /// 收线了没有。只在那条串行队列上读写。
    var finished = false

    init(reader: AVAssetReader, output: AVAssetReaderAudioMixOutput,
         writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }
}

