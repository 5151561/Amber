import AppKit

extension SyncedLyricsViewController {

    /// 间奏三个滚动入口的公共骨架。规格见 §3.5。
    ///
    /// [实测] `animateInstrumentalStart`、
    /// `animateInstrumentalEnd`、`dismissInstrumentalView`
    /// 三者共用：从锚点行往后逐行重测几何、写 frame，最后一行触发文档收口，
    /// 然后一次性把 `contentView.bounds.origin` 换掉（只换 origin，同 §2.2）。
    ///
    /// - Parameters:
    ///   - anchorIndex: 锚点行在 `lyrics.lines` 里的下标。三个入口只有这个来源不同：
    ///     start 用入参那一行、end 用入参数组的第 0 个、dismiss 由
    ///     `documentVisibleRect` 现找。
    ///   - origin: 要写进 clip view 的滚动 origin。
    ///   - measure: 行几何，对应原版的 `(view, mode: 2, ctx)`。
    func relayoutLines(from anchorIndex: Int,
                              scrollingTo origin: CGPoint,
                              measure: (SyncedLyricsLineView, Int) -> CGRect) {
        guard let manager, anchorIndex >= 0 else { return }
        let lastIndex = (lyrics?.lines.count ?? 0) - 1

        // §17.2 说这几步在屏幕上是**零位移**的——行 +delta、视口 +delta 两边抵消。
        // 让行 frame 吃一条 0.25s 的隐式动画，抵消就不成立了，视口先走、行慢慢跟。
        withoutImplicitAnimation {
            for index in anchorIndex..<manager.lineViews.count {
                let view = manager.lineViews[index]
                view.frame = measure(view, index)
                // 最后一行之后要收口文档高度、摆免责声明标签。
                if index == lastIndex {
                    collapseDocument(below: view)
                }
            }
        }
        setScrollOrigin(origin)
    }

    /// `animateInstrumentalStart`：展开动画的**完成回调**，不是动画本身。规格见 §17.2。
    ///
    /// [实测] 它挂在 `animator.completionHandlers`，
    /// 动画**结束之后**才跑，三步：
    ///
    /// 1. 受影响的行 `frame.origin.y += delta`——把动画期间用的
    ///    临时坐标还原成真实布局；
    /// 2. 从间奏行下标一直重排到最后一行，最后一行收口文档；
    /// 3. 一次性把 `contentView.bounds.origin` 换成目标 origin。
    ///
    /// **这三步在屏幕上是零位移的**：行 +delta、视口 +delta，两边抵消。
    /// 它只是把「动画期间的临时坐标 + 没动过的视口」换成「真实布局 + 真实滚动位置」。
    ///
    /// 未接线：Amber 的展开走 `animateInstrumentalExpansion`（叠加式，第一帧就落到真值），
    /// 压根不建临时坐标，也就没有这一步对账。留着记原版的三步。
    func animateInstrumentalStart(shifting views: [SyncedLyricsLineView],
                                         byDeltaY delta: CGFloat,
                                         anchorIndex: Int,
                                         scrollingTo origin: CGPoint,
                                         measure: (SyncedLyricsLineView, Int) -> CGRect) {
        adjustLineViews(views, byDeltaY: delta)
        relayoutLines(from: anchorIndex, scrollingTo: origin, measure: measure)
    }

