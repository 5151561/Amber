import AppKit

/// `SBS_TextContentLayer.measureRows` 的结果缓存。
///
/// 那个函数是**排版行的量度**（宽、高、ascent，外加一条给落点查询用的 `CTLine`），
/// 而它有两类调用方：
///
/// - `sizeThatFits(width:)` —— 只要宽高。行几何 `recomputeLineFrames`
///   对**全表每一行**调一次，一次翻行至少跑两遍（`relayout` 一次、
///   随后的 `collapseDocument` / `scrollToSelectedLine` 一路上还会再来）；
/// - `rebuild(width:)` —— 真的要 `CTLine`，去问每个音节的横向落点。
///
/// 只为量宽高就 `NSAttributedString` + 逐 fragment `CTLineCreateWithAttributedString`
/// 太贵。折行那一步（`LyricsTextLayout.wrap`）本来就有缓存，缺的是它后面那段
/// CoreText 排版框——补上这张表之后，测量路径全是字典命中，`CTLine` 只在
/// (文本, 字体, 宽度) 第一次出现时建一次，之后连 `rebuild` 一起复用。
///
/// **结果与不带缓存时逐像素相同**：命中与否返回的是同一批 `RowMetrics` 值，
/// 没有任何近似或重新计算（对照断言见 `LyricsLineGeometryTests.testMeasureRowsMatchesCoreTextReference`）。
enum LyricsRowMetricsCache {

    /// 上限与 `LyricsTextLayout.wrapCacheLimit` 同量级：一行正文一条，
    /// 加上换宽度时的旧档，1024 条足够一首长歌在窗口拉动期间不抖。
    static let limit = 1024

    // 下面几张表标 `nonisolated(unsafe)`，理由与代价都写在这里，别当橡皮擦看：
    //
    // 事实：它们只在主线程的排版路径上被摸。[实测 2026-09-17] 在歌词那 5 个
    // `layoutSublayers` 覆写里插 `dispatchPrecondition(condition: .onQueue(.main))`，
    // 装机后带歌词播放 35 秒，一次都没触发。
    //
    // 那为什么不用 `@MainActor` 把这件事写出来——试过了，走不通：调用方是
    // `SBS_TextContentLayer` 那一族 `CALayer` 子类，而 SDK 里 `CALayer` 没有
    // `@MainActor` 标注（`NSView` 有，所以视图层没这问题）。给子类标上之后，
    // `layoutSublayers` / `init()` 这些覆写仍然跟着父类是非隔离的，体内一碰 `self`
    // 就是「sending 'self'」——问题只是从这里挪到了那里。
    //
    // 所以 SDK 给 `CALayer` 补上 `@MainActor` 之前，这里只能是断言而不是证明。
    nonisolated(unsafe) private static var storage: [String: [SBS_TextContentLayer.RowMetrics]] = [:]
    nonisolated(unsafe) private static var use: [String: UInt64] = [:]
    nonisolated(unsafe) private static var clock: UInt64 = 0

    static func key(text: String, font: NSFont, width: CGFloat) -> String {
        [text, font.fontName,
         String(describing: font.pointSize),
         String(describing: width)].joined(separator: "\u{1}")
    }

    static func value(for key: String) -> [SBS_TextContentLayer.RowMetrics]? {
        guard let cached = storage[key] else { return nil }
        touch(key)
        return cached
    }

    static func store(_ rows: [SBS_TextContentLayer.RowMetrics], for key: String) {
        storage[key] = rows
        touch(key)
        evictIfNeeded()
    }

    private static func touch(_ key: String) {
        clock &+= 1
        use[key] = clock
    }

    /// 超上限丢最旧的一半（同 `LyricsTextLayout` 的折行缓存），不整张清空。
    private static func evictIfNeeded() {
        guard storage.count > limit else { return }
        let victims = use.sorted { $0.value < $1.value }.prefix(storage.count / 2)
        for (key, _) in victims {
            storage.removeValue(forKey: key)
            use.removeValue(forKey: key)
        }
    }
}
