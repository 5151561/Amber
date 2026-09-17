import QuartzCore
import XCTest
@testable import Amber

/// `Amber/Lyrics/` 那几组测试共用的夹具。
///
/// 三套夹具的差别只在行流：
/// - `makeManager` 只要时间轴，不建视图；
/// - `makeScrubFixture` 文本 / 间奏交替，20 s 一行，用来走查间奏进出；
/// - `makeExpansionFixture` 只有一条间奏，10 s 一行，用来走查「上下展开」。
@MainActor
protocol LyricsKitFixtures {}

@MainActor
extension LyricsKitFixtures {

    func specs() -> LyricsSpecs { LyricsSpecs() }

    func textLine(index: Int = 0,
                  start: TimeInterval,
                  end: TimeInterval) -> TextLine {
        var line = TextLine()
        line.index = index
        line.startTime = start
        line.endTime = end
        return line
    }

    func makeManager(lead: TimeInterval = 0.1) -> SyncedLyricsManager {
        var configuration = SyncedLyricsManager.Configuration(
            finishLineAnimationDuration: 0.25, maxEndTimeOffset: 0.5)
        configuration.animationDuration = { _ in lead }
        return SyncedLyricsManager(configuration: configuration)
    }

    static func makeTextLyrics(_ spans: [(TimeInterval, TimeInterval)]) -> Lyrics {
        var lyrics = Lyrics()
        lyrics.lines = spans.enumerated().map { index, span in
            var line = TextLine()
            line.index = index
            line.startTime = span.0
            line.endTime = span.1
            line.text = "第\(index)句"
            return line
        }
        return lyrics
    }

    /// 搭一套「控制器 + 视觉管理器 + 时间轴」，行是 文本/间奏 交替。
    func makeScrubFixture(elapsed: @escaping () -> TimeInterval)
    -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager, SyncedLyricsManager) {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        let timeline = SyncedLyricsManager(configuration: .init(specs: controller.specs),
                                           maxSelectedLines: controller.specs.maxSelectedLines)
        timeline.delegate = controller
        timeline.elapsedTimeProvider = elapsed
        visual.manager = timeline

        var lines: [any LyricsLine] = []
        for index in 0..<8 {
            let start = Double(index) * 20
            if index % 2 == 1 {
                var instrumental = InstrumentalLine()
                instrumental.index = index
                instrumental.startTime = start
                instrumental.endTime = start + 20
                lines.append(instrumental)
            } else {
                var text = TextLine()
                text.index = index
                text.startTime = start
                text.endTime = start + 20
                text.text = "第\(index)行歌词"
                lines.append(text)
            }
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)
        return (controller, visual, timeline)
    }

    /// 一条间奏 + 若干文本行的行流。间奏落在 `instrumentalIndex`。
    func makeExpansionFixture(instrumentalAt instrumentalIndex: Int,
                              lineCount: Int = 9)
    -> (SyncedLyricsViewController, SyncedLyricsVisualExperienceManager) {
        let controller = SyncedLyricsViewController()
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        controller.view.layoutSubtreeIfNeeded()

        let visual = SyncedLyricsVisualExperienceManager()
        visual.viewController = controller
        visual.specs = controller.specs
        controller.manager = visual

        var lines: [any LyricsLine] = []
        for index in 0..<lineCount {
            let start = Double(index) * 10
            if index == instrumentalIndex {
                var instrumental = InstrumentalLine()
                instrumental.index = index
                instrumental.startTime = start
                instrumental.endTime = start + 10
                lines.append(instrumental)
            } else {
                var text = TextLine()
                text.index = index
                text.startTime = start
                text.endTime = start + 5
                text.text = "第\(index)行歌词"
                lines.append(text)
            }
        }
        var lyrics = Lyrics()
        lyrics.lines = lines
        controller.setLyrics(lyrics)
        return (controller, visual)
    }
}

/// `syncBlurToPlaybackState()` 只读 `isPaused`，`elapsedTime` 走不到。
@MainActor
final class StubTimingProvider: SyncedLyricsTimingProvider {
    var isPaused = false
    var elapsedTime: TimeInterval = 0
}
