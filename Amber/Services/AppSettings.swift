import Combine
import Foundation
import SwiftUI

// MARK: - popup 的取值

/// 通用页「更大字体」：歌词与发音同屏时，哪一条用更大的字号。
/// [AX] 选项实测：歌词 / 发音。
enum LargerTextTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyrics, pronunciation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyrics: return "歌词"
        case .pronunciation: return "发音"
        }
    }
}

/// 播放页「过渡效果样式」。[RES] 文案取自 Music 的 `zh_CN.lproj/Localizable.strings`
/// （UI 禁用态展不开菜单，key `a5mew7vz0v`=自动过渡、`tkq9ez3fux`=智能过渡）。
enum CrossfadeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, smart
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动过渡"
        case .smart: return "智能过渡"
        }
    }
}

/// 播放页「杜比全景声」。[AX] 自动 / 始终打开 / 关闭。
enum DolbyAtmosMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, alwaysOn, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .alwaysOn: return "始终打开"
        case .off: return "关闭"
        }
    }
}

/// 播放页「HDMI直通」。[AX] 关闭 / 首选HDMI直通。
enum HDMIPassthrough: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, preferred
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .preferred: return "首选HDMI直通"
        }
    }
}

/// 播放页「视频质量 › 流播放」。[AX] 良好 / 较佳（最高1080p） / 最佳（最高4K）。
enum VideoStreamQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case good, better, best
    var id: String { rawValue }
    var title: String {
        switch self {
        case .good: return "良好"
        case .better: return "较佳（最高1080p）"
        case .best: return "最佳（最高4K）"
        }
    }
}

/// 播放页「视频质量 › 下载」。[AX] 最高为高清 / 最高为标清 / 最兼容的格式。
enum VideoDownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd, sd, compatible
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hd: return "最高为高清"
        case .sd: return "最高为标清"
        case .compatible: return "最兼容的格式"
        }
    }
}

/// 「导入设置…」子对话框的「导入时使用」。[AX] 2026-09-05 展开实测。
enum ImportEncoder: String, Codable, CaseIterable, Identifiable, Sendable {
    case aac, aiff, appleLossless, mp3, wav
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aac: return "AAC编码器"
        case .aiff: return "AIFF编码器"
        case .appleLossless: return "Apple保真压缩编码器"
        case .mp3: return "MP3编码器"
        case .wav: return "WAV编码器"
        }
    }

    /// 「详细信息」那一框里的规格文字。[AX] 只实测到 AAC × iTunes Plus 这一格
    /// （「128 kbps（单声道）/256 kbps（立体声），44.100 kHz，VBR。」），
    /// 其余格按 iTunes 的老规格补，标 `[推]`。
    func detail(preset: ImportPreset) -> String {
        switch self {
        case .aiff, .wav:
            return "自动（16 位／44.100 kHz，立体声）。"           // [推]
        case .appleLossless:
            return "自动（无损压缩，与源文件逐比特一致）。"          // [推]
        case .mp3:
            switch preset {
            case .highQuality: return "128 kbps（立体声），44.100 kHz，联合立体声，普通立体声。"  // [推]
            case .iTunesPlus, .custom: return "160 kbps（立体声），44.100 kHz，VBR。"          // [推]
            case .spokenPodcast: return "64 kbps（单声道），22.050 kHz。"                     // [推]
            }
        case .aac:
            switch preset {
            case .highQuality: return "128 kbps（立体声），44.100 kHz。"                       // [推]
            case .iTunesPlus, .custom:
                return "128 kbps（单声道）/256 kbps（立体声），44.100 kHz，VBR。"              // [AX]
            case .spokenPodcast: return "64 kbps（单声道），44.100 kHz。"                      // [推]
            }
        }
    }
}

/// 「导入设置…」子对话框的「设置」。[AX] 高质量(128 kbps) / iTunes Plus / 口述播客 / 自定义…
enum ImportPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case highQuality, iTunesPlus, spokenPodcast, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .highQuality: return "高质量(128 kbps)"
        case .iTunesPlus: return "iTunes Plus"
        case .spokenPodcast: return "口述播客"
        case .custom: return "自定义…"
        }
    }
}

