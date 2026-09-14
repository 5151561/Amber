import Foundation

extension String {
    /// http 升 https，规避 ATS 限制。
    /// 两家音源的封面/取流地址都有回 http 的时候（电台头图、心情歌单封面尤其多）。
    var httpsUpgraded: String {
        hasPrefix("http://") ? "https://" + dropFirst("http://".count) : self
    }
}

extension Sequence {
    /// 按 key 去重，保留首次出现的顺序。
    func deduped<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

extension Sequence where Element: Identifiable {
    /// 按 id 去重，保留首次出现的顺序。
    func dedupedByID() -> [Element] { deduped { $0.id } }
}

extension MusicProvider {
    /// 榜单曲目 + 段标题的「查看全部」落点。
    /// 两家只差榜单 id 的拼法（`ne:3779629` / `qq:top:62`），取数与截断完全一样。
    func chartSlot(playlistID: String, limit: Int = 20) async -> CatalogSlotResult {
        let chart = Playlist(id: playlistID, kind: kind, name: "排行榜")
        guard let detail = try? await playlistDetail(chart) else { return .empty }
        return .init(items: .tracks(Array(detail.tracks.prefix(limit))), seeAll: detail.playlist)
    }
}
