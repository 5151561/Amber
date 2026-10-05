import QuartzCore

// 亮字那一半按需建、按需拆。
//
// 原来每个音节建好就是 base / sung 一对，非选中行只是把 `row.sung.opacity` 置 0；
// 可 opacity 0 的子层照样 display、背衬照样占着（[实测 2026-09] 一份进程 4258 个
// `CATextLayer`、CoreAnimation 59 MB，亮字约占音节层的一半）。
//
// 拆的只是亮字 `CATextLayer`：容器 `row.sung`、它的遮罩 `row.gradient`、容器 opacity
// 与那条淡出全都不动，每帧照常推进。所以亮字现建出来的那一刻，遮罩宽度已经是当前进度、
// 容器 opacity 已经是该有的值——不存在「从 0 扫到当前进度」或者闪一帧的起点问题。
//
// 什么时候建、什么时候拆，由 `applyColors` / `prepareSungOpacity` / 两条 rebuild 决定：
// 变可见（选中或预热）之前建；淡出**落位**之后、或瞬时熄灭时拆（见 `Row.sungTeardownToken`）。

extension SBS_TextContentLayer {

    /// 照着 base 把这一行的亮字建出来。已建就什么都不做。
    func ensureSungLayers(in row: Row, color: CGColor) {
        guard !row.hasSungLayers else { return }
        row.hasSungLayers = true
        // 新层的属性一条条写进去，别让任何一条带隐式动画（尤其 `position`：
        // 默认 action 会让亮字从原点飞过来）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in row.syllables.indices {
            row.syllables[index].sung = makeSungTwin(of: row.syllables[index].base,
                                                     color: color, in: row)
        }
        for index in row.ruby.indices {
            row.ruby[index].sung = makeSungTwin(of: row.ruby[index].base,
                                                color: color, in: row)
        }
        CATransaction.commit()
    }

    /// 拆掉这一行的亮字。只在它们看不见时调（容器 opacity 落到 0 之后）。
    func discardSungLayers(in row: Row) {
        guard row.hasSungLayers else { return }
        row.hasSungLayers = false
        for index in row.syllables.indices {
            row.syllables[index].sung?.removeFromSuperlayer()
            row.syllables[index].sung = nil
        }
        for index in row.ruby.indices {
            row.ruby[index].sung?.removeFromSuperlayer()
            row.ruby[index].sung = nil
        }
    }

    /// 瞬时熄灭时的拆层：当场拆，除非容器上还挂着上一条没跑完的淡出。
    ///
    /// 把模型值改成 0 不会摘掉那条淡出，画面上它仍在淡；这时拆了就是半透明的亮字
    /// 一帧消失。所以不动——口令也不改，留给那条淡出自己的收尾去拆。
    /// （淡出中途「又亮又灭」过一轮的话，那次收尾的口令已经作废，亮字会留到下一次
    /// 熄灭或重排再拆：只是晚拆，不会错拆。）
    func discardSungLayersIfSettled(in row: Row) {
        guard row.hasSungLayers, row.sung.animation(forKey: "opacity") == nil else { return }
        row.sungTeardownToken &+= 1
        discardSungLayers(in: row)
    }

    /// 一层与 base **同位同形**的亮字。
    ///
    /// - 属性逐条抄 base（`makeTextLayers` 写过的那几条），不重新排一遍：
    ///   `alignmentMode` 是 CATextLayer 认的那条对齐（属性串里的段落对齐它不看），
    ///   字体、字号、放宽过的宽度也都原样，排出来的字形与 base 逐像素重合。
    /// - 落点抄的是 base 的**模型**位置：抬升（`liftStartedSyllables`）是当场把真值
    ///   写进模型、动画只把 2pt 偏移退回 0（§6.5 叠加式），所以模型位置已含抬升。
    /// - base 上若还挂着那条没飘完的抬升（`position` 叠加动画），原样拷一份挂上来：
    ///   `beginTime` 是绝对时间，同一条弹簧在同一时刻算出同一个偏移，两层同相位飘完，
    ///   不会出现底字还在飘、亮字已经落位的错层。拷贝摘掉 delegate，
    ///   不去动原动画器的完成记账（`totalAnimations` / `completionCount`）。
    private func makeSungTwin(of base: CATextLayer, color: CGColor, in row: Row) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = base.contentsScale
        layer.isWrapped = base.isWrapped
        layer.truncationMode = base.truncationMode
        layer.alignmentMode = base.alignmentMode
        layer.font = base.font
        layer.fontSize = base.fontSize
        layer.foregroundColor = color
        layer.string = base.string
        layer.bounds = base.bounds
        layer.anchorPoint = base.anchorPoint
        layer.position = base.position
        layer.transform = base.transform
        for keyPath in ["position", "transform"] {
            guard let running = base.animation(forKey: keyPath),
                  let copy = running.copy() as? CAAnimation else { continue }
            copy.delegate = nil
            layer.add(copy, forKey: keyPath)
        }
        row.sung.addSublayer(layer)
        return layer
    }
}
