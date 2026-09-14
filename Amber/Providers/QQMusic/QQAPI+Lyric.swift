import Foundation

// 歌词的三块增强：多风格翻译歌词、助唱标注歌词、AI 歌词词典。
// 移植来源：[QQMusicApi] `modules/lyric.py`、`models/lyric.py`。
//
// **正文歌词不在这个文件里。** 基线的 `QQAPI.lyrics(track:)`（`GetPlayLyricInfo`，
// 同一个 module `music.musichallSong.PlayLyricInfo`）拿的是「唱的那一份」：
// 逐字正文 `lyric` + 翻译 `trans` + 音译 `roma`，三样合成一条 `[LyricLine]`。
// 这里四条方法拿的是「正文之外的那些」，与它并存：
//
// | 这里的方法 | method | 拿什么 |
// | --- | --- | --- |
// | `multiStyleTranslations` | `BatchGetMultiStyleTransLyric` | 除了默认翻译之外的其他译本（诗意/粤语/方言/中译英…） |
// | `hasSingingAnnotations` | `GetSingingAnnotationsInfo` | 只回一个布尔：这首歌有没有助唱标注 |
// | `singingAnnotationLyrics` | `GetPlayLyricInfo` 的 `singingAnnotationsLyric` 字段 | 带换气标记的那一版逐字歌词 |
// | `aiDictionary` | `IsAIDictExists` + `GetAIDictInfo` | 划词释义 |
//
// `singingAnnotationLyrics` 与基线共用 method 但**不是重复实现**：基线那条请求里
// 没有 `needSingingAnnotations`，服务端也就不发这个字段；而这条只要注释版，
// `trans`/`roma` 一律关掉、返回值也只取 `singingAnnotationsLyric`。两条各取各的。
//
// 解密一律走 `QRCDecoder.decodePayload`（与基线同一份），不另写。
//
// ⚠️ **`crypt` 只能传 0。** 参考实现在 `get_lyric` 里固定传 `crypt: 1`，
// [实测 2026-09-09 curl] 匿名下传 1 时 `lyric` 与 `singingAnnotationsLyric` 都只回
// **20 字节**（40 个 hex 字符，如 `928444555443A90BE7558C007361B177E71EC61A`）——
// 20 不是 8 的倍数，3DES 根本解不动，参考实现自己的 `qrc_decrypt` 也会抛。
// 同一条请求把 `crypt` 改成 0，`lyric` 立刻变成 6384 字符的完整密文、
// `singingAnnotationsLyric` 6576 字符，且都能正常解出 QRC XML。
// 基线的 `lyrics(mid:wordByWord:)` 传的正是 0，这里跟它一致。

extension QQAPI {

    // MARK: - 多风格翻译

    /// 一份翻译歌词。
    struct QQStyledLyric: Hashable, Sendable {
        /// 风格 id（实测「中译英」是 8）
        let style: Int
        /// 风格名，直接摆到界面上的切换器里
        let styleName: String
        /// 已解密的 LRC 正文
        let lrc: String
        let updatedAt: Date?
    }

