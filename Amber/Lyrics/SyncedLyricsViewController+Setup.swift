import AppKit
import QuartzCore

/// 文档视图。y 往下长——行的纵向堆叠（§2.6）与滚动 origin 的公式（§2.5）
/// 都按这个方向写。
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 只多做一件事：把**滚轮**也算成「用户在拖」。
///
/// `willStartLiveScroll` / `didEndLiveScroll` 只有触控板那种带 phase 的滚动才发，
/// 普通鼠标滚轮一个通知都不发——照 AppKit 的默认走，用滚轮的人永远进不了
/// `.scroll` 模式（§2.9），歌词会一边被滚一边自动翻回去，跟用户抢。
final class LyricsScrollView: NSScrollView {

    var onUserScrollBegan: (() -> Void)?
    var onUserScrollEnded: (() -> Void)?
    var onLegacyScrollWheel: (() -> Void)?
    private var legacyScrollEndTimer: Timer?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // 有 phase 的交给 live scroll 通知，别重复上报。
        guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return }

        onLegacyScrollWheel?()
        if legacyScrollEndTimer == nil { onUserScrollBegan?() }
        legacyScrollEndTimer?.invalidate()
        // 滚轮没有「松手」事件，只能按静默时长判结束。
        legacyScrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.legacyScrollEndTimer = nil
                self?.onUserScrollEnded?()
            }
        }
    }
}

extension SyncedLyricsViewController {

    // MARK: - 搭台

    /// 建滚动视图与文档视图。
    ///
    /// 滚动位置**只通过写 `contentView.bounds.origin` 改**（§2.2），
    /// 所以这里不装 `NSScrollView` 自己的那套滚动动画。
    func installScrollView(in container: NSView) {
        let scrollView = LyricsScrollView()
        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = specs.showsVerticalScrollIndicator
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        // `contentView.postsBoundsChangedNotifications` 这里原本开着，但全仓没有任何
        // `NSView.boundsDidChangeNotification` 的监听方——歌词是逐帧写
        // `contentView.bounds.origin` 滚的（§2.2），开着就等于每帧白发一条通知。

        let document = FlippedDocumentView()
        document.wantsLayer = true
        // **这一位不在文档视图上开。** 滤镜挂在每个行视图自己的层树里
        // （`SyncedLyricsLineView.configure` 那一处才是必需的）；文档视图跟整份文稿
        // 一样高（几千 pt），在它上面开等于把整棵树按进程内渲染，滚动时全额重合成。
        scrollView.documentView = document

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.scrollView = scrollView
        self.documentView = document
        scrollView.onUserScrollBegan = { [weak self] in self?.scrollViewWillBeginScrolling() }
        scrollView.onUserScrollEnded = { [weak self] in self?.scrollViewDidEndScrolling() }
        scrollView.onLegacyScrollWheel = { [weak self] in self?.updateLineAlphasForViewportEdges() }
        installScrollObserversIfNeeded()
    }

