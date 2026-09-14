import XCTest
@testable import Amber

/// DMAP 编解码。字节布局是这条路上唯一「一个 bit 都不能错」的地方——
/// 长度头写歪了对方就顺着错长度乱走，表现是遥控器整个连不上而不是某一项显示错。
final class RemoteDMAPTests: XCTestCase {

    func testNodeLayoutIsTagLengthPayload() {
        let node = DMAPNode.u32("mstt", 200)
        let bytes = [UInt8](node.encoded)
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(Array(bytes[0..<4]), Array("mstt".utf8))
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 4])          // 大端长度
        XCTAssertEqual(Array(bytes[8..<12]), [0, 0, 0, 200])       // 大端值
    }

    func testVersionIsMajorU16PlusMinorAndPatch() {
        let bytes = [UInt8](DMAPNode("mpro", .version(2, 0, 0)).encoded)
        XCTAssertEqual(Array(bytes[8...]), [0, 2, 0, 0])
    }

    func testContainerLengthCoversAllChildren() {
        let node = DMAPNode.container("mlog", [.u32("mstt", 200), .u32("mlid", 7)])
        let bytes = [UInt8](node.encoded)
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 24])   // 两个 12 字节子节点
        XCTAssertEqual(bytes.count, 32)
    }

    func testRoundTripAcrossTypes() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let tree = DMAPNode.container("msrv", [
            .u32("mstt", 200),
            .string("minm", "我的电脑"),
            .u8("mslr", 1),
            .u16("mcty", 9),
            .u64("mper", 0x0102_0304_0506_0708),
            DMAPNode("mpro", .version(3, 1, 2)),
            DMAPNode("mstm", .date(stamp)),
            DMAPNode("canp", .data(Data([1, 2, 3, 4]))),
            .container("mlcl", [.container("mlit", [.u32("miid", 42)])]),
        ])

        let decoded = DMAPDecoder.parse(tree.encoded)
        XCTAssertEqual(decoded.count, 1)
        let root = decoded[0]
        XCTAssertEqual(root.code, "msrv")
        XCTAssertEqual(root.child("mstt")?.uintValue, 200)
        XCTAssertEqual(root.child("minm")?.stringValue, "我的电脑")
        XCTAssertEqual(root.child("mslr")?.uintValue, 1)
        XCTAssertEqual(root.child("mcty")?.uintValue, 9)
        XCTAssertEqual(root.child("mper")?.uintValue, 0x0102_0304_0506_0708)
        XCTAssertEqual(root.child("mstm")?.uintValue, 1_700_000_000)
        XCTAssertEqual(root.child("canp")?.payload, Data([1, 2, 3, 4]))
        // 容器要能递归到底
        XCTAssertEqual(root.find("miid")?.uintValue, 42)
    }

    func testHexValueIsUppercaseFixedWidth() {
        let node = DMAPNode.container("cmpa", [.u64("cmpg", 0x00AB_CDEF_0000_0001)])
        let guid = DMAPDecoder.find("cmpa", in: node.encoded)?.child("cmpg")
        XCTAssertEqual(guid?.hexValue, "00ABCDEF00000001")
    }

    /// 只有码表里登记为 container 的才递归。没登记的当二进制数据原样留着，
    /// 不能顺着它往里瞎解。
    func testUnknownCodeIsNotTreatedAsContainer() {
        let inner = DMAPNode.u32("mstt", 200).encoded
        let node = DMAPNode("xxxx", .data(inner))
        let decoded = DMAPDecoder.parse(node.encoded)
        XCTAssertEqual(decoded.first?.children.count, 0)
        XCTAssertEqual(decoded.first?.payload, inner)
    }

    func testTruncatedStreamStopsInsteadOfLooping() {
        var bytes = DMAPNode.u32("mstt", 200).encoded
        bytes.removeLast(2)   // 长度头说 4 字节，实际只剩 2
        XCTAssertTrue(DMAPDecoder.parse(bytes).isEmpty)
    }

    func testContentCodesCarriesEveryKnownCode() {
        let response = DMAPCodes.contentCodesResponse()
        let decoded = DMAPDecoder.parse(response.encoded)
        let entries = decoded.first?.children.filter { $0.code == "mdcl" } ?? []
        XCTAssertEqual(entries.count, DMAPCodes.table.count)
        // mcnm 装的就是那四个字符的字节
        let names = entries.compactMap { $0.child("mcnm")?.stringValue }
        XCTAssertTrue(names.contains("mstt"))
    }

    func testContainerCodesIncludeThePairingReply() {
        XCTAssertTrue(DMAPCodes.containerCodes.contains("cmpa"))
        XCTAssertTrue(DMAPCodes.containerCodes.contains("mlit"))
        XCTAssertFalse(DMAPCodes.containerCodes.contains("cmpg"))
    }
}
