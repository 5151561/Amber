import Foundation

/// 歌词数据模型。字段与顺序照原版的 19 个字段排。
struct Lyrics: Sendable {

    enum LyricsType: Sendable { case `static`, timedLines, timedWords }
    enum VocalistsType: Sendable { case single, duet, group }
    enum AgentAlignment: Sendable { case normal, flipped }

    /// 行的书写方向。**行自带**，不是全局设置——间奏行的三点落点就按它选左/右。
    ///
    /// [实测] 类型是 `Lyrics.Direction`，
    /// enum，两个空 case，声明序 `leftToRight` = 0、`rightToLeft` = 1（§15.2）。
    enum Direction: Sendable { case leftToRight, rightToLeft }

    /// 每行自己声明支持哪些特效——逐字渐变、上抬、强调。
    struct Capability: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let gradient = Capability(rawValue: 1 << 0)
        static let lift     = Capability(rawValue: 1 << 1)
        static let emphasis = Capability(rawValue: 1 << 2)
    }

    /// 一个词的强调载荷。辉光强度、强调缩放都由它驱动。
    ///
    /// [TYPE] §23.3：`Lyrics.Word.Emphasis` 是双 case 枚举
    /// `{ case factor(Double); case none }`，声明序`factor` = tag 0、`none` = tag 1。
    /// 它内联在 `Word.correspondingLyricWord` 里，载荷落在、
    /// tag 落在 §23.6 的字段全表里。
    ///
    /// **`.none` 的词整个不做辉光**——实测在进入辉光前先比了这个 tag，
    /// 是五道闸里的第四道，命中就直接跳过。
    enum Emphasis: Sendable, Equatable {
        case factor(Double)
        case none

        /// 强度公式里的乘数。`.none` 不参与公式（调用方要先过闸），这里给 0
        /// 是为了让公式在漏闸时退化成「不发光」而不是崩。
        var factor: Double {
            switch self {
            case .factor(let value): return value
            case .none: return 0
            }
        }

        var isNone: Bool {
            switch self {
            case .factor: return false
            case .none: return true
            }
        }
    }

    /// 空间音频要给歌词整体加偏移。
    enum AudioAttribute: Sendable, Hashable {
        case spatial(lyricsOffset: TimeInterval)
    }

    var type: LyricsType = .static
    var lines: [any LyricsLine] = []
    var leadingSilence: TimeInterval = 0        // 前奏长度，源数据直接给
    var vocalistsType: VocalistsType = .single
    var songwriters: [String] = []              // 作为最后一行渲染
    var translations: [String: [String]] = [:]
    var transliterations: [String: [String]] = [:]
    var audioAttributes: Set<AudioAttribute> = []

    init() {}
}

protocol LyricsLine: Sendable {
    /// 行在 `Lyrics.lines` 里的下标。
    ///
    /// [实测] 这是行存在体的协议：`selecting line` 与
    /// `selecting` 都靠它把行换成`manager.lineViews[index]`。
    /// 视图数组与行数组是**按下标一一对应**的，中间没有查找表。
    var index: Int { get }
    var startTime: TimeInterval { get }
    var endTime: TimeInterval { get }
}

/// 普通唱词行。注意整行时间与主唱时间是分开的两组。
struct TextLine: LyricsLine, Sendable {
    var index: Int = 0
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var primaryVocalsStartTime: TimeInterval = 0
    var primaryVocalsEndTime: TimeInterval = 0
    var isFirstLineOfParagraph = false          // 段间距 39 靠它
    var agentAlignment: Lyrics.AgentAlignment = .normal
    /// 这一行的书写方向。与 `agentAlignment` 是**两件事**：前者管排版靠哪边，
    /// 它管逐字从哪头开始扫。原版也是两个并列字段（`InstrumentalLine.lyricsDirection`
    /// 同源，§15.2「书写方向随行走，不是全局设置」）。
    ///
    /// 对唱翻转侧是「右对齐的拉丁/CJK 行」——顶到右边，但仍从左往右唱。
    /// 早先这三处遮罩方向读的是 `agentAlignment == .flipped`，`.flipped` 一旦出现
    /// 就会把它们倒过来扫。
    var direction: Lyrics.Direction = .leftToRight
    var capabilities: Lyrics.Capability = []
    var backgroundVocals: BackgroundVocals?

    struct BackgroundVocals: Sendable {
        var startTime: TimeInterval = 0
        var endTime: TimeInterval = 0
    }

    // MARK: 内容 `[补]`
    //
    // 只记了**选行状态机碰得到**的字段（时间、能力、对齐），
    // 文本与逐字时间轴原版当然也有——内容层要拿它排版、
    // 每帧要拿它走查——但字段名与偏移没读出来。下面这几个是按内容层的需要补的，
    // 名字自取，不对应任何实测偏移。

