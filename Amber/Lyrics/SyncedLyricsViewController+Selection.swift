import AppKit

// 批次 9 的 view controller 侧配件。规格见 §9.3 / §9.5。

extension SyncedLyricsViewController {

    /// 当前与可视矩形**相交**的行。
    ///
    /// [实测] 取 `scrollView.documentVisibleRect`，
    /// 逐行 `CGRectIntersectsRect(可视矩形, v.frame)` 过滤
    /// `manager.lineViews` 全表，命中的 append 进一个`ContiguousArray`。
    ///
    /// 注意判据是**相交**，和 §2.1 决定滚不滚时用的**包含**（`CGRectContainsRect`）
    /// 不是一回事：那边要求整行装得下，这边只要露出一点就算。
    ///
    /// 间奏展开那一路**不走这里**：它要的是「滚动前后任一时刻露出来的一段连续行」，
    /// 见 `affectedLineViews(aroundLineAt:deltaY:)`（§16.4）。
    func visibleLineViews() -> [SyncedLyricsLineView] {
        guard let scrollView, let manager else { return [] }
        let visible = scrollView.documentVisibleRect
        return manager.lineViews.filter { visible.intersects($0.frame) }
    }

    /// 当前是不是高对比度辅助功能外观。
    ///
    /// [实测] `view.effectiveAppearance.bestMatch(from:)` 对
    /// `[AccessibilityHighContrastAqua, AccessibilityHighContrastDarkAqua]`
    /// 求最佳匹配，非 nil 即真（的）。
    ///
    /// 两个用处，都是「高对比度下不模糊」：`deselecting all` c 与
    /// 和 `LyricsSpecs.dynamicWhite` 里那套
    /// 判据完全一样——颜色和模糊共用同一个开关。
    var isHighContrastAppearance: Bool {
        view.effectiveAppearance.bestMatch(from: [
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) != nil
    }

    /// 选中一行之后的重排 + 滚动。
    ///
    /// [实测] 在 `scrollView.contentView.layer` 上建一个`LayerPropertyAnimator`
    /// （取 `contentView`、取`layer`），挂三四个
    /// completion handler（两处往 `completionHandlers`
    /// 里 append），最后走下发。细节没走完 `[部分]`。
    ///
    /// 调用方 `selecting` 先抓一份`visibleLineViews()` 的快照捕进闭包
    /// 所以回调里看到的是**动画开始那一刻**的可见行集合。
    /// - Parameter stagger: 逐行错开方式。原版有两条**互不相同**的公式，见 `LineStagger`：
    ///   收起间奏是线性累加，间奏展开是 `lineDelay × (max(i,1) − 1)`
    ///   ——前两行共享 delay 0（§17.1）。平时整批行同时起步。
    func relayout(affected: [SyncedLyricsLineView],
                  animation: SyncedLyricsLineLayer.SelectionAnimation,
                  animated: Bool,
                  stagger: LineStagger = .none) {
        recomputeLineFrames()
        guard let manager else { return }

        // 只有 frame 真的变了的行才动。`LayerPropertyAnimator` 那边还有一道
        // 「值没变就不建动画」，这里先筛一遍省掉建对象。
        // `affectedOrdinal` 是这一行在**受影响的行**里的位置（含没动的行）——
        // §17.1 的错开量按它算，所以入参必须已经按行下标升序（`affectedLineViews` 会排）。
        let moved = affected.enumerated()
            .compactMap { affectedOrdinal, view -> (SyncedLyricsLineView, CGRect, Int)? in
                guard let index = manager.lineViews.firstIndex(where: { $0 === view }),
                      let frame = lineFrames[safe: index],
                      frame != view.frame else { return nil }
                return (view, frame, affectedOrdinal)
            }
        let animatedIDs = Set(moved.map { ObjectIdentifier($0.0) })

        // 行高变化（尤其是间奏三个点展开/收起）会改变后续所有行的位置。只更新
        // 当前可见行会让屏外行保留旧 frame，滚过去便出现巨大空档或整体漂移。
        // 可见行继续走动画，屏外变化立即提交，保证整份文档始终是一套几何。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in manager.lineViews.enumerated()
        where !animatedIDs.contains(ObjectIdentifier(view)) {
            view.frame = lineFrames[safe: index] ?? .zero
        }
        CATransaction.commit()
        defer { scrollToSelectedLine(animation: animation, animated: animated) }

        guard !moved.isEmpty else {
            collapseDocument(below: manager.lineViews.last)
            return
        }

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (view, frame, _) in moved { view.frame = frame }
            CATransaction.commit()
            collapseDocument(below: manager.lineViews.last)
            return
        }

        let curve = LyricsAnimationCurve.spring(
            SpringAnimationParameters(mass: animation.spring.mass,
                                      stiffness: animation.spring.stiffness,
                                      damping: animation.spring.damping,
                                      duration: animation.duration,
                                      settlingDuration: animation.settlingDuration))
        // 逐行错开时每行得有自己的 delay，而 `LayerPropertyAnimator` 的 delay 是
        // 整条动画记录一份的——只好一行一个 animator。不错开就仍走单个，
        // 少建一堆对象，也保持既有那条路径原样。
        let animators: [LayerPropertyAnimator]
        if stagger.isStaggered {
            animators = moved.enumerated().map { movedOrdinal, entry in
                let a = LayerPropertyAnimator(curve: curve)
                a.delay = stagger.delay(movedOrdinal: movedOrdinal,
                                        affectedOrdinal: entry.2)
                a.layers = [entry.0.layer].compactMap { $0 }
                return a
            }
        } else {
            let a = LayerPropertyAnimator(curve: curve)
            a.layers = moved.compactMap { $0.0.layer }
            animators = [a]
        }

        // `position` 不是行的中心：AppKit 背衬层的`anchorPoint` 是 (0, 0)，
        // position 恒等于 `frame.origin`。拿`frame.midX/midY` 当目标，弹簧期间
        // 每一行都会被推向右下各半个身位（x 偏 width/2，行越长偏得越多），
        // 动画收尾再弹回模型值——间奏三个点撑开那一下的「向右漂移」就是这么来的。
        //
        // 所以先把模型值落到位，再按落位后的**真实** position 建动画，
        // anchorPoint / flipped 怎么设都不用管。
        let starts: [(index: Int, layer: CALayer, from: CGPoint)] = moved.enumerated()
            .compactMap { index, entry in
                guard let layer = entry.0.layer else { return nil }
                // 上一轮弹簧还在跑时模型值已经是新的了，起点要取呈现层，否则会跳一下。
                return (index, layer, layer.presentation()?.position ?? layer.position)
            }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (view, frame, _) in moved { view.frame = frame }
        CATransaction.commit()
        for (index, layer, from) in starts {
            let animator = animators.count == 1 ? animators[0] : animators[index]
            animator.addAnimation(to: layer, keyPath: "position",
                                  from: from,
                                  to: layer.position,
                                  frameRateRange: (min: 0, max: 0))
        }
        track(animators)
        for animator in animators {
            animator.finishDispatch {
                for (view, frame, _) in moved { view.frame = frame }
                self.collapseDocument(below: manager.lineViews.last)
            }
        }
    }

