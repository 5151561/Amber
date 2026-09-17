import Foundation
import ImageIO

/// 写进音频文件的标签。
///
/// 下载落地的是音源 CDN 的**裸流**：2026-09-09 逐个翻已下载的文件，QQ 的 m4a 里
/// `moov/udta/meta/ilst` 只有一条`----/iTunSMPB`（无缝播放的填充信息），
/// 标题 / 艺人 / 专辑 / 封面一个都没有。所以「下载」这一步之后还要按 `Track` 补写一遍，
/// 否则文件拿到 Finder、Music.app 或任何第三方播放器里都是一堆无名文件。
struct AudioTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: String?
    var genre: String?
    /// 封面的**原始字节**（JPEG / PNG），不是解码后的位图——四种容器都是把原图整块塞进去。
    var artwork: Data?
    /// 封面 MIME：`image/jpeg` 或`image/png`。
    var artworkMIME: String?
    /// 纯文本歌词（不带时间轴的那种）。没有就不写这一格。
    var lyrics: String?

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil
            && trackNumber == nil && discNumber == nil && year == nil && genre == nil
            && artwork == nil && lyrics == nil
    }
}

enum AudioTagWriteError: LocalizedError {
    /// 文件结构不是这个容器该有的样子（截断、魔数对不上、box 长度越界……）。
    case malformed(String)
    /// 认得出容器，但这个变体还没实现（例如 Ogg 里不是 Vorbis / Opus 的码流）。
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let why): return "音频文件结构异常：\(why)"
        case .unsupported(let what): return "暂不支持给这种文件写标签：\(what)"
        }
    }
}

/// 按容器把 `AudioTags` 写进已经落地的文件。
///
/// 四种容器各有各的写法，分四个文件实现；这里只按**头字节**分派
/// （容器判定复用 `DownloadStore.fileExtension(ofHeader:)`，理由见那里：
/// URL 上的扩展名是档位码约定的，降级取到别的容器时那个名字就是错的）。
/// 多的一步是：读到 `ID3` 时要先整块跳过去再看真魔数——别的工具会给 FLAC / Ogg
/// 前面加一块 ID3——那条是分派器独有的，`fileExtension(ofHeader:)` 不管（见那里的注释）。
enum AudioTagWriter {

    /// 就地给文件写标签。认不出的容器返回 `false`（**不当错误**：下载本身是成功的，
    /// 只是这份文件没法带标签，不该因此把整首歌标成下载失败）。
    @discardableResult
    nonisolated static func write(_ tags: AudioTags, to url: URL) throws -> Bool {
        guard !tags.isEmpty else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        var head = (try? handle.read(upToCount: 12)) ?? Data()
        // ID3 开头**不等于** mp3：为了让 Finder 显示封面，别的工具（Mp3tag 那类）会在
        // `fLaC` / `OggS` 前面前置一块 ID3，用户手上就有这种文件。
        // 按 header 里的 synchsafe 长度整块跳过去再看后面的魔数——不跳的话这份 FLAC
        // 会被判成 mp3 交给 `ID3TagWriter`，Vorbis comment 那份从此再也不更新。
        if let skip = ID3TagWriter.tagLength(header: head), skip > 0 {
            try? handle.seek(toOffset: UInt64(skip))
            let inner = (try? handle.read(upToCount: 12)) ?? Data()
            if ["flac", "ogg"].contains(DownloadStore.fileExtension(ofHeader: [UInt8](inner))) {
                head = inner
            }
        }
        // 写入器自己会重开文件（还要原子替换），判完就把这个只读句柄还回去。
        try? handle.close()
        switch DownloadStore.fileExtension(ofHeader: [UInt8](head)) {
        case "flac": try FLACTagWriter.write(tags, to: url)
        case "ogg": try OggTagWriter.write(tags, to: url)
        case "mp3": try ID3TagWriter.write(tags, to: url)
        case "m4a": try MP4TagWriter.write(tags, to: url)
        default: return false
        }
        return true
    }
}

// MARK: - Vorbis comment / PICTURE（FLAC 与 Ogg 共用这两段）

