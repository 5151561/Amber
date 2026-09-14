import Foundation

// MARK: - M4A / MP4

/// 就地给 ISO BMFF（m4a / mp4）写 `moov/udta/meta/ilst`。
///
/// 为什么自己拼 box，而不是让 `AVAssetExportSession` 带 `metadata` 重导一遍：导出会**重新封装**
/// 整个文件——AAC 的 `iTunSMPB`（编码器填充信息，无缝播放靠它）会被换成导出器自己算的一份，
/// 还要把整首歌重新过一遍写入管线。我们要动的只有 `moov` 里那几百字节，其余原样搬运。
///
/// 参考规范：ISO/IEC 14496-12（box 结构、`meta` 是 full box、`stco`/`co64` 存的是**文件绝对偏移**）。
/// `ilst` 那一层不在公开规范里，按 iTunes 的既成写法：每个标签是一个以标签名为 box 类型的容器，
/// 里面套一个 `data` box（4 字节 well-known type + 4 字节 locale + 正文）。
enum MP4TagWriter {

    /// 搬运 `mdat` 用的块大小。一首歌几十上百 MB，绝不能整块读进内存。
    private static let copyChunk = 1 << 20  // 1 MiB

    /// `moov` 会整块读进内存改，给个上限兜底：正常一首歌的 moov 是几十 KB 到几百 KB，
    /// 超过 64 MiB 基本可以断定是把 box 长度读错了。
    private static let moovSizeLimit: UInt64 = 64 << 20

    nonisolated static func write(_ tags: AudioTags, to url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let top = try topLevelBoxes(handle, fileSize: fileSize)

        // 分片 MP4 的样本偏移在 `moof/traf/trun` 里，还可能带 `sidx` 索引偏移，
        // 改 moov 长度会把那一整套算错。这条路不趟，交给上层当「这份文件没法带标签」。
        if let fragment = top.first(where: { $0.type == "moof" || $0.type == "sidx" }) {
            throw AudioTagWriteError.unsupported("分片 MP4（顶层有 \(fragment.type)）")
        }
        guard let moovBox = top.first(where: { $0.type == "moov" }) else {
            throw AudioTagWriteError.malformed("顶层没有 moov box")
        }
        guard moovBox.size <= moovSizeLimit else {
            throw AudioTagWriteError.malformed("moov 长度 \(moovBox.size) 不合常理")
        }

        try handle.seek(toOffset: moovBox.offset)
        guard let oldMoov = try handle.read(upToCount: Int(moovBox.size)),
              oldMoov.count == Int(moovBox.size) else {
            throw AudioTagWriteError.malformed("moov 被截断")
        }

        var newMoov = try rewriteMoov(oldMoov, tags: tags)
        let delta = Int64(newMoov.count) - Int64(oldMoov.count)
        if delta != 0 {
            // `stco`/`co64` 存的是**文件绝对偏移**：moov 一变长，排在它后面的 mdat 整体后移，
            // 那些偏移必须跟着挪。实测 QQ 的 m4a 是 mdat 在前 moov 在后（偏移都小于 moov 起点，
            // 一个都不用动），但网易云和自己转码出来的文件常常是 moov 在前，不能只按前一种写。
            try shiftChunkOffsets(in: &newMoov, delta: delta, movedFrom: moovBox.offset)
        }
        if delta == 0, newMoov == oldMoov { return }  // 标签本来就一模一样，别白搬一遍文件

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".am-tag-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try handle.seek(toOffset: 0)
            try copy(handle, count: moovBox.offset, to: output)
            try output.write(contentsOf: newMoov)
            try handle.seek(toOffset: moovBox.offset + moovBox.size)
            try copy(handle, count: fileSize - (moovBox.offset + moovBox.size), to: output)
            try output.close()
            // 原子替换：中途断电／被杀也不会留下半个文件（原文件要么是旧的要么是新的）
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: - box 结构

    private struct TopBox {
        let type: String
        let offset: UInt64
        let size: UInt64
    }

    /// 一个完整的子 box（含头），原样留着——不认识的 atom 要能字节级原封不动地写回去。
    private struct Child {
        let type: String
        let body: Data
    }

    private static func topLevelBoxes(_ handle: FileHandle, fileSize: UInt64) throws -> [TopBox] {
        var boxes: [TopBox] = []
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let type = fourCCString(header, 4)
            var size = UInt64(be32(header, 0))
            if size == 1 {
                // 64 位长度：真正的长度在头后面那 8 字节里（largesize）
                guard header.count >= 16 else { throw AudioTagWriteError.malformed("largesize 被截断") }
                size = be64(header, 8)
                guard size >= 16 else { throw AudioTagWriteError.malformed("largesize \(size) 太小") }
            } else if size == 0 {
                // 长度 0 = 这个 box 一直延伸到文件尾（只可能是最后一个）
                size = fileSize - offset
            }
            guard size >= 8, offset + size <= fileSize else {
                throw AudioTagWriteError.malformed("box \(type) 长度 \(size) 越界")
            }
            boxes.append(TopBox(type: type, offset: offset, size: size))
            offset += size
        }
        guard !boxes.isEmpty else { throw AudioTagWriteError.malformed("解析不出任何顶层 box") }
        return boxes
    }

