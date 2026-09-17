import Foundation

/// 把内存里的 `LyricLine` 序列化成 LRC 文本，给下载好的音频写进标签
/// （m4a 的 `©lyr`、mp3 的 `USLT`、FLAC/Ogg 的 `LYRICS=`）。
///
/// 只做「取哪些、怎么排」这一层，不碰文件；纯函数，好测也好在任何线程上调。
///
/// 取舍都在一条线上：**标签里放的是歌词原文，不是 Amber 的界面产物**。
/// - `transliteration`（界面上的「发音」）不写。它是副行，LRC 没有副行的概念，
///   塞进去只会跟正文交替出现，别的播放器读到就是两行串行的乱码。
/// - `syllables`（逐字时间轴）不写。逐字要么走 QRC 要么走 YRC，都是各家私有格式，
///   没有通行标签放得下；降级成行级时间戳反而是所有播放器都认的最大公约数。
/// - `.interlude`（间奏的三个点）与 `.credits`（尾部词曲作者）滤掉。
///   这两种行是 `LyricParser` 为了界面「别让上一句干等」「结尾有个收」造出来的，
///   歌词原文里没有它们。
/// - 歌手提示行（`TAEYANG：`）在解析阶段就没进 `.lyric`——它标的是「下一段换人了」，
///   与`.interlude` / `.credits` 同档，是界面用的结构信息而不是歌词原文。
/// - `translation` 保留，紧跟正文再写一行**同时间戳**的译文。这是双语 LRC 的通行写法：
///   认的播放器叠成上下两行，不认的顶多多显示一行，不会坏。
///
/// **无时间戳的那一档（`lines.isUntimed`）照样写，只是一个时间戳都不带。**
/// 这不是降级：这些标签的原生内容本来就是纯文本——ID3 的 `USLT` 全称是
/// "Unsynchronised lyric/text transcription"，`©lyr` 与 Vorbis 的`LYRICS=` 同为纯文本字段，
/// 同步歌词才是后来借时间戳挤进去的那一种。反过来给每行补一个 `[00:00.00]` 更糟：
/// 规矩的播放器会把整首歌当成第 0 秒的一整行。上面那三条取舍（发音不写、创作者不写、
/// 译文紧跟正文）在这一档原样沿用。
enum LyricsLRC {

    /// 序列化。滤完没有任何非空正文时返回 nil——宁可这一格不写，
    /// 也别给文件塞一串只有时间戳的空壳。
    nonisolated static func text(from lines: [LyricLine]) -> String? {
        if lines.isUntimed { return untimedText(from: lines) }
        // 入参不保证有序（歌词可能是从几路数据归并出来的），自己排一次。
        // LRC 本身就要求按时间递增，同一时刻再按 index 稳住原有先后。
        let ordered = lines
            .filter { $0.kind == .lyric }
            .sorted { ($0.time, $0.index) < ($1.time, $1.index) }

        var out: [String] = []
        for line in ordered {
            let body = sanitized(line.text)
            guard !body.isEmpty else { continue }
            let stamp = timestamp(line.time)
            out.append(stamp + body)
            // 译文与正文共用时间戳；正文为空的那种「只有翻译」的行前面已经被挡掉了，
            // 免得译文成了孤儿行。
            if let translation = line.translation.map(sanitized), !translation.isEmpty {
                out.append(stamp + translation)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// 无戳那一档：`.plain` 行原样写，译文紧跟它那一行。
    ///
    /// **不排序**——`time` 在这一档全是 0，排了也只是按 index 走一遍；而文件顺序
    /// （解析时的行序）本来就是纯文本仅有的顺序信息，照原样传下去最稳妥。
    /// `.credits` 与 `transliteration` 同带戳那支一样不写。
    private static func untimedText(from lines: [LyricLine]) -> String? {
        var out: [String] = []
        for line in lines where line.kind == .plain {
            let body = sanitized(line.text)
            guard !body.isEmpty else { continue }
            out.append(body)
            if let translation = line.translation.map(sanitized), !translation.isEmpty {
                out.append(translation)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// `[mm:ss.xx]`。分钟不设上限也不回绕：超过一小时就写 `[62:03.10]`，
    /// 长音轨（现场整段、有声书）才不会被折回开头。
    private static func timestamp(_ time: TimeInterval) -> String {
        // NaN 与负数当 0；再夹一个上界，免得离谱的值在转 Int 时溢出。
        let seconds = time.isFinite ? min(max(time, 0), 1_000_000) : 0
        // 先整体折算成百分秒再拆，进位才会一路带上去：9.999s → 999.9 → 1000 → 00:10.00。
        let total = Int((seconds * 100).rounded())
        let minutes = total / 6000
        let secs = (total / 100) % 60
        let hundredths = total % 100
        return "[\(minutes.zeroPadded(to: 2)):\(secs.zeroPadded(to: 2)).\(hundredths.zeroPadded(to: 2))]"
    }

    /// 两端空白去掉；行内换行换成空格——一行里出现 `\n` 会把这行劈成没有时间戳的半行，
    /// 后半截在别的播放器里就成了游离文本。
    private static func sanitized(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
