import Foundation

// MARK: - 音乐源

/// 音乐源标识
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case netease
    case qq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        }
    }

    var shortName: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ"
        }
    }
}

// MARK: - 统一模型

struct Track: Identifiable, Codable, Hashable, Sendable {
    /// 形如 "ne:347230" / "qq:0039MnYb0qxYhV"；本地导入的是 "local:<sha1>"（见 `isLocal`）
    let id: String
    let kind: ProviderKind
    /// 「显示简介」面板能改这两项（`TrackInfoStore.update` → `LibraryStore.updateTrack`），
    /// 所以是 `var`——理由与下面`albumName` / `artworkURL` 那两条同类：
    /// 资料库里的这份记录是可编辑的，音源给的只是初值。
    var title: String
    var artistName: String
    let artistId: String?
    /// 音源的专辑歌曲列表常常不带专辑节点（QQ 尤其），入库时由 LibraryStore 用所属专辑补齐，
    /// 资料库「歌曲」表的「专辑 / 类型」两列才有内容可显示，故这两项可写。
    var albumName: String
    var albumId: String?
    /// 封面地址。本地导入的曲目写的是内嵌封面落地后的 `file://`（见`ImportService`），
    /// 「自动更新已导入歌曲的插图」回填音源封面时也要改写这一项，故可写。
    var artworkURL: String?
    /// 秒
    let duration: TimeInterval
    /// 专辑内的音轨号与光盘号（资料库「歌曲」表的「音轨编号 / 光盘编号」两列）。
    /// 专辑与歌单接口给，搜索接口不给，所以是可选。
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    /// QQ 音乐取流所需的 media_mid（登录取流用，网易云为 nil）
    var mediaMid: String? = nil
    /// 音源是否提供无损档（仅表示音源侧可用；实际播哪一档看音质偏好与降级结果）。
    /// 用 Optional 而非带默认值的 Bool：旧的 library.json 里没有这个键，
    /// 合成的 Decodable 对非可选属性缺键会直接抛错。
    ///
    /// **这里没有「本机文件在哪」那一格。** 从前有一个 `localPath`，它与下载索引
    /// 是同一件事的两份真相，而实测已经坐实那份副本会腐败（用户本机 8 条`localPath`
    /// 全部指向改名前的媒体夹、8 个文件全不存在，同期索引里 14 条是活的）。
    /// 现在「这首歌在本机有没有文件、在哪」只有一处能回答：`DownloadStore`
    /// （落库是主库的`local_file` 表）。
    var losslessAvailable: Bool? = nil
}

extension Track {
    /// 本地导入曲目的 id 前缀。**没有新增 `ProviderKind.local`**：`ProviderKind.allCases`
    /// 是「音源」清单——设置 › 音源逐条列开关、`syncAccountPlaylists` 逐个问账号歌单、
    /// `AppState.provider(_:)` 还是强解包，多一个没有 provider 的成员要在四五处开特例。
    /// 本地性只由这个 **id 前缀**表示，`kind` 仍是一个真音源（导入时的默认音源），
    /// 于是「查歌词 / 找封面 / 前往艺人」这些按 kind 走 provider 的路一行都不用改。
    ///
    /// 它回答的是「这首歌从哪儿来的」（用户自己导进来的，不是从音源点出来的），
    /// **不回答「文件此刻在不在、在哪」**——那是 `DownloadStore` 一处的事。
    /// 两个问题从前挤在一个字段上（`isLocal` 与`localPath` 互相当对方的判据），
    /// 于是文件被删之后既不算「本地」也不算「在线」。
    static let localIDPrefix = "local:"

    var isLocal: Bool { id.hasPrefix(Track.localIDPrefix) }

    /// 能否跳转到艺人页：有在线 artistId，或者艺人名有效（可在线检索或在资料库内定位）。
    var canGoToArtist: Bool {
        if let id = artistId, !id.isEmpty { return true }
        let trimmed = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != ImportService.unknownArtist
    }
}

/// `IndexSet` 版的删除与重排。
///
/// SwiftUI 给 `RangeReplaceableCollection` / `MutableCollection` 带了同名的
/// `remove(atOffsets:)` / `move(fromOffsets:toOffset:)`，但那要 `import SwiftUI`——
/// 服务层（`LibraryStore`）为两个数组方法把整个界面框架拉进来不合适，何况
/// `MemberImportVisibility` 打开之后这条依赖会明着写在文件头上。
///
/// 语义与 SwiftUI 那份**逐位相同**，由 `AlbumTrackOrderTests` 里的差分测试钉住：
/// 两份实现跑同一批随机用例，结果必须一致。
extension Array {
    /// 删掉这些下标上的元素。下标按**原数组**计。
    mutating func amberRemove(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        self = enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    /// 把这些下标上的元素整体挪到 `destination` **之前**。
    ///
    /// 坑在 `destination` 是**原数组**的下标：先摘出来再插回去时，落点要减掉
    /// 「摘走的元素里有几个排在它前面」，否则往后挪时会差这么多位。
    mutating func amberMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }
        let moved = source.map { self[$0] }
        for index in source.reversed() { remove(at: index) }
        insert(contentsOf: moved, at: destination - source.count(in: 0 ..< destination))
    }
}