    /// 把一个完整 box 拆成「类型 + 正文」。正文是新拷的 Data，索引从 0 开始。
    private static func split(_ box: Data) throws -> (type: String, payload: Data) {
        guard box.count >= 8 else { throw AudioTagWriteError.malformed("box 不足 8 字节") }
        let type = fourCCString(box, 4)
        var size = Int(be32(box, 0))
        var header = 8
        if size == 1 {
            guard box.count >= 16 else { throw AudioTagWriteError.malformed("largesize 被截断") }
            size = Int(be64(box, 8))
            header = 16
        } else if size == 0 {
            size = box.count
        }
        guard size >= header, size <= box.count else {
            throw AudioTagWriteError.malformed("box \(type) 长度 \(size) 越界")
        }
        let base = box.startIndex
        return (type, Data(box[(base + header)..<(base + size)]))
    }

    /// 顺着一段容器正文切出它的子 box。
    private static func children(inPayload payload: Data) throws -> [Child] {
        var result: [Child] = []
        var index = 0
        while index + 8 <= payload.count {
            var size = Int(be32(payload, index))
            var header = 8
            if size == 1 {
                guard index + 16 <= payload.count else {
                    throw AudioTagWriteError.malformed("largesize 被截断")
                }
                size = Int(be64(payload, index + 8))
                header = 16
            } else if size == 0 {
                size = payload.count - index
            }
            guard size >= header, index + size <= payload.count else {
                throw AudioTagWriteError.malformed("子 box 长度 \(size) 越界")
            }
            let base = payload.startIndex
            result.append(Child(type: fourCCString(payload, index + 4),
                                body: Data(payload[(base + index)..<(base + index + size)])))
            index += size
        }
        return result
    }

    private static func makeBox(_ type: String, _ payload: Data) -> Data {
        var box = Data(capacity: payload.count + 8)
        box.appendBE32(UInt32(payload.count + 8))
        box.append(fourCC(type))
        box.append(payload)
        return box
    }

    private static func rebuild(_ type: String, _ children: [Child], prefix: Data = Data()) -> Data {
        var payload = prefix
        for child in children { payload.append(child.body) }
        return makeBox(type, payload)
    }

    // MARK: - moov → udta → meta → ilst

    private static func rewriteMoov(_ moov: Data, tags: AudioTags) throws -> Data {
        let (_, payload) = try split(moov)
        var kids = try children(inPayload: payload)
        let index = kids.firstIndex { $0.type == "udta" }
        let oldUdta = index.map { kids[$0].body }
        let newUdta = Child(type: "udta", body: try rewriteUdta(oldUdta, tags: tags))
        if let index {
            kids[index] = newUdta
        } else {
            kids.append(newUdta)  // 规范里 udta 就该在 moov 末尾
        }
        return rebuild("moov", kids)
    }

