import XCTest
@testable import Amber

/// 音量跨启动保留。
///
/// 从前 `PlayerController.volume` 只活在内存里，每次打开 Amber 都是满格；
/// 现在由 AppState 在 `init` 里读回、并在每次改动时写盘（见 `AppState.volumeKey` 那一段）。
final class VolumePersistenceTests: XCTestCase {

    /// 测试宿主就是 Amber 本身，落在隔离的 suite 里，别写进开发者真实的偏好。
    private let suite = "VolumePersistenceTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    private func makeState() -> AppState { AppState(defaults: defaults) }

    /// 没存过就是满格；调过一次之后，下一次「启动」还是那一格。
    @MainActor
    func testVolumeSurvivesRelaunch() async {
        let first = makeState()
        XCTAssertEqual(first.player.volume, 1.0, accuracy: 0.0001)

        first.player.volume = 0.42
        // 落盘那条订阅换成 Observations 之后要过一跳（以前 .sink 是同步回调）。
        await settleObservations()

        let second = makeState()
        XCTAssertEqual(second.player.volume, 0.42, accuracy: 0.0001)
    }

    /// 静音（0）也照存：退出时是静音的，打开还是静音的。
    @MainActor
    func testMutedStateSurvivesRelaunch() async {
        let first = makeState()
        first.player.volume = 0
        await settleObservations()

        XCTAssertEqual(makeState().player.volume, 0, accuracy: 0.0001)
        _ = first
    }

    /// 存下来的值越界（手改偏好、旧版本写坏）时夹回 0…1，不把脏值喂给播放器。
    @MainActor
    func testStoredVolumeIsClamped() {
        defaults.set(3.5, forKey: "playerVolume")
        XCTAssertEqual(makeState().player.volume, 1.0, accuracy: 0.0001)

        defaults.set(-1.0, forKey: "playerVolume")
        XCTAssertEqual(makeState().player.volume, 0, accuracy: 0.0001)
    }
}