    /// 多风格翻译歌词。`music.musichallSong.PlayLyricInfo/BatchGetMultiStyleTransLyric`
    /// （[QQMusicApi] `modules/lyric.py::get_multi_style_trans_lyric`），
    /// param `{songID: <数字 id>}`——**键名是大写 D 的 `songID`**，
    /// 与基线正文那条的 `songMid` 不是一套写法，别混。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，songID=107192078（告白气球）回
    /// `lyrics[]` 1 条：`{style: 8, styleName: "中译英", lyric: <hex 密文>, timestamp: 1764916975}`。
    /// 密文用 `QRCDecoder` 解出来是**普通 LRC**（不是逐字 QRC）：
    /// 头几行是 `[ti:告白气球]` / `[ar:周杰伦]` / `[al:…]` / `[offset:0]`，
    /// 第一句正文是 `[00:00.00]以下歌词翻译由文曲大模型提供`，
    /// 之后 `[00:23.59]Cafe on the left bank of the Seine` 这样逐行对齐。
    /// 前奏那几行是 `//` 占位（与 roma 那边同一个约定，见记忆里那条 QQ roma 的坑）。
    ///
    /// 交出来的是**原文 LRC 字符串**而不是 `[LyricLine]`：这几份是「另一个译本」，
    /// 要用的话得跟正文按时间归并到 `LyricLine.translation` 上去，那是界面层选了
    /// 哪个风格之后的事；在这里先解析成行反而把时间轴拆散了。
    func multiStyleTranslations(_ track: Track) async -> [QQStyledLyric] {
        guard let songID = await songID(mid: track.id.rawID) else { return [] }
        guard let data = try? await musicu(module: "music.musichallSong.PlayLyricInfo",
                                           method: "BatchGetMultiStyleTransLyric",
                                           param: ["songID": songID]) else { return [] }
        return (data["lyrics"] as? [[String: Any]] ?? []).compactMap { item -> QQStyledLyric? in
            guard let raw = item["lyric"] as? String,
                  let lrc = QRCDecoder.decodePayload(raw), !lrc.isEmpty else { return nil }
            let ts = item["timestamp"] as? Int ?? 0
            return QQStyledLyric(style: item["style"] as? Int ?? 0,
                                 styleName: item["styleName"] as? String ?? "翻译",
                                 lrc: lrc,
                                 updatedAt: ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil)
        }
    }

    /// 这首歌有没有其他译本。基线那条正文请求的响应里就带 `hasMultiTrans`
    /// （[实测 2026-09-09 curl] 告白气球是 `true`），所以想省一条请求的话
    /// 也可以从那儿读——只是基线没把它交出来。这里单独问一次，
    /// 用途是「要不要在界面上显示翻译风格切换器」。
    func hasMultiStyleTranslations(_ track: Track) async -> Bool {
        !(await multiStyleTranslations(track).isEmpty)
    }

    // MARK: - 助唱标注

    /// 这首歌有没有助唱标注歌词。
    /// `music.musichallSong.PlayLyricInfo/GetSingingAnnotationsInfo`
    /// （[QQMusicApi] `modules/lyric.py::get_singing_annotations_info`），
    /// param `{songID: <数字 id>, needNum: false}`——`needNum` 要真的是布尔
    /// （参考实现在这条上开了 `preserve_bool=True`，说明服务端认的是 JSON 布尔）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，告白气球回
    /// `{remainingNum: 1, hasSingingAnnotationsLyric: true, total: 3, blockScheme: "qqmusic://…dialog_vip_cashier…"}`。
    /// `blockScheme` 指向会员收银台——说明**这功能在 QQ 客户端里是限次/会员的**
    /// （`total 3` / `remainingNum 1` 是次数），但歌词本体在匿名下照样发得出来（见下）。
    /// 参考实现的 model 只列了 `hasSingingAnnotationsLyric` 一项，另外三个是实测多出来的。
    func hasSingingAnnotations(_ track: Track) async -> Bool {
        guard let songID = await songID(mid: track.id.rawID) else { return false }
        guard let data = try? await musicu(module: "music.musichallSong.PlayLyricInfo",
                                           method: "GetSingingAnnotationsInfo",
                                           param: ["songID": songID, "needNum": false]) else {
            return false
        }
        return (data["hasSingingAnnotationsLyric"] as? Bool) ?? false
    }