    /// 把还亮着的第一行滚回它的目标位置。
    ///
    /// [实测]在 **`scrollView.contentView.layer`** 上
    /// 建 animator（取 `contentView`、取`layer`）——
    /// 也就是说「就地换选中态」那一支（§9.3）照样会滚，只是不走
    /// `animating to`。少了这一段，当前行完整可见时画面就再也不动了。
    ///
    /// 滚向哪一行由 `scrollTargetLineView` 判（滚动不提前、与高亮分开；最多领先正在唱的那句一行）。
    /// 旧行唱完淘汰（`deselectLine`）时目标行不变、已在目标位置（命中死区），平滑过渡无跳动。
    ///
    /// 三道闸照 §6.4：用户在拖、在 tracking、或 3 秒计时器还没到，都不抢镜头。
    func scrollToSelectedLine(animation: SyncedLyricsLineLayer.SelectionAnimation,
                              animated: Bool) {
        guard let manager,
              let target = manager.scrollTargetLineView(at: manager.currentElapsedTime())
                ?? manager.selectedLineViews.last
        else { return }
        scroll(toLineView: target, animation: animation, animated: animated)
    }

    /// 把焦点位挪到某一行，**不碰选中态**（选中态归 `selectLine` / `activateDueLines`）。
    /// 每帧的 `followScrollTarget` 用它：目标行完整可见就按 §9.3 就地那一支滚；
    /// 不完整可见照 §6.4 的四道闸走 `animating to` 的滚动部分（含 §2.8 的 delay 压缩）。
    func scrollFocus(to view: SyncedLyricsLineView,
                     animation: SyncedLyricsLineLayer.SelectionAnimation) {
        guard let manager else { return }
        let visible = scrollView?.documentVisibleRect ?? .zero
        let fitsVertically = view.frame.minY >= visible.minY && view.frame.maxY <= visible.maxY
        guard !fitsVertically, let line = view.lineLayer?.line else {
            scroll(toLineView: view, animation: animation, animated: true)
            return
        }
        guard animateToDecision(targetLineFrame: view.frame) == .scroll else { return }
        let elapsed = manager.currentElapsedTime()
        let (spring, delay) = lineChangeSpring(for: line, baseOffset: elapsed - line.startTime)
        manager.needsTapHandling = false
        scroll(to: targetOrigin(for: view), spring: spring, delay: delay)
    }