    /// 行文本。
    var text: String = ""
    /// 翻译副行。`translationSpacing` 7 / `translationBottomPadding` 4 归它管。
    var translation: String?
    /// 音译副行。Amber 的数据源不产出。
    var transliteration: String?
    /// 逐字时间轴。空表示这行只有整行时间，内容层走整行档（`.despacito`）。
    var syllables: [SyllableTiming] = []

    /// 一个逐字单元的时间。原版把它摊在 `Syllable` 层，
    /// 那一层同时带排版出来的 frame；这里只留数据面，frame 由内容层算。
    struct SyllableTiming: Sendable, Equatable {
        var text: String = ""
        var startTime: TimeInterval = 0
        var endTime: TimeInterval = 0
        /// 这几个字的发音。有值的行走「发音贴在字底下」那条排版（§见 `RubyLayout`），
        /// 整行那条 `transliteration` 副行就不再出现。
        var transliteration: String?
        /// 这个逐字单元的强调载荷。原版挂在 `Word` 上（§23.6 内联模型的
        /// Amber 的 QRC 源里「一个单元就是一个词」，所以摊在这一层，
        /// 建 `Word` 时原样带过去（`SBS_TextContentLayer+Layout` / `+Ruby`）。
        ///
        /// 生产侧原版是服务端数据（§23.8 `[缺口]`），QRC/YRC 都不带这个字段——
        /// Amber 自己按音节时长合成，规则见 `LyricsAdapter.synthesizeEmphasis`。
        var emphasis: Lyrics.Emphasis = .none
        init(text: String, startTime: TimeInterval, endTime: TimeInterval,
             transliteration: String? = nil,
             emphasis: Lyrics.Emphasis = .none) {
            self.text = text; self.startTime = startTime; self.endTime = endTime
            self.transliteration = transliteration
            self.emphasis = emphasis
        }
    }

    init() {}
}

/// 间奏行（三个点那一行）。
///
/// [实测] 类型是 `Lyrics.InstrumentalLine`，**struct**
/// （不是类），32 字节四个字段：`lineIndex: Int`、`startTime: Double`、`endTime: Double`、
/// `lyricsDirection: Lyrics.Direction`（§15.2）。这里的`index` 就是原版的`lineIndex`。
struct InstrumentalLine: LyricsLine, Sendable {
    var index: Int = 0
    /// **展开动画跑完、行完全张开那一刻。**
    ///
    /// 选行状态机（准入 / 淘汰 / 焦点位）读的是它：准入在`startTime − scrollLead`
    /// 触发，而展开就是在准入那一刻起跑的，跑完正好落在这里（见 `LyricsAdapter`）。
    var startTime: TimeInterval = 0
    /// **收起动画起跑那一刻**（行高 40 → 0，同一次重排把视口滚向下一句）。
    var endTime: TimeInterval = 0
    /// **行开始张开那一刻** —— 三个点的时间窗以它为原点。`[补]`
    ///
    /// 与 `startTime` 差一个展开动画：行高是**瞬时**落到 40 的（重排只动`position`），
    /// 所以点从这一刻起就在屏幕上，`startTime` 才是它们停稳的时刻。
    ///
    /// 两个数必须分开，不能让点阵拿 `startTime` 顶替：`[PX] 2026-09-04` 逐帧量 Music
    /// 那一段间奏 —— 行在 t=3.13 **开始**、撑开 3.67 落定、点 t≈4.05 才往上走 ——
    /// `firstDotDelay`（1.0）量的是 **3.13 那个起点**，不是 3.67。合成一个字段的话
    /// 点会白等一个 `scrollLead`：5 秒的间奏里真正在动的窗口只剩 0.4 秒，
    /// 而一个点淡入就要 0.8 秒。
    ///
    /// 前奏行没有「上一句」要等，展开不占前面的时间，所以它 `== startTime`。
    ///
    /// 可选是因为 0 是**合法值**（前奏行就从 0 开始），拿 0 当「没填」会把前奏之外
    /// 的行全部把原点拉到歌曲开头。没填就退回 `startTime`（等于「不留展开余量」，
    /// 也就是这个字段出现之前的行为）。
    var openTime: TimeInterval?
    /// 这一行的书写方向。三点整排靠哪一边就看它（§13.6）。
    var lyricsDirection: Lyrics.Direction = .leftToRight
    init() {}
}

/// 词曲作者行。`Lyrics.songwriters` 渲染成的最后一行，不吃悬停（§4.1 第二道闸）。
struct SongwritersLine: LyricsLine, Sendable {
    var index: Int = 0
    var startTime: TimeInterval = .infinity
    var endTime: TimeInterval = .infinity
    /// 已经拼好的整行文字。`[补]`，同`TextLine.text`。
    var text: String = ""
    init() {}
}
