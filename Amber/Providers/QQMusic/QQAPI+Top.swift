import Foundation

// 榜单补全：完整的榜单目录（分组 + 期数 + 历史期），与带期数/翻页的榜单详情。
// 移植来源：[QQMusicApi] `modules/top.py`、`models/top.py`。
//
// 与基线的关系（`music.musicToplist.Toplist` 的 `GetAll` / `GetDetail` 两条 method
// 基线都已经在用，这里**不是重复，是把被砍掉的参数与字段补回来**）：
//
// | 基线（`QQAPI.swift`） | 这里 | 差在哪 |
// | --- | --- | --- |
// | `loadToplists()`：`GetAll` → `prefix(12)`，每条只取 topId/title/封面 | `toplistCatalog()` | 不截断（实测 4 组共 30 张），保留分组名、期数 `period`、更新时间、总曲数、播放量，以及**历史期表** `history` |
// | `toplistDetail(_:)`：`GetDetail` 固定 `offset: 0, num: 50` | `toplistPage(...)` | 收 `period`（看往期）、`offset`/`limit`（翻页），并把名次算出来 |
//
// 基线那两条是「目录页那一格」与「点进去看当期前 50」，够用；这里这两条是
// 「榜单全表」「往期榜」「第 51 名之后」——是它给不了的东西，所以值得单独一份。
// **基线那两条一个字都没动。**
//
// 两条都匿名可用（[实测 2026-09-09 curl]，不带 comm 不带 cookie，code 0）。

extension QQAPI {

    // MARK: - 榜单目录

    /// 一张榜。
    struct QQToplist: Sendable {
        /// `qq:top:<topId>`，与基线拼法一致，可以直接丢给 `playlistDetail`
        let playlist: Playlist
        let topID: Int
        /// 当期标识。日更榜是 `"2026-09-09"`，周更榜是 `"2026_36"`（年_周），
        /// **MV 榜是空串**（那张榜不分期）
        let period: String
        /// 完整标题（「飙升榜 第252天」「内地榜 第36周」）
        let titleDetail: String
        let updateTime: String
        /// 有往期的榜给年份表，如 `[2026, 2025, 2024, 2023, 2022]`；日更榜是空表
        let historyYears: [Int]
        /// 与 `historyYears` 一一对应的期号表（周更榜是第几周，倒序）
        let historySubPeriods: [[Int]]
    }

    /// 一组榜（「巅峰榜」「地区榜」「特色榜」「全球榜」）。
    struct QQToplistGroup: Sendable {
        let id: Int
        let name: String
        let toplists: [QQToplist]
    }

    /// 榜单目录。`music.musicToplist.Toplist/GetAll`，param 是空对象
    /// （[QQMusicApi] `modules/top.py::get_category`）。
    ///
    /// [实测 2026-09-09 curl] 匿名 code 0，`group[]` 4 组共 30 张：
    /// 巅峰榜 6（飙升/热歌/新歌/流行指数/听歌识曲/MV）、地区榜 9、特色榜 11、全球榜 4。
    /// **基线只取前 12 张**（`prefix(12)`，正好卡在地区榜第 6 张），特色榜与全球榜
    /// 一张都进不了目录页——这就是这条方法存在的理由。
    ///
    /// 每条给：`topId` / `title` / `titleDetail`（「飙升榜 第252天」）/ `intro`（榜单规则说明）/
    /// `period` / `updateTime` / `listenNum`(18633712) / `totalNum`(100) /
    /// `headPicUrl` + `frontPicUrl` + `mbHeadPicUrl` + `mbFrontPicUrl` 四种封面 /
    /// `history: {year: [...], subPeriod: [[...], ...]}`。
    ///
    /// 实测到的期数规律：巅峰榜那 6 张是**日更**（`period` = `2026-09-09`，`history` 全空，
    /// 看不了往期）；地区/特色/全球那 24 张是**周更**（`period` = `2026_36`，
    /// `history.year` 给 5 年、`subPeriod` 与之对应给每年的周号倒序表）。
    /// 唯一的例外是 MV 榜（topId 201）：`period` 是空串。
    func toplistCatalog() async -> [QQToplistGroup] {
        await catalogCache.value(for: "qq:musicToplist.GetAll.full") {
            guard let data = try? await self.musicu(module: "music.musicToplist.Toplist",
                                                    method: "GetAll", param: [:]),
                  let groups = data["group"] as? [[String: Any]] else { return nil }
            return groups.map { group in
                QQToplistGroup(
                    id: group["groupId"] as? Int ?? 0,
                    name: group["groupName"] as? String ?? "排行榜",
                    toplists: (group["toplist"] as? [[String: Any]] ?? []).compactMap(Self.parseToplist))
            }
        } ?? []
    }