    /// 把某一行滚回它的目标位置（§2.5）。三道闸同上。
    ///
    /// 间奏展开那一路要单独指定锚点：那一批的目标行是**间奏行自己**，
    /// 而 `selectedLineViews.first` 在句与句交界处还是上一句。
    func scroll(toLineView view: SyncedLyricsLineView,
                animation: SyncedLyricsLineLayer.SelectionAnimation,
                animated: Bool) {
        guard let manager else { return }
        guard manager.mode == .regular, !isDragging,
              manager.allowAnimateToNextLineAfterScroll else { return }

        let origin = targetOrigin(for: view)
        guard animated else { setScrollOrigin(origin); return }
        scroll(to: origin, spring: animation.spring, delay: 0)
    }

    /// 目标行没被完整装下时的降级路径：滚动动画过去。
    ///
    /// [实测] `selecting` 尾调`animating to`，
    /// 参数 `(line, nil, true)`，外加一个 Double —— 那个 Double 是
    /// `elapsedTimeProvider() − 空间音频偏移`，
    /// 与 §1.2 的前两步一致。见 §5.5 / §6.4。
    func animate(to line: any LyricsLine, at elapsed: TimeInterval) {
        guard let manager, let view = manager.lineViews[safe: line.index] else { return }

        switch animateToDecision(targetLineFrame: view.frame) {
        case .selectOnly:
            // [实测]：**不是整个 return**——照样造描述符、
            // `selecting line(…, true, true)` 换外观，只是滚动位置一动不动。
            // 写成 return 的话，用户拖开歌词后当前行高亮会停在旧行上。
            manager.selectLine(line,
                               animation: manager.makeLineChangeAnimation(),
                               deselectingOthers: true,
                               updatesInstrumentalTime: true)

        case .scroll:
            let (spring, delay) = lineChangeSpring(for: line, baseOffset: elapsed - line.startTime)
            // 点击驱动的那条硬编码弹簧只管这一次滚动（§6.1），用完就撤旗。
            manager.needsTapHandling = false
            manager.selectLine(line,
                               animation: .init(spring: spring),
                               deselectingOthers: false,
                               updatesInstrumentalTime: true)
            scroll(to: scrollOrigin(forLineFrame: view.frame), spring: spring, delay: delay)
        }
    }
}

