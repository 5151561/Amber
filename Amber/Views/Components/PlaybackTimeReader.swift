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
struct PlaybackTimeReader<Content: View>: View {
    @EnvironmentObject private var clock: PlaybackClock

    @ViewBuilder var content: (TimeInterval) -> Content

    var body: some View { content(clock.time) }
}
