import Foundation

// MARK: - Apple Music 三页的栏目结构

/// 主页 / 新发现 / 广播的**栏目名、卡型、顺序**，照 Apple Music 实测写死
/// （2026-09-03 抓 music.apple.com/cn/{home,new,radio}，已登录中国区账号）。
/// 音源不参与决定页面长什么样，只按 `CatalogSlot` 交数据；交不出来的段整段省掉。
///
/// 没复刻的段（音源没有对应数据，或需要 Amber 还没有的卡型）：
/// 主页的「演唱会」(bubble tip 定位卡，两家音源都没有演出数据)；
/// 新发现的「即将发布」（两家都没有预发行专辑接口）。
enum CatalogPages {

    /// 主页（ListenNowPageIntent）。实测 24 段，编排是：前 9 段固定骨架，
    /// 第 10 段起是长尾——曲风/年代/「更多类似作品 + 种子」交替，段名就是种子或维度本身。
    /// 长尾几乎全是方卡、里面**主要装专辑**；只有专属精选推荐/为你制作的歌单是海报卡。
    static func listenNow(recent: [Track]) -> [CatalogPageSection] {
        var sections: [CatalogPageSection] = [
            .init(id: "top-picks", title: "专属精选推荐", style: .poster, slot: .topPicks),
            .init(id: "recents", title: "最近播放", style: .squares(rows: 1), slot: .recentlyPlayed, showsChevron: true),
            .init(id: "mandopop", title: "华语流行乐", style: .squares(rows: 1), slot: .tagged(.mandopop)),
        ]
        if !recent.isEmpty {
            sections.append(.init(id: "more-like-1", style: .squares(rows: 1),
                                  slot: .moreLikeThis(Array(recent.prefix(5))), showsChevron: true))
        }
        sections += [
            .init(id: "made", title: "为你制作的歌单", style: .poster, slot: .madeForYou),
            .init(id: "stations", title: "为你精选的电台", style: .stations, slot: .stations),
            .init(id: "moods", title: "找到迎合心情的内容", style: .stations, slot: .moodStations),
            .init(id: "latest", title: "为你推荐最新作品", style: .squares(rows: 1), slot: .latestReleases, showsChevron: true),
            .init(id: "recommended", title: "推荐歌单", style: .superHero, slot: .recommendedPlaylist),
            .init(id: "tens", title: "2010 年代", style: .squares(rows: 1), slot: .tagged(.tens)),
            .init(id: "alternative", title: "华语另类音乐", style: .squares(rows: 1), slot: .tagged(.alternative)),
            .init(id: "jpop", title: "日本流行乐", style: .squares(rows: 1), slot: .tagged(.jpop)),
            .init(id: "kpop", title: "韩国流行乐", style: .squares(rows: 1), slot: .tagged(.kpop)),
            .init(id: "cantopop", title: "广东歌", style: .squares(rows: 1), slot: .tagged(.cantopop)),
            .init(id: "western", title: "欧美流行乐", style: .squares(rows: 1), slot: .tagged(.western)),
            .init(id: "noughties", title: "2000 年代", style: .squares(rows: 1), slot: .tagged(.noughties)),
            .init(id: "electronic", title: "电子音乐", style: .squares(rows: 1), slot: .tagged(.electronic)),
            // 末段：Music 是「演唱会」（气泡提示，音源没有演出数据，不复刻）+「音乐回忆」
            .init(id: "memories", title: "音乐回忆：你的热门音乐", style: .poster, slot: .musicMemories),
        ]
        return sections
    }

    /// 新发现（BrowsePageIntent）。段名与顺序照 music.apple.com/cn/new 实测。
    static let browse: [CatalogPageSection] = [
        .init(id: "hero", style: .hero, slot: .featured),
        .init(id: "spotlights", title: "瞩目之星", style: .squares(rows: 1), slot: .artistSpotlights, showsChevron: true),
        .init(id: "new-songs", title: "新歌精选", style: .trackColumns(rows: 4), slot: .newSongs, showsChevron: true),
        .init(id: "this-week", title: "本周新发行", style: .squares(rows: 1), slot: .newReleases(page: 0), showsChevron: true),
        .init(id: "recent", title: "新近发布", style: .squares(rows: 1), slot: .newReleases(page: 1), showsChevron: true),
        .init(id: "playlists", title: "歌单已更新", style: .squares(rows: 2), slot: .updatedPlaylists, showsChevron: true),
        .init(id: "cafe", title: "咖啡时光", style: .squares(rows: 1), slot: .tagged(.cafe), showsChevron: true),
        .init(id: "city", title: "城市排行榜", style: .squares(rows: 1), slot: .cityCharts),
        .init(id: "trending", title: "正在流行中", style: .trackColumns(rows: 4), slot: .trendingSongs, showsChevron: true),
        .init(id: "everyone", title: "大家都在听", style: .trackColumns(rows: 4), slot: .popularSongs, showsChevron: true),
        .init(id: "charts", title: "每周热门 100 首", style: .squares(rows: 1), slot: .charts, showsChevron: true),
        .init(id: "shows", title: "最新电台节目", style: .episodes(rows: 3), slot: .radioEpisodes, showsChevron: true),
        .init(id: "videos", title: "观看艺人分享", style: .videos, slot: .artistShares, showsChevron: true),
        .init(id: "explore", title: "探索更多", style: .links, slot: .browseGroups),
    ]

    /// 广播（RadioPageIntent）。中国区 Music 只有三段：顶部 hero 宽卡 + 两条「风格电台」
    /// （两条同名，是 Music 自己就这么下发的）。
    static let radio: [CatalogPageSection] = [
        .init(id: "radio-hero", style: .hero, slot: .radioFeatured),
        .init(id: "radio-0", title: "风格电台", style: .stations, slot: .radioStations(page: 0), showsChevron: true),
        .init(id: "radio-1", title: "风格电台", style: .stations, slot: .radioStations(page: 1), showsChevron: true),
    ]
}
