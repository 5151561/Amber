import os

/// 歌词每帧路径的 Instruments 埋点（审查单 §3-3 的一半）。
///
/// 这个项目把帧预算写进了验收标准（「ProMotion 屏上滚动要更顺」，实测依据在
/// `SyncedLyricsViewController+Setup.startDisplayLink` 那段 120Hz 的注释里），
/// 却一个采样点都没有——「顺不顺」只能靠肉眼，慢了也说不清是滚动那半还是逐字染色那半。
/// 有了这几条 interval，Instruments 的「os_signpost」仪器就能直接给出每帧耗时的分布，
/// 与 Time Profiler 并排看还能把某一帧的尖峰对到具体调用栈上。
///
/// **为什么敢常驻在每帧回调里**：`OSSignposter` 在没人采样时
/// （`signpostsEnabled == false`）只做一次判断就返回，不格式化、不投递。
/// 真正的开销在**参数**上——所以这里的名字一律是 `StaticString` 字面量，
/// 每帧路径上**一次字符串插值都不许有**：插值是在调用之前就算好的，
/// `os_signpost` 的懒格式化救不了它。要带数值就传 `OSLogMessage` 的格式串，别自己拼。
///
/// 范围只到歌词这一路。别的模块要埋点自己开 category，不要往这个 enum 里塞。
enum LyricsSignposts {

    /// Instruments 按 subsystem / category 分组。subsystem 取 bundle id，
    /// category 一个就够：这一路只有 `displayLinkFired` 一条每帧驱动
    /// （面板里那台歌词控制器与整窗播放器那台是同一个类，共用这条链）。
    static let frames = OSSignposter(subsystem: "com.changlepan.Amber", category: "LyricsFrame")
}
