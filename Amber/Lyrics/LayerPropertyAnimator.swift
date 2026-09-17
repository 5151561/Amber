import QuartzCore

/// 原版 `LayerPropertyAnimator`：一次给一组 layer 下发同一条曲线的多个属性动画，
/// 记账 `totalAnimations` / `completionCount`，全部落位后回调。
///
/// 字段与原类的字段一一对应。
final class LayerPropertyAnimator: NSObject, CAAnimationDelegate {

    /// 曲线就是 `LyricsAnimationCurve`——原版这两处是同一个 6 case 的 enum
    /// （最大载荷 `spring` 48 字节 + 1 字节 tag = 0x31 的那个描述符），
    /// tag → case 的映射见 §5.1。这里只留一个定义。
    typealias AnimationCurve = LyricsAnimationCurve

    enum State: Sendable { case idle, running }

    var delay: TimeInterval = 0                       // +16
    var state: State = .idle                          // +24
    var animationCurve: AnimationCurve                // +32
    var layers: [CALayer] = []                        // +88
    /// **只弱持有正在跑的那些**。`CAAnimation.delegate` 是**强**引用（文档原话是
    /// 「the animation object retains its delegate」，AppKit 里少见的一条），
    /// 下发时 `anim.delegate = self` 之后再把动画强持有回来就成了环：
    /// animator → animations → delegate → animator，两头谁也放不了谁。
    ///
    /// [实测 leaks 2026-09-17] 一次十来分钟的播放，`leaks` 报出 **1536 个
    /// `ROOT CYCLE: LayerPropertyAnimator`**；每个环还顺手把 `layers` 里的
    /// `SyncedLyricsLineLayer` → `SBS_TextContentLayer` → 每音节两个 `CATextLayer`
    /// → CoreText 的 `CTTypesetter`/`CTRun`/`NSCTFont` 整串拖住，合计 78543 个对象、
    /// 6.2 MB，播多久涨多久。`pruneFinishedAnimators` 摘的只是
    /// `currentAnimators` 那份登记，环本身摘不掉。
    ///
    /// 弱持有之后生命周期正好合上：动画挂在层上时**层**强持有它、它强持有 delegate，
    /// 动画器活着、`animationDidStop` 照收；最后一条动画落位被摘掉，动画器随之释放，
    /// `layers` 攥着的那串层一起放掉。已经跑完的动画自动从这张表里消失——
    /// `cancelRunningAnimations` 要的本来就只是「还在跑的那些」的 keyPath，语义不变。
    private struct WeakAnimation { weak var value: CAAnimation? }
    private var liveAnimations: [WeakAnimation] = []   // +104
    var animations: [CAAnimation] { liveAnimations.compactMap(\.value) }
    /// 未接线：原版字段，Amber 的下发路径按 keyPath 逐条 `addAnimation`，用不到它。
    var extraKeyPaths: [String] = []                  // +112
    var completionHandlers: [() -> Void] = []         // +120
    /// 未接线：原版字段，Amber 撤动画时按 `layers × animations` 现算（见
    /// `cancelRunningAnimations`），没有维护这张表。
    var layerAnimationMap: [ObjectIdentifier: [CAAnimation]] = [:]  // +128
    var totalAnimations: Int = 0                      // +136
    var completionCount: Int = 0                      // +144

    init(curve: AnimationCurve) {
        self.animationCurve = curve
        super.init()
    }

    /// 这条动画器是不是已经跑完（或压根没建出动画）。
    ///
    /// 光看 `state` 不够：`.running` 只在`finishDispatch` **建过动画**时才置
    /// 所以「刚 `addAnimation` 完还没下发」和「已经全部落位」
    /// 两种情形的 `state` 都是`.idle`——再比一次`completionCount` / `totalAnimations`
    /// 这两个专为记账留的字段才分得开。一条都没建（`totalAnimations == 0`）
    /// 时 `finishDispatch` 当场跑完回调，也算完成。
    var isFinished: Bool { state == .idle && completionCount >= totalAnimations }

