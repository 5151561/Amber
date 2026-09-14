import QuartzCore

/// 一次属性动画的曲线。
///
/// 原版是 Music 歌词模块的一个 enum：6 个 case，最大载荷 `spring` = 48 字节，加 1 字节 tag
/// 正好 **0x31**——原版到处传的那个描述符就是它，见 lyrics 规格 §3.4。
///
/// tag 与 case 的对应是**实测**的（§5.1）：下发端在
/// 处按 tag 字节分派，0 建 `CASpringAnimation`，1/2/3/4 分别取
/// `EaseInEaseOut`/`EaseIn`/`EaseOut`/`Linear` 四个`kCAMediaTimingFunction*`
/// 常量，5 走 `initWithControlPoints::::`。
enum LyricsAnimationCurve: Equatable {
    case spring(SpringAnimationParameters)
    case easeInOut(TimeInterval)
    case easeIn(TimeInterval)
    case easeOut(TimeInterval)
    case linear(TimeInterval)
    case custom(CGPoint, CGPoint, duration: TimeInterval)

    /// 起的分派。
    ///
    /// 弹簧那一支不返回 timing function——它建的是 `CASpringAnimation`，
    /// 时长取 `settlingDuration`，与 §2.4 的工厂同一套。
    func makeAnimation(keyPath: String) -> CABasicAnimation {
        switch self {
        case .spring(let p):                                   // tag 0
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = p.mass
            a.stiffness = p.stiffness
            a.damping = p.damping
            a.duration = p.duration ?? a.settlingDuration
            return a
        case .easeInOut(let d):                                // tag 1
            return Self.basic(keyPath, d, .easeInEaseOut)
        case .easeIn(let d):                                   // tag 2
            return Self.basic(keyPath, d, .easeIn)
        case .easeOut(let d):                                  // tag 3
            return Self.basic(keyPath, d, .easeOut)
        case .linear(let d):                                   // tag 4
            return Self.basic(keyPath, d, .linear)
        case .custom(let c1, let c2, let d):                   // tag 5
            let a = CABasicAnimation(keyPath: keyPath)
            a.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y))
            a.duration = d
            return a
        }
    }

    private static func basic(_ keyPath: String,
                              _ duration: TimeInterval,
                              _ name: CAMediaTimingFunctionName) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.timingFunction = CAMediaTimingFunction(name: name)
        a.duration = duration
        return a
    }
}
