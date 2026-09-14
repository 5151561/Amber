import AppKit
import CoreImage
import QuartzCore

// 批次 9：聚焦（悬停）外观的唯一下发口。
// 两个调用方：
//   1. `-[SyncedLyricsLineView mouseEntered:/mouseExited:]` →
//      调聚焦切换，传 `(isEntering, false)`（§4.1）
//   2. 调聚焦切换，传 `(false, animationKind != 0xff)`
//      ——一行要变成选中、而它正被悬停时的失焦收尾（§1.6 第 2 步）
// 规格见 lyrics 规格 §9.4。

extension SyncedLyricsLineLayer {

    /// 亮度滤镜的 keyPath。
    ///
    /// [实测] 的字面量是 `filters.colorBrightness.inputAmount`（长度 35，
    /// `x24 + 3`）。私有`CAFilter` 的输入键叫`inputAmount`，公开的
    /// `CIColorControls` 叫`inputBrightness`——**滤镜名照抄、输入键换掉**。
    ///
    /// - Important: 两者的量纲不保证一致。ASM 的满量程是 ±1（见
    ///   `focusedBrightnessAmount`），`CIColorControls.inputBrightness` 的 ±1 是
    ///   加在归一化 RGB 上的，可能过曝。实机比对后要调就调那个常量，keyPath 不动。
    static let brightnessKeyPath = "filters.colorBrightness.inputBrightness"
    /// 模糊滤镜的 keyPath。[实测] 的字面量，长度 32（`0x20 |<<48`）。
    /// `CIGaussianBlur` 的输入键本来就叫`inputRadius`，原样。
    static let blurKeyPath = "filters.gaussianBlur.inputRadius"

    /// 聚焦态切换用的曲线。
    ///
    /// [实测] 把三个 16 字节常量拼成 `LyricsAnimationCurve`
    /// 的载荷，tag 字节写 5 → `.custom`（§5.1 的实测映射）：
    ///
    /// ```
    /// → (0.33, 0.0)     载荷 [0][1]
    /// → (0.2,  0.1)     载荷 [2][3]
    /// → (0.12, 0.0)     载荷 [4] = duration
    /// ```
    ///
    /// `deselecting all` 的去模糊支用的是**同一组常量、同一个 tag**——
    /// 两处独立构造点完全一致，可以确定这就是「行外观淡入淡出」的统一曲线。
    ///
    /// - Note: 控制点 `c2.x = 0.2 < c1.x = 0.33`，在 x 方向不单调，是条相当陡的
    ///   ease-in。数值是实测，把它当「120 ms 内快速切完、末段最急」来理解。
    static let focusTransitionCurve = LayerPropertyAnimator.AnimationCurve
        .custom(CGPoint(x: 0.33, y: 0), CGPoint(x: 0.2, y: 0.1), duration: 0.12)

    /// 聚焦时亮度滤镜的目标量。
    ///
    /// [实测]：读 `specs + 0x2f4`（= `focusStyle`），
    /// 后 `cneg x26, #-1, ne`——**`.dark`(1) → −1，`.bright`(0) → +1**。
    /// 取值走 `Int → NSNumber` 桥接，是整数不是小数。
    ///
    /// 也就是说 `focusStyle` 决定的是**提亮还是压暗**，幅度两边都是满量程 1。
    var focusedBrightnessAmount: Int { specs.focusStyle == .bright ? 1 : -1 }

