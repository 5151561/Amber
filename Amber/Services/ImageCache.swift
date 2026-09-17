import AppKit
import CryptoKit
import Foundation
import ImageIO
import os

/// 图片缓存：内存 NSCache + 磁盘缓存 + 请求去重。
///
/// **不做成 actor**：`memoryCachedImage(for:)` 必须是同步的（理由见它头上那段），
/// 而 actor 上的方法一律异步。所以走另一条路——可变状态只有在途表一份，收在
/// `inFlight` 那把锁的 state 里，其余全是 `let`。`@unchecked` 只差 `NSCache` 这一项：
/// 它自己是线程安全的，Foundation 没给它 `Sendable` 标注而已。
final class ImageCache: @unchecked Sendable {

    static let shared = ImageCache()

    private let memory = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let session = URLSession(configuration: {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return config
    }())
    /// 在途请求表。**表就装在锁里**，不另立一个字段：分开写的话锁护着谁全凭自觉，
    /// 编译器也验不了；收进 state 之后「拿得到表」就等于「已经持锁」。
    private let inFlight = OSAllocatedUnfairLock<[String: Task<NSImage?, Never>]>(initialState: [:])
    /// 过期清理只在首次取图时安排一次。
    private let didSweep = OSAllocatedUnfairLock(initialState: false)

    /// 磁盘文件超过这个时长没被读过就清掉（封面地址会随目录页轮换，旧图不会再被要）。
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDirectory = caches.appendingPathComponent("Amber/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        // 封面是位图，按张数限不住内存，另外按像素数估的字节数封顶。
        memory.countLimit = 400
        memory.totalCostLimit = 256 * 1024 * 1024
    }

    /// 内存里已经有的那一张，同步取。
    ///
    /// 给「重新上屏」用：先 `contents = nil` 再等一次异步回填，即使图早就在 `NSCache` 里，
    /// 卡片也必定空白至少一帧——切页时看到的封面闪动就是这么来的。命中就直接贴。
    func memoryCachedImage(for urlString: String?) -> NSImage? {
        guard let urlString else { return nil }
        return memory.object(forKey: urlString as NSString)
    }

    func image(for urlString: String?) async -> NSImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        sweepDiskIfNeeded()

        if let cached = memory.object(forKey: urlString as NSString) { return cached }

        // 本地导入曲目的封面是 `file://`（内嵌图落在 Application Support/Amber/Artwork）。
        // 这种地址不走网络那条路：URLSession 认 file 协议，但再往磁盘缓存里存一份
        // 只是把同一张图抄了两遍，而且那份抄件会被 30 天的清理误删。
        if url.isFileURL {
            // 片段里带着档位就按档解码，没带就按原尺寸（与改这条之前一致）。
            // 键用的是**带片段的整串**，所以 40pt 的行与 400pt 的头各占一条，
            // 小档不会把大档的位图顶掉、大档也不会被小档污染。
            guard let data = try? Data(contentsOf: url),
                  let image = Self.decode(data, maxPixelSize: Self.requestedPixelSize(url))
            else { return nil }
            store(image, for: urlString)
            return image
        }

