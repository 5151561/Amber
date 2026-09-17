import AppKit

extension SyncedLyricsViewController {

    /// 定位到某一行时，是瞬时换选中态还是滚动动画过去。
    ///
    /// 未接线：Amber 走的是 `SyncedLyricsVisualExperienceManager.select(_:)` 里那句
    /// `visible.contains(view.frame)` 现场判，没有经过这个枚举。
    /// 判据本身仍是实测的，留着当对照。
    enum LineTransition: Sendable, Equatable {
        /// 目标行已经完整可见——不滚动，直接换选中态。
        case selectInPlace
        /// 目标行没有完整露出来——滚动动画过去。
        /// 原版日志：`line is not completely visible on screen, animating to it instead.`
        case animateTo
    }

    /// [实测] `selecting`：
    ///
    /// ```
    /// documentVisibleRect → v0-v3
    /// lineView.frame      → v4-v7
    /// CGRectContainsRect
    /// cbz w0, → animating to it instead
    /// ```
    ///
    /// 判据是**整行 frame 是否被可视矩形完整装下**，不是按距离或行数。
    /// 差一个像素露在外面就降级成动画。注意用的是文档坐标下的 `frame`，
    /// 且行高含行距——所以「差一点点」比直觉中更常发生。
    ///
    /// 未接线：判据在 `select(_:)` 里就地写了一遍，没有调这里。
    func transition(forTargetLineFrame lineFrame: CGRect) -> LineTransition {
        guard let visible = scrollView?.documentVisibleRect else { return .animateTo }
        return visible.contains(lineFrame) ? .selectInPlace : .animateTo
    }

    /// 把滚动位置设到指定 origin。
    ///
    /// [实测] `animate(line:` 起的每帧闭包：读`contentView.bounds`、
    /// **只替换 origin、保留 size**、写回。原版不用 `scroll(to:)` 也不用
    /// `scrollToVisible:`——那些会让 AppKit 接管曲线，和原版对不上。
    func setScrollOrigin(_ origin: CGPoint) {
        guard let clip = scrollView?.contentView else { return }
        lyricsDebugLog("setScrollOrigin: from=\(clip.bounds.origin.y) to=\(origin.y)")
        var b = clip.bounds
        b.origin = origin
        clip.bounds = b
        // 歌词是逐帧改 `bounds.origin` 滚的，AppKit 不会为此补发`mouseExited:`——
        // 指针底下的行被滚走时会永远停在悬停外观（偏亮、不模糊），和旁边的行对不上。
        syncHoverState()
    }

    /// 按指针的**实际位置**裁决哪一行该处于悬停外观。
    ///
    /// 跟踪区只负责通知「有事发生」，谁该亮由这里算——这样滚动、换歌、
    /// 窗口失活导致的漏事件都不会留下卡住的高亮行。
    func syncHoverState() {
        let target = hoverTarget()
        guard target !== hoveredLineView else { return }
        hoveredLineView?.setHovered(false)
        hoveredLineView = target
        target?.setHovered(true)
    }

    /// 清掉悬停外观（换歌 / 重排前用）。
    func clearHoverState() {
        hoveredLineView?.setHovered(false)
        hoveredLineView = nil
    }

    private func hoverTarget() -> SyncedLyricsLineView? {
        guard let scrollView, let document = documentView,
              let window = document.amberWindow, window.isKeyWindow,
              !isDragging
        else { return nil }
        let point = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // 先按视口粗筛：指针不在歌词区里就没有目标，省掉逐行遍历。
        guard scrollView.documentVisibleRect.contains(point) else { return nil }
        guard let lineViews = manager?.lineViews, !lineViews.isEmpty else { return nil }

        // 行是按下标纵向堆叠的（§2.6：每行的 y 从上一行的 maxY 现算），所以
        // `frame.minY` / `maxY` 沿下标单调不减——二分找到第一条`maxY > point.y`
        // 的行即可，它前面的行 `maxY <= point.y`，一条都不可能命中。
        // 这条路挂在 `setScrollOrigin` 上，**每帧**都走一遍，全表线性扫太亏。
        var low = 0
        var high = lineViews.count
        while low < high {
            let mid = (low + high) / 2
            if lineViews[mid].frame.maxY > point.y { high = mid } else { low = mid + 1 }
        }
        // 往后扫一小段：高度为 0 的行（收起态的间奏）与同一条 y 上的行都在这一段里，
        // 而行宽只有文字那么宽，命中还要过 x。取第一条真正装下指针的，与原来的
        // `first { $0.frame.contains(point) }` 完全同解。
        var index = low
        while index < lineViews.count, lineViews[index].frame.minY <= point.y {
            if lineViews[index].frame.contains(point) { return lineViews[index] }
            index += 1
        }
        return nil
    }

