import AppKit

// `SyncedLyricsLineView` 的视图本体。原版是`NSControl` 子类
// （源文件 `SyncedLyricsLineView_AppKit.swift`），悬停、按下、点击都挂在这里，
// 真正的外观下发全在 `lineLayer` 上。

extension SyncedLyricsLineView {

    /// 装配一行。行与视图按下标一一对应，所以这里只认 `line` 不认下标。
    func configure(line: any LyricsLine, specs: LyricsSpecs) {
        // 行图层挂成**背衬层的子层**，不是直接当 `layer`：视图是 flipped 的，
        // AppKit 只会给自己管的背衬层置 `isGeometryFlipped`；换成 layer-hosting
        // 就得自己翻，容易把整行画倒。
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 行图层比视图大一圈（滤镜溢出），两处都不能裁：`NSView.clipsToBounds`
        // 与 UIKit 相反，**默认为 true**，只关 `masksToBounds` 会被它在下一次
        // 布局时同步回去，模糊仍旧被削在文字盒边上。
        clipsToBounds = false
        layer?.masksToBounds = false
        // **逐行模糊/亮度真正生效的开关**。`SyncedLyricsLineLayer` 把
        // `CIGaussianBlur` + `CIColorControls` 挂在`filters` 上（§9.4 / §9.6），
        // 而 AppKit 的背衬层默认走**进程外**渲染，那条路根本不执行 Core Image
        // 滤镜——`filters` 装上了、`inputRadius` 也动了，画面上一点变化都没有，
        // 也不报错。开这一位让本视图连同其子层改走进程内渲染，滤镜才落到像素上。
        // （同一个坑 `MiniPlayerView.centerContent` 已经踩过一次。）
        // 代价是这棵子树失去进程外渲染的优化，这是用 CI 滤镜的固有开销。
        layerUsesCoreImageFilters = !LyricsDebugFlags.disablesLayerFilters
        if lineLayer == nil {
            let lineLayer = SyncedLyricsLineLayer()
            self.lineLayer = lineLayer
            layer?.addSublayer(lineLayer)
        }
        applyBackingScale()
        lineLayer?.configure(line: line, specs: specs, appearance: effectiveAppearance)
        // 词曲作者那一行不吃悬停（§4.1 第二道闸），也就不必装跟踪区。
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText(for: line))
    }

    private func accessibilityText(for line: any LyricsLine) -> String {
        switch line {
        case let text as TextLine:            return text.text
        case let credits as SongwritersLine:  return credits.text
        case is InstrumentalLine:             return "间奏"
        default:                              return ""
        }
    }
}

/// `NSControl` 那一半。分开写是因为 Swift 不许在 extension 里覆写非 objc 的成员，
/// 而 `isFlipped` / `mouseDown` 这些必须在类体里。
extension SyncedLyricsLineView {

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    // 进/出都转给控制器统一裁决：跟踪区只是「有事发生」的信号，谁该亮由
    // 指针的实际位置决定（见 `SyncedLyricsViewController.syncHoverState()`）。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        notifyHoverChanged()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        notifyHoverChanged()
    }

    private func notifyHoverChanged() {
        guard let controller = target as? SyncedLyricsViewController else {
            setHovered(true)                    // 没接上控制器时退回旧行为
            return
        }
        controller.syncHoverState()
    }

    /// 按下缩到 `touchDownTransform`(0.95)，松手弹回，并在**松手仍在框内**时发动作。
    override func mouseDown(with event: NSEvent) {
        guard lineLayer?.specs.renderingMode != .static else { return }
        applyTouchDown(true)
        var inside = true
        // 自己跑事件循环：`NSControl` 的默认追踪会先把动作发出去，
        // 而这里要的是「按住期间一直缩着」。
        while let next = amberWindow?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                inside = bounds.contains(point)
                break
            }
            let nowInside = bounds.contains(point)
            if nowInside != inside {
                inside = nowInside
                applyTouchDown(inside)
            }
        }
        applyTouchDown(false)
        if inside { sendPrimaryAction() }
    }

    private func applyTouchDown(_ down: Bool) {
        guard let lineLayer else { return }
        let target = down ? lineLayer.specs.touchDownTransform : .identity
        let animator = LayerPropertyAnimator(curve: SyncedLyricsLineLayer.focusTransitionCurve)
        animator.layers = [lineLayer]
        animator.addAnimation(to: lineLayer, keyPath: "transform",
                              from: lineLayer.value(forKeyPath: "transform"),
                              to: CATransform3DMakeAffineTransform(target),
                              frameRateRange: (min: 0, max: 0))
        animator.finishDispatch { lineLayer.setAffineTransform(target) }
    }

    /// [实测] `-[SyncedLyricsLineView primaryAction]` 只是
    /// `sendAction:to:` 的转发——面板自己不 seek，交给宿主。
    func sendPrimaryAction() {
        if let action { sendAction(action, to: target) }
    }
}
