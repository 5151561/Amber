# 界面骨架的响应式审查与整改单

> 2026-09-17。审查对象：`Amber/Views/**`、`Amber/App/**`、`Amber/Services/LibraryStore.swift`、
> `Amber/Player/PlayQueueModel.swift`。标尺是现代响应式 UI 的四条原则：
> **状态驱动 UI、稳定 Identity、增量局部刷新（Diffing）、就地复用与保留现有内容**。
>
> 与 [appkit-rewrite-plan.md](appkit-rewrite-plan.md) 的分工：那份管「骨架换成什么」，
> 这份管「换完之后数据怎么流」。铁律仍以 `AGENTS.md`「界面层」一节为唯一副本。

## 0. 诊断

AppKit 改造把**渲染层**换现代了，**失效传播模型**还是 SwiftUI 那一套——而且丢掉了 SwiftUI 自带的 diff。

大量订阅写成 `objectWillChange.sink { 重算全部 + reloadData() }`：订阅只当「有事发生」的信号，
不看它带来的值；响应一律把整页从头算一遍。SwiftUI 时代还有框架的 diff 兜底，AppKit 里没人兜。

两个量化证据：

- `LibraryStore` 有 28 个 `@Published` + 5 处手工 `objectWillChange.send()`，约 30 个写入口，
  **全部只有一个出口**。资料库四页 + 歌曲页全订在这一个出口上。
- 「身份没变、内容变了」这一类（心水星、下载态、入库态）**没有就地更新的路径**，
  只能整页重灌，或者干脆不更新（后者就是下面的故障 1）。
  > **订正（2026-09-17）**：审查初稿把这条归咎于「`reconfigureItems` 全仓 0 次使用」，
  > 那是错的——`NSDiffableDataSourceSnapshot.reconfigureItems(_:)` 是 **UIKit 独有**，
  > AppKit 上根本没有这个成员（`swiftc -typecheck` 探针报`has no member`，
  > AppKit 头文件里零命中）。AppKit 只有 `reloadItems(_:)`，而它是销毁重建。
  > 就地重配得自己写：按身份问 `dataSource.indexPath(for:)` → `collectionView.item(at:)`
  > 拿在屏那一件、直接再 `configure` 一次（`CatalogPageViewController.reconfigure(_:)`）。

`CatalogPageViewController` 与 `PlayQueueViewController` 是做到位的两处，当仓库内的样板用。

## 1. 可复现的故障

每条都回读核过，行号为 2026-09-17 的 main + 工作区。