    private static func rewriteUdta(_ udta: Data?, tags: AudioTags) throws -> Data {
        var kids = udta == nil ? [] : try children(inPayload: try split(udta!).payload)
        let index = kids.firstIndex { $0.type == "meta" }
        let newMeta = Child(type: "meta", body: try rewriteMeta(index.map { kids[$0].body },
                                                               tags: tags))
        if let index { kids[index] = newMeta } else { kids.append(newMeta) }
        return rebuild("udta", kids)
    }

    /// `meta` 是 full box：正文开头有 4 字节 version+flags，之后才是子 box。
    ///
    /// 但 QuickTime 那一支的 `meta` 没有这 4 字节（子 box 直接开始）。判定靠头 4 字节：
    /// full box 那 4 字节是 version=0 flags=0，全零；非 full box 那里是第一个子 box 的长度，
    /// 不可能是 0。已有的是哪种就保持哪种，别把人家的结构改了；新建的一律写成 full box。
    private static func rewriteMeta(_ meta: Data?, tags: AudioTags) throws -> Data {
        var prefix = Data([0, 0, 0, 0])
        var kids: [Child] = []
        if let meta {
            let payload = try split(meta).payload
            let base = payload.startIndex
            let isFullBox = payload.count >= 4 && payload[base..<(base + 4)].allSatisfy { $0 == 0 }
            prefix = isFullBox ? Data(payload[base..<(base + 4)]) : Data()
            kids = try children(inPayload: isFullBox ? Data(payload[(base + 4)...]) : payload)
        }

        // handler 必须是 `mdir`，否则 iTunes / AVFoundation 根本不去看这个 meta 里的 ilst。
        // reserved 头一格写 `appl` 是 iTunes 的既成写法，各家解析器都按这份样子认。
        if !kids.contains(where: { $0.type == "hdlr" && handlerType(of: $0.body) == "mdir" }) {
            var body = Data()
            body.appendBE32(0)              // version + flags
            body.appendBE32(0)              // pre_defined
            body.append(fourCC("mdir"))     // handler_type
            body.append(fourCC("appl"))     // reserved[0]
            body.appendBE32(0)              // reserved[1]
            body.appendBE32(0)              // reserved[2]
            body.append(0)                  // name（空串）
            let hdlr = Child(type: "hdlr", body: makeBox("hdlr", body))
            if let index = kids.firstIndex(where: { $0.type == "hdlr" }) {
                kids[index] = hdlr
            } else {
                kids.insert(hdlr, at: 0)    // hdlr 必须排在 ilst 前面
            }
        }

        let index = kids.firstIndex { $0.type == "ilst" }
        let newIlst = Child(type: "ilst", body: try rewriteIlst(index.map { kids[$0].body },
                                                               tags: tags))
        if let index { kids[index] = newIlst } else { kids.append(newIlst) }
        return rebuild("meta", kids, prefix: prefix)
    }

    private static func handlerType(of hdlr: Data) -> String? {
        guard let payload = try? split(hdlr).payload, payload.count >= 12 else { return nil }
        return fourCCString(payload, 8)
    }

    /// 合并 ilst：我们写的那几个整条替换（同名的多份只留一份），其余原样保留。
    ///
    /// 「保留」这条不是客气：QQ 落地的 m4a 里就那一条 `----`/`iTunSMPB`，是 AAC 编码器的
    /// 前后填充样本数，播放器靠它做无缝拼接，丢了这首歌前后会多出几十毫秒静音。
    private static func rewriteIlst(_ ilst: Data?, tags: AudioTags) throws -> Data {
        let produced = atoms(for: tags)
        let producedTypes = Set(produced.map(\.type))
        var emitted = Set<String>()
        var kids: [Child] = []

        for child in (ilst == nil ? [] : try children(inPayload: try split(ilst!).payload)) {
            guard producedTypes.contains(child.type) else { kids.append(child); continue }
            guard !emitted.contains(child.type) else { continue }  // 同名的重复份直接丢
            emitted.insert(child.type)
            kids.append(produced.first { $0.type == child.type }!)
        }
        for atom in produced where !emitted.contains(atom.type) { kids.append(atom) }
        return rebuild("ilst", kids)
    }

