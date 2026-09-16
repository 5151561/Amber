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

    private static var storage: [String: [SBS_TextContentLayer.RowMetrics]] = [:]
    private static var use: [String: UInt64] = [:]
    private static var clock: UInt64 = 0

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
