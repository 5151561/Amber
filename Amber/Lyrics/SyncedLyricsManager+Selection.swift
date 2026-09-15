import Foundation

extension SyncedLyricsManager {

    /// 每帧算出的时间基准。规格见 lyrics 规格 §1.2。
    ///
    /// 复现 manager 每帧更新。三步全为 [实测]：
    ///
    /// 1. `elapsedTimeProvider()`
    /// 2. 空间音频时减去歌词偏移（`isPlayingSpatial` @）
    /// 3. 加上 `configuration.animationDuration(行时长)` 得 cutoff
    ///
    /// 容易读错的地方：**淘汰判据用的不是裸 elapsed**，而是这个 cutoff；
    /// 而且提前量是**按行时长算的闭包返回值**，不是 spec 里那个常数 0.1。
    struct TimeBasis: Sendable, Equatable {
        /// 扣掉空间音频偏移之后的播放进度。
        var elapsed: TimeInterval
        /// `elapsed + animationDuration(lineDuration)`，淘汰队首时比的就是它。
        var cutoff: TimeInterval
    }

    func timeBasis(spatialLyricsOffset: TimeInterval,
                          candidateLineDuration: TimeInterval?) -> TimeBasis {
        var elapsed = elapsedTimeProvider()
        if isPlayingSpatial {
            elapsed -= spatialLyricsOffset          // [实测] fsub d8, d8, d10
        }
        // 没有候选行时原版喂 0
        let lead = configuration.animationDuration(candidateLineDuration ?? 0)
        return TimeBasis(elapsed: elapsed, cutoff: elapsed + lead)
    }

    // MARK: 淘汰

    /// 选中集合已满时，队首是否让位。
    ///
    /// [实测]：；满了才比队首 `endTime` 与 cutoff，
    /// —— **`endTime >= cutoff` 保留**，否则移除队首。
    func shouldEvictOldestSelectedLine(oldestEndTime: TimeInterval,
                                              cutoff: TimeInterval,
                                              selectedCount: Int) -> Bool {
        guard selectedCount >= maxSelectedLines else { return false }
        return oldestEndTime < cutoff
    }

    // MARK: 准入

    /// 下一行是否够格进选中集合。
    ///
    /// 两条路，满足其一即可：
    ///
    /// 1. **常规提前量**（[实测]）：
    ///    `d11 = startTime - maxEndTimeOffset`，再 /——
    ///    `startTime - 0.5 >= elapsed` 就跳过，否则纳入。即
    ///    **`elapsed > startTime - maxEndTimeOffset`**。
    ///
    ///    注意：`maxEndTimeOffset` 名字里带 end，实际是**减在下一行的`startTime` 上**，
    ///    让新行提前 0.5 s 进场；不是让旧行延后 0.5 s 退场。两种写法看到的效果
    ///    一样（句间不断亮），但照「旧行延后」实现的话，间奏前最后一句会多亮 0.5 s——
    ///    因为没有下一行来接——原版不会。旧行的退场只由 `shouldEvictOldestSelectedLine` 管。
    ///
    /// 2. **给焦点位让路**（`[补]`）：焦点位要在开唱前一整个滚动动画（`scrollLead`）
    ///    就让过去，好让滚动跑完那一刻正好是开唱那一刻。而焦点位只在选中集合里挑，
    ///    所以准入窗口至少要和 `scrollLead` 一样宽，否则那一行还没进来、滚不过去。
    ///
    ///    这条压着 `selectedCount < maxSelectedLines`：一次只多放一行进来。
    ///    `scrollLead`（≈0.89 s）比密集说唱的句长还大，没有这道闸的话，短句歌里
    ///    一帧能放进三四行，选中集合、焦点位、淘汰全乱。有了它，焦点位最多领先
    ///    正在唱的那句一行——和 `scrollTargetLineView` 的规则 2 是同一条纪律。
    ///
    /// - Parameter selectedCount: 当前选中集合的条数，只给 2. 那道上限闸用。
    ///   不传就只走 1.（`resync` 这类「按时刻一次算完」的路径）。
    func shouldAdmit(line: any LyricsLine,
                     elapsed: TimeInterval,
                     selectedCount: Int = .max) -> Bool {
        if elapsed > line.startTime - configuration.maxEndTimeOffset { return true }
        guard selectedCount < maxSelectedLines else { return false }
        return elapsed > line.startTime - configuration.scrollLead
    }

