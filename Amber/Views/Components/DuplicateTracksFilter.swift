import Foundation

// MARK: - 「显示重复项目」的视图过滤（spec §10.3）

/// 重复判定的两档。菜单上是同一项的两个面：不按修饰键是宽松档（res 30500 idx 16
/// `显示重复项目`），按住 Option 换成严格档（idx 17`显示完全重复的项目`）——
/// 「严格档 = 宽松档序号 + 1」在 `-[NativeContentController validateMenuItem:]`
/// 里就是一条 `cinc`，见 spec §10.3.1。`[实测]`
enum DuplicateMatch {
    /// 宽松档。
    case loose
    /// 严格档。
    case exact
}

/// 「显示重复项目」只过滤显示，**不改数据、不自动合并、不自动删**（spec §10.3 结尾，
/// 处置是手动的，见 §10.4 的 `Keep Duplicate` / `Delete Duplicate`）。所以这里是一段
/// 纯函数：进来一串曲目，出去还是那一串的子集，顺序原样。
///
/// ⚠️ **两档各比较哪些字段是 `[推]`，不是实测。**`-[NativeContentController
/// doShowHideDuplicates:]` 在 ObjC 侧只把「宽松/严格」压成一个`bool` 交给 C++ 引擎
/// **两档各比较哪些字段在 C++ 虚函数体里，静态分析拿不到**
/// （spec §10.3.2 记的阻塞 ①，ObjC↔C++ 跨语言边界）。顺带记一条批次 45 的翻案：
/// `duplicatesAll` / `duplicatesExact` **不是这两档的 pref key**，是「重复项视图」
/// 这个导航目的地的名字（`__cfstring` 里一串目的地名中的两个），拿它们去找判据是找错了门。
/// spec 末尾还专门
/// 挂了一条 ⚠️ 说「不要把坊间说法写进 spec」。那条仍然成立——但复刻这一侧必须给出一个
/// 能跑的判据，这里选的就是流传最广、也最容易被观察到的那一版口径：
///
/// - 宽松 = 曲名 + 艺人
/// - 严格 = 再加专辑 + 时长（秒，取整）
///
/// **它是我们的选择，不是 Music 的事实。** 哪天 C++ 侧被读出来了（或实机对比坐实了），
/// 只改这一处 `key(for:match:)` 就够——菜单、页面态、流水线都不认识这条判据。
enum DuplicateTracksFilter {

    /// 只留下「所在分组条数 ≥ 2」的曲目，**保持传入顺序**。
    ///
    /// 顺序必须原样：这一档是过滤视图，用户看到的仍是他自己那张表的排法，
    /// 不能因为「按组聚拢好看」就在这里重排——排序是流水线最后一步的事。
    static func duplicates(in tracks: [Track], match: DuplicateMatch) -> [Track] {
        let keys = tracks.map { key(for: $0, match: match) }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(keys.count)
        for key in keys { counts[key, default: 0] += 1 }
        return zip(tracks, keys).compactMap { track, key in
            (counts[key] ?? 0) >= 2 ? track : nil
        }
    }

    /// 分组键。`[推]`，理由见类型注释。
    ///
    /// 字段之间用 `\u{1F}`（单元分隔符）拼：它不会出现在曲名/艺人/专辑里，
    /// 免得「艺人叫 `A-B` 的曲名`C`」和「艺人`A` 的曲名`B-C`」撞成一组。
    private static func key(for track: Track, match: DuplicateMatch) -> String {
        var parts = [track.title.duplicateKeyForm, track.artistName.duplicateKeyForm]
        if match == .exact {
            parts.append(track.albumName.duplicateKeyForm)
            // 时长取整到秒：同一首歌的两份文件解出来的时长常差几十毫秒，
            // 按浮点原值比等于严格档永远判不出重复。
            parts.append(String(Int(track.duration.rounded())))
        }
        return parts.joined(separator: "\u{1F}")
    }
}

private extension String {
    /// 进分组键之前的规范化：首尾空白、大小写、变音符号、全半角的差别都不该
    /// 把「同一首歌的两份记录」拆到两组去。一律用系统的 `folding(options:locale:)`，
    /// 不自己建映射表（AGENTS.md「先用系统默认值」）。
    var duplicateKeyForm: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }
}

/// 那颗菜单项的三态标题（spec §10.3.1）。
///
/// 单拎出来是为了能离线自证：标题在 Music 那边是 `-[NativeContentController
/// validateMenuItem:]` 里现算的，我们这边同样现算，而「按住 Option 时它显示什么」
/// 靠鼠标是验不了的（菜单已经拉开、修饰键又只在 validate 那一刻问一次）。
/// 规则这半截不该跟着一起被挡在测试之外——同 `ImportReplacePrompt` 的分法。
enum DuplicatesMenuItem {

    /// 三条分支与 ASM 里的三支一一对应（res 30500，`[实测]`+`[RES]`）：
    ///
    /// - 正在看重复项（原版用一个布尔位记这个状态）→ idx 18，
    ///   **此时不再看 Option**；
    /// - 否则按住 Option → idx 17（`cinc`：宽松档序号 + 1）；
    /// - 否则 → idx 16。
    static func title(showingDuplicates: Bool, optionDown: Bool) -> String {
        if showingDuplicates { return "显示所有项目" }
        return optionDown ? "显示完全重复的项目" : "显示重复项目"
    }
}