/// Vorbis comment 的字段表。
///
/// 字段名按 xiph.org 的 `Ogg Vorbis I format specification: comment field and header`，
/// 大写、`名字=值`、整段 UTF-8。曲序/碟序的「共几首」在 Vorbis comment 里没有
/// `TRCK` 那种`3/12` 的合并写法，是`TRACKNUMBER` + `TRACKTOTAL` 两条
/// （FLAC 官方工具 metaflac、foobar2000、MusicBrainz Picard 都是这一对），所以两条都写。
private func vorbisFields(_ tags: AudioTags) -> [(String, String)] {
    var fields: [(String, String)] = []
    func put(_ name: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        fields.append((name, value))
    }
    put("TITLE", tags.title)
    put("ARTIST", tags.artist)
    put("ALBUM", tags.album)
    put("ALBUMARTIST", tags.albumArtist)
    put("TRACKNUMBER", tags.trackNumber.map(String.init))
    put("TRACKTOTAL", tags.trackTotal.map(String.init))
    put("DISCNUMBER", tags.discNumber.map(String.init))
    put("DISCTOTAL", tags.discTotal.map(String.init))
    put("DATE", tags.year)
    put("GENRE", tags.genre)
    put("LYRICS", tags.lyrics)
    return fields
}

/// comment 正文：`u32le vendor 长度 + vendor` + `u32le 条数` + 每条`u32le 长度 + 正文`。
///
/// 长度全是**小端**——Vorbis comment 是 Ogg Vorbis 里唯一不跟 FLAC 大端对齐的一段，
/// FLAC 规范也明说这块「按 Vorbis 的字节序原样嵌入」。
private func vorbisCommentBody(vendor: String, fields: [(String, String)]) -> Data {
    var out = Data()
    let vendorBytes = Data(vendor.utf8)
    out.appendLE32(vendorBytes.count)
    out.append(vendorBytes)
    out.appendLE32(fields.count)
    for (name, value) in fields {
        let entry = Data("\(name)=\(value)".utf8)
        out.appendLE32(entry.count)
        out.append(entry)
    }
    return out
}

/// 从已有的 comment 正文里取回 vendor string。
///
/// vendor 是**编码器**的签名而不是标签，vorbiscomment / metaflac 改标签时都原样留着，
/// 我们也留着：换成 "Amber" 会让文件看起来像是我们编码的。读不出来（截断）才用兜底。
private func vorbisVendor(inCommentBody body: Data) -> String? {
    // 从前为了下标方便把整块 comment 拷成 `[UInt8]`：那一块连歌词带 base64 封面，
    // 动辄几十上百 KB，而这里要的只有开头 4 字节长度和紧跟着的那截 vendor。
    // `RawSpan` 借的是 `body` 自己的字节，一个字节都不拷；调用方传的是
    // `old.dropFirst(prefix.count)` 这种切片时它也照样从 0 起算（`Data` 的下标是绝对索引，
    // 直接换成 `body[4...]` 会读错位置，这里故意不那么写）。
    let bytes = body.bytes
    guard bytes.byteCount >= 4 else { return nil }
    // 小端 32 位。偏移 0 但 `body` 自身未必对齐，所以走不对齐读；`UInt32` 进 `Int` 恒非负，
    // 原来那条 `length >= 0` 到这里已经是恒真，跟着删掉。
    //
    // `unsafeLoadUnaligned` 不安全在它自己不查边界，读越界是未定义行为而不是 trap；
    // 谁保证它安全：紧挨着上面那条 `bytes.byteCount >= 4`。
    let length = unsafe Int(UInt32(littleEndian: bytes.unsafeLoadUnaligned(fromByteOffset: 0,
                                                                          as: UInt32.self)))
    guard bytes.byteCount >= 4 + length else { return nil }
    // 仍旧走 `String(bytes:encoding:)`：vendor 不是合法 UTF-8 时要的就是 nil、让调用方兜底，
    // `String(decoding:)` 会拿替换字符糊过去，那是另一种行为。
    return String(bytes: body.dropFirst(4).prefix(length), encoding: .utf8)
}

/// 单个 METADATA_BLOCK 的长度字段只有 3 字节，所以块正文上限 2^24−1。
private let flacMaxBlockLength = 0xFF_FFFF

