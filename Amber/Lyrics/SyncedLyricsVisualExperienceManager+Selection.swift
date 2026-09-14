import AppKit
import QuartzCore

// 批次 9：选行状态机。三个入口 + 两个公共出口，规格见
// lyrics 规格 §9。
//
//   selecting——对外入口，决定滚不滚
//   selecting line——换选中态的实体
//   deselecting all——全量清空 + 回填模糊
// ——单行选中态出口（§1.6）
// ——单行模糊出口

extension SyncedLyricsVisualExperienceManager {

    // MARK: - 描述符工厂

    /// 造一次行外观切换用的动画描述。规格 §9.1。
    ///
    /// 两条路，分岔点在 **`lyrics.type`**（：`manager.lyrics` 非 nil 且
    /// `lyrics + 0x48 == 2`）：
    ///
    /// - **逐字歌词**（`.timedWords`）走的推导支：
    ///   弹簧不是常数，而是由入参 `speed` 现算的（见`derivedLineChangeSpring`）。
    /// - **其它**：直接用 `specs.lineChangeSpringTimingParameters`
    ///   （specs = `(1, 100, 18)`），再造一个临时
    ///   `CASpringAnimation` 把`settlingDuration` 读回来填进描述符。
    ///
    /// `selecting` 调它时传`(speed: 0, useSpecsSpring: true)`（的
    /// 所以**默认路径下永远是 specs 里那条弹簧**。
    func makeLineChangeAnimation(speed: Double = 0,
                                        useSpecsSpring: Bool = true)
        -> SyncedLyricsLineLayer.SelectionAnimation {
        // 逐字歌词才有资格走推导支。
        let derived = lyrics?.type == .timedWords && !useSpecsSpring
        let spring = derived ? Self.derivedLineChangeSpring(speed: speed)
                             : specs.lineChangeSpringTimingParameters
        return .init(spring: spring)
    }

    /// 逐字歌词的翻行弹簧：由一个归一化的「速度」现算，不读 specs。
    ///
    /// [实测]，全是立即数：
    ///
    /// ```
    /// u  = (speed >= 0.2) ? (min(speed, 0.75) − 0.2) / 0.55 : 0      ; ∈ [0, 1]
    /// ζ  = 0.78 + 0.12 · (1 − u)                                     ; 0.90 → 0.78
    /// T  = 0.48 + 0.27 · u                                           ; 0.48 → 0.75
    /// spring =(dampingRatio: ζ, response: T)
    /// ```
    ///
    /// 也就是：**唱得越快，阻尼比越低、周期越长**——快歌的翻行更"荡"一点，
    /// 慢歌更干脆。两条线性映射的四个端点都是实测。
    ///
    /// 入参 `speed` 的物理量纲没走完`[部分]`；`speed < 0.2` 时`u = 0`，
    /// 取到端点 `(ζ = 0.90, T = 0.48)`——注意 ζ = 0.90 正好是
    /// `specs.lineChangeSpringTimingParameters` `(1, 100, 18)` 的阻尼比，
    /// 两条路在下端是接上的。
    static func derivedLineChangeSpring(speed: Double) -> SpringTimingParameters {
        let u = speed >= 0.2 ? (min(speed, 0.75) - 0.2) / 0.55 : 0
        let dampingRatio = 0.78 + 0.12 * (1 - u)
        let response = 0.48 + 0.27 * u
        return SpringTimingParameters(dampingRatio: dampingRatio, response: response)
    }

    // MARK: - selecting line

