import Combine
import SwiftUI

// MARK: - 列表尺寸（全局偏好）

/// 列表字号与行高的三档。
///
/// Music 里这不是某张表自己的设置，而是一条**全局偏好**：
/// `AMPTrackDisplayController.setupListFontFromPrefs:`（`[实测]`）每次都去
/// `listViewSizeToUse(prefs)` 问档位，再按档配三把字体（常规／粗体／等宽数字）与行高，
/// 然后把新字体逐个刷到所有可见单元格和列头上。三档的数值是写死在那段代码里的：
/// 小 11pt / 行高 18、中 12pt / 行高 22、大 14pt / 行高 40。
///
/// 数字列用等宽数字字体（`monospacedDigitSystemFont`），这样右对齐的时长、播放次数
/// 逐位对齐；Amber 的数字列本来就在用 `.monospacedDigit()`，与它同义。
enum ListViewSize: Int, CaseIterable, Identifiable {
    case small = 1, medium = 0, large = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    /// `[实测]` 三档字号
    var fontSize: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 12
        case .large: return 14
        }
    }

    /// `[实测]` 三档行高（`desiredRowHeight` 走的是同一套档位）
    var rowHeight: CGFloat {
        switch self {
        case .small: return 18
        case .medium: return 22
        case .large: return 40
        }
    }
}

/// 全局的列表尺寸偏好。跟 Music 一样是**应用级**的一条设置，不属于哪一张表，
/// 所以单独一个 store，而不是塞进 SongsTableSettings。
@MainActor
final class ListViewSizeStore: ObservableObject {
    @Published var size: ListViewSize {
        didSet { defaults.set(size.rawValue, forKey: Self.key) }
    }

    private let defaults: UserDefaults
    private static let key = "listViewSize"

    /// `defaults` 可注入，理由同`QQLoginStore`：测试宿主就是 App 本人，
    /// 写死 `.standard` 会让`xcodebuild test` 覆盖掉用户真实的偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.key) as? Int
        size = stored.flatMap(ListViewSize.init(rawValue:)) ?? .medium
    }

    var fontSize: CGFloat { size.fontSize }
    var rowHeight: CGFloat { size.rowHeight }
}

/// 歌曲表的列（宽度／显隐／顺序）、排序与筛选。
///
/// 这三样原先是 SongsTable 自己的 `@State`。Music 的「查看显示选项」是一扇**独立窗口**
/// （AX 实测 AXWindow 286×655、标题「显示选项」，由 `ViewNSMenuHelper.doShowHideViewOptions:`
/// 打开），跟表格不在同一棵视图树里；两边要改的是同一份状态，只能抬到共享对象上。
@MainActor
final class SongsTableSettings: ObservableObject {
    @Published var columns = SongsTableColumns()
    /// 排序列与升降序跨启动保留。
    ///
    /// Music 把它存在播放列表自己的 columnSet 里：`loadColumnsFromSet:`（`[实测]`）
    /// 装列时拿每一列的字段号跟**存档里的当前排序字段**比，对上了就取该列的
    /// `sortDescriptorPrototype`，再按存档里的升序标志决定
    /// 要不要换成 `NSSortDescriptor(key:ascending:false)`。
    /// 也就是说排序列与方向都是持久状态，不是每次开表都回到出厂值。
    @Published var sort = SongsTableSort() { didSet { saveSort() } }
    /// 筛选同样不是一次性的：`setCurrentFilterCategories:`（`[实测]`）把当前分类
    /// 连同 viewMode 写回播放列表对象，下次由 `updateFilteringState` 重新套上。
    /// Amber 没有播放列表对象承载它，落到偏好里。
    @Published var filter = SongsTableFilter.all { didSet { saveFilter() } }