    /// 记账：全部动画落位后跑一次 `completionHandlers`。
    /// `totalAnimations` / `completionCount` 这两个字段就是为它留的。
    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        completionCount += 1
        guard completionCount >= totalAnimations else { return }
        state = .idle
        let handlers = completionHandlers
        completionHandlers = []
        for handler in handlers { handler() }
    }

    // 下发逻辑见本文件下方，规格在 §6.3 与 §6.5。
}

extension LayerPropertyAnimator {

    /// 下发时给每个动画申请的帧率。
    ///
    /// [实测] Music 下发的是
    /// `CAFrameRateRange(minimum: 入参, maximum: 入参, preferred: 120)`，
    /// 并附带一个高刷理由码。
    ///
    /// 也就是说歌词滚动是**主动申请 ProMotion 高刷**的，不是蹭默认帧率。
    /// minimum / maximum 由调用方给，只有 preferred 是写死的。
    static let preferredFrameRate: Float = 120
    static let highFrameRateReason: UInt32 = 0x0012_0002

    /// 拼一个 CoreAnimation 收得下的帧率区间。
    ///
    /// [实测] 是 `CAFrameRateRange(minimum: 入参, maximum: 入参, preferred: 120)`，
    /// 而所有调用点传的都是 **0**。照抄会当场抛异常：CoreAnimation 要求
    /// `preferred` 落在`[minimum, maximum]` 内，`0/0/120` 不合法
    /// （实测崩在 `-[CAAnimation preferredFrameRateRange]`）。
    ///
    /// 所以把 0 当「没给上下界」讲，退成「就要 120」——120/120/120 是合法的，
    /// 在 60Hz 屏上由系统自己往下夹。调用方真给了上下界就照给的来，
    /// `preferred` 夹进区间。
    static func frameRateRange(min lower: Float, max upper: Float) -> CAFrameRateRange {
        guard upper > 0 else {
            return CAFrameRateRange(minimum: preferredFrameRate,
                                    maximum: preferredFrameRate,
                                    preferred: preferredFrameRate)
        }
        let lo = lower > 0 ? Swift.min(lower, upper) : upper
        let preferred = Swift.min(Swift.max(preferredFrameRate, lo), upper)
        return CAFrameRateRange(minimum: lo, maximum: upper, preferred: preferred)
    }

    /// 下发一条属性动画。的单条循环体，规格见 §6.3。
    ///
    /// 三条容易漏的：
    /// - 调用方若在 `CATransaction.disableActions()` 为真的环境里，原版整个退化成
    ///   直接赋值、一个动画都不建。批量重排常包在里面，
    ///   这条决定了那些路径下一帧到位、不留残影。
    /// - **值没变就不建动画**（`isEqual:` 一票否决）。
    ///   无脑 `add` 会让同一属性被反复重启，观感上就是「越滚越黏」。
    /// - `beginTime` 是`CACurrentMediaTime() + delay`，不是`fromValue` 里等。
    @discardableResult
    func addAnimation(to layer: CALayer,
                             keyPath: String,
                             from oldValue: Any?,
                             to newValue: Any?,
                             frameRateRange: (min: Float, max: Float)) -> CABasicAnimation? {
        if CATransaction.disableActions() {
            layer.setValue(newValue, forKeyPath: keyPath)
            return nil
        }
        if let a = oldValue as? NSObject, let b = newValue as? NSObject, a.isEqual(b) {
            return nil
        }

        let anim = animationCurve.makeAnimation(keyPath: keyPath)

        anim.preferredFrameRateRange = Self.frameRateRange(
            min: frameRateRange.min, max: frameRateRange.max)
        anim.fromValue = oldValue
        anim.toValue = newValue

        anim.delegate = self
        layer.removeAnimation(forKey: keyPath)
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .both
        anim.isRemovedOnCompletion = true                          //(w2 = 1)
        layer.add(anim, forKey: keyPath)

        liveAnimations.append(WeakAnimation(value: anim))
        totalAnimations += 1
        return anim
    }
}

extension LayerPropertyAnimator {