    /// 启动滚动动画前，先把受影响的行整体沿 y 平移一个增量。
    ///
    /// [实测] `animate(line:`：逐个`frame` →
    /// `fadd d1, d8, d1` → `setFrame:`，`d8` 是首个 Double 入参。
    /// 原版把「整体平移」和「滚动动画」当两件事分开做。
    func adjustLineViews(_ views: [SyncedLyricsLineView], byDeltaY delta: CGFloat) {
        // 这是**动画开始前**的整体平移，本身不该有过渡——原版也把它和滚动动画
        // 当两件事分开做。不关隐式动画的话它自己先走 0.25s，和随后下发的弹簧打架。
        withoutImplicitAnimation {
            for v in views {
                var f = v.frame
                f.origin.y += delta
                v.frame = f
            }
        }
    }

    // 批次 5：animate(line:) / layoutLines / hidePreviousLines
    //   见 SyncedLyricsViewController+LayoutLines.swift
    // 批次 6：的分支（needsTapHandling / duration hack）见 Spring.swift，
    //   动画下发见 LayerPropertyAnimator.swift，
    //   animating to 的四条闸见 +AnimatingTo.swift。
}

/// 行几何。规格见 §2.6。
enum LyricsLineGeometry {

    /// 一行的纵向落点：**从上一行的 `maxY` 现算**，不是行高累加器。规格见 §16.2。
    ///
    /// [实测]：
    ///
    /// ```
    /// index == 0 ⇒ y = specs.firstLineStartingPosition（= 60）
    /// y = prevRect.maxY
    /// if prevRect.height > 0 { y += specs.lineSpacing }（= 25）
    /// ```
    ///
    /// **高度为 0 的行不产生行距**——这条和 §16.1 的条件行高是一对：收起态的间奏行
    /// 既不占高度也不占行距，在行流里彻底隐形；打开后它自己占 40、再补 25 的行距，
    /// 于是它后面每一行整体下移 65。漏了这条，收起状态会多出 25 的空隙。
    /// 判据是**上一行的高度**，与它是不是间奏行无关。
    static func originY(after previous: CGRect?,
                        firstLineStartingPosition: CGFloat,
                        lineSpacing: CGFloat) -> CGFloat {
        guard let previous else { return firstLineStartingPosition }
        return previous.maxY + (previous.height > 0 ? lineSpacing : 0)
    }

    /// 一行被视口上下边缘切掉之后还剩多少（0…1），逐行透明度就取它。
    ///
    /// 纯几何，不看选中态也不看时间轴（理由见
    /// `SyncedLyricsViewController.updateLineAlphasForViewportEdges`）。
    /// 0 高的行（收起态的间奏行，§16.1）没有「被切掉多少」可言，直接 0。
    ///
    /// - Parameter lineMinY: 行盒上沿在**文档坐标**里的位置。调用方要传
    ///   **呈现层**算出来的那个值，不是模型 frame —— 间奏展开那条路
    ///   （`animateInstrumentalExpansion`）会在第一帧就把全表 frame 写成终值、
    ///   再用叠加动画把「看起来还在原处」退回去；拿模型值算，亮度就会比位置
    ///   早半秒到位，间奏进出时看到的那一下闪就是它。
    static func edgeAlpha(lineMinY: CGFloat, lineHeight: CGFloat, viewport: CGRect) -> CGFloat {
        guard lineHeight > 0 else { return 0 }
        let visible = min(lineMinY + lineHeight, viewport.maxY) - max(lineMinY, viewport.minY)
        return min(max(visible / lineHeight, 0), 1)
    }