    /// 换选中态。复现 `selecting line`，规格 §9.2。
    ///
    /// - Parameters:
    ///   - line: 目标行。原版从存在体的取下标
    /// 再 `lineViews[index]` 拿视图。
    ///   - animation: `nil` = 瞬时落值（tag 0xff）。
    ///   - deselectingOthers: `w2`。为真才遍历`selectedLineViews` 逐个取消
    ///     并清空数组（`tbz`）。**`selecting` 传 false**——
    ///     句与句交界处两行同亮就是靠这个；传 true 的是 `jumping to`（§5.4）。
    ///   - updatesInstrumentalTime: `w3`。为真时把当前播放进度推给间奏层
    ///     （`tbz`）。
    func selectLine(_ line: any LyricsLine,
                           animation: SyncedLyricsLineLayer.SelectionAnimation?,
                           deselectingOthers: Bool,
                           updatesInstrumentalTime: Bool) {
        guard lineViews.indices.contains(line.index) else { return }
        let target = lineViews[line.index]

        // 一、取消其它行。–
        if deselectingOthers {
            for view in selectedLineViews where view !== target {   //的 NSObject ==
                if view.isHighlighted { view.isHighlighted = false }
                view.setAccessibilitySelected(false)
                view.lineLayer?.apply(selected: false, animation: animation)
            }
            selectedLineViews = []                                 //写空数组存储
        }

        // 二、目标行进选中态。–
        if target.isHighlighted { target.isHighlighted = false }
        target.setAccessibilitySelected(true)
        target.lineLayer?.apply(selected: true, animation: animation)

        // 三、逐字内容层起进度。
        //    第二参数是 `animationKind != 0xff`，喂进去的时间是 §1.2 的前两步
        //    （elapsed − 空间音频偏移），**不含**第三步那个 animationDuration 提前量。
        startWordProgress(on: target, animated: animation != nil)

        // 四、间奏行的特判。–
        //    先取 `lineLayer.contentLayer`，再动态转型到
        //    `MusicInstrumentalContentLayer`（元数据来自）。
        //    转型成功才认这一行是间奏——判的是**内容层的类**，不是行模型的类型。
        if let dots = target.lineLayer?.contentLayer as? InstrumentalContentLayer {
            instrumentalBreakVisibleView = target
            if updatesInstrumentalTime {
                // 调——§3.3 倒带分支里那个「复位后重排」
                // 的入口，参数是当前时刻。选中一个间奏行等于**把点阵重建到该时刻**，
                // 不是从头播一遍：中途 seek 进间奏时点数要立刻对得上。
                // 这里对应的是独立的重排，不是只计算动作的
                // 每帧状态机。必须实际下发动画，否则计数已前进、点却仍是透明的。
                dots.prepare(at: currentElapsedTime())
            }
        }

        // 五、去模糊：传 `(target, true, 0.0)`
        setBlurRadius(0, on: target, animated: true)

        // 六、入列。–是 `Array.append`
        //    （`_makeUniqueAndReserveCapacityIfNotUnique` + `_appendElementAssumeUniqueAndCapacity`），
        //    不是 Set.insert——`selectedLineViews` 是**有序数组**，
        //    §1.3 的「队首出局」淘汰的就是它的第 0 个。
        selectedLineViews.append(target)
        // 起才打 "[SyncedLyricsDebug] selecting line …"，在所有副作用之后。
    }

    // MARK: - selecting

