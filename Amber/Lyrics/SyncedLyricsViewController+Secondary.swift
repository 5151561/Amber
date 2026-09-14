import AppKit
import QuartzCore

// 翻译 / 发音两条副行的显隐。
//
// [实测] `LyricsSpecs` 字段 77`showTranslationTransliterationSpringParameters`
// = mass 1 / stiffness 150 / damping 30 —— 原版为「显隐副行」单独留了一条弹簧，
// 说明这件事在 Music 里**是带过渡的重排**，不是换一份数据重建。
//
// 所以这里也走重排：开关落在 `LyricsSpecs` 上（`showsTranslation` /
// `showsTransliteration`），内容层按开关重新测量 → 行高变 → 下面的行要往下挪，
// 挪的那一段用上面那条弹簧。行视图不拆不建，逐字进度、选中态、滚动位置全都保着。

extension SyncedLyricsViewController {

    /// 切换副行显隐。值没变直接返回。
    func setSecondaryLinesVisible(translation: Bool, transliteration: Bool) {
        guard specs.showsTranslation != translation
                || specs.showsTransliteration != transliteration
        else { return }

        specs.showsTranslation = translation
        specs.showsTransliteration = transliteration
        manager?.specs = specs

        guard let manager, !manager.lineViews.isEmpty else { return }

        // 旧位置先记下来：新值一步到位写进模型，动画只把「旧 − 新」退回 0
        // （§6.5 的非破坏性叠加，中途再切一次不会打架）。
        let oldCenters = manager.lineViews.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }

        // 把新 spec 推进每一行：内容层的 `sizeThatFits` 读的是它自己那份 specs，
        // 不推下去的话 `recomputeLineFrames` 量到的还是旧行高。
        //
        // 走的是 `applySecondaryLineVisibility` 而不是`updateAppearance`：后者会把
        // `layoutWidth` 清零，于是全表每一行的正文`CATextLayer` 都被拆掉重建、
        // `RubyLayout.blocks` 重跑一遍——而这里只是显隐两条副行。逐字档只在
        // 「发音成块」真的变了时才重排，其余情形摆一摆副行那三层就够。
        for view in manager.lineViews {
            view.lineLayer?.specs = specs
            view.lineLayer?.contentLayer?
                .applySecondaryLineVisibility(specs: specs,
                                              appearance: view.effectiveAppearance)
        }
        recomputeLineFrames()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, view) in manager.lineViews.enumerated() {
            view.frame = lineFrames[safe: index] ?? .zero
        }
        CATransaction.commit()

        let animator = LayerPropertyAnimator(
            curve: .spring(specs.showTranslationTransliterationSpringParameters))
        for (index, view) in manager.lineViews.enumerated() {
            guard let layer = view.layer, let oldCenter = oldCenters[safe: index] else { continue }
            // 只弹**位移**：行盒长高是往下长的，内容顶对齐，看得见的变化就是
            // 下面那些行整体下挪。副行文字本身是即时出现的——原版是不是还给它
            // 单独淡入没读出来，这里不臆造。
            let offset = CGPoint(x: oldCenter.x - view.frame.midX,
                                 y: oldCenter.y - view.frame.midY)
            animator.layers.append(layer)
            animator.addAdditiveAnimation(to: layer, keyPath: "position",
                                          offset: offset, frameRateRange: (min: 0, max: 0))
        }
        animator.finishDispatch {}

        collapseDocument(below: manager.lineViews.last)
        // 上面的行长高了会把当前行顶下去，重新落一次基线。
        reanchorSelectedLine()
    }
}
