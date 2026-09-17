import XCTest
@testable import Amber

/// 裸 sqlite3 封装层。这里钉的几乎都是**不报错但写出脏数据**那一类，
/// 编译过、跑得动、断言不写就永远发现不了。
final class SQLiteDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: SQLiteDatabase!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 五种存储类往返

    func testRoundTripsEveryStorageClass() throws {
        try db.execute("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, n INTEGER)")
        let blob = Data([0x00, 0xFF, 0x42, 0x00])   // 带 0 字节：当成 C 字符串处理就会被截断
        try db.run("INSERT INTO t VALUES(?,?,?,?,?)",
                   [42, 3.5, "文字 text", blob, SQLValue.null])

        // 取值一律在 decode 闭包里做，闭包只返回值类型——`Row` 出了闭包就读成空，
        // 见 `testRowIsInvalidAfterEscaping`。
        let row = try XCTUnwrap(try db.value("SELECT i, d, s, b, n FROM t") {
            (i: $0.int(0), d: $0.double(1), s: $0.text(2), b: $0.data(3), nIsNull: $0.isNull(4))
        })
        XCTAssertEqual(row.i, 42)
        XCTAssertEqual(row.d, 3.5, accuracy: 0.0001)
        XCTAssertEqual(row.s, "文字 text")
        XCTAssertEqual(row.b, blob)
        XCTAssertTrue(row.nIsNull)
    }

    // MARK: Row 的存活期

    /// **这条钉的是一个已知陷阱的表现，不是期望的用法。**别照着它写业务代码。
    ///
    /// `Row` 只包一个指向语句的指针，不持有数据；`query` / `value` 走完都会 `reset`
    /// 那条语句（语句是缓存复用的，必须复位）。所以把 `Row` 带出 decode 闭包之后再取值，
    /// 取到的是复位后的空语句：不报错、不崩，每一列都答成 NULL —— `int` 是 0、`text` 是 ""、
    /// `isNull` 一律 true。表现就是「库里明明有行，读出来全是空」，查半天查不到源头。
    ///
    /// 把它钉下来有两个用处：一是这条行为真变了（比如哪天换成持有数据的 Row）测试会红，
    /// 提醒来改上面那段注释；二是下一个踩进来的人搜「读出来全是空」时，
    /// 测试名会直接告诉他答案。正确写法见同文件其余各条：闭包里取完值，只返回值类型。
    func testRowIsInvalidAfterEscaping() throws {
        try db.execute("CREATE TABLE t(i INTEGER, s TEXT)")
        try db.run("INSERT INTO t VALUES(?,?)", [42, "在库里"])

        // 闭包里取：这才是该有的写法，读得到真数据。
        let inside = try XCTUnwrap(try db.value("SELECT i, s FROM t") {
            (i: $0.int(0), s: $0.text(1))
        })
        XCTAssertEqual(inside.i, 42)
        XCTAssertEqual(inside.s, "在库里")

        // 带出闭包再取：同一行，全成空。
        let escaped = try XCTUnwrap(try db.value("SELECT i, s FROM t") { $0 })
        XCTAssertEqual(escaped.int(0), 0, "Row 逃出闭包后语句已复位，读到的不是那一行")
        XCTAssertEqual(escaped.text(1), "")
        XCTAssertTrue(escaped.isNull(0),
                      "失效后每一列都报 NULL，跟「这列真的是 NULL」在调用点上分不开")
    }

    /// 日期走 `timeIntervalSinceReferenceDate`，与旧 JSON 存档同一个纪元——
    /// 迁移时数字原样搬，不换算。
    func testDateUsesReferenceDateEpoch() throws {
        try db.execute("CREATE TABLE t(at REAL)")
        let date = Date(timeIntervalSinceReferenceDate: 810_627_409.26319)
        try db.run("INSERT INTO t VALUES(?)", [date])

        XCTAssertEqual(try db.value("SELECT at FROM t") { $0.double(0) }!,
                       810_627_409.26319, accuracy: 0.000001)
        XCTAssertEqual(try db.value("SELECT at FROM t") { $0.date(0) }!, date)
    }

    // MARK: 三态：NULL 与 0 / false 不是一回事

    /// `trackNumber`、`losslessAvailable`、`tagged` 都是三态列。
    /// 用 `int()` / `bool()` 取会把 NULL 读成 0 / false——
    /// 「还没补过标签」就此变成「补过了，结果是否」，而且一声不吭。
    func testOptAccessorsDistinguishNullFromZero() throws {
        try db.execute("CREATE TABLE t(id TEXT, n INTEGER, flag INTEGER, s TEXT, d REAL)")
        try db.run("INSERT INTO t VALUES('zero', 0, 0, '', 0.0)")
        try db.run("INSERT INTO t VALUES('null', NULL, NULL, NULL, NULL)")

        let zero = try XCTUnwrap(try db.value("SELECT n, flag, s, d FROM t WHERE id='zero'") {
            (n: $0.optInt(0), flag: $0.optBool(1), s: $0.optText(2), d: $0.optDouble(3))
        })
        XCTAssertEqual(zero.n, 0)
        XCTAssertEqual(zero.flag, false)
        XCTAssertEqual(zero.s, "")
        XCTAssertEqual(zero.d, 0)

        // 同一行里把 opt 组和非 opt 组一起取出来，好把两者的差别摆在一处看。
        let null = try XCTUnwrap(try db.value("SELECT n, flag, s, d FROM t WHERE id='null'") {
            (n: $0.optInt(0), flag: $0.optBool(1), s: $0.optText(2), d: $0.optDouble(3),
             rawN: $0.int(0), rawFlag: $0.bool(1))
        })
        XCTAssertNil(null.n)
        XCTAssertNil(null.flag)
        XCTAssertNil(null.s)
        XCTAssertNil(null.d)
        // 非 opt 的那组照旧把 NULL 读成 0：这是 SQLite 的行为，不是 bug，
        // 钉住它是为了说明「该用 opt 的地方用错了会发生什么」。
        XCTAssertEqual(null.rawN, 0)
        XCTAssertFalse(null.rawFlag)
    }

    /// `Optional` 的条件遵循：`nil` 绑成 NULL，有值绑成值。
    func testOptionalBindsAsNull() throws {
        try db.execute("CREATE TABLE t(a TEXT, b INTEGER, c REAL)")
        try db.run("INSERT INTO t VALUES(?,?,?)",
                   [String?.none, Int?.some(7), Date?.none])

        let row = try XCTUnwrap(try db.value("SELECT a, b, c FROM t") {
            (a: $0.optText(0), b: $0.optInt(1), c: $0.optDouble(2))
        })
        XCTAssertNil(row.a)
        XCTAssertEqual(row.b, 7)
        XCTAssertNil(row.c)
    }

    // MARK: 语句缓存

    /// 语句是缓存复用的。用完只 `reset` 不 `clear_bindings` 的话，上一轮绑的参数
    /// 会原样留在格子里，下一轮少绑一个就**悄悄拿上次的值去写**。
    /// 这里连着用同一条 SQL 绑不同的参数，确认每一轮都只看见自己那份。
    func testCachedStatementDoesNotLeakPreviousBindings() throws {
        try db.execute("CREATE TABLE t(id INTEGER, s TEXT)")
        for i in 1...5 {
            try db.run("INSERT INTO t VALUES(?,?)", [i, "第\(i)条"])
        }
        let all = try db.query("SELECT id, s FROM t ORDER BY id") { ($0.int(0), $0.text(1)) }
        XCTAssertEqual(all.map(\.0), [1, 2, 3, 4, 5])
        XCTAssertEqual(all.map(\.1), ["第1条", "第2条", "第3条", "第4条", "第5条"])

        // 同一条 SELECT 连查两次，第二次不该受第一次的绑定影响。
        let first = try db.query("SELECT s FROM t WHERE id = ?", [2]) { $0.text(0) }
        let second = try db.query("SELECT s FROM t WHERE id = ?", [4]) { $0.text(0) }
        XCTAssertEqual(first, ["第2条"])
        XCTAssertEqual(second, ["第4条"])
    }

    /// 上一条查询没取完就撒手（`value` 只取第一行），语句仍停在半途。
    /// 下一次复用之前必须复位，否则接着上次的游标往下走。
    func testPartiallyConsumedStatementIsResetBeforeReuse() throws {
        try db.execute("CREATE TABLE t(id INTEGER)")
        for i in 1...3 { try db.run("INSERT INTO t VALUES(?)", [i]) }

        XCTAssertEqual(try db.value("SELECT id FROM t ORDER BY id") { $0.int(0) }, 1)
        XCTAssertEqual(try db.value("SELECT id FROM t ORDER BY id") { $0.int(0) }, 1)
        XCTAssertEqual(try db.query("SELECT id FROM t ORDER BY id") { $0.int(0) }, [1, 2, 3])
    }

    // MARK: SQLITE_TRANSIENT

    /// 绑字符串传 `SQLITE_STATIC` 会让 SQLite 记住一个调用结束就失效的 Swift 临时缓冲。
    /// 大多数时候还读得对，直到那块内存被复用——写进库的就是乱码，不报任何错。
    ///
    /// 用「动态拼的长字符串 + 大量分配」把复用概率顶上去。
    func testLongDynamicStringsSurviveBinding() throws {
        try db.execute("CREATE TABLE t(id INTEGER, s TEXT)")
        var expected: [String] = []
        for i in 0..<200 {
            let s = String(repeating: "长字符串\(i)·", count: 40)
            expected.append(s)
            try db.run("INSERT INTO t VALUES(?,?)", [i, s])
            _ = (0..<50).map { String(repeating: "垃圾", count: $0 + 1) }   // 搅动分配器
        }
        let read = try db.query("SELECT s FROM t ORDER BY id") { $0.text(0) }
        XCTAssertEqual(read, expected)
    }

    // MARK: 事务

    func testTransactionCommits() throws {
        try db.execute("CREATE TABLE t(id INTEGER)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES(1)")
            try db.run("INSERT INTO t VALUES(2)")
        }
        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 2)
    }

    func testTransactionRollsBackOnThrow() throws {
        struct Boom: Error {}
        try db.execute("CREATE TABLE t(id INTEGER)")
        try db.run("INSERT INTO t VALUES(0)")

        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES(1)")
            try db.run("INSERT INTO t VALUES(2)")
            throw Boom()
        }) { XCTAssertTrue($0 is Boom, "抛出去的该是 body 的错，不是回滚过程里的错") }

        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 1,
                       "整个事务都该回滚，只剩事务之前那条")
    }

    /// SQLite 不支持嵌套事务，而「外层已经开着」在写入路径上是常事
    /// （一次入库 = 写曲目 + 写关系表 + 写搜索索引）。内层要并进外层，不能自己再 BEGIN。
    func testNestedTransactionJoinsOuter() throws {
        try db.execute("CREATE TABLE t(id INTEGER)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES(1)")
            try db.transaction { try db.run("INSERT INTO t VALUES(2)") }
            try db.run("INSERT INTO t VALUES(3)")
        }
        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 3)
    }

    /// 内层抛错 → 外层整个回滚，且事务深度归零（否则下一个事务会以为自己是嵌套的，
    /// 永远不再真正 BEGIN／COMMIT）。
    func testTransactionDepthResetsAfterFailure() throws {
        struct Boom: Error {}
        try db.execute("CREATE TABLE t(id INTEGER)")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES(1)")
            try db.transaction { throw Boom() }
        })
        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 0)

        try db.transaction { try db.run("INSERT INTO t VALUES(9)") }
        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 1,
                       "深度没归零的话这一笔提交不了")
    }

    // MARK: 报错

    func testErrorCarriesMessageAndSQL() throws {
        let sql = "SELECT * FROM 这张表不存在"
        XCTAssertThrowsError(try db.query(sql) { $0.int(0) }) { error in
            guard let e = error as? SQLiteError else { return XCTFail("该是 SQLiteError：\(error)") }
            XCTAssertEqual(e.sql, sql, "错误要带上是哪条 SQL 出的问题，否则几十条语句里无从查起")
            XCTAssertFalse(e.message.isEmpty)
            XCTAssertTrue(e.description.contains("这张表不存在"))
        }
    }

    /// 参数个数对不上要当场报错。不拦的话 SQLite 会把没绑的格子当 NULL 写进去。
    func testBindCountMismatchThrows() throws {
        try db.execute("CREATE TABLE t(a INTEGER, b INTEGER)")
        XCTAssertThrowsError(try db.run("INSERT INTO t VALUES(?,?)", [1])) { error in
            guard let e = error as? SQLiteError else { return XCTFail("该是 SQLiteError：\(error)") }
            XCTAssertTrue(e.message.contains("参数个数"))
        }
        XCTAssertEqual(try db.value("SELECT count(*) FROM t") { $0.int(0) }, 0)
    }

    // MARK: 落盘

    func testRunReportsChanges() throws {
        try db.execute("CREATE TABLE t(id INTEGER)")
        for i in 1...3 { try db.run("INSERT INTO t VALUES(?)", [i]) }
        XCTAssertEqual(try db.run("UPDATE t SET id = id + 10 WHERE id > 1"), 2)
        XCTAssertEqual(try db.run("DELETE FROM t WHERE id > 100"), 0)
    }

    /// WAL 会在库旁边留 `-wal`。只拷 `.sqlite` 会拿到陈旧的库，
    /// 所以退出前要并一次——并完 wal 该是 0 字节。
    func testCheckpointTruncatesWAL() throws {
        let path = directory.appendingPathComponent("test.sqlite")
        let wal = directory.appendingPathComponent("test.sqlite-wal")
        try db.execute("CREATE TABLE t(id INTEGER, s TEXT)")
        for i in 0..<500 { try db.run("INSERT INTO t VALUES(?,?)", [i, String(repeating: "x", count: 200)]) }
        XCTAssertGreaterThan(try size(of: wal), 0, "写完还没并，wal 该是有内容的")

        try db.checkpointTruncate()
        XCTAssertEqual(try size(of: wal), 0)

        // 并完之后，只凭主库文件就能读全。
        let reopened = try SQLiteDatabase(path: path)
        XCTAssertEqual(try reopened.value("SELECT count(*) FROM t") { $0.int(0) }, 500)
    }

    func testReopenSeesCommittedRows() throws {
        let path = directory.appendingPathComponent("test.sqlite")
        try db.execute("CREATE TABLE t(id INTEGER)")
        try db.transaction { for i in 1...10 { try db.run("INSERT INTO t VALUES(?)", [i]) } }
        db = nil

        let reopened = try SQLiteDatabase(path: path)
        XCTAssertEqual(try reopened.value("SELECT count(*) FROM t") { $0.int(0) }, 10)
    }

    /// 开库就位的那套 PRAGMA 真的生效了（`foreign_keys` 默认是关的，不显式打开
    /// 外键就是一句没人执行的注释）。
    func testPragmasAreApplied() throws {
        XCTAssertEqual(try db.value("PRAGMA journal_mode") { $0.text(0) }, "wal")
        XCTAssertEqual(try db.value("PRAGMA foreign_keys") { $0.int(0) }, 1)
    }

    func testForeignKeyCascadeWorks() throws {
        try db.execute("""
            CREATE TABLE parent(id TEXT PRIMARY KEY);
            CREATE TABLE child(parent_id TEXT REFERENCES parent(id) ON DELETE CASCADE, n INTEGER);
            """)
        try db.run("INSERT INTO parent VALUES('p')")
        try db.run("INSERT INTO child VALUES('p', 1)")
        try db.run("DELETE FROM parent WHERE id = 'p'")
        XCTAssertEqual(try db.value("SELECT count(*) FROM child") { $0.int(0) }, 0)
    }

    private func size(of url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
