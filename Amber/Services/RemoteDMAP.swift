import Foundation

// MARK: - DMAP

/// DMAP（Digital Media Access Protocol）——iTunes / Music 与 iOS「遥控」App 之间
/// 所有请求与应答的载荷格式。结构极简：
///
///     4 字节 ASCII tag ‖ 4 字节大端长度 ‖ 载荷
///
/// 容器的载荷就是子节点首尾相接；字符串是 UTF-8，整数大端，
/// `version` 是「主 u16 ‖ 次 u8 ‖ 修订 u8」，`date` 是 u32 的 Unix 秒。
///
/// **出处**：苹果没有公开规范。这套编码是社区实现的共识，本文件按多份开源实现
/// （DAAP/DACP 的公开文档、owntone 一系）落地。字节格式本身在各实现之间完全一致，
/// 可以当事实；**具体某个字段该填什么值**才是推断，逐条标 `[推]`，
/// 汇总见 `RemoteControlServer` 顶上的说明。
enum DMAPType: UInt16 {
    case byte = 1, ubyte = 2, short = 3, ushort = 4
    case int = 5, uint = 6, long = 7, ulong = 8
    case string = 9, date = 10, version = 11, container = 12
}

/// 一个 DMAP 节点的值。`container` 用数组天然打断递归，不需要`indirect`。
enum DMAPValue {
    case container([DMAPNode])
    case string(String)
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)
    case u64(UInt64)
    /// 主 / 次 / 修订。`mpro 2.0.0` 的四个字节就是`00 02 00 00`。
    case version(UInt16, UInt8, UInt8)
    case date(Date)
    case data(Data)
}

struct DMAPNode {
    let code: String
    let value: DMAPValue

    init(_ code: String, _ value: DMAPValue) {
        self.code = code
        self.value = value
    }

    // 常用构造的糖，省得每处都写 `.u32(...)`
    static func container(_ code: String, _ children: [DMAPNode]) -> DMAPNode {
        DMAPNode(code, .container(children))
    }
    static func string(_ code: String, _ value: String) -> DMAPNode {
        DMAPNode(code, .string(value))
    }
    static func u8(_ code: String, _ value: UInt8) -> DMAPNode { DMAPNode(code, .u8(value)) }
    static func u16(_ code: String, _ value: UInt16) -> DMAPNode { DMAPNode(code, .u16(value)) }
    static func u32(_ code: String, _ value: UInt32) -> DMAPNode { DMAPNode(code, .u32(value)) }
    static func u64(_ code: String, _ value: UInt64) -> DMAPNode { DMAPNode(code, .u64(value)) }
}

// MARK: - 编码

extension DMAPValue {
    /// 本值的字节（不含 tag 与长度头）。
    var payload: Data {
        switch self {
        case .container(let children):
            var out = Data()
            for child in children { out.append(child.encoded) }
            return out
        case .string(let s):
            return Data(s.utf8)
        case .u8(let v):
            return Data([v])
        case .u16(let v):
            return Data([UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
        case .u32(let v):
            return DMAPValue.bigEndian(UInt64(v), byteCount: 4)
        case .u64(let v):
            return DMAPValue.bigEndian(v, byteCount: 8)
        case .version(let major, let minor, let patch):
            return Data([UInt8(truncatingIfNeeded: major >> 8),
                         UInt8(truncatingIfNeeded: major), minor, patch])
        case .date(let d):
            return DMAPValue.bigEndian(UInt64(UInt32(max(0, d.timeIntervalSince1970))), byteCount: 4)
        case .data(let d):
            return d
        }
    }

    private static func bigEndian(_ value: UInt64, byteCount: Int) -> Data {
        var out = Data(count: byteCount)
        for i in 0..<byteCount {
            out[i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (byteCount - 1 - i)))
        }
        return out
    }
}

extension DMAPNode {
    /// 完整的一个节点：tag ‖ 大端长度 ‖ 载荷。
    var encoded: Data {
        let body = value.payload
        var out = Data()
        // tag 必须正好 4 个 ASCII 字符；不足补空格、超出截断，免得写出一份长度对不上的流。
        var tag = Array(code.utf8)
        if tag.count > 4 { tag = Array(tag.prefix(4)) }
        while tag.count < 4 { tag.append(0x20) }
        out.append(contentsOf: tag)
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24),
                                UInt8(truncatingIfNeeded: n >> 16),
                                UInt8(truncatingIfNeeded: n >> 8),
                                UInt8(truncatingIfNeeded: n)])
        out.append(body)
        return out
    }
}

// MARK: - 解码

/// 解出来的一个节点。解码器不认识值类型（同一段字节到底是 u32 还是 4 字节字符串，
/// 只有内容码表知道），所以原样保留载荷，取值时由调用方决定怎么读。
struct DMAPRawNode {
    let code: String
    let payload: Data
    let children: [DMAPRawNode]

