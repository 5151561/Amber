import Foundation

/// 资料库搜索的切分、拼音与查询串：入库侧和查询侧共用的那几个纯函数。
///
/// **为什么不能把搜索词直接递给 FTS5。** 默认的 `unicode61` 分词器按「字母 / 数字」聚词，
/// 而整串汉字之间没有分隔符，于是**一整串汉字被当成一个 token**：
///
/// ```
/// MATCH '帶你飛' → 命中      MATCH '你飛' → 不命中
/// MATCH '七里香' → 命中      MATCH '里香' → 不命中
/// ```
///
/// 今天七处 `localizedCaseInsensitiveContains` 搜得到的东西，换成裸 FTS5 反而搜不到——
/// 那不是升级，是功能回归。
///
/// **解法是「空格插值 + 短语邻近」。** 入库时把汉字 / 假名 / 谚文逐字垫空格（`segment`），
/// 一个字就是一个 token；查询时**用同一个 `segment` 切**，再按用户敲的空白分组、组内并成
/// 一个引号短语（`ftsQuery`）。FTS5 的短语要求词元位置紧邻，于是 `"你 飛"` 精确命中
/// `帶 你 飛`，而 `"飛 你"` 一条都不命中——**邻近约束就是「没退化成 AND」的那道闸**，
/// `LibrarySearchTests` 里的反序用例守的就是它。
///
/// 拼音（`pinyinTokens`）是顺手白送的**附加**召回通道：正文那条 unigram 通道不受影响，
/// 多音字读错最多少一条召回，不会产生假阳性；简繁互搜（`带你飞` ↔ `帶你飛`）也是它白送的。
///
/// **一个有意的行为变化，别当 bug 改回去**：拉丁文字从「任意子串」收窄为「词前缀」。
/// 今天 `contains` 让 `aylor` 也能搜到 `Taylor`，FTS5 做不到（`taylor` 能）。
/// Apple Music 自己就是词前缀匹配，这算更正确，但它确实是个变化，
/// `LibrarySearchTests.testLatinMatchesWordPrefixNotArbitrarySubstring` 专门钉住它。
enum LibrarySearch {

    // MARK: - 字符判定

