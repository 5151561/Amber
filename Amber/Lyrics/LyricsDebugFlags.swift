import CoreGraphics
import Foundation

/// 歌词的启动参数开关。**只在 DEBUG 生效**，用来把某一轮改动单独关掉做 A/B，
/// 不要拿它当功能开关——定位完就该删。
///
/// 用法与 `-dumpviews` 一族同源（见 `Amber/App/DebugSnapshot.swift`）：
///
/// ```
/// open -a /Applications/Amber.app --args -nolyricsfilters
/// open -a /Applications/Amber.app --args -inklinewidth
/// ```
enum LyricsDebugFlags {

    /// `-nolyricsfilters`：不给行视图打开 `layerUsesCoreImageFilters`。
    ///
    /// 打开这一位是逐行模糊与悬停提亮**真正开始执行**的原因（AppKit 的背衬层默认
    /// 走进程外渲染，那条路不执行 Core Image 滤镜）。代价是这棵子树改走进程内渲染。
    /// 带上这个参数就退回本轮改动之前的渲染路径：滤镜装着但不跑。
    static let disablesLayerFilters = flag("-nolyricsfilters")

    /// `-inklinewidth`：行框宽退回「墨迹宽」，不用测量宽。
    ///
    /// 本轮把行框宽从墨迹宽改成了测量宽（`recomputeLineFrames`，理由见那里的注释）。
    /// 带上这个参数就退回改动之前的取值。
    ///
    /// 注意它会让**对唱翻转侧看着像没右对齐**：顶右靠的是「行盒右缘压在栏右缘」
    /// （`0.15 + 0.85 = 1`），退回墨迹宽之后盒子缩到墨迹上，盒内再顶右也不动地方。
    static let usesInkLineWidth = flag("-inklinewidth")

    /// `-lyricsblur <值>`：现场改非聚焦行的高斯模糊半径，省得为了试一个数重装一遍。
    /// 不带这个参数就用 `SyncedLyricsVisualExperienceManager.deselectedBlurRadius` 的默认值。
    /// 上限仍受 §9.6 那条写死的 `min(radius, 4.0)` 管。
    static let blurRadius: CGFloat? = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-lyricsblur"),
              index + 1 < arguments.count,
              let value = Double(arguments[index + 1])
        else { return nil }
        return CGFloat(value)
        #else
        return nil
        #endif
    }()

    /// `-lyricslog`：向 `/tmp/lyrics_debug.log` 输出歌词滚动与选中诊断日志。
    static let enablesLogging = flag("-lyricslog")

    private static func flag(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(name)
        #else
        return false
        #endif
    }
}

func lyricsDebugLog(_ message: String) {
    #if DEBUG
    guard LyricsDebugFlags.enablesLogging else { return }
    let line = "\(Date()) [Lyrics] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/lyrics_debug.log")) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/lyrics_debug.log"))
        }
    }
    #endif
}