    /// 目录里的一张榜。封面四选一：`headPicUrl`(500 方) 优先，其次 `frontPicUrl`(300 方)，
    /// 再退到两个 `mb*` 移动版——与基线 `toplistDetail` 的取法一致，只是那边只认前两个。
    private static func parseToplist(_ t: [String: Any]) -> QQToplist? {
        guard let topID = t["topId"] as? Int else { return nil }
        let cover = ["headPicUrl", "frontPicUrl", "mbHeadPicUrl", "mbFrontPicUrl"]
            .compactMap { t[$0] as? String }.first { !$0.isEmpty }
        let history = t["history"] as? [String: Any] ?? [:]
        let playlist = Playlist(
            id: "qq:top:\(topID)", kind: .qq,
            name: t["title"] as? String ?? "排行榜",
            coverURL: Self.httpsURL(cover),
            description: (t["intro"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playCount: t["listenNum"] as? Int ?? 0,
            trackCount: t["totalNum"] as? Int ?? 0,
            creatorName: "排行榜")
        return QQToplist(
            playlist: playlist,
            topID: topID,
            period: t["period"] as? String ?? "",
            titleDetail: t["titleDetail"] as? String ?? playlist.name,
            updateTime: t["updateTime"] as? String ?? "",
            historyYears: history["year"] as? [Int] ?? [],
            historySubPeriods: history["subPeriod"] as? [[Int]] ?? [])
    }

    // MARK: - 榜单详情（带期数与翻页）

    /// 榜上的一首歌 + 它的名次。
    struct QQToplistEntry: Sendable {
        /// 名次（从 1 起，等于 `offset + 在这一页里的位置`）
        let rank: Int
        let track: Track
    }

    /// 一页榜单。
    struct QQToplistPage: Sendable {
        let playlist: Playlist
        let entries: [QQToplistEntry]
        /// 服务端回显的期数（可用来确认真的翻到了那一期）
        let period: String
        /// 完整标题，往期榜靠它显示「内地榜 第30周」
        let titleDetail: String
        let total: Int
    }

    /// 榜单详情。`music.musicToplist.Toplist/GetDetail`
    /// （[QQMusicApi] `modules/top.py::get_detail`）。
    ///
    /// param：`{topId, offset, num, withTags: true}` +（可选）`period`。
    /// `withTags` 要真的是布尔（参考实现在这条上开了 `preserve_bool`）。
    ///
    /// **`period` 是参考实现里没有的参数**——它的 `get_detail` 只收 topId/num/page/tag，
    /// 所以照着抄就永远只能看当期。这一条是从 `GetAll` 的 `history` 字段反推出来的，
    /// 并且验过：[实测 2026-09-09 curl] topId=5（内地榜），
    /// `period: "2026_30"` → 回显 `period: 2026_30`、`titleDetail: "内地榜 第30周"`，
    /// 头三首是 媚人 / Cold Blooded / 全世界的雨；换成 `"2026_36"`（当期）
    /// 头三首变成 唯有追赶风的方向 / 天生刺猬 / 不要问风往哪吹。**确实是两期不同的榜。**
    ///
    /// 翻页：`offset` 与 `num` 都真的生效（与歌手那两条不一样）。
    /// [实测] `num: 5` 回 5 首、`num: 100` 回 100 首；topId=26 `offset: 50` 拿到的是第 51 名起。
    ///
    /// 响应：`data`（榜单信息，键名就叫 `data`，基线那边还兼容了 `info`）+
    /// `songInfoList[]`（标准歌曲对象）+ `extInfoList` / `songTagInfoList` / `indexInfoList`
    /// ——后三个实测是空表，本轮不读。
    /// **名次不在歌曲对象里**（`songInfoList` 的条目就是普通 track，没有 rank 字段），
    /// 所以按 `offset + 位置` 自己算——榜单接口本来就是按名次序发的。
    func toplistPage(topID: Int, period: String? = nil,
                     offset: Int = 0, limit: Int = 50) async -> QQToplistPage? {
        var param: [String: Any] = ["topId": topID, "offset": max(0, offset),
                                    "num": max(1, limit), "withTags": true]
        if let period, !period.isEmpty { param["period"] = period }
        guard let data = try? await musicu(module: "music.musicToplist.Toplist",
                                           method: "GetDetail", param: param) else { return nil }
        let info = (data["data"] as? [String: Any]) ?? (data["info"] as? [String: Any]) ?? [:]
        let tracks = (data["songInfoList"] as? [[String: Any]] ?? []).compactMap { Self.parseTrack($0) }
        let entries = tracks.enumerated().map { QQToplistEntry(rank: offset + $0.offset + 1, track: $0.element) }
        let cover = ["headPicUrl", "frontPicUrl", "mbHeadPicUrl", "mbFrontPicUrl"]
            .compactMap { info[$0] as? String }.first { !$0.isEmpty }
        let playlist = Playlist(
            id: "qq:top:\(topID)", kind: .qq,
            name: info["title"] as? String ?? "排行榜",
            coverURL: Self.httpsURL(cover) ?? tracks.first?.artworkURL,
            description: (info["intro"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            playCount: info["listenNum"] as? Int ?? 0,
            trackCount: info["totalNum"] as? Int ?? entries.count,
            creatorName: "排行榜")
        return QQToplistPage(
            playlist: playlist,
            entries: entries,
            period: info["period"] as? String ?? (period ?? ""),
            titleDetail: info["titleDetail"] as? String ?? playlist.name,
            total: info["totalNum"] as? Int ?? entries.count)
    }

    /// 一张榜能看的往期列表（新到旧），直接可以拿去传给 `toplistPage(period:)`。
    ///
    /// `history.year` 与 `history.subPeriod` 是两张平行的表（[实测] 长度一致，
    /// 年份新到旧、每年的周号也是新到旧），拼法就是 `"<年>_<周>"`——
    /// 与当期 `period` 的写法一致，所以能直接用。
    /// 日更榜（巅峰榜那 6 张）这两张表都是空的，返回空数组＝「这张榜没有往期」。
    func toplistPeriods(_ toplist: QQToplist) -> [String] {
        zip(toplist.historyYears, toplist.historySubPeriods).flatMap { year, weeks in
            weeks.map { "\(year)_\($0)" }
        }
    }
}