    /// 间奏展开的动画本体。规格见 §16.3 / §17.1 / §17.2 与 §6.5 的叠加式下发。
    ///
    /// 屏幕上要的效果（[PX] 2026-09-04 录屏实测）：
    ///
    /// - 间奏行与它上方的行：**上移 `delta`**；
    /// - 它下方的行：**下移 `撑开量 − delta`**，而且逐行错开——上方走完三分之一时，
    ///   下方还一格没动。
    ///
    /// 实现上**不建临时坐标**：布局与视口第一帧就落到真值（行落到重排后的位置、
    /// 视口 `+= delta`），动画层只挂一条**叠加偏移**把「看起来还在原处」这件事
    /// 在时间上退回 0（§6.5）。两条理由：
    ///
    /// 1. 并发重排不打架。上一句被时间轴淘汰时会走 `deselectLine → relayout`，
    ///    那条路会 `recomputeLineFrames` 并立即提交没在动画里的行。若文档处在
    ///    「真实落点 − delta」的临时坐标里，这一提交会把行按真值写回、而视口还没挪，
    ///    上一句当场往下跳 `delta`，**和三个点叠在一起**。
    /// 2. 视口一次到位，不参与插值。视口若跟着滚，晚起跑的下方行会被拖着先跟上去
    ///    再回落——观感就是「下一句跟上来了」。
    ///
    /// 每一行的初始偏移 = 「它此刻在屏幕上的位置」减「它落位后在屏幕上的位置」：
    /// `offset = 呈现层 y − 真实落点 y + delta`。上方 ⇒`+delta`，下方 ⇒`−(撑开量 − delta)`。
    @discardableResult
    func animateInstrumentalExpansion(affected: [SyncedLyricsLineView],
                                      anchorIndex: Int,
                                      deltaY delta: CGFloat,
                                      animation: SyncedLyricsLineLayer.SelectionAnimation,
                                      stagger: LineStagger) -> [LayerPropertyAnimator] {
        recomputeLineFrames()
        guard let manager, let clip = scrollView?.contentView else { return [] }

        // 动画开始前每一行在屏幕上的位置（呈现层优先：上一轮弹簧可能还在跑）。
        let before: [ObjectIdentifier: CGFloat] = manager.lineViews.reduce(into: [:]) { map, view in
            guard let layer = view.layer else { return }
            map[ObjectIdentifier(view)] = (layer.presentation()?.position ?? layer.position).y
        }

        // 一、布局与视口一次到位（§17.2 的对账在这里就做完了，动画只补偏移）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in manager.lineViews.enumerated() {
            view.frame = lineFrames[safe: index] ?? .zero
        }
        setScrollOrigin(CGPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        CATransaction.commit()
        collapseDocument(below: manager.lineViews.last)

        // 二、受影响的行各挂一条叠加偏移，按 §17.1 逐行错开。
        let curve = LyricsAnimationCurve.spring(
            SpringAnimationParameters(mass: animation.spring.mass,
                                      stiffness: animation.spring.stiffness,
                                      damping: animation.spring.damping,
                                      duration: animation.duration,
                                      settlingDuration: animation.settlingDuration))
        var animators: [LayerPropertyAnimator] = []
        for (ordinal, view) in affected.enumerated() {
            guard let layer = view.layer,
                  let start = before[ObjectIdentifier(view)] else { continue }
            let offset = CGPoint(x: 0, y: start - layer.position.y + delta)
            guard abs(offset.y) >= 0.5 else { continue }

            let animator = LayerPropertyAnimator(curve: curve)
            animator.delay = stagger.delay(movedOrdinal: animators.count,
                                           affectedOrdinal: ordinal)
            animator.layers = [layer]
            animator.addAdditiveAnimation(to: layer, keyPath: "position",
                                          offset: offset,
                                          frameRateRange: (min: 0, max: 0))
            animators.append(animator)
        }
        track(animators)
        return animators
    }