extension Array where Element == Track {
    /// 排成原专辑的曲序：先碟号后碟内音轨号。**稳定**：音源没给序号的保持原有先后，
    /// 并排在有序号的之后——不去按标题猜顺序（那是资料库里本地文件的活，见
    /// `LibraryStore.tracks(in:)`）。
    ///
    /// QQ 的 `GetAlbumSongList` 回的**不是曲序**，看着像热度序：[实测 2026-09-08 curl]
    /// 《自传》13 首回来的 `index_album` 是 2,9,13,11,4,7,10,12,5,3,6,1,8；
    /// `param` 里加`sort: 1/2` 无效（响应里的`sort` 恒为 0），曲序只能客户端自己排。
    /// 网易云 `/api/v1/album` 本来就按曲序回（同日实测），排一遍不动它。
    ///
    /// 碟号两家的基数不同（QQ 的 `index_cd` 从 0 起，网易的`cd` 从 1 起），
    /// 这里只在一张碟内部比大小，不跨音源比，基数差不影响。
    func sortedByAlbumOrder() -> [Track] {
        enumerated().sorted { lhs, rhs in
            (lhs.element.discNumber ?? 0, lhs.element.trackNumber ?? .max, lhs.offset)
                < (rhs.element.discNumber ?? 0, rhs.element.trackNumber ?? .max, rhs.offset)
        }.map(\.element)
    }
}

struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ProviderKind
    let name: String
    let artistName: String
    let artistId: String?
    let artworkURL: String?
    let publishDate: String?
    let trackCount: Int
    let description: String?
    /// 曲风（Music.app 信息行首段，如 Mandopop）。音源没给就是 nil，此时该段整体省略。
    var genre: String? = nil
    /// 音源给的原样类型词：QQ `albumType`（录音室专辑 / EP / Single / 演唱会）、
    /// 网易 `type`（专辑 / EP / Single）。艺人页靠它把「专辑」拆出「单曲和 EP」
    /// 与「现场演出专辑」（Music 艺人页的段结构）；给不出就是 nil，一律当专辑。
    var albumType: String? = nil
}

extension Album {
    /// 本地导入曲目归出来的专辑 id 前缀（`local:album:<sha1(专辑名+艺人)>`）。
    /// 这种专辑没有音源可问详情，曲目就在资料库里（见 `AlbumDetailViewController.reload`）。
    static let localIDPrefix = "local:album:"

    var isLocal: Bool { id.hasPrefix(Album.localIDPrefix) }
}

/// 艺人介绍面板上的一行事实（「生日 / 1979年1月18日」这种）。
///
/// 键名由音源给（QQ 的百科表是中文键，逐人不同），所以这里不做成枚举——
/// 面板只负责把 label / value 摆出来。
struct ArtistFact: Codable, Hashable, Sendable {
    let label: String
    let value: String
}