| # | 故障 | 根因位置 | 原则 | 状态 |
| --: | --- | --- | :-: | --- |
| 1 | 主页「最近播放」的心水星点了没反应，再点一次又加回去 | `Catalog/CatalogCardItemsShelf.swift:156,173`；`Shell/CatalogPageViewController.swift:402` 只订 `$recentContainers` | 1 | **已修**（批 C） |
| 2 | 多选后「从播放列表中删除」只删被点的那一首 | `Components/TrackRowView.swift:702` 交整份选中集，`Shell/TrackTableViewController.swift:477` 的 `remove` 写死单下标 | 1 | **已修**（批 B） |
| 3 | 资料库艺人页：一敲搜索框就丢选中，清空搜索也回不去 | `Shell/LibraryArtistsViewController.swift:425` `deselectAll` → `:733` 代理清 `selectedID` → `:387` 兜成「所有艺人」；全文件无 `isSyncing` | 1+2 | **已修**（批 A） |
| 4 | 歌单改名后侧栏高亮整个消失 | `App/AppState.swift:727` `SidebarItem.playlist` 的 `Hashable` 含 name，而 `id` 不含 | 2 | **已修**（批 接缝） |
| 5 | 详情页排序/筛选后选中高亮指向别的歌 | `Shell/TrackTableViewController.swift:282` 重载前后不按身份存取选区，`:518` 按 row index 反查 | 2 | **已修**（批 B） |
| 6 | 筛选状态下页头 ••• 的「插播/下载」作用于全表 | `Shell/PlaylistDetailViewController.swift:235` 不重 apply 页头；`Shell/DetailHeaderViews.swift:594` 捕获全量 `content.tracks` | 1 | **已修**（批 B） |
| 7 | 断网搜索显示「无结果」，回车重搜没有任何反应 | `Shell/SearchResultsModel.swift` 从不发 `.error`（五路全 `try?`）；`:227` 去重闸挡住重搜 | 1 | **已修**（批 C） |
| 8 | 「显示简介」里打字被异步回调吞掉（焦点丢失、组字被吞、滚回顶部） | `Shell/InfoPanelWindowController.swift:476` → `:255` 整块换 `documentView` | 4 | **已修**（批 E2） |
| 9 | 开关一个音乐源，工具栏被拆光重建三次；正在打字的搜索框被拔出来 | `Shell/CatalogPageViewController.swift:368` 每个缓存根页各挂一份且不判栈顶；`Shell/MainWindowController.swift:145` 强制重造整条 | 3 | **已修**（批 C） |
| 10 | 鼠标不动，悬浮态却乱了 | `Shell/LibraryGridCards.swift:133` 的 `!==` 短路 + `:229` `prepareForReuse` 清 `isHovering`；`Components/SongsTableView.swift:708` `rolloverRow` 是行下标 | 4 | **已修**（批 B/D） |
| 11 | 专辑页连改两次评分，第二下经常没反应 | `Shell/DetailHeaderViews.swift:1044` 每次 `refreshLibraryState()` 拆建 `ratingHost`，而该方法由 `player.$isPlaying/$currentIndex/$queue` 驱动（`Shell/TrackTableViewController.swift:552`） | 4 | **已修**（批 B） |
| 12 | 待播清单分区头「来自《某某》」连点五次压五层同页，各发一遍网络请求 | `Shell/ContentNavigationController.swift:99` 的 `push` 从不用 `Route` 的相等性 | 2 | **已修**（批 D） |
| 13 | 艺人页「最新發行」卡的 ＋ 与库不同步，会重复入库并弹两次 toast | `Catalog/ArtistPageCards.swift:681` 的 `cardAction` 是建卡时的快照 | 1 | **已修**（批 C） |
| 14 | 换标签时整片网格先消失变 spinner、滚动位置归零 | `Shell/CatalogRoomViewController.swift:294` 先 `apply(items: [])` 再等网络 | 4 | **已修**（批 C） |
| 15 | 进艺人页一两秒后所有货架集体闪一下重建 | `Catalog/ArtistPageModel.swift:74` 发两次 `.content`，段数 +1 必然改 `layoutSignature` → `invalidateLayout()` | 3 | **已修**（批 C） |
| 16 | 收起「播放中」期间换歌，再展开先看到上一首封面 | `Shell/NowPlayingHostController.swift:108` `host.isHidden = true` 让 SwiftUI 停更新（`Shell/PageHosting.swift:38` 自己记着这条规律） | 4 | **已修**（批 E1） |
| 17 | 大资料库里往下浏览时，表格自己滚回选中那首歌 | `Components/SongsTableView.swift:94` 的 `scroll:` 传 `rowsChanged`，被动刷新也滚 | 4 | **已修**（批 B） |
| 18 | 搜一个库里没有的词，看到带列头的一片纯空白、零文案 | `Shell/LibrarySongsViewController.swift:213` 空态判据是 `libraryTracks.isEmpty` 而不是 `rows.isEmpty` | 1 | **已修**（批 A） |

## 2. 系统性问题

### 2.1 原则 1 · 状态驱动

**粗粒度失效**。`LibraryStore` 一个出口，消费端一律全量重算：

| 页面 | 订阅 | 响应 |
| --- | --- | --- |
| 专辑 | `LibraryAlbumsViewController.swift:68` | 全库过滤+排序 + `:89 reloadData` |
| 所有播放列表 | `LibraryAllPlaylistsViewController.swift:61` | `:87 reloadData` |
| 最近添加 | `LibraryRecentlyAddedViewController.swift:64` | 重分组 + `:122 reloadData` |
| 艺人 | `LibraryArtistsViewController.swift:324` | 左表 + 右表**各一次** reloadData |
| 歌曲 | `LibrarySongsViewController.swift:178` | 全库过滤+排序（这一页有合批，其余四页没有） |

给一张专辑点一次喜爱 ★，以上全部跑一遍。而且**没有可见性闸门**——
`ContentNavigationController.swift:74` 的 `rootPages` 把访问过的根页全缓存着，隐藏的页照刷不误。
`pageDidAppear` 钩子已有，没用在这件事上。

侧栏是唯一订得细的（`SidebarOutline.swift:134` 订 `library.$playlists`），且有「没变就不重载」的闸门
（`:404`）——其余几页照抄它。

**自激**。`LibraryRecentlyAddedViewController.swift:102` 的 `updateDisplayTitle()` 写
`model.displayTitle`（`@Published`），而同一页又把 `model.objectWillChange` 接成整页重灌。
滚过一个段头 = 整页重灌一次。工具栏那条链（`ContentToolbar.swift:229`）本来就订 `$displayTitle`，
页面这条多余。

