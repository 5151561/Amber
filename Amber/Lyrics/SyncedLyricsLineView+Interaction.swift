import AppKit

extension SyncedLyricsLineView {

    /// 悬停进出。规格见 §4.1。
    ///
    /// [实测] `-[SyncedLyricsLineView mouseEntered:]` 与
    /// `mouseExited:` 是同一个函数的两个入口，都转给
    /// 进出两条共用一个入口 `(event, sel, isEntering)`，只差最后那个布尔。
    /// 它先 `objc_msgSendSuper2` 调父类，再过三道闸——任何一道拦下就**什么都不做**，
    /// 连「取消上一次悬停」都不做。
    ///
    /// 第二道闸的目标类型是实测的：类型信息
    /// → `SongwritersLine`。词曲作者那一行不吃悬停高亮。
    ///
    /// 第三道闸 `os_variant_has_internal_content("com.apple.Music")` 在发行版恒为 false，
    /// 复刻里没有对应物，这里不建模。
    func shouldApplyHover() -> Bool {
        guard let lineLayer else { return false }
        guard lineLayer.specs.renderingMode != .static else { return false }
        guard !(lineLayer.line is SongwritersLine) else { return false }
        return true
    }

    /// 悬停外观的实际下发口。参数见 `lyrics-logic.md`：
    /// 外扩 `highlightViewMargin`(16)、圆角`highlightViewCornerRadius`(16)、
    /// 文字压到 `highlightLabelAlpha`(0.85)。
    ///
    /// [实测] 最终落到聚焦切换，传 `(isEntering, false)`。
    func setHovered(_ hovered: Bool) {
        guard shouldApplyHover() else { return }
        lineLayer?.isHighlighted = hovered
        // [实测] 真正下发的是 `(isEntering, false)`，
        // 即**不带动画**地切聚焦外观——亮度 ±1、模糊归零（§9.4）。
        // `highlightView*` 那四个 spec 字段（8% 白底 / 圆角 16 / 外扩 16 / 标签 0.85）
        // 的消费者没有定位到，所以这里不画底板。
        lineLayer?.setLineFocused(hovered, animated: false)
        // 提亮是**不带动画**的，所以这条路必须这一刻就通——晚一帧就是「亮了一帧才亮」。
        syncCoreImageFilterUsage()
    }
}

extension SyncedLyricsViewController {

    /// 点击一行。规格见 §4.3。
    ///
    /// [实测] `-[SyncedLyricsViewController handleTap:]`**头四条指令是早退**：
    /// `renderingMode == .static` 直接`ret`，整块不可交互——和 §4.1 的第一道闸同一个判据。
    /// 往下是。
    ///
    /// 返回值是要冻结进度的那一行，交给调用方去逐音节冻结
    /// （`lineTapProgressFreezeDuration = 0.1` 秒后解冻，见`tapProgressFreezeDeadline`）。
    @discardableResult
    func handleTap(on lineView: SyncedLyricsLineView) -> SyncedLyricsLineView? {
        guard specs.renderingMode != .static else { return nil }

        manager?.needsTapHandling = true
        // 注意：点击**立刻**交还控制权，不走 §2.9 那 3 秒。等 3 秒的只有拖动。
        //
        // [实测] 作废计时器 + 置 nil、把
        // `allowAnimateToNextLineAfterScroll` 置 true。Amber 这边还得**连 mode 一起**
        // 交还——`mode = .regular` 在 Amber 是挂在那个计时器体里的，光把计时器掐掉
        // 就再没人把它拨回来了：「先滑动进清晰态、3 秒内点一行」之后歌词会一直
        // 停在 `.scroll` 的外观上往下走。两件事收在`returnControlToPlayback()` 里。
        manager?.returnControlToPlayback()

        manager?.lastTapDate = Date()
        timingProviderGate.lastTapDate = manager?.lastTapDate       // §1.4 判据 2

        // §7.6：把这一行的逐字进度钉住，等新时间源送到再放开。
        if let content = lineView.lineLayer?.contentLayer as? SBS_TextContentLayer {
            content.freezeProgress(for: specs.lineTapProgressFreezeDuration)
        }

        // 点击立刻触发平滑滚动到目标行，无需等待 seek 往返延迟
        if let line = lineView.lineLayer?.line {
            jump(to: line, animated: true)
        }

        notifyDelegateOfTap(on: lineView)
        return lineView
    }

    /// 逐字进度冻结多久。
    ///
    /// [实测] 把整包 880 字节的 `LyricsSpecs` `memcpy` 进闭包，
    /// 从副本读出 `lineTapProgressFreezeDuration`，
    /// 拿它当 `after:`。每个音节先置一个「冻结」标志（`syllable = 1`），
    /// 0.1 秒后解冻。
    ///
    /// 用途：点击瞬间把该行逐字进度钉住，等新时间源送到再放开，
    /// 免得进度先弹回旧位置再跳过去。
    var tapProgressFreezeDeadline: TimeInterval { specs.lineTapProgressFreezeDuration }

    /// 点了一行之后，等新时间源的宽限。
    ///
    /// [实测] `DispatchQueue.main.asyncAfter(deadline: .now() + 1.0)`，
    /// 闭包三条指令直接尾调 =
    /// `No new timing provider for 1 second, resetting to old one`。
    ///
    /// 这条把 §1.4 的表格补完了：那个「1 秒超时回退」的调度点就在这里。
    /// 含义是——点了一行之后给宿主 1 秒钟送新时间源，逾期未到就退回旧的，
    /// 不让歌词僵在那儿。
    static let newTimingProviderGrace: TimeInterval = 1.0

    /// 歌词面板**自己不 seek**。
    ///
    /// [实测]只做一件事：把行取出来交给
    /// `SyncedLyricsViewController.delegate`，由宿主决定怎么跳。
    func notifyDelegateOfTap(on lineView: SyncedLyricsLineView) {
        (delegate as? any SyncedLyricsViewControllerDelegate)?
            .syncedLyricsViewController(self, didTap: lineView.lineLayer?.line)
    }
}

@MainActor
protocol SyncedLyricsViewControllerDelegate: AnyObject {
    func syncedLyricsViewController(_ controller: SyncedLyricsViewController,
                                    didTap line: (any LyricsLine)?)
}
