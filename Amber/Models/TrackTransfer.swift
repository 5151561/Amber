import AppKit
import CoreTransferable
import UniformTypeIdentifiers

/// 拖曲目用的载荷。
///
/// Music 的做法（`[实测]` `tableView:pasteboardWriterForRow:`）是往剪贴板写
/// **item 的标识符**，落点那边再拿标识符回资料库里找回曲目
/// （`doReorderItemsWithIdentifiers:beforeItem:`，167 条指令，
/// macOS 27（26A5425a）基线；旧记的是 macOS 26 基线，
/// 换算 delta −0x9c，正是 playlists scope 里函数最多的那一档，见
/// playlists 规格 §14）。
/// Amber 这边没有 C++ 的 playlist 层做标识符解析，所以直接把曲目本身编码进去，
/// 语义一致而少一次查找；仍然保留「一次拖一批」的形状——Music 的拖拽本来就是多行的。
struct TrackTransfer: Codable, Transferable {
    var tracks: [Track]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .amberTracks)
    }

    /// 直接往 `NSPasteboardItem` 上写时用的类型。与`UTType.amberTracks.identifier` 是同一个串，
    /// 但不必为了拿一个常量去查一次 LaunchServices（NSTableView 起拖那一下是热路径）。
    static let pasteboardType = NSPasteboard.PasteboardType(amberTracksIdentifier)
}

/// 私有拖拽类型的标识符。**必须同时写进 Info.plist 的 `UTExportedTypeDeclarations`**：
/// 没声明的话 `UTType(exportedAs:)` 给回来的类型`supertypes` 是空的（实测），
/// 既不 conform `public.data` 也不 conform`public.item`，SwiftUI 那边
/// `dropDestination(for: TrackTransfer.self)` 的`CodableRepresentation` 就认不出这份载荷。
let amberTracksIdentifier = "com.changlepan.Amber.tracks"

extension UTType {
    /// 私有拖拽类型。Music 用的也是自己的私有 pasteboard 类型，不是通用的文件/URL 类型——
    /// 这样表格之间能互认，拖到别的 App 里则什么也不会发生。
    static let amberTracks = UTType(exportedAs: amberTracksIdentifier)
}
