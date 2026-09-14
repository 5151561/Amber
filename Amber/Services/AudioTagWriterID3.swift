import Foundation

// MARK: - MP3 / ID3v2

/// 给 MP3 换一整块 ID3v2.4 标签。
///
/// 「换」不是「加」：ID3v2 只认文件最前面那一块，后面再叠一块的话第二块会被当成音频数据，
/// 播放器要么读到旧标签、要么在开头爆一声噪音。所以先量出旧标签整块有多长、整块跳过去，
/// 再把新标签接上原来的音频帧。
///
/// 参考规范：ID3v2.4.0 structure / frames。两个和 v2.3 不一样、写错就全盘错位的点：
/// **frame size 也是 synchsafe 整数**（v2.3 是普通 32 位），文本编码字节 3 才是 UTF-8。
enum ID3TagWriter {

    /// 搬运音频用的块大小，理由同 MP4：一首歌几十 MB，不能整块进内存。
    private static let copyChunk = 1 << 20  // 1 MiB

    /// 标签尾部留的空白。留一点，下次改标签只要没变长就能原地覆盖（我们目前不做原地覆盖，
    /// 但别的工具会），而且有些老解码器读到标签紧贴帧头时会咬掉第一帧。
    private static let padding = 1024

    nonisolated static func write(_ tags: AudioTags, to url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        let audioStart = try existingTagLength(handle, fileSize: fileSize)
        let tag = tagData(tags)

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".am-tag-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try output.write(contentsOf: tag)
            try handle.seek(toOffset: audioStart)
            var left = fileSize - audioStart
            while left > 0 {
                let want = Int(min(left, UInt64(copyChunk)))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    throw AudioTagWriteError.malformed("搬运音频时文件提前结束")
                }
                try output.write(contentsOf: chunk)
                left -= UInt64(chunk.count)
            }
            try output.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: - 旧标签

    /// 文件开头那块 ID3v2 一共占多少字节（没有就是 0）——也就是音频从哪儿开始。
    ///
    /// header 里的 size **不含** 那 10 字节 header 本身；flags 的 0x10 位表示尾部还有一份
    /// 10 字节 footer，那 10 字节也不在 size 里，漏掉就会把 footer 当音频留下来。
    ///
    /// 只看头 10 字节，所以拆成一个能给别人用的函数：分派器要靠它跳过 ID3 前缀去看真魔数，
    /// FLAC 写入器要靠它跳过上一次写的那块前缀（两处都只有头几个字节在手）。
    /// 返回 `nil` ＝ 确实是 ID3 开头，但长度字段不是合法 synchsafe，也就是这块标签坏了。
    nonisolated static func tagLength(header: Data) -> Int? {
        let bytes = [UInt8](header.prefix(10))
        guard bytes.count == 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,  // "ID3"
              bytes[3] != 0xFF, bytes[4] != 0xFF                     // 版本号里不许出现 0xFF
        else { return 0 }
        let size = synchsafeValue(Data(bytes), 6)
        guard size >= 0 else { return nil }
        return 10 + size + ((bytes[5] & 0x10) != 0 ? 10 : 0)
    }

    private static func existingTagLength(_ handle: FileHandle, fileSize: UInt64) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        let header = (try handle.read(upToCount: 10)) ?? Data()
        guard let length = tagLength(header: header) else {
            throw AudioTagWriteError.malformed("ID3 长度里有非 synchsafe 字节")
        }
        let total = UInt64(length)
        guard total <= fileSize else { throw AudioTagWriteError.malformed("ID3 标签长度超出文件") }
        return total
    }

    // MARK: - 拼标签

    /// 拼一整块 ID3v2.4 标签的字节（header + frames + padding）。
    ///
    /// 单独拎出来是为了测试能手拼一块真标签当夹具（`FLACTagWriter` 要能吃下别的工具
    /// 加在 `fLaC` 前面的 ID3 前缀，那条得先造得出这样的文件）。
    nonisolated static func tagData(_ tags: AudioTags) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            var payload = Data([3])  // 文本编码 3 = UTF-8（v2.4 才有这一档）
            payload.append(Data(value.utf8))
            frames.append(frame(id, payload))
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TPE2", tags.albumArtist)
        text("TALB", tags.album)
        // TRCK / TPOS 都是「序号/总数」的字符串形式，不知道总数就只写序号
        text("TRCK", numbering(tags.trackNumber, tags.trackTotal))
        text("TPOS", numbering(tags.discNumber, tags.discTotal))
        text("TDRC", tags.year)   // v2.4 用 TDRC 记录时间，TYER 已经废弃
        text("TCON", tags.genre)

        if let lyrics = tags.lyrics, !lyrics.isEmpty {
            // USLT：编码(1) + 语言(3) + 内容描述(以编码对应的终止符结尾) + 歌词
            // 语言写 `und`（ISO-639-2 的「未确定」）——歌词来自哪个语种我们并不知道，
            // 写死 eng 会让按语言挑选的播放器挑错。
            var payload = Data([3])
            payload.append(Data("und".utf8))
            payload.append(0)  // 空描述
            payload.append(Data(lyrics.utf8))
            frames.append(frame("USLT", payload))
        }
        if let artwork = tags.artwork, !artwork.isEmpty {
            // APIC：编码(1) + MIME(Latin-1，0 结尾) + 图片类型(1) + 描述(0 结尾) + 图片字节
            let isPNG = tags.artworkMIME?.lowercased().contains("png") == true
                || artwork.starts(with: [0x89, 0x50, 0x4E, 0x47])
            var payload = Data([3])
            payload.append(Data((isPNG ? "image/png" : "image/jpeg").utf8))
            payload.append(0)
            payload.append(3)  // picture type 3 = Cover (front)
            payload.append(0)  // 空描述
            payload.append(artwork)
            frames.append(frame("APIC", payload))
        }

        var tag = Data()
        tag.append(Data("ID3".utf8))
        tag.append(contentsOf: [4, 0])  // v2.4.0
        tag.append(0)                   // flags：不开 unsynchronisation、不开扩展头、没有 footer
        tag.append(synchsafeBytes(frames.count + padding))
        tag.append(frames)
        tag.append(Data(repeating: 0, count: padding))
        return tag
    }

    private static func numbering(_ number: Int?, _ total: Int?) -> String? {
        guard let number else { return nil }
        guard let total, total > 0 else { return String(number) }
        return "\(number)/\(total)"
    }

    /// 一个 frame：ID(4) + size(4，v2.4 是 synchsafe) + flags(2) + 正文。
    private static func frame(_ id: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(Data(id.utf8))
        data.append(synchsafeBytes(payload.count))
        data.append(contentsOf: [0, 0])
        data.append(payload)
        return data
    }

    // MARK: - synchsafe

    /// synchsafe 整数：4 个字节各只用低 7 位，最高位恒为 0——这样标签长度本身
    /// 永远不会撞上 MPEG 的帧同步字（连续 11 个 1），扫描器不会把它误判成音频帧头。
    static func synchsafeBytes(_ value: Int) -> Data {
        let value = max(0, min(value, 0x0FFF_FFFF))
        return Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                     UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }

    /// 反过来读 synchsafe。任一字节的最高位是 1 就说明这不是合法的 synchsafe，返回 -1。
    static func synchsafeValue(_ data: Data, _ offset: Int) -> Int {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return -1 }
        var result = 0
        for byte in 0..<4 {
            let value = data[base + byte]
            guard value & 0x80 == 0 else { return -1 }
            result = result << 7 | Int(value)
        }
        return result
    }
}