// MARK: - 设置窗口的全部取值

/// Music 设置窗里那一整套开关的值，一个 struct 装全部。
///
/// 设置窗编辑的是它的**副本**，「好」按下才写回 `AppSettings`——Music 的取消/好就是
/// 这个意思（[AX] 好带 default_action）。
///
/// 出厂值一律照 Music 的实测态填（`Reports/`settings 规格` 各表的「当前值」
/// 是本机用户状态，不是出厂默认，所以这里取的是「看起来像出厂默认」的那一侧，
/// 有疑问的以 Music 实测态为准）。
///
/// **`功能` 字段说明**：每个字段的注释写明它落到哪。唯一「存而不接」的是 `hdmiPassthrough`，
/// 原因见它自己的注释——不是没做，是 macOS 没向第三方开这条路。
/// （2026-09-05 立起来时这里有一半字段是「占位」：控件照抄、值照存、没有消费者；
/// 2026-09-07/08 分批接线后已全部接上。）
struct SettingsValues: Codable, Equatable, Sendable {

    // MARK: 通用

    /// 同步资料库。Amber 接的是 **QQ 账号里的歌单同步**（`AppState.syncAccountPlaylists`）。
    var syncLibrary = true
    /// 自动下载。开着时进资料库的歌立刻落地（`LibraryStore.onTracksAdded`
    /// → `AppState` → `DownloadStore.download`）。
    var automaticDownloads = false
    /// 下载杜比全景声。关掉时下载档位跳过沉浸声那一档（`AppState.downloadQuality`
    /// 把它映射成 `.off` 喂给`StreamQuality.clamped`）。
    var downloadDolbyAtmos = true
    /// 始终检查可用的下载。启动时把资料库里还没落地的歌补下
    ///（`AppState.checkForMissingDownloads`）。只在「自动下载」也开着时生效——
    /// 它是自动下载的修饰语，不是第二个开关。
    var alwaysCheckForDownloads = true
    /// 使用听歌历史记录。关掉后不再记播放次数／跳过次数／最近播放（`LibraryStore`）。
    var useListeningHistory = true
    /// 更大字体。译文与发音**同屏**时哪一条用大那一档（`LyricsSpecs.largerSecondary`，
    /// 选档收在 `LyricsSpecs.secondaryFonts(hasTranslation:hasTransliteration:)`）；
    /// 只剩一条副行时两档没有区别。
    ///
    /// 出厂值取 `.pronunciation`：`[实测]` 从 Music 回收的那道二选一就是「发音 15 / 译文 12」，
    /// 这是 Music 出厂状态下实际画出来的样子；[AX] 设置窗里读到的「歌词」是那台机器的用户态。
    var largerText: LargerTextTarget = .pronunciation
    /// 显示 › iTunes Store。控制边栏「商店」那一组。
    var showITunesStore = true
    /// 显示 › 星级评分。关掉后歌曲表不再出评分列。
    var showStarRatings = true
    /// 显示 › 歌曲列表复选框。开着时资料库「歌曲」页最左出一列勾选框
    /// （`SongsTableColumns.Key.checked`，勾选状态存`LibraryStore.uncheckedTrackIDs`）；
    /// 自动连播跳过没勾的（`PlayerController.nextStep(skippingUnchecked:)`），手动切歌照放。
    /// 详情页的曲目表还没有这一列（它不共用列机制）。
    var songListCheckboxes = false
    /// 通知 › 歌曲更改时。换歌时发一条系统通知。
    var notifyOnSongChange = false

    // MARK: 播放