    /// additive 动画的两个端点。规格见 §6.5。
    ///
    /// [实测] 都是 `CA_addValue:multipliedBy:` 传`-1`，
    /// 也就是减法：`from = 旧 − 新`、`to = 新 − 新 = 0`。
    ///
    /// 配合 `isRemovedOnCompletion = true` 与末尾把目标值直接写进属性
    /// 这是 Core Animation 标准的**非破坏性叠加**：
    /// 模型层一步到位跳到新值，动画层只把「旧 − 新」这个偏移在时间上退回 0。
    /// 中途再来一次动画不会打架——新动画叠加新的偏移，旧的继续退它自己的。
    ///
    /// 复刻若写成常规的 `fromValue = 旧 / toValue = 新`，连续翻行会看到明显跳变。
    ///
    /// `CA_addValue:multipliedBy:` 是 CoreAnimation 的私有 selector，
    /// 原版先 `respondsToSelector:` 再用，不响应时退回
    /// `presentationLayer.value(forKeyPath:)`。
    /// 这里只对数值类型直接做减法——Amber 不碰私有 API。
    ///
    /// 未接线：`addAdditiveAnimation` 直接用`isAdditive` + `from = offset / to = 0`
    /// 表达同一件事，没有再走这两个端点。留着记 `CA_addValue:multipliedBy:(-1)` 的语义。
    static func additiveEndpoints(from old: Double, to new: Double)
        -> (from: Double, to: Double) {
        (old - new, 0)
    }

    /// 下发一条**叠加式**属性动画：模型值已经是真值，动画只把偏移退回 0。规格见 §6.5。
    ///
    /// [实测]`CA_addValue:multipliedBy:(-1)`：
    /// `from = 旧 − 新`、`to = 0`，配合`isRemovedOnCompletion = true` 与
    /// 「目标值无论如何都写进模型」。
    ///
    /// **并发重排不打架靠的就是这条**：任何时候把模型值再写一遍，写的都是真值，
    /// 正在跑的偏移继续退它自己的。换成常规的 `from = 旧 / to = 新`，
    /// 文档就处在一套「动画期间才成立」的临时坐标里——别的路径（比如上一句被淘汰时
    /// 那次 `relayout`）一提交，行就当场跳回真值，和还没跳的行叠在一起。
    ///
    /// `beginTime` 在未来 +`fillMode = .both` ⇒ **还没轮到的行原地不动**（保持满偏移），
    /// 这正是逐行错开该有的样子（§17.1）。
    @discardableResult
    func addAdditiveAnimation(to layer: CALayer,
                              keyPath: String,
                              offset: CGPoint,
                              frameRateRange: (min: Float, max: Float)) -> CABasicAnimation? {
        guard offset != .zero, !CATransaction.disableActions() else { return nil }

        let anim = animationCurve.makeAnimation(keyPath: keyPath)
        anim.preferredFrameRateRange = Self.frameRateRange(
            min: frameRateRange.min, max: frameRateRange.max)
        anim.isAdditive = true
        anim.fromValue = NSValue(point: NSPoint(x: offset.x, y: offset.y))
        anim.toValue = NSValue(point: .zero)
        anim.delegate = self
        layer.removeAnimation(forKey: keyPath)
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .both
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: keyPath)

        liveAnimations.append(WeakAnimation(value: anim))
        totalAnimations += 1
        return anim
    }

    /// 下发收尾。规格见 §6.5。
    ///
    /// **目标值无论如何都要写进属性**。动画是
    /// `isRemovedOnCompletion = true` 的，跑完就摘掉，届时图层显示的是**模型值**——
    /// 只在「一条动画都没建」时才写模型值的话，动画一结束外观就整个弹回旧值。
    /// 这是 §6.5 那套非破坏性叠加的前提：模型层一步到位跳到新值，
    /// 动画层只负责把「旧 − 新」这个偏移在时间上退回 0。
    ///
    /// [实测]：建过动画就置 `.running`，回调等落位（`animationDidStop`）；
    /// 一条都没建就在本次调用里同步跑完 `completionHandlers`——
    /// 漏了后半条，链式动画会在「目标值恰好没变」的那一帧整条卡死。
    func finishDispatch(applyFinalValues: () -> Void) {
        // 写模型值本身会再触发一次隐式动画，和刚下发的那条打架，所以关掉。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFinalValues()
        CATransaction.commit()

        if totalAnimations != 0 {
            state = .running
        } else {
            let handlers = completionHandlers
            completionHandlers = []
            for handler in handlers { handler() }
        }
    }
}
