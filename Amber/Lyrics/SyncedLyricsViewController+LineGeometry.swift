import AppKit

// 批次 16 / 17：间奏「上下展开」的本体。规格见
// lyrics 规格 §16.1–16.6 与 §17.1–17.3。
//
// 一句话：**展开不是三个点的动画，也不是整体平移**。间奏行一直躺在行流里，
// 高度是条件值（收起 0 / 打开 40）；打开那一刻它自己占 40、又给后面补上 25 的
// 行距，于是它之后的每一行整体下移 65，这一格就是「撑开」。
// （§13.3 里的「展开动效」说的是三个点自己的呼吸缩放，两回事。）

extension SyncedLyricsViewController {

    /// 一行的高度。**间奏行是条件值**——这条是整个「上下展开」的开关。规格见 §16.1。
    ///
    /// [实测] 行几何按这个顺序决定：
    ///
    /// ```
    /// 不是间奏行                              ⇒ 用 sizeThatFits
    /// 先无条件清零                            ★ 后面每一步都只是「停在 0」
    /// renderingMode == .static                ⇒ 停在 0
    /// instrumentalBreakVisibleView == nil     ⇒ 停在 0
    /// 那个视图的行下标 != 本行下标             ⇒ 停在 0
    /// 都不命中                                ⇒ 取 specs 里的 40
    /// ```
    ///
    /// 判据是 **`manager.instrumentalBreakVisibleView` 指着谁**，不是内容层自己的
    /// `isSelected`——同一时刻至多一行能撑开这条不变量由此而来。
    func lineHeight(for line: (any LyricsLine)?, measured: CGFloat) -> CGFloat {
        guard line is InstrumentalLine else { return measured }
        guard specs.renderingMode != .static,
              let open = manager?.instrumentalBreakVisibleView,
              open.lineLayer?.line?.index == line?.index
        else { return 0 }
        return specs.instrumentalBreakViewHeight
    }

    /// `hidePreviousLines` 打开时，间奏行**之上**的行淡成全透明并收进`hiddenLineViews`。
    ///
    /// [实测] 逐行位移闭包尾部：
    /// `specs.hidePreviousLines` 为真且`myIndex < targetIndex` 时
    /// `setAlphaValue(0)`+ `hiddenLineViews.append`。
    /// 与 §5.4 第 9 步 `jumping to` 里那处是两个独立的取值点。
    ///
    /// 基线 `hidePreviousLines = false`，默认看不到这个效果。
    /// 反向恢复由谁做没读出来（§17.6），照原版只做单向。
    func hideLines(above index: Int, among views: [SyncedLyricsLineView]) {
        guard specs.hidePreviousLines, let manager else { return }
        for view in views where (view.lineLayer?.line?.index ?? .max) < index {
            view.alphaValue = 0
            manager.hiddenLineViews.insert(view)
        }
    }
}

// MARK: - 受影响的行（§16.4 / §17.1）

extension SyncedLyricsViewController {

    /// 这次动画要动的行：「滚动前后**任一时刻**露在视口里的那一段连续行」。规格见 §16.4。
    ///
    /// [实测] 调用点，本体：
    ///
    /// ```
    /// rect2 = CGRectOffset(可视矩形, dy: delta)
    /// union = CGRectUnion(可视矩形, rect2)
    /// 一、从目标行下标向前（递减到 0），首次不相交即停
    /// 二、从目标行下标 + 1 向后（递增到末行），同样即停
    /// 三、按行下标升序排序后返回
    /// ```
    ///
    /// 三条都不能省：
    /// - 对**全部行**做动画 → 屏幕外几百行白白参与；
    /// - 只取**当前可见行** → 从下方进场的那几行缺一段位移，进场时跳一下；
    /// - 不排序 → §17.1 的逐行错开就不是「从上往下」推进的了。
    func affectedLineViews(aroundLineAt index: Int,
                           deltaY delta: CGFloat) -> [SyncedLyricsLineView] {
        guard let scrollView, let manager,
              manager.lineViews.indices.contains(index) else { return [] }
        let visible = scrollView.documentVisibleRect
        let union = visible.union(visible.offsetBy(dx: 0, dy: delta))

        var picked: [(index: Int, view: SyncedLyricsLineView)] = []
        var cursor = index                                             // 一、向前，含目标行
        while cursor >= 0 {
            let view = manager.lineViews[cursor]
            guard Self.intersectsAffectedUnion(union, view.frame) else { break }
            picked.append((cursor, view))
            cursor -= 1
        }
        cursor = index + 1                                             // 二、向后
        while cursor < manager.lineViews.count {
            let view = manager.lineViews[cursor]
            guard Self.intersectsAffectedUnion(union, view.frame) else { break }
            picked.append((cursor, view))
            cursor += 1
        }
        return picked.sorted { $0.index < $1.index }.map(\.view)       // 三、升序
    }