struct Artist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ProviderKind
    let name: String
    let avatarURL: String?
    let description: String?
    /// 艺人页头图：**宽幅**大图，与方形的 `avatarURL` 是两张不同的图，不能互相顶替
    /// （圆头像塞宽幅图会裁成一条，满幅 hero 塞 300 方图会糊）。
    /// 只有艺人详情接口给得出，搜索结果里没有；约一半艺人没有这张图（见
    /// `QQAPI.parseSingerDetail`），拿不到时 hero 自己回退到`avatarURL`。
    var bannerURL: String? = nil
    /// 艺人介绍面板上那几行事实（生日 / 出道日期 / 职业 / 代表作品…）。
    /// 来自 QQ 百科 XML 的 `<basic>` 表（`QQAPI.parseWikiFacts`）；给不出就是空数组，
    /// 面板那一段整块不占位。对应 Music 介绍面板里「成立日期」「類型」那两行。
    ///
    /// 非可选 + 默认值在这里是安全的：`Artist` **不落盘**（资料库存的是曲目/专辑/播放列表，
    /// 艺人是现算的，见 `LibraryStore.libraryArtists()`）。真要存进 library.json 时得注意
    /// 合成的 `Decodable` 对非可选属性缺键会抛错、不会用默认值（`Track.losslessAvailable`
    /// 上面那条注释就是这个坑），到时候改成可选或自写 `init(from:)`。
    var facts: [ArtistFact] = []

    /// 资料库派生艺人的 id 前缀：`library-artist:<艺人名>`。
    ///
    /// 这类艺人**不是音源里的艺人**，只是「资料库里的歌按艺人名分个类」，冒号后面是名字
    /// 不是 mid。所以它没有在线艺人页可去（拿名字当 mid 去打 QQ 的
    /// `GetAlbumList` 会回 104400，之前还被误判成「登录已过期」）。
    /// 造这种 id 的地方与判定都走这两个符号，别再各写各的字符串。
    static let libraryIDPrefix = "library-artist:"

    /// 资料库派生艺人（见 `libraryIDPrefix`）：不挂艺人页链接。
    var isLibraryDerived: Bool { id.hasPrefix(Self.libraryIDPrefix) }
}

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ProviderKind
    let name: String
    var coverURL: String? = nil
    var description: String? = nil
    var playCount: Int = 0
    var trackCount: Int = 0
    var creatorName: String? = nil
    /// 这份歌单是不是**当前登录账号自己建的**——只有自己建的才写得进去
    /// （收藏来的是别人的歌单，「添加到播放列表」摆出来点了也只会被服务端拒）。
    /// 只有 `accountPlaylists()` 会填它，目录里搜来的歌单一律是 nil＝不知道，按不可写算。
    ///
    /// 用 Optional 而不是带默认值的 Bool：它跟着 `LibraryPlaylist.source` 落进
    /// `library.json`，旧存档里没有这个键，合成的 Decodable 对非可选属性缺键会直接抛错
    /// （与 `Track.losslessAvailable` 同一个理由）。
    var isOwned: Bool? = nil

    /// 是否为排行榜/榜单类歌单（对应规格里的 isCharted / PlaylistItemModel.chartRank）
    ///
    /// 只认两类确定信号：榜单专用 id（QQ 巅峰榜 `qq:top:<topId>`、目录里写死的那几张），
    /// 以及**以「榜」结尾**的名字——网易云的榜单走普通歌单 id，除了名字没有别的标记。
    /// 别再拿 "Top" / "TOP" / "100" 这种子串猜：「100+ 车载英文歌」「NON-STOP 舞曲」
    /// 都会被误判成榜单，普通歌单平白多出一列名次。
    var isChart: Bool {
        if id.contains(":top:") { return true }
        if ChartCatalog.charts(for: kind).contains(where: { id == "\(kind.rawValue):\($0.id)" }) { return true }
        return name.hasSuffix("榜") || name.contains("排行榜")
    }
}

/// 资料库里的一份播放列表。
///
/// Music.app 的「播放列表」是资料库实体，三种来源在界面上一视同仁：
/// 自己在 App 里新建的、从目录里「添加到资料库」的、以及账号自带的（Music 是 iCloud
/// 资料库，Amber 这边是登录的音源账号）。所以这里用一个类型带 `origin` 区分，
/// 而不是三套结构。
struct LibraryPlaylist: Identifiable, Codable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Amber 里新建的：曲目就存在本地，可增删改
        case local
        /// 从目录里加进资料库的音源歌单：曲目每次打开时向音源取，本地只留一个引用
        case added
        /// 登录账号在音源里的歌单（自建 + 收藏），由同步维护，本地不可编辑
        case account
    }

    let id: String
    var name: String
    var origin: Origin
    /// 非本地来源时指向的音源歌单（打开详情页就拿它去 `playlistDetail`）
    var source: Playlist?
    /// 只有 `.local` 用：本地维护的曲目表
    var tracks: [Track]
    var coverURL: String?
    var description: String?
    var createdAt: Date
    var addedAt: Date

    /// 本地列表用首曲封面顶；音源列表用它自己的封面。
    var artworkURL: String? { coverURL ?? tracks.first?.artworkURL }

    /// 只有自己在 Amber 里建的列表能改名、加歌、删歌。
    var isEditable: Bool { origin == .local }

    /// 卡片/侧栏副标题：本地列表报曲目数，音源列表报创建者。
    var subtitle: String {
        switch origin {
        case .local: return "\(tracks.count) 首歌曲"
        case .added, .account:
            if let creator = source?.creatorName, !creator.isEmpty { return creator }
            let count = source?.trackCount ?? 0
            return count > 0 ? "\(count) 首歌曲" : "播放列表"
        }
    }

    static func local(name: String, tracks: [Track] = []) -> LibraryPlaylist {
        let now = Date()
        return LibraryPlaylist(id: "local:\(UUID().uuidString)", name: name, origin: .local,
                               source: nil, tracks: tracks, coverURL: nil, description: nil,
                               createdAt: now, addedAt: now)
    }

    static func from(_ playlist: Playlist, origin: Origin) -> LibraryPlaylist {
        let now = Date()
        return LibraryPlaylist(id: playlist.id, name: playlist.name, origin: origin,
                               source: playlist, tracks: [], coverURL: playlist.coverURL,
                               description: playlist.description, createdAt: now, addedAt: now)
    }
}

