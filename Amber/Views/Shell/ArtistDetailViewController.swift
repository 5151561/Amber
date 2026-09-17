import AppKit

// MARK: - 艺人页（目录形态）—— 计划阶段 4 最后一批
//
// ## 为什么这一版是「目录页」而不是「详情表格」
//
// 上一版把艺人页做成了 `TrackTableViewController` 的子类（圆头像头部 + 一列热门歌曲 +
// 专辑网格），那是照搬旧 SwiftUI 版的形状。Music 的艺人页根本不长这样：
// 实机（Music 1.7，2026-09-06 告五人页）自上而下是：钉住的满幅封面背景 +
// 「最新發行 / 熱門歌曲」并排带 + 「專輯」「單曲和 EP」「現場演出專輯」「相似藝人」货架
// ——各段都是**目录页的段**，见 `ArtistPageModel` 的段表。
//
// 规格那边也是这个结论：艺人页容器 `ArtistDetailPageView` 与主页/新发现/广播共用同一台
// 状态机 `CatalogPagePresenter<Page>`（`artistpage 规格` §0 的边界那段明写
// 「页面容器本身、状态机是 `catalogpage` scope 的题目」；那台引擎的规格在
// `catalogpage 规格` §1）。也就是说 Music 自己就是「艺人页 = 目录页的一种」。
//
// 所以这一版就是一句话：**`CatalogPageViewController` 吃`ArtistPageModel`**。
// 段怎么组在 `ArtistPageModel`；艺人页比别页多一样的是**钉住的封面背景**
// （图不随文稿滚，滚起来从清晰变糊，见 `ArtistBackdropView`）——由
// `makePinnedBackdrop()` 提供给宿主，图片随内容状态补灌。

@MainActor
final class ArtistDetailViewController: CatalogPageViewController {

    /// 与宿主里那份同一个实例：背景层的封面地址要从页面模型这边拿。
    private let pageModel: ArtistPageModel

    private weak var backdrop: ArtistBackdropView?

    /// 标题栏那颗「共享」要交出这位艺人的网页地址，所以这一份留着。
    private let artist: Artist

    init(appState: AppState, artist: Artist) {
        let model = ArtistPageModel(appState: appState, artist: artist)
        self.pageModel = model
        self.artist = artist
        super.init(appState: appState, model: model)
    }

    /// [PX] Music 的艺人页标题栏与页面里都不摆标题，顶上直接是那张大图。
    override var showsPageTitle: Bool { false }

    /// [PX] 大图从**窗口顶**开始铺（穿过标题栏那 52），所以顶部内缩置 0、
    /// `automaticallyAdjustsContentInsets` 关掉，由钉住的背景层自己把那一条画满。
    override var extendsUnderTitlebar: Bool { true }

    /// 艺人属于某一个音源，换源不该把这一页重拉成别人的艺人；
    /// 标题栏那枚音乐源切换胶囊也就不摆了。
    override var followsSelectedProvider: Bool { false }

    /// 摆。[AX] `catalog-artist.json` 实测标题栏右端：共享 x=1388、更多 x=1424
    /// （与 `playlist-detail` 同一组坐标）。
    ///
    /// 现状注明：这一页还没有自己的 `pageMoreEntries`（本批不给艺人页接菜单内容），
    /// 所以点下去弹的是窗口那条兜底项——`MainWindowController.menuNeedsUpdate:` 里那条
    /// 「在当前音乐源中搜索」。这正是 [实测] §10.1 那对分工的自然结果：
    /// 摆不摆（`playlistShowsToolbarActions`）与弹什么（`actionMenuFromSender:`）
    /// 本来就是两件事（macOS 27 / 26A5425a 基线）。接上内容是后续批次的事。
    override var pageShowsToolbarActions: Bool { true }

    /// [AX] `catalog-artist.json` 实测那颗「共享」x=1388 确实在，交出去的是这位艺人在
    /// 音源网页版的公开页面（`ProviderWebLink.artist`）。给不出就整件不摆——
    /// 判据见 `MainWindowController.makeIdentifiers()`。
    override var pageShareItems: [Any] { [artist.webShareURL].compactMap { $0 } }

    /// 满幅封面垫在 scroll view 底下（宿主负责插入与转发滚动位置）。
    override func makePinnedBackdrop() -> (any CatalogPageBackdroping)? {
        let backdrop = ArtistBackdropView()
        self.backdrop = backdrop
        return backdrop
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 内容到位后把封面喂给背景层。hero 那件卡上已经不装图了
        // （图钉在背景层，不随文稿滚），宽幅页头图优先、退回方头像——
        // 取哪张的逻辑与数据源对齐：见 `ArtistPageModel.backdropArtworkURL`。
        observers.observeNow({ [pageModel] in pageModel.state }) { [weak self] state in
            guard case .content = state, let backdrop = self?.backdrop else { return }
            backdrop.setArtwork(url: self?.pageModel.backdropArtworkURL)
        }
    }
}
