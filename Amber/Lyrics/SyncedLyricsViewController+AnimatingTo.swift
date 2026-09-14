import AppKit

extension SyncedLyricsViewController {

    /// `animating to` 的决策部分。规格见 §6.4。
    ///
    /// [实测]。`animate(line:` 与`jump` 的降级支都汇到它，
    /// 但它并不总是滚——先算一个 `offScreen`，再过四条闸。
    enum AnimateToDecision: Sendable, Equatable {
        /// 四条闸全过：走 §2.5 的目标位置 + §6.1 的弹簧选择滚过去。
        case scroll
        /// 有闸没过：**只换选中态外观，滚动位置一动不动**。
        ///
        /// 注意不是「整个 return」——原版在那支照样
        /// 造描述符、`selecting line(…, true, true)` 换外观。
        /// 写成 return 的话，用户拖开歌词后当前行高亮会停在旧行上。
        case selectOnly
    }

    /// 视口是否已经跟播放完全脱节。
    ///
    /// [实测] 两次 `CGRectIntersectsRect` 算的是同一个量：
    /// - 目标行 frame ∩ `documentVisibleRect`，相交就直接判 false；
    /// - 不相交才遍历 `manager.selectedLineViews`，
    ///   只要有一个相交就 false，全不相交（含集合为空）才 true。
    func isOffScreen(targetLineFrame: CGRect) -> Bool {
        guard let visible = scrollView?.documentVisibleRect else { return true }
        if visible.intersects(targetLineFrame) { return false }
        guard let manager, !manager.selectedLineViews.isEmpty else { return true }
        return !manager.selectedLineViews.contains { visible.intersects($0.frame) }
    }

    /// 四条闸。[实测]。
    ///
    /// 第 2 条最反直觉：**视口跟播放完全脱节时反而什么都不滚**。
    /// 和 §2.7 的「`jump` 完全不可见反而硬跳」是同一种取舍的两个面——
    /// 用户已经翻到别处了就别抢镜头，等他回来或等 §2.9 那 3 秒计时器交还控制权。
    ///
    /// 第 3 条的屏蔽（`bic w9, w9, w8`）也讲得通：手指还在滚轮上本来不该抢，
    /// 但用户**点了一行**且 `snapScrollToLines` 为真时必须滚，否则点击没有反馈。
    func animateToDecision(targetLineFrame: CGRect) -> AnimateToDecision {
        guard let manager else { return .selectOnly }

        // w8：点击驱动时才让 snapScrollToLines 参与，否则恒 0。
        let snapMask = manager.needsTapHandling && specs.snapScrollToLines

        guard manager.mode != .tracking else { return .selectOnly }
        guard !isOffScreen(targetLineFrame: targetLineFrame) else { return .selectOnly }
        guard !(isDragging && !snapMask) else { return .selectOnly }
        guard manager.allowAnimateToNextLineAfterScroll else { return .selectOnly }
        return .scroll
    }
}