/// 按 FLAC 规范拼 PICTURE 块的**正文**（不含 4 字节块头）。
///
/// 字段顺序（FLAC format spec, METADATA_BLOCK_PICTURE，全部大端）：
/// 图片类型、MIME 长度+MIME、描述长度+描述、宽、高、色深、索引色数、数据长度+数据。
/// 图片类型 3 = Front Cover。宽/高能用 ImageIO 读到就填真值，读不出来写 0——
/// 规范原文允许这几格为 0（"may be 0 if unknown"），色深/索引色数同理不去猜。
///
/// 超过单块上限时返回 `nil`：宁可不写封面，也不能写出一个长度字段装不下的块（那是坏文件）。
/// Ogg 那边的 `METADATA_BLOCK_PICTURE` 用的也是这一块（base64 之前的原始字节），共用这一个构造。
private func flacPictureBlockBody(artwork: Data, mime: String) -> Data? {
    var size = (width: 0, height: 0)
    if let source = CGImageSourceCreateWithData(artwork as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        size.width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        size.height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
    }
    let mimeBytes = Data(mime.utf8)
    var out = Data()
    out.appendBE32(3)  // Front Cover
    out.appendBE32(mimeBytes.count)
    out.append(mimeBytes)
    out.appendBE32(0)  // 描述留空
    out.appendBE32(size.width)
    out.appendBE32(size.height)
    out.appendBE32(0)  // 色深未知
    out.appendBE32(0)  // 非索引色
    out.appendBE32(artwork.count)
    out.append(artwork)
    guard out.count <= flacMaxBlockLength else { return nil }
    return out
}

/// 封面的 MIME：调用方没给就按魔数认，认不出当 JPEG（音源给的封面只有这两种）。
private func artworkMIME(_ tags: AudioTags) -> String {
    if let mime = tags.artworkMIME, !mime.isEmpty { return mime }
    let head = [UInt8]((tags.artwork ?? Data()).prefix(4))
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    return "image/jpeg"
}

