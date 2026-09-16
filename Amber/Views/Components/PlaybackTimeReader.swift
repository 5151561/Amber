import SwiftUI

/// 只订阅播放进度的容器。
///
/// 播放进度 10 Hz 一跳。把读进度的那几行包在这里面，重画就只发生在括号里，
/// 不会顺着 `AppState` 波及整棵视图树（详见 `PlaybackClock` 的注释）。
///
/// ```swift
/// PlaybackTimeReader { time in
///     Text(time.mmss)
/// }
/// ```
///
/// `isActive` 是给**常驻但看不见**的宿主准备的闸。整窗播放器收起时不再用
/// `isHidden`（那会连里面那棵 SwiftUI 的更新一起停掉，见
/// `NowPlayingHostController.hideAfterCollapse` 与 design-ref/reactive-ui-review.md
/// 故障 16），代价是这一层会在没人看的时候继续按 10 Hz 走时。
/// 关掉它就不建立对 `PlaybackClock` 的订阅——**必须靠「换掉视图」来断**，
/// 光在 body 里绕开 `clock.time` 没用：`@EnvironmentObject` 的订阅是声明即生效的，
/// 读不读都会被 `objectWillChange` 打醒。
struct PlaybackTimeReader<Content: View>: View {
    /// 宿主看得见（或该继续走时）时为 true。
    var isActive = true
    /// `isActive == false` 时顶上的读数，一般传 `player.currentTime`。
    /// 闸关着的期间宿主本来就不可见，这个值只是别让版面掉成 `--:--`；
    /// 一开闸下面那支立刻拿 `clock.time` 覆盖它。
    var frozenTime: TimeInterval = 0

    @ViewBuilder var content: (TimeInterval) -> Content

    var body: some View {
        if isActive {
            LivePlaybackTime(content: content)
        } else {
            content(frozenTime)
        }
    }
}

/// 真正挂在时钟上的那一支。`isActive` 翻面时整支被换掉，订阅跟着建立／断开。
private struct LivePlaybackTime<Content: View>: View {
    @EnvironmentObject private var clock: PlaybackClock

    @ViewBuilder var content: (TimeInterval) -> Content

    var body: some View { content(clock.time) }
}
