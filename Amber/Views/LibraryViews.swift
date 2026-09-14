import SwiftUI

// MARK: - 排序

/// 资料库专辑网格的排序键。键值照 [实测] 内容域排序枚举
/// （`library 规格` §4.1：3=标题、7=年份、8=流派、90=评分；4=导演是 MV 域专属），
/// 该枚举的回收处是 MV/TV 网格，资料库专辑网格自己的排序面未能定值——
/// 键值沿用内容域、取值域按 Album 字段落地，标 [推]。
enum LibraryGridSortKey: Int, CaseIterable, Identifiable {
    case title = 3
    case year = 7
    case genre = 8
    case rating = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .title: return "标题"
        case .year: return "年份"
        case .genre: return "流派"
        case .rating: return "评分"
        }
    }
}

/// 专辑网格的排序状态（方向语义同 [实测] `currentSortDirection`：0=升序、1=降序）。
struct LibraryGridSort: Equatable {
    var key: LibraryGridSortKey = .title
    var ascending = true
}

// MARK: - 标题栏三件套（标题 + 筛选 + 搜索）

// 资料库各页的标题栏同构 [AX]（Music 1.7 专辑/艺人/最近添加/歌曲四页）：
// 页面标题在标题栏左侧（221.5 起、13pt secondary），右端是筛选槽（1208 宽 40）
// 与搜索槽（1248 宽 217，字段 211×38）。
//
// 这三件已经搬到 AppKit 工具栏：`Amber/Views/Shell/ContentToolbar.swift` 的
// `LibraryPageController`（形态）+`LibraryFilterMenuController`（☰ 菜单，
// 结构仍照 [实测] `library 规格` §4.2 的「每页筛选固定两项」与 §4.3 的
// `AMPSortableMenuHandler.refreshItemsInMenu:`）。取值从各页的`@State` 提到了
// `LibraryPageModel`——标题栏与页面是两棵树，必须看同一份。

// MARK: - 最近添加

/// 「最近添加」的日期分段。Music 实测有「昨天 / 本周」两档
/// （recently-added.{json,png}，标题栏标题也是分段名）；其余档按日历语义补齐 [推]。
enum RecentAddedBucket: Int, CaseIterable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, thisYear, earlier

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .lastWeek: return "上周"
        case .thisMonth: return "本月"
        case .thisYear: return "今年"
        case .earlier: return "更早"
        }
    }

    /// 判段。今天 > 昨天 > 本周 > 上周 > 本月 > 今年 > 更早，命中的是最具体的一档
    /// （昨天与本周重叠时归昨天）。`now` 供测试注入，默认当前时刻。
    static func bucket(of date: Date, calendar: Calendar = .current,
                       now: Date = Date()) -> RecentAddedBucket {
        func daysAgoStart(_ offset: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: now)!)
        }
        if date >= daysAgoStart(0) { return .today }
        if date >= daysAgoStart(-1) { return .yesterday }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        if date >= weekStart { return .thisWeek }
        if date >= calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)! { return .lastWeek }
        if date >= calendar.dateInterval(of: .month, for: now)!.start { return .thisMonth }
        if date >= calendar.dateInterval(of: .year, for: now)!.start { return .thisYear }
        return .earlier
    }
}

// MARK: - 艺人页（已迁移至 AppKit：LibraryArtistsViewController.swift）
