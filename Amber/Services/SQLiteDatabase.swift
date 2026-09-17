import Foundation
import SQLite3

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
///   （为什么不干脆用 `~Escapable` 让编译器拦住：那要 Swift 6 语言模式，本工程还在
///   Swift 5 模式；等切过去可以把这段注释换成类型系统的约束。）
struct Row {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }

    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    /// 三态列必须走这几个 `opt`：`trackNumber`、`losslessAvailable`、`tagged`
    /// 都是「没有这个值」与「值是 0 / false」意思不同的列，
    /// 用 `int()` 取会把 NULL 读成 0，把「还没补过标签」读成「补过了，结果是否」。
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
    func optBool(_ i: Int32) -> Bool? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) != 0 }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }

    func date(_ i: Int32) -> Date? {
        isNull(i) ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, i))
    }

    func data(_ i: Int32) -> Data? {
        guard !isNull(i), let bytes = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
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
final class SQLiteDatabase {

    private var db: OpaquePointer?

    /// 准备好的语句缓存。`sqlite3_prepare_v2` 一次约 20–50 µs，缓存后复用约 2 µs；
    /// 记一次播放这种「每首歌走一遍」的路径值这一下。
    ///
    /// 不做淘汰：语句是代码里的字面量，条目数由代码量封顶（几十条），不随数据增长。
    private var cache: [String: OpaquePointer] = [:]

    /// 事务深度。见 `transaction` 的注释。
    private var transactionDepth = 0

    /// `sqlite3_bind_text` / `_blob` 的最后一个参数。
    ///
    /// **这是整个封装唯一一个会静默写出脏数据的坑**：默认的 `SQLITE_STATIC` 是
    /// 「这块内存我不管，你保证它一直在」，而 Swift `String` 递给 C 的是一个
    /// 调用结束就失效的临时缓冲。传 `STATIC` 编译过、跑得动、大多数时候还对，
    /// 直到某次那块内存被复用——写进库里的就是一段乱码。`TRANSIENT` 让 SQLite
    /// 自己复制一份，代价是一次 memcpy。永远传它。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: 开与关

    init(path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            throw SQLiteError(code: code, message: message, sql: "open \(path.path)")
        }
        db = handle
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
        for stmt in cache.values { sqlite3_finalize(stmt) }
        cache.removeAll()
        // 用 close 不用 close_v2：还有语句没 finalize 时 close 会回 SQLITE_BUSY，
        // 而 close_v2 会把连接标成僵尸慢慢泄漏，出问题时什么都看不见。
        sqlite3_close(db)
    }

    // MARK: 执行

    /// 跑一段可以有多条语句的 SQL（建表、PRAGMA）。不接参数——要接参数就用 `run`。
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    /// 跑一条写语句，返回受影响的行数。
    @discardableResult
    func run(_ sql: String, _ binds: [any SQLBindable] = []) throws -> Int {
        let stmt = try prepared(sql)
        defer { reset(stmt) }
        try bind(binds, to: stmt, sql: sql)
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(sql) }
        return Int(sqlite3_changes(db))
    }

    /// 跑一条查询，逐行交给 `decode`。
    func query<T>(_ sql: String, _ binds: [any SQLBindable] = [],
                  _ decode: (Row) -> T) throws -> [T] {
        let stmt = try prepared(sql)
        defer { reset(stmt) }
        try bind(binds, to: stmt, sql: sql)
        var out: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW { out.append(decode(Row(stmt: stmt))) } else if code == SQLITE_DONE {
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
        let stmt = try prepared(sql)
        defer { reset(stmt) }
        try bind(binds, to: stmt, sql: sql)
        let code = sqlite3_step(stmt)
        if code == SQLITE_ROW { return decode(Row(stmt: stmt)) }
        guard code == SQLITE_DONE else { throw error(sql) }
        return nil
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

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
        if let cached = cache[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let e = error(sql)
            sqlite3_finalize(stmt)
            throw e
        }
        cache[sql] = stmt
        return stmt
    }

    /// 用完就复位。
    ///
    /// `reset` 之外还要 `clear_bindings`：语句是缓存复用的，上一轮绑的参数会原样留着，
    /// 下一轮少绑一个格子就会**悄悄拿上次的值去写**——不报错，数据是错的。
    private func reset(_ stmt: OpaquePointer) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    private func bind(_ binds: [any SQLBindable], to stmt: OpaquePointer, sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard binds.count == expected else {
            throw SQLiteError(code: SQLITE_MISUSE,
                              message: "参数个数对不上：语句要 \(expected) 个，给了 \(binds.count) 个",
                              sql: sql)
        }
        for (offset, value) in binds.enumerated() {
            let i = Int32(offset + 1)
            let code: Int32
            switch value.sqlValue {
            case .null: code = sqlite3_bind_null(stmt, i)
            case .int(let v): code = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): code = sqlite3_bind_double(stmt, i, v)
            case .text(let v): code = sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                code = v.isEmpty
                    ? sqlite3_bind_zeroblob(stmt, i, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count),
                                                            Self.transient) }
            }
            guard code == SQLITE_OK else { throw error(sql) }
        }
    }

    private func error(_ sql: String) -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }
}