    /// 并集判交。
    ///
    /// `CGRectIntersectsRect` 对**空矩形恒为 false**，而收起态的间奏行正是 0 高——
    /// 照抄的话遍历会在间奏行上立刻停住，它自己和它上面的行一条都进不了动画集合，
    /// 上半边就不会让位。0 高的行改判「落点是否在并集的纵向区间内」。`[补]`
    private static func intersectsAffectedUnion(_ union: CGRect, _ frame: CGRect) -> Bool {
        guard frame.height <= 0 else { return union.intersects(frame) }
        return frame.minY >= union.minY && frame.minY <= union.maxY
    }
}

// MARK: - delta（§16.5）

extension SyncedLyricsViewController {

    /// 间奏行打开这一次，视口要走的位移量。规格见 §16.5。
    ///
    /// [实测] 主项：`delta = 目标 origin.y − contentView.bounds.origin.y`。
    /// 修正项，**两道闸都过才加**：
    ///
    /// ```
    /// 闸一 fcmp d8, d0 / b.ne     新行高 == 旧行高 ⇒ 不修正
    /// 闸二 cmn w8, #0x41 / b.gt   selectedLinePosition 的 tag > −65 ⇒ 不修正
    /// delta += (新行高 − 旧行高) × 0.5
    /// ```
    ///
    /// 三条易错：
    /// - 修正项两个操作数**都是行高**（新高 − 旧高），不是「可视高 − 行高」；
    /// - **`delta` 不含间奏行那 40**：算它的时候间奏行还关着（先置空），
    ///   那 40 是随后 `selecting line` 打开、由重排补上的；
    /// - 闸二等价于 `selectedLinePosition == .center`（§17.3 把 tag 编码逐位读死了），
    ///   基线版式是贴顶的 `.topRelative`，**默认配置下这条修正项从不生效**——
    ///   它是给居中版式准备的：贴顶只看 `minY`，行高变不变都不影响目标位置。
    ///
    /// 死区照旧：`abs(delta) < 1` 就归零，否则间奏进出时会抖。
    ///
    /// - Important: **修正项实测不成立，这里不加。** [PX] 2026-09-04 逐帧量 Music
    ///   整窗的一段间奏（录屏 2204×1434）：间奏行上方的行上移 160px、下方的行下移
    ///   20px、两行之间撑开 183px、正常行距 216px。拿这四个数去反解，只有
    ///   「**居中版式 + 收起态间奏行照吃前置行距 + 不加高度修正**」这一组能自洽，
    ///   且反解出的缩放是 **1.975 px/pt** —— 正好是 1:1 的 Retina 窗口录制；
    ///   代回去得行距 48、间奏行高 42、撑开量 90pt、上一句行盒 56.5pt、
    ///   `delta = 56.5/2 + 48 = 76.5pt`（实测 80pt），下方`90 − 76.5 = +13.5pt`。
    ///   加上那条 `+20` 则**无解**（delta 会超过撑开量，下方的行改为跟着上移）。
    ///
    ///   §16.5 把它记成「`(新行高 − 旧行高) × 0.5`，闸二是`.center`」，
    ///   §17.3 又推出「基线贴顶所以从不生效」。整窗恰恰是居中版式（`.center(rect:)`），
    ///   照抄就会命中——而实测说不该命中。判断是那两道闸的归属读错了（可能修正项
    ///   属于另一条路径），已记在这里，等回头拿二进制复核。
    func instrumentalOpenDelta(for view: SyncedLyricsLineView) -> CGFloat {
        guard let clip = scrollView?.contentView else { return 0 }
        // 走 `targetOrigin(for:)`：它对打开着的间奏行按收起态算，两处口径永远一致。
        let delta = targetOrigin(for: view).y - clip.bounds.origin.y
        return abs(delta) < Self.scrollDeadZone ? 0 : delta
    }
}

// MARK: - 逐行错开（§17.1 / §3.5）

/// 一批行动画的起跑错开方式。原版有两条互不相同的公式，别混用。
enum LineStagger: Equatable {

    /// 整批同时起步。
    case none

    /// [实测] `dismissInstrumentalView`：`Double(第几条被动画的行) × lineDelay`，
    /// **线性累加**。收起间奏走这条。
    case linear(TimeInterval)

    /// [实测] duration hack：
    /// `lineDelay × (max(i, 1) − 1)`，`i` 是这一行在**受影响的行（下标升序）**里的位置。
    /// 注意 `max(i,1) − 1`：**前两行共享 delay 0**，从第三行起才拉开（§17.1）。
    case sharedFirstPair(TimeInterval)

    /// - Parameters:
    ///   - movedOrdinal: 在**真的要动的行**里的序号（`.linear` 用）。
    ///   - affectedOrdinal: 在**受影响的行**（含没动的）里的序号（`.sharedFirstPair` 用）。
    func delay(movedOrdinal: Int, affectedOrdinal: Int) -> TimeInterval {
        switch self {
        case .none:
            return 0
        case .linear(let unit):
            return Double(movedOrdinal) * unit
        case .sharedFirstPair(let unit):
            return unit * Double(max(affectedOrdinal, 1) - 1)
        }
    }

    var isStaggered: Bool { self != .none }
}