    /// 歌曲过渡（交叉淡入淡出）。落到 `PlayerController` 的双路`PlaybackDeck`：
    /// 下一首提前取好、preroll 好，在当前这首结尾前 N 秒两路同时出声，
    /// 音量斜坡挂在各自的 `DeckAudioMix` 上（`AVMutableAudioMixInputParameters`）。
    /// 同一张专辑内的相邻曲目与单曲循环不过渡（见 `PlayerController.handoffMode`）。
    var crossfade = false
    /// 过渡效果样式。落点同上（`PlayerController.handoffMode`）。
    ///
    /// **「智能过渡」与「自动过渡」在 Amber 里是同一件事**：智能过渡要按调性/拍速挑接点，
    /// AVFoundation 与 MediaToolbox 都没有公开的调性或拍速分析 API，
    /// 没有这个能力就不假装有——两档一律按自动来（`handoffMode` 的注释里也写了一遍）。
    /// [AX] 勾选框关着时整颗 popup 禁用。
    var crossfadeStyle: CrossfadeStyle = .automatic
    /// 队列面板顶部的「自动播放」开关（[实测] playqueue spec §3.9 的
    /// `autoplay.value` 绑的那一位）。
    ///
    /// 开着时 `PlayerController` 会在队尾快见底（剩不到
    /// `PlayerController.autoplayRefillThreshold` 项）时拿**当前这首**去问音源要相似歌，
    /// 以 `origin: .autoplay` 追加到队尾；关掉时把已经补进来的那几项清掉
    /// （`clearAutoplayItems()`）。要候选走`MusicProvider.similarTracks`，**只有这一条路**：
    /// QQ 是 `music.recommend.TrackRelationServer/GetSimilarSongs`（一次 26 首），
    /// 网易云是 `simiSong`（一次 5 首）。5 首不算少——种子跟着当前曲往前走，
    /// 每首新歌都再问一批，这条路本来就是无限的。
    ///
    /// 按钮本身的可用性另看 `PlayQueueModel.autoplayAvailable`（问当前曲的音源）。
    var playQueueAutoplay = false
    /// 声音增强器。落到 `AudioTap` 的实时回调：每声道低架 + 临场感峰值 + 高架三节 biquad
    /// （`SoundEnhancerCurve` / `Biquad`），再加立体声展宽与末级软限幅，
    /// 跑在 `MTAudioProcessingTap` 里，每支 item 出生就带（见`PlayerController.makeItem`）。
    var soundEnhancer = false
    /// 声音增强器滑杆。[AX] 量程 0–255（AX min/max 实测），默认取中点。
    /// 映射：0 → 全 0，255 → 低架 +6 dB @100 Hz、临场感 +2.5 dB @2.5 kHz（Q≈1）、
    /// 高架 +7.5 dB @4 kHz、侧信号 ×1.7、前级 −2 dB（`SoundEnhancerCurve.gains(level:)`）。
    /// 这几个数都是 [推]：Music 那根滑杆没有可读的曲线，取的是「推到高档能明显听出
    /// 更亮更宽更有推力」的一档——上一版（+3/+6/−3）实听「效果不明显」。
    var soundEnhancerLevel: Double = 127
    /// 音量平衡（Sound Check）。落到同一条 tap：K 加权积分响度（`LoudnessMeter`）在播放中
    /// 边播边量，一首整整播完写进 `LoudnessStore`，增益在 tap 内乘
    /// （目标 −16 LUFS，上限 +6 dB，再让开 1 dB 峰值余量）。
    ///
    /// **第一遍只量不调，第二遍才归一**：音源不给响度标签（`AVMetadataIdentifier` 里
    /// 也没有 iTunNORM），只拿开头一段估整首会把安静的前奏误判成「整首都轻」
    /// （见 memory `am-no-per-song-tuning`）。已下载的文件不用等听完——
    /// 落地时 `DownloadStore.onDownloaded` 就把它交给`LoudnessStore` 离线量了。
    var soundCheck = false
    /// 启用无损音频。关掉后取流档位夹到有损那几档（`AppState.effectiveQuality`）。
    var losslessEnabled = true
    /// 下载档位。下载那条 resolver 的起点（`AppState.downloadQuality`），
    /// 与流播放的 `effectiveQuality` 各夹各的：Music 里这两个选择器本来就是分开的。
    var downloadQuality: StreamQuality = .lossless
    /// 杜比全景声。两处消费，先经 `resolved(for:)` 把「自动」折算成确定的一档：
    /// ① 取流档位（`AppState.effectiveQuality` → `StreamQuality.clamped`，「关闭」跳过沉浸声那一档）；
    /// ② `AVPlayerItem.allowedAudioSpatializationFormats`
    ///（`AudioOutputRules.spatializationFormats(for:)`，由`PlayerController.spatializationProvider` 注入）。
    var dolbyAtmos: DolbyAtmosMode = .automatic
    /// HDMI直通。**存而不接，且这不是「还没做」**：macOS 没有向第三方 App 开放杜比直通
    ///（Apple 支持文档只列 Music / QuickTime / TV），公开 SDK 里连 E-AC-3 的
    /// IEC-60958 传输格式 ID 都没有——Amber 的沉浸声档取回来的正是 E-AC-3 JOC，
    /// `Tools/audio-probe.swift` 在真机上最好也只能看到`cac3`（AC-3），
    /// 而 macOS 不带 E-AC-3 → AC-3 的编码器。所以 `.preferred` 不改变任何输出路由，
    /// 设置页的说明文字里也照实写了这一句（见 `SettingsView` 的 HDMI 描述）。
    var hdmiPassthrough: HDMIPassthrough = .off
    /// 视频质量 › 流播放。App 内 MV 播放器（`MVPlayerWindowController`）取流的封顶分辨率：
    /// 良好 ≤480p `[推]` / 较佳 ≤1080p / 最佳不封顶（`MVStream.maxHeight(for:)`）。
    /// QQ 走 `GetMvUrls` 的 mp4 档位表，匿名最高 720p、1080p 起要会员；网易服务端自己降级，
    /// 问一次回来的 `r` 才是真档位。
    var videoStreamQuality: VideoStreamQuality = .best
    /// 视频质量 › 下载。`DownloadStore.downloadMV` 的封顶：高清 ≤1080p / 标清 ≤480p /
    /// 最兼容 ≤720p `[推]`（两家只发 H.264+AAC 的 mp4，「最兼容」在 Amber 里只剩分辨率这一层）。
    /// 文件落在 `<媒体>/MV/`，再点同一支 MV 优先播本地那份。
    var videoDownloadQuality: VideoDownloadQuality = .hd