/// 逐字歌词里的一个音节（QRC 的 `字(起点,时长)`）。行级歌词没有这一层。
struct LyricSyllable: Hashable, Sendable {
    let text: String
    let time: TimeInterval
    let duration: TimeInterval
    /// 这个音节自己的发音（罗马音）。
    ///
    /// QQ 的 `roma` 与正文是**同一套时间戳**的 QRC——正文` 甘(46529,928)い(47457,297)`
    /// 对上 roma `a(46529,176)ma(46705,752)i(47457,297)`，roma 切得更细但端点严丝合缝，
    /// 所以按时间区间就能把它归到正文音节上（`LyricParser.attachTransliteration`）。
    /// 网易的 `romalrc` 只有行级时间，归不进来，留 nil、退回整行那条副行。
    let transliteration: String?
    var end: TimeInterval { time + duration }

    init(text: String, time: TimeInterval, duration: TimeInterval,
         transliteration: String? = nil) {
        self.text = text
        self.time = time
        self.duration = duration
        self.transliteration = transliteration
    }
}

struct LyricLine: Identifiable, Hashable, Sendable {
    /// 歌词轨里除了正文还有三种非「带时间轴的正文」的行，跟 Music 一致。
    enum Kind: Hashable, Sendable {
        /// 正文
        case lyric
        /// 间奏：用三个点占住这段空白，而不是让上一句一直干等
        case interlude
        /// 尾部创作者（词在前、曲在后），只在整首歌最后出现一次
        case credits
        /// **没有时间戳的纯文本正文行。**
        ///
        /// 音源不给「歌词是什么格式」这个类别位——[实测 2026-09-16 curl] QQ 的
        /// `GetPlayLyricInfo` 对一份 253 行、零个时间戳的词回的是 `qrc=0` /
        /// `lyric_style=0`，与普通 LRC 的响应一模一样；网易的纯文本与行级 LRC
        /// 共用 `lrc` 这一个字段。所以这个类别只能由 Amber 自己按形态立
        ///（整份一个时间戳都没有），且只在解析时判一次，不在渲染时临时嗅探。
        ///
        /// 与 `.lyric` 分开是为了让编译器把每一处 `kind` 判据都指出来：
        /// 混进 `.lyric` 的话，LRC 写出会给它补一个 `[00:00.00]`、
        /// 适配层会造出 `startTime = 0` 的行，被选行状态机在 t=0 一次性全选中。
        case plain
    }

    /// 这一行由谁唱。
    ///
    /// 来源是歌词里那些**独立成行、冒号后为空**的歌手提示行（`TAEYANG：`、`周杰伦：`）——
    /// QQ 用它标下一段换人了。提示行本身不上屏，它标出来的归属留在这里。
    struct Vocalist: Hashable, Sendable {
        /// 提示行里的原样写法（`T.O.P`、`周杰伦`）。
        let name: String
        /// 在本首歌名册里的位置，按**首次出现序**。同一个人的所有行同号。
        let index: Int
    }

    let index: Int
    let time: TimeInterval
    /// 本行唱完的时刻。Music 是「唱完就翻页、到点才高亮」，翻页依据是它而不是下一行的起点。
    let end: TimeInterval
    let text: String
    let translation: String?
    /// 音译副行（Music 界面上叫「发音」）。QQ 的 `roma`、网易的`romalrc`。
    let transliteration: String?
    /// 逐字时间轴；为空表示这行只有整行时间。
    let syllables: [LyricSyllable]
    let kind: Kind
    /// 这一行是不是段首。**只有 `.plain` 会置真**：纯文本里空行是仅有的段落信息
    ///（实测网易《国王的新衣》正文里多处空行分段），而带时间轴那条路上的段落由间奏行
    /// 表达——「按空隙猜段落」早就被证伪过，见 `LyricsAdapter` 里那段注释，别改回去。
    let startsParagraph: Bool
    /// 唱这一行的人。`nil` = 这首歌没有歌手提示行，或这行排在第一条提示之前。
    let vocalist: Vocalist?

    var id: Int { index }

