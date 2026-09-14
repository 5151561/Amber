# 音源接口移植清单

> 目标：把两份第三方实现里 Amber 用得上的接口**全部接进网络层**，先不管界面。
> 「界面缺什么」是下一轮的事，这一轮只保证「要做某个功能时，接口已经在手上」。
>
> 参考实现（判断某条能力有没有，先查这两份，别凭印象下结论）：
> - 网易云 <https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced> `module/*.js`（439 条，
>   一个文件一条接口，文件头一行中文注释是名字，正文写明路径、参数、走哪条通道）
> - QQ 音乐 <https://github.com/l-1124/QQMusicApi> `qqmusic_api/modules/*.py`
>   （`_build_cgi(module=…, method=…, param=…)` 直接对应 Amber 的 `musicu`），
>   `qqmusic_api/models/*.py` 是响应形状

## 记法

- **状态**：`已有` = 这一轮之前就在 Amber 里；`第一轮` / `第二轮` = 本次移植的批次；`不接` = 判断过、故意不做。
- 每条接口在代码里都要带出处标记（`[api-enhanced] module/xxx.js` / `[QQMusicApi] modules/xxx.py`）
  与验证标记（`[实测 <日期> curl]`，或明说「匿名回 XXX，成功态未实机验证」）。
  **实测标记是承诺**，没打过 curl 就不许写。

## 这一轮之前 Amber 有的（基线）

搜索五类、目录页三页取数、歌单/专辑/艺人详情、相似歌手、相似歌曲、账号歌单（只读）、
取流、歌词（含逐字）、MV 取流、扫码登录、榜单列表。

两条基线接口这一轮起对外可用（原先是 `private`）：`NeteaseAPI.get/getInterface`、`QQAPI.musicu`、
`QQAPI.songID(mid:)`、两家的 `catalogCache`。

## 共享模型（`Amber/Providers/ProviderAPIModels.swift`）

`FavoriteTarget` / `FavoriteCounts` / `MusicLibraryWriting`、`HotSearchItem` / `SearchSuggestion` /
`MusicSearchSuggesting`、`CommentTarget` / `MusicComment` / `CommentPage` / `MusicCommenting`、
`PlayRecordItem`、`ProviderUserProfile`、`TrackCredit`。

只有一家有的（网易云盘、QQ 不喜欢名单）留在各自的扩展文件里，不往共享文件里凑。

## 第一轮（已落地 2026-09-09）：收藏写入、搜索建议、推荐、账号

| 家 | 文件 | 覆盖 |
| --- | --- | --- |
| 网易 | `NeteaseAPI+Library.swift` | 红心、喜欢列表、歌单增删歌、建/删/改歌单、收藏歌单/专辑/歌手/MV/电台、收藏计数 |
| 网易 | `NeteaseAPI+Search.swift` | 搜索建议（移动/PC）、热搜榜、默认搜索词、多类型搜索、cloudsearch |
| 网易 | `NeteaseAPI+Discover.swift` | 每日推荐歌曲/歌单、历史每日推荐、私人 FM + 垃圾桶、心动模式、推荐 MV、独家放送 |
| 网易 | `NeteaseAPI+Account.swift` | 用户详情、听歌排行、最近播放（歌/专辑/歌单）、云盘（列表/详情/删）、VIP、等级、登出、刷新、听歌打卡 |
| QQ | `QQAPI+Library.swift` | 歌单增删歌、建/删歌单、收藏歌单/专辑、收藏 MV 列表、「我喜欢」当红心 |
| QQ | `QQAPI+Search.swift` | 热搜、智能补全、快速搜索、综合搜索 |
| QQ | `QQAPI+Recommend.swift` | 猜你喜欢、雷达、推荐歌单、推荐新歌、首页 feed |
| QQ | `QQAPI+User.swift` | 用户主页、VIP、关注歌手/用户、粉丝、好友、不喜欢名单、登出 |

## 第二轮（已落地 2026-09-09）：电台播客、评论、视频、歌手页、歌曲附加信息

| 家 | 文件 | 覆盖 |
| --- | --- | --- |
| 网易 | `NeteaseAPI+Radio.swift` | 电台分类/精选/详情/节目/节目详情、订阅与订阅列表、电台各榜、广播电台（voice/broadcast）、助眠解压 |
| 网易 | `NeteaseAPI+Comments.swift` | v2 统一评论、热评、点赞、发/回/删、评论计数 |
| 网易 | `NeteaseAPI+Video.swift` | MV 详情、全部 MV、MV 榜、独家、相似 MV、视频详情/取流/分类、相关视频、歌曲相关视频 |
| 网易 | `NeteaseAPI+Artist.swift` | 歌手头图信息、介绍、全部专辑、相关 MV、热门 50、粉丝数、歌手分类、热门歌手 |
| 网易 | `NeteaseAPI+SongInfo.swift` | 音乐百科、创作者、副歌时间、音质详情、灰色歌曲其他版本、动态封面、红心数、旧版歌词 |
| 网易 | `NeteaseAPI+Style.swift` | 曲风列表/详情/歌曲/专辑/歌手/歌单、曲风偏好；榜单详情 v2、指定维度榜 |
| QQ | `QQAPI+Comments.swift` | 评论数、热评、最新评论、推荐评论、发/删评论 |
| QQ | `QQAPI+Video.swift` | 歌手 MV 列表、视频信息批量、歌曲相关 MV |
| QQ | `QQAPI+SongInfo.swift` | 歌曲标签、其他版本、制作人、相关歌单、粉丝数、曲谱、CDN 调度 |
| QQ | `QQAPI+Lyric.swift` | 多语种翻译歌词、演唱注释、AI 词典 |
| QQ | `QQAPI+Singer.swift` | 歌手主页 tab、歌手列表（分类）、歌手专辑/歌曲分页 |
| QQ | `QQAPI+Top.swift` | 榜单全量（基线 `prefix(12)` 卡掉了特色榜 11 张与全球榜 4 张）、榜单详情翻页与**往期**（`period`） |