**事件当状态存**。`AppState` 上四个一次性意图靠消费方手工清空：`pendingRoute`(:25)、
`pendingLibraryArtistID`(:32)、`toastMessage`(:19)、`playlistNamePrompt`(:22)。
其中 `pendingRoute` 的清空**根本没生效**：`@Published` 在 willSet 发布，
`ContentNavigationController.swift:61` 那句 `= nil` 在外层赋值真正落存储之前就跑完，随后被覆盖。
这个字段永远停在最后一条路由上（`.trackGrid` 能带上百个 `Track`）。
同类的 `pendingLibraryArtistID` 多了一跳 `.receive(on:)`，是对的。
计划 §2 铁律 4 的终态是走响应链冒泡。

**多份真相**：

- 面板开合散在 5 处：`AppState.playerInspector` / `NSSplitViewItem.isCollapsed` /
  `InspectorContainerViewController.mode`（两实例）/ `MiniPlayerContentView.panelMode` /
  `NowPlayingViewModel.isQueueOpen` + `LyricsOptions.isVisible`，而且是**故意单向**同步
  （`MiniPlayerContentView.swift:161` 写了理由）。后果：整窗播放器那对布尔与全局那一位不通，
  第一次开「播放中」永远是歌词抽屉。
- 房间页「选中哪个标签」三份：`CatalogRoomViewController.swift:276` 同时写 `selectedTag` /
  `liveHeader` / `headerPrototype`（只为量高存在的影子实例）。
- `NowPlayingView.swift:27` 是一个 883 行、一个 body 的 struct，八个 `some View` 是 computed
  property 不是独立类型，所以没有各自的依赖集；同时 `@EnvironmentObject` 了三个上帝对象。
  一首歌播完 `notePlayed` 改 `playCounts` → 整棵重算。

**三态不是状态机**。`TrackTableViewController.swift:58` 的 `enum PageState` 是对的；
歌曲页用两个手工互斥的 `isHidden`（`:213`）、艺人页用 6 个开关拼形态
（`:363`/`:444`/`:478`，且早退那支不清 `artists`/`detailRows`）、网格三页没有 loading/error 的位置。

### 2.2 原则 2 · 稳定 Identity

- **掺下标**：`CatalogRoomViewController.swift:118` `RoomEntryID { index, id }`；
  `NowPlaying/TrackSectionsPlatter.swift:76` `ForEach(...enumerated(), id: \.offset)` + `.id(index)`。
  后者还与 `PlayQueueViewController` 构成同一份队列的两套实现、两种身份模型。
- **掺会变的内容**：`AppState.swift:727` `SidebarItem.playlist` 含名字；
  `CatalogFeedModel.swift:265` `id: "\(playlist.id)-\(playlist.name)"`
  （音源的每日/每周歌单标题常带日期。今天还咬不到人，因为 `.loading` 每次先清空整页，
  两份快照之间没有能退化的 diff——改走增量它第一个爆）。
- **用 row index 记状态**：详情页选区（故障 5）、歌曲表 `rolloverRow`（故障 10）、
  艺人页音轨选中（`LibraryArtistsViewController.swift:76`，`selectedTrackID = nil` 写在 `:458`
  而不是 `presentedID != selectedID` 分支里，于是任何一次资料库变动都把它抹掉）。
- **导航身份没用起来**：`Route` 是 `Hashable`，`push` 一次都没用到相等性（故障 12）。
  `Route` 的三个 grid 分支还直接带数组载荷；`.recentlyPlayed` 已经因为同样理由改成无载荷
  （`AppState.swift:802` 的注释写了原委），这三条没跟上。

### 2.3 原则 3 · 增量局部刷新

`reloadData()` 8 处 vs diffable 4 处，且 diffable 有 2 处把优势抵消掉了：

| 位置 | 问题 |
| --- | --- |
| `CatalogRoomViewController.swift:354` | `animatingDifferences: false` + **无条件** `invalidateLayout()` |
| `SearchLandingViewController.swift:220` | 同上。身份本身是干净的（`"brick:\(term)"`），白瞎了 |

`invalidateLayout()` 的代价目录页自己记着（`CatalogPageViewController.swift:692`）：
「横向货架里的 cell 会被整批重建、封面重新异步取，界面上就是闪一下」。

就地重配在 AppKit 上没有现成 API（见 §0 的订正），故障 1、13 要自己写一条「按身份找到在屏那一件、再 configure 一次」的路径。

### 2.4 原则 4 · 就地复用