    /// 首行的纵向落点。规格见 §16.2。
    ///
    /// [实测]：
    /// - 贴顶版式（`specs.selectedLinePosition.tag >= 0`，即 `.top` / `.topRelative`）：
    ///   落到 `specs.firstLineStartingPosition`（= 60）；
    /// - 居中版式（`tag < 0`，即 `.center`）：落到让首行在滚动 origin 为 0 时正好居中于载荷矩形的高度，
    ///   即 `|sub_10109a09c(0, 目标行几何).y| = (rect.height − line0.height)/2 + rect.minY`。
    ///   [PX] §22.3 实测「首组为焦点时组框中心仍在锚位（上方留白 276）」正是这个初值。
    static func firstLineY(specs: LyricsSpecs,
                           lineHeight: CGFloat,
                           containerHeight: CGFloat) -> CGFloat {
        // 静态档（整份无戳纯文本）没有「当前行」，`selectedLinePosition` 那套锚点
        // 无从谈起：整份词从顶部内边距起铺。`staticTopContentInset`(=22) 的唯一
        // 使用方就是这里——两处宿主都传 `.center(rect:)`，不分这一档的话整窗下
        // 首行上方会凭空空出三百多 pt。底部留白另有出口（见 +Instrumental 的
        // `staticBottomContentInset`）。
        guard specs.renderingMode != .static else { return specs.staticTopContentInset }

        switch specs.selectedLinePosition {
        case .top, .topRelative:
            return specs.firstLineStartingPosition
        case .center(let rect):
            if let rect {
                return max(specs.firstLineStartingPosition, rect.minY + (rect.height - lineHeight) / 2)
            } else {
                return max(specs.firstLineStartingPosition, (containerHeight - lineHeight) / 2)
            }
        }
    }

    /// 一行排版时实际可用的宽度。
    ///
    /// [实测]：取 `documentView.frame` 宽度减去左右边距；
    /// 非正值直接跳过整段布局。
    static func availableWidth(documentWidth: CGFloat,
                                      margins: NSEdgeInsets) -> CGFloat {
        documentWidth - margins.left - margins.right
    }

    /// 一行的水平落点档位。三路，基点都是 `margins.left`。
    enum LineAlignment {
        /// 默认。普通行**贴左**，不是居中。
        case left
        case center
        /// 对唱翻转侧：收窄到 85% 再右推 15%。
        case flipped
    }

    /// 分组判据：对唱翻转侧、或带和声，都按分组行收窄。`[推]`
    static func isVocalGroup(_ line: (any LyricsLine)?) -> Bool {
        guard let text = line as? TextLine else { return false }
        return text.agentAlignment == .flipped || text.backgroundVocals != nil
    }

    /// 排版宽度系数。
    ///
    /// [实测] → specs
    /// = `vocalGroupWidthCoefficient`；普通行走的。
    ///
    /// 注意这是**排版宽度**的系数，不是缩放变换——和声 / 对唱分组的行按可用宽度的
    /// 85% 去折行测高，普通行用满宽。
    static func widthCoefficient(isVocalGroup: Bool, specs: LyricsSpecs) -> CGFloat {
        isVocalGroup ? specs.vocalGroupWidthCoefficient : 1.0
    }

    /// 行的对齐档。
    ///
    /// [实测] 把居中与右推两个偏移都无条件算好备用，
    /// **选择器没解出来**。这里按参照物取：翻转侧右推，其余行看
    /// `lineTextAlignment`——显式居中才居中，nil（natural）与 leading 一律贴左。
    /// [PX] Music 整窗歌词各行左边缘完全对齐，按「普通行也居中」实现的话短句会飘。`[推]`
    static func lineAlignment(agent: Lyrics.AgentAlignment,
                              textAlignment: NSTextAlignment?) -> LineAlignment {
        if agent == .flipped { return .flipped }
        return textAlignment == .center ? .center : .left
    }