    // MARK: 文件

    /// 「媒体」文件夹。已下载曲目的落点（`DownloadStore.init`）。改了路径就整份搬过去：
    /// `DownloadStore` 自己订阅这个键，搬完/搬砸都回一句 toast（`onMediaFolderChanged`）。
    /// nil 表示还没改过，用 `SettingsValues.defaultMediaFolder`。
    var mediaFolderPath: String?
    /// 保持「媒体」文件夹有序。开着时新下载按 `艺人/专辑/编号标题.ext` 摆
    ///（`DownloadStore.relativePath`），关着是扁平的`<id>.ext`。**只影响新文件**。
    var keepMediaFolderOrganized = true
    /// 添加到资料库时将文件拷贝到「媒体」文件夹。「文件 › 导入…」（`ImportService`）里
    /// 不需转码的文件：开＝按 `keepMediaFolderOrganized` 的命名拷进`mediaFolder`，关＝原地引用
    ///（从资料库删掉也不删用户的原文件）。转码产物无论开关都落媒体文件夹——那是 Amber 新造的文件。
    var copyFilesToMediaFolder = true
    /// 导入设置 › 导入时使用。`ImportTranscoder` 用 AVAssetReader/Writer 转码：AAC / Apple 保真压缩 /
    /// AIFF / WAV；源格式已与所选一致就不转。**MP3**：Apple 没有编码器，源本来是 MP3 就原样进，
    /// 否则回落 AAC 并 toast 一次。
    var importEncoder: ImportEncoder = .aac
    /// 导入设置 › 设置。转码码率 / 声道 / 采样率取自下面 `ImportEncoder.detail(preset:)` 的规格文字
    ///（`ImportOutputSpec.make`）。
    var importPreset: ImportPreset = .iTunesPlus
    /// 导入设置 › 读取音乐光盘时使用纠错功能。音乐光盘在 macOS 由 cddafs 挂成 AIFF，走同一条导入路；
    /// 「纠错」没有公开 API，这里落成读元数据与转码时的读取重试次数（3 次 vs 1 次）。
    var importUseErrorCorrection = false

