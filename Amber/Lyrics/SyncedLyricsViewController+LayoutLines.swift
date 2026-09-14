import AppKit

extension SyncedLyricsViewController {

    /// 重排全部行，并在锚点行真的移位时把它滚回目标位置。规格见 §5.2。
    ///
    /// [实测] `layoutLines: scrolling to`。
    ///
    /// 两条要点：
    /// - **判据是矩形全等（`CGRectEqualToRect`），不是 y 差**。
    ///   窗口宽度变了导致换行数变化、锚点行因此移位时才滚；只是末尾几行重排、
    ///   锚点没动就一动不动。
    /// - 滚的是**重新定位到 §2.5 的目标位置**，不是按位移量补偿。锚点行就是当前行时
    ///   两者等价，不是时不等价——原版选了前者。
    ///
    /// - Parameter anchor: 原版取入参数组的第 0 个；数组为空时 `before` 是`.zero`
    ///   （四个），于是几乎必然「动过」，也就必然滚一次。
    @discardableResult
    func layoutLines(anchor: SyncedLyricsLineView?,
                            measure: (SyncedLyricsLineView, Int) -> CGRect) -> CGPoint? {
        guard let manager else { return nil }
        let before = anchor?.frame ?? .zero
        let lastIndex = (lyrics?.lines.count ?? 0) - 1

        withoutImplicitAnimation {
            for (index, view) in manager.lineViews.enumerated() {
                view.frame = measure(view, index)
                if index == lastIndex { collapseDocument(below: view) }
            }
        }

        let after = anchor?.frame ?? .zero
        guard !after.equalTo(before) else { return nil }        //相等就返回

        let origin = scrollOrigin(forLineFrame: after)
        setScrollOrigin(origin)
        return origin
    }
}

extension SyncedLyricsViewController {

    /// `animate(line:` 的骨架。规格见 §5.3。
    ///
    /// [实测]。一个函数体里带两条日志（`Adjusting` 与
    /// `scrolling to`），`Adjusting` 那一段由入参枚举的 tag决定走不走。
    ///
    /// 最后一步是间奏的交接：**间奏视图不是自己消失的，是下一次 `animate(line:)`
    /// 顺手收掉的**，且先把 `instrumentalBreakVisibleView` 置 nil 再收——
    /// 收起动画跑的时候这个字段已经是空的，别指望在动画回调里还读得到它。
    ///
    /// 未接线：Amber 的翻行走 `+Selection.swift` 的`relayout(affected:…)`，间奏收起
    /// 由 `deselectLine` 那条路带走（`dismissesInstrumental`），没有调这里。
    /// 连带 `dismissInstrumental(_:measure:)` 也只有它一个调用方。
    func animate(shifting views: [SyncedLyricsLineView],
                        byDeltaY delta: CGFloat,
                        scrollingTo origin: CGPoint,
                        relayoutRange: Range<Int>,
                        measure: (SyncedLyricsLineView, Int) -> CGRect) {
        adjustLineViews(views, byDeltaY: delta)                 //，§2.3
        setScrollOrigin(origin)

        guard let manager else { return }
        withoutImplicitAnimation {
            for index in relayoutRange where index < manager.lineViews.count {
                let view = manager.lineViews[index]
                view.frame = measure(view, index)
            }
        }

        // 还挂着间奏视图就收起来，注意先清空字段再调。
        if let visible = manager.instrumentalBreakVisibleView {
            manager.instrumentalBreakVisibleView = nil
            dismissInstrumental(visible, measure: measure)
        }
    }

    /// 收起间奏视图。目标 origin 要扣掉间奏占的那一格，见 §3.5。
    private func dismissInstrumental(_ view: SyncedLyricsLineView,
                                     measure: (SyncedLyricsLineView, Int) -> CGRect) {
        guard let manager,
              let index = manager.lineViews.firstIndex(of: view) else { return }
        let origin = dismissInstrumentalOrigin(scrollOrigin(forLineFrame: view.frame))
        relayoutLines(from: index, scrollingTo: origin, measure: measure)
    }
}

extension SyncedLyricsViewController {

    /// `hidePreviousLines` 的唯一实现。规格见 §5.4 第 9 步。
    ///
    /// [实测] `jumping to` 读`specs + 0x2f2`（`0x31a − 0x28`）
    /// = `hidePreviousLines`，为真时对**下标小于目标行**的每一行
    /// `setAlphaValue(0)`。那处的`setAlphaValue(1.0)`
    /// 是它的反向操作。
    ///
    /// 不是 `isHidden`，是 alpha——所以布局位置不变，只是看不见。
    /// 基线 `hidePreviousLines = false`，默认看不到这个效果。
    func applyHidePreviousLines(targetLineIndex: Int) {
        guard specs.hidePreviousLines, let manager else { return }
        for (index, view) in manager.lineViews.enumerated() {
            view.alphaValue = index < targetLineIndex ? 0 : 1
        }
    }
}
