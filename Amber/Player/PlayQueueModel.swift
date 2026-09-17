import AppKit
import Combine

// MARK: - 队列面板的视图模型
//
// 对应 Music 的 `ITPlayQueueModel`（[实测] playqueue spec §2）：面板
// `NativePlayQueueViewController` 唯一的数据源，自己不持有队列状态，
// 只从引擎（Amber 这边是 `PlayerController`）读出来切成四个分区。
//
// Amber 与 Music 的一处结构差：Music 的引擎 `ITMPCQueueControllerBehavior` 本来就把队列
// 存成 `PBPlayQueueSection` 数组，视图模型照`sectionKind` 分捡即可；Amber 的队列是一个
// 平铺的 `[Track]` ＋ 一条等长的`[QueueOrigin]`，所以分区要在这里推（见`sections`）。

/// 队列面板的四个分区。
/// [实测] playqueue spec §3.4：UI 侧 diffable data source 的 section tag 就是 **0…3**
/// （`Optional<Section>.none` 编码成 4，那是「普通数据行没有 section identifier」的意思，
/// 不是第五个分区）。与 §2.1 引擎侧的 `sectionKind`（1/3/4/5）**不是同一套编号**。
enum PlayQueueSection: Int, Hashable, CaseIterable {
    case history = 0, upNext = 1, continuePlaying = 2, autoplay = 3
}

/// 「混音」按钮当前是哪一档。
/// [实测] playqueue spec §1.5：`ITPlayQueueModel.mixingType` 就是
/// `playerControlsState.transitionStyle == 1` 这一个布尔切面，图标/标题在
/// `Crossfade` 与`automix` 两张图、`PLAY_QUEUE_CROSSFADE_BUTTON_TITLE` 与
/// `PLAY_QUEUE_AUTOMIX_BUTTON_TITLE` 两条文案之间翻。
enum PlayQueueMixingType: Hashable {
    case crossfade, automix
}

/// 面板里的一项。
///
/// `identifier` 是 diffable data source 的 item identifier，照
/// [实测] playqueue spec §1.1「内容项 ID 是结构化字符串、冒号分隔」的形状拼：
/// Amber 这边取 `"曲目 id:第几次出现"`——`occurrence` 是这一项在当前队列里
/// **同 `track.id` 的第几次出现**（从 0 起），用来满足「同一首歌在队列里
/// 出现两次＝两个不同 identifier」。它对位 §1.1 里 `makeContentItemID` 的
/// `repeatIteration` 那类「区分同一首歌的多次出现」的分量。
///
/// **队列下标不进 identifier。** §1.1 的三个分量里一个下标都没有，Amber 也不能有：
/// 面板走 `NSTableViewDiffableDataSource`，identifier 就是 diff 的身份。下标一旦进去，
/// 往队列中间插一首（「稍后播放」）或删一首，它**后面每一项的 identifier 都会跟着变**，
/// diff 只能判成「整批删掉、整批重插」——插一首歌整个下半张表重刷/重新淡入，
/// 而不是平滑地让一行挤进去。换成「第几次出现」，插/删只会影响同一首歌的后续出现，
/// 其余项的身份原样不动，diff 拿到的是一次真正的移动/插入。
///
/// （§1.2 的「循环一轮就把 `repeatIteration` +1 重铸 ID」Amber 没有对应机制——
/// Amber 的循环不复制队列项，同一首绕几遍还是同一行。）
/// 当前下标另存在 `queueIndex` 里，每次`sections` 重算，跳播/删除/重排都读它。
struct PlayQueueItem: Hashable, Identifiable {
    let identifier: String
    let queueIndex: Int
    let track: Track
    let section: PlayQueueSection
    var id: String { identifier }
}

@MainActor
final class PlayQueueModel: ObservableObject {

    /// 四个分区一次算出来的结果。分区推导是纯函数（见 `sections`），
    /// 这样面板的取数逻辑不用起 App 就能单测。
    struct Sections: Equatable {
        var history: [PlayQueueItem] = []
        var upNext: [PlayQueueItem] = []
        var continuePlaying: [PlayQueueItem] = []
        var autoplay: [PlayQueueItem] = []
    }

    private let appState: AppState
    private var player: PlayerController { appState.player }
    private var cancellables = Set<AnyCancellable>()
    private let observers = TaskBag()

