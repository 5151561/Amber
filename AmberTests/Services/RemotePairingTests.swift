import CryptoKit
import XCTest
@testable import Amber

/// 配对码与配对表。
final class RemotePairingTests: XCTestCase {

    /// 已知向量，用 Python 的 `hashlib.md5` 算的：
    ///
    ///     m = hashlib.md5(); m.update(b'0000000000000001')
    ///     for c in '1234': m.update(c.encode()); m.update(b'\x00')
    ///     m.hexdigest().upper()  # 690E6FF61E0D7C747654A42AED17047D
    func testPairingCodeMatchesKnownVector() {
        XCTAssertEqual(RemotePairing.pairingCode(pairID: "0000000000000001", pin: "1234"),
                       "690E6FF61E0D7C747654A42AED17047D")
        XCTAssertEqual(RemotePairing.pairingCode(pairID: "0000000000000001", pin: "0000"),
                       "75D809650423A40091193AA4944D1FBD")
    }

    /// PIN 是逐位「ASCII + NUL」，不是整串一次喂进去——两者算出来不一样，
    /// 写错的话表现是「密码永远不对」。
    func testPinDigitsAreNulSeparated() {
        let correct = RemotePairing.pairingCode(pairID: "0000000000000001", pin: "1234")
        let naive = { () -> String in
            var md5 = Insecure.MD5()
            md5.update(data: Data("0000000000000001".utf8))
            md5.update(data: Data("1234".utf8))
            return md5.finalize().hexString(uppercase: true)
        }()
        XCTAssertNotEqual(correct, naive)
    }

    func testPinValidation() {
        XCTAssertTrue(RemotePairing.isValidPIN("0000"))
        XCTAssertFalse(RemotePairing.isValidPIN("123"))
        XCTAssertFalse(RemotePairing.isValidPIN("12345"))
        XCTAssertFalse(RemotePairing.isValidPIN("12a4"))
    }

    func testRandomLibraryIDIs16Hex() {
        let id = RemotePairing.randomLibraryID()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isLowercase })
    }

    // MARK: 配对表

    private func device(_ guid: String, name: String = "iPhone") -> PairedRemote {
        PairedRemote(guid: guid, name: name, deviceType: "iPhone", pairedAt: Date())
    }

    @MainActor
    func testAddAndPersist() {
        let storage = MemoryPairingStorage()
        let store = RemotePairingStore(storage: storage)
        store.add(device("0102030405060708"))
        XCTAssertEqual(store.devices.count, 1)

        // 换一个 store 从同一份存储读回来
        let reloaded = RemotePairingStore(storage: storage)
        XCTAssertEqual(reloaded.devices.map(\.guid), ["0102030405060708"])
    }

    @MainActor
    func testSameGuidOverwritesInsteadOfDuplicating() {
        let store = RemotePairingStore(storage: MemoryPairingStorage())
        store.add(device("0102030405060708", name: "旧名字"))
        store.add(device("0102030405060708", name: "新名字"))
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.name, "新名字")
    }

    /// 手机发上来的 guid 带 `0x` 前缀、可能是小写、可能省掉前导零。
    @MainActor
    func testContainsNormalizesGuid() {
        let store = RemotePairingStore(storage: MemoryPairingStorage())
        store.add(device("00ABCDEF00000001"))
        XCTAssertTrue(store.contains(guid: "0x00abcdef00000001"))
        XCTAssertTrue(store.contains(guid: "0xABCDEF00000001"))    // 前导零省掉
        XCTAssertTrue(store.contains(guid: "00ABCDEF00000001"))
        XCTAssertFalse(store.contains(guid: "0x00ABCDEF00000002"))
    }

    @MainActor
    func testForgetAllClearsStorage() {
        let storage = MemoryPairingStorage()
        let store = RemotePairingStore(storage: storage)
        store.add(device("0102030405060708"))
        store.removeAll()
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(storage.load())
        XCTAssertTrue(RemotePairingStore(storage: storage).devices.isEmpty)
    }
}
