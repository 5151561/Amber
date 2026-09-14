import SwiftUI

/// 检查器容器里**歌词那一档**的那片 SwiftUI 叶子（Music 的歌词面板控制器
/// 在 `MusicInspectorContainer` 里占的那一格，inspector spec §1.1 的`lyrics` +32）。
///
/// 前身叫「播放器检查器视图」，里面同时装着歌词与待播清单两档。待播清单换成 AppKit
/// 的 `PlayQueueViewController` 之后，SwiftUI 那份队列**没有任何宿主**了
///（主窗走 `InspectorContainerViewController`，迷你窗抽屉也换到同一台容器上），
/// 所以整块删掉，连带 `mode` 参数——只剩一档就不需要选档了。同理删掉的还有：
///
/// - **表头与那颗 ✕**：Music 的歌词面板本来就没有标题栏（[AX] `lyrics-panel.json`：
///   `AXGroup 歌词` 底下只有一个同尺寸滚动区），队列面板顶上是「自动连播 / 混音」
///   那条按钮排而不是「标题 + 叉」（playqueue spec §3.2 的视图树里没有这两件）。
///   关面板走的是宿主自己的入口——主窗是底栏胶囊那颗键，迷你窗是本窗的队列键。
/// - **`.amberTrackDrop` 落点**：拖入已经由`PlayQueueViewController` 用
///   `TrackTransfer.pasteboardType` 在表格上重接（§3 的`acceptTracks`）。
///
/// 哪一档由谁说了算仍是「一扇窗一份」：容器实例自己的 `mode`（inspector spec §1），
/// 不是全局 `AppState.playerInspector`——不然在迷你窗里点歌词会把主窗的面板列一起掀开。
struct InspectorLyricsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false
    @AppStorage(LyricsTranslationOptions.showTranslationKey)
    private var showTranslation = LyricsTranslationOptions.showTranslationDefault
    @AppStorage(LyricsTranslationOptions.showTransliterationKey)
    private var showTransliteration = LyricsTranslationOptions.showTransliterationDefault

    private var track: Track? { player.currentTrack }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: track?.id) { await loadLyrics() }
    }

    @ViewBuilder
    private var content: some View {
        if lyricsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if track == nil {
            inspectorEmpty("播放歌曲以查看歌词", symbol: "quote.bubble")
        } else if lyrics.isEmpty {
            inspectorEmpty("这首歌曲暂时没有歌词", symbol: "quote.bubble")
        } else {
            // 侧栏这档的覆盖项：
            // - 19pt 的左右内边距走**滚动视图里面**的 margins。加在外面（原来那句
            //   `.padding(.horizontal:)`）会让滚动区窄一圈，行贴着 clip view 左沿，
            //   逐行模糊往左糊出去的那一圈被 NSClipView 剪掉，未轮到的行左边缘
            //   出现一条硬边——整窗那边 `hostedContentInset` 早就改过来了，这边漏了。
            // - `.sidebar` 是 [资源]`TextStyles.plist` 10200 那档（24pt）。不传的话
            //   落到基线 spec 的 Dynamic Type `.largeTitle`（macOS 约 26pt），
            //   与 [AX] 实测的行盒 28（24pt bold 的行高）对不上。
            //
            // `isActive` 这里**不接**：容器切到待播盘就把这一片从视图树里摘掉，
            // `viewWillDisappear` 已经把每帧驱动停了；再按`isPlaying` 关一道，
            // 暂停时拖进度条就不会重新落行（整窗那边现在正是这样）。
            SyncedLyricsView(
                lyrics: lyrics,
                player: player,
                showsTranslation: showTranslation,
                showsTransliteration: showTransliteration,
                overrides: .init(horizontalMargin: MusicMetrics.Inspector.lyricsInset,
                                 sizeClass: .sidebar))
                // [AX] 翻译键是**窗口的直接子件**、不在歌词组里，所以浮在歌词之上
                // 而不是跟着滚；距面板右沿与窗底各 15。
                .overlay(alignment: .bottomTrailing) {
                    LyricsTranslationButton(hasTranslation: lyrics.hasTranslation,
                                            hasTransliteration: lyrics.hasTransliteration)
                        .padding(MusicMetrics.Lyrics.TranslationButton.inset)
                }
        }
    }

    private func inspectorEmpty(_ message: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 取词统一走 `LyricsStore`：同一首在这里与整窗歌词之间来回切只打一次网络，
    /// 命中缓存时同步就能拿到，连转圈那一帧都省了。
    ///
    /// 旧的 `track.id == self.track?.id` 竞态判断换成`Task.isCancelled`——
    /// 上面的 `.task(id:)` 换歌时会取消这一份，语义一样（旧请求回来不覆盖新歌），
    /// 而且不用再回头读一次 `self.track`。
    private func loadLyrics() async {
        guard let track else {
            lyrics = []
            return
        }
        if let cached = appState.lyricsStore.cachedLyrics(for: track) {
            lyrics = cached
            return
        }
        lyrics = []
        lyricsLoading = true
        defer { lyricsLoading = false }
        let loaded = await appState.lyricsStore.lyrics(for: track,
                                                       using: appState.provider(track.kind))
        guard !Task.isCancelled else { return }
        lyrics = loaded
    }
}