- **先清空再填**：`CatalogRoomViewController.swift:294`（故障 14）；
  `CatalogFeedModel.swift:76` 的 `.loading` 清空整页（这条注释里写明是有意取舍，
  但同一批里 `SearchResultsModel.swift:65` 选的是另一条——旧结果留着，两种口径）。
- **拆掉重建而不是改属性**：`DetailHeaderViews.swift:1044`（评分星 + 整棵 `NSMenu`，故障 11）、
  `:452`/`:1012`（简介视图、无损徽标；`ExpandableTextView` 有内部状态，整块换新等于全丢）、
  `Components/TrackRowView.swift:258`（换形态时 14 件子视图全拆全建，而 `.detail` ↔
  `.libraryAlbum` 只差一列星级）、`CatalogRoomHeaderView.swift:341`（整排胶囊全拆全建，
  让 `:141` 那句「只改样子不重建整条」的承诺在换标签这条路上落空）。
  正确写法就在隔壁：`DetailHeaderViews.swift:523` 的 `PlaylistHeaderView.refreshLibraryState`
  只改符号和使能，不拆任何视图。
- **常驻被打折**：`NowPlayingHostController.swift:108`（故障 16）。
- **滚动位置被抢**：`SongsTableView.swift:94`（故障 17）。

## 3. 已经做对的，别动

1. `CatalogEntryID`（`CatalogPageViewController.swift:494`）：不含位置，段内重复靠 `occurrence`，
   第一件永远是 0。
2. 版式指纹 + 条件失效（`:689`）：只有段序/段样式/每段件数真变了才 `invalidateLayout()`，
   并论证了为什么不把容器宽写进指纹。**全仓唯一把增量做到位的地方，§1 的多条修法都抄它。**
3. 待播清单的 identity（`Player/PlayQueueModel.swift:51`）：`"\(track.id):\(occurrence)"`，
   occurrence 跨分区连续计数——同一首歌在历史段和队列段不撞 ID，分区不进 identifier 所以
   「播成历史」是 move 不是 delete+insert，下标故意不进。代价在注释里认了。
4. `AppState` 真的不转发子 store（`AppState.swift:321` + `AmberTests/AppStateForwardingTests.swift:88`
   的反向断言钉死）。
5. 播放进度没把界面拖下水：`PlaybackClock` 独立（`Player/PlayerController.swift:14`），
   SwiftUI 侧 `PlaybackTimeReader` 把重画关在闭包里，AppKit 侧直接订 `clock.$time` 只改那几个 field。
6. 导航栈返回真的复用 VC（`ContentNavigationController.swift:159`，页面视图一律不摘只切 `isHidden`）。
7. 检查器是两个常驻子控制器交叉淡入，不是抽换 rootView（`InspectorContainerViewController.swift:16`）。
8. 异步封面全线有身份校验：`Components/Components.swift:226` 的 `.task(id:)` + `requested == requestURL`；
   `Catalog/CatalogCardItems.swift:208` 的 `requestToken`。典型的「串图」bug 不存在。
9. `SearchResultsModel` 的状态机：世代号去抖 + 三重竞态 guard，新词提交后旧结果原地留着
   ——原则 4 的正确形状（只差 `.error`）。
10. `SongsTableController`：`selectedTrackIDs()/restore()` 按 id；`update(rows:)` 有真正的变更判定，
    没变只走 `refreshTextCells()` 就地改文字。
11. `refreshVisibleRows` / `refreshTrackStates`：播放态、下载进度走「重调可见行 configure」，
    不碰 `reloadData`。
12. 两个播放器的元数据按字段更新，订阅逐条拆开，`updateBadge` 自己去重
    ——这批 `isHidden =` 是有分工的 setter，不是散弹。
13. 0 宽闸门三处一致（`CatalogPageViewController.swift:629`、`CatalogRoomViewController.swift:333`、
    `SearchLandingViewController.swift:200`），挡下的快照在 `viewDidLayout` / `pageDidAppear` 补灌。
14. 货架横滚位置按 `section.id` 存（`CatalogPageViewController.swift:1375`），不是按段序号。
15. 侧栏：细粒度订阅 + 变更闸门 + `isSyncing` 护栏 + `SidebarNode` 覆写 `isEqual/hash` 落在值上。
    除了 `SidebarItem` 含 name 那条，这一块是全仓最干净的。

## 4. 整改批次

按文件所有权切，各批文件**不重叠**，可并行。