    /// 对外的选行入口。复现 `selecting`，规格 §9.3。
    ///
    /// 判据只有一条：**目标行的 frame 有没有被可视矩形完整装下**
    /// （`CGRectContainsRect`）。差一个像素都会降级成滚动动画。
    @discardableResult
    func select(_ line: any LyricsLine) -> SelectOutcome {
        guard let viewController else { return .skipped }
        guard lineViews.indices.contains(line.index) else { return .skipped }
        let view = lineViews[line.index]

        // 间奏行平时是 0 高，轮到它才把行流撑开一格（§16）。时序照 §16.6：
        //
        //   1. 先算 delta 与「受影响的行」——**此刻间奏行还是 0 高**，delta 不含那 40；
        //   2. 再同步 `selectLine`，它把`instrumentalBreakVisibleView`
        //      指向这一行，行高这才变成 40；
        //   3. 最后才建动画。
        //
        // 第 2、3 步颠倒的话量到的高度还是 0，展开完全不发生。
        if line is InstrumentalLine,
           view.lineLayer?.contentLayer is InstrumentalContentLayer,
           instrumentalBreakVisibleView !== view {
            let delta = viewController.instrumentalOpenDelta(for: view)        // §16.5
            let affected = viewController.affectedLineViews(aroundLineAt: line.index,
                                                            deltaY: delta)     // §16.4
            #if DEBUG
            if CommandLine.arguments.contains("-lyricsdebug") {
                let slot = specs.instrumentalBreakViewHeight + specs.lineSpacing
                let previous = lineViews[safe: line.index - 1]?.frame ?? .zero
                let msg = "[间奏] delta=\(delta.rounded()) 撑开量=\(slot) "
                    + "下方位移=\(slot - delta) 上一句行盒=\(previous.height.rounded()) "
                    + "行距=\(specs.lineSpacing) 受影响=\(affected.count)\n"
                FileHandle.standardError.write(Data(msg.utf8))   // stdout 是块缓冲的，走 stderr
            }
            #endif
            let animation = makeLineChangeAnimation(speed: 0, useSpecsSpring: true)
            selectLine(line, animation: animation,
                       deselectingOthers: false, updatesInstrumentalTime: true)
            // 动画期间**视口不动**，每一行自己走到「真实落点 − delta」：上方（含间奏行）
            // 上移 delta、下方下移 `撑开量 − delta`，逐行错开（§16.3 / §17.1 / §17.2）。
            // 跑完由完成回调一次对账（行 += delta、视口 += delta，屏幕零位移）。
            //
            // 视口在动画期间**不能**跟着滚：晚起跑的下方行会被拖着先跟上去再回落，
            // 观感就是「下一句跟上来了」——Music 实测下方行在上方走完三分之一时仍一格没动。
            viewController.animateInstrumentalExpansion(
                affected: affected,
                anchorIndex: line.index,
                deltaY: delta,
                animation: animation,
                stagger: .sharedFirstPair(specs.lineDelay))    // §17.1
            viewController.hideLines(above: line.index, among: affected)         // §17.2
            return .selectedInPlace
        }

        let visible = viewController.scrollView?.documentVisibleRect ?? .zero
        // [实测] 是 `CGRectContainsRect(visible, lineFrame)`，整个矩形都比。
        // **Amber 这里只比纵向**，原因是两边的横向前提不一样：
        //
        // Music 的行框是满宽（[PX] §22.3：面板 683、行左缘 19、行宽 645），而它的
        // `documentVisibleRect` 就是整幅面板宽，横向那一半恒真，contains 实际只在比纵向。
        // Amber 的 clip view 会因为内容内缩 / 滚动条比 documentView 窄几个点，而行框自本轮
        // 起也是满宽（= 可用宽）——横向就可能差那么一点点，于是一个**纵向**的判断
        // （「这一行整个装得下吗」）被横向翻掉：每次翻行都判成「装不下」，
        // 走 `animate(to:)` 整屏滚过去，而不是就地重排。这正是「只有整屏滑动」。
        //
        // 面板只纵向滚，横向从来不是「可见与否」的自由度，所以只比纵向既保住原意
        // 又不受这几个点的影响。`[补]`
        let fitsVertically = view.frame.minY >= visible.minY && view.frame.maxY <= visible.maxY
        if fitsVertically {
            // 完全可见 → 不滚，就地换选中态。起
            let animation = makeLineChangeAnimation(speed: 0, useSpecsSpring: true)
            selectLine(line, animation: animation,
                       deselectingOthers: false, updatesInstrumentalTime: true)
            // 抓一份「当前与可视矩形相交的行」快照，
            // 连同 self 与描述符一起捕进闭包，作为随后那次布局的回调。
            let affected = viewController.visibleLineViews()
            viewController.relayout(affected: affected,
                                    animation: animation,
                                    animated: true)
            return .selectedInPlace
        } else {
            // 不完全可见 → "line is not completely visible on screen, animating to it instead."
            viewController.animate(to: line, at: currentElapsedTime())
            return .animatedTo
        }
    }

    /// `select(_:)` 走了哪一支。原版没有返回值，这里留给调用方对账。
    enum SelectOutcome: Sendable { case skipped, selectedInPlace, animatedTo }

    // MARK: - deselecting all

