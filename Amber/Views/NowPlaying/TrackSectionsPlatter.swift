import SwiftUI

/// 整窗播放器里的「待播清单」盘。
///
/// [实测] nowplaying spec §6.5：NowPlayingView 的 Swift 函数区里直读到两个动画名
/// `trackSectionsPlatter.expanded` / `trackSectionsPlatter.collapsed`，
/// 和一个专用视图标识 `NowPlayingView.TrackSectionsScrollableContentFade`
/// ——所以待播清单在整窗播放器里**是一块会展开/收起的盘**，不是弹出式菜单
/// （Amber 之前用 popover，形不对）。盘的下限高度走 [实测] §2.2 的 `drawerHeight = 200`。
///
/// 拖放照 [实测] §3.3 `PBPlayerViewModel.isValidDrop:`/
/// `handleDrop:`：按`NSPasteboardItem` 枚举拖进来的曲目，落到清单里。
struct TrackSectionsPlatter: View {
    /// 整窗播放器收起时传 false：盘里那个电平指示条是 30fps 的 `TimelineView`，
    /// 挂着就一直重画，底下还压着一整块玻璃要跟着合成。
    var isActive = true

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController

    private typealias M = MusicMetrics.NowPlaying

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: M.platterInnerSpacing) {
            header
            if player.queue.isEmpty {
                Text("待播清单为空")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(M.subtitleOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .padding(M.platterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 不能用默认的 clear 玻璃：盘有 630×748 那么大，底下的歌词会整片透上来，
        // 两层字叠在一起谁都读不了。小胶囊用 clear 没问题，这块得用 regular。
        .amberGlass(in: RoundedRectangle(cornerRadius: M.platterCornerRadius, style: .continuous),
                 clear: false)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: M.platterCornerRadius, style: .continuous)
                    .strokeBorder(Color.amberKey, lineWidth: 2)
            }
        }
        .dropDestination(for: TrackTransfer.self) { items, _ in
            let tracks = items.flatMap(\.tracks)
            guard !tracks.isEmpty else { return false }
            player.playLast(tracks)
            appState.showToast(tracks.count > 1 ? "已加入待播清单 \(tracks.count) 首" : "已加入待播清单")
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("待播清单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: M.platterRowSpacing)
            if !player.queue.isEmpty {
                Text("\(player.queue.count) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(M.subtitleOpacity))
            }
        }
    }

    /// 这块盘上的行。身份取 `PlayQueueModel` 那一套（`"曲目 id:第几次出现"`，下标故意不进，
    /// 理由见 `PlayQueueItem` 的注释）——同一份队列在侧栏面板与这里必须是同一套身份。
    ///
    /// 从前这里按数组下标认行（`id: \.offset` + `.id(index)`）：队列中间插一首或去掉一首，
    /// 插入点之后**每一行**的 id 都对应到了另一首歌，行里`ArtworkView` 的 `.task(id:)`
    /// 因此整批重跑（其中有一句 `image = nil`），没命中内存缓存的当场清空——
    /// 整块盘从插入点往下刷一片渐变占位块再逐个淡回来。按身份走之后是一行滑进来、其余不动。
    private var items: [PlayQueueItem] {
        PlayQueueModel.items(queue: player.queue, origins: player.queueOrigins,
                             currentIndex: player.currentIndex)
    }

    /// 当前曲在这份清单里的身份。滚动定位按它走，不再按下标
    /// （下标滚到的那一行在插删之后已经是另一首歌了）。
    private var currentItemID: PlayQueueItem.ID? {
        guard let index = player.currentIndex else { return nil }
        return items.first { $0.queueIndex == index }?.id
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // `PlayQueueItem` 是 `Identifiable`，`ForEach` 直接吃它的 `id`，
                    // 也就是 `proxy.scrollTo` 认的那个 id，不必再挂一层 `.id(…)`。
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.vertical, M.platterInnerSpacing)
            }
            // [实测] TrackSectionsScrollableContentFade：滚动内容上下渐隐
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: M.platterFadeFraction),
                        .init(color: .black, location: 1 - M.platterFadeFraction),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
            .onAppear {
                guard let id = currentItemID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: player.currentIndex) { _, _ in
                guard let id = currentItemID else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ item: PlayQueueItem) -> some View {
        let track = item.track
        let isCurrent = player.currentIndex == item.queueIndex
        return Button {
            player.playTrack(at: item.queueIndex)
        } label: {
            HStack(spacing: M.platterRowSpacing) {
                ArtworkView(url: track.artworkURL, tint: Color.tint(for: track.kind),
                            points: ArtworkSize.row)
                    .frame(width: MusicMetrics.TrackRow.artworkSize,
                           height: MusicMetrics.TrackRow.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: MusicMetrics.TrackRow.artworkCornerRadius,
                                                style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.85))
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(M.subtitleOpacity))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isCurrent {
                    NowPlayingLevelsView(isPlaying: player.isPlaying && isActive)
                }
            }
            .padding(.vertical, M.platterInnerSpacing)
            .padding(.horizontal, M.platterInnerSpacing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 这是待播清单，走队列那一份项序（实测 `ITPlayQueueModel.actionMenuForItems:source:`）。
        // 「从队列中移除」现在还接不上（`PlayerController` 没有这条），按「禁用即隐藏」不摆，
        // 但它在表里的位置已经排好了。
        .contextMenu {
            MenuSpec.Rows(TrackActions(tracks: [track], appState: appState).queueRow())
        }
    }
}