        let fileName = Self.fileName(urlString)
        let diskURL = diskDirectory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: diskURL), let image = Self.decode(data) {
            store(image, for: urlString)
            return image
        }

        // 查与插必须在同一次加锁里：分两次的话两个调用方会各自建一份 task，各下一次图。
        let task: Task<NSImage?, Never> = inFlight.withLock { inFlight in
            if let existing = inFlight[urlString] { return existing }
            let created = Task<NSImage?, Never> { [weak self] in
                guard let self else { return nil }
                defer { self.inFlight.withLock { _ = $0.removeValue(forKey: urlString) } }
                do {
                    let (data, _) = try await self.session.data(from: url)
                    guard let image = Self.decode(data) else { return nil }
                    try? data.write(to: diskURL, options: .atomic)
                    self.store(image, for: urlString)
                    return image
                } catch {
                    return nil
                }
            }
            inFlight[urlString] = created
            return created
        }
        return await task.value
    }

    /// 清空内存与磁盘上的全部封面（设置 › 高级 › 还原缓存）。
    ///
    /// 在跑的下载不动它们：那几张落地后会照旧写进磁盘目录，属于「清完之后又取的」，
    /// 与清空这件事不冲突。
    func clear() {
        memory.removeAllObjects()
        let directory = diskDirectory
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return }
            for file in files { try? manager.removeItem(at: file) }
        }
    }

    /// 当场解码成位图，别把「还没解码的 `NSImage`」发出去。
    ///
    /// `NSImage(data:)` 只是把字节收下，真正解码推迟到有人画它的时候——而画它的那一刻
    /// 是 `CALayer.contents = image` 之后由 AppKit 代劳的，同一张 `NSImage` 挂在几个
    /// 不同尺寸的层上就要重新光栅化几次，几张图同时在解码时会互相串进对方的位图，
    /// 屏幕上就是「一块封面由几条别人的封面横带拼成」。
    ///
    /// `CGImageSourceCreateImageAtIndex` + `kCGImageSourceShouldCacheImmediately` 把解码
    /// 提前到这里（后台线程、每张图各自一份），`NSImage(cgImage:size:)` 之后只是一层壳，
    /// 交给 CoreAnimation 时直接就是位图，没有「用的时候再画一遍」。
    ///
    /// - Parameter maxPixelSize: 给了就按这个长边降采样。本地导入曲目的内嵌封面常见
    ///   1500–3000px，一张就吃掉 `totalCostLimit` 的百分之几，而 40pt 的行只要 80px；
    ///   档位由 `ArtworkSize.url` 写进 `file://` 地址的片段里（网络封面每档尺寸各有
    ///   各的地址，档位在服务端就分好了，走的是 nil 这一支）。
    nonisolated static func decode(_ data: Data, maxPixelSize: Int? = nil) -> NSImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let cgImage: CGImage?
        if let maxPixelSize {
            // `…FromImageAlways`：内嵌缩略图往往没有或太小，一律拿原图现缩。
            // 源图本来就比要的小时它**不放大**（[实测 probe] 1200px 的源要 4000px，
            // 回来的还是 1200），所以这一档只会砍、不会插值糊。
            // 故意不传 `kCGImageSourceCreateThumbnailWithTransform`：上面那条不降采样的
            // 路也不转 EXIF 朝向，两支要给出同一张图，不能只有一支会转。
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let cgImage else { return nil }
        // 尺寸按像素给：封面都是位图，再按 DPI 折算成 point 只会让 40pt 的行拿到一张
        // 「size 500×500」的图去缩放，NSCache 的 cost 也会跟着算错。
        return NSImage(cgImage: cgImage,
                       size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// 从 `file://` 地址的片段里读出请求档位（像素）。没有标记就回 nil = 按原尺寸解。
    private static func requestedPixelSize(_ url: URL) -> Int? {
        guard let fragment = url.fragment,
              fragment.hasPrefix(ArtworkSize.localPixelMarker),
              let pixels = Int(fragment.dropFirst(ArtworkSize.localPixelMarker.count)),
              pixels > 0
        else { return nil }
        return pixels
    }

    /// NSCache 的 cost 用「像素数 × 4」估位图占用（RGBA8）。
    private func store(_ image: NSImage, for urlString: String) {
        let size = image.size
        let pixels = Int(size.width.rounded()) * Int(size.height.rounded())
        memory.setObject(image, forKey: urlString as NSString, cost: max(pixels, 1) * 4)
    }

    private static func fileName(_ urlString: String) -> String {
        // SHA256 前 16 字节：31 位散列在几千张封面的量级上已经会撞，撞了就串图。
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.prefix(16).hexString()
    }

    /// 首次取图时清一次超期文件，放后台不挡取图。
    private func sweepDiskIfNeeded() {
        let shouldSweep = didSweep.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        guard shouldSweep else { return }
        let directory = diskDirectory
        let cutoff = Date(timeIntervalSinceNow: -Self.maxAge)
        Task.detached(priority: .background) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentAccessDateKey,
                                                                .contentModificationDateKey])
                let touched = values?.contentAccessDate ?? values?.contentModificationDate
                guard let touched, touched < cutoff else { continue }
                try? manager.removeItem(at: file)
            }
        }
    }
}
