# 待办（设置窗功能接线之后留下的）

> 与 [apple-music-catalog-todo.md](apple-music-catalog-todo.md) 同一种写法：只列没做完的，每条写清 Music 的规格来源、Amber 现状、要动哪些文件。

## 1. 遥控器：资料库浏览

- **Amber 现状**：`RemoteControlServer` 只做了配对、登录、播放控制、正在播放状态；
  `/databases/1/items`、`/browse` 回语法合法的空表，手机上「资料库」页是空的。
- **要做的**：按 DAAP 把 `LibraryStore` 的曲目/专辑/艺人/播放列表编成`adbs`/`abro`/`apso` 容器，
  支持 `query=` 过滤与`index=` 翻页；`ctrl-int/1/cue?command=play&query=…` 起播。
- **前置**：先用真机跑通现有的配对与控制（几个 `[推]` 的协议值要在真机上核实）。

## 2. 详情页曲目表的勾选列

- **Amber 现状**：勾选列只在资料库「歌曲」页（`SongsTableColumns`）；专辑/歌单详情页的`TrackTableViewController`
  只有一条 `NSTableColumn`，曲目画在`TrackRowView` 里，不共用列机制。
- **要做的**：`TrackRow*` 排一格勾选框，读写同一份`LibraryStore.uncheckedTrackIDs`。

## 3. 自动连播的剩余缺口

- **QQ 每补一批要多打一条详情请求**：`GetSimilarSongs` 只认数字 songid，而 Amber 的 QQ 曲目 id
  是 mid（`qq:004OJ2Hr0NDxI7`），`QQAPI.similarTracks` 先用`CgiGetTrackInfo` 换一次。
  要省掉这一跳得让 `Track` 带上音源的数字 id（`parseTrack` 现在只取 mid），
  那是改模型的事，收益只有一条请求，暂不做。
- **`simiSong` 一次只给 5 首**：`limit` 传官方默认的 50 也还是 5 条，`offset` 传 5/10/20/50
  回的都是同一批（服务端不认这个翻页参数）。[实测 2026-09-09 curl] 匿名 songid=1330348068。
  登录之后会不会多给没验过。**但这不是缺口**：种子跟着当前曲往前走
  （`PlayerController.refillAutoplayIfNeeded`），每播到一首新歌就再问一批 5 首，
  自动连播这条路本来就是无限的——别再因为「量不够」去给它接第二条召回。
- **`/api/link/position/show/resource`（「插播相似歌曲」）没并进来**：
  [api-enhanced] `module/song_simi_get.js`，`positionCode: "toolBarRcmdSong"`。
  [实测 2026-09-09 curl] 匿名 code 200，但一次只回一条 `commonResourceList`，
  里面只有 `resourceId` 一个数字 id，还得再打一条详情才成得了 Track，量还不如 simiSong。
- **QQ 的 `RecommendApi`**（`get_guess_recommend` / `get_radar_recommend` /
  `get_recommend_songlist` / `get_recommend_newsong`）与
  `TrackRelationServer/GetRelatedPlaylist`（相关歌单，`vecPlaylist` 传上一批 id 换一批）：
  那几条是「目录页的推荐段」，不是自动连播要的东西，要接归到目录页那份待办里。

## 4. 私人 FM 与心动模式：两个独立的播放模式，都还没做

> **它们不是自动连播的候选源。** 2026-09-09 把这两条接进过自动连播的分层召回，
> 接错了，已摘除：自动播放分区头上写的是「将播放类似歌曲」
> （`PLAY_QUEUE_AUTOPLAY_SUBTITLE`，实测自 Music 的 zh_CN`UserInterface.strings`），
> 「与当前这首相似」是这个功能对用户的承诺；而这两条在网易云各自是**独立的一种播放模式**，
> 发回来的歌与当前种子无关。实机 dump 就是证据：种子「起风了」，simiSong 给的是
> 「在你的身边／还是分开／哪里都是你」，FM 垫的是「MONTAGEM XONADA／DAY1／荒漠上行走」。
> 将来真要做，是连着各自的 UI 一起设计的两个功能，不是往队列里掺歌。
> 下面两段是那一轮已经验证过的信息，原样留着，做的时候不用再验一遍。