    /// 队首行当初是踩着哪个时刻进来的：两条准入路里更早的那个。`[补]`
    ///
    /// 只有倒带判据用它。`shouldAdmit` 那边还压着「选中集合没满」这道闸，所以真实的准入
    /// 只会比这个时刻更晚——判倒带时宁可宽一点：判漏了下一帧照样能增量追上，
    /// 判过头了却会把刚提前就位的下一句硬拽回上一句。
    func admissionThreshold(for line: any LyricsLine) -> TimeInterval {
        line.startTime - max(configuration.maxEndTimeOffset, configuration.scrollLead)
    }

    /// 行是否已唱完。[实测] /
    /// —— `endTime >= elapsed` 表示还没唱完；否则走收尾路径，
    /// 对应 `lineFinishProgressAnimationDuration = 0.25`（把没走完的进度补完）。
    func hasFinished(line: any LyricsLine, elapsed: TimeInterval) -> Bool {
        line.endTime < elapsed
    }
}

// MARK: - 每帧走查

extension SyncedLyricsManager {

    /// 空间音频的歌词偏移，取自 `lyrics.audioAttributes`。
    /// Amber 的 QRC/LRC 源不产出这个属性，恒为 0——代码路径照留。
    var spatialLyricsOffset: TimeInterval {
        for case .spatial(let offset) in lyrics?.audioAttributes ?? [] { return offset }
        return 0
    }

    /// 每帧入口。规格见 §1.2 与 §1.3。
    ///
    /// 顺序照原版：先算时间基准 → 队首出局 → 下一行准入 → 已唱完的行走收尾。
    ///
    /// - Returns: 这一帧的时间基准，调用方要拿 `elapsed` 去喂逐字内容层。
    @discardableResult
    func update() -> TimeBasis {
        let candidate = nextLine
        let basis = timeBasis(
            spatialLyricsOffset: spatialLyricsOffset,
            candidateLineDuration: candidate.map { $0.endTime - $0.startTime })

        guard lyrics != nil else { return basis }

        // 倒带：进度退到了当前选中集合之前，增量推进追不回来，整体重排。`[补]`
        // 原版靠 `jumping to`（§5.4）与时间源切换（§1.4）覆盖 seek，
        // Amber 这边进度条随时可拖，所以留一条自愈路径。
        //
        // 比的是队首的**准入门槛**，不是裸的 `startTime - maxEndTimeOffset`：
        // 队首可能是「给焦点位让路」提前放进来的那条（`shouldAdmit` 的第 2 条路），
        // 此刻 `elapsed` 本来就还没到它的`startTime`——照裸提前量判，每次提前让位之后
        // 都会被认成倒带，刚让过去的焦点位又被拽回上一句，画面卡在那儿来回跳。
        if let first = selectedLines.first,
           basis.elapsed < admissionThreshold(for: first) {
            resync(at: basis.elapsed)
            return basis
        }

        evictFinishedHead(cutoff: basis.cutoff)
        admitUpcomingLines(elapsed: basis.elapsed, cutoff: basis.cutoff)
        reportFinishedLines(elapsed: basis.elapsed)
        return basis
    }

    /// 队首出局。[实测]：满了才比，`endTime >= cutoff` 保留。
    private func evictFinishedHead(cutoff: TimeInterval) {
        while let first = selectedLines.first,
              shouldEvictOldestSelectedLine(oldestEndTime: first.endTime,
                                            cutoff: cutoff,
                                            selectedCount: selectedLines.count) {
            selectedLines.removeFirst()
            delegate?.syncedLyricsManager(self, didDeselect: first)
        }
    }

