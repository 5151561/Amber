import AppKit

// MARK: - 搜索结果页（目录页引擎的一档）—— 计划阶段 5 批 C
//
// 结果页与主页/新发现/广播/艺人页是同一台引擎：一页分区货架（艺人/专辑/歌曲/播放列表/MV）
// + 段头 + 三态 + 悬浮翻页箭头，全部由 `CatalogPageViewController` 提供，
// 这里只把三个开关拨到搜索页该有的样子。段怎么组见 `SearchResultsModel.sections()`。
//
// 与艺人页当初的做法一致（`ArtistDetailViewController`）：引擎认 `CatalogPageModelProviding`，
// 换个数据源就是另一页，不再多写一套滚动/复用/悬浮。

@MainActor
final class SearchResultsViewController: CatalogPageViewController {

    init(appState: AppState, model: SearchResultsModel) {
        super.init(appState: appState, model: model)
    }

    /// [PX] Music 的搜索页（落地与结果都是）没有页面大标题，标题栏中央就是搜索框本身。
    override var showsPageTitle: Bool { false }

    /// 内容照常从标题栏底下滚过（`automaticallyAdjustsContentInsets` 给的那 52），
    /// 不像艺人页要把图铺到窗口顶。
    override var extendsUnderTitlebar: Bool { false }

    /// 首段标题上面那 14：旧版 SwiftUI 结果页的 `.padding(.top, 14)`，一个不改。
    /// 引擎默认 0 是给艺人页那张满幅 hero 的（图要顶着窗口顶），这一页没有 hero。
    override var firstSectionTopGap: CGFloat { 14 }

    /// 标题栏归 `SearchPageController` 摆（居中搜索框 + 范围分段控件），
    /// 这里不摆音乐源胶囊；「换了音乐源就重搜」也不走引擎那条，
    /// 由 `SearchResultsModel` 自己订阅 `selectedProvider`（只有在线范围才重搜）。
    override var followsSelectedProvider: Bool { false }
}
