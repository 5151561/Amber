import SwiftUI
import QuartzCore
import CoreText
import XCTest
@testable import Amber

/// 弹簧本体：翻行那条的端点与物理量、`ScrollSpring` 的落位与延迟。
@MainActor
final class LyricsSpringTests: XCTestCase, LyricsKitFixtures {

    // MARK: - §2.8 duration hack

    /// §2.8 duration hack：命中就压 delay，弹簧本体不动。
    func testDurationHack() {
        XCTAssertTrue(DurationHack.isTriggered(lineTime: 1.0, maxEndTimeOffset: 0.5,
                                               baseOffset: 0.2, settlingDuration: 0.6))
        XCTAssertFalse(DurationHack.isTriggered(lineTime: 4.0, maxEndTimeOffset: 0.5,
                                                baseOffset: 0.2, settlingDuration: 0.6))
        XCTAssertEqual(DurationHack.delay(lineTime: 1.0, maxEndTimeOffset: 0.5, baseOffset: 0.2),
                       0.3, accuracy: 1e-9)
    }

    // MARK: - 滚动弹簧

    /// 翻行那条欠阻尼（会过冲），点击那条过阻尼（不回弹）。
    func testScrollSpringOvershootDependsOnDampingRatio() {
        let underdamped = LyricsSpecs().lineChangeSpringTimingParameters
        let samples = stride(from: 0.05, through: 1.5, by: 0.01).map {
            ScrollSpring.decay(t: $0, parameters: underdamped)
        }
        XCTAssertTrue(samples.contains { $0 < -1e-4 }, "ζ=0.9 应当过冲到负位移")

        let overdamped = SpringTimingParameters.tapDriven
        let noOvershoot = stride(from: 0.01, through: 2.0, by: 0.01).allSatisfy {
            ScrollSpring.decay(t: $0, parameters: overdamped) >= -1e-9
        }
        XCTAssertTrue(noOvershoot, "ζ>1 不该过冲")
    }

    func testScrollSpringStartsAtOriginAndSettlesAtTarget() {
        let spring = ScrollSpring(from: 0, to: 100,
                                  parameters: LyricsSpecs().lineChangeSpringTimingParameters,
                                  delay: 0, startTime: 0)
        XCTAssertEqual(spring.value(at: 0), 0)
        XCTAssertEqual(spring.value(at: spring.settlingDuration + 1), 100)
        XCTAssertTrue(spring.isFinished(at: spring.settlingDuration + 0.001))
    }

    func testScrollSpringHonoursDelay() {
        let spring = ScrollSpring(from: 0, to: 100,
                                  parameters: LyricsSpecs().lineChangeSpringTimingParameters,
                                  delay: 0.3, startTime: 0)
        XCTAssertEqual(spring.value(at: 0.2), 0)
        XCTAssertNotEqual(spring.value(at: 0.4), 0)
    }
    // MARK: - §2.4 / §9.1 翻行弹簧的端点与物理量

    /// 逐字歌词动态弹簧端点与物理公式核验（sub_0x10110b814）。
    /// ζ = 0.78 + 0.12 * (1 - u), T = 0.48 + 0.27 * u
    func testDerivedLineChangeSpringEndpointsAndPhysics() {
        // [实测]：ω = 2π / response（那个常量是 2π 不是 π），stiffness = m·ω²。
        // 与 SwiftUI 的 `Spring(response:dampingRatio:)` 一字不差。
        let byResponse = SpringTimingParameters(dampingRatio: 0.9, response: 0.5)
        XCTAssertEqual(byResponse.angularFrequency, 2 * Double.pi / 0.5, accuracy: 1e-9)
        XCTAssertEqual(byResponse.stiffness,
                       byResponse.angularFrequency * byResponse.angularFrequency, accuracy: 1e-9)

        // specs 那条 (1, 100, 18) 正好接在慢歌端点上。
        XCTAssertEqual(LyricsSpecs().lineChangeSpringTimingParameters.dampingRatio,
                       0.90, accuracy: 1e-3)
        // 视觉管理器上那个同名入口只是转发，不许在半路改数。
        XCTAssertEqual(SyncedLyricsVisualExperienceManager.derivedLineChangeSpring(speed: 0.475),
                       SpringTimingParameters.derivedLineChangeSpring(speed: 0.475))

        // 慢歌端点：speed <= 0.2 => u = 0, ζ = 0.90, T = 0.48
        let slowSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.1)
        XCTAssertEqual(slowSpring.dampingRatio, 0.90, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / slowSpring.angularFrequency, 0.48, accuracy: 1e-4)

        // 快歌端点：speed >= 0.75 => u = 1, ζ = 0.780, T = 0.75
        let fastSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.8)
        XCTAssertEqual(fastSpring.dampingRatio, 0.780, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / fastSpring.angularFrequency, 0.75, accuracy: 1e-4)

        // 中间值：speed = 0.475 => u = 0.5, ζ = 0.84, T = 0.615
        let midSpring = SpringTimingParameters.derivedLineChangeSpring(speed: 0.475)
        XCTAssertEqual(midSpring.dampingRatio, 0.84, accuracy: 1e-4)
        XCTAssertEqual(2 * Double.pi / midSpring.angularFrequency, 0.615, accuracy: 1e-4)

        // 点击驱动：过阻尼 (2, 260, 50), ζ ≈ 1.096 > 1
        let tap = SpringTimingParameters.tapDriven
        XCTAssertEqual(tap.mass, 2.0)
        XCTAssertEqual(tap.stiffness, 260.0)
        XCTAssertEqual(tap.damping, 50.0)
        XCTAssertGreaterThan(tap.dampingRatio, 1.0)
        XCTAssertLessThan(fastSpring.angularFrequency, slowSpring.angularFrequency,
                          "唱得越快周期越长，ω 反而该变小")
    }
}