    /// 「显示插图」：表格改成按专辑分组，最左多出一条 230pt 的插图列。
    @Published var showArtwork = false {
        didSet {
            columns.showsArtwork = showArtwork
            // 打开插图那一下把专辑排序模式抬到「按艺人排列专辑」：参照页未开插图时专辑列头是
            // 「专辑」，开着插图同屏核对到的插图列头是「按艺人排列专辑」，两次实测只有这样才都成立。[推]
            // 用户已经自己换过档（非「专辑」）就不动。init 里从存档恢复这一位时不算「打开」：
            // 那一下若也抬档，会在排序状态还没读回来之前先把默认排序写进存档、盖掉用户的。
            if showArtwork, !oldValue, !isRestoring, sort.albumMode == .album { sort.albumMode = .byArtist }
            saveArtwork()
        }
    }
    /// 「始终显示」：曲目行不够高也把封面整块画出来（组会被撑高）。
    /// Music 里它在「显示插图」关着时是灰的。
    @Published var alwaysShowArtwork = false { didSet { saveArtwork() } }
    /// 「插图大小」：滑杆三档 0/1/2
    @Published var artworkSize = 0 {
        didSet { columns.artworkSize = artworkSize; saveArtwork() }
    }
    /// 「显示曲目插图」：每行左边多一张小封面，行高顶到 54。
    /// 对应控制器上的 `showTrackArtwork`（`[实测]` `setShowTrackArtwork:`：
    /// 置位后把曲目封面列的 hidden 取反，并把表格样式切成 Plain）。
    @Published var showTrackArtwork = false {
        didSet { columns.showsTrackArtwork = showTrackArtwork; saveArtwork() }
    }

    private static let storageKey = "songsTableColumns"
    private static let artworkKey = "songsArtwork"
    private static let sortKey = "songsTableSort"
    private static let filterKey = "songsTableFilter"

