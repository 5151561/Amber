import Foundation

// 文件名／目录名里的元信息。
//
// 从音源下下来的文件常常一个标签都不带（QQ 音乐的杜比 mp4 就是 `availableMetadataFormats == []`），
// 信息全在文件名里。Music 遇到这种文件也是照文件名填的，Amber 同法：**只补标签没给的那几格**，
// 标签有的一律以标签为准。
//
// 规则全部是纯函数，见 `ImportServiceTests` 里按真实文件名写的用例。

struct ImportNameGuess: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var trackNumber: Int?

    /// 文件名两段式切出来的另一半。标签已经给了艺人时，用它判断切对了没有：
    /// 「我天生 - 有梦版」这种「标题 - 版本」切出来的两半没有一半是艺人，就整条当标题。
    var splitCounterpart: String?
    /// 去掉噪声括号、曲序之后的整条文件名（切不开时就用它当标题）
    var cleanedStem: String = ""

    // MARK: - 入口

    static func guess(for url: URL) -> ImportNameGuess {
        var result = ImportNameGuess()
        let stem = url.deletingPathExtension().lastPathComponent

        // 1. 先摘掉噪声括号：`[杜比D003-最高码率]` 里那个裸横杠会把下一步的切分带歪。
        var cleaned = stripNoiseBrackets(stem)

        // 2. 开头的曲序：`01 `、`01.`、`01-`
        if let (number, rest) = leadingTrackNumber(cleaned) {
            result.trackNumber = number
            cleaned = rest
        }
        cleaned = cleaned.trimmed
        result.cleanedStem = cleaned

        // 3. 切「艺人／标题」
        if let split = splitArtistTitle(cleaned) {
            result.title = split.title
            result.artist = split.artist
            result.splitCounterpart = split.counterpart
        } else if !cleaned.isEmpty {
            result.title = cleaned
        }

        // 4. 目录链：`…/艺人/专辑/曲目.m4a` 才算数，两级都得是「像名字」的目录
        //    （用户主目录、Music、QQ音乐 这类落脚点不算）。
        let album = url.deletingLastPathComponent()
        let artist = album.deletingLastPathComponent()
        if isNameLikeFolder(album), isNameLikeFolder(artist) {
            result.album = album.lastPathComponent
            if result.artist == nil { result.artist = artist.lastPathComponent }
        }
        return result
    }

    // MARK: - 括号

    /// 方括号／全角方括号整段摘掉；圆括号只摘「音质／版本噪声」那种
    /// （`(with 五月天阿信)`、`(Live)` 是标题的一部分，摘了反而丢信息）。
    static func stripNoiseBrackets(_ text: String) -> String {
        var result = ""
        var buffer = ""
        var opener: Character?
        for character in text {
            if let open = opener {
                if character == Self.brackets[open] {
                    // 圆括号里装的若不是噪声，原样放回去
                    if (open == "(" || open == "（"), !isNoise(buffer) {
                        result += "\(open)\(buffer)\(character)"
                    }
                    opener = nil
                    buffer = ""
                } else {
                    buffer.append(character)
                }
                continue
            }
            if Self.brackets[character] != nil {
                opener = character
                buffer = ""
                continue
            }
            result.append(character)
        }
        if let open = opener { result += "\(open)\(buffer)" }   // 括号没闭合，原样留着
        return result.collapsingSpaces
    }

    private static let brackets: [Character: Character] = [
        "[": "]", "【": "】", "〔": "〕", "(": ")", "（": "）",
    ]

    /// 音质／来源标记。列表是「见过就删」的黑名单，宁可漏删也不误删。
    private static let noiseWords = [
        "码率", "音质", "无损", "杜比", "臻品", "母带", "试听", "官方版",
        "hires", "hi-res", "dolby", "atmos", "flac", "ape", "wav", "dsd",
        "explicit", "clean", "kbps", "320k", "128k", "192k", "256k",
    ]

    private static func isNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        return noiseWords.contains { lower.contains($0) }
    }

    // MARK: - 曲序

    /// 开头的曲序：`01 标题` / `01.标题` / `01-标题`。
    /// 只认 1～3 位数，四位数是年份（`1989 - Taylor Swift`）。
    static func leadingTrackNumber(_ text: String) -> (Int, String)? {
        let trimmed = text.trimmed
        var digits = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber, digits.count < 3 {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard let number = Int(digits), number > 0 else { return nil }
        // 数字后面必须跟分隔符，`1979` 这种整条是标题的不能被啃掉一截
        guard index < trimmed.endIndex else { return nil }
        let separator = trimmed[index]
        guard separator == " " || separator == "." || separator == "-" || separator == "_" else {
            return nil
        }
        let rest = trimmed[trimmed.index(after: index)...].trimmed
        guard !rest.isEmpty else { return nil }
        return (number, rest)
    }

    // MARK: - 切「艺人／标题」

    struct Split: Equatable, Sendable {
        var artist: String
        var title: String
        /// 与 `artist` 相对的那一半的原文（判断切向用）
        var counterpart: String
    }

    /// 两种写法，按分隔符区分——这不是猜，是两家客户端各自的导出命名：
    ///
    /// - `标题 - 艺人`（**带空格**的横杠）：QQ 音乐、网易云音乐下载下来就是这个样子
    ///   （`又到天黑 - 告五人.flac`、`晴天 - 周杰伦.flac`、`月牙湾 - F.I.R.飞儿乐团 […].mp4`）；
    /// - `艺人-标题`（**不带空格**的横杠）：第三方下载器的老写法
    ///   （`Imagine Dragons-Next To Me.mp4`、`Imagine Dragons-Thunder.flac`）。
    ///
    /// 两半哪半是艺人拿不准时以上面这条为准；调用方若已经从标签里知道艺人，
    /// 用 `splitCounterpart` 反过来纠正（见 `ImportNameGuess.resolvedTitle`）。
    static func splitArtistTitle(_ text: String) -> Split? {
        for separator in [" - ", " — ", " – "] {
            if let range = text.range(of: separator) {
                let left = String(text[..<range.lowerBound]).trimmed
                let right = String(text[range.upperBound...]).trimmed
                guard !left.isEmpty, !right.isEmpty else { continue }
                return Split(artist: right, title: left, counterpart: right)
            }
        }
        // 裸横杠：前后都不能是空格（上面那条已经把带空格的挑走了）
        if let range = text.range(of: "-") {
            let left = String(text[..<range.lowerBound]).trimmed
            let right = String(text[range.upperBound...]).trimmed
            if !left.isEmpty, !right.isEmpty {
                return Split(artist: left, title: right, counterpart: left)
            }
        }
        return nil
    }

    /// 标签已经给了艺人时，标题该取哪一半。
    ///
    /// 切向只有两种可能，用已知艺人对一下就能定死；两半都不是艺人（`我天生 - 有梦版`
    /// 这种「标题 - 版本」）时整条当标题，别把版本名切走。
    func resolvedTitle(knownArtist: String?) -> String? {
        guard let knownArtist, !knownArtist.isEmpty else { return title }
        guard let title, let counterpart = splitCounterpart else { return self.title }
        let known = knownArtist.folded
        if counterpart.folded == known { return title }           // 切对了
        if title.folded == known { return counterpart }           // 切反了
        return cleanedStem.isEmpty ? title : cleanedStem          // 两边都不是艺人
    }

    // MARK: - 目录

    /// 「像名字」的目录：不是根、不是主目录，不是 Music／下载 这类落脚点，
    /// 也不是临时目录、光盘子目录（`CD1`）这种一看就不是专辑名的。
    ///
    /// 宁可判不出来（回落「未知艺人／未知专辑」）也不能瞎填：填错了要用户一条条去改。
    static func isNameLikeFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.count >= 2, name.count <= 60 else { return false }
        guard name != "/", name != "." else { return false }
        if url.deletingLastPathComponent().path == url.path { return false }   // 根
        if url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path { return false }
        let lower = name.lowercased()
        if genericFolders.contains(lower) { return false }
        // `AmberImportTests-9B4A…`、`C4C6E1F2-…`：带 UUID 的一律不是专辑名
        if name.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil {
            return false
        }
        // 纯十六进制的一长串（缓存目录）
        if name.count >= 8,
           name.range(of: #"^[0-9A-Fa-f]+$"#, options: .regularExpression) != nil { return false }
        // 光盘子目录：`CD1` / `Disc 2` / `DVD 1`
        if lower.range(of: #"^(cd|disc|disk|dvd)\s?\d+$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private static let genericFolders: Set<String> = [
        "music", "musics", "音乐", "我的音乐", "media", "媒体", "downloads", "download",
        "下载", "desktop", "桌面", "documents", "文稿", "文档", "itunes", "itunes media",
        "library", "users", "volumes", "am", "qq音乐", "网易云音乐", "kugou", "酷狗音乐",
        "酷我音乐", "音乐下载", "temp", "tmp", "新建文件夹", "未分类",
    ]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 比对艺人名用：忽略大小写与前后空白
    var folded: String { trimmed.lowercased() }
    /// 摘掉括号后常留下连着的两个空格，并成一个
    var collapsingSpaces: String {
        split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ").trimmed
    }
}

private extension Substring {
    var trimmed: String { String(self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