private extension Data {
    mutating func appendLE32(_ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                            UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    mutating func appendBE32(_ value: Int) {
        let v = UInt32(truncatingIfNeeded: value)
        append(contentsOf: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func appendLE64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

/// 原地改写：同目录临时文件写完再 `replaceItemAt` 原子替换。
///
/// 不在原文件上就地改的理由有两个：一是标签块长度会变、整段音频得挪位置；
/// 二是写到一半掉电/被杀，用户的那首歌就废了。同目录是 `replaceItemAt` 的前提
/// （跨卷时它会退化成拷贝，音乐目录可能在外置盘上，几百 MB 拷一遍就白白慢一倍）。
private func replaceAtomically(_ url: URL, _ body: (FileHandle) throws -> Void) throws {
    let directory = url.deletingLastPathComponent()
    let temp = directory.appendingPathComponent(".am-tagwrite-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: temp.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: temp) }
    let out = try FileHandle(forWritingTo: temp)
    do {
        try body(out)
        try out.close()
    } catch {
        try? out.close()
        throw error
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
}

/// 把 `handle` 当前位置到文件末尾的内容按块拷给`out`。
///
/// 1 MiB 一块：hires FLAC 动辄几百 MB，`Data(contentsOf:)` 整首读进来就是几百 MB 常驻。
private func copyRest(from handle: FileHandle, to out: FileHandle) throws {
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        try out.write(contentsOf: chunk)
    }
}

// MARK: - FLAC

enum FLACTagWriter {

    /// 保留原有的元数据块，只换掉 VORBIS_COMMENT 与我们那张封面。写出来的是标准形状的
    /// FLAC：第一个字节就是 `fLaC`，标签只有 Vorbis comment + PICTURE 块。
    ///
    /// 块结构（FLAC format spec, METADATA_BLOCK_HEADER）：1 字节里最高位是
    /// last-metadata-block 标志、低 7 位是类型，跟着 3 字节**大端**长度。
    /// 类型 0 STREAMINFO 必须仍是第一块（解码器就按这个找采样率/声道），所以只在它后面动手。
    nonisolated static func write(_ tags: AudioTags, to url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        // 这份文件的开头可能带着一块 ID3：为了让 Finder 显示封面，别的工具会给 FLAC
        // 前置一块。整块跳过去、从 `fLaC` 读起，不然会把 ID3 当成元数据块解出一堆乱码。
        // 重写之后那块前缀自然就不在了——这是「按标准形状重排一遍」的顺带结果，
        // 不是我们主动去清理谁的文件。
        let header = (try input.read(upToCount: 10)) ?? Data()
        guard let id3Length = ID3TagWriter.tagLength(header: header) else {
            throw AudioTagWriteError.malformed("文件开头那块 ID3 的长度里有非 synchsafe 字节")
        }
        try input.seek(toOffset: UInt64(id3Length))

        guard let magic = try input.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            throw AudioTagWriteError.malformed("不是 FLAC：魔数不是 fLaC")
        }

        var kept: [(type: UInt8, body: Data)] = []
        var vendor = "Amber"
        var sawLast = false
        while !sawLast {
            guard let header = try input.read(upToCount: 4), header.count == 4 else {
                throw AudioTagWriteError.malformed("元数据块头截断")
            }
            // 块头就地读：`Span` 借 `header` 自己的四个字节，不再每块拷一个小数组出来。
            // 长度是 3 字节大端，没有 `UInt24` 能一次读出来，移位照旧；下标 0…3 由上面
            // 那条 `count == 4` 兜住——`Span` 越界是 trap 而不是返回 nil，边界得自己先验。
            let bytes = header.span
            sawLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard let body = try input.read(upToCount: length), body.count == length else {
                throw AudioTagWriteError.malformed("元数据块正文截断（类型 \(type)，声称 \(length) 字节）")
            }
            if kept.isEmpty && type != 0 {
                throw AudioTagWriteError.malformed("第一块不是 STREAMINFO")
            }
            switch type {
            case 1:
                break  // PADDING：本来就是占位，重排之后没必要留
            case 4:
                // 旧 comment：只把 vendor 取回来，内容整块换掉（否则会重复写同名字段）
                vendor = vorbisVendor(inCommentBody: body) ?? vendor
            case 6 where isFrontCover(body):
                break  // 我们自己写的那张封面，换掉而不是再追加一张
            default:
                kept.append((type, body))
            }
        }
        let audioStart = try input.offset()

        var blocks = kept
        var fields = vorbisFields(tags)
        var comment = vorbisCommentBody(vendor: vendor, fields: fields)
        if comment.count > flacMaxBlockLength {
            // 只可能是歌词太长撑爆的；丢掉歌词也要保住其它字段
            fields.removeAll { $0.0 == "LYRICS" }
            comment = vorbisCommentBody(vendor: vendor, fields: fields)
        }
        guard comment.count <= flacMaxBlockLength else {
            throw AudioTagWriteError.unsupported("标签正文超过单块上限")
        }
        blocks.append((4, comment))
        if let artwork = tags.artwork, !artwork.isEmpty,
           let picture = flacPictureBlockBody(artwork: artwork, mime: artworkMIME(tags)) {
            blocks.append((6, picture))
        }

        try replaceAtomically(url) { out in
            try out.write(contentsOf: Data("fLaC".utf8))
            for (index, block) in blocks.enumerated() {
                let isLast = index == blocks.count - 1
                var header = Data([block.type | (isLast ? 0x80 : 0)])
                let length = block.body.count
                header.append(contentsOf: [UInt8((length >> 16) & 0xFF),
                                           UInt8((length >> 8) & 0xFF),
                                           UInt8(length & 0xFF)])
                try out.write(contentsOf: header)
                try out.write(contentsOf: block.body)
            }
            try input.seek(toOffset: audioStart)
            try copyRest(from: input, to: out)
        }
    }

    /// PICTURE 块正文的头 4 字节是大端的图片类型，3 = Front Cover。
    /// 别的类型（封底、艺人照……）不是我们写的，原样留着。
    nonisolated private static func isFrontCover(_ body: Data) -> Bool {
        let bytes = [UInt8](body.prefix(4))
        return bytes.count == 4 && bytes == [0, 0, 0, 3]
    }
}

// MARK: - Ogg

/// Ogg 的页校验和：多项式、**不反射**、初值 0、末尾不异或。
///
/// 跟 zlib/PNG 那个 CRC-32 是两码事（那个反射且初值全 1），照抄会算出完全不同的值，
/// 播放器只会说文件坏了。RFC 3533 §6 明确写了 Ogg 用的是这一版。
enum OggCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var remainder = UInt32(index) << 24
        for _ in 0..<8 {
            remainder = remainder & 0x8000_0000 != 0
                ? (remainder << 1) ^ 0x04c1_1db7
                : remainder << 1
        }
        return remainder
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(UInt8(truncatingIfNeeded: crc >> 24) ^ byte)]
        }
        return crc
    }
}