    /// 四个分区。任何一个为空，面板就不 append 那个分区
    /// （[实测] playqueue spec §3.4：四对 `(tag, 数组)` 逐对判空，空的不进快照）。
    @Published private(set) var historyItems: [PlayQueueItem] = []
    @Published private(set) var upNextItems: [PlayQueueItem] = []
    @Published private(set) var continuePlayingItems: [PlayQueueItem] = []
    @Published private(set) var autoplayItems: [PlayQueueItem] = []

    // MARK: 两条独立的变更通知（[实测] playqueue spec §3.3 末）

    /// 「数据变了」——对位 Music 的 `kViewModelDataObservationContext`：
    /// 四个分区数组、循环信息行、顶部两颗按钮的状态变了，面板**只重建快照并 apply**，
    /// 不碰任何一行的高度（行高由 delegate 的 `tableView:heightOfRow:` 在 apply 过程中
    /// 逐行问，不需要额外通知）。
    let dataDidChange = PassthroughSubject<Void, Never>()

    /// 「来源变了」——对位 Music 的 `kViewModelSourceObservationContext`：
    /// `continuePlayingSource`（「来自《某专辑》」）变了，面板**只**对「继续播放」那一条
    /// 分区头行发 `noteHeightOfRowsWithIndexesChanged:`，因为那行有没有「来自…」
    /// 决定它是 58 还是 44（§3.5）。
    ///
    /// **为什么必须是两条而不是一条**：合成一条之后「数据变了」和「来源变了」分不开，
    /// 就只能每次 apply 完对全部行重问高度；而 `noteHeightOfRows` 内部会走一遍
    /// `endUpdates`，`endUpdates` 又把`apply` 的 completion 再打一遍——自己喂自己，
    /// 实机必然栈溢出（crash `Amber-2026-09-09-042558.ips`）。
    let sourceDidChange = PassthroughSubject<Void, Never>()

    init(appState: AppState) {
        self.appState = appState
        let player = appState.player

        // 面板会频繁问这四个数组（每次快照、每次行高、每次选区都要），所以订阅着重算一次存下来，
        // 不在 getter 里每次现推。`@Published` 是 willSet 语义（订阅到的是**改之前**的值），
        // 所以统一 `receive(on: DispatchQueue.main)` 推到下一跳再读，与仓库里其它订阅口径一致。
        Publishers.Merge3(
            player.$queue.map { _ in () },
            player.$queueOrigins.map { _ in () },
            player.$currentIndex.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.recompute() }
        .store(in: &cancellables)

        // 循环模式**改的是快照内容**（§3.4：`continuePlayingIsRepeating` 决定分区末尾
        // 追不追那条循环信息行），所以它走「数据」这一条，不走「来源」。
        player.$repeatMode
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.dataDidChange.send()
            }
            .store(in: &cancellables)

