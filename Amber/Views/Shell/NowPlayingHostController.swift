import AppKit
import QuartzCore
import SwiftUI

/// 「正在播放」整窗播放器的宿主。**常驻**，收起时整块位移到窗口下沿之外。
///
/// 为什么不是「要用才建」：那样每次展开都是新建一棵 `NowPlayingView`，`@State` 全部归零——
/// 背景先画成空态灰、封面是占位方块，等 `.task` 取回封面才补上，肉眼就是
/// 「背景瞬间出现、内容随后滑上来」。常驻 + 自己算位移之后，展开即完成态。
///
/// 展开/收起的动画归 AppKit（旧版是 SwiftUI 的 `.animation(.spring(...), value:)`）：
/// `CASpringAnimation` 的 stiffness / damping 由`MusicMetrics.NowPlaying` 的
/// `transitionResponse` / `transitionDamping` 换算（质量取 1：ω = 2π/response，
/// stiffness = ω²，damping = 2ζω——这是 SwiftUI `spring(response:dampingFraction:)`
/// 的定义式，两边同一条曲线）。
///
/// 过渡期里面仍是 SwiftUI：一小片根视图观察 `showingNowPlaying`，把值交给
/// `NowPlayingView(isPresented:)`（那一位控制背景律动、rollover 计时的启停，
/// 不能只靠「看不看得见」）。
@MainActor
final class NowPlayingHostController: NSViewController {

    private let appState: AppState
    private var host: NSHostingView<AnyView>?
    private(set) var isPresented = false

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NowPlayingContainerView()
        container.wantsLayer = true
        let host = appState.hostingView { NowPlayingRoot(appState: appState) }
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.host = host
        view = container
    }

    /// 宿主（窗口根）布局时调一次：整块与窗口同尺寸，按当前状态放在窗内或窗下。
    func layoutInHost(bounds: NSRect) {
        view.frame = NSRect(x: bounds.minX,
                            y: bounds.minY + (isPresented ? 0 : -bounds.height),
                            width: bounds.width, height: bounds.height)
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        guard let superview = view.superview else {
            isPresented = presented
            return
        }
        let changed = presented != isPresented
        isPresented = presented
        if presented {
            // 收起时是 `isHidden`（等价于 SwiftUI 的`allowsHitTesting(false)` +
            // `accessibilityHidden`），展开要先放回来才看得见。
            host?.isHidden = false
            view.isHidden = false
        }

        let bounds = superview.bounds
        let targetY = bounds.minY + (presented ? 0 : -bounds.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard changed, animated, !reduceMotion, let layer = view.layer else {
            view.frame = NSRect(x: bounds.minX, y: targetY,
                                width: bounds.width, height: bounds.height)
            if !presented { hideAfterCollapse() }
            return
        }

        let fromY = layer.presentation()?.position.y ?? layer.position.y
        view.frame = NSRect(x: bounds.minX, y: targetY,
                            width: bounds.width, height: bounds.height)
        let spring = CASpringAnimation(keyPath: "position.y")
        spring.mass = 1
        let omega = 2 * Double.pi / MusicMetrics.NowPlaying.transitionResponse
        spring.stiffness = omega * omega
        spring.damping = 2 * MusicMetrics.NowPlaying.transitionDamping * omega
        spring.initialVelocity = 0
        spring.fromValue = fromY
        spring.toValue = layer.position.y
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "amber.nowPlayingSlide")

        if !presented {
            let delay = spring.settlingDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isPresented else { return }
                self.hideAfterCollapse()
            }
        }
    }

    /// 动画结束再藏：藏早了就看不到落下去的那一段。
    /// 藏起来之后这一整棵子树不参与命中测试，也不进辅助功能树。
    private func hideAfterCollapse() {
        host?.isHidden = true
        view.isHidden = true
    }
}

/// 「正在播放」整窗播放器的 AppKit 容器。
///
/// 对应 Music 规格（nowplaying spec §2.4）的 `VibrantDragBlockingView` 阻断层：
/// 吸收未被内部视图消费的 `scrollWheel:` 事件，阻止滚轮/触控板双指滑动事件沿响应链冒泡至`NSWindow`，
/// 彻底避免背后的表格/内容页发生穿透滚动。
private final class NowPlayingContainerView: NSView {

    override func scrollWheel(with event: NSEvent) {
        // 吸收未被内部视图消费的滚轮与触控板滑动手势，拦截穿透。
    }
}

/// 只为把 `showingNowPlaying` 变成`NowPlayingView` 的入参而存在的一小片根视图。
private struct NowPlayingRoot: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NowPlayingView(isPresented: appState.showingNowPlaying)
            .ignoresSafeArea()
    }
}
