import SwiftUI

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
/// 在 SwiftUI 里自己积分。曲线、加速度、生命周期与归档一致。
struct ReactionEffectView: View {

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
    }

    struct Particle: Identifiable {
        let id = UUID()
        let symbol: String
        let born: TimeInterval
        /// 在 emitterSize 宽度内的随机横向偏移
        let offsetX: CGFloat
        /// 每颗粒子的字号（emoji 本身没有 sprite 图，用字号代替 contentsScale）
        let baseSize: CGFloat
    }

    var particles: [Particle]
    /// 发射线相对容器底部的位置
    var emitterBottomInset: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                // renderMode = backToFront：先生的在后面，后生的压在上面
                ForEach(particles.filter { now - $0.born < Spec.lifetime }) { particle in
                    let age = now - particle.born
                    let progress = age / Spec.lifetime
                    Text(particle.symbol)
                        .font(.system(size: particle.baseSize))
                        .padding(Spec.cellPadding)
                        .scaleEffect(Spec.scale * CGFloat(interpolate(
                            progress, locations: Spec.scaleLocations, values: Spec.scaleValues)))
                        .opacity(interpolate(
                            progress,
                            locations: evenLocations(Spec.alphaValues.count),
                            values: Spec.alphaValues))
                        .position(
                            x: geometry.size.width / 2 + particle.offsetX,
                            y: geometry.size.height - emitterBottomInset - CGFloat(rise(after: age)))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 带线性阻尼的匀加速位移：v' = a - k·v，积分得
    /// y(t) = (a/k)·(t − (1 − e^(−k·t))/k)。k 取归档里的 drag=0.2。
    private func rise(after time: TimeInterval) -> Double {
        let a = Spec.yAcceleration
        let k = Spec.drag
        guard k > 0 else { return 0.5 * a * time * time }
        return (a / k) * (time - (1 - exp(-k * time)) / k)
    }

    private func evenLocations(_ count: Int) -> [Double] {
        guard count > 1 else { return [0] }
        return (0 ..< count).map { Double($0) / Double(count - 1) }
    }

    /// CAEmitterBehavior 的 valueOverLife / colorOverLife 都是按 location 分段线性。
    private func interpolate(_ progress: Double, locations: [Double], values: [Double]) -> Double {
        guard let first = values.first, let last = values.last else { return 1 }
        if progress <= locations[0] { return first }
        if progress >= locations[locations.count - 1] { return last }
        for index in 1 ..< locations.count where progress <= locations[index] {
            let span = locations[index] - locations[index - 1]
            guard span > 0 else { return values[index] }
            let t = (progress - locations[index - 1]) / span
            return values[index - 1] + (values[index] - values[index - 1]) * t
        }
        return last
    }
}

/// 按住不放持续发射、松手停发射，速率取归档里的 birthRate。
@Observable
final class ReactionEmitter {

    private(set) var particles: [ReactionEffectView.Particle] = []
    private var timer: Timer?

    /// Music 的反应表情组
    static let symbols = ["❤️", "🔥", "😂", "😮", "😢", "👍"]

    func start(_ symbol: String) {
        stop()
        emit(symbol)
        // birthRate 4.5 颗/秒
        let interval = 1 / ReactionEffectView.Spec.birthRate
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emit(symbol) }
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

    private func emit(_ symbol: String) {
        let now = Date.timeIntervalSinceReferenceDate
        let half = ReactionEffectView.Spec.emitterWidth / 2
        particles.append(ReactionEffectView.Particle(
            symbol: symbol,
            born: now,
            offsetX: CGFloat.random(in: -half ... half),
            baseSize: CGFloat.random(in: 18 ... 26)))
        // 过期的清掉，别让数组无限长
        particles.removeAll { now - $0.born > ReactionEffectView.Spec.lifetime }
    }
}
