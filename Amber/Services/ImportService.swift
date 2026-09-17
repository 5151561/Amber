import AVFoundation
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 「文件 › 导入…」：把本机的音频文件读进资料库。
//
// Music 的这条命令做四件事：读元数据 → 按「导入设置」转码 → 按「拷贝到媒体文件夹」落地
// → 进资料库。Amber 一一对应，设置 › 文件 里那五项在这条路上全部有了消费者：
//
// | 设置 | 落到哪 |
// | --- | --- |
// | `importEncoder` / `importPreset` | `ImportOutputSpec.make` 的转码目标 |
// | `importUseErrorCorrection` | 读文件的重试次数（3 次 vs 1 次） |
// | `copyFilesToMediaFolder` | 不转码的文件是拷进「媒体」文件夹还是原地引用 |
// | `autoUpdateImportedArtwork` | 没有内嵌封面时按「艺人 标题」到音源搜一张回填 |
//
// 本地曲目为什么不新增 `ProviderKind.local`，见`Track.localIDPrefix` 的注释。

// MARK: - 一次导入的取值快照

/// 导入期间用到的设置与落点，一次性抓好丢给后台——后台那段不碰 `AppSettings`，
/// 免得一批文件导到一半用户在设置窗里改了编码器，前半截和后半截各按一套规格走。
struct ImportOptions: Sendable {
    var encoder: ImportEncoder
    var preset: ImportPreset
    var errorCorrection: Bool
    var copyToMediaFolder: Bool
    var organized: Bool
    var mediaFolder: URL
    var artworkFolder: URL
    /// 本地曲目挂哪个音源（查歌词、搜封面、前往艺人都按它走），取导入时的默认音源。
    var kind: ProviderKind
    /// 下载索引的一份快照（id → 路径），撞名让位的判据（见 `ImportWorker.mediaFolderDestination`）。
    ///
    /// 「这个落点是不是别人的」这件事，真相在下载索引里：拷进「媒体」文件夹的导入产物
    /// 最后也经 `DownloadStore.adoptLocalFile` 进同一份索引，与下载来的那些混在一起。
    /// 后台那段够不着 `DownloadStore`（`ImportWorker` 整段`nonisolated`），所以抓成快照带进去。
    var occupied: [String: String] = [:]

    var readAttempts: Int { errorCorrection ? 3 : 1 }

    @MainActor
    static func current(kind: ProviderKind, settings: AppSettings = .shared,
                        occupied: [String: String] = [:]) -> ImportOptions {
        let values = settings.values
        return ImportOptions(encoder: values.importEncoder,
                             preset: values.importPreset,
                             errorCorrection: values.importUseErrorCorrection,
                             copyToMediaFolder: values.copyFilesToMediaFolder,
                             organized: values.keepMediaFolderOrganized,
                             mediaFolder: values.mediaFolder,
                             artworkFolder: ImportService.defaultArtworkFolder,
                             kind: kind,
                             occupied: occupied)
    }
}

/// 一个文件导完之后的结果。
struct ImportedFile: Sendable {
    var track: Track
    /// 音频最终在哪（转码产物 / 媒体文件夹里的拷贝 / 原地那份）
    var fileURL: URL
    /// 原地引用（没拷进「媒体」文件夹）。这种文件是用户自己的，
    /// 从资料库里删歌时不能跟着删（见 `DownloadStore.adoptLocalFile`）。
    var external: Bool
    /// 这一首是因为「选了 MP3 但源不是 MP3」才回落成 AAC 的
    var mp3Fallback: Bool
}

// MARK: - 协调器

@MainActor
final class ImportService {

    struct Summary: Equatable, Sendable {
        var imported = 0
        var skipped = 0
        var failed = 0
        var mp3Fallback = false

