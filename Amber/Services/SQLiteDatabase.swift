import Foundation
import SQLite3

// MARK: - 关于这个文件里的 `unsafe`

// 这是全仓唯一直接调 `libsqlite3` 的地方，也是 strict memory safety
//（`SWIFT_STRICT_MEMORY_SAFETY`，SE-0458）下 `unsafe` 最密的一个文件。契约只有一条，
// 在这里写一次，下面每一处标记都指向它：
//
// **`sqlite3_*` 整族本身就是不安全契约的一部分。** 句柄是 `OpaquePointer`、文本是
// `UnsafePointer<CChar>`、out 参数是 `UnsafeMutablePointer<…>`——这不是我们写出来的裸指针，
// 是这套 C API 的形状，没有安全替代（不引 GRDB / SQLite.swift 的理由见 `SQLiteDatabase`）。
//
// 谁保证它安全：下面这两个类型，它们是不安全的**边界**，所以都标了 `@safe`——
//
// - `SQLiteDatabase` 从 `init` 建连接、`deinit` 收语句与连接，句柄与语句缓存全程私有、
//   一个都不外传；对外只收发 Swift 值类型（`String` / `Data` / `SQLValue` / `Row`）。
// - `Row` 只在 decode 闭包里活着，指向的语句由 `SQLiteDatabase` 持有。
//
// 于是上一层（`AmberDatabase` / `LibraryStore` 那些）一个 `unsafe` 都写不出来，
// 而这个文件里的 `unsafe` 一律**只是一个词、不带解释**：解释在这儿。
// 只有当某一处的契约**超出**这一条时才就地补一句——全文件只有四处那样
//（`transient`、`text` 的 NUL 结尾、`data` 的指针/长度配对、blob 绑定的借出范围）。
//
// 反过来说也成立：这个文件里冒出一个**没有**被上面两个类型罩住的 `unsafe`，
// 那就是真越界了，该当场停下来想，而不是照着旁边抄一个词。

// MARK: - 绑定

/// 能当参数绑进语句的类型。
///
/// 用协议而不是一堆 `init` 重载：重载遇到 `Optional` 会在「`Int` 还是 `Int?`」上
/// 反复挑，写调用点时要不停加显式类型。协议这边 `Optional` 只要一条条件遵循就全覆盖了。
protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

/// 绑进语句的那一个格子。对应 SQLite 的五种存储类。
enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }

/// 时间一律存 `REAL` 的 `timeIntervalSinceReferenceDate`。
///
/// 这是 `JSONEncoder` 的默认日期策略（`.deferredToDate`）用的同一个纪元，
/// 所以从旧的 JSON 存档迁过来时数字**原样搬**，不用换算，
/// 手写旧存档时间戳的那几条测试（`LibraryStoreDerivedTests` 一带）也继续有效。
extension Date: SQLBindable { var sqlValue: SQLValue { .double(timeIntervalSinceReferenceDate) } }

extension URL: SQLBindable { var sqlValue: SQLValue { .text(absoluteString) } }

extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

// MARK: - 出错

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    /// 出错的那条 SQL。错误信息里不带它的话，`SQLITE_ERROR: near "x": syntax error`
    /// 这种报错落到几十条语句的库里根本无从查起。
    let sql: String

    var description: String {
        sql.isEmpty ? "SQLite \(code): \(message)" : "SQLite \(code): \(message) —— SQL: \(sql)"
    }
}

// MARK: - 取行

