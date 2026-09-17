import AppKit
import Foundation

/// 主库：`~/Library/Application Support/Amber/library.sqlite`。
///
/// 这一层只管三件事——**建表、升级、谁来共用这条连接**。查询与写入在各自的 store 里，
/// 下面那层 `SQLiteDatabase` 则完全不认识 Amber 的模型。三层各管一段，中间这层是
/// 唯一知道「Amber 的库长什么样」的地方。
///
/// **为什么一份库装下 Library / TrackInfo / Loudness / 本机文件四摊账**：它们本来就
/// 全按 `track.id` 挂，分成四份 JSON 只是因为各自的 store 是分头长出来的。合成一份之后
/// 「这首歌的一切」是一次 JOIN，而不是四次字典查找加四份各自会腐败的真值。
///
/// **线程**：`@MainActor`，和四个 store 同一条线。`SQLiteDatabase` 不是 `Sendable`，
/// 后台要干活的正确切法是后台只做文件 IO 与解析，解析出的值类型回主 actor 再写库。
@MainActor
final class AmberDatabase {

    /// 底下那条裸连接。store 直接拿它发语句。
    let sqlite: SQLiteDatabase

    /// 库文件本身（`-wal` / `-shm` 是它的旁文件，见 `checkpoint()`）。
    let fileURL: URL

    private var terminationObserver: (any NSObjectProtocol)?

    // MARK: - 开库

