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
/// 过渡期里面仍是 SwiftUI：`isPresented` 由本控制器**换 rootView 推进去**
/// （那一位控制背景律动、rollover 计时的启停，不能只靠「看不看得见」）。
///
/// 从前是一小片 `NowPlayingRoot` 以 `@ObservedObject` 观察整份`AppState` 再取
/// `showingNowPlaying`——那等于让 AppState 上的每一次变化（toast、导航意图、侧栏选中）
/// 都把整棵 `NowPlayingView` 重算一遍。换 rootView 是 AppKit 主动推一次状态，
/// 见 `PageHosting.hostingRoot` 的注释。
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
        let host = appState.hostingView { nowPlayingRoot(isPresented: isPresented) }
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
        container.isInert = !isPresented
    }

    /// 整窗播放器那棵 SwiftUI 子树。`ignoresSafeArea` 铺满全窗，位移归本控制器。
    private func nowPlayingRoot(isPresented: Bool) -> some View {
        NowPlayingView(isPresented: isPresented, appState: appState)
            .ignoresSafeArea()
    }

    /// 宿主（窗口根）布局时调一次：整块与窗口同尺寸，按当前状态放在窗内或窗下。
    func layoutInHost(bounds: NSRect) {
        view.frame = NSRect(x: bounds.minX,
                            y: bounds.minY + (isPresented ? 0 : -bounds.height),
                            width: bounds.width, height: bounds.height)
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        let changed = presented != isPresented
        isPresented = presented
        // `isPresented` 是 SwiftUI 侧的入参（背景律动、rollover 计时、歌词每帧驱动
        // 全看它），由 AppKit 换 rootView 主动推进去。这一步在「还没挂进窗口」时
        // 也要做，不然首次上屏那一下推的是旧值。
        if changed, let host { host.rootView = appState.hostingRoot { nowPlayingRoot(isPresented: presented) } }
        if presented {
            // 收起期间只是「不参与命中测试、不进辅助功能树」+ alpha 0，展开先还原。
            (view as? NowPlayingContainerView)?.isInert = false
            view.alphaValue = 1
        }
        guard let superview = view.superview else { return }

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

    /// 动画结束再收尾：收早了就看不到落下去的那一段。
    ///
    /// 类头注释真正要的只有两件事——**不参与命中测试、不进辅助功能树**。
    /// 从前是拿 `isHidden` 一并办掉的，代价是`NSHostingView` 一旦被隐藏，
    /// 里面那棵 SwiftUI 就**停止更新**（`PageHosting.swift` 自己记着这条规律）：
    /// 收起期间从迷你播放器换了歌，`NowPlayingView` 的`.task(id: track?.id)` 不跑，
    /// 再按开先看到上一首的封面/空态再淡入新的——正是本类头注释说要避免的那一幕
    /// （design-ref/reactive-ui-review.md 故障 16）。
    ///
    /// 所以两件事各用各的开关，`isHidden` 这把过度的锤子收起来：
    /// 命中测试由 `NowPlayingContainerView.hitTest` 短路、辅助功能树由
    /// `accessibilityHidden` 摘掉，画面上再压一道 `alphaValue = 0`
    ///（整块本来就已经位移到窗外，这一道是保险）。
    ///
    /// 「收起后 CPU ≈ 0」不靠这里：那是 SwiftUI 侧`isPresented` 的事——
    /// 背景律动、粒子、歌词每帧驱动、待播盘电平条、连时间行那 10 Hz 的走时
    /// （`PlaybackTimeReader.isActive`）全按它停，见 `NowPlayingView`。
    private func hideAfterCollapse() {
        (view as? NowPlayingContainerView)?.isInert = true
        view.alphaValue = 0
    }
}

/// 「正在播放」整窗播放器的 AppKit 容器。
///
/// 对应 Music 规格（nowplaying spec §2.4）的 `VibrantDragBlockingView` 阻断层：
/// 吸收未被内部视图消费的 `scrollWheel:` 事件，阻止滚轮/触控板双指滑动事件沿响应链冒泡至`NSWindow`，
/// 彻底避免背后的表格/内容页发生穿透滚动。
private final class NowPlayingContainerView: NSView {

    /// 收起期间「当它不存在」：不接命中测试、不进辅助功能树。
    /// **不动 `isHidden`**——那会连带把里面那棵 SwiftUI 的更新一起停掉，
    /// 理由见 `NowPlayingHostController.hideAfterCollapse`。
    var isInert = false {
        didSet {
            guard isInert != oldValue else { return }
            setAccessibilityHidden(isInert)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        // 吸收未被内部视图消费的滚轮与触控板滑动手势，拦截穿透。
    }
}