    private let defaults: UserDefaults
    /// init 正在从存档恢复各项时为真；此时属性观察器里那些「用户刚动了开关」才该有的联动一律不做。
    private var isRestoring = true
    /// 通用页「显示 › 星级评分」「显示 › 歌曲列表复选框」两条的订阅：它们不在这张表
    /// 自己的状态里，改了要转成列变化，表格才知道该重建列
    /// （`SongsTableController` 是拿`columns` 前后相等与否判断的）。
    private var appSettingsObserver: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        columns.decode(defaults.string(forKey: Self.storageKey) ?? "")
        // 先把星级开关镜像进来，下面恢复排序列时才会把已经藏起来的评分列算作不可选
        columns.showsStarRatings = AppSettings.shared.values.showStarRatings
        columns.showsCheckboxes = AppSettings.shared.values.songListCheckboxes
        appSettingsObserver = AppSettings.shared.$values.sink { [weak self] values in
            self?.applyStarRatings(values.showStarRatings)
            self?.applyCheckboxes(values.songListCheckboxes)
        }
        let artwork = defaults.array(forKey: Self.artworkKey) as? [Int] ?? []
        showArtwork = artwork.first == 1
        alwaysShowArtwork = artwork.count > 1 && artwork[1] == 1
        artworkSize = artwork.count > 2 ? artwork[2] : 0
        showTrackArtwork = artwork.count > 3 && artwork[3] == 1
        // 存档里的排序列若已经被藏起来（或本来就不能排），跟 toggleVisible 一样退回默认列——
        // 否则表面上没有任何列在排序，列头的方向箭头也无处可画。
        let stored = defaults.array(forKey: Self.sortKey) as? [String] ?? []
        // 专辑排序模式跟排序列/方向存在同一条：它就是排序状态的一部分（Music 的插图列头
        // 显示的正是当前模式），单独一把钥匙只会在两处不同步时出怪。
        let mode = stored.count > 2
            ? Int(stored[2]).flatMap(SongsTableSort.AlbumSortMode.init(rawValue:)) : nil
        if let name = stored.first, let key = SongsTableColumns.Key(rawValue: name),
           columns.sortableColumns.contains(key) {
            sort = SongsTableSort(column: key, ascending: stored.count < 2 || stored[1] == "1",
                                  albumMode: mode ?? SongsTableSort().albumMode)
        } else if let mode {
            sort.albumMode = mode
        }
        if let name = defaults.string(forKey: Self.filterKey),
           let stored = SongsTableFilter(rawValue: name) {
            filter = stored
        }
        isRestoring = false
    }

    /// 列宽、显隐与顺序跨启动保留，与 Music 一致。
    func save() {
        defaults.set(columns.encoded, forKey: Self.storageKey)
    }

    private func saveSort() {
        defaults.set([sort.column.rawValue, sort.ascending ? "1" : "0",
                      String(sort.albumMode.rawValue)],
                     forKey: Self.sortKey)
    }

    private func saveFilter() {
        defaults.set(filter.rawValue, forKey: Self.filterKey)
    }

    private func saveArtwork() {
        defaults.set([showArtwork ? 1 : 0, alwaysShowArtwork ? 1 : 0, artworkSize,
                      showTrackArtwork ? 1 : 0],
                     forKey: Self.artworkKey)
    }

    /// 增删一列。排序依据被藏起来时退回默认列，否则表面上没有任何列在排序。
    func toggleVisible(_ key: SongsTableColumns.Key) {
        columns.toggleVisible(key)
        fallbackSortColumnIfNeeded()
        save()
    }

    /// 排序列没法用了（被藏起来或本来就不能排）就退回默认列。
    /// **专辑排序模式留着**——那一档管的是「专辑列怎么排」，跟现在哪一列在排序无关，
    /// 顺手清掉的话，用户下次点回专辑列会发现自己选的档位没了。
    private func fallbackSortColumnIfNeeded() {
        guard !columns.sortableColumns.contains(sort.column) else { return }
        let fallback = SongsTableSort()
        sort = SongsTableSort(column: fallback.column, ascending: fallback.ascending,
                              albumMode: sort.albumMode)
    }

    /// 「显示 › 星级评分」改了。
    ///
    /// 只动镜像那一位，**不调 `save()`**：列宽／显隐／顺序这份存档一个字节都没变，
    /// 开关再打开时那两列还是用户原来的宽度与位置。排序列正好是被藏起来的评分列时，
    /// 按 `toggleVisible` 那条老规矩退回默认列。
    private func applyStarRatings(_ shown: Bool) {
        guard columns.showsStarRatings != shown else { return }
        columns.showsStarRatings = shown
        fallbackSortColumnIfNeeded()
    }

    /// 「显示 › 歌曲列表复选框」改了。同样只动镜像那一位、**不调 `save()`**：
    /// 勾选列不进列存档（它不可隐藏、不可换位、宽度也不可调），
    /// 而且它本来就不能当排序依据，不必走 `fallbackSortColumnIfNeeded`。
    private func applyCheckboxes(_ shown: Bool) {
        guard columns.showsCheckboxes != shown else { return }
        columns.showsCheckboxes = shown
    }
}

// MARK: - 显示选项

/// 「显示选项」窗口（Music 的 doShowHideViewOptions:，从筛选菜单最下方的
/// 「查看显示选项」进）。2026-08-15 对 Music 1.7 的 AX 实录：
/// 顶部一个「排序方式：」弹出菜单，下面是分组的列勾选框，每组两列。
///
/// Music 在弹出菜单与分组之间还有「显示插图／始终显示／插图大小」三件——那是给插图列用的，
/// Amber 的表格没有插图列，摆上去就是三个点不动的控件，故不做；其余照实录补齐。
struct SongsViewOptionsView: View {
    @EnvironmentObject private var settings: SongsTableSettings
    /// 折叠状态只是窗口自己的显示态，不跟着列设置落盘。
    /// 出厂时「文件／分类／其他」是收起来的（Music 实测就这三组收起）。
    @State private var collapsed: Set<String> = ["文件", "分类", "其他"]

    private typealias M = MusicMetrics.SongsViewOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sortRow
            artworkRows
            Divider().padding(.horizontal, M.dividerInset)
            ScrollView {
                VStack(alignment: .leading, spacing: M.groupSpacing) {
                    // 星级评分关掉时那两项不列出来，分栏按剩下的项重排（见 columns.listed）
                    ForEach(SongsTableColumns.optionGroups) { group(settings.columns.listed($0)) }
                }
                .padding(.top, M.groupSpacing)
                .padding(.horizontal, M.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: M.windowWidth)
    }