    /// 助唱标注版的逐字歌词。
    ///
    /// 与基线 `lyrics(track:)` 同走 `GetPlayLyricInfo`，但请求里多一个
    /// `needSingingAnnotations: true`（布尔），返回里只取 `singingAnnotationsLyric`
    /// 这一个字段——`trans` / `roma` 一律关掉，正文归基线那条管（见文件头的分工表）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0。解出来是**与正文同一份 QRC XML**
    /// （`<QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent="…">`），
    /// 逐字时间轴与正文逐字一致，行数也一致（告白气球两边都是 63 行），
    /// 差别只有两种插进正文里的标记符：
    /// - `^`：一句开头或某个字前的**大换气**（这次出现 34 处，如 `[23593,2567]^塞(23593,201)纳…`）；
    /// - `` ` ``：句中的**小换气**（6 处，如 `我(…)手(…)一(…)` + `` ` `` + `杯(…)`）。
    ///
    /// **原样交出解密后的文本，不做清洗**：直接扔给 `LyricParser` 的话这两个符号会
    /// 混进歌词正文显示出来；而它们本来就是这份数据的全部价值（要在界面上画换气记号）。
    /// 怎么呈现是界面层的事，这一层不替它决定——同理也不在这里 `LyricParser.parse`。
    func singingAnnotationLyrics(_ track: Track) async -> String? {
        let mid = track.id.rawID
        guard !mid.isEmpty else { return nil }
        guard let data = try? await musicu(
            module: "music.musichallSong.PlayLyricInfo",
            method: "GetPlayLyricInfo",
            param: ["songMid": mid, "qrc": 1, "crypt": 0,
                    "lrc_t": 0, "qrc_t": 0, "roma": 0, "trans": 0,
                    "needSingingAnnotations": true, "type": 1]) else { return nil }
        guard let raw = data["singingAnnotationsLyric"] as? String, !raw.isEmpty,
              let text = QRCDecoder.decodePayload(raw), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - AI 词典

    /// AI 词典里的一条：某个词/短语 + 释义 + 它在哪一行歌词里。
    struct QQLyricDictEntry: Hashable, Sendable {
        let phrase: String
        let explanation: String
        /// 词所在的那行歌词原文
        let lyricText: String
        /// 那行的中文翻译
        let translatedLyricText: String
        /// 那行的时间戳（接口给的是字符串，不是数字）
        let timestamp: String
    }

    /// AI 歌词词典（歌词里划词看释义的那份数据）。
    ///
    /// 两条接口：先 `IsAIDictExists` 问有没有，有才 `GetAIDictInfo` 取
    /// （[QQMusicApi] `modules/lyric.py::is_ai_dict_exists` / `get_ai_dict`），
    /// param 都是 `{songID: <数字 id>}`。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0：告白气球 `IsAIDictExists` 回 `{exists: false}`，
    /// `GetAIDictInfo` 回 `{dictList: null}`——**两条对得上**，所以先问再取这一步
    /// 不是白问，它能省掉一条注定为空的请求（也是参考实现分成两个方法的理由）。
    /// **有词典时的条目形状没有实机验证过**（手上这首没有），
    /// 字段名取自参考实现的 `AIDictItem`：`phrase` / `explain` / `lyric_text` /
    /// `trans_lyric_text` / `lyric_timestamp`，装在 `dictList` 里。
    func aiDictionary(_ track: Track) async -> [QQLyricDictEntry] {
        guard let songID = await songID(mid: track.id.rawID) else { return [] }
        guard let exists = try? await musicu(module: "music.musichallSong.PlayLyricInfo",
                                             method: "IsAIDictExists",
                                             param: ["songID": songID]),
              (exists["exists"] as? Bool) == true else { return [] }
        guard let data = try? await musicu(module: "music.musichallSong.PlayLyricInfo",
                                           method: "GetAIDictInfo",
                                           param: ["songID": songID]) else { return [] }
        return (data["dictList"] as? [[String: Any]] ?? []).compactMap { item -> QQLyricDictEntry? in
            guard let phrase = item["phrase"] as? String, !phrase.isEmpty else { return nil }
            return QQLyricDictEntry(phrase: phrase,
                                    explanation: item["explain"] as? String ?? "",
                                    lyricText: item["lyric_text"] as? String ?? "",
                                    translatedLyricText: item["trans_lyric_text"] as? String ?? "",
                                    timestamp: item["lyric_timestamp"] as? String ?? "")
        }
    }
}