    /// §2.9：手一碰就进 `.scroll`，松手起 3 秒计时器才交还控制权。
    ///
    /// 块式的 `addObserver(forName:object:queue:)` 注册的是**通知中心自己造的一个
    /// 令牌对象**，不是 `self`——`deinit` 里那句`removeObserver(self)` 摘不掉它，
    /// 于是闭包（连同它捕获的 `scrollView`）会一直挂在通知中心上。所以令牌得存下来，
    /// 由 `tearDown()` 逐个摘。可重入：已经装过就不再装，`viewWillAppear` 直接调。
    func installScrollObserversIfNeeded() {
        guard scrollObservers.isEmpty, let scrollView else { return }
        let center = NotificationCenter.default
        scrollObservers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                               object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollViewWillBeginScrolling() }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                               object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollViewDidEndScrolling() }
            },
            center.addObserver(forName: NSScrollView.didLiveScrollNotification,
                               object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLineAlphasForViewportEdges() }
            },
        ]
    }

    /// 摘掉块式观察者。`tearDown()` 与`deinit` 共用，重复调无副作用。
    func removeScrollObservers() {
        let center = NotificationCenter.default
        for token in scrollObservers { center.removeObserver(token) }
        scrollObservers = []
    }

    /// [实测] `-[… scrollViewWillBeginScrolling]`：置`isDragging`，
    /// `mode = .scroll`，并走 §9.7 的外观收尾。
    func scrollViewWillBeginScrolling() {
        isDragging = true
        cancelScrollSpring()
        manager?.beginScrolling()
    }

    /// [实测] `-[… scrollViewDidEndScrolling]` →。
    func scrollViewDidEndScrolling() {
        isDragging = false
        manager?.endScrolling()
    }

    // MARK: - 装歌词

    func setLyrics(_ lyrics: Lyrics?) {
        lyricsDebugLog("setLyrics: \(lyrics?.lines.count ?? 0) lines, type=\(String(describing: lyrics?.type))")
        isSettingLyrics = true
        defer { isSettingLyrics = false }

        self.lyrics = lyrics
        manager?.lyrics = lyrics
        manager?.needsTapHandling = false
        manager?.manager?.setLyrics(lyrics)

        guard let manager, let documentView else { return }
        clearHoverState()
        for view in manager.lineViews { view.removeFromSuperview() }
        manager.lineViews = []
        manager.selectedLineViews = []
        manager.blurredLineViews = []
        manager.hiddenLineViews = []
        manager.instrumentalBreakVisibleView = nil
        disclaimerLabel?.removeFromSuperview()
        disclaimerLabel = nil

        manager.lineViews = (lyrics?.lines ?? []).map { line in
            let view = SyncedLyricsLineView()
            view.configure(line: line, specs: specs)
            view.target = self
            view.action = #selector(lineViewTapped(_:))
            documentView.addSubview(view)
            return view
        }
        lineFrames = []
        relayoutEverything()

        // 行是**带着模糊出生**的：`selecting line` 第五步显式去模糊
        // （§9.2 的 `(target, true, 0.0)`），`deselecting line`
        // 又把 3.0 填回去（§9.8）——这套只有在「非选中行默认糊着」时才自洽。
        //
        // 静态档（整份无戳纯文本）反过来：**诞生即选中**。那一档的去模糊本来由
        // 时间驱动的选行负责，而这份词没有时间轴，模糊永远散不掉；叠上
        // `deselectedTextColor`（白 α0.175）就是一面看不见的墙。
        //
        // 一句就够，不需要 `setProgress`：无戳行没有音节，内容层恒是
        // `TextContentLayer`（见 `+Content.swift` 的分支），逐字渐变那条链
        // 结构上够不着；`animation: nil` 即瞬时落值 + 单位变换（不缩 0.98），
        // 内容层的主色于是取 `selectedTextColor`（100%）。
        //
        // **走图层直连、不进 `selectLine`**：`selectedLineViews` 是淘汰、滚动焦点
        // 与 `unblurredLineViewIDs` 三件事的依据，这面墙不参与那套状态机。
        // 不进 `blurredLineViews`，下游每一处「把模糊填回去」的循环也就无事可做。
        if specs.renderingMode == .static {
            for view in manager.lineViews {
                view.lineLayer?.apply(selected: true, animation: nil)
            }
        } else {
            for view in manager.lineViews {
                manager.setBlurRadius(SyncedLyricsVisualExperienceManager.deselectedBlurRadius,
                                      on: view, animated: false)
            }
        }
    }

    @objc func lineViewTapped(_ sender: Any?) {
        guard let view = sender as? SyncedLyricsLineView else { return }
        handleTap(on: view)
    }

    // MARK: - 行几何（§2.6）

    /// 重算全部行的 frame。原版是——
    /// 一次算一行，纵向的 y 靠外层循环累加；这里一次算完存进 `lineFrames`，
    /// `measure` 就退化成查表，三个滚动入口共用的`(view, index) -> CGRect` 签名不变。
    func recomputeLineFrames() {
        guard let manager, let documentView, let scrollView else { lineFrames = []; return }

        // 文档宽度先跟上视口。行几何取的是 **documentView** 的宽度（§2.6），
        // 而文档收口取的是 **scrollView** 的宽度（§3.6）——稳态相等，
        // 但第一次布局时文档还是零宽，不同步就一行都算不出来。
        if documentView.frame.width != scrollView.frame.width {
            documentView.frame.size.width = scrollView.frame.width
        }

        // [实测]：可用宽度 = documentView 宽 − 左右边距，非正就整段跳过。
        let available = LyricsLineGeometry.availableWidth(documentWidth: documentView.frame.width,
                                                          margins: margins)
        guard available > 0 else { lineFrames = []; return }

        var frames: [CGRect] = []
        frames.reserveCapacity(manager.lineViews.count)
        // [实测] 纵向落点从**上一行的 maxY** 现算（§16.2），第一行落在
        // `firstLineStartingPosition = 60`。这里按下标升序一次算完，
        // 等价于原版那条「读 lineViews[i−1] 此刻的 frame」的路。
        var previous: CGRect?

        for (index, view) in manager.lineViews.enumerated() {
            let line = lyrics?.lines[safe: index]
            let isVocalGroup = LyricsLineGeometry.isVocalGroup(line)
            let coefficient = LyricsLineGeometry.widthCoefficient(isVocalGroup: isVocalGroup,
                                                                  specs: specs)
            let measureWidth = available * coefficient          // [实测]
            // 宽受限、高无限：折行交给 TextKit，不限行数、不截断、不缩字号。
            let size = view.sizeThatFits(NSSize(width: measureWidth, height: .infinity))

            var y: CGFloat
            if let previous {
                y = LyricsLineGeometry.originY(
                    after: previous,
                    firstLineStartingPosition: specs.firstLineStartingPosition,
                    lineSpacing: specs.lineSpacing)
            } else {
                y = LyricsLineGeometry.firstLineY(
                    specs: specs,
                    lineHeight: size.height,
                    containerHeight: scrollView.frame.height)
            }
            // [实测] 段首吃 `paragraphSpacing = 39`（`isFirstLineOfParagraph`）。
            if index > 0, (line as? TextLine)?.isFirstLineOfParagraph == true {
                y += specs.paragraphSpacing
            }

            let alignment = LyricsLineGeometry.lineAlignment(
                agent: (line as? TextLine)?.agentAlignment ?? .normal,
                textAlignment: specs.lineTextAlignment)
            // 行框宽 = **测量宽**，不是墨迹宽。两条理由：
            //
            // - [PX] §22.3：「行左缘 = 面板左 + 19、行框宽 = 面板宽 − 38」，
            //   438–683 全宽度档恒定；[AX] `lyrics-panel.json` 侧栏那份也一样
            //   （面板 258、行 `[1231, …, 220, …]`，220 = 258 − 38）。
            //   两个 surface 各自独立量到「行框宽 = 可用宽」，是规律不是样本。
            // - **量与排是同一个宽度**才不会折两次。内容层排版走的是
            //   `bounds.width`；行框贴着墨迹的话，排版时会拿「最宽那一段的用宽」
            //   再折一次——而 `lineBreakStrategy` 里的`.pushOut` 是段落级的
            //   （为了不让末行只剩一个词，会把整段的断点推开），窄一点就可能
            //   多断出一行，测高按 n 行、渲染成 n+1 行，最后一行被行框裁掉。
            //   发音成块那条路（`rubyRows`）同理。
            let frameWidth: CGFloat
            let x: CGFloat
            switch alignment {
            case .center:
                // 居中那一支 [实测] 用的是 `(可用 − 实际) / 2`，与「行框贴墨迹」
                // 配套；`lineTextAlignment` 基线是 nil，这支默认走不到，
                // 原样留着（§2.6 的三路对齐，居中态 `[部分]`）。
                frameWidth = size.width
                x = margins.left + (available - size.width) / 2
            case .left, .flipped:
                frameWidth = LyricsDebugFlags.usesInkLineWidth ? size.width : measureWidth
                x = margins.left + LyricsLineGeometry.horizontalOffset(
                    availableWidth: available,
                    usedWidth: measureWidth,
                    coefficient: coefficient,
                    alignment: alignment)
            }
            // [实测] 间奏行的高度是条件值（§16.1）：`instrumentalBreakVisibleView`
            // 正指着这一行才是 40，否则 0——「上下展开」的开关就是这一句。
            let frame = CGRect(x: x, y: y,
                               width: frameWidth,
                               height: lineHeight(for: line, measured: size.height))
            frames.append(frame)
            previous = frame
        }
        lineFrames = frames
    }

    /// 三个滚动入口共用的测量闭包。
    var measure: (SyncedLyricsLineView, Int) -> CGRect {
        { [weak self] _, index in self?.lineFrames[safe: index] ?? .zero }
    }

    /// 宽度变了 / 换歌了：重算全部行的 frame 并落位，最后收口文档高度。
    func relayoutEverything() {
        recomputeLineFrames()
        guard let manager else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in manager.lineViews.enumerated() {
            view.frame = lineFrames[safe: index] ?? .zero
        }
        CATransaction.commit()
        collapseDocument(below: manager.lineViews.last)
        updateLineAlphasForViewportEdges()
    }

    // MARK: - 视口边缘遮罩与动态行透明度

    /// 原生 AppKit 视口垂直渐变遮罩：在 `scrollView` 上挂载垂直羽化 `CAGradientLayer`，
    /// 上下平滑移入移出；左右不加遮罩，由 `margins` 安全边距（safe area）保证不被裁切。
    func updateViewportMask() {
        guard let scrollView, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        let bounds = scrollView.bounds
        let maskBounds = CGRect(origin: .zero, size: bounds.size)

        let vMask: CAGradientLayer
        if let existing = scrollView.layer?.mask as? CAGradientLayer {
            vMask = existing
        } else {
            vMask = CAGradientLayer()
            vMask.colors = [
                NSColor.clear.cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor,
            ]
            vMask.startPoint = CGPoint(x: 0.5, y: 0)
            vMask.endPoint = CGPoint(x: 0.5, y: 1)
            scrollView.layer?.mask = vMask
        }

        let vFraction = MusicMetrics.NowPlaying.hostedContentVerticalFadeFraction
        vMask.locations = [
            0.0,
            NSNumber(value: Double(vFraction)),
            NSNumber(value: Double(1 - vFraction)),
            1.0,
        ]

        // 左右不加遮罩，由 safe area / margins 保证安全边距
        vMask.mask = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vMask.frame = maskBounds
        CATransaction.commit()
    }

    /// 逐行透明度：**行被视口上下边缘切掉多少，就淡多少**，只看几何。
    ///
    /// 一行完全在视口内就一律全亮——正在唱的那句在两种落点档里（侧栏的贴顶、
    /// 整窗播放器的 `.center`）都完整落在视口里，所以这里永远碰不到它。
    ///
    /// **不看选中态。** 选中发生在开唱前 `maxEndTimeOffset`（0.5 s）的准入，
    /// 拿它当亮度开关，下一句就会在还没唱的时候先亮起来；亮度是几何的事，
    /// 唱没唱是时间的事，两件事不能共用一个开关。
    ///
    /// **行的落点取呈现层，视口取模型值。** 两者口径不同是因为它们在动画里的
    /// 处境本来就不同：间奏展开那条路（`animateInstrumentalExpansion`）第一帧就把
    /// 全表 frame 与视口 origin 都写成终值，然后只给受影响的行挂一条**叠加偏移**，
    /// 把「看起来还在原处」在时间上退回 0——所以**行**在屏幕上还没动、模型值却已到位，
    /// 必须问呈现层；而**视口**是在关动作的事务里一次到位的（那条路刻意不让视口参与
    /// 插值，见 `+Instrumental.swift` 的理由二），模型值就是屏幕上的值。
    ///
    /// 漏了这条，间奏进出时边缘那几行的透明度会比位置早半秒跳到终点——
    /// 位置没动、亮度先动，就是实机上看到的那一下闪（收起时反向再闪一次）。
    /// 同一条规矩 `animateInstrumentalExpansion` 自己取 `before` 时就在用
    /// （「呈现层优先：上一轮弹簧可能还在跑」）。
    func updateLineAlphasForViewportEdges() {
        guard let scrollView, let manager, !manager.lineViews.isEmpty else { return }
        let viewport = scrollView.contentView.bounds
        guard viewport.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in manager.lineViews {
            // 收起态的间奏行高度为 0（§16.1），没有「被切掉多少」可言。
            guard !manager.hiddenLineViews.contains(view) else {
                setAlpha(0, on: view)
                continue
            }
            let height = view.frame.height
            let alpha = LyricsLineGeometry.edgeAlpha(lineMinY: presentedMinY(of: view),
                                                     lineHeight: height,
                                                     viewport: viewport)
            setAlpha(alpha, on: view)
        }
        CATransaction.commit()
    }

    /// 行盒上沿此刻**在屏幕上**的位置。
    ///
    /// 行视图是 layer-backed 的，位移动画（含间奏那条叠加偏移）挂在它自己的背衬层
    /// `position` 上，`bounds` 不参与——所以高度取模型值、中心取呈现层，两者拼出
    /// 上沿。呈现层拿不到（没有动画在跑、或还没上屏）就回落模型值，
    /// 与改这条之前的取值完全一致。
    private func presentedMinY(of view: SyncedLyricsLineView) -> CGFloat {
        guard let layer = view.layer, let presented = layer.presentation() else {
            return view.frame.minY
        }
        return presented.position.y - layer.bounds.height * layer.anchorPoint.y
    }

    /// 每帧全表写 `alphaValue` 等于每帧把整棵层树重新提交一遍；值没变就别写。
    private func setAlpha(_ alpha: CGFloat, on view: SyncedLyricsLineView) {
        guard abs(view.alphaValue - alpha) > 0.001 else { return }
        view.alphaValue = alpha
    }

    // MARK: - 每帧（§1.1）

    /// `CADisplayLink` → `-[… displayLinkFired]`（跳板）
    /// → 真身 → manager 每帧更新。
    func startDisplayLink() {
        guard displayLink == nil else { displayLink?.isPaused = false; return }
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc func displayLinkFired() {
        guard let visual = manager, let timeline = visual.manager else { return }
        // [PX] §22.3：暂停后全表清晰，恢复播放再糊回去。静态档的早退落在
        // `syncBlurToPlaybackState()` 自己开头（那一档压根不产生模糊，没有要清的、
        // 更不该回填），所以摆在下面那道闸前后都一样。
        visual.syncBlurToPlaybackState()
        guard specs.renderingMode != .static else { return }

        let basis = timeline.update()
        advanceScrollSpring()
        // 先点亮到点的行，再按点亮后的结果决定焦点位要不要往下一句挪。
        visual.activateDueLines(at: basis.elapsed)
        visual.followScrollTarget(at: basis.elapsed)
        updateLineAlphasForViewportEdges()

        // 逐字渐变每帧推进（原版的走查）。喂进去的时间是
        // §1.2 的前两步（扣掉空间音频偏移），**不含**第三步那个提前量。
        //
        // `animated: true` 说的是**抬升**那一条（`SBS_TextContentLayer.applyProgress`
        // 只把这个标志喂给`liftStartedSyllables`）：逐帧推进才是「这个字轮到了」
        // 的那一刻，那 2pt 该由 (1, 14, 7) 慢慢飘上去。假的话每个音节开唱时是
        // 2pt 瞬移，观感就是逐字弹跳。seek 由`isContinuousAdvance` 那道闸挡掉。
        for view in visual.selectedLineViews {
            view.lineLayer?.startProgress(at: basis.elapsed, animated: true)
        }
        // 间奏点阵的状态机也按帧推进（§3.3）。
        if let instrumental = visual.instrumentalBreakVisibleView,
           let dots = instrumental.lineLayer?.contentLayer as? InstrumentalContentLayer {
            dots.advance(to: basis.elapsed)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