        // [实测] §3.3 末：`continuePlayingSource` 单独一条——它不改分区内容，
        // 只改「继续播放」分区头那一行的高度与文案。
        player.$queueSource
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.sourceDidChange.send()
            }
            .store(in: &cancellables)

        // 顶部两颗按钮读的是设置（见 `mixingEnabled` / `autoplayEnabled`）——属于「数据」。
        observers.observe({ AppSettings.shared.values }) { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.dataDidChange.send()
        }

        recompute()
    }

    private func recompute() {
        let result = Self.sections(queue: player.queue, origins: player.queueOrigins,
                                   currentIndex: player.currentIndex)
        historyItems = result.history
        upNextItems = result.upNext
        continuePlayingItems = result.continuePlaying
        autoplayItems = result.autoplay
        // [实测] §3.3 末：四个数组落定之后才发「数据变了」——`@Published` 是 willSet 语义，
        // 订阅方直接读 `historyItems` 会读到旧值，所以通知放在赋值之后自己发。
        dataDidChange.send()
    }

    // MARK: - 分区推导（纯函数）

    /// 把平铺的队列切成四个分区。
    ///
    /// [实测] playqueue spec §2.1 的对位：
    /// - `history`（kind 1）＝ `currentIndex` **之前**的项，与 origin 无关——
    ///   「历史」是位置不是来源，手动加的项播过去了照样落进历史；
    /// - `upNext`（kind 3）＝ 当前曲及其之后、origin ==`.manual` 的项；
    /// - `continuePlaying`（kind 4）＝ 同上、origin ==`.source` 的项；
    /// - `autoplay`（kind 5）＝ 同上、origin ==`.autoplay` 的项（自动连播续上的，
    ///   见 `PlayerController.refillAutoplayIfNeeded`）。
    ///
    /// **当前曲落在哪个分区**：Music 静态里没有直接证据（kind 2 那一档「没有对应缓存数组、
    /// 被跳过」，spec 自己标着 `[部分]`，猜是「当前播放中」的占位 section）。这里取
    /// 「当前曲留在它原本的分区里」——`.manual` 进 upNext、`.source` 进 continuePlaying，
    /// 与截图 `design-ref/ui-spec/pages/queue-panel.png` 里「正在播的那首就在『继续播放』
    /// 第一行、没有单独占一段」的观感一致。这一条是 `[推]`。
    ///
    /// `origins` 短于`queue` 时缺的那几项按`.source` 兜底：调用方保证两者等长
    /// （`PlayerController` 的硬不变式），这里只是不让它崩。
    static func sections(queue: [Track], origins: [PlayerController.QueueOrigin],
                         currentIndex: Int?) -> Sections {
        var result = Sections()
        for item in items(queue: queue, origins: origins, currentIndex: currentIndex) {
            switch item.section {
            case .history: result.history.append(item)
            case .upNext: result.upNext.append(item)
            case .continuePlaying: result.continuePlaying.append(item)
            case .autoplay: result.autoplay.append(item)
            }
        }
        return result
    }

    /// 同一份推导，但**按队列原序**交出来，不分捡进四个数组。
    ///
    /// 侧栏面板要的是分区（`sections`），整窗播放器那块盘`TrackSectionsPlatter` 要的是
    /// 一条平铺的清单——从前它自己按数组下标认行（`ForEach(...enumerated(), id: \.offset)`），
    /// 于是队列中间插一首/删一首，插入点之后每一行的身份都指到了另一首歌，整块盘从插入点
    /// 往下刷一片占位块再逐个淡回来（design-ref/reactive-ui-review.md §2.2）。
    /// 同一份队列在两处必须是同一套身份，所以身份只在这里生成一次，两边共用。
    ///
    /// `section` 照旧算出来跟着项走：平铺展示用不上它，但菜单与拖放要按分区判语义。
    static func items(queue: [Track], origins: [PlayerController.QueueOrigin],
                      currentIndex: Int?) -> [PlayQueueItem] {
        // 每个 track.id 已经出现过几次 —— identifier 的第二个分量，见 `PlayQueueItem`。
        var occurrences: [String: Int] = [:]
        var result: [PlayQueueItem] = []
        result.reserveCapacity(queue.count)
        for (index, track) in queue.enumerated() {
            let origin = index < origins.count ? origins[index] : .source
            let section: PlayQueueSection
            if let currentIndex, index < currentIndex {
                section = .history
            } else {
                switch origin {
                case .manual: section = .upNext
                case .source: section = .continuePlaying
                case .autoplay: section = .autoplay
                }
            }
            let occurrence = occurrences[track.id, default: 0]
            occurrences[track.id] = occurrence + 1
            result.append(PlayQueueItem(identifier: "\(track.id):\(occurrence)",
                                        queueIndex: index, track: track, section: section))
        }
        return result
    }

    // MARK: - 「继续播放」分区头（[实测] playqueue spec §2.1 / §2.4 / §3.6）

    /// 分区头副行「来自《…》」的名字。没有来源就不摆那一行。
    var continuePlayingSource: String? { player.queueSource?.title }

    /// 来源能不能点。[实测] §2.4：`continuePlayingSourceIsActionable` 为真才响应点击。
    /// Amber 这边＝起播时给没给 `Route`（单曲播放、目录卡上的 ▶ 这些就没有）。
    var continuePlayingSourceIsActionable: Bool { player.queueSource?.route != nil }

    /// 点「来自《…》」。走 `AppState.push`（现有的导航登记点，`ContentNavigationController`
    /// 订阅 `pendingRoute` 入栈），不自己造第二条路。
    func doContinuePlayingSourceClicked() {
        guard let route = player.queueSource?.route else { return }
        appState.push(route)
    }

    /// 循环播放信息行的开关。[实测] §3.4：分区 2 末尾**二选一**追加一条信息行，
    /// **先判循环**——这一条为真就摆 `RepeatingInfoCell`，不再看「还有 N 项」。
    /// Amber 这边只有「全部循环」会让队列绕回去；单曲循环不改队列，不算。
    var continuePlayingIsRepeating: Bool { player.repeatMode == .all }

    /// 「还有 N 首歌曲」的计数（[实测] §3.7 `MoreCountInfoCell`）。
    ///
    /// **Amber 恒 0**：Music 的队列是分页载入的，面板里只有前一段，剩下的用这一行报个数；
    /// Amber 起播时把整份列表一次全推进队列，没有「还有 N 项没载入」这回事。
    /// 于是那条信息行在 Amber 里永远不出现，但代码路径按 spec 保留——
    /// 哪天队列改成分页，只要这里返回真数就接上了。
    var continuePlayingMoreCount: Int { 0 }

    // MARK: - 顶部两颗按钮（[实测] playqueue spec §3.9）

    /// 「自动播放」可不可用 ＝ 这一队当前那首的音源交不交得出相似歌
    /// （`MusicProvider.supportsAutoplay`）。两家都有这条接口：
    /// - QQ：`music.recommend.TrackRelationServer` / `GetSimilarSongs`
    ///   （[QQMusicApi]；接口只认数字 songid，Amber 的 id 是 mid，`QQAPI.similarTracks`
    ///   先用 `CgiGetTrackInfo` 换一次）；
    /// - 网易云：eapi `/api/v1/discovery/simiSong`（`songid`/`limit`/`offset`，匿名可用）。
    ///
    /// 判据只看 `supportsAutoplay`，**不看登录态**：两家的相似歌曲接口匿名都打得通
    /// （[实测 2026-09-09 curl]），没有理由把未登录的人挡在 ∞ 之外。
    ///
    /// 按**当前曲**的音源判而不是按侧栏选中的音源：队列里放的是哪一家的歌，
    /// 续队列就得问哪一家。没起播时退回当前浏览的那个源，让面板一开就有个确定的态。
    /// §3.9 的绑定表里 `autoplay.enabled` 绑的就是它；`autoplay.value` 绑的
    /// `autoplayEnabled` 是`available && enabled`。
    var autoplayAvailable: Bool {
        appState.provider(player.currentTrack?.kind ?? appState.selectedProvider).supportsAutoplay
    }

    /// 自动播放开关的存放处。真正的续队列在 `PlayerController.refillAutoplayIfNeeded`——
    /// 它订阅着这个字段：翻开立刻补一批，翻关就 `clearAutoplayItems()`。
    var autoplayEnabled: Bool {
        get { AppSettings.shared.values.playQueueAutoplay }
        set { AppSettings.shared.values.playQueueAutoplay = newValue }
    }

    /// 「混音」可不可用。[实测] §1.5：Music 这一位是 `os_feature_enabled("Sonic", "Alchemy")`
    /// 的 feature flag；Amber 的过渡（交叉淡入淡出）是现成的，所以恒 true。
    /// §3.9：为假时整颗按钮 hidden。
    var mixingAvailable: Bool { true }

    /// [实测] §1.5：`mixingEnabled` → `playerControlsState.isTransitionsSupported`。
    /// Amber 这边「支持」与「开着」是同一件事，都落到设置里的「歌曲过渡」。
    var mixingEnabled: Bool {
        get { AppSettings.shared.values.crossfade }
        set { AppSettings.shared.values.crossfade = newValue }
    }

    /// [实测] §1.5：`mixingActive` → `playerControlsState.isTransitionsEnabled`。同上。
    var mixingActive: Bool { AppSettings.shared.values.crossfade }

    /// [实测] §1.5：`transitionStyle == 1` 那一档就是 automix。
    /// Amber 的「智能过渡」（`CrossfadeStyle.smart`）对位它——虽然实现上与自动过渡同一套
    /// （没有公开的调性/拍速分析 API，见 `SettingsValues.crossfadeStyle` 的注释），
    /// 但面板上该显示哪张图、哪条标题是按用户选的那一档来的。
    var mixingType: PlayQueueMixingType {
        AppSettings.shared.values.crossfadeStyle == .smart ? .automix : .crossfade
    }

    // MARK: - 行为（[实测] playqueue spec §2.2 / §2.3 / §3.10）

    /// 双击一行立即跳播（[实测] §2.3：`doDoubleClickActionForItem:` 直接
    /// `playQueue playItem:`，不走「先选中再按播放」的两段式）。
    func doDoubleClickAction(for item: PlayQueueItem) {
        player.playTrack(at: item.queueIndex)
    }

    /// 删除选中项（[实测] §2.3：单项走 `doDeleteActionForItem:`，多选走
    /// `removeFromPlayQueueActionWithItems:`；Amber 这边合成一条批量路径）。
    func doDeleteAction(for items: [PlayQueueItem]) {
        guard !items.isEmpty else { return }
        player.removeFromQueue(at: IndexSet(items.map(\.queueIndex)))
    }

    /// 「继续播放」分区头那颗「清除」（[实测] §3.6：按钮 enabled 绑
    /// `continuePlayingItems` 非空；§1.3 引擎侧是`clearAllItemsAfterContentItemID:`）。
    func doClearContinuePlaying() {
        player.clearContinuePlaying()
    }

    /// 分区内可不可以拖拽重排。
    ///
    /// [实测] §2.3 末尾那四个能力位（`canAddToContinuePlayingItems` /
    /// `continuePlayingItemsCanBeReordered` / `canAddToAutoplayItems` /
    /// `autoplayItemsCanBeReordered`）说明只读性是运行时判定的。Amber 的取值：
    /// - `history` 已经播过了，改它没有意义 → 否；
    /// - `upNext` / `continuePlaying` → 是；
    /// - `autoplay` 是猜出来的一段、随时会被下一个种子顶掉，手排没有意义 → 否
    ///   （Music 真机上这一段也通常整体只读）。
    func canReorder(_ section: PlayQueueSection) -> Bool {
        switch section {
        case .history, .autoplay: return false
        case .upNext, .continuePlaying: return true
        }
    }

    /// 队列内部拖拽重排（[实测] §2.2 `doReorderItemsWithIdentifiers:beforeItem:`）。
    /// `target` 为 nil ＝拖到最后（排到队尾）。
    func doReorder(_ items: [PlayQueueItem], before target: PlayQueueItem?) {
        guard !items.isEmpty else { return }
        player.moveInQueue(IndexSet(items.map(\.queueIndex)),
                           to: target?.queueIndex ?? player.queue.count)
    }

    /// 行内 ••• 与右键共用的同一份菜单（[实测] §3.8 / §3.10：
    /// `ampTableView:menuForRows:` 与行上那颗省略号都落到`actionMenuForItems:source:`）。
    ///
    /// Amber 直接复用全局那一份 `TrackActions`（目录卡、曲目行、详情页都用它），
    /// 只是多接一项「移除」，项序走它的 `queueRow()`——那一份正是照
    /// `-[ITPlayQueueModel actionMenuForItems:source:]` @ 实测的 8 段排布，
    /// 与本文件同源，不必在这里另排一份。标题用 Music 的原文 **「移除」**
    /// （`REMOVE_FROM_PLAY_QUEUE_SWIPE_ACTION`，zh_CN 下就是这两个字，
    /// 实测 `/System/Applications/Music.app/Contents/Resources/zh_CN.lproj/UserInterface.strings`）。
    func actionMenu(for items: [PlayQueueItem]) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let actions = TrackActions(
            tracks: items.map(\.track),
            appState: appState,
            // 菜单里的「播放」＝从这一行开始放、后面接着放，上下文就是整个队列。
            playContext: TrackPlayContext(tracks: player.queue, index: items[0].queueIndex),
            remove: (title: "移除", run: { [weak self] in self?.doDeleteAction(for: items) }))
        return MenuSpec.makeMenu(actions.queueRow())
    }

    /// 从外部拖进来的曲目落到队列里（[实测] §2.2 `acceptDropFromOutsideTable:beforeItem:`：
    /// 拖专辑/歌单进来时先展开成曲目再插入——展开归调用方，这里只管落点）。
    ///
    /// 落点在「继续播放」里就按 `.source` 插，其余都算用户手动加的（Up Next 语义）；
    /// 没有落点＝拖到最末，等同「加入待播清单」（`playLast`，落到 Up Next 末尾）。
    func acceptDrop(_ tracks: [Track], before target: PlayQueueItem?) {
        guard !tracks.isEmpty else { return }
        guard let target else {
            player.playLast(tracks)
            return
        }
        player.insertIntoQueue(tracks, at: target.queueIndex,
                               origin: target.section == .continuePlaying ? .source : .manual)
    }
}