extension SyncedLyricsViewController {

    /// 撤掉正在跑的滚动 / 翻行动画。规格 §9.9。
    ///
    /// [实测] 遍历 `currentAnimators` 与`lineUpdateAnimationData`，
    /// 对每条动画先 `animationForKey:` 再`removeAnimationForKey:`
    /// 并把 animator 的 `state` 写回 idle
    /// （`strb wzr, [x27, #0x18]`——= 24，
    /// 正是 `LayerPropertyAnimator.state` 的偏移，和已有模型对上）。
    ///
    /// 用户一开始拖就调这个：**手在内容上时任何在跑的动画都是在跟他抢**，
    /// 直接撤掉，而不是等它跑完。
    /// 登记一批刚建好的动画器，顺手把已经跑完的剔掉。
    ///
    /// `currentAnimators` 原本只在`cancelRunningAnimations` 里整体清空，
    /// 而那条路**只有用户开始拖歌词时才走**——不拖歌词的话，每翻一行、每次间奏
    /// 展开都往里 append，一首歌下来就是几百个 `LayerPropertyAnimator` 连着它们
    /// 捕获的图层与闭包一直挂着。这里在两个 append 点共用一个入口：
    /// 登记前剔一次，并给每条动画器挂一个「落位后再剔一次」的完成回调。
    ///
    /// `cancelRunningAnimations` 的语义不变：它撤的是**还在跑的**那些，
    /// 已经跑完的本来就没有动画可撤（`isRemovedOnCompletion = true`，图层上早没了）。
    func track(_ animators: [LayerPropertyAnimator]) {
        pruneFinishedAnimators()
        for animator in animators {
            animator.completionHandlers.append { [weak self] in
                self?.pruneFinishedAnimators()
            }
        }
        currentAnimators.append(contentsOf: animators)
    }

    /// 把已经落位的动画器从 `currentAnimators` 里摘掉。判据见
    /// `LayerPropertyAnimator.isFinished`——不能只看`state == .idle`，
    /// 那样会把「刚建好、还没 `finishDispatch`」的（间奏展开那一路就是）一起摘走，
    /// 用户随后开拖时 `cancelRunningAnimations` 就撤不掉它们了。
    func pruneFinishedAnimators() {
        guard !currentAnimators.isEmpty else { return }
        currentAnimators.removeAll { $0.isFinished }
    }

    func cancelRunningAnimations() {
        for animator in currentAnimators {
            for layer in animator.layers {
                for keyPath in animator.animations.compactMap({ $0.value(forKey: "keyPath") as? String }) {
                    if layer.animation(forKey: keyPath) != nil {
                        layer.removeAnimation(forKey: keyPath)
                    }
                }
            }
            animator.state = .idle
        }
        currentAnimators = []
    }

    /// 一行应该落在哪儿。公式见 §2.5。
    ///
    /// 打开着的间奏行按**收起态**（高度 0）算锚点：展开那一批的 `delta` 就是这么算的
    /// （§16.5：算 delta 时 `instrumentalBreakVisibleView` 还是空的）。之后任何一次
    /// 「滚回还亮着的第一行」（`deselectLine` 收尾那次）若按 40 高再算一遍，
    /// 居中版式下会差**半个行高**，视口就在展开落定后又被推 20pt。
    /// [PX] Music 实测展开落定后 1.5s 内视口一格没动。
    func targetOrigin(for view: SyncedLyricsLineView) -> CGPoint {
        var frame = view.frame
        if manager?.instrumentalBreakVisibleView === view { frame.size.height = 0 }
        return scrollOrigin(forLineFrame: frame)
    }

    /// 与给定矩形相交的行。`deselecting line` 收尾时用的是
    /// 「目标位置 ∪ documentVisibleRect」这个并集（§9.8）。
    func lineViews(in rect: CGRect) -> [SyncedLyricsLineView] {
        manager?.lineViews.filter { rect.intersects($0.frame) } ?? []
    }
}