    /// 全量取消选中，并把行重新模糊回去。复现 `deselecting all`，规格 §9.5。
    ///
    /// 未接线：Amber 的取消选中是逐行的（`deselectLine`，由时间轴淘汰驱动），
    /// 没有「一次全清」的触发点。留着记 §9.5 的两道闸与那条弹簧。
    func deselectAll() {
        // `mode != .regular` 直接返回。
        // 用户手还在内容上时**不清选中**——拖动中歌词不会整片暗下去。
        guard mode == .regular else { return }
        // ：VC 上还有一道布尔闸（同一个字段槽），
        // 位置与 §2.9 里 `scrollViewWillBeginScrolling` 置位的那个一致，按`isDragging` 读。[推]
        guard let viewController, !viewController.isDragging else { return }

        for view in selectedLineViews {
            // 起：**每一行都现造一次弹簧描述符**——
            // 循环体里新建一个 `CASpringAnimation` 只为读回`settlingDuration`，
            // 再丢掉。参数每次都一样，纯属没提到循环外。照抄没必要，提出去即可。
            let animation = SyncedLyricsLineLayer.SelectionAnimation(
                spring: specs.lineChangeSpringTimingParameters)

            if view.isHighlighted { view.isHighlighted = false }
            view.setAccessibilitySelected(false)
            view.lineLayer?.apply(selected: false, animation: animation)

            // `specs.lineBlurEnabled`（manager = specs）
            // 不开就跳过后面整段——连 `blurredLineViews` 都不登记。
            guard specs.lineBlurEnabled else { continue }
            // ：高对比度辅助功能外观下**不模糊**。
            // 判据与 `LyricsSpecs.dynamicWhite` 里那套`bestMatch` 完全一致。
            guard !viewController.isHighContrastAppearance else { continue }

            setBlurRadius(Self.deselectedBlurRadius, on: view, animated: true)
        }
        selectedLineViews = []
    }

    // MARK: - 单行模糊出口

    /// 设一行的模糊半径，并同步 `blurredLineViews`。规格 §9.6。
    ///
    /// 两道闸加一个夹取：
    ///
    /// - `specs.lineBlurEnabled` 且**不是**高对比度外观时，
    ///   任何半径都放行；否则只放行 `radius <= 0`。
    ///   即**加模糊会被禁用/高对比度挡住，去模糊永远允许**。
    /// -：`radius = min(radius, 4.0)`。上限 4 是写死的，
    ///   §1.5 那个 3.0 是 `deselecting all` 的取值，不是上限。
    /// -：`radius == 0` → 从`blurredLineViews` 移除
    /// 否则插入（是 `Set.insert`）。
    func setBlurRadius(_ radius: CGFloat,
                              on view: SyncedLyricsLineView,
                              animated: Bool) {
        let allowed = specs.lineBlurEnabled
            && !(viewController?.isHighContrastAppearance ?? false)
        guard allowed || radius <= 0 else { return }

        let clamped = min(radius, Self.maxBlurRadius)
        view.lineLayer?.setBlurRadius(clamped, animated: animated)

        if radius == 0 {
            blurredLineViews.remove(view)
        } else {
            blurredLineViews.insert(view)
        }
    }

    /// 逐行模糊半径的上限。[实测] 的。
    static let maxBlurRadius: CGFloat = 4.0

    // MARK: - 暂停期间不模糊（[PX] §22.3）

    /// 按播放/暂停态开关整表模糊。每帧由 `displayLinkFired` 调一次。
    ///
    /// [PX] §22.3 末段的实测：「焦点行清晰、其余行高斯模糊；**暂停后全部行清晰**
    /// （blur 只在播放中应用）」——这是 `px-lyric-font.swift` 扫字号时被迫记下来的
    /// 副产物：暂停态的样本每一行都是清晰带（过渡宽 1-2px），播放态只有焦点行是。
    /// 静态侧没读到对应的闸（只有 `lineBlurEnabled` 与高对比度
    /// 两道），推测在宿主侧按播放态调这两条出口，Amber 按实测接。`[推]`
    ///
    /// 两条纪律：
    /// - 去模糊/回填都走 `setBlurRadius(_:on:animated:)` 这个唯一出口，
    ///   §9.6 那两道闸原样生效（关掉模糊或高对比度时回填会被挡，清除永远允许）。
    /// - 回填只在 `.regular` 下做。用户手还在内容上（`.scroll` / `.tracking`）时
    ///   整表本来就该是清的（§9.9 `clearAllBlur`），这里不去跟它抢。
    func syncBlurToPlaybackState() {
        guard let paused = timingProvider?.isPaused else { return }
        let previous = isPlaybackPausedForBlur
        let changed = previous != paused
        isPlaybackPausedForBlur = paused

        if paused {
            // 换歌 / 换行也可能在暂停期间往回填模糊（`setLyrics` 里那次「带着模糊
            // 出生」就是），所以暂停态每帧都看一眼集合空不空，不只看边沿。
            guard changed || !blurredLineViews.isEmpty else { return }
            // 首帧（`previous == nil`）直接落值：面板是暂停着打开的时候，
            // 不该先闪一下模糊再淡开。
            clearBlurForPause(animated: previous != nil)
        } else if changed {
            restoreBlurAfterPause()
        }
    }