    /// 按 `AudioTags` 拼出要写进 ilst 的那几个 atom。顺序照 iTunes 的习惯排。
    private static func atoms(for tags: AudioTags) -> [Child] {
        var result: [Child] = []
        func text(_ type: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            result.append(Child(type: type, body: dataAtom(type, wellKnown: 1,
                                                           value: Data(value.utf8))))
        }
        text("\u{A9}nam", tags.title)
        text("\u{A9}ART", tags.artist)
        text("aART", tags.albumArtist)
        text("\u{A9}alb", tags.album)
        text("\u{A9}gen", tags.genre)
        text("\u{A9}day", tags.year)
        // `trkn`/`disk` 的 data 是二进制（well-known type 0），8 字节：
        // reserved(2) | 序号(2) | 总数(2) | reserved(2)。总数不知道就写 0。
        if let number = tags.trackNumber {
            result.append(Child(type: "trkn",
                                body: dataAtom("trkn", wellKnown: 0,
                                               value: pair(number, tags.trackTotal))))
        }
        if let number = tags.discNumber {
            result.append(Child(type: "disk",
                                body: dataAtom("disk", wellKnown: 0,
                                               value: pair(number, tags.discTotal))))
        }
        text("\u{A9}lyr", tags.lyrics)
        if let artwork = tags.artwork, !artwork.isEmpty {
            // 封面的 well-known type 直接是图片格式：JPEG=13、PNG=14。
            // MIME 认不出来时按字节判，判不出就按 JPEG（iTunes 的默认）。
            let isPNG = tags.artworkMIME?.lowercased().contains("png") == true
                || artwork.starts(with: [0x89, 0x50, 0x4E, 0x47])
            result.append(Child(type: "covr",
                                body: dataAtom("covr", wellKnown: isPNG ? 14 : 13, value: artwork)))
        }
        return result
    }

    private static func pair(_ number: Int, _ total: Int?) -> Data {
        var data = Data()
        data.appendBE16(0)
        data.appendBE16(UInt16(clamping: number))
        data.appendBE16(UInt16(clamping: total ?? 0))
        data.appendBE16(0)
        return data
    }

    private static func dataAtom(_ type: String, wellKnown: UInt32, value: Data) -> Data {
        var inner = Data()
        inner.appendBE32(wellKnown)  // 高位 1 字节是 version(0)，低 3 字节才是类型
        inner.appendBE32(0)          // locale（country + language），一律 0
        inner.append(value)
        return makeBox(type, makeBox("data", inner))
    }

    // MARK: - chunk 偏移修正

    /// 把 `moov` 里所有指向 `threshold` 之后的 chunk 偏移加上 `delta`。
    ///
    /// 只改「指向 moov 起点之后」的那些：moov 在 mdat 后面时样本数据一个字节没动，
    /// 偏移当然也不该动；moov 在前时 mdat 整体后移 delta，偏移就得跟着走。
    private static func shiftChunkOffsets(in moov: inout Data, delta: Int64,
                                          movedFrom threshold: UInt64) throws {
        try walk(&moov, range: 0..<moov.count, delta: delta, threshold: threshold, depth: 0)
    }