        /// 结尾那句 toast。Music 的导入没有模态进度条，Amber 也只在末尾报一次。
        var message: String {
            var parts: [String] = []
            parts.append(imported > 0 ? "已导入 \(imported) 首" : "没有导入任何歌曲")
            if skipped > 0 { parts.append("\(skipped) 首已在资料库") }
            if failed > 0 { parts.append("\(failed) 首失败") }
            var text = parts.joined(separator: "，")
            // MP3 那句只提示一次，不是每首都念一遍。
            if mp3Fallback { text += "。macOS 没有 MP3 编码器，已按 AAC 导入" }
            return text
        }
    }

    private let library: LibraryStore
    private let downloads: DownloadStore
    private let settings: AppSettings

    /// 「自动更新已导入歌曲的插图」：按（艺人，标题）到音源要一张封面地址。
    /// 由 `AppState` 接到默认音源的搜索；尽力而为，取不到就算了，绝不挡着导入。
    var artworkLookup: ((String, String) async -> String?)?
    /// 本地曲目挂的音源（默认音源）。做成闭包是因为用户随时能在设置里换。
    var defaultKind: () -> ProviderKind = { .qq }

    private(set) var isRunning = false

    init(library: LibraryStore, downloads: DownloadStore, settings: AppSettings = .shared) {
        self.library = library
        self.downloads = downloads
        self.settings = settings
    }