- **私人 FM**：`/api/v1/radio/get`，走 eapi，**无参数**（[api-enhanced]`module/personal_fm.js`）。
  [实测 2026-09-09 curl] 匿名（没有 `MUSIC_U`）照样回`code:200`；`data` 里**恒 1 条**，
  连打 6 条拿到 6 首互不相同的歌，6 条总共约 1.3 秒。未登录时发的是大盘热门而不是
  「你的口味」。曲目是明文接口那套字段（`artists` / `album` / `duration`），
  `NeteaseAPI.parseTrack` 直接认；档位节点叫`bMusic` / `hMusic`（不是`sq` / `hr`，
  所以 `losslessAvailable` 是 nil＝未知），碟号那一格叫`disc` 不是`cd`（取不到就是 nil）。
  UI 上它是「私人 FM」那种一首一首往下发的模式，还有「不喜欢」这类回流动作。
- **心动模式**（智能播放）：`/api/playmode/intelligence/list`，参数
  `songId` / `type: "fromPlayOne"` / `playlistId`（**必填**）/`startMusicId` / `count`
  （[api-enhanced] `module/playmode_intelligence_list.js`）。语义是「在某张歌单里按心动
  顺序播下去」，所以它天然绑着一张歌单，不是「找与这首相似的歌」。
  **要登录**：匿名只回 `{"code":301}`（[实测 2026-09-09 curl]，网易云的「未登录」码——
  这至少坐实了路径与参数没写错，写错回的是别的码）。**200 的响应形状从未实机验证过**：
  参考实现里每项是 `{"id": …, "songInfo": {歌曲对象}}`。哪天扫码登录之后，
  第一件事是把这条的真实响应对一遍。

## 5. 队列面板的惯性滚动吸附

- **Music 的规格**：`playqueue 规格` §3.11——`scrollViewBeganMomentum:withVelocity:
  targetContentOffset:` 里把惯性落点改写到最近的分区头行：`thr = min(rowHeight × N, 200)`，
  `velocity > 0` 判`0 < (minY − t) < thr`（单侧），`velocity ≤ 0` 判`−thr < (t − minY) < thr`（双侧）。
- **Amber 现状**：没做。那是 Music 的桌面界面层自家滚动视图的回调，`NSScrollView` 既拿不到惯性落点
  也改不了它。`PlayQueueViewController` 里留了`TODO`，阈值与两支判据已抄全。
  少这一条的表现只是「滑完不吸附到分区头」，§3.11 的 5 秒回滚仍会把面板带回正在播的位置。
- **要做的**：要么自己接管 `scrollWheel:` 做惯性模拟，要么等到有公开等价 API。优先级低。

## 6. 队列面板的三处小缺口

- **`displayStyle` 三档只接了写入侧**：`miniplayer 规格` §11.7 实测它由 `MPContentView`
  按形态写三档（全窗口 `{6,7,8}`→3、窗口化`{3,4,5}`→1、迷你横条`{0,1,2}`→2），
  但 `playqueue 规格` §3 通篇没有读取点——三档各自改了什么外观没坐实。
  Amber 已经把跳表接到 `PlayQueueViewController.displayStyle`，渲染侧一笔没动，挖到了直接填。
- **重复曲目的 item identifier 会重编号**：identifier 是 `"<trackID>:<第几次出现>"`，
  删掉靠前那次出现会让同一首歌后面每次出现的序号前移，那几行在 diff 里仍是「删 + 插」。
  要彻底消掉得在 `PlayerController` 侧给每个队列项发一个稳定的 slot id。
- **`TrackListPageController` 起播时的`queueSource` 没有`Route`**，只给了标题，
  所以「继续播放」分区头那行「来自：…」在这一页点不动。要补得从 `PageHosting.swift`
  把 route 一路传进来。

## 7. 歌单详情页缺 Music 的两个货架（建议歌曲 / 精选艺人）

- **Music 的规格**：`playlists 规格` §2.1.1（macOS 27 26A5425a 基线）第一次把这一页
  的排布读全了。`docStack`（竖直`NSStackView`，`alignment=Leading`）自上而下**六个**
  arranged subview，六次 `addArrangedSubview:` 的顺序就是这个

  1. `headerMargins` → header，边距 **0 / 40 / 30 / 40**
  2. `trackTable`（`Music.MusicTrackTableLockup`），无边距包装
  3. `AMPEmptyStateLockup`，无边距包装（与 2、4 共用`playlistIsEmpty` 那条`NSHiddenBinding`，
     只有它多带一个 `NSNegateBooleanTransformerName` 取反）
  4. `footerMargins` → footer，边距 **0 / 40 / 0 / 40**
  5. `suggestedContainer`（`AMPCollapsableView`）→ `suggestedMargins` → shelf.view，
     边距 **20 / 40 / 20 / 40**，`collapsed = !偏好开关`
  6. `artistsShelf`（`AMPCollapsableView`）→ 直接装 shelf.view，**没有边距包装**，
     `collapsed = !hasContents`

  边距那四参的顺序是 top / leading / bottom / trailing
  （`addAndAlignSubview:topMargin:leadingMargin:bottomMargin:trailingMargin:`）。