    // MARK: 高级

    /// 添加与删除播放列表歌曲：加进本地播放列表的歌同时进资料库
    ///（`LibraryStore.addTracks(_:toPlaylist:)`），从资料库删掉时也从`.local` 列表里清
    ///（`pruneAfterLibraryRemoval`）。
    var syncPlaylistSongsWithLibrary = false
    /// 添加与删除喜爱歌曲：心水的歌同时进资料库（`LibraryStore.toggleFavorite`），
    /// 从资料库删掉时同时取消心水（`pruneAfterLibraryRemoval`）。
    var syncFavoriteSongsWithLibrary = true
    /// 自动更新已导入歌曲的插图。导入的文件没有内嵌封面时，按「艺人标题」到默认音源搜第一条的封面回填
    ///（`ImportService`，尽力而为，失败不影响导入）。
    var autoUpdateImportedArtwork = false
    /// 窗口 › 在其他所有窗口前端显示迷你播放程序。独立的迷你播放器窗口
    ///（`MiniPlayerWindowController`，窗口 › 迷你播放器 ⌥⌘M）开着就`level = .floating`，
    /// 改开关时窗口在开着也立刻生效。主窗底栏那颗胶囊不受影响。
    var miniPlayerOnTop = false
    /// 窗口 › 在其他所有窗口前端播放视频。MV 播放器窗（`MVPlayerWindowController`）
    /// 开着就 `level = .floating`，播放中改开关立刻生效。
    var videoOnTop = false
    /// 迷你播放器窗要不要挂 `NSToolbar`（歌词/待播清单/AirPlay/音量那一条）。
    ///
    /// 对应 Music 的 `use_toolbar_in_miniplayer`（miniplayer spec §5）——那是一条
    /// **纯 NSUserDefaults 开关，设置窗里没有对应的勾选框**，所以这里也只有值、不上界面；
    /// 改它时迷你窗会实时装/卸工具条（`MiniPlayerWindowController.observeDefaults`）。
    /// 出厂 true = Music 的默认行为。
    var useToolbarInMiniPlayer = true

    /// 「媒体」文件夹的出厂位置：Music 是 ~/音乐/Music/媒体，Amber 挪到自己名下。
    static var defaultMediaFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Amber/媒体", isDirectory: true)
    }

    var mediaFolder: URL {
        mediaFolderPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultMediaFolder
    }

    /// 下载取流的起点档位：设置里选的下载档，过一道与流播放同一个夹取。
    ///
    /// 「下载杜比全景声」是个勾选框，映射成 `.automatic`／`.off` 喂给`clamped`
    /// ——沉浸声那一档的取舍两条路是同一套规则，只是开关不同。
    /// 「启用无损音频」是全局封顶，两条路共用（关掉后下载也只到有损档）。
    var downloadStreamQuality: StreamQuality {
        downloadQuality.clamped(losslessEnabled: losslessEnabled,
                                dolbyAtmos: downloadDolbyAtmos ? .automatic : .off)
    }

    // MARK: 解码

    /// 把存下来的 JSON 解回一份设置，**缺的键落到该字段的出厂值**。
    ///
    /// 做法是：出厂值先编成字典，再拿存下来的键逐键盖上去，最后整份解码。
    /// 不这么做的话，每加一个字段都会把用户已存的设置清一次——合成 `Codable` 的
    /// `init(from:)` 缺一个非可选键就 throw，而调用方是`try?`，一 throw 整份回落出厂值。
    ///
    /// 顺带兜住的：存的 JSON 里留着**删掉过的旧键**也不碍事，合并后那些键仍在，
    /// 但合成的 `init(from:)` 只按自己声明的键取，多出来的直接不看。
    ///
    /// **兜不住的**：值的类型对不上——比如某个 enum 的 rawValue 改了名、
    /// 或者 Bool 字段换成了别的类型——照旧整份 throw、回落出厂值。
    /// 这一档是有意留着的：一个键的值坏掉时没法只把这个键判死，
    /// 真要动 rawValue 就得自己写迁移。
    ///
    /// `SettingsValues` 是平的（全是 Bool / Double / String / String rawValue 的 enum），
    /// 没有嵌套的字典或子结构，所以浅合并就够；哪天真加了嵌套字段，
    /// 那一层也得按同样的口径合，不能只合最外层。
    static func decode(_ data: Data) -> SettingsValues {
        let factory = SettingsValues()
        guard
            let factoryData = try? JSONEncoder().encode(factory),
            var merged = try? JSONSerialization.jsonObject(with: factoryData) as? [String: Any],
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return factory }
        for (key, value) in stored { merged[key] = value }
        guard
            let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let decoded = try? JSONDecoder().decode(SettingsValues.self, from: mergedData)
        else { return factory }
        return decoded
    }
}