    /// 「排序方式：」+ 弹出菜单（AX：标签 x=604、菜单 x=694 宽 122 高 20）
    private var sortRow: some View {
        HStack(spacing: M.sortLabelGap) {
            Text("排序方式：")
            Picker("", selection: $settings.sort.column) {
                ForEach(settings.columns.sortableColumns, id: \.self) {
                    Text(SongsTableColumns.title(for: $0)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: M.sortPickerWidth)
        }
        .padding(.horizontal, M.contentInset)
        .padding(.vertical, M.sortRowPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 插图三件（[AX] 勾选框 x=638、滑杆 605 宽 282）。
    /// 「始终显示」跟着「显示插图」启停——Music 里前者关着时它是灰的。
    private var artworkRows: some View {
        VStack(alignment: .leading, spacing: M.artworkRowSpacing) {
            Toggle("显示插图", isOn: $settings.showArtwork)
            Toggle("始终显示", isOn: $settings.alwaysShowArtwork)
                .disabled(!settings.showArtwork)
                .padding(.leading, M.artworkIndent)
            // Music 的这扇窗里没有这一条——`showTrackArtwork` 在它那儿由控制器/偏好从别处置位，
            // 歌曲页的显示选项只管专辑插图那三件。Amber 没有别的入口，先摆在这儿，
            // 位置也跟它是「插图」这一族的语义走。
            Toggle("显示曲目插图", isOn: $settings.showTrackArtwork)
            VStack(alignment: .leading, spacing: 0) {
                Text("插图大小：")
                    .foregroundStyle(settings.showArtwork ? Color.primary : Color.secondary)
                Slider(value: Binding(get: { Double(settings.artworkSize) },
                                      set: { settings.artworkSize = Int($0.rounded()) }),
                       in: 0...2, step: 1)
                    .disabled(!settings.showArtwork)
            }
            .padding(.top, M.artworkRowSpacing)
        }
        .padding(.horizontal, M.contentInset)
        .padding(.bottom, M.sortRowPadding)
    }

    @ViewBuilder
    private func group(_ group: SongsTableColumns.OptionGroup) -> some View {
        let isCollapsed = collapsed.contains(group.title)
        VStack(alignment: .leading, spacing: M.rowSpacing) {
            header(group, collapsed: isCollapsed)
            if !isCollapsed {
                HStack(alignment: .top, spacing: 0) {
                    checkboxes(group.leading)
                    checkboxes(group.trailing)
                }
            }
        }
    }

    /// 组名。「音乐」是常驻组，没有折叠三角；其余组都能折叠。
    @ViewBuilder
    private func header(_ group: SongsTableColumns.OptionGroup, collapsed isCollapsed: Bool) -> some View {
        if group.collapsible {
            Button {
                if isCollapsed { collapsed.remove(group.title) } else { collapsed.insert(group.title) }
            } label: {
                HStack(spacing: M.triangleGap) {
                    // Music 用的是 AppKit 那颗实心三角，不是 chevron
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: M.triangleSize))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(group.title)
                }
            }
            .buttonStyle(.plain)
        } else {
            // [AX] 「音乐」的组名左沿 612，与它下面的勾选框（611）平齐，不跟着三角内缩
            Text(group.title)
        }
    }

    private func checkboxes(_ keys: [SongsTableColumns.Key]) -> some View {
        VStack(alignment: .leading, spacing: M.rowSpacing) {
            ForEach(keys, id: \.self) { key in
                Toggle(isOn: Binding(
                    get: { settings.columns.isVisible(key) },
                    set: { _ in settings.toggleVisible(key) })) {
                    Text(SongsTableColumns.title(for: key))
                }
            }
        }
        .frame(width: M.checkboxColumnWidth, alignment: .leading)
    }
}