    /// 直接对着一个库文件开。
    ///
    /// 迁移那一步要往 `library.sqlite.new` 这个 sidecar 里写，所以路径是参数而不是写死的——
    /// sidecar 建好、校验过再 rename 成正式库，中途崩了磁盘上只有一个孤儿 `.new`，
    /// 旧的 JSON 一个字没动，下次启动重来。
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        sqlite = try SQLiteDatabase(path: fileURL)
        try Self.migrate(sqlite)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpoint() }
        }
    }

    /// `directory` 供测试注入临时目录；默认落 `~/Library/Application Support/Amber/`。
    ///
    /// 解析规则与 `LoudnessStore.init(directory:)` 逐字相同——四个 store 的构造器签名
    /// 一个字不改，就靠这一条：它们传进来的 `directory` 原样交给 `shared(directory:)`，
    /// 同一个目录换算出同一个 key，拿到同一条连接。
    convenience init(directory: URL?) throws {
        try self.init(fileURL: Self.fileURL(in: Self.resolvedDirectory(directory)))
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - 连接注册表

    /// 弱引用的盒子。库的生命周期跟着**持有它的 store**走，不跟着这张表走——
    /// 四个 store 都放掉之后条目自然变空壳，下次查到空壳就地删掉。
    ///
    /// 不用强引用：那等于给进程开了一个永不释放的单例，测试里每建一个临时目录
    /// 就多漏一条连接和一个打开的文件句柄，几百条用例跑下来会顶到文件描述符上限。
    private final class WeakBox {
        weak var value: AmberDatabase?
        init(_ value: AmberDatabase) { self.value = value }
    }

    private static var registry: [String: WeakBox] = [:]

    /// 按目录记忆化的共享连接。
    ///
    /// **这是「测试注入不改任何构造器签名」的全部机制**：`LibraryStore(directory:)` /
    /// `TrackInfoStore(directory:)` / `LoudnessStore(directory:)` / `DownloadStore(directory:)`
    /// 四个构造器里各自调一次这个函数，同一个 `directory` 就共用同一条连接、同一份
    /// `library.sqlite`。约 30 处测试调用点一个字不用动。
    ///
    /// **为什么不做单例**：测试里每条用例一个临时目录，进程里同时活着好几个库是常态。
    /// 按目录记忆化既满足「App 里只有一条连接」，又不把这个事实写死成全局。
    ///
    /// key 用**解析过符号链接、标准化之后的路径**：`FileManager.temporaryDirectory`
    /// 给的是 `/var/folders/…`，而 `/var` 是 `/private/var` 的符号链接。不解析的话
    /// 同一个目录的两种写法会各开一条连接，两条连接各有各的 WAL 读快照，
    /// 测试里表现为「刚写进去的行读不到」。
    static func shared(directory: URL?) throws -> AmberDatabase {
        let resolved = resolvedDirectory(directory)
        let key = resolved.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = registry[key]?.value { return existing }
        let database = try AmberDatabase(fileURL: fileURL(in: resolved))
        registry[key] = WeakBox(database)
        return database
    }

    /// 目录不存在就建出来——`sqlite3_open_v2` 的 `CREATE` 只建文件不建父目录，
    /// 少了这一步在全新机器上第一次启动会直接 `SQLITE_CANTOPEN`。
    private static func resolvedDirectory(_ directory: URL?) -> URL {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Amber", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    private static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("library.sqlite")
    }

    // MARK: - 退出前收尾

    /// 把 wal 并回主库并截断。
    ///
    /// WAL 会在库旁边留 `library.sqlite-wal` / `-shm`，只拷走 `.sqlite` 会拿到一份陈旧的库
    /// ——用户手动备份、或者 `sqlite3` 命令行事后核数时都会踩到。正常退出之后磁盘上
    /// 永远是「一个完整文件 + 0 字节 wal」。
    ///
    /// **现在这个观察者是空转的**：还没有任何 store 接到主库上来，checkpoint 也就没有
    /// 东西可并。它先写好，是因为三个 store 各自的 `willTerminate` 观察者
    /// （`LibraryStore` / `TrackInfoStore` / `LoudnessStore`）要合并到这一处来，
    /// 那时它们的 `flushNow()` 身体换成 checkpoint，名字与调用点全保留。
    ///
    /// 失败不抛：这是退出路径，能做的只有尽力而为——真 checkpoint 不掉（比如磁盘满），
    /// 下次开库 SQLite 自己会把 wal 重放回去，数据不丢，只是那份 `.sqlite` 一时是陈旧的。
    func checkpoint() {
        try? sqlite.checkpointTruncate()
    }

    // MARK: - 版本与升级链

    /// 初始 schema 就是 v1。
    private static let baselineVersion: Int32 = 1

    /// 升级链。**目前为空**——v1 是初始 schema，还没有任何一次升级。
    ///
    /// 每条在一个事务里跑：`BEGIN IMMEDIATE` → SQL → `PRAGMA user_version = n` → `COMMIT`。
    /// `user_version` 存在库头里、随事务原子提交，所以不会出现「表改了版本号没跟上」
    /// 或者反过来的中间态；建表之前就能读（新库读出 0），`sqlite3 库 "PRAGMA user_version"`
    /// 一条命令看得见。
    ///
    /// **优先加法**（`ADD COLUMN` / `CREATE TABLE` / `CREATE INDEX`）。这套机制替代的是
    /// 今天为了「加一个字段」手写的那一大串解码回落：`TrackInfo.init(from:)`
    /// （`TrackInfoStore.swift:118`，36 个字段逐条 `decodeIfPresent` 兜默认值）
    /// 与 `LibraryStore.Storage`（`:175-202`，同样一串）。那种写法的代价不是啰嗦，
    /// 是**它把「旧存档缺这个键」和「这个键解坏了」压成了同一种处置**——
    /// 一律回落默认值，于是数据出问题时一声不响。`ADD COLUMN … DEFAULT` 由 SQLite
    /// 一次性把默认值物化进每一行，读出来的永远是真实值。
    ///
    /// 非加法的升级（改列类型、拆表）在跑之前先 `cp library.sqlite library.sqlite.bak-v<n>`。
    private static let migrations: [(to: Int32, sql: String)] = []

    /// 当前库的 `user_version`。
    func userVersion() throws -> Int32 {
        try Self.userVersion(sqlite)
    }

    private static func userVersion(_ db: SQLiteDatabase) throws -> Int32 {
        try db.value("PRAGMA user_version") { Int32(truncatingIfNeeded: $0.int(0)) } ?? 0
    }

    /// 建库 / 补升级。开库路径上唯一会改 schema 的地方。
    ///
    /// 版本号就是幂等的闸：重复开同一个库，第二次读到的 `user_version` 已经是最新，
    /// 建表那段一条都不会再跑。所以 DDL 里**故意不写 `IF NOT EXISTS`**——写了就等于
    /// 给「版本号说建过了、表却不在」这种真正的坏账加了一层静音。让它当场炸。
    private static func migrate(_ db: SQLiteDatabase) throws {
        var version = try userVersion(db)

        if version == 0 {
            try db.transaction {
                try db.execute(schema)
                try db.execute("PRAGMA user_version = \(baselineVersion)")
            }
            version = baselineVersion
        }

        for step in migrations where step.to > version {
            try db.transaction {
                try db.execute(step.sql)
                try db.execute("PRAGMA user_version = \(step.to)")
            }
            version = step.to
        }
    }

    // MARK: - Schema

    /// v1 的全套建表语句。
    ///
    /// 注释写的是**为什么这么建**，尤其是那几条「故意不这么建」的——它们每一条都对应
    /// 一次实测，不写下来的话下一个人顺手「补全」就把语义改掉了，而且不会有任何报错。
    private static let schema = """
        -- ── 曲目主表 ────────────────────────────────────────────────────────────
        -- 收掉今天的 247 份副本（199 首唯一曲目摊在 libraryTracks/favorites/recents/
        -- 各歌单里各存一份完整 Track），于是 updateTrack 改一个字段不再要同步五处。
        --
        -- **不做 GC**：今天曲目掉出 recents 的 200 窗口就整条消失，于是「recents 里的歌
        -- 有几条已经不在资料库中」这种坑一直在。这里行留着，上界是「这辈子见过的曲目数」，
        -- 约 200 B/行。哪些歌在资料库里由下面五张关系表说了算，不由这张表的存在性说了算。
        CREATE TABLE track (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          artist_name TEXT NOT NULL,
          artist_id TEXT,
          album_name TEXT NOT NULL,
          album_id TEXT,
          artwork_url TEXT,
          duration REAL NOT NULL,
          -- 三态列：NULL = 音源没给，不是 0。取值必须走 Row.optInt。
          track_number INTEGER,
          disc_number INTEGER,
          media_mid TEXT,
          -- 同上，NULL = 未知，与「明确不是无损」不是一回事。
          lossless_available INTEGER,
          -- LibraryStore.fallbackKey(for:) 的结果，写入时物化。
          -- 不能在 SQL 里现算：那个 key 里有 lowercased()，而 SQLite 的 lower()
          -- 只折 ASCII（实测 LIKE '%чайков%' 匹不上 ЧАЙКОВСКИЙ），
          -- 现算出来的 key 和 Swift 算的不是一个东西，专辑归位会静默错。
          album_key TEXT NOT NULL
        );
        CREATE INDEX track_album_id ON track(album_id) WHERE album_id IS NOT NULL;
        CREATE INDEX track_album_key ON track(album_key);
        CREATE INDEX track_artist ON track(artist_name);

        -- ── 五张关系表（原来是五份数组）──────────────────────────────────────────
        -- position 保留人工排序：这几份在界面上是有序列表，不是集合。
        CREATE TABLE library_track  (track_id TEXT PRIMARY KEY REFERENCES track(id), position INTEGER NOT NULL);
        CREATE TABLE favorite_track (track_id TEXT PRIMARY KEY REFERENCES track(id), position INTEGER NOT NULL);
        CREATE TABLE recent_track   (track_id TEXT PRIMARY KEY REFERENCES track(id), position INTEGER NOT NULL);
        CREATE INDEX library_track_pos ON library_track(position);

        CREATE TABLE library_album (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          name TEXT NOT NULL,
          artist_name TEXT NOT NULL,
          artist_id TEXT,
          artwork_url TEXT,
          publish_date TEXT,
          track_count INTEGER NOT NULL,
          description TEXT,
          genre TEXT,
          album_type TEXT,
          position INTEGER NOT NULL,
          -- 原来是 albumAddedAt 一份独立字典，合进本行。
          -- 缺值时的回落（扫这张碟里曲目 addedAt 的最大值）是迁移时算一次写死，
          -- 不再是运行时每问一次就全表扫一遍。
          added_at REAL,
          album_key TEXT NOT NULL
        );
        CREATE INDEX library_album_key ON library_album(album_key);
        CREATE INDEX library_album_artist ON library_album(artist_name);

        CREATE TABLE playlist (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          -- LibraryPlaylist.Origin 的 rawValue：local / added / account
          origin TEXT NOT NULL,
          -- LibraryPlaylist.source: Playlist? 整块存 JSON。
          -- 不展开成列：它是音源歌单的原样快照，Amber 自己一个字段都不改、
          -- 也没有任何查询按它的内部字段筛。展开只会多十几列没人读的空值。
          source_json TEXT,
          cover_url TEXT,
          description TEXT,
          created_at REAL NOT NULL,
          added_at REAL NOT NULL,
          position INTEGER NOT NULL
        );

        -- 【故意不设 UNIQUE(playlist_id, track_id)】
        -- Music 允许同一首歌在一份列表里出现多次（addTracks 那里明写「不去重」）。
        -- 加唯一约束不是「更严谨」，是把一条产品行为改掉，而且是在插入时静默失败。
        -- 主键给 (playlist_id, position)：一份列表里位置才是唯一的那件事。
        CREATE TABLE playlist_track (
          playlist_id TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
          track_id TEXT NOT NULL REFERENCES track(id),
          position INTEGER NOT NULL,
          PRIMARY KEY (playlist_id, position)
        );
        CREATE INDEX playlist_track_track ON playlist_track(track_id);

        -- ── 搜索 ────────────────────────────────────────────────────────────────
        -- 一张 FTS5 表服务曲目 / 专辑 / 歌单 / 艺人四种对象，七处搜索收成一个口。
        --
        -- 用**普通 FTS5 表**（不是 external content）：所有写入本来就汇在 store 的几个
        -- 函数里，自己维护即可。external content 表要给每张源表各写 3 个触发器，
        -- 还要给 TEXT 主键另补一张 rowid 映射（FTS5 的 rowid 是整数），
        -- 换来的只是省掉一份正文副本。删除直接 DELETE … WHERE owner_id = ?，
        -- 普通表支持，external content 表不支持。
        --
        -- 各列的内容见 LibrarySearch.indexRow：表意文字逐字垫空格成 unigram + 三种拼音形态。
        -- 默认的 unicode61 分词器把整串汉字当一个 token，不垫空格的话「里香」搜不到
        -- 「七里香」——那是功能回归。
        --
        -- **正文为什么按字段分列。** 先前是一列 body、字段之间垫一个 unicode61 会当分隔符
        -- 丢掉的符号；而丢掉的符号**不占 token 位置**，短语邻近于是能跨字段成立——
        -- 实测搜「飛周」命中「帶你飛 / 周杰倫」这种曲名末字接艺人首字的假阳性。
        -- FTS5 的列语义恰好是要的那条：**短语不跨列、AND 跨列**，也就是
        -- 「字段内要相邻、字段之间只要都出现过」。
        --
        -- **phonetic 为什么反而可以合成一列。** 拼音查询永远不会变成短语：ftsQuery 对
        -- 拉丁词是一词一组、组间用 AND 连（dai ni fei → "dai"* AND "ni"* AND "fei"*），
        -- 没有邻近约束，也就没有跨字段泄漏可言。
        --
        -- 四种对象共用这六列，用不上的列写空串（专辑名只有曲目有，歌单的 artist 是创建者）。
        CREATE VIRTUAL TABLE search_index USING fts5(
          name,                   -- 曲名 / 专辑名 / 歌单名 / 艺人名
          artist,                 -- 曲目与专辑的艺人；歌单的创建者
          album,                  -- 只有曲目有
          phonetic,               -- 以上各段的拼音三形态，合成一列
          owner_kind UNINDEXED,   -- track | album | playlist | artist
          owner_id   UNINDEXED
        );

        -- ── 最近播放台账（上限 50）────────────────────────────────────────────────
        CREATE TABLE recent_container (
          position INTEGER PRIMARY KEY,      -- 0 = 最近
          dedupe_key TEXT NOT NULL UNIQUE,   -- RecentContainer.id
          kind TEXT NOT NULL,
          -- .track / .libraryPlaylist 只存 id，曲目与歌单从各自的表现取——
          -- 这一下删掉 updateTrack 的第五处写入点。
          ref_id TEXT,
          -- .album / .playlist / .artist 存原样 Codable JSON：这几个 case 故意是快照
          -- （音源那份专辑/歌单不在资料库里，没有表可以指）。不该规范化的不规范化。
          payload TEXT
        );

        -- ── 按 id 挂的账 ─────────────────────────────────────────────────────────
        -- 【故意不设外键】这一组全部不 REFERENCES track(id)。
        -- playCounts 今天就是游离 id 键：实测 lastPlayedAt 有 121 个键，
        -- 而 libraryTracks 只有 57 条——听过但没入库、入库后又移出的都在里面。
        -- 加上 FK 会让插入这些行直接失败，加上 FK CASCADE 更糟：把歌从资料库里移出
        -- 会顺手抹掉它这辈子的播放次数和评分，而且不会有任何提示。
        -- 「账按 id 记，与在不在资料库里无关」是现有语义，这里原样保住。
        CREATE TABLE track_stat (
          track_id TEXT PRIMARY KEY,
          play_count INTEGER NOT NULL DEFAULT 0,
          skip_count INTEGER NOT NULL DEFAULT 0,
          added_at REAL,
          last_played_at REAL,
          last_skipped_at REAL
        );
        CREATE INDEX track_stat_last_played ON track_stat(last_played_at) WHERE last_played_at IS NOT NULL;

        -- 曲目与专辑共用一张：评分的 id 空间本来就是混的（ratings 字典同款）。
        CREATE TABLE rating (id TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE favorite_album (id TEXT PRIMARY KEY);
        CREATE TABLE favorite_artist (id TEXT PRIMARY KEY);
        CREATE TABLE unchecked_track (id TEXT PRIMARY KEY);
        CREATE TABLE suggest_less_track (id TEXT PRIMARY KEY);
        CREATE TABLE suggest_less_artist (id TEXT PRIMARY KEY);
        CREATE TABLE dismissed_account_playlist (id TEXT PRIMARY KEY);

        -- 【missingFileTrackIDs 故意不建表】
        -- 文件在不在是磁盘此刻的事实，不是资料库属性。落盘只会得到一份一开机就过期的
        -- 快照：盘插回来了、文件找回来了，库里那条「失联」还在，界面照旧打感叹号。
        -- 它每次启动现扫，这条不变。

        -- ── 简介面板（原 trackinfo.json）─────────────────────────────────────────
        -- TrackInfo 三十多个字段全部展开成列，不存整块 JSON：面板是逐字段提交的，
        -- 而 comments / custom_lyrics 是长文本——改一个 bpm 不该把几 KB 歌词重写一遍。
        -- 「设置与长文本改动频率差两个数量级」这个诉求在 SQL 里由列级 UPDATE 天然满足。
        --
        -- 【title / artist / album / track_number / disc_number 五项故意不建列】
        -- info(for:) 每次都从 Track 现取：资料库那份才是权威（别处改过标题、
        -- 导入回填过专辑名，面板一打开就该看见新值）。存一份在这儿就是第二份真值，
        -- 而且是注定会发霉的那一份。
        CREATE TABLE track_info (
          track_id TEXT PRIMARY KEY,
          -- 详细信息页
          album_artist TEXT NOT NULL DEFAULT '',
          composer TEXT NOT NULL DEFAULT '',
          show_composer_in_all_views INTEGER NOT NULL DEFAULT 0,
          grouping TEXT NOT NULL DEFAULT '',
          genre TEXT NOT NULL DEFAULT '',
          year INTEGER,
          track_count INTEGER,
          disc_count INTEGER,
          is_compilation INTEGER NOT NULL DEFAULT 0,
          bpm INTEGER,
          comments TEXT NOT NULL DEFAULT '',
          use_work_and_movement INTEGER NOT NULL DEFAULT 0,
          work_name TEXT NOT NULL DEFAULT '',
          movement_name TEXT NOT NULL DEFAULT '',
          movement_number INTEGER,
          movement_count INTEGER,
          -- 选项页
          media_kind TEXT NOT NULL DEFAULT 'music',   -- TrackInfo.MediaKind 的 rawValue
          start_time_enabled INTEGER NOT NULL DEFAULT 0,
          start_time REAL NOT NULL DEFAULT 0,
          stop_time_enabled INTEGER NOT NULL DEFAULT 0,
          stop_time REAL,                             -- NULL = 用曲目原时长
          remember_playback_position INTEGER NOT NULL DEFAULT 0,
          skip_when_shuffling INTEGER NOT NULL DEFAULT 0,
          volume_adjustment INTEGER NOT NULL DEFAULT 0,  -- −255…255
          equalizer_preset TEXT,                      -- NULL =「无」
          -- 分类页
          sort_title TEXT NOT NULL DEFAULT '',
          sort_album TEXT NOT NULL DEFAULT '',
          sort_album_artist TEXT NOT NULL DEFAULT '',
          sort_artist TEXT NOT NULL DEFAULT '',
          sort_composer TEXT NOT NULL DEFAULT '',
          -- 歌词页：非 NULL ＝「自定义歌词」勾着，用这份纯文本顶掉音源的词
          custom_lyrics TEXT
        );

        -- 「记住播放位置」的断点。**不并进 track_info**：那张表是设置，这张是状态。
        -- 混在一起的话，面板每次比对「有没有改过」都会被播放进度搅成「改了」。
        -- 播放中每 0.1 s 来一次，由 store 侧的 5 秒台阶闸决定值不值得写。
        CREATE TABLE track_resume (track_id TEXT PRIMARY KEY, position REAL NOT NULL);

        -- ── 响度（原 loudness.json）──────────────────────────────────────────────
        -- 对着 LoudnessEntry。gainDB 是现算的派生量（目标 −16 LUFS、+6 上限、
        -- 峰值留 1 dB），不建列——把可调参数算出来的结果存下来，改参数那天就全是陈旧值。
        CREATE TABLE loudness (
          track_id TEXT PRIMARY KEY,
          lufs REAL NOT NULL,
          peak_db REAL NOT NULL,
          measured_at REAL NOT NULL
        );

        -- ── 本机文件 ────────────────────────────────────────────────────────────
        -- 一张表 + scope 列，不拆成两张。
        -- 「external 是权威、media 是可重建的投影」这个判断成立，但不变量不该由表边界
        -- 保证：十几处读点问的都是同一个问题（「这首歌在本机有文件吗，在哪」），
        -- 拆表要给它们全加 UNION，只换来 4 处少写一个 WHERE。
        -- 不变量改由重建语句的 WHERE scope='media' AND volume_uuid = ? 保证，
        -- 再由一条测试守住——测试还能同时守住「WHERE 写对了但 UPSERT 覆盖了
        -- external 行的 quality」这类表边界根本守不住的情况。
        --
        -- 【故意不对 track(id) 建外键】MV 用 "mv:<id>" 前缀键共用这张表，
        -- 那些键在 track 表里没有对应行。建了外键 MV 下载会直接插不进来。
        CREATE TABLE local_file (
          key TEXT PRIMARY KEY,        -- track.id 或 "mv:<id>"
          scope TEXT NOT NULL,         -- 'media' = 媒体夹内（投影，可重建）｜'external' = 原地引用（权威）
          relative_path TEXT NOT NULL, -- media 相对媒体夹；external 是绝对路径
          volume_uuid TEXT,
          -- bytes + mtime 判 staleness（差 > 2 s 才算被换过）。不存 sha256：
          -- 判文件变没变一次 stat 就够，而哈希的开销不在 CPU 在 IO（3000 首 × 40 MB 冷读）。
          bytes INTEGER NOT NULL,
          mtime REAL,
          added_at REAL NOT NULL,
          -- 展示文案（「无损 · 44.1 kHz 16 位 FLAC」），只给人看。
          quality TEXT,
          -- 结构化音质，全部来自已经在算的 StreamFormat，零额外 IO。
          -- 有了这四列，「按音质过滤 / 排序」才能是 INNER JOIN + ORDER BY；
          -- 拿 quality 排是按「无损 / 高音质 / 高解析度无损」的字面排，是错的。
          codec TEXT,
          sample_rate REAL,
          bit_depth INTEGER,
          tier TEXT,
          -- 三态：NULL = 还没补过标签，0 = 补过但失败。用 int() 取会把两者压成同一件事。
          tagged INTEGER,
          tag_version INTEGER
        );
        CREATE INDEX local_file_scope ON local_file(scope);
        CREATE INDEX local_file_volume ON local_file(volume_uuid) WHERE volume_uuid IS NOT NULL;
        CREATE INDEX local_file_tier ON local_file(tier) WHERE tier IS NOT NULL;
        """
}
