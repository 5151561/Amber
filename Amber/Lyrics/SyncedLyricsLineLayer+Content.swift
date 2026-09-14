import AppKit
import QuartzCore

// 行图层的装配：三选一的内容层、几何、以及「正在拖」的转告。
//
// 内容层怎么选是实测的旁证：`selecting line` 把`contentLayer`
// 往 `MusicInstrumentalContentLayer` 上转型来认间奏行（判的是**内容层的类**，
// 不是行模型的类型），往 `SBS_TextContentLayer` 上转型来推逐字进度。
// 也就是说三种行各自换一种内容层，剩下的那种（整行档）兜底。

extension SyncedLyricsLineLayer {

    /// 这一行该用哪种内容层。
    static func contentKind(for line: any LyricsLine) -> ContentKind {
        switch line {
        case is InstrumentalLine:
            return .instrumental
        case let text as TextLine:
            // 有逐字时间轴才谈得上渐变扫过；只有整行时间的走整行档。
            return text.syllables.isEmpty ? .despacito : .sbsText
        default:
            return .despacito
        }
    }

    /// 装配这一行。换歌 / 换行时调一次。
    func configure(line: any LyricsLine, specs: LyricsSpecs, appearance: NSAppearance?) {
        self.specs = specs
        self.line = line

        let kind = Self.contentKind(for: line)
        let content = makeContentLayer(kind: kind, line: line)
        content?.updateAppearance(specs: specs, appearance: appearance)

        if let old = contentLayer, old !== content { old.removeFromSuperlayer() }
        contentLayer = content
        if let content, content.superlayer !== self { addSublayer(content) }
        // 内容层是在这里现造的，子层默认 1× —— 建完立刻把倍率灌下去。
        applyRenderingScale(renderingScale)
        setNeedsLayout()
    }

    private func makeContentLayer(kind: ContentKind,
                                  line: any LyricsLine) -> (any SyncedLyricsContentLayer)? {
        switch kind {
        case .instrumental:
            // [实测]（§15.3）的三分支。
            //
            // 一、`renderingMode == .static`（侧栏那一档）→ **根本不建间奏层**，
            //     直接把内容层置空（`stp xzr, xzr`）。侧栏歌词里没有三个点。
            guard specs.renderingMode != .static else { return nil }

            // 二、已有的内容层能转型 → **就地复用**：回填四个字段再 `reset()`
            // **不重建点**——重建会让点闪一下。
            // 三、否则新建（+）。
            let layer: InstrumentalContentLayer
            if let reused = contentLayer as? InstrumentalContentLayer {
                reused.specs = specs
                reused.line = line
                reused.setSelected(false, animated: false)
                reused.reset()
                layer = reused
            } else {
                layer = InstrumentalContentLayer()
                layer.specs = specs
                layer.line = line
                layer.reset()
            }

            // 三条路最后都落到同一句 `alignment =`——
            // 也就是 §15.5 那个建点触发点，点在这一刻出现。落点按**行自带**的
            // 书写方向选边，不是全局设置。
            let direction = (line as? InstrumentalLine)?.lyricsDirection ?? .leftToRight
            layer.alignment = InstrumentalContentLayer.dotAlignment(for: direction)
            // 赋的值与默认值相等时 `didSet` 按原版语义早退，这一手负责补建（只建不重排）。
            layer.makeDotsIfNeeded()
            return layer

        case .sbsText:
            let layer = (contentLayer as? SBS_TextContentLayer) ?? SBS_TextContentLayer()
            layer.specs = specs
            layer.setLine(line as? TextLine)
            layer.resetProgress()
            return layer

        case .despacito:
            let layer = (contentLayer as? TextContentLayer) ?? TextContentLayer()
            layer.specs = specs
            switch line {
            case let text as TextLine:
                layer.setLine(text)
            case let songwriters as SongwritersLine:
                var text = TextLine()
                text.index = songwriters.index
                text.text = songwriters.text
                layer.setLine(text)
            default:
                layer.setLine(nil)
            }
            return layer
        }
    }

    /// 行几何测高时问的就是它（`sizeThatFits:`）。
    func sizeThatFits(width: CGFloat) -> CGSize {
        contentLayer?.sizeThatFits(width: width) ?? .zero
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 行图层为滤镜溢出外扩过（`filterBleed`），内容层缩回去才落在原位。
        contentLayer?.frame = bounds.insetBy(dx: Self.filterBleed, dy: Self.filterBleed)
        CATransaction.commit()
    }

    /// §9.9 第二段：把「正在拖」转告内容层。
    func applyScrolling(_ scrolling: Bool, animated: Bool = true) {
        isScrolling = scrolling
        contentLayer?.setScrolling(scrolling, animated: animated)
    }

    /// 外观（高对比度与否）变了要重新解析颜色。
    func applyAppearance(_ appearance: NSAppearance?) {
        contentLayer?.updateAppearance(specs: specs, appearance: appearance)
    }
}
