import Foundation

// MARK: - 目录货架装配辅助

extension CatalogShelf {
    /// 非空才成段：音源某路接口为空或失败时自动省掉该段，不在页面上留空标题。
    static func make(
        id: String,
        title: String? = nil,
        style: CatalogStyle,
        showsChevron: Bool = false,
        result: CatalogSlotResult
    ) -> CatalogShelf? {
        guard !result.items.isEmpty else { return nil }
        return CatalogShelf(id: id, title: title, style: style, showsChevron: showsChevron, result: result)
    }

    static func playlists(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .squares(rows: 1),
        showsChevron: Bool = false,
        eyebrows: [String: String] = [:],
        _ items: [Playlist]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .playlists(items), eyebrows: eyebrows))
    }

    static func albums(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .squares(rows: 1),
        showsChevron: Bool = false,
        eyebrows: [String: String] = [:],
        _ items: [Album]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .albums(items), eyebrows: eyebrows))
    }

    static func tracks(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .trackColumns(rows: 4),
        showsChevron: Bool = false,
        seeAll: Playlist? = nil,
        _ items: [Track]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .tracks(items), seeAll: seeAll))
    }

    static func artists(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .squares(rows: 1),
        showsChevron: Bool = false,
        _ items: [Artist]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .artists(items)))
    }

    static func mvs(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .videos,
        showsChevron: Bool = false,
        _ items: [MV]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .mvs(items)))
    }

    static func tagGroups(
        id: String,
        title: String? = nil,
        style: CatalogStyle = .links,
        showsChevron: Bool = false,
        _ groups: [CatalogTagGroup]
    ) -> CatalogShelf? {
        make(id: id, title: title, style: style, showsChevron: showsChevron,
             result: .init(items: .tagGroups(groups)))
    }
}

