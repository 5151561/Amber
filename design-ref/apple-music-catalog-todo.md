# 目录页三页 —— 还没做的部分（对照表）

> 配套：[apple-music-catalog-pages.md](apple-music-catalog-pages.md)（Apple 的完整栏目清单与卡型规格）。
> 本文只列**还没做的**，每条给出：Apple 的规格 → Amber 现状 → 数据源是否可行（已实测）→ 要动哪些文件。
> 采集与验证时间 2026-09-03，中国区、网易云匿名 / QQ 已登录。
>
> 现有做法（别改这个前提）：**栏目结构照 Apple 写死在 `Amber/Views/Catalog/CatalogPages.swift`**，
> 卡型照网页 DOM 复刻在 `CatalogCards.swift`，音源只按 `CatalogSlot` 交数据
> （`MusicProvider.catalogItems`），交不出来的段整段省掉，不拿别的内容顶。

---

## 0. 已经做掉的（2026-09-03 下午，两家音源都实机看过）

| 段 | 卡型 | 落地方式 |
| --- | --- | --- |
| 主页「推荐歌单」 | 新卡 `.superHero` → `CatalogBannerCard` | 整宽一张图 + 一句描述居中压在图底；网易云取个性歌单里没被前两段用掉的那张，QQ 取推荐流 From=20 |
| 主页「音乐回忆：你的热门音乐」 | 复用海报卡 | **不走音源**：`LibraryStore.topTracksLastMonth()` 统计上个自然月的播放，落点是新的 `Route.localTracks` |
| 新发现「观看艺人分享」 | 新卡 `.videos` → `CatalogVideoCard` | 网易云 `mv/first`、QQ `GetAllocMvInfo`；点击开音源网页 MV 页（App 内没有播放器） |
| 新发现「探索更多」 | 新卡 `.links` → `CatalogLinkCard` | 链接组落成音源的歌单分类分组，落点是新页 `CatalogTagBrowsePage`（组名 + 标签排 + 歌单网格） |
| 主页「为你制作的歌单」的**内容** | 卡型没动 | Apple 那段是 3 张自动生成的个人混音歌单；Amber 原来放的是推荐流/个性歌单的后半段。改成网易云雷达歌单的后半（前 3 张归精选）、QQ 推荐流功能入口行里的 `每日30首 / 百万收藏 / 新歌推荐`（type=500，带真 tid 与封面） |
| 主页「专属精选推荐」的**内容** | 卡型没动 | 原来是按类型分组的一堆歌单；改成照 Music 的配方**逐张换类型**（电台/专辑/心情台轮流），头两张是真的个人电台（网易云用雷达歌单、QQ 用「猜你喜欢」「随心听」）。**音源的推荐流歌单不进这一段**（用户定的，UGC 标题不搭）。配方在 `CatalogSlotResult.topPicks` |

顺手修的：网易云匿名状态下 `copywriter` 是**空串**（不是缺字段），空串会让海报卡多占一行、
让大横幅变成一张没字的图，已在 `parsePlaylist` 里折成 nil（QQ 的 `desc` 同理）。
海报卡第三行网页复测是 **11/400** 不是 13，已改（`posterDescSize`）。

大横幅**不能**用 `aspectRatio(_:contentMode: .fit)` 定高：纵向 ScrollView 提议的高度是无穷，
实测会把卡撑成正方形（AX 量到 1030×1030），得自己量宽度再钉高度（`onGeometryChange`）。

---

## A. 还没做的段

### A1. 「<艺人>参与作品 →〈艺人〉和类似艺人」电台（**没做**）

Music 的「专属精选推荐」里还有一类卡是**艺人电台**（eyebrow 写「<艺人>參與作品」，
落点是「<艺人>和類似藝人」电台）。Amber 现在把这个位置让给了别的类型。
两家音源都没有现成的「艺人电台」实体：QQ 能用 `music.SimilarSingerSvr/GetSimilarSingerList`
凑一批相似歌手，但要自己把它们的热门歌拼成可播的流；网易云那边相似歌手接口还没探。

### A2. 主页「演唱会」—— bubble-tip（**建议不做**）

Apple 是纯文字卡 +「设定位置」按钮，内容靠定位拉附近演唱会。网易云/QQ 都没有演唱会数据，
做出来只能是个永远空的壳。**建议整段不复刻**，或只在 Amber 自己有演出数据源时再说。

---

## B. 卡型现成、卡在数据的段

> **重要教训**：QQ 的 `musicu.fcg` 对**不存在的模块**一律回 `code 500003`，
> 跟「要登录」长得一模一样。之前判定「QQ 交不出来」的那几条，其实是我模块名写错了——
> 带登录态重探，换成真模块名之后全都通了。
> 探接口用 `-qqprobe <输出文件>` 启动参数（`QQAPI.debugProbeCatalog`，DEBUG-only），
> 它走的是 App 里注入了登录 cookie 的 `musicu()`，比匿名 curl 准；报告里会把首项整条 JSON 打出来。
> 真模块名的来源：`github.com/luren-dc/QQMusicApi` 的 `qqmusic_api/modules/*.py`。

### B1. 新发现「即将发布」（**还没解决**）

- Apple：方卡货架，条目是**预发行专辑**。
- 卡型现成（`.squares(rows: 1)` + `.albums`），只差数据。
- 两家都没找到能用的预发行接口：
  - 网易云 `/api/album/list?type=hot` → `code -462`「请绑定手机后再试」（匿名）。
  - QQ `music.musicHall.MusicHallAlbum/GetPreSaleAlbum`、`newalbum.NewAlbumServer/get_pre_album_info`、
    `GetComingSoonAlbum` → 全是 500003/500005（登录态下也一样，即模块不存在）。
  - `music.musichallAlbum.AlbumListServer/GetAlbumList` 是**按歌手**取专辑，不是预发行，且回 104403。
