import AppKit
import QuartzCore

/// 表情反应的粒子效果，按 Music.app 自带的 `Contents/Resources/ReactionEffect.ca`
/// 逐项复刻（music-static-assets 笔记「Core Animation 归档」）。
///
/// 归档里记的是一个 `CAEmitterLayer`：
/// ```
/// layer  myEmitter : emitterShape=cuboid  emitterSize=50×0  renderMode=backToFront
/// cell   1         : birthRate=1.5  lifetime=0.9  scale=1.3  mass=1  speed=1
///                    yAcceleration=1000  particleType=sprite  color=(1,1,1)
/// behavior drag            : drag=0.2
/// behavior valueOverLife   : keyPath=scale
///          locations [0, 0.15, 0.344708, 0.852889, 1]
///          values    [0, 1,    1.5,      1.5,      1]
/// behavior colorOverLife   : 6 段白色，末两段 alpha 0.8043 → 0
/// animation birthRate      : 4.5 → 0，0.0225777s 线性（松手时停发射用）
/// ```
///
/// 这里不用 `CAEmitterLayer`：`colorOverLife` / `valueOverLife` 走的是
/// `CAEmitterBehavior` 那套私有 API，Amber 不碰私有 API，所以照着同一组参数
/// 自己排关键帧。曲线、加速度、生命周期与归档一致。
///
/// 骨架换 AppKit（计划阶段 6）之后这一块是 **CALayer 版**：一粒子一
/// `CATextLayer` + 一组 `CAKeyframeAnimation`，动画落在渲染服务器上跑，
/// 主线程每帧不做任何事。旧版是 SwiftUI 的 `TimelineView(.animation)`，
/// 按住一个表情就按屏幕刷新率把整片重算一遍。
/// 位移那条带阻尼的积分**预先采样成关键帧**，不必每帧算。
@MainActor
final class ReactionEffectView: NSView {

    /// 归档里的原始参数，改这里就等于改效果。
    enum Spec {
        /// emitterCell.lifetime
        static let lifetime: Double = 0.9
        /// emitterCell.scale
        static let scale: CGFloat = 1.3
        /// emitterCell.yAcceleration（正方向朝上）
        static let yAcceleration: Double = 1000
        /// drag behavior 的 drag 系数，按线性阻尼积分
        static let drag: Double = 0.2
        /// emitterSize 的宽（高为 0，即一条水平发射线）
        static let emitterWidth: CGFloat = 50
        /// birthRate 关键帧的起始值——松手时从这个值线性归零，
        /// 也就是按住时的实际发射速率（emitterCell 里记的 1.5 是静置值）
        static let birthRate: Double = 4.5
        /// birthRate 4.5 → 0 的时长
        static let stopDuration: Double = 0.0225777
        /// valueOverLife(scale)
        static let scaleLocations: [Double] = [0, 0.15, 0.344708, 0.852889, 1]
        static let scaleValues: [Double] = [0, 1, 1.5, 1.5, 1]
        /// colorOverLife 的 6 段：前四段全不透明，末两段 0.8043 → 0
        static let alphaValues: [Double] = [1, 1, 1, 1, 0.8043, 0]
        /// [实测] `Music.ReactionCell.fittingSize` / `_ReactionCell.fittingSize` → 4
        static let cellPadding: CGFloat = 4
        /// 位移那条积分采样成多少段关键帧。0.9 秒 40 段 ≈ 22.5ms 一段，
        /// 中间由 Core Animation 自己线性插值，肉眼看不出与逐帧积分的差别。
        static let riseSamples = 40
    }

    /// 发射线相对容器底部的位置
    var emitterBottomInset: CGFloat = 0

    override var isFlipped: Bool { false }