// MARK: - 档位夹取

extension StreamQuality {

    /// 设置 › 播放里那两个开关对取流档位的夹取，返回**实际该从哪一档开始试**。
    ///
    /// - `losslessEnabled == false`：无损与沉浸声那几档全部让开，从最高的有损档起
    ///   （Music 关掉「启用无损音频」就是封顶 AAC 256，同一个意思）。
    /// - `dolbyAtmos == .off`：只让开沉浸声那一档，`.alwaysOn` 保留它。
    ///   传进来的**必须是折算过的模式**：调用方先用 `DolbyAtmosMode.resolved(for:)`
    ///   把「自动」按当前默认输出设备变成 `.alwaysOn` 或`.off`
    ///   （`AppState.effectiveQuality` 就是这么做的），所以这里只认确定的两档。
    ///
    /// 夹取只改**起点**，降级阶梯不变：这首歌没有目标档位时照旧一路往下试。
    func clamped(losslessEnabled: Bool, dolbyAtmos: DolbyAtmosMode) -> StreamQuality {
        var candidates = ladder
        if dolbyAtmos == .off {
            candidates.removeAll { $0.group == "沉浸声" }
        }
        if !losslessEnabled {
            candidates.removeAll { $0.group == "沉浸声" || $0.group == "无损" }
        }
        // 阶梯是从高到低排的，第一个没被排除的就是新起点；真被排空了退回标准档
        return candidates.first ?? .standard
    }
}

// MARK: - 杜比全景声的「自动」

extension DolbyAtmosMode {

    /// 「自动」按当前默认输出设备折算成确定的一档；「始终打开」「关闭」原样返回。
    ///
    /// 没有任何 API 能回答「这台输出支持杜比全景声」，所以判据是输出设备的传输方式与
    /// 声道数（见 `AudioOutput.prefersAtmos`）：内建/蓝牙/双声道 USB 耳机取沉浸声，
    /// HDMI、DisplayPort、聚合设备这些走无损档——那些路径上 macOS 只会把 E-AC-3
    /// 解码成多声道 PCM 再送出去，拿无损反而是更高的实际质量。
    ///
    /// 纯函数：测试直接构造 `AudioOutput`，不用真设备。
    func resolved(for output: AudioOutput) -> DolbyAtmosMode {
        guard self == .automatic else { return self }
        return output.prefersAtmos ? .alwaysOn : .off
    }
}

// MARK: - 落盘

/// 设置窗口那一整套偏好的持有者。
///
/// 整个 `SettingsValues` 按 JSON 存一个键：设置窗是「按好才生效」的一次性写回，
/// 分成几十个键既没有额外好处，还要为每个键写一遍读写。
///
/// 视图从环境里拿（`@EnvironmentObject`）；`LibraryStore` 这类非视图代码走`shared`。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published var values: SettingsValues {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let key = "appSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 走 `SettingsValues.decode`：缺的键落该字段的出厂值，而不是整份回落出厂值。
        if let data = defaults.data(forKey: Self.key) {
            values = SettingsValues.decode(data)
        } else {
            values = SettingsValues()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