    /// 暂停：全表去模糊。`radius == 0` 恒被放行，也顺带把`blurredLineViews` 排空。
    private func clearBlurForPause(animated: Bool) {
        guard !blurredLineViews.isEmpty else { return }
        let onScreen = Set((viewController?.visibleLineViews() ?? []).map(ObjectIdentifier.init))
        // 屏外行直接落值：同 §9.9，看不见的行没必要各起一条 0.12s 的淡变。
        for view in blurredLineViews {
            setBlurRadius(0, on: view,
                          animated: animated && onScreen.contains(ObjectIdentifier(view)))
        }
        blurredLineViews = []
    }

    /// 恢复播放：非选中行重新糊回去。判据仍是二值的「是不是当前聚焦行」（§1.5）。
    private func restoreBlurAfterPause() {
        guard mode == .regular else { return }
        let onScreen = Set((viewController?.visibleLineViews() ?? []).map(ObjectIdentifier.init))
        let selected = Set(selectedLineViews.map(ObjectIdentifier.init))
        for view in lineViews where !selected.contains(ObjectIdentifier(view)) {
            setBlurRadius(Self.deselectedBlurRadius, on: view,
                          animated: onScreen.contains(ObjectIdentifier(view)))
        }
    }

    // MARK: - 模式切换的外观下发

    /// 进入 `.scroll` 时的外观收尾。规格 §9.7。
    ///
    /// [实测] `-[… scrollViewWillBeginScrolling]` → → 这里。
    ///
    /// ```
    /// specs.renderingMode == .static → return       ; 整块不可交互
    /// (self)                          ; [部分]
    /// (viewController)                ; [部分]
    /// allowAnimateToNextLineAfterScroll = false
    /// allowAnimateToNextLineAfterScrollTimer.invalidate() 并置 nil
    /// for v in hiddenLineViews { v.alphaValue = 1; hiddenLineViews.remove(v) }
    /// ```
    ///
    /// 最后那段是这次批次里唯一一处**模式切换直接改外观**的地方：
    /// `hidePreviousLines`（specs）藏起来的行，一开始拖就**全部恢复不透明**，
    /// 并清空 `hiddenLineViews`。用户要翻看歌词，藏着的部分必须先露出来。
    /// 注意恢复是**瞬时赋值**，没有动画（`setAlphaValue: 1.0` 直接调）。
    func beginScrollingAppearance() {
        guard specs.renderingMode != .static else { return }

        clearAllBlur()
        viewController?.cancelRunningAnimations()

        allowAnimateToNextLineAfterScroll = false
        allowAnimateToNextLineAfterScrollTimer?.invalidate()
        allowAnimateToNextLineAfterScrollTimer = nil

        for view in hiddenLineViews {
            view.alphaValue = 1.0
        }
        hiddenLineViews = []                                        //逐个 remove
    }

    // MARK: - deselecting line