enum OggTagWriter {

    /// [实测 2026-09-09] Finder / QuickLook 给音频取缩略图时**只读 ID3**：`qlmanage -t`
    /// 对 m4a（`covr`）产出 150 KB 的真封面，对内嵌了合规 PICTURE 块的 FLAC 只产出
    /// 3.5 KB 的通用音符占位图，Ogg 的 `METADATA_BLOCK_PICTURE` 同理。
    /// 当前的决定是**两种容器都不为这个改文件格式**——各写各的规范标签就好，
    /// Finder 那头留给以后的 QuickLook 缩略图扩展。
    ///
    /// Ogg 里换 comment header：Vorbis 是第二个包，Opus 是 `OpusTags` 那个包。
    ///
    /// 换掉之后包长会变、页也要重排，所以这一路的**后续页都要顺延页号并重算 CRC**
    /// （页号是按 serial 各算各的，别的码流原样抄过去就行）。
    nonisolated static func write(_ tags: AudioTags, to url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        try replaceAtomically(url) { out in
            var codec: Codec?
            var serial: UInt32 = 0
            var packets: [Data] = []
            var pending = Data()
            var rewritten = false
            var sequence: UInt32 = 0  // 目标流下一页该用的页号

            while let page = try readPage(input) {
                if rewritten {
                    // comment 之后这一路的页长变了，页号得顺延；页号是按 serial 各算各的，
                    // 别的码流原样抄过去就行（多路复用时不动人家的页）
                    if page.serial == serial {
                        try out.write(contentsOf: page.bytes(sequence: sequence))
                        sequence += 1
                    } else {
                        try out.write(contentsOf: page.raw)
                    }
                    continue
                }

                guard let codec else {
                    // BOS 页的第一个包就是识别头；认不出的码流（skeleton、theora……）原样保留
                    guard page.headerType & 0x02 != 0,
                          let identified = Codec(identifying: page.body) else {
                        try out.write(contentsOf: page.raw)
                        continue
                    }
                    // 识别头独占 BOS 页（Vorbis I §4.2 / RFC 7845 §3 都这么要求），
                    // 所以这页整页原样抄过去：页号仍是 0，重排从下一页才开始
                    let leftover = collect(page: page, into: &packets, pending: &pending, upTo: 1)
                    guard packets.count == 1, pending.isEmpty, !leftover else {
                        throw AudioTagWriteError.malformed("BOS 页里不止一个识别头包")
                    }
                    codec = identified
                    serial = page.serial
                    sequence = 1
                    try out.write(contentsOf: page.raw)
                    continue
                }

                guard page.serial == serial else {
                    try out.write(contentsOf: page.raw)
                    continue
                }
                let leftover = collect(page: page, into: &packets, pending: &pending,
                                       upTo: codec.headerPacketCount)
                guard packets.count == codec.headerPacketCount else { continue }
                guard pending.isEmpty, !leftover else {
                    // 同两条规范都要求音频包另起一页；真混在一起就只能认栽，
                    // 不然重排会把那半个音频包丢掉
                    throw AudioTagWriteError.malformed("comment 头页里还夹着音频包")
                }
                packets[1] = codec.commentPacket(tags, old: packets[1])
                for bytes in pages(for: Array(packets.dropFirst()), serial: serial,
                                   firstSequence: 1) {
                    try out.write(contentsOf: bytes)
                    sequence += 1
                }
                rewritten = true
            }

            guard rewritten else {
                throw codec == nil
                    ? AudioTagWriteError.unsupported("Ogg 里不是 Vorbis / Opus 码流")
                    : AudioTagWriteError.malformed("头包没读完文件就结束了")
            }
        }
    }

    // MARK: 码流

    private enum Codec: Equatable {
        case vorbis
        case opus

        init?(identifying packet: Data) {
            if packet.starts(with: [0x01] + Array("vorbis".utf8)) { self = .vorbis }
            else if packet.starts(with: Array("OpusHead".utf8)) { self = .opus }
            else { return nil }
        }

