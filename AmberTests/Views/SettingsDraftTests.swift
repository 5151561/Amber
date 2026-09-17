import XCTest
@testable import Amber

/// 设置窗口的草稿：Music 的设置是「按『好』才生效」，Amber 用 SettingsDraft 兜住这段编辑期。
final class SettingsDraftTests: XCTestCase {

    @MainActor
    private func makeProviderStore(_ name: String = #function) -> ProviderSettingsStore {
        let suite = "SettingsDraftTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return ProviderSettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @MainActor
    private func makeSettings(_ name: String = #function) -> AppSettings {
        let suite = "SettingsDraftTests.settings.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    /// 测试跑在 App 宿主进程里，`UserDefaults.standard` 就是 Amber 自己那份偏好。
    /// 这两个 store 必须拿隔离的 suite，否则 `apply` 会把开发者本人的
    /// 音质 / 列表大小偏好覆盖成默认值（音质会一路掉回 128k）。
    @MainActor
    private func makeQQLogin(_ name: String = #function) -> QQLoginStore {
        let suite = "SettingsDraftTests.qq.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return QQLoginStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @MainActor
    private func makeListViewSize(_ name: String = #function) -> ListViewSizeStore {
        let suite = "SettingsDraftTests.listSize.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return ListViewSizeStore(defaults: UserDefaults(suiteName: suite)!)
    }

    /// 至少留一个源：草稿里也不能把最后一个开着的关掉
    func testLastEnabledProviderCannotBeDisabled() {
        var draft = SettingsDraft()
        draft.enabledProviders = [.qq]

        XCTAssertFalse(draft.canDisable(.qq))
        draft.setEnabled(false, for: .qq)
        XCTAssertEqual(draft.enabledProviders, [.qq])
    }

    /// 关掉的正好是默认源时，默认源顺移到还开着的第一个——popup 不能停在已关的源上
    func testDisablingDefaultProviderMovesIt() {
        var draft = SettingsDraft()
        draft.enabledProviders = [.netease, .qq]
        draft.defaultProvider = .qq

        draft.setEnabled(false, for: .qq)

        XCTAssertEqual(draft.enabledProviders, [.netease])
        XCTAssertEqual(draft.defaultProvider, .netease)
    }

    /// 写回时必须先开后关。反过来的话，中间会短暂只剩零个源，
    /// 被 store 的「最后一个不许关」挡住，换源就写不进去。
    @MainActor
    func testApplySwapsProviderWithoutHittingLastOneGuard() {
        let store = makeProviderStore()
        XCTAssertEqual(store.orderedEnabled, [.qq])

        var draft = SettingsDraft()
        draft.enabledProviders = [.netease]
        draft.defaultProvider = .netease
        draft.apply(settings: makeSettings(),
                    providerSettings: store,
                    listViewSize: makeListViewSize(),
                    qqLogin: makeQQLogin())

        XCTAssertEqual(store.orderedEnabled, [.netease])
        XCTAssertEqual(store.defaultProvider, .netease)
    }

    /// 「好」按下时，Music 那一整套值一次性写回 AppSettings（占位项也要一起落盘，
    /// 否则下次开窗草稿又抓回旧值，用户会以为设置没保存）
    @MainActor
    func testApplyWritesAllMusicValues() {
        let settings = makeSettings()
        var draft = SettingsDraft()
        draft.values.crossfade = true
        draft.values.dolbyAtmos = .off
        draft.values.importEncoder = .mp3
        draft.values.soundEnhancerLevel = 200

        draft.apply(settings: settings,
                    providerSettings: makeProviderStore(),
                    listViewSize: makeListViewSize(),
                    qqLogin: makeQQLogin())

        XCTAssertEqual(settings.values.crossfade, true)
        XCTAssertEqual(settings.values.dolbyAtmos, .off)
        XCTAssertEqual(settings.values.importEncoder, .mp3)
        XCTAssertEqual(settings.values.soundEnhancerLevel, 200)
    }

    /// 「好」写回的档位要落进**注入的那份** defaults，且下次开 App 读得回来。
    /// 这条同时是回归护栏：写死 `UserDefaults.standard` 的旧写法会污染 Amber 自己的偏好。
    @MainActor
    func testApplyPersistsStreamQuality() {
        let suite = "SettingsDraftTests.quality.\(#function)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = QQLoginStore(defaults: defaults)
        XCTAssertEqual(store.quality, .standard)
        let untouched = UserDefaults.standard.string(forKey: "qqStreamQuality")

        var draft = SettingsDraft()
        draft.quality = .lossless
        draft.apply(settings: makeSettings(),
                    providerSettings: makeProviderStore(),
                    listViewSize: makeListViewSize(),
                    qqLogin: store)

        XCTAssertEqual(store.quality, .lossless)
        XCTAssertEqual(QQLoginStore(defaults: defaults).quality, .lossless)
        // 真实域（跑测试时就是 Amber 自己那份偏好）一个字节都不许动
        XCTAssertEqual(UserDefaults.standard.string(forKey: "qqStreamQuality"), untouched)
    }

    /// 「启用无损音频」关掉 → 起点降到最高的有损档；「杜比全景声＝关闭」→ 跳过沉浸声。
    /// 夹取只改起点，降级阶梯不动。
    func testQualityClamping() {
        // 关掉无损：从沉浸声那一档起也要落到有损的第一档
        XCTAssertEqual(StreamQuality.atmos.clamped(losslessEnabled: false, dolbyAtmos: .automatic), .ogg640)
        XCTAssertEqual(StreamQuality.master.clamped(losslessEnabled: false, dolbyAtmos: .automatic), .ogg640)
        // 关掉杜比全景声：沉浸声让开，落到它下面那一档
        XCTAssertEqual(StreamQuality.atmos.clamped(losslessEnabled: true, dolbyAtmos: .off), .surround)
        // 两个开关都不挡的时候原样返回
        XCTAssertEqual(StreamQuality.lossless.clamped(losslessEnabled: true, dolbyAtmos: .automatic), .lossless)
        XCTAssertEqual(StreamQuality.high.clamped(losslessEnabled: false, dolbyAtmos: .off), .high)
    }
}