/// 一行结果。**按列序号取，不按列名**——列名查表要为每个格子做一次字符串比较，
/// 而启动时一次全量读是几万行 × 十几列。序号由调用方按 `SELECT` 的书写顺序数，
/// 就近对着那条 SQL 看，比列名更不容易错。
///
/// - Important: **`Row` 只在 `query` / `value` 的 decode 闭包里活着，出了闭包就是废的。**
///
///   它只包一个指向语句的 `OpaquePointer`，不持有任何一行的数据——数据在 SQLite
///   那条语句内部的结果缓冲里。而语句是缓存复用的，`query` / `value` 走完都会
///   `reset` 它（见 `reset(_:)`），一复位结果缓冲就没了。复位之后 `sqlite3_column_*`
///   照样能调、不报错、不崩，只会**把每一列都答成 NULL**：`int` 读成 0、`text`
///   读成 ""、`isNull` 一律 true。
///
///   所以 `try db.value("SELECT …") { $0 }` 这种「把 Row 带出来再取值」的写法是
///   编译过、跑得动、数据全错的那一类坑，典型表现是「库里明明有行，读出来全是空」。
///   正确写法是**在闭包里取完值**，闭包只返回值类型：
///
///   ```swift
///   // 对：闭包返回元组
///   let t = try db.value("SELECT id, title FROM track") { (id: $0.text(0), title: $0.text(1)) }
///   // 错：Row 逃出去了，t?.text(0) 永远是 ""
///   let t = try db.value("SELECT id, title FROM track") { $0 }
///   ```
///
///   `testRowIsInvalidAfterEscaping` 专门钉住了这个表现，好让下一个踩进来的人
///   从测试名上直接看到答案。
///
///   （为什么不干脆用 `~Escapable` 让编译器拦住？这段从前写的是「那要 Swift 6 语言模式，
///   本工程还在 Swift 5 模式」——**这个理由已经过期，工程现在就是 Swift 6 语言模式**。
///   换了新理由之后结论没变，而且是两道，任一道都足够：
///
///   一、造不出来。`~Escapable` 的值必须由带生命周期标注的初始化器产出，而 `Row` 借的是
///   `sqlite3_stmt` 的行缓冲，没有可借的 Swift 值，唯一写得出的标注是 `@_lifetime(immortal)`。
///   实测（Swift 6.4）：`@lifetime` 要开实验特性 `LifetimeDependence`，`@_lifetime` 还要再开
///   一个 `Lifetimes`；两个都不开时连逐成员初始化器都不给，直接报
///   `an implicit initializer cannot return a ~Escapable result`。发布版不该开实验特性。
///
///   二、就算两个都开，这道闸也**拦不住它本该拦的那一下**。实测把 `Row` 改成 `~Escapable`
///   之后写 `db.value(sql) { $0 }` 并不报错：`T` 被推成了 `Void`，`$0` 变成一句被丢掉的
///   表达式，只给两条**警告**（`expression of type 'Row' is unused`、
///   `constant 't' inferred to have type '()?'`）；错误要等到下游真去用那个值才出来
///   （`value of tuple type '()' has no member 'int'`）。也就是说它买到的不是「在写错的那一行
///   拦住」，而是「在再下一行拦住」——比现在这段注释加 `testRowIsInvalidAfterEscaping` 强一点，
///   但离计划设想的那道类型闸还差着，不值得为它开两个实验特性。
///   等 `Lifetimes` 转正、且 `{ $0 }` 本身能报错，再回来改这段。）
///
/// `@safe` 是说**这个类型把不安全存储收在了安全接口里**：外面拿不到那个 `OpaquePointer`，
/// 每个取值方法回的都是 Swift 值类型。注意它保证的是内存安全，不是上面那条生命周期纪律——
/// 逃出闭包读到全空是「数据错」不是「越界」，那一条今天仍然只有注释和测试在守。
@safe struct Row {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { unsafe sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func int(_ i: Int32) -> Int64 { unsafe sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { unsafe sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { unsafe sqlite3_column_int64(stmt, i) != 0 }

    func text(_ i: Int32) -> String {
        guard let c = unsafe sqlite3_column_text(stmt, i) else { return "" }
        // 超出文件头那条契约的部分：`String(cString:)` 要求 `c` 以 NUL 结尾，
        // 这由 SQLite 保证（`sqlite3_column_text` 回的是 NUL 结尾的 UTF-8）。
        // 那块内存只活到下一次 `step` / `reset`，而这里当场拷成 `String`，没有借出去。
        return unsafe String(cString: c)
    }

    /// 三态列必须走这几个 `opt`：`trackNumber`、`losslessAvailable`、`tagged`
    /// 都是「没有这个值」与「值是 0 / false」意思不同的列，
    /// 用 `int()` 取会把 NULL 读成 0，把「还没补过标签」读成「补过了，结果是否」。
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : unsafe sqlite3_column_int64(stmt, i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : unsafe sqlite3_column_double(stmt, i) }
    func optBool(_ i: Int32) -> Bool? { isNull(i) ? nil : unsafe sqlite3_column_int64(stmt, i) != 0 }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }

    func date(_ i: Int32) -> Date? {
        isNull(i) ? nil : unsafe Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, i))
    }