    /// 取消**单独一行**的选中。规格 §9.8。
    ///
    /// 这个函数原先没被列进来——它没有 `[SyncedLyricsDebug]` 字符串，是顺着
    /// 的调用方反查出来的。它补上了 §9.2 留的空白：
    /// `selecting` 传`deselectingOthers = false`、只往`selectedLineViews` 里追加，
    /// 那么谁负责减？就是这里。§1.3 的「队首出局」在视图侧走的是这条路。
    ///
    /// ```
    /// index = line.index
    /// view  = lineViews[index]
    /// 在 selectedLineViews 里线性找到 view → remove(at: i)
    /// desc  =(0, 1); desc.tag = 0
    /// view.isHighlighted = false
    /// view.setAccessibilitySelected(false)
    /// (false, desc)
    /// (view, animated: true, radius: 3.0)
    /// ```
    ///
    /// 两条：
    ///
    /// - **3.0 在这里第二次出现**（的）。§1.5 只记了
    ///   `deselecting all` 那一处；两个独立取值点一致，这个常量可以当定论。
    /// - **移除用的是线性查找 + `remove(at:)`**，不是`Set.remove`——又一条
    ///   `selectedLineViews` 是数组的证据。
    ///
    /// 收尾还有一段：若移除后 `selectedLineViews` 还有元素，就拿**剩下的第一行**
    /// 算目标位置（§2.5），与 `documentVisibleRect` 求
    /// `CGRectUnion`，据此重排并滚回去。
    /// 也就是说**取消一行之后画面会跟着收回到还亮着的那一行**，不会停在原地。
    /// 并集是为了把「旧位置到新位置」整段都算进重排范围。
    func deselectLine(_ line: any LyricsLine) {
        guard lineViews.indices.contains(line.index) else { return }
        let view = lineViews[line.index]

        if let i = selectedLineViews.firstIndex(where: { $0 === view }) {
            selectedLineViews.remove(at: i)
        }

        let animation = makeLineChangeAnimation(speed: 0, useSpecsSpring: true)
        if view.isHighlighted { view.isHighlighted = false }
        view.setAccessibilitySelected(false)
        view.lineLayer?.apply(selected: false, animation: animation)
        setBlurRadius(Self.deselectedBlurRadius, on: view, animated: true)
        // 间奏行是这一路收起的：先把字段置空，再让下面那次重排把它收掉（§9）。
        let dismissesInstrumental = instrumentalBreakVisibleView === view
        if dismissesInstrumental {
            instrumentalBreakVisibleView = nil
        }

        // 收回到还亮着的第一行。–
        guard let first = selectedLineViews.first,
              let viewController, let scrollView = viewController.scrollView
        else { return }
        let target = viewController.targetOrigin(for: first)        //，§2.5
        let span = CGRect(origin: target, size: .zero)
            .union(scrollView.documentVisibleRect)
        viewController.relayout(affected: viewController.lineViews(in: span),
                                animation: animation,
                                animated: true,
                                // 收起间奏行时逐行错开，第 n 条延迟 n × 0.05——
                                // 这条是**线性累加**，和展开那条 max(i,1)−1 不是一个公式。
                                stagger: dismissesInstrumental ? .linear(specs.lineDelay) : .none)
    }

    // MARK: - 拖动前的清场

    /// 把所有行的模糊清掉。规格 §9.9。
    ///
    /// [实测] 遍历 `blurredLineViews`，每个都过和 §9.6 一样的两道闸
    /// （`specs.lineBlurEnabled`、非高对比度外观），
    /// 然后 `setShouldRasterize(false)` + 动画`filters.gaussianBlur.inputRadius`，
    /// 最后从集合里摘掉。
    ///
    /// 收尾还有第二段（起）：遍历 `lineViews`，给每个`lineLayer`
    /// 的一个 Bool 写 1（同一个字段槽，紧挨着 `isSelected`(cb8)
    /// 与 `contentLayer`(cc0)，按`isScrolling` 读`[推]`），再
    /// 把这件事转告内容层。
    ///
    /// 浏览态仍会把状态转告内容层，但内容层保留当前播放行的高亮，只提亮其它行。
    func clearAllBlur() {
        // 这是**拖动的第一帧**，而下面两个循环都是全表的：一首歌上百行，屏上撑死
        // 露出七八行。屏外行照样建动画，等于每次一碰歌词就凭空造几百条 0.12s 的
        // 淡变，全跑在没人看得见的图层上。屏外的直接落值——落到的是同一个终值，
        // 等它滚进视野时外观完全一致。
        let onScreen = Set((viewController?.visibleLineViews() ?? []).map(ObjectIdentifier.init))
        for view in blurredLineViews {
            view.lineLayer?.setBlurRadius(0, animated: onScreen.contains(ObjectIdentifier(view)))
        }
        blurredLineViews = []
        for view in lineViews {
            // 写 `isScrolling`，紧接着转告内容层——
            // 两件事在这里合成一个调用。
            view.lineLayer?.applyScrolling(true,
                                           animated: onScreen.contains(ObjectIdentifier(view)))
        }
    }