    init(index: Int, time: TimeInterval, end: TimeInterval, text: String,
         translation: String? = nil, transliteration: String? = nil,
         syllables: [LyricSyllable] = [], kind: Kind = .lyric,
         vocalist: Vocalist? = nil, startsParagraph: Bool = false) {
        self.index = index
        self.time = time
        self.end = end
        self.text = text
        self.translation = translation
        self.transliteration = transliteration
        self.syllables = syllables
        self.kind = kind
        self.vocalist = vocalist
        self.startsParagraph = startsParagraph
    }
}

extension Array where Element == LyricLine {

    /// 整份歌词一个时间戳都没有 ⇒ 走静态档（`Lyrics.type == .static`）。
    ///
    /// **空数组不算**：那是「确认没词」，归 `LyricsStore` 的负结果缓存管，
    /// 不能把面板翻进静态档。`.credits` 放行是因为无戳那条路照样会在尾部补一行创作者。
    var isUntimed: Bool {
        !isEmpty && allSatisfy { $0.kind == .plain || $0.kind == .credits }
    }
}

// MARK: - 聚合结构

// MARK: - 目录页（主页 / 新发现 / 广播）

/// 目录页卡片的排布，对应 `lockup 规格` 的组件家族。
enum CatalogStyle: Sendable {
    /// 全高海报（主页「专属精选推荐」「为你制作的歌单」）
    case poster
    /// 顶部宽 hero（新发现首段、中国区广播首段）
    case hero
    /// 整宽大横幅，一段只有一张（主页「推荐歌单」，Apple 内部叫 super-hero）
    case superHero
    /// 方卡货架，rows = 行数
    case squares(rows: Int)
    /// 电台方卡：台名压在图上 + 图下两行（中国区「风格电台」）
    case stations
    /// 多列曲目行，rows = 每列行数
    case trackColumns(rows: Int)
    /// 16:9 视频卡货架（新发现「观看艺人分享」）
    case videos
    /// 纯文字链接组（新发现「探索更多」）
    case links
    /// 横向宽卡（「最新电台节目」单集）
    case episodes(rows: Int)
}

/// Music 主页长尾货架的维度。实测那些货架里**装的主要是专辑**（夹少量编辑歌单），
/// 段名就是维度本身（「國語流行樂」「日本流行樂」「2000 年代」）。
/// 两家音源都能按地区取新碟，所以语种维度落到「该地区的专辑」；
/// 年代维度只有网易云有（歌单标签 80后/90后/00后），QQ 交不出来，那两段会整段省掉。
enum CatalogTag: Sendable {
    /// 地区/语种 → 专辑
    case mandopop, cantopop, jpop, kpop, western
    /// 年代 → 歌单（音源没有按年代的专辑接口）
    case noughties, tens
    /// 曲风/场景 → 歌单
    case alternative, electronic, cafe
}

/// 目录页一段要什么内容。Music 的栏目结构是固定的（见 CatalogPages），
/// 音源只按格子交数据，交不出来就返回空，页面把那一段整段省掉。
enum CatalogSlot: Sendable {
    // 主页
    case topPicks           // 专属精选推荐
    case madeForYou         // 为你制作的歌单
    case moodStations       // 找到迎合心情的内容
    case stations           // 为你精选的电台
    case latestReleases     // 为你推荐最新作品
    case recommendedPlaylist // 推荐歌单（整宽大横幅，一段只要一张）
    case tagged(CatalogTag) // 曲风/年代/语种/场景货架
    /// 「更多类似作品」：给一串候选种子（最近播放），音源挑第一个查得出东西的，
    /// 段标题写成那首歌的名字、左边挂它的封面（Music 的种子头，见 CatalogPageViewController）。
    case moreLikeThis([Track])
    /// 最近播放，来自本地资料库而不是音源
    case recentlyPlayed
    /// 「音乐回忆：你的热门音乐」。Music 那张卡落点是服务端每月生成的歌单；
    /// Amber 没有服务端，用本地资料库上个月的播放记录现拼，同样不走音源。
    case musicMemories
    // 新发现
    case featured           // 顶部 hero 的编辑精选
    case artistSpotlights   // 瞩目之星
    case newSongs           // 新歌精选
    case newReleases(page: Int) // 本周新发行 / 新近发布
    case updatedPlaylists   // 歌单已更新
    case trendingSongs      // 正在流行中
    case popularSongs       // 大家都在听
    case charts             // 每周热门 100 首
    case cityCharts         // 城市排行榜
    case radioEpisodes      // 最新电台节目
    case artistShares       // 观看艺人分享（MV / 访谈）
    case browseGroups       // 探索更多：音源的歌单分类分组
    // 广播
    case radioFeatured          // 顶部主打电台
    case radioStations(page: Int) // 风格电台
}

