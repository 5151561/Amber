import CryptoKit
import Foundation
import Network

// MARK: - 模型

/// 浏览 `_touch-remote._tcp` 发现的一台还没配对的遥控器。
struct DiscoveredRemote: Identifiable, Hashable {
    /// Bonjour 服务名。遥控 App 拿一串 hex 当服务名，同一台设备重开 App 会变，
    /// 所以只当「本次列表里的行 id」用，不落盘。
    let id: String
    /// TXT `DvNm`：设备名（「小明的 iPhone」）
    let name: String
    /// TXT `Pair`：16 位 hex 的配对标识，算配对码要用
    let pairID: String
    /// TXT `DvTy`：设备型号（iPhone / iPad…）
    let deviceType: String
    let endpoint: NWEndpoint
}

/// 配对成功、记在本机的一台遥控器。
struct PairedRemote: Identifiable, Codable, Hashable {
    /// 手机在 `cmpg` 里发回来的 8 字节 GUID，16 位大写 hex。
    /// 它既是身份也是**凭证**——后续 `/login?pairing-guid=0x…` 就靠它认人，
    /// 所以这份表存在钥匙串而不是明文 JSON（见 `RemotePairingStore`）。
    let guid: String
    let name: String
    let deviceType: String
    let pairedAt: Date

    var id: String { guid }
}

// MARK: - 配对码

enum RemotePairing {

    /// 配对码 = MD5( Pair 的 16 个 ASCII 字符 ‖ 每位 PIN 数字的 ASCII 后跟一个 NUL )。
    ///
    /// 「数字后跟 NUL」等价于把 PIN 按 UTF-16LE 编码，公开实现里两种写法都能见到。
    ///
    /// 测试向量（`hashlib.md5`）：
    ///   pair=`0000000000000001`, pin=`1234` → `690E6FF61E0D7C747654A42AED17047D`
    ///   pair=`0000000000000001`, pin=`0000` → `75D809650423A40091193AA4944D1FBD`
    static func pairingCode(pairID: String, pin: String) -> String {
        var md5 = Insecure.MD5()
        md5.update(data: Data(pairID.utf8))
        for character in pin {
            md5.update(data: Data(String(character).utf8))
            md5.update(data: Data([0]))
        }
        return md5.finalize().map { String(format: "%02X", $0) }.joined()
    }

    /// PIN 必须是 4 位数字（遥控 App 上显示的就是四格）。
    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    /// 随机生成一个 16 位大写 hex 的资料库标识（`_touch-able._tcp` 的服务名与 `DbId`）。
    static func randomLibraryID() -> String {
        (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }
}

// MARK: - 存储

/// 配对表的落点。抽出协议只为一件事：测试不碰钥匙串。
protocol RemotePairingStorage: AnyObject {
    func load() -> String?
    func save(_ json: String)
    func clear()
}

/// 出厂落点：钥匙串里**一条** generic password，值是整张表的 JSON。
///
/// 为什么不是 Application Support 里的 JSON：`cmpg` 拿到手就是控制本机播放的凭证，
/// 谁读到谁就能 `/login` 成功。一条一台设备地存又没必要（同一个 service 下多开条目
/// 只会让「忽略所有遥控器」要删一串键），所以整张表塞一条。
/// 键名与 QQ cookie 那些共用 `KeychainHelper` 的 service。
final class KeychainPairingStorage: RemotePairingStorage {
    private let key: String

    init(key: String = "remote-pairings") { self.key = key }

    func load() -> String? { KeychainHelper.get(key) }
    func save(_ json: String) { KeychainHelper.set(json, for: key) }
    func clear() { KeychainHelper.delete(key) }
}

/// 测试用的内存落点。
final class MemoryPairingStorage: RemotePairingStorage {
    private var json: String?
    init(json: String? = nil) { self.json = json }
    func load() -> String? { json }
    func save(_ json: String) { self.json = json }
    func clear() { json = nil }
}

@MainActor
final class RemotePairingStore {

    private(set) var devices: [PairedRemote] = []
    private let storage: RemotePairingStorage

    init(storage: RemotePairingStorage = KeychainPairingStorage()) {
        self.storage = storage
        if let json = storage.load(), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PairedRemote].self, from: data) {
            devices = decoded
        }
    }

    /// 同一台设备重复配对就覆盖旧记录（GUID 不变时名字可能变了）。
    func add(_ device: PairedRemote) {
        devices.removeAll { $0.guid.caseInsensitiveCompare(device.guid) == .orderedSame }
        devices.append(device)
        persist()
    }

    func removeAll() {
        devices.removeAll()
        storage.clear()
    }

    /// `/login?pairing-guid=0x…` 的校验。手机发上来的 hex 大小写不定，一律不敏感比。
    func contains(guid: String) -> Bool {
        let normalized = RemotePairingStore.normalize(guid)
        return devices.contains { RemotePairingStore.normalize($0.guid) == normalized }
    }

    /// 去掉 `0x` 前缀、补齐到 16 位、转大写。
    static func normalize(_ guid: String) -> String {
        var hex = guid.uppercased()
        if hex.hasPrefix("0X") { hex.removeFirst(2) }
        while hex.count < 16 { hex = "0" + hex }
        return hex
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices),
              let json = String(data: data, encoding: .utf8) else { return }
        storage.save(json)
    }
}