    /// 水平落点。
    ///
    /// [实测]：居中用 `(可用 − 实际) / 2`；
    /// `.flipped` 一侧用`可用 × (1 − 系数)` = 0.15 × 可用。
    ///
    /// 所以对唱不是两栏等分，而是**收窄到 85% + 右移 15%**。
    static func horizontalOffset(availableWidth: CGFloat,
                                        usedWidth: CGFloat,
                                        coefficient: CGFloat,
                                        alignment: LineAlignment) -> CGFloat {
        switch alignment {
        case .left:    return 0
        case .center:  return (availableWidth - usedWidth) / 2
        case .flipped: return availableWidth * (1 - coefficient)
        }
    }
}

extension SyncedLyricsViewController {

    /// 算出要写进 `contentView.bounds` 的滚动 origin。
    ///
    /// 规格见 §2.5。
    /// 分派看 `selectedLinePosition` 的 tag 字节（`_specs + 0x38`）。
    /// `x` 分量恒为 0——横向滚动位置从不参与。
    /// 分派实测（§17.3 补完 §2.5）：specs 里那个字节是枚举 tag，
    /// **`w8 >= 0` 走贴顶**（`top` / `topRelative` 两个 case 行为完全一样，载荷都不读），
    /// `w8 < 0` 才是居中，此时`k = w8 & 0x3f` 是`Optional<CGRect>` 的 tag。
    func scrollOrigin(forLineFrame lineFrame: CGRect) -> CGPoint {
        switch specs.selectedLinePosition {

        // A 路 [实测]：载荷不参与，偏移量走独立的 topInset，且夹零。
        // 夹零不能省，否则第一行会把内容拉出上边界。
        // `topRelative`（基线那一档）与`top` 同路——它的载荷在这个函数里从没被读过。
        case .top, .topRelative:
            return CGPoint(x: 0, y: max(0, lineFrame.minY - topInset))

        // B 路 [实测]：在参照矩形里垂直居中。
        // `rect == nil`（k == 1）这一支用`scrollView.frame`，
        // 且**不减 minY**；有载荷那一支要减掉参照矩形自身的 minY。
        case .center(let rect):
            guard let rect else {
                let container = scrollView?.frame ?? .zero
                let half = (container.height - lineFrame.height) / 2
                return CGPoint(x: 0, y: lineFrame.minY - half)
            }
            // 减的是「行 minY 与容器 minY 之差」，不是中心差——只在行高等于容器高时等价。
            let half = (rect.height - lineFrame.height) / 2
            return CGPoint(x: 0, y: lineFrame.minY - half - rect.minY)
        }
    }
}

extension SyncedLyricsViewController {

    /// `jump` 是否要降级成动画滚动。
    ///
    /// 复现 `jumping to` 的三重判据。
    /// 规格见 §2.7。
    ///
    /// **注意判据方向与 `transition(forTargetLineFrame:)` 相反**：
    /// - `selecting` 用`CGRectContainsRect`——没被完整装下就动画。
    /// - `jump` 用`CGRectIntersectsRect`——有交集才动画，**完全不可见反而硬跳**。
    ///
    /// 目标行在附近时动画有连续感；远在几屏之外时动画会变成一次疯狂的长距离滚动。
    /// 两处若写成同一个判据，长距离跳转（点进度条跳到副歌）会拖出一段甩尾。
    ///
    /// - Parameters:
    ///   - targetLine: 原版在这里判型，目标类型是 `InstrumentalLine`。
    ///     转型**成功**则硬跳：间奏行没有文字，动画滚过去看不出所以然。见 §4.2。
    ///   - animated: 原版读的 `[x19, #0x5c]` 布尔，位置上像调用方传入的开关。[推]
    func jumpShouldAnimate(targetLineFrame: CGRect,
                                  targetLine: (any LyricsLine)?,
                                  animated: Bool) -> Bool {
        guard let visible = scrollView?.documentVisibleRect else { return false }
        guard visible.intersects(targetLineFrame) else { return false }  // 不相交 → 硬跳
        guard !(targetLine is InstrumentalLine) else { return false }
        return animated
    }