        /// Vorbis 三个头包（识别 / comment / setup），Opus 两个（OpusHead / OpusTags）。
        var headerPacketCount: Int { self == .vorbis ? 3 : 2 }

        /// comment 包的前后缀。Vorbis 是 `\u{03}vorbis` 打头、末尾还有一位 framing bit
        /// （Vorbis I §4.2.2 要求置 1，缺了 libvorbis 直接判包损坏）；Opus 是 `OpusTags`，没有 framing bit。
        var prefix: Data { self == .vorbis ? Data([0x03] + Array("vorbis".utf8)) : Data("OpusTags".utf8) }

        func commentPacket(_ tags: AudioTags, old: Data) -> Data {
            let vendor = vorbisVendor(inCommentBody: old.dropFirst(prefix.count)) ?? "Amber"
            var fields = vorbisFields(tags)
            // 封面在 Ogg 里没有独立块，规范做法是把 FLAC 的 PICTURE 块 base64 塞进一条 comment
            if let artwork = tags.artwork, !artwork.isEmpty,
               let picture = flacPictureBlockBody(artwork: artwork, mime: artworkMIME(tags)) {
                fields.append(("METADATA_BLOCK_PICTURE", picture.base64EncodedString()))
            }
            var packet = prefix
            packet.append(vorbisCommentBody(vendor: vendor, fields: fields))
            if self == .vorbis { packet.append(0x01) }
            return packet
        }
    }

    // MARK: 页

    private struct Page {
        var headerType: UInt8
        var granule: UInt64
        var serial: UInt32
        var segments: [UInt8]
        var body: Data
        var raw: Data

        /// 只换页号（正文一个字节不动），CRC 跟着重算。
        func bytes(sequence: UInt32) -> Data {
            OggTagWriter.pageBytes(headerType: headerType, granule: granule, serial: serial,
                      sequence: sequence, segments: segments, body: body)
        }
    }

    /// 读一页。到文件尾返回 `nil`。
    ///
    /// 页头 27 字节（RFC 3533 §6）：`OggS`、版本、header type、granule(8, 小端)、
    /// serial(4)、页号(4)、CRC(4)、段数(1)，后面跟段表，段长之和就是正文长度。
    nonisolated private static func readPage(_ handle: FileHandle) throws -> Page? {
        guard let header = try handle.read(upToCount: 27), !header.isEmpty else { return nil }
        guard header.count == 27, header.prefix(4) == Data("OggS".utf8) else {
            throw AudioTagWriteError.malformed("Ogg 页头截断或 capture pattern 不对")
        }
        // 27 字节页头从前整块拷成 `[UInt8]` 再逐字节取。一首歌几百上千页，那就是几百上千次
        // 堆分配，全为了读六七个字段。`Span` 直接借 `header` 自己的字节，取法一个字没变。
        // 下面所有下标都落在这 27 字节里——上面那条 `count == 27` 就是它们的边界保证，
        // `Span` / `RawSpan` 越界是 trap 而不是返回 nil，长度只能这样先验。
        let bytes = header.span
        guard bytes[4] == 0 else {
            throw AudioTagWriteError.malformed("Ogg 版本不是 0")
        }
        let count = Int(bytes[26])
        guard let table = try handle.read(upToCount: count), table.count == count else {
            throw AudioTagWriteError.malformed("Ogg 段表截断")
        }
        let segments = [UInt8](table)
        let length = segments.reduce(0) { $0 + Int($1) }
        guard let body = try handle.read(upToCount: length), body.count == length else {
            throw AudioTagWriteError.malformed("Ogg 页正文截断")
        }
        // granule(8) 与 serial(4) 都是定长小端整数，各整块读一次再按小端解释，
        // 与原来逐字节移位拼出来的值一个比特不差（`UInt64(littleEndian:)` 在小端机上是恒等，
        // 大端机上是整体字节翻转，正是那个循环在做的事）。
        // 偏移 6 / 14 都不是自然对齐，所以只能走不对齐读，`load` 那一族会在对齐上炸。
        //
        // `unsafeLoadUnaligned` 不安全在它自己不查边界，读越界是未定义行为而不是 trap；
        // 谁保证它安全：上面那条 `count == 27`——6+8 与 14+4 都落在 27 里，
        // 而 `raw` 就是这 27 字节的视图。整个 `Page(...)` 是一个表达式，一个标记罩住两次读。
        let raw = bytes.bytes
        return unsafe Page(headerType: bytes[5],
                           granule: UInt64(littleEndian: raw.unsafeLoadUnaligned(
                               fromByteOffset: 6, as: UInt64.self)),
                           serial: UInt32(littleEndian: raw.unsafeLoadUnaligned(
                               fromByteOffset: 14, as: UInt32.self)),
                           segments: segments, body: body, raw: header + table + body)
    }