### 移植过程中查出并修掉的既有问题

这些不是新接口，是接的过程中拿真实响应对出来的老账，都已就地修正：

- **`NeteaseAPI.djRadioDetail(_:)` 静默截断节目单**：写死 `limit=50` 不翻页，131 期的电台
  点进去只有 50 期；电台名/封面还是从**节目列表第一条**里反推的，零节目的新电台整个空白。
  改成先问电台自己的详情（`/api/djradio/v2/get`）、节目单翻到底。
- **`NeteaseAPI.artistDetail(_:)` 专辑写死 30 张不翻页**：高产歌手的「全部专辑」缺一大半。
  改成一页 100 张（仍是一条请求）。要一张不落用 `artistAlbums(_:all:true)`。
- **`QQAPI.artistDetail(_:)` 的 `number: 50` 是摆设**：[实测] 传 10/50/100 一律回 30 条。
  专辑那一格按第一页回的 `total` 并发补后续页（上限 4 页）。
- **`QQAPI.parseSingerListItem` 的头像回退永不触发**：`(s["singer_pic"] as? String) ?? …`，
  空串是合法 String。`GetSingerList` 每项的 `singer_pic` 都是空串，会得到一批空头像。
- **`QQAPI.newSongTracks()` 的频道号注释与接口自己回的 `lanlist` 对不上**：
  正确的是 5=最新 / 1=内地 / 6=港台 / 2=欧美 / 4=韩国 / 3=日本。
- **`NeteaseJSON` 缺数组档**：云盘那两条接口参考实现发的是真数组，与 `trackIds` 的
  字符串形式不通用，补了 `.array`。

### 参考实现本身的三处错/失效（照抄会踩）

- **`top_list.js`（`/api/playlist/v4/detail`）已经失效**：四种参数 × 两条通道 × 两个域名
  一律「请求参数错误」。方法留着，注释写明「拿到 nil 是常态，该走 v6」。
- **`lyric.get_lyric` 固定传 `crypt:1` 是错的**：匿名下只回 20 字节（3DES 解不动），
  `crypt:0` 才回完整密文。Amber 基线传的正是 0。
- **QQ `OffsetStrategy(page_size_key="number")` 在歌手歌曲/专辑两条上会跳过数据**：
  服务端不认 `number`，恒回 30；按请求页大小推 offset 就会漏。Amber 按实际条数推进。

## 界面接线第一批（2026-09-09）：右键菜单里靠这批接口活过来的项

菜单表本来就把「Amber 还没有的能力」列在原位、`run` 给 nil（`MenuSpec` 的禁用即隐藏），
所以这一轮只是把 nil 换成动作，一处项序都没动。

| 菜单项 | 接的是 | 备注 |
| --- | --- | --- |
| 减少推荐（曲目） | QQ `FeedbackBlack/AddDislike`；网易 `/api/v2/discovery/recommend/dislike` | 判据在 `AppState.canSuggestLess` |
| 撤销减少推荐（曲目） | QQ `CancelDislike` | **网易云没有撤销接口**，那一家永远只摆得出前一条 |
| 减少推荐（艺人） | QQ `AddDislike` 的 `Singers`（要先把 singerMid 换成数字 SingerID） | 网易云不收歌手，`supportsArtistSuggestLess` 报 false |
| 添加到播放列表 › 账号歌单 | 两家的 `addTracks(_:to:)` | 只列**自建**歌单（`Playlist.isOwned`），收藏来的写不进去 |

两条口径写在这儿免得下次改错：

- **心水/喜爱仍然只在本机**，不往账号里写红心——那是 Amber 自己的资料库属性；
  要把歌放进音源账号，走「添加到播放列表 › 账号歌单」，由用户自己挑哪一份。
- 「减少推荐」在本地留了一份镜像（`LibraryStore.suggestLessTrackIDs`）只为决定菜单摆哪一条。
  换账号、或在音源自家 App 里点的不喜欢，这份镜像都对不上——明知的取舍，写请求本身幂等。

菜单里仍然空着的那几条与理由：**置顶 / 在 iTunes Store 中显示 / 分享**（Amber 没有对应形态）、
**创建电台**（网易的私人 FM 与心动模式是两个独立播放模式，见 todo.md §4）、
**显示简介**（接口这一轮备齐了——音乐百科、创作者、制作人、音质详情、歌曲标签——
缺的是那个面板本身，是一件连着 UI 设计的活）。

## 不接（判断过，写下理由免得下次又捡起来）

- **网易的云贝 / 云小编 / 音乐人工作台 / 会员任务 / 签到 / 年度报告 / 私信 / 动态 / 一起听**：
  这些是网易云自家的社区与运营功能，Amber 是个 Apple Music 形态的播放器，界面上没有它们的位置。
  （「一起听」将来若要做 SharePlay 形态的功能再单独评估，那是连着 UI 一起设计的事。）
- **数字专辑购买 / 付费下载记录**：涉及交易，不做。
- **注册、改绑手机**：这两件事该在网易云自己的 App 里做，Amber 不碰。
  （**手机号登录已经做了**，2026-09-09 按用户要求补的——「扫码很麻烦」。
  验证码与密码两条都走 `/api/w/login/cellphone`，见 `Amber/Providers/Netease/NeteasePhoneLogin.swift`。
  密码与验证码不落盘、不进日志；手机号也不记。）
- **QQ 的私信（`private_message.py`）与 mqtt**：同「私信」条。
