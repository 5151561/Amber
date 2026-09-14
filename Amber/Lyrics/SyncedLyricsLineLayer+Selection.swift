import AppKit
import QuartzCore

extension SyncedLyricsLineLayer {

    /// 一次行外观切换要用的动画描述。
    ///
    /// 就是 `LyricsAnimationCurve` 本身：原版那个 6 case 的 enum，最大载荷
    /// `spring` 48 字节 + 1 字节 tag = **0x31**，正好是原版到处传的那个描述符。
    /// 载荷布局由三处独立构造点逐字段对齐读出：
    ///
    /// | 内容 |
    /// | --- |
    /// | `mass` / `stiffness` / `damping` |
    /// | `duration: TimeInterval?`（payload + tag；三处都写 nil） |
    /// | `settlingDuration`——造一个临时`CASpringAnimation` 读回来的 |
    /// | enum tag；**`0xff` = 不做动画，直接落值** |
    ///
    /// - Important: 这纠正了此前把 `settlingDuration` 那一槽当`initialVelocity`
    ///   的记法。三个构造点全都在那个位置写 `settlingDuration`，且`duration`
    ///   明确是个 `Optional`（值 + tag 两槽），48 字节里排不下第四个非可选 Double。
    struct SelectionAnimation: Sendable, Equatable {
        var spring: SpringTimingParameters
        /// 调用方给的时长覆盖。三处构造点都是 `nil`——没见过非 nil 的实例。
        var duration: TimeInterval?
        var settlingDuration: TimeInterval
        init(spring: SpringTimingParameters,
                    duration: TimeInterval? = nil,
                    settlingDuration: TimeInterval) {
            self.spring = spring
            self.duration = duration
            self.settlingDuration = settlingDuration
        }

        /// 按原版那套造：设 mass/stiffness/damping，再把 `settlingDuration` 读回来当时长。
        init(spring: SpringTimingParameters) {
            let a = CASpringAnimation(keyPath: "transform", spring: spring)
            self.init(spring: spring, settlingDuration: a.settlingDuration)
        }
    }

    /// 把选中态应用到这一行。
    ///
    /// （`selecting line` 与`deselecting all` 都收敛到它）。规格见`lyrics 规格` §1.6 与 §9.4。
    ///
    /// - Parameter animation: `nil` 对应原版的 tag 字节`0xff`，即瞬时落值。
    func apply(selected: Bool, animation: SelectionAnimation?) {
        // [实测]：状态没变就立即返回，不重复起弹簧。
        // 这条必须留——每帧都会调进来，少了它弹簧会被反复重启。
        guard selected != isSelected else { return }

        // [实测]：仅「将要变成选中」且当前是聚焦行时，
        // 走失焦收尾。第一参数写死 `0`，
        // 第二参数是 `animationKind != 0xff`，即「这次切换有没有动画」。
        if selected, isLineFocused {
            setLineFocused(false, animated: animation != nil)
        }

        isSelected = selected                                   // [实测]

        // [实测] 选中 = 单位变换；非选中 = specs.deselectedTransform（scale 0.98）。
        // 无动画那一支是就地拼出来的单位矩阵，
        // 有动画那一支从 specs 取 `deselectedTransform`。
        let target = selected ? CGAffineTransform.identity : specs.deselectedTransform
        if let animation {
            animateAffineTransform(to: target, with: animation)
        } else {
            setAffineTransform(target)                          // [实测]
        }

        // [实测]：两支汇合后都去读 layer 上的
        // `contentLayer`（存在体，占两个槽：对象 + 类型槽），
        // 非 nil 就调，参数 `(selected, animated)`。
        // 动画支传 animated = true，瞬时支传 false。
        contentLayer?.setSelected(selected, animated: animation != nil)
    }

    /// 走那条下发路径把仿射变换动过去。
    ///
    /// [实测]：把 0x31 字节描述符原样拷进
    /// `LayerPropertyAnimator` 的`animationCurve`，`layers = [self]`
    /// （栈上数组头常量 = `(count: 1, capacity: 3)`），
    /// 挂一个完成回调，然后以 `(0, 0)` 收尾。
    ///
    /// 注意末位参数是 **0**，而的聚焦动画传的是 **1**——
    /// 两处下发的第二个参数不同，含义未走完 `[部分]`。
    func animateAffineTransform(to target: CGAffineTransform, with animation: SelectionAnimation) {
        let animator = LayerPropertyAnimator(curve: .spring(
            SpringAnimationParameters(mass: animation.spring.mass,
                                      stiffness: animation.spring.stiffness,
                                      damping: animation.spring.damping,
                                      duration: animation.duration,
                                      settlingDuration: animation.settlingDuration)))
        animator.layers = [self]
        animator.addAnimation(to: self,
                              keyPath: "transform",
                              from: value(forKeyPath: "transform"),
                              to: CATransform3DMakeAffineTransform(target),
                              frameRateRange: (min: 0, max: 0))
        animator.finishDispatch { self.setAffineTransform(target) }
    }
}