    /// 汉字（含扩展 A / B 起、兼容区）。**只有汉字**产拼音，假名谚文不产。
    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)       // 扩展 A
            || (0x4E00...0x9FFF).contains(value)    // 基本区
            || (0xF900...0xFAFF).contains(value)    // 兼容汉字
            || (0x20000...0x3FFFF).contains(value)  // 扩展 B 及以后
    }

    /// 需要逐字垫空格的文字：汉字 + 平 / 片假名 + 谚文。
    ///
    /// 这三种文字的共同点是「词之间不写空格，但单字本身就有意义」，所以按字建索引既能
    /// 搜子串又不会把索引撑爆。泰文 / 高棉文同样不写空格却没有单字语义，不在此列——
    /// 它们退化成整串一个 token，和今天一样搜不动，这是已知的、没有用户的缺口。
    private static func isIdeographOrKana(_ value: UInt32) -> Bool {
        isHan(value)
            || (0x3040...0x30FF).contains(value)    // 平假名 + 片假名
            || (0xAC00...0xD7AF).contains(value)    // 谚文音节
    }

    // MARK: - 切分

    /// 表意文字逐字垫空格，拉丁与数字保持整词。
    ///
    /// 拉丁词不拆的原因有两条：它本来就已经被分词器切成 token 了，再拆只会把
    /// `Taylor` 变成六个单字母 token（索引膨胀、噪声召回）；而且前缀查询靠的正是整词。
    ///
    /// **入库与查询必须调同一个它**。两侧切法差一个空格，位置序列就对不上，
    /// 短语邻近约束当场失效——而失效的表现是「搜不到」，不是报错，没测试就发现不了。
    static func segment(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if isIdeographOrKana(scalar.value) {
                out += " \(scalar) "
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - 拼音

    /// 给每一段**汉字连续串**产三种拼音形态：空格全拼 / 连写全拼 / 首字母。
    ///
    /// ```
    /// pinyinTokens("周杰倫 七里香")
    /// → ["zhou jie lun", "zhoujielun", "zjl", "qi li xiang", "qilixiang", "qlx"]
    /// ```
    ///
    /// 两条实测才发现的坑，都在这段代码里，改它之前先看一眼：
    ///
    /// 1. **必须按「汉字连续段」产，不能对整串产。** 整串产会得到 `zjlqlx`，而用户敲的
    ///    `qlx` 是它**中间的子串**，前缀匹配不上。按段产得 `zjl` 和 `qlx` 两个 token 才命中。
    ///    所以这里遇到非汉字就 `flush()`，不是攒到最后一次转。
    /// 2. **空格全拼之外必须另存连写全拼。** 只存 `qi li xiang` 时，用户敲 `qili`
    ///    前缀匹配的是 token `qi`，`qili` 比它长，匹不上。
    ///
    /// 读音准确度不用操心：`CFStringTransform` 是按整段转的，多音字带得上上下文
    /// （`长江` / `长大`）；退一万步读错了也只是少一条召回，正文 unigram 那条路照走。
    static func pinyinTokens(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""

        func flush() {
            defer { run = "" }
            guard !run.isEmpty else { return }
            let buffer = NSMutableString(string: run) as CFMutableString
            // 先转注音再去声调符：`kCFStringTransformMandarinLatin` 吐的是带声调的
            // `zhōu jié lún`，不去掉的话用户永远敲不出那几个带调字母。
            guard CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false),
                  CFStringTransform(buffer, nil, kCFStringTransformStripDiacritics, false) else {
                return
            }
            let syllables = (buffer as String).lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
            guard !syllables.isEmpty else { return }
            out.append(syllables.joined(separator: " "))        // qi li xiang
            guard syllables.count > 1 else { return }           // 单字没有「连写」「首字母」可言
            out.append(syllables.joined())                      // qilixiang
            out.append(String(syllables.compactMap(\.first)))   // qlx
        }

        for scalar in text.unicodeScalars {
            if isHan(scalar.value) {
                run.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    // MARK: - 索引正文

    /// 写进 `search_index` 的一行：正文按字段分列，拼音合成一列。
    ///
    /// 四个可搜对象（track / album / playlist / artist）共用这几列，用不上的写空串。
    struct IndexRow {
        let name: String
        let artist: String
        let album: String
        let phonetic: String
    }

    /// 入库侧唯一的出口：正文各段各自走 `segment`（与 `ftsQuery` 同一个），
    /// 三段的拼音并进 `phonetic`。
    ///
    /// **正文为什么按字段出列，而不是拼成一串。** 先前是一列 `body`、字段之间垫
    /// `" ⧉ "`：`unicode61` 把那个符号当分隔符丢掉，而丢掉的符号**不占 token 位置**，
    /// 于是短语邻近能跨字段成立——实测搜 `飛周` 命中「帶你飛 / 周杰倫」这种
    /// 曲名末字接艺人首字的假阳性。FTS5 的列语义恰好给出要的那条规则：
    /// **短语不跨列、AND 跨列**，也就是「字段内要相邻、字段之间只要都出现过」。
    /// `LibrarySearchTests` 里 `飛周` / `倫葉` 两条零命中守的就是它。
    ///
    /// **`phonetic` 为什么反而可以合成一列。** 拼音查询永远不会变成短语：`ftsQuery`
    /// 对拉丁词是一词一组、组间用 `AND` 连（`dai ni fei` →
    /// `"dai"* AND "ni"* AND "fei"*`），压根没有邻近约束，也就没有跨字段泄漏可言。
    /// 合成一列还省掉三列稀疏索引。
    static func indexRow(name: String, artist: String = "", album: String = "") -> IndexRow {
        IndexRow(
            name: segment(name),
            artist: segment(artist),
            album: segment(album),
            phonetic: (pinyinTokens(name) + pinyinTokens(artist) + pinyinTokens(album))
                .joined(separator: " "))
    }

    // MARK: - 查询串

    /// **唯一**允许生成 MATCH 表达式的地方；返回 nil 表示空查询，调用方走「不加筛选、
    /// 返回全部」那条路（实测裸空串进 MATCH 报 `fts5: syntax error near ""`）。
    ///
    /// 三条规则：
    ///
    /// - **每一段都用双引号包起来**。FTS5 的查询串是有语法的，`*` `^` `-` `AND` `NEAR` `(`
    ///   都是元字符，用户在搜索框里随手敲一个就是一条 `SQLITE_ERROR`。引号把它们全中和掉，
    ///   段内的 `"` 按 FTS5 的规矩写成 `""`。
    /// - **分组依据是用户原串里的空白，不是「相邻的表意文字」。** 先按用户敲的空白切 chunk，
    ///   每个 chunk 各自过 `segment`，一个 chunk 出一组。切出多个 token 的组是引号短语
    ///   求邻近（`"你 飛"`），只切出一个 token 的组加 `*` 求前缀（`"taylor"*`）。
    ///   短语后面不加 `*`：`你飛` 要的是「紧挨着」，不是「以它开头」。
    /// - 组与组之间是 `AND`：`Taylor 你飛` = 既有 `taylor` 前缀词、又有 `你飛` 这个相邻短语。
    ///
    /// **为什么分组依据非得是用户敲的空白。** `segment` 吐出来的空格有两种来源：用户自己
    /// 打的，和它为表意文字垫出来的。从前这里只看 token 相邻、不看来源，于是
    /// `周杰倫 帶你飛` 被并成**一个**短语 `"周 杰 倫 帶 你 飛"`——而正文已经按字段分了列，
    /// **短语不跨列**，一个横跨曲名与艺人的短语在任何一列里都不成立，零命中。
    /// 「艺人名 + 曲名」是最常见的搜法之一，那不是缺口是窟窿。
    /// 按用户敲的空白分组之后它成了 `"周 杰 倫" AND "帶 你 飛"`：**AND 跨列**，正是要的语义。
    ///
    /// 代价是 `飛 周`（用户自己在两字之间敲了空格）会命中，而 `飛周`（连着敲）照旧零命中。
    /// 这**不是**放回了那条跨字段假阳性：用户显式敲空格就是在说「这是两个词」，语义本就该是
    /// AND；假阳性防的是**没敲空格**时短语偷偷跨过字段边界，那道闸由分列本身守着，没松。
    /// `LibrarySearchTests` 里这两条是成对写的，它们的对比就是这条规则的全部意义。
    static func ftsQuery(_ input: String) -> String? {
        let groups = input.split(whereSeparator: \.isWhitespace)
            .map { segment(String($0)).split(separator: " ").map(String.init) }
            // 守住「空组」：`\(body)` 拼出来的 `""*` 是 FTS5 语法错，而空查询的正解是
            // 返回 nil 让调用方不加筛选。今天 `segment` 对无空白的非空 chunk 不会吐空，
            // 但它一旦学会丢弃字符（比如加个控制符过滤），这里就是第一个踩雷的地方。
            .filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }

        return groups.map { group in
            let body = group.joined(separator: " ").replacingOccurrences(of: "\"", with: "\"\"")
            return group.count > 1 ? "\"\(body)\"" : "\"\(body)\"*"
        }.joined(separator: " AND ")
    }
}