    /// 收起间奏行之后，滚动目标要把它占的那一格扣掉。
    ///
    /// [实测] `dismissInstrumentalView`：
    /// `d9 -= specs.instrumentalBreakViewHeight + specs.lineSpacing`。
    /// 间奏行从行流里消失，后面的行整体上移一格，目标 y 不同步减掉的话
    /// 收起的一瞬间会跳一格。
    func dismissInstrumentalOrigin(_ origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x,
                y: origin.y - (specs.instrumentalBreakViewHeight + specs.lineSpacing))
    }

    /// `dismissInstrumentalView` 的逐行错开量。
    ///
    /// [实测]：`Double(第几条被动画的行) × specs.lineDelay`，
    /// 存进动画记录的 delay 槽。`lineDelay = 0.05` 到这里才看清用法——
    /// **不是固定错开，是按序号线性累加**。弹簧本体仍走 §2.4 的
    /// 调用时传 `(0, 1)`。
    ///
    /// 未接线：同一条公式已经落在 `LineStagger.linear(specs.lineDelay)` 上，
    /// 收起间奏由 `relayout(…, stagger:)` 消费。
    func dismissInstrumentalDelay(forAnimatedLineOrdinal ordinal: Int) -> TimeInterval {
        Double(ordinal) * specs.lineDelay
    }

    /// 收口文档：摆免责声明标签、定 `documentView` 的高度。规格见 §3.6。
    ///
    /// [实测]，被间奏三个入口和 `layoutLines` 共同调用。
    ///
    /// 两条容易踩的：
    /// - **底部留白在同步模式下不是常量**，是「容器高 − 最后一行高」，
    ///   这才让最后一行也能被滚到屏幕中间；`staticBottomContentInset = 30`
    ///   只在 `renderingMode == .static` 生效。
    /// - 可用宽度这里取 **`scrollView`** 的宽度，而 §2.6 的行几何取 **`documentView`**
    ///   的宽度。稳态相等、重排那一帧不一定，别混用。
    @discardableResult
    func collapseDocument(below lastLineView: SyncedLyricsLineView?) -> CGRect {
        guard let scrollView, let documentView else { return .zero }
        let lineView = lastLineView ?? manager?.lineViews.last
        let lineFrame = lineView?.frame ?? .zero

        let containerWidth = scrollView.frame.width
        let available = containerWidth - margins.left - margins.right

        var bottomAnchor = lineFrame
        if let text = disclaimerText {
            let label = disclaimerLabel ?? {
                let l = NSTextField(labelWithAttributedString: text)
                l.wantsLayer = true
                disclaimerLabel = l
                return l
            }()
            label.attributedStringValue = text
            let size = label.sizeThatFits(CGSize(width: available, height: .infinity))
            // RTL 下 x 走的是「容器宽 − leading 边距」，不是镜像后的 trailing 边距。
            let x = view.userInterfaceLayoutDirection == .rightToLeft
                ? containerWidth - margins.left
                : margins.left
            label.frame = CGRect(x: x, y: lineFrame.maxY + specs.lineSpacing,
                                 width: size.width, height: size.height)
            documentView.addSubview(label)
            bottomAnchor = label.frame
        } else {
            disclaimerLabel?.removeFromSuperview()
            disclaimerLabel = nil
        }

        let bottomPadding: CGFloat
        switch specs.renderingMode {
        case .static: bottomPadding = specs.staticBottomContentInset
        case .synced: bottomPadding = scrollView.frame.height - lineFrame.height
        }

        let frame = CGRect(x: 0, y: 0,
                           width: containerWidth,
                           height: bottomAnchor.maxY + bottomPadding)
        documentView.frame = frame
        return frame
    }
}

extension SyncedLyricsViewController {

    /// 跳到间奏行时的交接。规格见 §5.4 第 7b 步。
    ///
    /// [实测] 判型命中 `InstrumentalContentLayer` 之后：先把
    /// `instrumentalBreakVisibleView` 换成目标行，再按一个布尔二选一——真就带着
    /// `elapsed` 走 §3.3 的每帧入口，假就只重排点。
    ///
    /// 关键在于**每帧入口被直接喂目标时刻**：拖到间奏中段，点不会从第一个重新亮起，
    /// 该亮的已经亮着、呼吸计数也已经追平。§3.3 那条「应亮 < 已亮就整体复位」
    /// 也正是在往回拖时靠这里触发。
    @discardableResult
    func handOffInstrumental(to lineView: SyncedLyricsLineView,
                                    elapsed: TimeInterval,
                                    advancesStateMachine: Bool) -> [InstrumentalContentLayer.FrameAction] {
        guard let dots = lineView.lineLayer?.contentLayer as? InstrumentalContentLayer
        else { return [] }
        manager?.instrumentalBreakVisibleView = lineView
        guard advancesStateMachine else {
            return dots.prepare(at: elapsed)                     //重排
        }
        return dots.advance(to: elapsed)                        //快进
    }
}