- 下一步：接上网易云登录后重试 `/api/album/list`；或从 QQ 新碟里挑 `release_time` 在未来的。

### B2. 「2010 年代」两家都是空的（**还没解决**）

- 网易云歌单分类的「主题」组只有 70后/80后/90后/00后，指的是**听众年龄段**——
  「90后」实际返回的是 1990s 的歌，套到「2010 年代」驴唇不对马嘴，所以映射成 nil、整段省掉。
- 「2000 年代」用「00后」标签是对得上的，已经接了。
- QQ 干脆没有年代标签。
- 下一步：找按发行年份取内容的路子，或接受这一段只在网易云有「2000 年代」。

### B3. 「最新电台节目」在 QQ 上是空的（**还没解决**）

- 网易云已接（`/api/personalized/djprogram` → 节目单集，横向宽卡，点开即播）。
- QQ 的长音频（`RecommendFeed` shelf id=272）是广播剧/有声书，跟 Apple 的电台节目不是一回事，
  没拿来顶。`music.radio.RadioProgram/GetProgramList`、`music.longAudio.LongAudioSvr/GetRecommend`
  都是 500003（模块不存在），还没找到对的模块名。

### B4. 还没做、但接口已经探通的段

- 「**XX 的乐迷还喜欢**」（Apple 主页长尾里有这条，Amber 两家都没做）：
  QQ 用 `music.SimilarSingerSvr/GetSimilarSingerList {singerMid, number}`（登录态实测 OK）；
  网易云那边**还没探**相似歌手接口。卡型现成（方卡 + 艺人/专辑）。
- QQ 还探通了 `music.recommend.TrackRelationServer/GetRelatedPlaylist {songid, vecPlaylist:[]}`（相关歌单）、
  `MvService.MvInfoProServer/GetSongRelatedMv`、`GetSingerMvList`（单曲/歌手的 MV）。

## C. 已知的小差异（不是缺功能，记录备查）

1. **方卡第二行在网易云匿名状态下可能是空的**：推荐/相似接口给的 `album.artist` 是空对象，
   **原因是没登录**。别拿歌曲的 `artists` 去补（合辑会写错人）。接上网易云登录就有了。
   方卡文字块高度钉死 37，少一行不会跟同排错位。
2. **海报卡/hero 卡的 AX 框比实际大**：文字 overlay 把无障碍框撑到图的外接方形
   （海报报 328×328、hero 报 379×379、大横幅报 1030×1030）。按截图量出来是 246×328 / 379×312，
   跟 Music 对得上，**用 AX 尺寸做像素比对时要注意这一点**，别当成排版 bug 去「修」；
   量大横幅这种整宽卡的真实高度，看下一段标题的 y 差（段距 25）反推更准。
3. **QQ 的 500003 = 模块不存在，不是权限不足**。判定「QQ 没有某个能力」之前，
   先确认模块名是对的（去 `luren-dc/QQMusicApi` 的 `qqmusic_api/modules/*.py` 里找），
   再用 `-qqprobe` 带登录态验一遍。匿名 curl 探出来的 500003 说明不了任何问题。
4. **广播页按中国区复刻**（用户 2026-09-03 定的）：hero 宽卡 + 两条同名「风格电台」。
   `design-ref/ui-spec/pages/radio.json` 那份是国际区（Apple Music 1 等 183.5 方形瓷砖 +
   三条节目单集货架），结构完全不同，**别照那份改**。
5. **视频卡/链接格/大横幅没有 AX 实测**（Music.app 的 AX 树这几天整棵取不到）。
   现在的尺寸是按网页实测折算的 [推] 值：视频卡按方卡的网页→AX 比例（179.5/199）折，
   大横幅按 1074/460 折，链接格直接照网页的 58 高。以后 Music 的 AX 树能取到了要复核。

---

## D. 动手时的落点速查

| 要改什么 | 文件 |
| --- | --- |
| 加/改栏目、调顺序 | `Amber/Views/Catalog/CatalogPages.swift` |
| 加卡型 | `Amber/DesignSystem/MusicMetrics.swift`（`enum Catalog`）+ `Amber/Views/Catalog/CatalogCards.swift` + `CatalogPageView.swift` 的 `card(_:)` / `shelfContent(_:)` |
| 加 slot / 条目类型 | `Amber/Models/Models.swift`（`CatalogSlot` / `CatalogItems` / `CatalogStyle`）+ `Amber/Providers/MusicProvider.swift` |
| 音源取数 | `Amber/Providers/Netease/NeteaseAPI.swift` / `Amber/Providers/QQMusic/QQAPI.swift` 的 `catalogItems(_:)` |
| 段 → 卡片的翻译、并发拉取 | `Amber/Views/Catalog/HomePages.swift` |
| 「探索更多」的落地页 | `Amber/Views/Catalog/CatalogTagBrowsePage.swift` |

跑起来看效果：`./Tools/run.sh`（构建+长期签名安装到 /Applications+启动，别自己 open DerivedData 里的）。
采 AX 树核对：`xcrun swift Tools/ui-spec.swift /Applications/Amber.app --runtime -o out.json`。
页面滚不动的时候：合成滚轮事件对 SwiftUI 的 ScrollView 不起作用，改用 AX——
找到窗口里最高的那个 `AXScrollBar`，`AXUIElementSetAttributeValue(bar, kAXValueAttribute, 0.55)` 即可。