| 批 | 主题 | 覆盖 | 文件 | 状态 |
| :-: | --- | --- | --- | --- |
| **A** | 资料库失效粒度 | 故障 3、18；§2.1 粗粒度与自激 | `Services/LibraryStore.swift`、`Shell/Library{Albums,AllPlaylists,RecentlyAdded,Artists,Songs}ViewController.swift` | **已完成** 2026-09-17 |
| **B** | 详情页与曲目表 | 故障 2、5、6、10（后半）、11、17；§2.4 拆建 | `Shell/TrackTableViewController.swift`、`Shell/PlaylistDetailViewController.swift`、`Shell/DetailHeaderViews.swift`、`Components/TrackRowView.swift`、`Components/SongsTableView.swift` | **已完成** 2026-09-17 |
| **C** | 目录页 / 房间页 / 搜索 / 工具栏 | 故障 1、7、9、13、14、15；§2.3 | `Shell/CatalogPageViewController.swift`、`Shell/CatalogRoom{ViewController,HeaderView}.swift`、`Shell/Search{ResultsModel,LandingViewController}.swift`、`Catalog/{CatalogCardItemsShelf,ArtistPageCards,ArtistPageModel,CatalogFeedModel}.swift`、`Shell/MainWindowController.swift` | **已完成** 2026-09-17 |
| **D** | 身份与导航 | 故障 4、10（前半）、12；§2.2 | `App/AppState.swift`、`Views/SidebarOutline.swift`、`Views/LibraryPlaylistViews.swift`、`Shell/LibraryGridCards.swift`、`Shell/ContentNavigationController.swift`、`NowPlaying/TrackSectionsPlatter.swift` | **已完成** 2026-09-17 |
| **E** | 中等工程量，单独排 | 故障 8、16；§2.1 面板开合单一真值、`NowPlayingView` 拆子视图；`pendingRoute` 改响应链 | `Shell/InfoPanelWindowController.swift`、`Shell/NowPlayingHostController.swift`、`NowPlaying/NowPlayingView.swift`、`Shell/MainSplitViewController.swift`、`Shell/MiniPlayerContentView.swift` | **已完成** 2026-09-17（拆成 E1/E2 两批） |

`SidebarItem.playlist` 去掉 name 是横跨 A/B/C/D 的接缝（调用点在 `DetailHeaderViews.swift:667`、
`LibraryGridCards.swift:480`、`LibraryPlaylistViews.swift:57`），**在切批次之前由主会话一次改完**，
四批从同一棵树起步。