/// 一段里混排的条目。Music 的「专属精选推荐」就是电台/歌单/专辑混排，
/// 每张卡靠 eyebrow 说明推荐理由，所以段内类型不统一。
enum CatalogEntry: Sendable {
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)

    var id: String {
        switch self {
        case .playlist(let v): return v.id
        case .album(let v): return v.id
        case .artist(let v): return v.id
        }
    }
}

enum CatalogItems: Sendable {
    case none
    case playlists([Playlist])
    case albums([Album])
    case tracks([Track])
    case artists([Artist])
    case mvs([MV])
    case tagGroups([CatalogTagGroup])
    case mixed([CatalogEntry])

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .playlists(let v): return v.isEmpty
        case .albums(let v): return v.isEmpty
        case .tracks(let v): return v.isEmpty
        case .artists(let v): return v.isEmpty
        case .mvs(let v): return v.isEmpty
        case .tagGroups(let v): return v.isEmpty
        case .mixed(let v): return v.isEmpty
        }
    }
}

/// 音源歌单分类里的一个标签。id 是音源自己的键：网易云是标签名
/// （`/api/playlist/list` 的 cat），QQ 是 categoryId。
struct CatalogTagRef: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// 一组标签（网易云的语种/风格/场景/情感/主题，QQ 的语种/流派/主题/心情/场景）。
/// Music 的「探索更多」是 5 条编辑链接（按风格浏览/年代之声/…），落点是 Apple 的
/// `/room/` 分类页；Amber 没有编辑内容，链接组落成音源自己的分类分组，
/// 点进去是同构的分类浏览页（`CatalogRoomViewController` 的`.tagGroup` 形态）。
struct CatalogTagGroup: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ProviderKind
    let name: String
    let tags: [CatalogTagRef]
}

/// 音源交给一个格子的东西
struct CatalogSlotResult: Sendable {
    var items: CatalogItems = .none
    /// 这一格**取不到**（连接类错误、服务端拒绝），与「音源本来就没这一格」分开。
    ///
    /// 为什么是加字段而不是把 `MusicProvider.catalogItems` / `playlists(tag:)` 改成
    /// `throws`（审查单 §8「留给下一轮」第 1 条）：`.empty` 对这两条是**有意义的返回值**
    /// ——很多格子音源本来就不供，改 `throws` 会把「没这一格」与「取不到」混成一件事；
    /// 而带默认值的加法是源码兼容的，现存构造点一行不动。
    var failure: URLError? = nil
    /// 段标题「查看全部」的落点；有才显示 ›
    var seeAll: Playlist? = nil
    /// 卡片眉行（Music 的 eyebrow），按条目 id 索引
    var eyebrows: [String: String] = [:]
    /// 段标题由内容决定时用它盖掉 CatalogPages 里的占位（种子货架 = 种子名）
    var title: String? = nil
    /// 种子头的小字与缩略图（「更多类似作品」+ 种子封面）
    var headline: String? = nil
    var seedArtworkURL: String? = nil
    /// 种子曲目所属的专辑实体（点击种子进入该专辑页）
    var seedAlbum: Album? = nil

    static let empty = CatalogSlotResult()
}

extension CatalogSlotResult {
    /// 「专属精选推荐」的混排。Music 实测这一段是**逐张换类型**的：
    /// 电台 → 电台 → 专辑 → 心情电台 → 歌单 → 专辑 → 电台 → 歌单，
    /// 每张卡的 eyebrow 说明它为什么在这（專屬推薦 / 最新發行 / 心情歌單推薦）。
    /// 不能按类型分组一堆一堆地摆——那是 Amber 之前的样子，跟 Music 一眼就不一样。
    /// 两家音源交上来的东西不同名但落位一样，所以摆位这件事在这里做、两边共用。
    ///
    /// **不收音源的推荐流歌单**（QQ 的 PlaylistSquare、网易云的 personalized/playlist）：
    /// 那批是「不听绝对后悔！抖音近期洗脑热歌」这类 UGC 标题，跟 Music 这一段的编辑气质不搭
    /// （用户 2026-09-03 定的）。腾出来的格子按电台/专辑/心情继续交替补——
    /// Music 那一段本来也是电台占一半。它们照旧出现在「为你制作的歌单」等段里。
    static func topPicks(radios: [Playlist], moods: [Playlist],
                         albums: [Album]) -> CatalogSlotResult {
        enum Kind { case radio, album, mood }
        let recipe: [Kind] = [.radio, .radio, .album, .mood, .radio,
                              .album, .mood, .radio, .album, .mood]
        var cursors: [Int] = [0, 0, 0]
        var entries: [CatalogEntry] = []
        var eyebrows: [String: String] = [:]
        var used = Set<String>()

        func take(_ kind: Kind) {
            let (index, eyebrow): (Int, String)
            switch kind {
            case .radio: (index, eyebrow) = (0, "专属推荐")
            case .album: (index, eyebrow) = (1, "最新发行")
            case .mood: (index, eyebrow) = (2, "心情歌单推荐")
            }
            // 同一格子里可能有重复（心情台也在热门台里），撞了就往后顺延
            while true {
                let entry: CatalogEntry
                switch kind {
                case .album:
                    guard cursors[index] < albums.count else { return }
                    entry = .album(albums[cursors[index]])
                case .radio:
                    guard cursors[index] < radios.count else { return }
                    entry = .playlist(radios[cursors[index]])
                case .mood:
                    guard cursors[index] < moods.count else { return }
                    entry = .playlist(moods[cursors[index]])
                }
                cursors[index] += 1
                guard used.insert(entry.id).inserted else { continue }
                entries.append(entry)
                eyebrows[entry.id] = eyebrow
                return
            }
        }

        for kind in recipe { take(kind) }
        return .init(items: .mixed(entries), eyebrows: eyebrows)
    }
}

