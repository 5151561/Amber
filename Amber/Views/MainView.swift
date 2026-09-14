import AppKit
import SwiftUI

// 主壳（分栏 / 导航栈 / 工具栏 / 迷你播放器 / 整窗播放器 / toast / 改名弹窗）已经搬进
// `Amber/Views/Shell/`：`MainWindowController` + `RootViewController` +
// `MainSplitViewController` + `ContentNavigationController` + `SidebarViewController`。
// 见 design-ref/appkit-rewrite-plan.md 阶段 1。资料库「歌曲」页也已换成 AppKit
// （`LibrarySongsViewController`，阶段 5），这里只剩一个拖入落点。

// MARK: - 拖入落点

/// 曲目拖入的落点：悬停时描一圈品牌色边（写法与待播清单那块盘一致，见 TrackSectionsPlatter）。
///
/// **现在一处都没有在用了。** 最后一个宿主是右侧面板那份 SwiftUI 待播清单；
/// 面板换成 AppKit 的 `PlayQueueViewController` 之后，拖入落点改由表格用
/// `TrackTransfer.pasteboardType` 接（`acceptTracks`），这一支 SwiftUI 落点
/// 就此空转，等确认没有新宿主要用再整块删。
/// 边栏原先也挂着它（「心水歌曲」与可编辑的播放列表行），侧栏换成 NSOutlineView 之后
/// 那两处改走 `NSOutlineViewDataSource` 的 validateDrop/acceptDrop
///（见 `SidebarOutlineController`），落点反馈同样是这一圈 2pt 品牌色边，
/// 由 `SidebarRowView.drawDraggingDestinationFeedback` 自绘。
private struct SidebarTrackDrop: ViewModifier {
    /// 关掉的行（只读的账号歌单）连拖拽反馈都不给，光标停在上面仍是「不接受」。
    var enabled: Bool
    /// 返回 false 表示这一批没有实际落进去（比如全都已经心水过了）。
    let accept: ([Track]) -> Bool

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: MusicMetrics.Sidebar.rowCornerRadius,
                                         style: .continuous)
                            .strokeBorder(Color.amberKey, lineWidth: 2)
                    }
                }
                .dropDestination(for: TrackTransfer.self) { items, _ in
                    let tracks = items.flatMap(\.tracks)
                    guard !tracks.isEmpty else { return false }
                    return accept(tracks)
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

extension View {
    func amberTrackDrop(enabled: Bool = true,
                     accept: @escaping ([Track]) -> Bool) -> some View {
        modifier(SidebarTrackDrop(enabled: enabled, accept: accept))
    }
}
