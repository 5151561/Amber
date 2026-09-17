import Foundation
import os

/// 诊断出口：日志一处、Instruments 埋点一处。
///
/// **为什么要有这一份，而不是各写各的。** 审查单 §3-3 记着两条：日志混着 `NSLog`
/// 与 `os.Logger`；「一个把帧预算写进验收标准的项目却没有 Instruments 埋点」。
/// 两条的解法是同一件事——把 subsystem 这个字符串收成一份。散写的话，`NSLog` 会
/// 继续长出来（它不用先声明 logger，随手就能写），而 signpost 会因为 subsystem
/// 打错一个字在 Instruments 里整条看不见，且**不报错**。
///
/// **`NSLog` 与 `Logger` 不是同一件东西**，这是替换的理由，不是风格偏好：
///
/// - `NSLog` 每条都无条件格式化 + 写 stderr + 走 ASL 桥，代价与「有没有人看」无关；
///   `Logger` 在没人订阅时连插值都不求值（`OSLogMessage` 是编译期展开的惰性形式）。
/// - `NSLog` 不带 subsystem/category，`log stream` 里只能按进程名捞，四个 store 的
///   「读库失败」混在一起分不开；`Logger` 可以 `--predicate 'category == "library"'`。
/// - `NSLog` 把整条消息当一个字符串存，`Logger` 的插值默认按**私有**处置
///   （字符串在设备上打点会显示成 `<private>`）。这一层记的是错误描述，
///   所以全部显式标 `.public`——不标的话线上捞回来是一排 `<private>`，等于没记。
enum AmberDiagnostics {

    /// 与既有四处 `Logger(subsystem:)` 逐字相同（`QQAPI` / `NeteaseAPI` /
    /// `RemoteControlServer` / `PlayerController`）。那四处不归本批，没去改。
    static let subsystem = "com.changlepan.Amber"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// 启动路径的 Instruments 埋点。
    ///
    /// ## 「埋点本身不能变成开销」——量过了，一条不是免费的
    ///
    /// `[实测]` 2026-09-17，本机 `-O -wmo`、**没有任何工具在录**、best of 5 ×
    /// 50 万次，同一个进程里分形状量：
    ///
    /// | 写法 | ns/次 |
    /// | --- | ---: |
    /// | 不埋 | 1.2 |
    /// | 区间 + 插值消息（本文件的用法） | **560** |
    /// | 区间、不带消息 | 440 |
    /// | 事件 + 插值消息（本文件的用法） | **271** |
    /// | 区间 + 插值消息，句柄换成 `OSLog.disabled` | 213 |
    ///
    /// 两条结论，都与「直觉上它不采样就是零」相反：
    ///
    /// 1. **不采样 ≠ 不花钱。** 自定义 subsystem 的 signpost 默认是开着的
    ///    （关掉要 `log config`），没人订阅时省掉的只是落盘那一段。
    /// 2. **贵的不是插值，是这次调用本身**：把消息整个去掉只从 560 降到 440，
    ///    连句柄换成 `OSLog.disabled` 都还要 213。所以「给带计数的那几处加个
    ///    `if enabled` 的闸」是白加的，省不到那 120 ns 之外的东西。
    ///
    /// 于是纪律是**按次数**定的，不是按写法定的：
    ///
    /// - 启动路径一次运行总共 3 条区间 + 6 个事件 ≈ **3.3 µs**，对着
    ///   `LibraryStore.load` 实测的 0.675 ms 是 0.5%，可以接受；
    /// - 每帧、每行、每个样本的路径上**一条都不许埋**（歌词那条 `CADisplayLink`
    ///   每帧一次 = 每秒 120 次，`LoudnessMeter` 的热循环更是每 4096 帧一次）。
    ///   要量那种地方，用 Instruments 的采样器，不要往里面塞 signpost。
    ///
    /// 只有一份 `static let`：`OSSignposter` 造一次要开一个 `OSLog` 句柄，
    /// 每次现造等于在上面那张表的每一行再加一次开销。
    ///
    /// 怎么看：Instruments 的 os_signpost 仪器，或者
    /// `xcrun xctrace record --template 'os_signpost' --launch /Applications/Amber.app`。
    /// 命令行捞法：`log stream --predicate 'subsystem == "com.changlepan.Amber"' --signpost`。
    static let launch = OSSignposter(subsystem: subsystem, category: "launch")
}