    func data(_ i: Int32) -> Data? {
        guard !isNull(i), let bytes = unsafe sqlite3_column_blob(stmt, i) else { return nil }
        // 超出文件头那条契约的部分：`Data(bytes:count:)` 按给的长度从裸指针拷，
        // 指针与长度必须取自**同一列、同一次取值**。`_blob` 与 `_bytes` 就是那一对，
        // 且顺序不能倒——SQLite 文档明说最稳的写法是先 `_blob` 再 `_bytes`，
        // 反过来会先触发类型转换，之前拿到的 blob 指针可能已经失效。
        return unsafe Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

// MARK: - 连接

/// 裸 `libsqlite3` 的薄封装：开库、准备语句、绑参、取行、事务。
///
/// **不认识 Amber 的任何模型**——建表、schema 升级、业务查询都在上一层。
///
/// 为什么不引 GRDB / SQLite.swift：这个工程零第三方依赖，而需求很窄（一张宽表 +
/// 十几张从表，没有复杂查询组合），两百行封装就够。不值得为它开一个依赖，
/// 以及依赖背后对 Swift 版本与并发模型的绑定。
///
/// **线程**：普通 `final class`，**不是** `Sendable`，也不加锁。所有访问都在
/// `@MainActor` 的 store 里。要后台干活的话，正确的切法是后台只做文件 IO 与解析，
/// 解析出的值类型交回主 actor 再写库（照 `ImportService` 那套）。
///
/// ## 为什么它没有被收进 `actor`（2026-09-17，modernization-review §2.4-1 的落点）
///
/// 审查单的修法是「把 `AmberDatabase`/`SQLiteDatabase` 收进一个 `actor`，四个 store
/// 保持 `@MainActor` 但读写 `await`，**先只搬只读的两条路**」。**后半句与前半句
/// 互相排斥**，这不是工程量问题，是 Swift 的隔离模型问题：
///
/// **actor 隔离是按对象算的，不是按方法算的。** 这个类一旦进 actor，**所有**
/// 入口同时变成 `await`——没有「只搬两条」这种中间态。而写入那一侧当场就不成立：
///
/// - `LibraryStore.persist(_:_:)` 的 body 是 `(SQLiteDatabase) throws -> Void`，
///   34 个调用点、33 个 `in db: SQLiteDatabase` 的助手。这些助手**不是纯写**——
///   它们在同一条语句里就读主 actor 的内存。最直白的一个是
///   `LibraryStore.persistStat(id:in:)`：绑定数组本身就是
///   `[id, playCounts[id] ?? 0, skipCounts[id] ?? 0, addedAt[id], …]`，五本主 actor
///   的字典摆在 `db.run` 的参数里。
/// - 更硬的是 `LibraryStore.persistAllPlaylists(in:)`：它在**一个事务里**交替做
///   「`SELECT` 现有 id」→「读主 actor 的 `playlists`」→「`DELETE`」→
///   「调同样 `@MainActor` 的 `searchIndex.delete`」。跨 actor 就是跨挂起点，
///   而 SQLite 的事务是**连接级**的——中间挂起，别人拿同一条连接发的语句会落进
///   这个还没提交的事务里。
///
/// 所以真正的先决条件是：**把这 33 个助手拆成「在主 actor 上取值」+「在 actor 上写」
/// 两半**，写的那一半只收值类型。那是一次独立的改造，不是「顺手搬两条路」。
///
/// 而那两条只读路各自还另有一堵墙，都不在本批文件的所有权范围内：
///
/// - `searchFilter`：七个调用点全在 `Views/Shell/**`（清单在它自己的注释里），
///   改 `async` 等于把七页的同步刷新链一起改成异步。
/// - `loadFromDatabase`：它跑在 `LibraryStore.init` 里，而 `init` 同步返回时
///   内存模型必须是满的——25 处测试构造点紧跟着就同步断言。
///
/// **不要用 `@unchecked Sendable` + 锁来绕过这一条。** 那条路通（把 `db`/`cache`/
/// `transactionDepth` 收进一把可重入锁就能让它 `Sendable`），但买回来的东西是负的：
/// 后台那一趟全量读会**持锁**几十毫秒，主线程此刻任何一次 `persist` 都得等它——
/// 等于把「读不再卡主线程」换成「写开始卡主线程」。要并行读写得开第二条连接
/// （WAL 允许），那又与「连接本就只有一条」冲突，并且每个 `AmberDatabase` 多一组
/// 文件描述符——测试里每条用例一个临时目录，`AmberDatabase.shared` 的注释里
/// 写着为什么这件事要紧。
///
/// `@safe`：连接句柄与语句缓存全程私有、一个都不外传，对外只收发 Swift 值类型——
/// 不安全到这个类的边界为止。详见文件头那段。
@safe final class SQLiteDatabase {

    private var db: OpaquePointer?

    /// 准备好的语句缓存。`sqlite3_prepare_v2` 一次约 20–50 µs，缓存后复用约 2 µs；
    /// 记一次播放这种「每首歌走一遍」的路径值这一下。
    ///
    /// 不做淘汰：语句是代码里的字面量，条目数由代码量封顶（几十条），不随数据增长。
    private var cache: [String: OpaquePointer] = unsafe [:]

    /// 事务深度。见 `transaction` 的注释。
    private var transactionDepth = 0

    /// `sqlite3_bind_text` / `_blob` 的最后一个参数。
    ///
    /// **这是整个封装唯一一个会静默写出脏数据的坑**：默认的 `SQLITE_STATIC` 是
    /// 「这块内存我不管，你保证它一直在」，而 Swift `String` 递给 C 的是一个
    /// 调用结束就失效的临时缓冲。传 `STATIC` 编译过、跑得动、大多数时候还对，
    /// 直到某次那块内存被复用——写进库里的就是一段乱码。`TRANSIENT` 让 SQLite
    /// 自己复制一份，代价是一次 memcpy。永远传它。
    ///
    /// 超出文件头那条契约的部分：`SQLITE_TRANSIENT` 在 C 头文件里是
    /// `((sqlite3_destructor_type)-1)`，一个当哨兵用的假函数指针，导进 Swift 之后只剩
    /// `unsafeBitCast` 能写出来。它永远不会被调用——SQLite 认的是这个值本身，
    /// 谁保证它安全就是这一条。
    private static let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: 开与关

    init(path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = unsafe sqlite3_open_v2(path.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle = unsafe handle else {
            let message = unsafe handle.map { unsafe String(cString: sqlite3_errmsg($0)) }
                ?? "无法打开数据库"
            unsafe sqlite3_close(handle)
            throw SQLiteError(code: code, message: message, sql: "open \(path.path)")
        }
        unsafe db = handle
        try execute(Self.pragmas)
    }

    /// 开库就位的一套 PRAGMA。
    ///
    /// - `WAL`：提交变成往 wal 追加，不再是回滚日志往返 + 多次 fsync。
    /// - `synchronous = NORMAL`：WAL 下的正解。耐久性口径要说清楚——**App 崩溃不丢**
    ///   （数据已经交给内核），只有掉电 / 内核 panic 会丢最后几笔事务。
    ///   对照从前那版「500 ms 防抖 + 整份覆盖」，这是严格变好，不是让步。
    /// - `foreign_keys`：只有 `playlist_track → playlist` 的 CASCADE 用得上，但默认关着，
    ///   不显式打开的话那条外键就是一句没人执行的注释。
    /// - `busy_timeout`：现在只有一条连接用不上，留着是为了将来拿 `sqlite3` 命令行
    ///   戳这个库时不会当场把 App 顶出 `SQLITE_BUSY`。
    private static let pragmas = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        PRAGMA busy_timeout = 5000;
        PRAGMA temp_store = MEMORY;
        """

    deinit {
        // 三个 `unsafe` 各管一段，for-in 就是这么拆的：`for unsafe` 管迭代器与每轮的元素，
        // `in unsafe` 管被遍历的那个表达式，最后一个管循环体。缺任何一个都还报。
        for unsafe stmt in unsafe cache.values { unsafe sqlite3_finalize(stmt) }
        unsafe cache.removeAll()
        // 用 close 不用 close_v2：还有语句没 finalize 时 close 会回 SQLITE_BUSY，
        // 而 close_v2 会把连接标成僵尸慢慢泄漏，出问题时什么都看不见。
        unsafe sqlite3_close(db)
    }

    // MARK: 执行

    /// 跑一段可以有多条语句的 SQL（建表、PRAGMA）。不接参数——要接参数就用 `run`。
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = unsafe sqlite3_exec(db, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = unsafe error.map { unsafe String(cString: $0) } ?? "未知错误"
            unsafe sqlite3_free(error)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    /// 跑一条写语句，返回受影响的行数。
    @discardableResult
    func run(_ sql: String, _ binds: [any SQLBindable] = []) throws -> Int {
        let stmt = try unsafe prepared(sql)
        defer { unsafe reset(stmt) }
        try unsafe bind(binds, to: stmt, sql: sql)
        let code = unsafe sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(sql) }
        return Int(unsafe sqlite3_changes(db))
    }

    /// 跑一条查询，逐行交给 `decode`。
    func query<T>(_ sql: String, _ binds: [any SQLBindable] = [],
                  _ decode: (Row) -> T) throws -> [T] {
        let stmt = try unsafe prepared(sql)
        defer { unsafe reset(stmt) }
        try unsafe bind(binds, to: stmt, sql: sql)
        var out: [T] = []
        while true {
            let code = unsafe sqlite3_step(stmt)
            if code == SQLITE_ROW { out.append(decode(unsafe Row(stmt: stmt))) } else if code == SQLITE_DONE {
                break
            } else {
                throw error(sql)
            }
        }
        return out
    }

    /// 只要第一行；没有行就是 nil。
    func value<T>(_ sql: String, _ binds: [any SQLBindable] = [],
                  _ decode: (Row) -> T) throws -> T? {
        let stmt = try unsafe prepared(sql)
        defer { unsafe reset(stmt) }
        try unsafe bind(binds, to: stmt, sql: sql)
        let code = unsafe sqlite3_step(stmt)
        if code == SQLITE_ROW { return decode(unsafe Row(stmt: stmt)) }
        guard code == SQLITE_DONE else { throw error(sql) }
        return nil
    }

    var lastInsertRowID: Int64 { unsafe sqlite3_last_insert_rowid(db) }

    // MARK: 事务

    /// 把 `body` 包进一个事务；`body` 抛错就整个回滚。
    ///
    /// 用 `BEGIN IMMEDIATE` 而不是裸 `BEGIN`：后者是 deferred，到第一次写才去拿写锁，
    /// 拿不到时给出的是**没法重试**的 `SQLITE_BUSY`（读事务已经开着，退不回去）。
    /// 现在只有一条连接碰不到，但这是零成本的正确默认值。
    ///
    /// 嵌套时内层不再 BEGIN，直接并进外层那个事务：SQLite 不支持嵌套事务，
    /// 而「外层已经开着」在写入路径上是常事（一次入库 = 写曲目 + 写关系表 + 写搜索索引）。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try body() }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            // 回滚失败没什么可做的（多半是连接已经废了），别用它盖掉真正的错。
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// 把 wal 并回主库文件并截断它。
    ///
    /// WAL 会在库旁边留 `-wal` / `-shm` 两个文件，只拷走 `.sqlite` 会拿到一份陈旧的库。
    /// 退出前跑一次，正常退出之后磁盘上永远是「一个完整文件 + 0 字节 wal」。
    func checkpointTruncate() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: 内部

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = unsafe cache[sql] { return unsafe cached }
        var stmt: OpaquePointer?
        guard unsafe sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = unsafe stmt else {
            let e = error(sql)
            unsafe sqlite3_finalize(stmt)
            throw e
        }
        unsafe cache[sql] = stmt
        return unsafe stmt
    }

    /// 用完就复位。
    ///
    /// `reset` 之外还要 `clear_bindings`：语句是缓存复用的，上一轮绑的参数会原样留着，
    /// 下一轮少绑一个格子就会**悄悄拿上次的值去写**——不报错，数据是错的。
    private func reset(_ stmt: OpaquePointer) {
        unsafe sqlite3_reset(stmt)
        unsafe sqlite3_clear_bindings(stmt)
    }

    private func bind(_ binds: [any SQLBindable], to stmt: OpaquePointer, sql: String) throws {
        let expected = Int(unsafe sqlite3_bind_parameter_count(stmt))
        guard binds.count == expected else {
            throw SQLiteError(code: SQLITE_MISUSE,
                              message: "参数个数对不上：语句要 \(expected) 个，给了 \(binds.count) 个",
                              sql: sql)
        }
        for (offset, value) in binds.enumerated() {
            let i = Int32(offset + 1)
            let code: Int32
            switch value.sqlValue {
            case .null: code = unsafe sqlite3_bind_null(stmt, i)
            case .int(let v): code = unsafe sqlite3_bind_int64(stmt, i, v)
            case .double(let v): code = unsafe sqlite3_bind_double(stmt, i, v)
            case .text(let v): code = unsafe sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                // 超出文件头那条契约的部分：`withUnsafeBytes` 借出的指针只在闭包里有效，
                // 而 `sqlite3_bind_blob` 在闭包内同步调用、且末参是 `transient`
                // （SQLite 当场复制），所以指针不会活过这一行。
                code = unsafe v.isEmpty
                    ? sqlite3_bind_zeroblob(stmt, i, 0)
                    : v.withUnsafeBytes { unsafe sqlite3_bind_blob(stmt, i, $0.baseAddress,
                                                                   Int32(v.count), Self.transient) }
            }
            guard code == SQLITE_OK else { throw error(sql) }
        }
    }

    private func error(_ sql: String) -> SQLiteError {
        unsafe SQLiteError(code: sqlite3_errcode(db),
                           message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }
}