    /// 粒子不接鼠标。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 发一颗。动画走完自己 `removeFromSuperlayer`。
    func emit(_ symbol: String) {
        guard let host = layer else { return }
        // 每颗粒子的字号（emoji 本身没有 sprite 图，用字号代替 contentsScale）
        let baseSize = CGFloat.random(in: 18 ... 26)
        // 在 emitterSize 宽度内的随机横向偏移
        let half = Spec.emitterWidth / 2
        let offsetX = CGFloat.random(in: -half ... half)

        let box = baseSize + Spec.cellPadding * 2
        let cell = CATextLayer()
        cell.string = NSAttributedString(
            string: symbol,
            attributes: [.font: NSFont.systemFont(ofSize: baseSize)])
        // CATextLayer 认 `alignmentMode`，不认属性串里的段落对齐。
        cell.alignmentMode = .center
        cell.truncationMode = .none
        cell.isWrapped = false
        cell.contentsScale = amberWindow?.backingScaleFactor ?? 2
        cell.bounds = CGRect(x: 0, y: 0, width: box * 2, height: box)
        cell.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let startX = bounds.midX + offsetX
        let startY = emitterBottomInset
        cell.position = CGPoint(x: startX, y: startY)
        // renderMode = backToFront：先生的在后面，后生的压在上面。
        host.addSublayer(cell)

        let rise = CAKeyframeAnimation(keyPath: "position.y")
        rise.values = (0 ... Spec.riseSamples).map { step -> CGFloat in
            let time = Spec.lifetime * Double(step) / Double(Spec.riseSamples)
            return startY + CGFloat(Self.rise(after: time))
        }
        rise.keyTimes = (0 ... Spec.riseSamples).map {
            NSNumber(value: Double($0) / Double(Spec.riseSamples))
        }
        rise.calculationMode = .linear

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = Spec.scaleValues.map { Spec.scale * CGFloat($0) }
        scale.keyTimes = Spec.scaleLocations.map { NSNumber(value: $0) }

        let alpha = CAKeyframeAnimation(keyPath: "opacity")
        alpha.values = Spec.alphaValues.map { Float($0) }
        alpha.keyTimes = Self.evenLocations(Spec.alphaValues.count).map { NSNumber(value: $0) }

        let group = CAAnimationGroup()
        group.animations = [rise, scale, alpha]
        group.duration = Spec.lifetime
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { cell.removeFromSuperlayer() }
        cell.opacity = 0
        cell.add(group, forKey: "amber.reactionParticle")
        CATransaction.commit()
    }

    /// 带线性阻尼的匀加速位移：v' = a - k·v，积分得
    /// y(t) = (a/k)·(t − (1 − e^(−k·t))/k)。k 取归档里的 drag=0.2。
    private static func rise(after time: TimeInterval) -> Double {
        let a = Spec.yAcceleration
        let k = Spec.drag
        guard k > 0 else { return 0.5 * a * time * time }
        return (a / k) * (time - (1 - exp(-k * time)) / k)
    }

    private static func evenLocations(_ count: Int) -> [Double] {
        guard count > 1 else { return [0] }
        return (0 ..< count).map { Double($0) / Double(count - 1) }
    }
}

/// 按住不放持续发射、松手停发射，速率取归档里的 birthRate。
@MainActor
final class ReactionEmitter {

    /// 发一颗。接在粒子层上（`ReactionEffectView.emit`）——发射器只管节拍，
    /// 粒子的生死由那一层自己管。
    var onEmit: ((String) -> Void)?

    private var timer: Timer?

    /// Music 的反应表情组
    static let symbols = ["❤️", "🔥", "😂", "😮", "😢", "👍"]

    func start(_ symbol: String) {
        stop()
        onEmit?(symbol)
        // birthRate 4.5 颗/秒
        let interval = 1 / ReactionEffectView.Spec.birthRate
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEmit?(symbol) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 归档里松手是把 birthRate 在 0.0226s 内线性拉到 0——这么短，等价于立刻停发射；
    /// 已经在飞的粒子照常走完自己的 lifetime。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// `Timer` 不是 `Sendable`，非隔离的 `deinit` 取不到它。标`isolated`：
    /// 主线程上释放时照旧同步跑完，停发射的时机不变。
    isolated deinit {
        timer?.invalidate()
    }
}