- **[AX] 实物量得到**：`playlist-detail.json` 里页脚 1862 之后还有两段——
  「看看哪些朋友聽過這張專輯」那块（区块 y=1943 高 204，标题 y≈2002，按钮「開始使用」y=2057），
  以及「精選藝人」货架（标题 y=2162、卡片带 2194–2362.8、卡片宽 **151**、卡间距 20、
  首卡左沿 **236.5** = 内容列 202.5 + 34）。整页内容列左沿 202.5、宽 1267.5。
- **Amber 现状**：`PlaylistDetailViewController` 的行只到页脚为止
  （`TrackTableViewController.RowKind` 就 header / columnHeader / track / empty / footer 五种），
  第 5、6 两段一个都没有。
- **要做的话数据从哪来**：
  - **精选艺人**：不用接口，本页曲目的 `Track.artist` 去重就能得到，
    卡片形态与艺人页那份圆头像卡（`LibraryGridCards`）同构，落点走`.artist` route。
    这条是纯本地计算，成本最低，可以先做。
  - **建议歌曲**：Music 那份是 Apple 的推荐引擎，Amber 侧没有等价物，
    要接音源的相似推荐（QQ `GetSimilarSongs` / 网易`simiSong`，接法与限制见上面第 3 节，
    注意 `simiSong` 一次只回 5 首）。做之前先想清楚「一张歌单的相似歌」用哪首当种子——
    Music 是整页级推荐，逐曲目召回再合并是另一回事。
  - 两段都要跟着 `AMPCollapsableView` 的收起语义：建议歌曲跟偏好开关，
    精选艺人跟「有没有内容」，没内容就整段不占高，而不是留一片空白。

## 8. 智能播放列表：Amber 没有这个形态

- **Music 的样子**（[实机截图 2026-09-09 23:54] 两张）：智能歌单的页头是「四宫格拼贴封面 +
  名字 + 副标题『智能播放列表』+ 一行红色的『⚙ 编辑规则』」，标题栏右端比普通歌单**多两颗键**，
  排在 ••• 左边：铅笔（编辑详情，弹「编辑播放列表」表单——封面走马灯 + 名称 + 描述（可选）
  + 取消/完成）与齿轮（编辑规则，弹经典的规则编辑器：「匹配下列条件：艺人包含告五人」+
  「最多 25 项选择标准随机」+「仅匹配勾选的项目」+「动态更新」+ 取消/好）。
- **[实测] 对应的实现**：`playlists 规格` §6.0（macOS 27 / 26A5425a 基线）——
  铅笔是 `canBeEdited`（对 playlist 判真）+`doEditDetails`；
  齿轮是 `canEditSettings`（`playlist != nil` **且** bit0 置位 **且**再对 playlist
  判一次真，**两道门**）+ `doEditSettings`。同页还有「刷新」
  （`canBeRefreshed`：`magic=='plst'` + bit0 + 非 0，**只对智能歌单出现**）。
  表单与规则编辑器整套在 `playlistedit 规格`（窗口高度公式
  `slotCount×162 + (slotCount-1)×10 + 162`、封面「配方」结构体、
  `SmartPlaylistEditorPredicateEditor` 那套`NSPredicateEditor` 覆写都在里面）。
- **Amber 现状**：完全没有智能歌单——`LibraryPlaylist` 没有类型枚举，也没有规则/动态更新。
  所以这两颗键、「刷新」那一条、以及 ☰ 里的「喜爱日期」之外的智能歌单专属排序都不存在。
  相关判据 [实测] §10.1：playlist 上有个歌单类型枚举（0 = 普通用户歌单、0x3d = 智能歌单），
  工具条那颗 ⋯ 只在 == 0 时出现——Amber 恒真也是因为只有普通歌单这一种。
- **要做的话**从数据层起：`LibraryPlaylist` 先有类型与规则（谓词 + 上限 + 选择标准 +
  仅匹配勾选 + 动态更新五样），再谈两颗键与那两个对话框。§13 复刻要点里那句
  「智能歌单类型要在数据模型层就存在，不能是 UI 层临时推断」说的就是这件事。