### 收工标准（每批都要）

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` + `-derivedDataPath`（见 AGENTS.md）
- `AmberTests` 全绿；跑测试会碰真实偏好与真实资料库（`am-tests-share-real-defaults`、
  `am-tests-launch-real-app-tasks`），测试期数据可随意改
- 改了界面骨架的批次，合回前由主会话跑一次 `./Tools/run.sh` 实机起一遍（编译过 ≠ 能起来）
- 像素一个不改：这一轮只动数据流，不动版式

## 5. 第一轮整改的结果（2026-09-17）

A/B/C/D 四批并行落地，`SidebarItem.playlist` 去掉 `name` 那道横跨四批的接缝由主会话先改。

### 收工核对

- 整树 `xcodebuild build`：**BUILD SUCCEEDED**，无新增警告
  （剩下三条 `LibraryArtistsViewController` 的 `'as' test is always true` / 未用变量，
  `git show HEAD:` 里逐条对得上，只是行号被推移）。
- `xcodebuild test`：**934 项全绿**。`AppStateForwardingTests` 里那条侧栏身份用例跟着改了
  （标题那一档改成空串），另加 `testRenamingPlaylistKeepsSidebarIdentity` 钉住「改名不换身份」。
- `./Tools/run.sh` 实机：起得来，主页 698 行视图树、歌曲页 1333 行都正常
  （工具栏 5 件：标题「歌曲」/ 弹性空位 / 筛选 / 搜索框 / 面板分隔件；表 108 行）。
- 启动后 CPU 约 100%、内存 174→280 MB：`sample` 打下来全在 `LoudnessStore.scan`
  （`LoudnessMeter.Accumulator.append` → `Biquad.process`，Debug `-Onone`），主线程栈是空的。
  这两个文件本轮一批都没碰，**不是本轮引入的**；但它值得单独排一条。

### 几处与原计划不同的决定

1. **导航 push 只做「栈顶去重」，不做「栈里已有就 pop 回去」。** 后者会把
   「专辑 → 艺人 → 又回同一张专辑」这种合法绕圈的中间几层连同滚动位置一起吞掉；
   而且 `Route` 的载荷是整份值，`Route.album(of:)` 造的是 `trackCount: 0` 的合成 `Album`，
   同一张碟从不同入口进来根本不相等，按「栈里有没有」判会时灵时不灵——比不判更糟。
   栈无限长改由 `ContentNavigationController.trimToMaxDepth`（上限 16，顶到了从栈底往上丢）兜底。
2. **`LibraryStore` 的细出口做成了私有 `PassthroughSubject` + 唯一入口 `changes(affecting:)`**，
   不暴露裸 subject——不留「订上就什么都收」的口子，那正是 `objectWillChange` 今天这副样子的由来。
3. **艺人页 hero 的 ★ 也一起接上了**（原计划标的优先级低），它与 `.release` 卡共用同一条订阅。
4. **搜索的 `.error` 只在五路全抛时才发**，部分失败仍摆已拿到的段——音源常年某一路 400。

### 这一轮新暴露、还没处理的

| 位置 | 问题 | 归属 |
| --- | --- | --- |
| `Player/LoudnessMeter.swift`、`Services/LoudnessStore.swift` | 启动后响度扫描把一整个核吃满且不让步，Debug 下尤甚 | 新开一条 |
| `Providers/MusicProvider.swift` 的 `playlists(tag:)` | 不 throw，失败返回 `[]`——房间页「探索更多」断网时显示「这个分类暂时没有内容。」，与故障 7 同病。修它要先改 provider 协议签名 | 批 E 或单列 |
| `Shell/CatalogRoomViewController.swift` | 整页没有错误态（`updateOverlay` 只有 loading / empty 两档），补「重试」要照目录页引擎再铺一遍覆盖层 | 同上 |
| `App/AppState.swift:813-817` | `.albumGrid` / `.playlistGrid` / `.trackGrid` 把整份数组算进 `Hashable`。改法：加一个「跟着走但不参与身份」的载荷壳（`==` 恒真、`hash` 空），分支补一个作用域化的 `key`。**坑**：`CatalogSection.id` 不是全局唯一的（每位艺人的「专辑」段 id 都是字面量 `"artist-albums"`），今天不撞纯粹是因为数组不一样——载荷一退出身份，key 必须写成 `"artist:\(artist.id)/\(section.id)"` 这种 | 批 E |
| `App/AppState.swift:806` `LocalTrackList` | 同一个病：合成的 `Hashable` 把整份 `tracks` 算进去了，而它自己明明有 `id`。心水卡每次求 `route` 都现拼一份全量 tracks，两次取值只要库变过就不相等 | 批 E |
| `Shell/PageHosting.swift:232` `LibraryPageModel.displayTitle` | 「一次性显示态」混在四页共用的模型里，只有最近添加写它。A4 只切断了页面那条订阅，隐患还在 | 批 E |
| `Shell/LibraryArtistsViewController.swift:400` 一带 | 早退那支不清 `artists` / `detailRows`，两张表端着上一轮数据挂在隐藏的分栏里。要把这一页 6 个开关收成一个状态枚举（工程量与 A7 相当） | 单列 |
| `Views/Components/TrackTableContract.swift` | `TrackRowConfiguration.remove` 仍是 `(() -> Void)?`。B1 走的是「由控制器按选中集重算」那条，字段没变成死字段，但日后要收口应改成 `(([Track]) -> Void)?` | 随手 |

### 要用户实机点的（鼠标类，按 `am-interaction-tests-by-user`）

1. 主页「最近播放」的单曲卡点心水星 —— 星应该当场跟着变，不用再点第二次。
2. 资料库艺人页选中某位艺人，在搜索框敲一个不匹配他的词 —— 右侧不该退成「选择艺人」，
   清空搜索应该还停在他身上。
3. 侧栏选中一份播放列表 → 右键重命名 —— 侧栏高亮不该消失。
4. 歌单页选中第 6 首，换一个排序键或敲一个搜索字符 —— 高亮应该跟着那首歌走。
5. 歌单页搜出 3 首，页头 ••• 的「插播 / 下载」应该只作用于这 3 首。
6. 专辑页连着改两次评分、或按住拖过五颗星 —— 第二下要有反应。
7. 光标停在资料库网格一张卡上不动，让一个下载完成 —— 暗罩与悬浮播放键应该原样还在。
8. 「最近添加」滚过段头 —— 标题跟着换，但卡片不该整页闪。
9. 待播清单分区头「来自《某某》」连点五次 —— 只进一层，按一次返回就出来。
10. 整窗播放器待播盘里「稍后播放」插一首 —— 插入点以下的封面不该整片刷成占位块。
11. 断网搜一个词 —— 应该给错误态 + 「重试」，而不是「无结果」。
12. 只启用一个音乐源时看一眼目录页标题栏（C9 唯一可能碰到排布的地方：
    标识符从 `[flexibleSpace, panelSeparator]` 变成 `[panelSeparator]`）。

## 6. 第二轮整改的结果（2026-09-17）

批 E 拆成 **E1（面板开合单一真值 + 整窗播放器）** 与 **E2（信息面板 + 路由身份）** 并行，
另开 **批 L** 修实机量到的响度扫描吃满一核。接缝由主会话先改：把 `Route` / `LocalTrackList` /
`RecentContainer.resolve` 从 `AppState.swift` 搬到 `Amber/Models/Route.swift`
（E1 要改 `AppState`、E2 要改 `Route`，不搬就是同文件撞车；顺带 `AppState` 从 874 行瘦到 789 行）。

### 收工核对（这一轮做全了）

- 整树 `xcodebuild build`：**BUILD SUCCEEDED**。
- **警告做了完整比对**（`git worktree` 出一棵 HEAD 各建一次，去重后对比）：
  **零新增**，还消掉 3 类（未用变量 `index`、`equalPowerNodes` 与 `offlineQueue` 两条 Swift 6 actor 隔离）。
  > 订正：§5 那句「无新增警告」是基于过滤过的 grep 得出的，口径不严；这一轮是全量 diff。
- `xcodebuild test`：**942 项，0 失败，1 项 skip**（L 加的手动基准）。上一轮是 934 项。
- `./Tools/run.sh` 实机：起得来。

### 批 L：真根因不是我猜的那三条

我从一次 5 秒采样推的三条（热循环反复分配数组 / `[[Float]]` 接口逼出拷贝 / 不让步不取消）里，
只有第三条是主因，而且**漏了决定性的一条**：

**`AVAudioFile.read(into:frameCount:)` 读到文件尾是抛 `eofErr`（OSStatus −39），不是回 0 帧。**
旧循环 `while true { do { try read } catch { return nil } }` 于是**每一首都走进 catch、整首作废**。
主会话独立复现过（`晴天 - 周杰伦.flac`：第 2904 次读抛 −39）。旁证：
`~/Library/Application Support/Amber/loudness.json` 长期只有 **1 条**（那条是「整首播完」的实时 tap 写的）。
也就是说离线扫描**从来没有产出过一条结果**，每次启动都把整个资料库重烧一遍——
「十几秒不收敛、每次开机都来一遍」的根在这里，不在 DSP 快慢。

修法与实测（L 的隔离基准，DYLD interpose 精确计数分配、耗时取 3 次最小值）：

| 场景 | 改前 | 改后 |
| --- | --- | --- |
| Debug `-Onone`，真实 m4a 187 s | 5.608 s，99,078,545 次 malloc | 0.373 s，52,990 次（**15.0× / 1,870×**） |
| Release `-O`，同一文件 | 0.180 s，42,529 次 | 0.147 s，28,720 次 |
| 节流前后占一个核（Debug，flac 342 s） | 100% | **37%** |

- 读循环按 `file.length` 收口，EOF 不再靠抛异常发现；异常路径改成「把已量到的交出去」。
- K 加权两节 + 峰值 + 平方和**融成一趟**，热循环零分配；内层一律 `while`
  （Debug 下 `for i in 0..<n` 每圈 1 次 malloc / 76 ns，`while` 0 次 / 4 ns，实测 20 倍）。
- **没有用 vDSP**：`vDSP_svesq` 是 `Float` 累加，现有离线路径是 `Double`，换过去数值会动——那是改语义。
- 数值逐位一致：改前/改后两份实现跑同一批 8 个真实文件，`lufsBits` / `peakBits` 零差异；
  新增钉住数值的回归测试（固定种子信号，误差上界 1e-9）+ 数组入口与指针入口位型相等 + eofErr 回归。
- 让步：首内「算 20 ms 睡 30 ms」（睡自家串行队列的线程，背后没人排队）、首间 0.25 s。
  代价：300 首的库约 6 分钟才全部有数——**对比改前是「永远没有数」**。

**实机复量（主会话）**：CPU 从 99–163% 降到 **13–22%**，RSS 从 174→280 MB 爬升变成**平稳 174 MB**；
`loudness.json` 一分钟内从 1 条涨到 **11 条**，峰值分布健康（6 个顶到 0 dBFS、5 个在 −0.1 ~ −2.32），
LUFS 范围 −15.5 ~ −8.0。端到端跑通。

### 几处决定

1. **整窗播放器收成单档**（一次只开歌词或待播盘，不再并存）。这是**用户拍板**的产品决定：
   主会话曾以「功能回退」为由要求恢复双抽屉，被驳回。`platterHeight` 里那支
   「歌词也开着 → 盘只占下半截」因此到不了，已删；注释写明要找回来该改 `NowPlayingViewModel` 那一位。
2. **面板状态拆成两位**：全局 `AppState.inspectorMode`（哪一档，永不为 nil，收起也记着）
   + 每个宿主自己的「开着没有」（主窗 `isInspectorOpen` / 迷你窗 `currState` / 整窗 VM 一位）。
   从前 `playerInspector: PlayerInspector?` 里 nil 既表示收起又抹掉档位，拖收一次就忘了上次那一档。
   新测试 `testInspectorKeepsModeWhenToggledClosed` 钉住这一条。
3. **`Route` 的载荷退出身份**用 `RouteCargo`（`==` 恒真、`hash` 空）。key 作用域化后
   主会话独立复核过：主页 18 段 / 新发现 14 段 / 广播 3 段，单页内无重复、**跨页零同名**，
   再叠音源与艺人 `kind:id`——不会把两页判成一页。
4. **收起「播放中」不再用 `isHidden`**（那会连 SwiftUI 的更新一起停掉），改 `alphaValue = 0` +
   关命中测试与 AX。随之给 `PlaybackTimeReader` 加了 `isActive` 闸——必须靠「换掉视图」断订阅，
   `@EnvironmentObject` 声明即生效，在 body 里绕开读取没用。于是「收起后 CPU ≈ 0」现在是完整的。

### 没能自证的

**E1-3 把 `NowPlayingView` 从 883 行一个 body 拆成 12 个子视图，「排版等价」只有静态论证。**
`-nowplaying -dumpviews` 在**改前改后都**捕获不到那片覆盖层（工具本身的限制，不是本轮引入），
所以拿不到逐行比对。主页与工具栏的 dump 倒是比了：逐行相同，唯二差别都无害——
HEAD 那个弹性空位本来就是 `hidden=true`（C9 删掉它确实不占位），另一处是补充视图的兄弟顺序、frame 一致。
**整窗播放器的版式请实机看。**

### 还没处理的

| 位置 | 问题 |
| --- | --- |
| `Services/LoudnessStore.swift` | 新下载的歌排在启动补量队列**后面**。给 `measureIfNeeded` 加个带默认值的优先级参数、`AppState.onDownloaded` 那行传一下即可 |
| `Player/LoudnessMeter.swift` | 节流占空比（37%）只有一次性基准的数，没写成测试（计时类断言天生易抖） |
| `App/AppState.swift` | `pendingRoute` 走响应链（铁律 4）仍未做：`RouteLink.swift` 那 21 处 SwiftUI `NavigationLink` 垫片还在，响应链够不到它们。载荷虽已退出身份，这个字段仍攥着那份数组 |
| `Shell/LibraryArtistsViewController.swift` | 早退那支不清 `artists` / `detailRows`，要把 6 个开关收成状态枚举 |
| `Shell/CatalogRoomViewController.swift` + `Providers/MusicProvider.swift` | 房间页没有错误态；`playlists(tag:)` 不 throw，断网时显示「这个分类暂时没有内容。」 |
| `Components/TrackTableContract.swift` | `TrackRowConfiguration.remove` 仍是 `(() -> Void)?`，日后收口应改成 `(([Track]) -> Void)?` |
| `AGENTS.md` | 「宿主被 `isHidden` 收起时 SwiftUI 停更新」这条规律值得提进界面层一节——本轮故障 16 与信息面板都踩在同一条上 |

### 要用户实机点的（补充 §5 那 12 条）

13. 整窗播放器：点待播清单会把歌词换掉（单档，这是设计）；第一次开「播放中」不再默认弹歌词抽屉。
14. 主窗面板开着待播清单 → 打开迷你窗，抽屉档位与主窗胶囊两颗键的高亮应一致。
15. 收起「播放中」→ 在迷你播放器换一首歌 → 再按开，应直接是新歌封面，不再先闪上一首。
16. 主窗面板选待播清单后关掉 → 开「播放中」→ 点歌词键开在歌词、再点收起 → 回主窗开面板仍是歌词。
17. **整窗播放器的版式**（E1-3 拆子视图后唯一没自证的地方）。
18. 「显示简介」里一边打字一边等流派探测回来，焦点、输入法组字、滚动位置都不该被吞。
