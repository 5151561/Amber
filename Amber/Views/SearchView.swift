import Foundation

// 搜索页的视图已经全部搬到 AppKit（计划 design-ref/appkit-rewrite-plan.md 阶段 5 批 C）：
// - 标题栏（居中搜索框 + 范围分段控件）：`Views/Shell/ContentToolbar.swift` 的
//   `SearchPageController` / `SearchPageFieldBinder`；
// - 状态机（提交链、最近搜索、资料库检索、在线检索）：`Views/Shell/SearchResultsModel.swift`；
// - 落地页：`Views/Shell/SearchLandingViewController.swift`；
// - 结果页：`Views/Shell/SearchResultsViewController.swift`（目录页那台引擎的一档）。
// 这个文件只剩下两边共用的范围枚举。

/// 搜索范围 tab。tag 值沿用 Music.app 的分派键（`search 规格` §4.1.2）：
/// Apple Music=1、Library=2、iTunes Store=3。Amber 不连 iTunes Store，
/// 映射为在线源=1、资料库=2；tab↔scope 同值映射（§4.1.7 currentSearchScope）。
enum SearchScopeTab: Int, CaseIterable, Identifiable {
    case online = 1
    case library = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .online: return "在线"
        case .library: return "资料库"
        }
    }

    /// Music 以「[tab名]」偏好串持久化默认 tab（§4.1.3 读取 / 写入）。
    var persistedKey: String { "[\(title)]" }

    static func from(persisted: String) -> SearchScopeTab {
        allCases.first { persisted == $0.persistedKey } ?? .online
    }

    /// 默认 tab 的偏好键。范围分段控件在 AppKit 工具栏那边（`SearchPageController`），
    /// 读写两侧都要用它。
    static let defaultScopeKey = "search-default-scope"
}