/// 目录页的一段：**栏目名与卡型照 Apple Music 写死**，数据由音源按 slot 填。
struct CatalogPageSection: Sendable, Identifiable {
    let id: String
    /// nil = 无标题段（Music 的 hero 货架、广播顶部）
    var title: String? = nil
    var style: CatalogStyle
    var slot: CatalogSlot
    var showsChevron: Bool = false
}

struct PlaylistDetail: Sendable {
    let playlist: Playlist
    let tracks: [Track]

    var isChart: Bool { playlist.isChart }
}

struct AlbumDetail: Sendable {
    let album: Album
    let tracks: [Track]
}

struct ArtistDetail: Sendable {
    let artist: Artist
    let hotTracks: [Track]
    let albums: [Album]
}

enum SearchSection: String, CaseIterable, Identifiable {
    case tracks = "单曲"
    case albums = "专辑"
    case artists = "歌手"
    case playlists = "歌单"

    var id: String { rawValue }
}

struct SearchResults {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var mvs: [MV] = []
}

/// 搜索结果页的 MV 分区条目（Music.app 结果页的「MV」shelf），新发现「观看艺人分享」
/// 那段的视频卡也是它。点击在 App 内开 `MVPlayerWindowController` 那扇窗播。
struct MV: Identifiable, Hashable, Sendable {
    /// `qq:<vid>` / `ne:<mvid>`。**冒号后面那截就是取流接口认的键**：
    /// QQ 的 `GetMvUrls` 只认字母数字的`vid`（不认数字 mv_id），网易的
    /// `song/enhance/play/mv/url` 认数字 id。
    let id: String
    let kind: ProviderKind
    let title: String
    let artistName: String
    let coverURL: String?
    /// 秒
    let duration: TimeInterval
    /// 网页端 MV 页地址。App 内已经能播了（见 `AppState.playMV`），
    /// 它只剩右键「在网页中打开」这一个落点，以及取流失败时的兜底。
    let webURL: URL
}

// MARK: - 排行榜目录

enum ChartCatalog {
    struct Chart: Identifiable, Hashable {
        /// 网易云为歌单 ID；QQ 为 "top:{榜单ID}"
        let id: String
        let name: String
    }

    static func charts(for kind: ProviderKind) -> [Chart] {
        switch kind {
        case .netease:
            return [
                Chart(id: "19723756", name: "飙升榜"),
                Chart(id: "3779629", name: "新歌榜"),
                Chart(id: "3778678", name: "热歌榜"),
                Chart(id: "2884035", name: "原创榜"),
            ]
        case .qq:
            return [
                Chart(id: "top:62", name: "飙升榜"),
                Chart(id: "top:26", name: "热歌榜"),
                Chart(id: "top:27", name: "新歌榜"),
                Chart(id: "top:4", name: "流行指数榜"),
            ]
        }
    }

    /// 由榜单目录生成统一的 Playlist 模型
    static func playlist(for chart: Chart, kind: ProviderKind) -> Playlist {
        Playlist(id: "\(kind.rawValue):\(chart.id)", kind: kind, name: chart.name)
    }
}

// MARK: - 工具扩展

extension String {
    /// 去掉 "ne:" / "qq:" 前缀，得到源站原始 ID
    var rawID: String {
        guard let idx = firstIndex(of: ":") else { return self }
        return String(self[index(after: idx)...])
    }
}

// MARK: 数字成串