    /// `.scroll` 的反向：把「正在拖」撤掉，非选中行重新模糊回去。
    ///
    /// 原版没有单独的函数与之对应——3 秒计时器到点后是靠下一次
    /// `deselecting all` / `selecting line` 把外观带回来的。这里显式做一次，
    /// 免得用户拖完之后不再翻行（例如停在同一句上）时外观卡在 40% 白。`[补]`
    func endScrollingAppearance() {
        // 同 `clearAllBlur`：屏外行直接落值，屏内行照旧走那条 0.12s 的淡变。
        let onScreen = Set((viewController?.visibleLineViews() ?? []).map(ObjectIdentifier.init))
        for view in lineViews {
            view.lineLayer?.applyScrolling(false,
                                           animated: onScreen.contains(ObjectIdentifier(view)))
        }
        guard specs.lineBlurEnabled,
              viewController?.isHighContrastAppearance != true else { return }
        let selected = Set(selectedLineViews.map(ObjectIdentifier.init))
        for view in lineViews where !selected.contains(ObjectIdentifier(view)) {
            setBlurRadius(Self.deselectedBlurRadius, on: view,
                          animated: onScreen.contains(ObjectIdentifier(view)))
        }
    }

    // MARK: - 时间基准

    /// `selecting line` / / `selecting` 三处取时间的写法完全一样：
    /// `elapsedTimeProvider()` 再减掉空间音频偏移，**不加** §1.2 第三步那个
    /// `animationDuration` 提前量。提前量只用于选行判据，不用于喂给图层。
    func currentElapsedTime() -> TimeInterval {
        guard let manager else { return 0 }
        var t = manager.elapsedTimeProvider()
        if manager.isPlayingSpatial {
            t -= spatialLyricsOffset
        }
        return t
    }

    /// 空间音频的歌词偏移，取自 `lyrics.audioAttributes`。
    var spatialLyricsOffset: TimeInterval {
        for case .spatial(let offset) in lyrics?.audioAttributes ?? [] { return offset }
        return 0
    }

    /// 把当前时间推给逐字内容层。
    ///
    /// 前置三闸：`lineLayer.contentLayer` 非 nil、能转型成
    /// 给出的那个类（逐字内容层 `[部分]`）、`manager` 非 nil。
    /// 通过后带着 `(animated, elapsed − 空间偏移)` 往下推。
    func startWordProgress(on view: SyncedLyricsLineView, animated: Bool) {
        guard view.lineLayer?.contentLayer != nil, manager != nil else { return }
        view.lineLayer?.startProgress(at: currentElapsedTime(), animated: animated)
    }
}

extension SpringTimingParameters {
    /// 由阻尼比与周期反推 `(mass, stiffness, damping)`。
    ///
    /// [实测]，全部实测：
    ///
    /// ```
    /// mass = Double(1)
    /// k    = Double(2)
    /// π    = ; 是 π，不是 2π
    /// ω    = k · π / response = 2π / response
    /// stiffness = mass · ω²
    /// damping   = dampingRatio · 2 · √(stiffness · mass)
    /// ```
    ///
    /// 只有两条指令 / `ret`——就是`Double.init(Int)`，
    /// 所以那两个标量字面上是 **1 和 2**。与 SwiftUI `Spring(response:dampingRatio:)`
    /// 一字不差。
    ///
    /// 造完之后原版同样造一个临时 `CASpringAnimation` 读回`settlingDuration`
    /// 填进描述符，与另外两个构造点一致。
    init(dampingRatio: Double, response: TimeInterval, mass: Double = 1) {
        let omega = 2 * Double.pi / response
        let stiffness = mass * omega * omega
        self.init(mass: mass,
                  stiffness: stiffness,
                  damping: dampingRatio * 2 * (stiffness * mass).squareRoot())
    }
}