    /// 懒建滤镜链。
    ///
    /// [实测]：`brightnessFilter == nil` 时才走这一段。建
    /// `CAFilter(type: kCAFilterColorBrightness)`、`inputAmount = 0`，然后
    /// `self.filters = [blurFilter, brightnessFilter]`——数组头常量
    /// 是 `(count: 2, capacity: 4)`，元素按`Any` 存（步长 32 字节：值 + 元类型），
    /// 所以**只有两个滤镜**，顺序是先模糊后亮度。
    ///
    /// Amber 用 `CIFilter` 顶替私有的`CAFilter`，靠`name` 让 keyPath 找得到它。
    /// 模糊那个原版是在别处建的（`setBlurRadius` 第一次动它之前就存在），
    /// 这里一并建出来——两个都在才保证 `filters` 数组的顺序是先模糊后亮度。
    func installFocusFiltersIfNeeded() {
        guard brightnessFilter == nil else { return }

        let blur = blurFilter ?? {
            let f = CIFilter(name: "CIGaussianBlur")
            f?.name = "gaussianBlur"
            f?.setValue(0, forKey: "inputRadius")
            return f
        }()
        blurFilter = blur

        let brightness = CIFilter(name: "CIColorControls")
        brightness?.name = "colorBrightness"
        brightness?.setValue(0, forKey: "inputBrightness")
        brightnessFilter = brightness

        // 滤镜要画到行框之外（模糊的尾巴、辉光），不能裁。
        masksToBounds = false
        // 下面 `setLineFocused` 的动画收尾会开`shouldRasterize`，而
        // `rasterizationScale` 默认 1.0——不在这里钉死，缓存位图就按 1× 画。
        rasterizationScale = renderingScale
        contentsScale = renderingScale
        filters = [blur, brightness].compactMap { $0 }
    }

    /// 切换聚焦（悬停）外观。复现原版的 `focused:animated:` 那条。
    ///
    /// 三段：
    ///
    /// 1. **早退**：读的同一个字段槽与
    /// 判「状态没变」时读写的是**同一个**——
    ///    即 `isSelected`。**选中的行不吃悬停**：它已经是满亮度、零模糊，
    ///    再叠一层只会闪。这条是两个函数交叉印证出来的，不是猜的。
    /// 2. **算目标值**：亮度 `focused ? ±1 : 0`（一次二选一）；
    ///    模糊 `focused ? 0 : blurRadius`（的分支）。
    ///    注意失焦时**恢复的是图层自己记着的 `blurRadius`**，不是写死的 3.0——
    ///    3.0 只出现在 `deselecting all` 里（§1.5）。
    /// 3. **落值**：`animated` 为真时先`shouldRasterize = false`，
    ///    再用上面那条 `.custom` 曲线把两个 keyPath 一起动过去；为假时
    ///    直接两次 `setValue(_:forKeyPath:)`。最后无论哪支都写`isLineFocused`
    ///    （两支汇合）。
    func setLineFocused(_ focused: Bool, animated: Bool) {
        // 1. 选中的行不参与悬停外观。[实测]
        guard !isSelected else { return }

        installFocusFiltersIfNeeded()

        let brightness = focused ? focusedBrightnessAmount : 0
        let blur = focused ? 0 : blurRadius

        if animated {
            shouldRasterize = false
            let animator = LayerPropertyAnimator(curve: Self.focusTransitionCurve)
            animator.addAnimation(to: self,
                                  keyPath: Self.brightnessKeyPath,
                                  from: value(forKeyPath: Self.brightnessKeyPath),
                                  to: brightness,
                                  frameRateRange: (min: 0, max: 0))
            animator.addAnimation(to: self,
                                  keyPath: Self.blurKeyPath,
                                  from: value(forKeyPath: Self.blurKeyPath),
                                  to: blur,
                                  frameRateRange: (min: 0, max: 0))
            // –挂的完成回调只有三条指令：
            // 取出捕获的图层，尾调 `setShouldRasterize:` 传 1。
            // 也就是**动画期间关光栅化、跑完再打开**——滤镜在动的时候缓存位图没有意义，
            // 动完了才值得缓存。复刻漏掉这条不会出错，但每帧都会重画。
            animator.completionHandlers.append { [self] in
                // **与 Apple 的差异**：原版这个回调无条件 `setShouldRasterize:1`
                // Amber 多一道闸——回调落地时若这一行已经成了选中行，
                // 就不开。理由：`apply(selected:)`（§1.6 第 2 步）在「悬停行变成选中行」
                // 时也走这条失焦收尾，而它是先调 `setLineFocused(false, …)`、
                // 再写 `isSelected`；0.12s 后回调跑起来时这一行正每帧
                // 推进逐字渐变遮罩，开了光栅化等于让 CoreAnimation 每帧重建整层位图。
                // 缓存位图与滤镜结果都不变，差别只在有没有那份缓存，画面一像素不动。
                guard !isSelected else { return }
                shouldRasterize = true
            }
            animator.finishDispatch {
                self.setValue(brightness, forKeyPath: Self.brightnessKeyPath)
                self.setValue(blur, forKeyPath: Self.blurKeyPath)
            }
        } else {
            setValue(brightness, forKeyPath: Self.brightnessKeyPath)
            setValue(blur, forKeyPath: Self.blurKeyPath)
        }

        isLineFocused = focused
    }
}

