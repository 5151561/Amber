import SwiftUI

/// 「正在播放」的电平指示条，复刻 `TrackNowPlayingIndicatorView`。
///
/// Music 在详情页音轨行放的不是喇叭图标，而是一个 NSView 子类画的四条电平：
/// 条宽与最大高度由宿主行给（`levelWidth` / `maximumLevelHeight` 都是 var），
/// 条间距和圆角则在 `init` 里按屏幕像素固定成 3px / 1px。
/// 尺寸与条数出处见 `MusicMetrics.NowPlayingLevels`。
///
/// 摆动本身取不到（动画在 Core Animation 层，只能量到几何），
/// 这里用四条不同周期、彼此错相的 ease-in-out 往复近似；暂停时压平到 `idleLevel`，
/// 与 Music 的 `playbackState` 分支一致——暂停不清零，只是不再摆。
///
/// - Important: **不要改回 `TimelineView`**。原来这里是
///   `TimelineView(.animation(minimumInterval: 1/30))`，每秒 30 次重算。
///   看着只是四个小方块，但 SwiftUI 每一跳都要把脏标记推过**整个窗口**的视图图，
///   而「播放中」展开之后那张图很大——实测光这一条就把 CPU 从 3% 顶到 33%
///   （`AG::Graph::propagate_dirty` 占了采样的大头）。
///   现在改成一条 `repeatForever`：动画落在渲染服务器上跑，SwiftUI 每帧不做任何事。
struct NowPlayingLevelsView: View {
    private typealias M = MusicMetrics.NowPlayingLevels

    var isPlaying: Bool
    var levelWidth: CGFloat = M.rowLevelWidth
    var maximumLevelHeight: CGFloat = M.rowMaximumLevelHeight
    var color: Color = .amberKey

    /// [HIG] 「减弱动态效果」：这四条是持续不停的自绘往复动画，系统不会替它降级。
    /// 开了这一位就停在静止的一帧——指示条照常摆出来（该多高还是多高，见
    /// `restingLevel`），只是不再摆动。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 摆动的驱动值。四条共用它，靠各自的 `duration` 与`delay` 错开相位。
    @State private var swinging = false

    var body: some View {
        HStack(alignment: .center, spacing: M.spacing) {
            ForEach(0 ..< M.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
                    .fill(color)
                    // 高度定死、只缩放：动 `frame` 每帧都要重新布局，动 transform 不用。
                    .frame(width: levelWidth, height: maximumLevelHeight)
                    .scaleEffect(y: swinging ? 1 : restingLevel, anchor: .center)
                    .animation(animation(for: index), value: swinging)
            }
        }
        .frame(width: M.width(levelWidth: levelWidth), height: maximumLevelHeight)
        .onAppear { syncSwing() }
        .onChange(of: isPlaying) { _, _ in syncSwing() }
        .onChange(of: reduceMotion) { _, _ in syncSwing() }
        .accessibilityHidden(true)
    }

    /// 不摆时停在哪：播放中（还没起摆）取 `minLevel`，暂停取`idleLevel`。
    private var restingLevel: CGFloat { isPlaying ? M.minLevel : M.idleLevel }

    /// 第 index 条的往复动画。半个周期一趟，`delay` 把四条错开。
    private func animation(for index: Int) -> Animation? {
        guard isPlaying, !reduceMotion else { return nil }
        let period = M.periods[index % M.periods.count]
        return .easeInOut(duration: period / 2)
            .repeatForever(autoreverses: true)
            .delay(period * Double(index) / Double(M.count))
    }

    /// `repeatForever` **不会**因为把`.animation` 换成 nil 就停下来——那只是
    /// 「以后不再动画」。要停就得显式无动画地把驱动值落回去。
    /// （同一个坑见 `NowPlayingBackdropView.syncPhase()`。）
    private func syncSwing() {
        guard isPlaying, !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { swinging = false }
            return
        }
        swinging = true
    }
}