    /// 下一行准入。判据见 `shouldAdmit`（常规提前量 0.5 s，或给焦点位让路的 `scrollLead`）。
    ///
    /// 循环是为了让快进后的追帧一次到位；每纳入一行都重跑一次淘汰，
    /// 于是选中集合始终不超过 `maxSelectedLines`，落点与逐帧推进一致。
    ///
    /// 判「是不是换歌 / 快进这类跨度」的那次预扫只用常规提前量（不传 `selectedCount:`）：
    /// `scrollLead` 那条本来就一次只放一行，拿它去数「待纳入几行」会把短句歌全判成快进。
    private func admitUpcomingLines(elapsed: TimeInterval, cutoff: TimeInterval) {
        // 一次要纳入的行超过上限，说明是换歌 / 快进这类跨度，不该逐行发一遍
        // 「选中」——那会让视图侧把中间每一行都翻一次。整体重排一次到位。`[补]`
        if let lines = lyrics?.lines {
            let pending = lines[min(nextLineIndex, lines.count)...]
                .prefix { shouldAdmit(line: $0, elapsed: elapsed) }
                .count
            if pending > maxSelectedLines {
                resync(at: elapsed)
                return
            }
        }
        while let next = nextLine, shouldAdmit(line: next,
                                              elapsed: elapsed,
                                              selectedCount: selectedLines.count) {
            advanceNextLine()
            selectedLines.append(next)
            delegate?.syncedLyricsManager(self, didSelect: next)
            evictFinishedHead(cutoff: cutoff)
        }
    }

    /// 已唱完的行走收尾路径（对应
    /// `lineFinishProgressAnimationDuration = 0.25`：把没走完的进度补完）。
    /// [实测]：`endTime < elapsed` 才算唱完。
    private func reportFinishedLines(elapsed: TimeInterval) {
        for line in selectedLines where hasFinished(line: line, elapsed: elapsed) {
            guard finishedLineIndices.insert(line.index).inserted else { continue }
            delegate?.syncedLyricsManager(self, didFinish: line)
        }
    }

    /// 把 `nextLine` 推到下一条。
    private func advanceNextLine() {
        guard let lines = lyrics?.lines else { nextLine = nil; return }
        nextLineIndex += 1
        nextLine = lines.indices.contains(nextLineIndex) ? lines[nextLineIndex] : nil
    }

    /// 按给定时刻重建整个选中集合。换歌、拖进度条倒带时走这条。`[补]`
    ///
    /// 规则与增量推进完全一致，只是一次算完：取所有满足准入条件的行，
    /// 留最后 `maxSelectedLines` 条里`endTime >= cutoff` 的那些。
    func resync(at elapsed: TimeInterval) {
        guard let lines = lyrics?.lines else { return }
        isResyncing = true
        defer {
            isResyncing = false
            delegate?.syncedLyricsManager(self, didResyncTo: selectedLines.last)
        }

        let previous = selectedLines
        let admitted = lines.filter { shouldAdmit(line: $0, elapsed: elapsed) }
        let cutoff = elapsed + configuration.animationDuration(0)
        var kept = admitted.suffix(maxSelectedLines).filter { $0.endTime >= cutoff }
        // 全都过期时（例如拖到间奏正中）留最后一条，免得整屏没有落点。
        if kept.isEmpty, let last = admitted.last { kept = [last] }

        nextLineIndex = (admitted.last.map { $0.index + 1 }) ?? 0
        nextLine = lines.indices.contains(nextLineIndex) ? lines[nextLineIndex] : nil
        selectedLines = Array(kept)
        finishedLineIndices = Set(lines.filter { $0.endTime < elapsed }.map(\.index))

        let keptIndices = Set(selectedLines.map(\.index))
        for line in previous where !keptIndices.contains(line.index) {
            delegate?.syncedLyricsManager(self, didDeselect: line)
        }
        let previousIndices = Set(previous.map(\.index))
        for line in selectedLines where !previousIndices.contains(line.index) {
            delegate?.syncedLyricsManager(self, didSelect: line)
        }
    }
}