    /// 内嵌封面的落点。放 Application Support 而不是「媒体」文件夹：
    /// 那个文件夹是音频的，图片混进去会被「保持有序」的目录结构带着到处跑。
    static var defaultArtworkFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Amber/Artwork", isDirectory: true)
    }

    // MARK: 导入

    /// 导入一批文件或文件夹（文件夹递归展开）。返回结果由调用方报 toast。
    func importItems(_ urls: [URL]) async -> Summary {
        isRunning = true
        defer { isRunning = false }

        let options = ImportOptions.current(kind: defaultKind(), settings: settings,
                                            occupied: downloads.indexedPaths)
        let files = await Task.detached(priority: .userInitiated) {
            ImportWorker.audioFiles(in: urls)
        }.value

        var summary = Summary()
        // 同一批里按（专辑名，艺人）归组，最后整组入库——资料库的「专辑」「艺人」两页
        // 都是从 `libraryAlbums` 派生的，只走`addToLibrary` 的话导进来的歌只会出现在
        // 「歌曲」页里，专辑页一张碟都不多。
        var grouped: [String: [Track]] = [:]
        var groupOrder: [String] = []

        // 开导之前先把这一批分开：哪些是新的、哪些是这一批**自己内部**重复的、
        // 哪些与**资料库既有条目**撞了。后两种都靠 id 认（id 由源文件路径定，
        // 见 `localID(forPath:)`，不读文件就能判），但处置完全不同：
        //
        // - 批内重复（同一个路径被选进来两遍）照旧静默跳过。用户并没有什么可决定的，
        //   那两份就是同一个文件，问一句只会显得这 App 不会数数。
        // - 与资料库撞名要**先问一句**：spec §10.4 说得很明白，导入撞名这条链的语义是
        //   「替换」而不是「去重」（`[RES]`）。Amber 从前是闷头跳过，末尾报一句「N 首已在
        //   资料库」——那是把「替换」当成「去重」办了，用户想拿新文件盖掉旧的根本没有入口。
        //
        // 撞名必须在开导**之前**一次性数清：问法本身按撞的条数分岔（见 `askReplace`），
        // 边导边问的话第一条撞上时还不知道后面总共撞几条，选不了问法。
        let existing = Dictionary(library.libraryTracks.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var pending: [URL] = []
        var collisions: [(url: URL, track: Track)] = []
        for file in files {
            let id = Self.localID(forPath: file.standardizedFileURL.path)
            guard seen.insert(id).inserted else {
                summary.skipped += 1
                continue
            }
            if let old = existing[id] { collisions.append((file, old)) }
            pending.append(file)
        }

        if !collisions.isEmpty {
            if await Self.askReplace(collisions, downloads: downloads) {
                // 「替换」＝把既有那条从资料库里摘掉，然后照正常流程重导一遍。
                // 不走「原地改字段」是因为替换本来就该连**文件**一起换：`removeFromLibrary`
                // 会经 `onTracksRemoved` 让下载索引把「媒体」文件夹里的旧产物清掉
                // （原地引用的用户文件不动，见 `DownloadStore.remove(ids:)`），
                // 腾出来的落点正好被下面这一轮重新占上，不会长出个 ` 1` 来。
                for collision in collisions { library.removeFromLibrary(collision.track) }
            } else {
                // 「不替换」＝维持从前的行为：这些文件不导，末尾按「已在资料库」报。
                let declined = Set(collisions.map(\.url))
                pending.removeAll { declined.contains($0) }
                summary.skipped += collisions.count
            }
        }

        for file in pending {
            do {
                // 设置只抓一次（免得一批导到一半用户改了编码器，前后半截各按一套规格走），
                // 但撞名判据得逐首现取：这一批前面几首刚经 `adoptLocalFile` 进了索引，
                // 后面这首要躲开它们——同碟同名同曲序的两首歌就是这么分开的。
                var fileOptions = options
                fileOptions.occupied = downloads.indexedPaths
                let imported = try await Task.detached(priority: .userInitiated) {
                    try await ImportWorker.process(file, options: fileOptions)
                }.value
                var track = imported.track
                if imported.mp3Fallback { summary.mp3Fallback = true }
                // 没有内嵌封面时才去问音源（Music 的这颗开关也是「补上没有的那些」）。
                if track.artworkURL == nil, settings.values.autoUpdateImportedArtwork,
                   let found = await artworkLookup?(track.artistName, track.title) {
                    track.artworkURL = found
                }
                // 先让下载索引认领这份文件，再入库：入库会触发「自动下载」，
                // 认领过之后它一看已经是 `.downloaded` 就跳过，不会拿 local: 的 id 去打音源。
                downloads.adoptLocalFile(at: imported.fileURL, for: track,
                                         external: imported.external)
                let key = Self.albumKey(album: track.albumName, artist: track.artistName)
                if grouped[key] == nil { groupOrder.append(key) }
                grouped[key, default: []].append(track)
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }

        for key in groupOrder {
            guard var tracks = grouped[key], let first = tracks.first else { continue }
            // 整组的封面：组里第一张有封面的（内嵌图，或「自动更新插图」搜回来的那张）。
            // 这一步必须在上面那个循环**之后**——搜回来的地址是逐首落到 `track.artworkURL`
            // 上的，专辑要是先定下来就只能是空的。
            let cover = tracks.compactMap(\.artworkURL).first
            // 一张碟只认一张封面：碟里只有一首带内嵌图时，另外几首跟着这张走
            // （Music 也是整碟一张图）。「未知专辑」是杂物筐，不同的歌混在一起，
            // 不能让其中一首的封面糊到别人头上——**专辑那一格也不给**，
            // 否则资料库里那个筐显示的就是筐里第一首歌的碟，看着就是「封面串了」。
            let junkDrawer = first.albumName == Self.unknownAlbum
            if let cover, !junkDrawer {
                for index in tracks.indices where tracks[index].artworkURL == nil {
                    tracks[index].artworkURL = cover
                }
            }
            let album = Album(id: Album.localIDPrefix + Self.sha1(key),
                              kind: options.kind,
                              name: first.albumName,
                              artistName: first.artistName,
                              artistId: nil,
                              artworkURL: junkDrawer ? nil : cover,
                              publishDate: nil,
                              trackCount: tracks.count,
                              description: nil)
            library.addAlbumToLibrary(album, tracks: tracks)
        }
        return summary
    }

    // MARK: 撞名询问

    /// 问用户要不要替换。返回 true＝替换（答案对**全部**撞名条目生效）。
    ///
    /// **一条走三分支的逐条问法，多条走批量那一句**——这条分派规则 spec 没有坐实，是 `[推]`。
    /// 判据：res 500 的三句都带 `%1$S`（要填曲目名），天然是逐条的；一批撞十条就得连弹
    /// 十张对话框，没人受得了。而 res 9003 idx 3 那句「一首或多首……」批量版的存在本身
    /// 就是 Music 对这件事的答案：撞成一片时它换一句话、一次问完。两句都实测得到，
    /// 缺的只是「几条起算多」这个门槛，取 2 是最保守的选择（能逐条问就逐条问，
    /// 逐条问不下去了才降级成一句笼统的）。
    private static func askReplace(_ collisions: [(url: URL, track: Track)],
                                   downloads: DownloadStore) async -> Bool {
        // sheet 贴哪：主窗。导入是「文件 ▸ 导入…」的后续，触发时主窗一定在。
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard collisions.count == 1, let only = collisions.first else {
            return await ImportReplaceAlert.confirmBatch(in: window)
        }
        // `%1$S` 填的是**既有条目**的曲目名：问的是「资料库里那个项目」要不要被换掉，
        // 待导那份这会儿连元数据都还没读（读文件在 `ImportWorker.process` 里），
        // 想拿它的标题也拿不到。
        // 既有那份文件在哪：问下载索引（本地性唯一的真值源）。取不到就是 nil，
        // `branch` 自会回落到中性的那句。
        let branch = ImportReplacePrompt
            .branch(existingModified:
                        modificationDate(atPath: downloads.fileURL(for: only.track.id)?.path),
                    incomingModified: modificationDate(atPath: only.url.standardizedFileURL.path))
        return await ImportReplaceAlert.confirm(branch: branch, trackTitle: only.track.title,
                                                in: window)
    }

    /// 文件的修改时间——三分支的判据（见 `ImportReplacePrompt.branch`，`[推]`）。
    ///
    /// 先问 URL 资源键，取不到再退回 `attributesOfItem`：两条路在正常文件上给的是同一个值，
    /// 但资源键那条在某些卷上会空手而归（缓存过的资源值失效、非本地卷）。
    /// 一律返回 `nil` 而不是随便凑个日期——`branch` 靠`nil` 回落到中性的那句 124。
    nonisolated static func modificationDate(atPath path: String?) -> Date? {
        guard let path else { return nil }
        if let date = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            return date
        }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 标签与文件名都认不出来时的占位（与 `ImportWorker.readMetadataOnce` 里那两句同源）
    static let unknownArtist = "未知艺人"
    static let unknownAlbum = "未知专辑"

    /// 归组键：专辑名 + 艺人（大小写与前后空白无关）。同名不同艺人的专辑不该并到一起。
    nonisolated static func albumKey(album: String, artist: String) -> String {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return album + "\u{1}" + artist
    }

    /// 本地曲目的 id：`local:` + 源文件绝对路径的 SHA-1。
    ///
    /// 取**源**路径而不是落地后的路径：这样「同一个文件导第二次」必然撞同一个 id，
    /// 资料库那头自己就会挡掉（`LibraryStore.insert` 认 id）。
    nonisolated static func localID(forPath path: String) -> String {
        Track.localIDPrefix + sha1(path)
    }

    nonisolated static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 后台那一段

/// 真正读文件、转码、落地的那段。全是 `nonisolated static`：整段在`Task.detached`
/// 里跑，主线程只负责收结果与动资料库。
enum ImportWorker {

    // MARK: 选文件

    /// 面板选中的东西展开成音频文件清单：文件夹递归进去，非音频的滤掉，
    /// 同一次导入里按路径排序（一张碟一次选进来时曲序才是稳的）。
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles,
                                                              .skipsPackageDescendants])
                while let child = enumerator?.nextObject() as? URL {
                    if isAudioFile(child) { files.append(child) }
                }
            } else if isAudioFile(url) {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// 是不是音频。按扩展名问 UTType：音乐光盘由 cddafs 挂成 `.aiff`，
    /// 走的就是这条普通文件的路（这也是「读取音乐光盘」在 Amber 里唯一的形态）。
    nonisolated static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    /// 面板允许选的类型。
    ///
    /// 光有 `.audio` 那一支不够：从音源下下来的歌不少是`.mp4`（`public.mpeg-4`，
    /// 杜比档尤其如此），它属于 `audiovisualContent` 而不是`audio`，
    /// 只列音频类型的话面板里那些文件是灰的——只能整个文件夹选进来，一首一首挑不了。
    /// 真正「有没有音轨」由 `process` 里的`loadTracks(withMediaType: .audio)` 把关。
    nonisolated static var panelContentTypes: [UTType] {
        [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie, .movie,
         .audiovisualContent]
    }

    // MARK: 一个文件

    nonisolated static func process(_ source: URL, options: ImportOptions) async throws -> ImportedFile {
        let asset = AVURLAsset(url: source)
        let meta = try await readMetadata(asset: asset, source: source,
                                          attempts: options.readAttempts)
        let format = await sourceFormat(asset: asset, url: source)
        let plan = ImportPlan.decide(source: format, encoder: options.encoder)

        let id = ImportService.localID(forPath: source.standardizedFileURL.path)
        var track = Track(id: id, kind: options.kind,
                          title: meta.title, artistName: meta.artist, artistId: nil,
                          albumName: meta.album, albumId: nil,
                          artworkURL: nil, duration: meta.duration,
                          trackNumber: meta.trackNumber, discNumber: meta.discNumber)

        // 内嵌封面先落地（`ImageCache` 认 file:// 地址）
        if let artwork = meta.artwork,
           let url = writeArtwork(artwork, id: id, folder: options.artworkFolder) {
            track.artworkURL = url.absoluteString
        }

        let placed: URL
        var external = false
        switch plan {
        case .copyOriginal:
            if options.copyToMediaFolder {
                placed = try copyIntoMediaFolder(source, track: track, options: options)
            } else {
                // 不转码又不拷贝：原样引用用户放在原处的那份文件。
                placed = source
                external = true
            }
        case .transcode(let encoder, _):
            let spec = ImportOutputSpec.make(encoder: encoder, preset: options.preset,
                                             source: format)
            let (destination, isOwn) = mediaFolderDestination(for: track,
                                                              ext: spec.fileExtension,
                                                              options: options)
            // `ImportTranscoder.export` 写之前会无条件清掉落点。走到这里落点要么是空的、
            // 要么就是这条曲目自己上次的产物（重导盖回去）——别人的名字（索引里的、
            // 以及索引不认得但确实在盘上的）`mediaFolderDestination` 都已经让开了。
            // 万一还是撞上（让开之后到这儿的空档里有人往那儿写了个文件），宁可让这一首
            // 导入失败，也不能把人家的文件悄悄换成转码产物。
            if !isOwn, FileManager.default.fileExists(atPath: destination.path) {
                throw ImportError.writeFailed("「媒体」文件夹里已经有 \(destination.lastPathComponent)")
            }
            // 读到的标签（含照文件名补出来的那几格）跟着写进产物：转码是重新造一个文件，
            // 不带上的话访达、Music 里看到的是「无标题 / 未知艺人 / 没封面」。
            let tags = ImportMetadata.items(for: spec.fileType, title: track.title,
                                            artist: track.artistName, album: track.albumName,
                                            trackNumber: track.trackNumber,
                                            discNumber: track.discNumber, artwork: meta.artwork)
            // 转码产物**一定**落「媒体」文件夹，与「拷贝到媒体文件夹」那颗勾无关：
            // 它是 Amber 新造出来的文件，不属于用户的源目录（往那里写等于弄脏人家的文件夹），
            // 临时目录又会被系统清掉。那颗勾管的是「不转码的文件要不要拷一份」。
            try await ImportTranscoder.export(url: source, to: destination, spec: spec,
                                              metadata: tags, attempts: options.readAttempts)
            placed = destination
        }
        // 落点只写进 `ImportedFile.fileURL`：调用方（`importItems`）拿着它逐条调
        // `downloads.adoptLocalFile`，那一下就是这份文件进本机账本的唯一入口。
        // 从前这里还往 `track.localPath` 上抄一份，是第二份真相，也是纯重复。
        return ImportedFile(track: track, fileURL: placed, external: external,
                            mp3Fallback: plan.mp3Fallback)
    }

    /// 按「保持"媒体"文件夹有序」的命名把源文件拷进去。
    nonisolated private static func copyIntoMediaFolder(_ source: URL, track: Track,
                                                        options: ImportOptions) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let (destination, isOwn) = mediaFolderDestination(for: track, ext: ext, options: options)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 只有确认落点上那份是这条曲目自己上一次落下的才清掉重来（＝同一首歌重导）。
        // 别人那些名字上面已经让开了；剩下还可能挡在这里的是索引不认得的文件，
        // `copyItem` 会因此抛错——这一首算导入失败，但用户自己的文件一个字节都不动。
        if isOwn { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// 这一首该落在「媒体」文件夹的哪儿，外加「落点上那份是不是它自己的」。
    ///
    /// 命名与撞名保护都与下载共用一套（`DownloadStore.relativePath` + `.placement`）——
    /// 两条路落进同一个文件夹，摆法不该有两种。
    ///
    /// 判据是 `options.occupied`（下载索引的快照）而**不是「文件存在」**：同一首歌重导时
    /// 目标文件当然还在，按文件存在判的话每导一次就多长出一个 ` 1`；索引里那条 path
    /// 记的就是它自己，那份本来就该被覆盖——第二格返回的就是这件事。
    ///
    /// 扁平模式（`organized == false`）不必单独判：那时名字是`<安全化 id>.ext`，
    /// 一首歌一个 id，而 `placement` 先把自己那条滤掉了，剩下的集合里不可能有同一个 id
    /// 产出的名字，原样返回。
    nonisolated static func mediaFolderDestination(for track: Track, ext: String,
                                                   options: ImportOptions) -> (url: URL,
                                                                               isOwn: Bool) {
        let wanted = DownloadStore.relativePath(for: track, ext: ext,
                                                organized: options.organized)
        let media = options.mediaFolder
        // 索引不认得、但确实躺在「媒体」文件夹里的文件也让开（用户自己拖进去的那种）：
        // 让位比报错好，`DownloadStore.place` 那条路同一个判据。
        let relative = DownloadStore.placement(of: wanted, for: track.id,
                                               occupied: options.occupied) {
            FileManager.default.fileExists(atPath: media.appendingPathComponent($0).path)
        }
        return (options.mediaFolder.appendingPathComponent(relative),
                options.occupied[track.id] == relative)
    }

    // MARK: 元数据

    struct RawMetadata: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var trackNumber: Int?
        var discNumber: Int?
        var artwork: Data?
    }

    /// 读元数据。读失败重试 `attempts` 次——设置 › 文件 › 导入设置 ›「读取音乐光盘时
    /// 使用纠错功能」在 Amber 里只能是这个意思：光盘纠错没有公开 API（cddafs 把音轨挂成
    /// 普通 AIFF 文件，读它就是读文件系统），能做的只有读不动时再来一遍。
    nonisolated static func readMetadata(asset: AVURLAsset, source: URL,
                                         attempts: Int) async throws -> RawMetadata {
        var lastError: Error = ImportError.readFailed("未知原因")
        for attempt in 0..<max(attempts, 1) {
            do {
                return try await readMetadataOnce(asset: asset, source: source)
            } catch {
                lastError = error
                if attempt + 1 < max(attempts, 1) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        throw lastError
    }

    /// 一个字段要问的全部写法。
    ///
    /// 只问 `commonIdentifier*` 是不够的：AVFoundation 只给「通用键」映射了一小部分
    /// （FLAC 的 `vorb/TRACKNUMBER`、`vorb/DISCNUMBER` 就没有通用键，
    /// 之前读进来的本地曲目曲序全是空的），mp4 的 `trkn`、ID3 的`TRCK` 也各是各的。
    /// 所以每格都按「通用键 → iTunes → ID3 → QuickTime → Vorbis」逐条问下去。
    private enum MetaKeys {
        static let title: [AVMetadataIdentifier] = [
            .commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription,
            .quickTimeMetadataTitle, .quickTimeUserDataTrackName, vorbis("TITLE"),
        ]
        static let artist: [AVMetadataIdentifier] = [
            .commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer,
            .quickTimeMetadataArtist, .quickTimeUserDataArtist, vorbis("ARTIST"),
            .iTunesMetadataAlbumArtist, .id3MetadataBand, vorbis("ALBUMARTIST"),
        ]
        static let album: [AVMetadataIdentifier] = [
            .commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle,
            .quickTimeMetadataAlbum, .quickTimeUserDataAlbum, vorbis("ALBUM"),
        ]
        static let track: [AVMetadataIdentifier] = [
            .iTunesMetadataTrackNumber, .id3MetadataTrackNumber, vorbis("TRACKNUMBER"),
        ]
        static let disc: [AVMetadataIdentifier] = [
            .iTunesMetadataDiscNumber, .id3MetadataPartOfASet, vorbis("DISCNUMBER"),
        ]
        static let artwork: [AVMetadataIdentifier] = [
            .commonIdentifierArtwork, .iTunesMetadataCoverArt, .id3MetadataAttachedPicture,
            .quickTimeMetadataArtwork, vorbis("METADATA_BLOCK_PICTURE"), vorbis("COVERART"),
        ]

        /// Vorbis comment（FLAC / Ogg）没有现成常量，标识符就是 `vorb/<字段名>`。
        static func vorbis(_ name: String) -> AVMetadataIdentifier {
            AVMetadataIdentifier(rawValue: "vorb/" + name)
        }
    }

    nonisolated private static func readMetadataOnce(asset: AVURLAsset,
                                                     source: URL) async throws -> RawMetadata {
        let (duration, items) = try await (asset.load(.duration), asset.load(.metadata))
        // 没有音轨的文件（歌词文本被误当音频、坏文件）到这里就该失败，别进资料库。
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ImportError.noAudioTrack
        }
        // `.metadata` 已经把各 keyspace 并在一起了，但个别容器（QuickTime 的 udta 等）
        // 只在 `availableMetadataFormats` 那条路上露面，两边都收下，先到的先用。
        var all = items
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let extra = try? await asset.loadMetadata(for: format) {
                    all.append(contentsOf: extra)
                }
            }
        }

        let taggedTitle = await string(all, MetaKeys.title)
        let taggedArtist = await string(all, MetaKeys.artist)
        let taggedAlbum = await string(all, MetaKeys.album)
        // 标签没给的那几格照文件名／目录名补（`月牙湾 - F.I.R.飞儿乐团 [杜比D003…].mp4`
        // 这种从音源下下来的文件一个标签都没有，信息全在名字里）。
        let guess = ImportNameGuess.guess(for: source)

        var meta = RawMetadata(title: taggedTitle
                                   ?? guess.resolvedTitle(knownArtist: taggedArtist)
                                   ?? source.deletingPathExtension().lastPathComponent,
                               artist: taggedArtist ?? guess.artist ?? ImportService.unknownArtist,
                               album: taggedAlbum ?? guess.album ?? ImportService.unknownAlbum,
                               duration: duration.seconds.isFinite ? duration.seconds : 0,
                               trackNumber: nil, discNumber: nil, artwork: nil)
        meta.artwork = await artwork(all)
        meta.trackNumber = await number(all, MetaKeys.track) ?? guess.trackNumber
        meta.discNumber = await number(all, MetaKeys.disc)
        return meta
    }

    /// 按给定的一串标识符逐条问，第一个非空字符串就是答案。
    nonisolated private static func string(_ items: [AVMetadataItem],
                                           _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            let matched = AVMetadataItem.metadataItems(from: items,
                                                       filteredByIdentifier: identifier)
            for item in matched {
                if let value = try? await item.load(.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    /// 内嵌封面：把各 keyspace 里第一份**能被 ImageIO 认出来**的图片数据交出去。
    ///
    /// FLAC 的 `METADATA_BLOCK_PICTURE` 由 AVFoundation 拆过了（`dataValue` 直接就是
    /// JPEG/PNG 字节），但别的来源不一定——认不出来时按 FLAC 的图片块结构再剥一层。
    nonisolated static func artwork(_ items: [AVMetadataItem]) async -> Data? {
        for identifier in MetaKeys.artwork {
            let matched = AVMetadataItem.metadataItems(from: items,
                                                       filteredByIdentifier: identifier)
            for item in matched {
                var data = try? await item.load(.dataValue)
                // iTunes 的 `covr` 偶尔以 NSData 之外的形式出现（value 是图片对象）
                if data == nil, let value = try? await item.load(.value) as? Data { data = value }
                // Vorbis 的图片块若是原样的 base64 文本
                if data == nil, let text = try? await item.load(.stringValue),
                   let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
                    data = decoded
                }
                guard let data, !data.isEmpty else { continue }
                if isImage(data) { return data }
                if let payload = flacPicturePayload(data), isImage(payload) { return payload }
            }
        }
        return nil
    }

    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// FLAC 的 `METADATA_BLOCK_PICTURE`：`type(4) | mimeLen(4) | mime | descLen(4) | desc |
    /// w(4) h(4) depth(4) colors(4) | dataLen(4) | data`，全是大端。返回最后那段图片字节。
    nonisolated static func flacPicturePayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        func readUInt32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            return value
        }
        guard readUInt32() != nil,                                   // 图片类型
              let mimeLength = readUInt32(), mimeLength >= 0 else { return nil }
        offset += mimeLength
        guard let descriptionLength = readUInt32(), descriptionLength >= 0 else { return nil }
        offset += descriptionLength
        offset += 16                                                 // 宽高位深色数
        guard let length = readUInt32(), length > 0,
              offset + length <= bytes.count else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }

    /// 「音轨编号 / 光盘编号」。两种写法都要认：iTunes 的 `trkn` 是一小段二进制，
    /// ID3 的 `TRCK` 是 "3/12" 这样的字符串。
    nonisolated private static func number(_ items: [AVMetadataItem],
                                           _ identifiers: [AVMetadataIdentifier]) async -> Int? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let data = try? await item.load(.dataValue), let value = number(fromData: data) {
                    return value
                }
                if let text = try? await item.load(.stringValue),
                   let value = number(fromText: text) {
                    return value
                }
                if let value = try? await item.load(.numberValue)?.intValue, value > 0 {
                    return value
                }
            }
        }
        return nil
    }

    /// iTunes 的 `trkn` / `disk`：8（或 6）字节，`00 00 <序号 BE16> <总数 BE16> ...`。
    nonisolated static func number(fromData data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }

    /// ID3 的 `TRCK` / `TPOS`："3" 或 "3/12"。
    nonisolated static func number(fromText text: String) -> Int? {
        let head = text.split(separator: "/").first.map(String.init) ?? text
        guard let value = Int(head.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    // MARK: 源格式

    nonisolated static func sourceFormat(asset: AVURLAsset, url: URL) async -> ImportSourceFormat {
        var format = ImportSourceFormat.unknown
        format.fileExtension = url.pathExtension.lowercased()
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = description.audioStreamBasicDescription
        else { return format }
        format.formatID = basic.mFormatID
        if basic.mSampleRate > 0 { format.sampleRate = basic.mSampleRate }
        if basic.mChannelsPerFrame > 0 { format.channels = Int(basic.mChannelsPerFrame) }
        return format
    }

    // MARK: 封面

    /// 内嵌封面落到 `<Application Support>/Amber/Artwork/<id>.<ext>`，返回它的 file URL。
    nonisolated static func writeArtwork(_ data: Data, id: String, folder: URL) -> URL? {
        guard !data.isEmpty else { return nil }
        let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let url = folder.appendingPathComponent(DownloadStore.safeName(id) + "." + ext)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
