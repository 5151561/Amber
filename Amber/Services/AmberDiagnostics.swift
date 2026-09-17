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
    /// **埋点本身不能变成开销**，所以这里只有一份 `static let`：`OSSignposter` 造一次
    /// 要开一个 `OSLog` 句柄，每次调用现造就把「不采样时接近零成本」这条给毁了。
    /// 采样关着时 `beginInterval` / `endInterval` 先看一眼 `signpostsEnabled` 再决定
    /// 要不要展开消息，所以带计数的那几处也不用自己加闸。
    ///
    /// 怎么看：Instruments 的 os_signpost 仪器，或者
    /// `xcrun xctrace record --template 'os_signpost' --launch /Applications/Amber.app`。
    /// 命令行捞法：`log stream --predicate 'subsystem == "com.changlepan.Amber"' --signpost`。
    static let launch = OSSignposter(subsystem: subsystem, category: "launch")
}