    /// 只往 `moov/trak/mdia/minf/stbl` 这条链上钻——别的容器里不会有 chunk 偏移表。
    private static let offsetTableParents: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    private static func walk(_ data: inout Data, range: Range<Int>, delta: Int64,
                             threshold: UInt64, depth: Int) throws {
        guard depth < 8 else { return }
        var index = range.lowerBound
        while index + 8 <= range.upperBound {
            var size = Int(be32(data, index))
            var header = 8
            if size == 1 {
                guard index + 16 <= range.upperBound else { return }
                size = Int(be64(data, index + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - index
            }
            guard size >= header, index + size <= range.upperBound else { return }
            let type = fourCCString(data, index + 4)
            let payload = (index + header)..<(index + size)
            if offsetTableParents.contains(type) {
                try walk(&data, range: payload, delta: delta, threshold: threshold, depth: depth + 1)
            } else if type == "stco" || type == "co64" {
                try patchOffsets(&data, payload: payload, wide: type == "co64",
                                 delta: delta, threshold: threshold)
            }
            index += size
        }
    }

    private static func patchOffsets(_ data: inout Data, payload: Range<Int>, wide: Bool,
                                     delta: Int64, threshold: UInt64) throws {
        guard payload.count >= 8 else { throw AudioTagWriteError.malformed("stco 正文不足 8 字节") }
        let count = Int(be32(data, payload.lowerBound + 4))  // 前 4 字节是 version+flags
        let width = wide ? 8 : 4
        guard payload.lowerBound + 8 + count * width <= payload.upperBound else {
            throw AudioTagWriteError.malformed("chunk 偏移表条数 \(count) 与 box 长度对不上")
        }
        for entry in 0..<count {
            let at = payload.lowerBound + 8 + entry * width
            let old = wide ? be64(data, at) : UInt64(be32(data, at))
            guard old >= threshold else { continue }
            let updated = Int64(old) + delta
            guard updated >= 0 else { throw AudioTagWriteError.malformed("chunk 偏移修正后为负") }
            if wide {
                data.replaceBE64(at, UInt64(updated))
            } else {
                guard updated <= Int64(UInt32.max) else {
                    // 32 位放不下就得把 stco 升级成 co64，那会再次改变 moov 长度、要迭代收敛。
                    // 只有 4 GiB 以上的文件才会碰到，不值得为它把流程复杂化。
                    throw AudioTagWriteError.unsupported("chunk 偏移超出 32 位，需要 co64")
                }
                data.replaceBE32(at, UInt32(updated))
            }
        }
    }

    // MARK: - 字节工具

    private static func copy(_ source: FileHandle, count: UInt64, to destination: FileHandle) throws {
        var left = count
        while left > 0 {
            let want = Int(min(left, UInt64(copyChunk)))
            guard let chunk = try source.read(upToCount: want), !chunk.isEmpty else {
                throw AudioTagWriteError.malformed("搬运时文件提前结束")
            }
            try destination.write(contentsOf: chunk)
            left -= UInt64(chunk.count)
        }
    }

    /// box 类型是 4 个**字节**，`©nam` 里那个 © 是单字节 0xA9（不是 UTF-8 的两字节）。
    /// 所以类型串一律按 Latin-1 在字节和字符串之间来回换。
    private static func fourCC(_ type: String) -> Data {
        let data = type.data(using: .isoLatin1) ?? Data()
        return data.count == 4 ? data : Data(repeating: 0x20, count: 4)
    }

    private static func fourCCString(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return "" }
        return String(data: Data(data[base..<(base + 4)]), encoding: .isoLatin1) ?? ""
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return 0 }
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(be32(data, offset)) << 32 | UInt64(be32(data, offset + 4))
    }
}

extension Data {
    fileprivate mutating func appendBE16(_ value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    fileprivate mutating func appendBE32(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * (3 - $0))) })
    }

    fileprivate mutating func replaceBE32(_ offset: Int, _ value: UInt32) {
        let base = startIndex + offset
        for byte in 0..<4 { self[base + byte] = UInt8(truncatingIfNeeded: value >> (8 * (3 - byte))) }
    }

    fileprivate mutating func replaceBE64(_ offset: Int, _ value: UInt64) {
        let base = startIndex + offset
        for byte in 0..<8 { self[base + byte] = UInt8(truncatingIfNeeded: value >> (8 * (7 - byte))) }
    }
}