    var stringValue: String { String(data: payload, encoding: .utf8) ?? "" }

    /// 大端无符号整数（1/2/4/8 字节都行）。超过 8 字节按前 8 字节算。
    var uintValue: UInt64 {
        var v: UInt64 = 0
        for byte in payload.prefix(8) { v = (v << 8) | UInt64(byte) }
        return v
    }

    /// 大写十六进制。配对 GUID（`cmpg`，8 字节）就用这个转成 16 位 hex。
    var hexValue: String {
        payload.map { String(format: "%02X", $0) }.joined()
    }

    /// 直接子节点里第一个叫 `code` 的。
    func child(_ code: String) -> DMAPRawNode? {
        children.first { $0.code == code }
    }

    /// 整棵子树里第一个叫 `code` 的（含自己）。
    func find(_ code: String) -> DMAPRawNode? {
        if self.code == code { return self }
        for child in children {
            if let hit = child.find(code) { return hit }
        }
        return nil
    }
}

enum DMAPDecoder {

    /// 把一段 DMAP 流解成节点数组。`containers` 指明哪些码是容器——解码器只能靠码表
    /// 判断该不该往里递归，猜不出来（容器的载荷和一段二进制数据长得一模一样）。
    static func parse(_ data: Data,
                      containers: Set<String> = DMAPCodes.containerCodes) -> [DMAPRawNode] {
        let bytes = [UInt8](data)
        return parse(bytes, from: 0, to: bytes.count, containers: containers)
    }

    static func find(_ code: String, in data: Data,
                     containers: Set<String> = DMAPCodes.containerCodes) -> DMAPRawNode? {
        for node in parse(data, containers: containers) {
            if let hit = node.find(code) { return hit }
        }
        return nil
    }

    private static func parse(_ bytes: [UInt8], from start: Int, to end: Int,
                              containers: Set<String>) -> [DMAPRawNode] {
        var nodes: [DMAPRawNode] = []
        var i = start
        while i + 8 <= end {
            guard let code = String(bytes: bytes[i..<(i + 4)], encoding: .ascii) else { break }
            let length = (Int(bytes[i + 4]) << 24) | (Int(bytes[i + 5]) << 16)
                | (Int(bytes[i + 6]) << 8) | Int(bytes[i + 7])
            let bodyStart = i + 8
            // 长度头坏了就整段停下：宁可少解一截，也不要顺着一个错长度乱走。
            guard length >= 0, bodyStart + length <= end else { break }
            let bodyEnd = bodyStart + length
            let children = containers.contains(code)
                ? parse(bytes, from: bodyStart, to: bodyEnd, containers: containers)
                : []
            nodes.append(DMAPRawNode(code: code,
                                     payload: Data(bytes[bodyStart..<bodyEnd]),
                                     children: children))
            i = bodyEnd
        }
        return nodes
    }
}

// MARK: - 内容码表

/// Amber 会发出或读入的那些内容码。两个用处：
/// ① 解码时判断哪些是容器；② `/content-codes` 要把这张表原样报给客户端。
///
/// 只列本实现用得到的。名字沿用 DAAP 的公开命名（`dmap.status` 这种），
/// 遥控 App 自己内建了全表，我们报的这份主要是给 DAAP 通用客户端看的。
enum DMAPCodes {

    struct Entry {
        let name: String
        let type: DMAPType
    }