// `String(format:)` 是 C 那套变参格式化，Swift 里它是 `@unsafe` 的：格式串与实参个数、
// 类型都没人对，写错了不报错、跑起来读到的是栈上别的东西。开了 strict memory safety
//（`SWIFT_STRICT_MEMORY_SAFETY`，SE-0458）之后每用一次报一条。
//
// 全仓的用法其实只有三种形状：定宽补零的整数、字节转十六进制、定小数位的浮点。
// 前两种有**逐字符等价**的纯 Swift 写法，直接换掉（`zeroPadded` / `hexString`）；
// 第三种没有，于是只收成一个 `@safe` 外壳（`fixed`），见它自己的注释。
//
// 为什么要收成一份而不是各处照抄：`String(_:radix:)` 不像 `%02x` 那样自带宽度，
// 补零得手写，而这几处的输出是 MD5/SHA 签名、eapi 密文串、配对码、缓存文件名——
// 少补一个零就是另一个值，且不会当场报错，只会在服务端验签或缓存串图时才发作。
// 这种「写七遍就有七次写错的机会」的活只留一份。
//
// 等价性不是推的：改前改后各自编成倾倒程序做过差分——`%02d`/`%03d`/`%04d` 走遍
// −2000…2000、`%02x`/`%02X` 走遍 256 个字节值、`%04x` 走遍 0…0xFFFF、
// `hexString` 拿 2000 组随机字节串（0–64 字节）大小写各一遍，全部逐字符一致。

extension BinaryInteger {
    /// 定宽、左侧补零的数字串：`String(format: "%0\(width)d")`（以及 `%0Nx` / `%0NX`）的安全替代。
    ///
    /// 与 `printf` 的宽度语义一致：`width` 是**最小**宽度，够长就原样不截断；
    /// 负号算进宽度里、零补在负号后面（`(-5).zeroPadded(to: 3)` → `-05`）。
    func zeroPadded(to width: Int, radix: Int = 10, uppercase: Bool = false) -> String {
        let digits = String(magnitude, radix: radix, uppercase: uppercase)
        let sign = self < 0 ? "-" : ""
        let short = width - sign.count - digits.count
        guard short > 0 else { return sign + digits }
        return sign + String(repeating: "0", count: short) + digits
    }
}

extension BinaryFloatingPoint {
    /// 定小数位的数字串，等同 `String(format: "%.\(places)f", self)`。
    ///
    /// 这一个**没有**安全替代，所以是外壳不是替换。`Double.formatted(.number.precision(
    /// .fractionLength(n)))` 看着对得上（默认进位规则同样是 round-half-even，钉住
    /// `en_US_POSIX` 也能挡掉区域差异），但两者进位的**对象**不同：`%f` 拿二进制真值去凑，
    /// `FormatStyle` 走 ICU，拿的是那个 Double 的最短十进制表示。落到平局上就分家——
    /// 60 万个样本的差分里 `%.1f` 差 49 条、`%.2f` 差 570 条、`%.3f` 差 5998 条，
    /// 例：`145140.45` 的 `%.1f`，printf 给 `145140.5`（真值略大于 .45），FormatStyle 给 `145140.4`。
    /// 播放量这类「整十整百」的数正好最容易踩上平局，所以不换。
    ///
    /// 不安全在哪：`String(format:)` 是 C 变参，格式串与实参没人对，写错不报错、
    /// 跑起来读的是栈上别的东西。谁保证它安全：格式串在这一行里拼死成 `%.<整数>f`、
    /// 实参也拼死成一个 `Double`，两者成对出现在同一个表达式里，调用方够不着；
    /// 唯一的变量 `places` 只影响小数位数，进不了「有几个实参、是什么类型」这件事。
    @safe func fixed(_ places: Int) -> String {
        unsafe String(format: "%.\(places)f", Double(self))
    }
}

extension Sequence<UInt8> {
    /// 字节序列的十六进制串，**每字节固定两位**：`map { String(format: "%02x", $0) }.joined()` 的安全替代。
    ///
    /// 大小写不是无所谓的，调用点各自按协议要求传：网易 `encSecKey` 要小写、
    /// eapi `params` 与 DAAP 的配对 GUID 要大写，写反了对面直接不认。
    func hexString(uppercase: Bool = false) -> String {
        reduce(into: "") { $0 += $1.zeroPadded(to: 2, radix: 16, uppercase: uppercase) }
    }
}

extension TimeInterval {
    /// mm:ss 展示
    var mmss: String {
        let total = Int(self.rounded())
        return "\(total / 60):\((total % 60).zeroPadded(to: 2))"
    }
}

extension Int {
    /// 播放量等大数的短格式（12.3万 / 1.2亿）
    var shortCount: String {
        if self >= 100_000_000 {
            return "\((Double(self) / 100_000_000).fixed(1))亿"
        }
        if self >= 10_000 {
            return "\((Double(self) / 10_000).fixed(1))万"
        }
        return "\(self)"
    }
}