extension SyncedLyricsLineLayer {

    /// 设逐行模糊半径。规格 §9.6。
    ///
    /// 三条：
    ///
    /// - **值没变就整个不做**（的）。这条和
    /// 开头那条早退是同一种防抖——每帧都会调进来。
    /// - 动画支先 `shouldRasterize = false`，再用**和聚焦切换
    ///   完全同一条曲线**（–载入的还是那三个常量、tag 还是 5）
    ///   把 `filters.gaussianBlur.inputRadius` 动过去。
    ///   这是第三处独立构造点，`focusTransitionCurve` 可以当定论。
    /// - 最后把 `blurRadius` 落到字段上——动画在滤镜上跑，真值记在图层字段里，
    ///   下次比较用的就是这个字段。
    func setBlurRadius(_ radius: CGFloat, animated: Bool) {
        guard radius != blurRadius else { return }

        installFocusFiltersIfNeeded()

        if animated {
            shouldRasterize = false
            let animator = LayerPropertyAnimator(curve: Self.focusTransitionCurve)
            animator.layers = [self]
            animator.addAnimation(to: self,
                                  keyPath: Self.blurKeyPath,
                                  from: blurRadius,
                                  to: radius,
                                  frameRateRange: (min: 0, max: 0))
            animator.finishDispatch {
                self.setValue(radius, forKeyPath: Self.blurKeyPath)
            }
        } else {
            setValue(radius, forKeyPath: Self.blurKeyPath)
        }

        previousBlurRadius = blurRadius
        blurRadius = radius
    }

    /// 让逐字内容层从某个时刻起接着推进度。
    ///
    /// [实测] 末尾会带着 `(animated, elapsed)` 往下推一次。
    /// 前面三道闸：`contentLayer` 非 nil、能转型成 **`SBS_TextContentLayer`**
    /// （类名实测得到）、`manager` 非 nil。整行文本层与间奏层都不吃这一步。
    func startProgress(at elapsed: TimeInterval, animated: Bool) {
        (contentLayer as? SBS_TextContentLayerProgress)?
            .setProgress(elapsed, animated: animated)
    }
}

/// 逐字内容层的进度面。复现在这里。
///
/// 原版 `SBS_TextContentLayer` 自己存一个进度，再往两个`TextLayer`
/// （主唱 + 和声，同一个字段槽）转发。
protocol SBS_TextContentLayerProgress: AnyObject {
    func setProgress(_ progress: Double, animated: Bool)
}

extension SBS_TextContentLayerProgress {

    /// 两级「值没变就不做」，第二级还带一条**倒退阈值**。
    ///
    /// [实测]：
    ///
    /// ```
    /// delta = 子层.progress − 新值
    /// fcmp  新值, 子层.progress
    /// fccmp delta, 0.5, #0, mi        ; 只有「新值更小」时才比这一下
    /// b.mi  跳过                       ; delta < 0.5 → 不下发
    /// ```
    ///
    /// 即 **往前永远下发；往回只有退超过 0.5 才下发**。
    /// 逐字进度每帧都在抖，时间源来回几十毫秒是常态——这条闸把抖动吃掉，
    /// 只放行真正的 seek。复刻漏了它，逐字渐变会在时间源抖动时反复回缩。
    static func shouldForward(newProgress: Double, current: Double) -> Bool {
        guard newProgress != current else { return false }
        if newProgress < current { return current - newProgress >= 0.5 }
        return true
    }
}