    static let table: [String: Entry] = [
        // dmap 基础
        "mstt": Entry(name: "dmap.status", type: .uint),
        "miid": Entry(name: "dmap.itemid", type: .uint),
        "mper": Entry(name: "dmap.persistentid", type: .ulong),
        "minm": Entry(name: "dmap.itemname", type: .string),
        "mimc": Entry(name: "dmap.itemcount", type: .uint),
        "mctc": Entry(name: "dmap.containercount", type: .uint),
        "mrco": Entry(name: "dmap.returnedcount", type: .uint),
        "mtco": Entry(name: "dmap.specifiedtotalcount", type: .uint),
        "muty": Entry(name: "dmap.updatetype", type: .ubyte),
        "mlcl": Entry(name: "dmap.listing", type: .container),
        "mlit": Entry(name: "dmap.listingitem", type: .container),
        "mlog": Entry(name: "dmap.loginresponse", type: .container),
        "mlid": Entry(name: "dmap.sessionid", type: .uint),
        "mupd": Entry(name: "dmap.updateresponse", type: .container),
        "musr": Entry(name: "dmap.serverrevision", type: .uint),
        "msrv": Entry(name: "dmap.serverinforesponse", type: .container),
        "mpro": Entry(name: "dmap.protocolversion", type: .version),
        "apro": Entry(name: "daap.protocolversion", type: .version),
        "mslr": Entry(name: "dmap.loginrequired", type: .ubyte),
        "msal": Entry(name: "dmap.supportsautologout", type: .ubyte),
        "mstm": Entry(name: "dmap.timeoutinterval", type: .uint),
        "msdc": Entry(name: "dmap.databasescount", type: .uint),
        "msup": Entry(name: "dmap.supportsupdate", type: .ubyte),
        "mspi": Entry(name: "dmap.supportspersistentids", type: .ubyte),
        "msex": Entry(name: "dmap.supportsextensions", type: .ubyte),
        "msbr": Entry(name: "dmap.supportsbrowse", type: .ubyte),
        "msqy": Entry(name: "dmap.supportsquery", type: .ubyte),
        "msix": Entry(name: "dmap.supportsindex", type: .ubyte),
        "msrs": Entry(name: "dmap.supportsresolve", type: .ubyte),
        "msas": Entry(name: "dmap.authenticationschemes", type: .ubyte),
        "msau": Entry(name: "dmap.authenticationmethod", type: .ubyte),
        "mccr": Entry(name: "dmap.contentcodesresponse", type: .container),
        "mdcl": Entry(name: "dmap.dictionary", type: .container),
        "mcnm": Entry(name: "dmap.contentcodesnumber", type: .uint),
        "mcna": Entry(name: "dmap.contentcodesname", type: .string),
        "mcty": Entry(name: "dmap.contentcodestype", type: .ushort),
        // daap 库
        "avdb": Entry(name: "daap.serverdatabases", type: .container),
        "aply": Entry(name: "daap.databaseplaylists", type: .container),
        "adbs": Entry(name: "daap.databasesongs", type: .container),
        "abro": Entry(name: "daap.databasebrowse", type: .container),
        "abpl": Entry(name: "daap.baseplaylist", type: .ubyte),
        "asai": Entry(name: "daap.songalbumid", type: .ulong),
        "asal": Entry(name: "daap.songalbum", type: .string),
        "asar": Entry(name: "daap.songartist", type: .string),
        // dacp 播放状态与控制
        "cmst": Entry(name: "dmcp.playstatus", type: .container),
        "cmsr": Entry(name: "dmcp.serverrevision", type: .uint),
        "caps": Entry(name: "dacp.playerstate", type: .ubyte),
        "cash": Entry(name: "dacp.shufflestate", type: .ubyte),
        "carp": Entry(name: "dacp.repeatstate", type: .ubyte),
        "cavc": Entry(name: "dacp.volumecontrollable", type: .ubyte),
        "caas": Entry(name: "dacp.albumshuffle", type: .uint),
        "caar": Entry(name: "dacp.albumrepeat", type: .uint),
        "canp": Entry(name: "dacp.nowplayingids", type: .version),
        "cann": Entry(name: "dacp.nowplayingtrack", type: .string),
        "cana": Entry(name: "dacp.nowplayingartist", type: .string),
        "canl": Entry(name: "dacp.nowplayingalbum", type: .string),
        "cang": Entry(name: "dacp.nowplayinggenre", type: .string),
        "cant": Entry(name: "dacp.remainingtime", type: .uint),
        "cast": Entry(name: "dacp.tracklength", type: .uint),
        "cmmk": Entry(name: "dmcp.mediakind", type: .uint),
        "casu": Entry(name: "dacp.su", type: .ubyte),
        "caov": Entry(name: "dacp.visualizerstate", type: .ubyte),
        "cmgt": Entry(name: "dmcp.getpropertyresponse", type: .container),
        "cmvo": Entry(name: "dmcp.volume", type: .uint),
        "caci": Entry(name: "dacp.controlint", type: .container),
        "cmik": Entry(name: "dmcp.ik", type: .ubyte),
        "cmsp": Entry(name: "dmcp.sp", type: .ubyte),
        "cmsv": Entry(name: "dmcp.sv", type: .ubyte),
        "cass": Entry(name: "dacp.ss", type: .ubyte),
        "cmpa": Entry(name: "dacp.pairingcontainer", type: .container),
        "cmpg": Entry(name: "dacp.pairingguid", type: .ulong),
        "cmnm": Entry(name: "dacp.devicename", type: .string),
        "cmty": Entry(name: "dacp.devicetype", type: .string),
    ]

    /// 解码器要往里递归的那些码。
    static let containerCodes: Set<String> = Set(
        table.filter { $0.value.type == .container }.map(\.key))

    /// `/content-codes` 的应答体。
    static func contentCodesResponse() -> DMAPNode {
        var children: [DMAPNode] = [.u32("mstt", 200)]
        for code in table.keys.sorted() {
            guard let entry = table[code] else { continue }
            children.append(.container("mdcl", [
                // mcnm 名义上是 uint，装的其实就是那四个字符的字节
                DMAPNode("mcnm", .data(Data(code.utf8))),
                .string("mcna", entry.name),
                .u16("mcty", entry.type.rawValue),
            ]))
        }
        return .container("mccr", children)
    }
}