    /// tracking 模式下的跳转。规格见 §4.4。
    ///
    /// [实测] `jumpTo: tracking mode, scrolling to`。
    /// **不过任何判据，直接换 origin**——用户手还在内容上，任何动画都是在跟他抢。
    /// 重排范围是**全表**（起的循环从 0 开始），
    /// 不像 §3.5 的间奏入口那样从锚点行往后：tracking 下不知道用户把哪一段拖进了视野。
    ///
    /// 未接线：Amber 的 `.tracking` 只作为模式存在，没有走这条入口的调用点。
    func jumpInTrackingMode(to origin: CGPoint,
                                   measure: (SyncedLyricsLineView, Int) -> CGRect) {
        setScrollOrigin(origin)
        guard let manager else { return }
        let lastIndex = (lyrics?.lines.count ?? 0) - 1
        for (index, view) in manager.lineViews.enumerated() {
            view.frame = measure(view, index)
            if index == lastIndex { collapseDocument(below: view) }
        }
    }
}

extension SyncedLyricsViewController {

    /// `jumping to`。规格见 §5.4。
    ///
    /// 与自动翻行那条路（`animating to`，§6.4）的关键差别：
    /// - 判据用 `CGRectIntersectsRect`——**目标行完全不可见时硬跳**，不甩一段长滚动；
    /// - 间奏行一律硬跳（§4.2）：没有文字，动画滚过去看不出所以然；
    /// - 先撤掉在跑的滚动，再落位，免得两条曲线打架。
    func jump(to line: any LyricsLine, animated: Bool) {
        guard let manager, let view = manager.lineViews[safe: line.index] else { return }
        cancelScrollSpring()

        // 跳到间奏行时把点阵重建到该时刻（§5.4 第 7b 步）——拖到间奏中段，
        // 点不会从第一个重新亮起。这一步**必须排在重排之前**：它同时把
        // `instrumentalBreakVisibleView` 指向目标行，而那正是行高的闸（§16.1），
        // 排在后面的话这一帧量到的还是 0 高，跳进间奏时不展开。
        if line is InstrumentalLine {
            handOffInstrumental(to: view,
                                elapsed: manager.manager?.elapsedTimeProvider() ?? 0,
                                advancesStateMachine: true)
        }

        // seek / 换歌的整体重排不会经过常规 `select(_:)`。先按最新选中态落一次
        // 几何，保证跳进间奏时它已经展开、跳离间奏时旧占位已经收起。
        recomputeLineFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, lineView) in manager.lineViews.enumerated() {
            lineView.frame = lineFrames[safe: index] ?? .zero
        }
        CATransaction.commit()
        collapseDocument(below: manager.lineViews.last)

        let origin = targetOrigin(for: view)          // 间奏行按收起态算锚点，见 targetOrigin
        if jumpShouldAnimate(targetLineFrame: view.frame, targetLine: line, animated: animated) {
            animateLineScroll(to: origin,
                              anchorLine: line,
                              spring: specs.lineChangeSpringTimingParameters,
                              baseOffset: 0)
        } else {
            setScrollOrigin(origin)
        }

        // §5.4 第 9 步：`hidePreviousLines` 为真时，目标行之前的行 alpha 归零。
        applyHidePreviousLines(targetLineIndex: line.index)
    }
}

extension SyncedLyricsViewController {

    /// 基线（`selectedLinePosition`）变了之后，把当前选中行重新滑到新落点。
    ///
    /// 走的是既有的 `jump(to:animated:)`：目标行与视口相交才动画、完全不可见就硬跳
    /// （§2.7）。没有选中行（还没起播 / 歌词为空）时什么都不做，
    /// 下一次 `didSelect` 自然会用新的 spec 落位。
    func reanchorSelectedLine() {
        guard let visual = manager,
              let view = visual.selectedLineViews.last,
              let index = visual.lineViews.firstIndex(of: view),
              let line = lyrics?.lines[safe: index]
        else { return }
        jump(to: line, animated: true)
    }
}