    /// 按段表把页里的包拼出来，拼够 `limit` 个就停。
    /// 返回「这页还有没剩下的段」——剩下就说明音频包跟头包挤在一页里了。
    nonisolated private static func collect(page: Page, into packets: inout [Data],
                                            pending: inout Data, upTo limit: Int) -> Bool {
        var offset = 0
        for (index, lace) in page.segments.enumerated() {
            if packets.count == limit {
                return index < page.segments.count
            }
            // `subdata(in:)` 会先造一份新的 `Data` 再拷进 `pending`，每段白拷一遍，
            // 而一页最多 255 段。切片是 O(1) 的视图，只剩 append 那一次真拷贝
            // （包必须自己持有字节，这一次留着）。
            // 用 dropFirst/prefix 而不是下标区间：`page.body` 万一是切片，
            // `Data` 的下标是绝对索引，那样会取错位置。
            pending.append(page.body.dropFirst(offset).prefix(Int(lace)))
            offset += Int(lace)
            // 段长不足 255 就是「包在这里结束」（RFC 3533 §6 的 lacing 规则）
            if lace < 255 {
                packets.append(pending)
                pending = Data()
            }
        }
        return false
    }

    /// 把包铺成页：一页最多 255 段，页首那段若不是包的开头就得置续页位。
    nonisolated private static func pages(for packets: [Data], serial: UInt32,
                                          firstSequence: UInt32) -> [Data] {
        var laces: [(length: UInt8, startsPacket: Bool)] = []
        var body = Data()
        for packet in packets {
            laces += lacing(for: packet)
            body.append(packet)
        }
        var out: [Data] = []
        var index = 0
        var offset = 0
        while index < laces.count {
            let end = min(index + 255, laces.count)
            let length = laces[index..<end].reduce(0) { $0 + Int($1.length) }
            out.append(pageBytes(
                // 不是包的开头就是续页，否则解码器会把这半截当成一个新包
                headerType: laces[index].startsPacket ? 0 : 0x01,
                granule: 0,  // 头页不含完整音频，granule 恒为 0
                serial: serial, sequence: firstSequence + UInt32(out.count),
                segments: laces[index..<end].map(\.length),
                // 同上：切页只要一个视图，真正的拷贝在 `pageBytes` 里把它接到页尾那一次。
                body: body.dropFirst(offset).prefix(length)))
            index = end
            offset += length
        }
        return out
    }

    /// 一个包的段表：每段 255，最后一段是余数。
    /// 包长正好是 255 的倍数时要补一个 0 长段，否则解码器会以为包还没完。
    nonisolated private static func lacing(for packet: Data) -> [(length: UInt8, startsPacket: Bool)] {
        var laces: [(length: UInt8, startsPacket: Bool)] = []
        var offset = 0
        repeat {
            let length = min(255, packet.count - offset)
            laces.append((UInt8(length), offset == 0))
            offset += length
        } while offset < packet.count || laces.last?.length == 255
        return laces
    }

    /// 拼一页的字节。CRC 是**把 CRC 字段当 0** 算完整页之后再填回去的（RFC 3533 §6）。
    nonisolated private static func pageBytes(headerType: UInt8, granule: UInt64, serial: UInt32,
                                              sequence: UInt32, segments: [UInt8],
                                              body: Data) -> Data {
        var page = Data("OggS".utf8)
        page.append(0)  // 版本
        page.append(headerType)
        page.appendLE64(granule)
        page.appendLE32(Int(serial))
        page.appendLE32(Int(sequence))
        page.appendLE32(0)  // CRC 占位
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let crc = OggCRC32.checksum(page)
        for offset in 0..<4 { page[22 + offset] = UInt8((crc >> UInt32(offset * 8)) & 0xFF) }
        return page
    }
}
