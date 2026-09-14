import AppKit
import SwiftUI

/// 整窗播放器的背景。
///
/// [TYPE] `NowPlayingViewModel.Backdrop(image / isPaused / isLegibilityOverlayShown)`；
/// Music 侧真正画它的是 `TSLBackdropMetalView`（`MPContentView` 的，
/// 判型得到）。
///
/// 两条实测得到的硬规则（nowplaying spec §2.1）：
///
/// ```
/// p = clamp((内容宽 − 400) / 400, 0, 1)
/// backdrop.scrimAlpha        = 0.7 − 0.4 × p      // 越宽纱罩越浅
/// backdrop.animationInterval = 10.5 − 9 × p       // 越宽律动越快
/// ```
///
/// 注意这两个量都跟**内容视图宽度**走，不是跟高度、也不是跟封面走
/// （规格笔记批次 33 的翻案：旧版写成「窗口内容高度、偏移 ε≈0.011」，两处都错）。
/// 整窗尺寸下宽度远大于 800，p 恒为 1，即纱罩 0.3、间隔 1.5s。
///
/// 色域本身仍走 [PX] 那套（`amberBackdropField`：12×12 方块均值 → 夹进实测 HSB 区间 → 铺满模糊），
/// 而那次采样就是在 923 高的窗口上做的，像素里**已经含 0.3 那层纱罩**，
/// 所以这里只补「比基线更浓的那一部分」（`backdropCalibratedScrim`）。
struct NowPlayingBackdropView: View {
    let artwork: NSImage?
    /// [TYPE] `Backdrop.isPaused`：暂停就停住律动，别在没人看的时候一直合成。
    let isPaused: Bool
    /// [实测] 的入参：`MPContentView` 的**宽度**。
    let contentWidth: CGFloat

    private typealias M = MusicMetrics.NowPlaying

    /// [HIG] 「减弱动态效果」：这块律动是 1.5s 一拍、**持续不停**的自绘动画，
    /// 系统不会替它降级。开了这一位就停在静止的一帧——`field`、纱罩、模糊照常画，
    /// 只是不做 phase 动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = false
    @State private var field: NSImage?

    /// 无封面时的底色，反算自 Music 空态截图的 #6E6F72
    private static let idle = Color(.sRGB, red: 0.357, green: 0.361, blue: 0.373)

    /// 停不停律动：暂停/收起，或用户开了「减弱动态效果」。
    private var motionPaused: Bool { isPaused || reduceMotion }

    private var animationInterval: TimeInterval {
        M.backdropAnimationInterval(contentWidth: contentWidth)
    }

    /// 只补基线之上的那一档；窗宽 ≥ 800 时为 0。
    private var extraScrim: CGFloat {
        max(M.backdropScrimAlpha(contentWidth: contentWidth) - M.backdropCalibratedScrim, 0)
    }

    var body: some View {
        ZStack {
            if let field {
                GeometryReader { geo in
                    // 方块均值场拉满窗口。放大是为了律动时不露边。
                    Image(nsImage: field)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: M.backdropBlur, opaque: true)
                        // 间隔取 ASM 的 animationInterval；幅度没在静态数据里，
                        // 取「看得出在动、又不晃眼」的小值。[推]
                        .scaleEffect(1.18 * (phase ? 1.03 : 1.0))
                        .rotationEffect(.degrees(phase ? 2.5 : -2.5))
                        .animation(motionPaused ? nil
                                                : .easeInOut(duration: animationInterval)
                                                    .repeatForever(autoreverses: true),
                                   value: phase)
                        .clipped()
                }
            } else {
                Self.idle
            }

            if extraScrim > 0 {
                Color.black.opacity(extraScrim)
            }
        }
        .onAppear { syncPhase() }
        // `repeatForever` 一旦跑起来，后面把`.animation` 改成 nil **不会取消它**——
        // 只是「以后不再动画」。所以暂停/收起时得显式把 `phase` 无动画地定住，
        // 否则那块 60 半径模糊的全窗图片会一直转下去。
        // 实测：收起「播放中」之后 CPU 仍停在 34%，就是这条没断干净。
        .onChange(of: motionPaused) { _, _ in syncPhase() }
        .task(id: artwork) { field = artwork?.amberBackdropField() }
    }

    private func syncPhase() {
        guard !motionPaused else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { phase = false }
            return
        }
        phase = true
    }
}
