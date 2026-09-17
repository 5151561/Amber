import Combine
import Foundation

/// 音乐源的启用状态与默认源（设置 › 音乐源）。持久化到 UserDefaults。
///
/// 关掉的源只是从「搜索 / 主页」的音乐源切换里消失，AppState 的 provider 注册表
/// 始终保留全部实现——资料库里已经收藏的该源歌曲仍要能取流播放。
@MainActor
@Observable
final class ProviderSettingsStore {

    /// 首次启动的默认：只开 QQ 音乐。
    /// 网易云接口没接登录，匿名下绝大多数曲目取不到流，开着只会一路报错。
    /// nonisolated：设置窗口的草稿（`SettingsDraft`）是个普通 struct，默认值要在
    /// 主 actor 之外读到它。`Set<ProviderKind>` 是 Sendable，跨 actor 读没有风险。
    nonisolated static let initialEnabled: Set<ProviderKind> = [.qq]

    private(set) var enabled: Set<ProviderKind>
    /// 启动时选中的音乐源，始终是已启用的源之一
    var defaultProvider: ProviderKind {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let enabledKey = "enabledProviders"
    private static let defaultProviderKey = "defaultProvider"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = (defaults.array(forKey: Self.enabledKey) as? [String] ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        // 空集合无从选源，退回初始默认（也覆盖首次启动没有这个键的情况）
        let restored = stored.isEmpty ? Self.initialEnabled : Set(stored)
        enabled = restored

        let storedDefault = defaults.string(forKey: Self.defaultProviderKey)
            .flatMap(ProviderKind.init(rawValue:))
        defaultProvider = storedDefault.flatMap { restored.contains($0) ? $0 : nil }
            ?? ProviderKind.allCases.first(where: restored.contains)
            ?? .qq
    }

    /// 已启用的源，按 ProviderKind 的声明顺序
    var orderedEnabled: [ProviderKind] {
        ProviderKind.allCases.filter(enabled.contains)
    }

    func isEnabled(_ kind: ProviderKind) -> Bool {
        enabled.contains(kind)
    }

    /// 至少要留一个源，最后一个已启用的源不允许关闭
    func canDisable(_ kind: ProviderKind) -> Bool {
        !(enabled.count == 1 && enabled.contains(kind))
    }

    func setEnabled(_ on: Bool, for kind: ProviderKind) {
        if on {
            guard !enabled.contains(kind) else { return }
            enabled.insert(kind)
        } else {
            guard canDisable(kind), enabled.contains(kind) else { return }
            enabled.remove(kind)
            if !enabled.contains(defaultProvider), let fallback = orderedEnabled.first {
                defaultProvider = fallback // didSet 里会落盘
            }
        }
        persist()
    }

    private func persist() {
        defaults.set(orderedEnabled.map(\.rawValue), forKey: Self.enabledKey)
        defaults.set(defaultProvider.rawValue, forKey: Self.defaultProviderKey)
    }
}
