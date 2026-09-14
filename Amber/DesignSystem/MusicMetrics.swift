import AppKit
import CoreGraphics

/// 全部布局度量 token，对照 Music.app 校准。
/// 校准基线：macOS 27.0、深色模式、窗口 1470×923、侧栏展开（渲染宽 202.5）。
/// 读数工具：Tools/ui-spec.swift（AX frame）+ 截图逐像素（字形带）；
/// 参照物存放在 design-ref/ui-spec/pages/，本 App 的对照件在 design-ref/ui-spec/am/。
///
/// 出处标注：
/// - [AX] Accessibility Inspector 读到的元素 frame
/// - [PX] 截图逐像素实测
/// - [推] 由实测值反推的实现参数
/// - 无标注 = 尚未对照 Music.app 校准，先集中管理，后续逐项校准
///
/// 校准发现偏差时只改这里，所有页面一起变。
///
/// **新增度量之前先问三问**（AGENTS.md「界面层」第 6 条）：
/// 1. 系统 API 能不能直接给（`NSFont.systemFontSize`、`RowSizeStyle`、`NSSplitViewItem`
///    默认厚度、`NSToolbar` 标准高、`NSCollectionLayoutSpacing`）？能就用系统的，
///    实测值只写进注释当验收标尺，别在这里立一条常量。
/// 2. 是不是 Music 自己的设计常量（[实测]/[资源] 出处）？那就该在这里当 token。
/// 3. 是不是补 SwiftUI 内建偏移的 [推]？随框架切换删——AppKit 里没有那层偏移。
/// 默认值与实测对不上时才写死，且注释要写明「系统默认 X，实测 Y」。
enum MusicMetrics {

    // MARK: - 页面通用

    enum Page {
        /// 普通内容页（搜索/详情/本地列表）水平内边距
        static let contentHorizontal: CGFloat = 16
        /// 详情页大区块（头部/按钮行/列表）间距
        static let blockSpacing: CGFloat = 24
        /// [实测] `AMPGridLayoutModel.minimumItemSize` → 183 / 210，
        /// `desiredArtworkSize` → 183。取小的那一档做自适应下限。
        static let gridItemMinWidth: CGFloat = 183
        /// [实测] `AMPGridLayoutModel.minimumInterItemSpacing` → 10（列间距）
        static let gridInterItemSpacing: CGFloat = 10
        /// [实测] `AMPGridLayoutModel.minimumLineSpacing` → 6（行间距，比列间距紧）
        static let gridLineSpacing: CGFloat = 6
        /// Music.app 内容页标题与第一行内容的左沿。
        /// 参照 [实测] `AMPGridLayoutModel.leadingMargin` / `trailingMargin` → 30，
        /// 那是 AppKit 网格控件自己的边距；本页左沿有 [PX] 实测，以实测为准。
        static let leadingMargin: CGFloat = 34
        static let titleTop: CGFloat = 8
        static let titleSize: CGFloat = 29
    }

    // MARK: - 标题栏

    enum Titlebar {
        // 这里原先还有一条 [推] `placeholderHeight = 28`：SwiftUI 时代`.toolbar(.hidden)`
        // 会把红绿灯一起收掉，得留一件透明占位撑住标题栏。AppKit 没有这回事——
        // [实测 2026-09-05] 摘光所有工具栏项后 `contentLayoutRect` 高仍 848、红绿灯仍在
        // (19,19)、工具栏仍 52，标题栏不塌。占位项与这条度量一起删了。

        /// [AX] 工具栏整条 `[0, 33, 1470, 52]`（songs/albums/home/search 四页同值），
        /// 内容滚动区正好从它的下沿 85 起。
        static let height: CGFloat = 52
        /// [AX] 标题栏里各槽的内容高：搜索框 38、范围分段控件 38（`songs.json` 的
        /// `AXTextField [1251, 40, 211, 38]`、`search.json` 的`AXRadioGroup [1205, 40, 257, 38]`）。
        static let itemHeight: CGFloat = 38
        /// 页面标题标签的对齐矩形往左扩多少 = 15 − 4 = **11**。
        ///
        /// 标题项的 view 是一枚**裸 `NSTextField`**（不是自定义容器）：[实测 2026-09-05]
        /// macOS 26 只给自定义容器视图套液态玻璃平台（`NSToolbarPlatterView`），裸标签不套。
        /// AppKit 按**对齐矩形**排它、两侧各垫 4：把对齐矩形往左扩 x，标签 frame 就落在
        /// viewer 左沿 + 4 + x（[实测] x = 8 时 viewer `[206.5, 0, 46, 52]`、标签 218.5）。
        /// Music 的标题 `AXStaticText` 在 221.5 = 组 206.5 + 15（`songs.json` / `albums.json`；
        /// 有返回键时整体右移 40，`lyrics-panel.json` 返回键 206.5 宽 40、文字 261.5），
        /// 所以 x = 11。由 `ToolbarTitleLabel.alignmentRectInsets` 给，标签的 frame 与
        /// AX frame 都落在 221.5。
        static let titleLeading: CGFloat = 11
        /// [AX] 返回键槽宽 40（`lyrics-panel.json` `AXButton [206.5, 33, 40, 52]`）
        static let backItemWidth: CGFloat = 40
        /// [AX] 筛选（排序选项）槽宽 40（`songs.json` `AXMenuButton [1208, 33, 40, 52]`）
        static let filterItemWidth: CGFloat = 40
        /// [AX] `search.json` 搜索页居中搜索框`AXTextField [597, 40, 484, 38]`。
        /// 1470 宽窗口实测 484，1440 宽窗口实测 473；下限 180。
        static let centerSearchFieldIdealWidth: CGFloat = 484
        static let centerSearchFieldMinWidth: CGFloat = 180
    }

    // MARK: - 侧栏

    enum Sidebar {
        static let widthMin: CGFloat = 180
        /// [AX] 与 Music 的 202.5 对齐（滚动区 `[0, 85, 202.5, 814]`、分隔线也在这个数上）。
        /// 落点是 `SidebarViewController.loadView` 里容器的 frame 宽：没有 autosave 记录时
        /// `NSSplitViewController` 按子控制器 view 的 frame 定首次厚度，这是系统自己的办法。
        static let widthIdeal: CGFloat = 202.5
        static let widthMax: CGFloat = 280

        /// [AX] 选中胶囊高度
        static let rowHeight: CGFloat = 30
        /// [PX] 选中胶囊圆角
        static let rowCornerRadius: CGFloat = 7
        /// 行内容（图标槽）相对胶囊左沿的内缩。
        /// 注释原先写的是「List 默认 21pt，差 9pt，经负外边距补偿后取 15」——那套补偿
        /// 随 SwiftUI List 一起没了。现在它是纯排版值：槽起点 = `capsuleInset + 这一条` = 25，
        /// 槽宽 25 ⇒ 图标墨迹中心恒在 37.5，与 [PX] 实测的十一个符号中心对上（见 `iconSlotWidth`）。
        static let rowContentLeading: CGFloat = 15
        /// [AX] 行距整 32pt（rows y=112,144,176…），胶囊 30pt 居中，故上下各 1
        static let rowVerticalInset: CGFloat = 1
        // 这里原先有两条只为 SwiftUI List 存在的 [推]，换成 NSOutlineView 之后都没了使用者，已删：
        // - `rowEdgeInset = 6`：List 行内容自带 ~4pt 内建偏移，配 6pt 行内边距才凑出实测的 10pt。
        //   现在胶囊直接按 [PX] 的 `capsuleInset = 10` 画。
        // - `sectionSpacing = 10`：组间距，实测是 13，见`groupTopSpacing`（已按实测排版）。

        /// [AX] 账号头像下沿距窗口底 18（Music 的账号按钮 `frameInWindow [18, 877, 73, 28]`、窗高 923）；
        /// [PX] `home.png` 实测同值（窗口内容在图里从 y=76 起，头像下沿 py 1886 ⇒ 905pt）。
        static let accountBottom: CGFloat = 18
        /// [AX] 头像左沿 18，与账号按钮的 x 同值；[PX] `home.png` 实测 18.0…46.0。
        static let accountLeading: CGFloat = 18
        /// [AX] 账号按钮高 28；[PX] `home.png` 里那枚头像实测 56×56 px@2x，是正圆。
        static let accountSize: CGFloat = 28
        /// 头像上沿到账号那一块顶端（= 侧栏滚动区下沿）的距离。
        /// [AX] Music 的滚动区下沿 866、头像上沿 877 ⇒ 11。
        static let accountTop: CGFloat = 11
        /// 头像与账号名之间的间距。
        /// [AX] 按钮 `[18, 877, 73, 28]` ⇒ 文字 52…91；头像 18…46，故 6。
        static let accountSpacing: CGFloat = 6
        /// [推] 播放列表行的封面方块。Music 这一行在参照账号里一条都没有，
        /// AX 采不到实测值；按图标槽（x 24…50、符号高 11）目测折成 19pt 方块，
        /// 采到 Music 的真实值后要复核。
        static let playlistArtworkSize: CGFloat = 19
        /// [推] 列表封面的圆角，随 `playlistArtworkSize` 一起是目测值。
        static let playlistArtworkRadius: CGFloat = 3

        // 以下是侧栏换成 NSOutlineView（SidebarOutline.swift）之后新用上的排版值。
        // 全部量自 `design-ref/ui-spec/pages/home.json` / `home.png`（Music 1470×923、深色、2x），
        // 上面那几条历史值一个没动。

        /// [AX] 选中胶囊左右各内缩 10：Music 的行 `[0, y, 202.5, 32]`、
        /// 里面的 `AXCell [10, y, 182.5, 32]`；[PX] `home.png` 选中那一行实测胶囊 x 10.0 → 192.5。
        /// （SwiftUI List 时代要用 6pt 行内边距 + List 自带的 ~4pt 内建偏移凑出这 10pt，
        /// 那条 `rowEdgeInset` 随 NSOutlineView 一起删了：这里直接按实测的 10 画。）
        static let capsuleInset: CGFloat = 10
        /// 图标槽宽。槽起点是 `capsuleInset + rowContentLeading = 25`，故槽中心恒在 x = 37.5。
        /// [PX] Music 十一个侧栏符号的**墨迹中心**实测 37.25…37.75（墨迹宽度 9.5…21 各不相同），
        /// 说明符号是**居中**在一个固定槽里的，不是左对齐；墨迹左沿因此落在 27…33，
        /// 与 `rowContentLeading` 注释里那句「图标左沿距窗口 30pt」是同一件事。
        static let iconSlotWidth: CGFloat = 25
        /// 图标视图左右各比名义槽多出的余量。只为**不剪裁**，不影响居中：
        /// `dot.radiowaves.left.and.right` 这种宽符号 [AX] 在 Music 里的图像盒是 24.5…51
        /// （26.5pt），比名义槽宽，`NSImageView` 又是`.scaleNone`，不留余量就会被剪掉两头。
        static let iconSlotOverflow: CGFloat = 4
        /// 行图标的 SF Symbol 字号。
        ///
        /// **不等于文字字号。** [PX] `NSImage.SymbolConfiguration(pointSize: 13)` 画出来的墨迹
        /// 比 Music（也比 Amber 上一版 SwiftUI `Label`）小 ~28%：放大镜墨迹 12pt vs 15.5pt、
        /// 广播 16 vs 21、音符 7.5 vs 9.5。SwiftUI 的 `Label` 图标不是按字号的 pointSize 排的，
        /// 按实测比例折回去就是 13 × 1.30 ≈ 17。取 17 之后逐符号复核墨迹尺寸。
        static let iconPointSize: CGFloat = 17
        /// [AX] 行文字 `AXStaticText [54, y, 131.5, 18]`：左沿 54。
        static let textLeading: CGFloat = 54
        /// [AX] 同上：文字右沿 185.5，距胶囊右沿（192.5）7。
        static let textTrailing: CGFloat = 7
        /// [PX] 行文字：中文墨迹高 11.5、每字宽 11.75 ⇒ 系统 13pt。Amber 旧版与 Music 完全同尺寸。
        static let rowFontSize: CGFloat = 13
        /// [PX] 组标题：墨迹高 9.5、每字宽 10.3 ⇒ 系统 11pt。
        static let groupFontSize: CGFloat = 11
        /// [AX] 组标题行高 19（`AXRow [0, 193, 202.5, 19]`）。
        static let groupRowHeight: CGFloat = 19
        /// [AX] 组标题文字左沿 15（`AXStaticText [15, 194.5, …, 16]`）。
        static let groupTextLeading: CGFloat = 15
        /// [AX] 组标题上方空 13pt：广播行 148+32=180 →「资料库」组标题 193。
        /// 这 13pt 不属于任何一行（Music 的 AXRow 之间真有缝）；AppKit 的行首尾相接，
        /// 只能把它算进组标题行的高度、内容压到下 19pt（见 SidebarOutline 的 heightOfRowByItem）。
        static let groupTopSpacing: CGFloat = 13
        // 这里原先有一条 [推] `labelInkInset = 1`：SwiftUI 时代拿`Text` 的墨迹去凑
        // Music 的位置，得往左退 1pt。侧栏换成 NSOutlineView 之后两边是同一种控件——
        // Music 的 `AXStaticText [54, y, 131.5, 18]` 就是它`NSTextField` 的 frame，
        // 文本框直接放在 `textLeading` / `groupTextLeading` 上即可，补偿已删。

        /// 拖入落点那圈边的粗细，沿用旧版 `SidebarTrackDrop` 的 2pt。
        static let dropBorderWidth: CGFloat = 2
    }

    // MARK: - 音乐源切换

    enum ProviderPicker {
        static let width: CGFloat = 184
        static let height: CGFloat = 26
        static let cornerRadius: CGFloat = 7
        static let horizontalPadding: CGFloat = 3
    }

    // MARK: - 右侧歌词 / 待播清单

    enum Inspector {
        /// [AX] 面板列 `[1212, 33, 258, 923]`（`lyrics-panel.json` / `queue-panel.json`，
        /// 窗口 1470×923）：分隔线在 1211.5，列本身 258 宽、上到窗顶下到窗底。
        ///
        /// 2026-09-05 更正：旧值 247 是「1440×900 基线约 247pt」的估读，与同一份
        /// AX 记录对不上——`lyricsInset` 的注释引的正是这条 258 的记录。
        /// 换骨架时一并对回实测值（面板列本身定宽，不随窗宽缩放）。
        static let width: CGFloat = 258
        static let titleTop: CGFloat = 15
        static let horizontalPadding: CGFloat = 18
        static let closeButtonSize: CGFloat = 28
        /// 歌词行相对面板的左右内边距。
        ///
        /// [AX] `lyrics-panel.json`（1470×923）：歌词组`[1212, 33, 258, 923]`、
        /// 里面的滚动区**同尺寸**，行 `[1231, …, 220, …]`——19pt 落在滚动区**里面**。
        /// 与整窗那档（`NowPlaying.hostedContentInset`）同值，也同样必须走
        /// `SyncedLyricsView.Overrides.horizontalMargin` 而不是外面的`.padding`：
        /// 加在外面的话，行贴着 clip view 左沿时逐行模糊糊出去的那一圈会被剪掉。
        static let lyricsInset: CGFloat = 19
    }

    // MARK: - 空状态

    enum EmptyState {
        /// [资源] `Assets.car` 里的空状态插图`Empty_Music_Note` 是 45×53@1x
        /// （同组还有 `Empty_Downloaded` 62×58、`Empty_Music_Videos` 65×51）。
        static let iconSize: CGFloat = 45
        static let topPadding: CGFloat = 150
        static let spacing: CGFloat = 12
        static let maxTextWidth: CGFloat = 360
    }

    // MARK: - 底部悬浮播放胶囊

    enum MiniPlayer {
        /// [AX] 固定 700×54，距窗口底 19pt。两态都是 700，变的是组间距与中央块：
        /// 空闲 9+148+9+369+9+147+9，有曲目 9+148+1+385+1+147+9。
        static let width: CGFloat = 700
        static let height: CGFloat = 54
        static let bottomMargin: CGFloat = 19
        /// 胶囊两侧防贴边的水平外边距（窗口极窄时生效）
        static let horizontalMargin: CGFloat = 12
        /// 列表底部安全区预留：胶囊高 + 距底 + 8pt 缓冲，避免滚到底被胶囊盖住
        static var scrollReserve: CGFloat { height + bottomMargin + 8 }

        /// [AX] 胶囊内容两侧内缩（Music 内层组 [559…1241] 对胶囊 [550…1250]）
        static let edgePadding: CGFloat = 9
        /// [AX] 组间距随播放态变：空闲 9（repeat 右沿 628.5 → 中央块 637.5），
        /// 有曲目 1（643.5 → 644.5）。传输组左贴、尾部组右贴，中央块吃掉剩下的宽度。
        static let idleGroupSpacing: CGFloat = 9
        static let groupSpacing: CGFloat = 1
        /// [AX] 传输键 hit box 相邻贴排，无间距
        static let transportSpacing: CGFloat = 0
        /// [AX] 传输键 hit box：普通键 28×28，播放键 36×36（合计宽 148）
        static let transportButtonSize: CGFloat = 28
        static let playButtonSize: CGFloat = 36
        /// 四颗普通键 + 播放键，键间无间距
        static var transportWidth: CGFloat { transportButtonSize * 4 + playButtonSize }

        // 图标字号 [PX]：按 Music 字形外框反推（随机 13×10.5、上一首 19×11、
        // 播放 19×21、循环 12×10、歌词 18.5×17.5、队列 17×12.5、音量 19.5×14.5）
        static let shuffleIconSize: CGFloat = 11.5
        static let skipIconSize: CGFloat = 14.5
        static let playIconSize: CGFloat = 26.5
        static let repeatIconSize: CGFloat = 11.5
        static let trailingIconSize: CGFloat = 17.5
        /// 音量键的符号本身比例不同，实测 15 就已经和 Music 吻合
        static let volumeIconSize: CGFloat = 15
        // [TYPE] `MiniPlayerTransportSpecs` 印证了「逐键分档」这件事：
        //   centerButtonFont: (CGFloat) -> Font          —— 中间播放键单独一档
        //   edgeButtonFont:   (TransportButtonImage, CGFloat) -> Font
        // 边键那个字体是**以图标为参数**的函数，Music 自己也按图标给不同字号，
        // 所以上面四个值各自独立是对的，不要合并成一个。

        // 中央「播放中」区块
        /// 中央块不是独立定值，是 700 减掉两端内缩、两侧固定组和两条间距后的余量。
        /// [AX] 实测：空闲 369（state=empty）、有曲目 385（state=populated）。
        static func centerWidth(spacing: CGFloat) -> CGFloat {
            width - edgePadding * 2 - transportWidth - trailingWidth - spacing * 2
        }
        /// [AX] 区块内容左右内缩（封面左沿 166、「更多」右沿 572）。
        /// [TYPE] `NowPlayingMiniPlayerSpecs` 里这是两个独立量
        /// （`centerViewLeadingPadding` / `centerViewTrailingPadding`），
        /// 实测两侧同为 8，先共用一个值，将来分开校准时再拆开。
        static let centerContentInset: CGFloat = 8
        /// [AX] 封面 34×34（播放态实测，非 36）。
        /// [TYPE] `NowPlayingMiniPlayerSpecs.artworkMaxHeight` 说明这是「不超过」的上限，
        /// 不是定值——封面比例不是 1:1 时按高度收，宽度跟着比例走。
        static let artworkSize: CGFloat = 34
        static let artworkCornerRadius: CGFloat = 4
        /// [AX] 封面到标题两行文字的间距（675→683）
        static let artworkToText: CGFloat = 8
        /// [AX] 标题/副标题行框相邻（876.5+16 = 892.5）
        static let centerTextSpacing: CGFloat = 0
        /// [AX] 胶囊悬浮时歌名右侧的星形收藏键。`home.json` / `new.json`（悬浮态那两张）：
        /// 标题 `[694.5, 894.5, 137.5, 16]`、喜爱键`[832, 894.5, 16, 16]`——
        /// 832 正是标题右沿，**间距 0**，命中盒 16×16 与标题行等高、顶对齐。
        /// （旧值 8 是按「无盒的字形间距」估的 [PX]，字形会因此比 Music 右移约 6pt。）
        static let starGap: CGFloat = 0
        static let starButtonSize: CGFloat = 16
        static let starIconSize: CGFloat = 12

        // 进度条（可见线 [PX]：静止 [166, 406]×2pt 距底 4.5；悬浮长高 8pt 距底 9，宽度不变）
        /// [AX] 悬浮/拖拽命中区高度（AXSlider 高 18，贴区块底部）
        static let scrubHitHeight: CGFloat = 18
        static let progressHeight: CGFloat = 2
        static let progressBottom: CGFloat = 4.5
        static let progressHoverHeight: CGFloat = 8
        static let progressHoverBottom: CGFloat = 9

        // 悬浮变形 [PX 实测 Music]：中央内容淡到 8%、整体缩到 98%（以区块中心为锚），
        // 两端浮出时间标签。变形在 0.2→0.3s 之间完成，取 0.25。
        static let scrubFadeOpacity: CGFloat = 0.08
        static let scrubContentScale: CGFloat = 0.98
        static let scrubMorphDuration: Double = 0.25
        /// [PX] 淡出的同时还要虚化：Music 悬浮态标题的归一化边缘锐度只剩静止的 15%
        /// （26.3 → 4.0），单纯降不透明度做不到——Amber 原先残影是「清晰但淡」，一眼就不同。
        static let scrubBlurRadius: CGFloat = 2.5
        /// [AX] 时间标签框 28.5×16（“0:00”）对应字号 13；[PX] 纯白，不是 secondary
        static let timeLabelSize: CGFloat = 13

        /// [AX] 右侧图标（含区块内的无损/更多）hit box 36×36、间距 1pt
        static let trailingButtonSize: CGFloat = 36
        static let trailingSpacing: CGFloat = 1
        /// [AX] 歌词／队列／AirPlay／音量四键：1015.5…1162.5，36 的盒子按 37 一跳
        static var trailingWidth: CGFloat { trailingButtonSize * 4 + trailingSpacing * 3 }

        // 随机/循环的「已开启」状态点。
        // [资源] Music.app 的 Assets.car 里带 `shuffle.and.dot`、`repeat.and.dot`、
        // `repeat1.and.dot` 三个自定义 SF Symbol——也就是说开启态不是只把图标变色，
        // 而是换成字形下方多一颗圆点的变体。第三方拿不到这几个符号，用叠加圆点复刻。
        /// 圆点直径：按 SF「.and.dot」惯例约为字号的 0.22
        static let activeDotSize: CGFloat = 2.5
        /// 圆点中心距字形中心的垂直距离
        static let activeDotOffset: CGFloat = 8
    }

    // MARK: - 独立迷你播放器窗（Music 的 MPContentView）

    /// 「窗口 ▸ 切换到 MiniPlayer」那扇独立窗的内容视图度量。
    ///
    /// 出处：miniplayer 规格 §0/§2/§3.2、
    /// `inspector 规格` §4.4、`nowplaying 规格` §2.2，
    /// 版式那一半来自 **2026-09-08 的 Music 录屏**（`录屏2026-09-08 11.31.29.mov`，2x 抓帧）。
    ///
    /// **版式（[PX]，标定 2 px/pt）**：方形态实测窗口 638×639 px = 320×320 pt，与
    /// `kMinWindowWidth = 320` + 方形锁对得上，所以`pt = (px − 窗原点) / 2`。
    /// 结构是「**封面铺满 w×w 的方形顶块，所有控件浮在封面上**，歌词/待播抽屉从封面
    /// 下沿往下额外长」——不是「封面段 + 常驻横条 + 抽屉」三段。证据两条：
    ///
    /// 1. 开着歌词那一帧里，封面方块的下沿实测在 `y=659`（窗顶 19），高 640 px = 320 pt
    ///    = 窗宽，抽屉从那条线往下开始；这正是规格 §3.2 判据 `h > 宽度 + 200` 的来历
    ///    （方形封面块之外还要再有一份 ≥ `drawerMinHeight` 的抽屉）。
    /// 2. 换歌交叉淡化那一帧里，新封面的白色下半部（「帶你飛」字样与「告五人」签名）
    ///    **透过进度条和传输键**画了出来——控制区不是独立的一块灰底。
    ///
    /// 下面这一组浮层度量**全部以「顶块下沿」为基准**（控制块是贴着封面底沿排的，
    /// 窗口长高时只有封面变高，控制块不动），所以名字都叫 `xxxFromBottom`。
    ///
    /// 标 `[实测]` 的十条是实测的形态常量，**一个不能改**；标`[PX]` 的是本次
    /// 从录屏量的；标 `[推]` 的是录屏没拍到、只能定的（只有收起态那两条）。
    /// 字号/圆键这几条与 `MusicMetrics.NowPlaying`（全屏播放器）**逐个对上**——
    /// 规格 §0 说迷你窗与全屏播放器共用同一个 `MPContentView`，实测印证了这一点：
    /// 标题 17、副标题 15、圆键 26 + 间距 8、star 13、play 33、shuffle/repeat 17 全同。
    enum MiniPlayerWindow {
        /// [实测] `loadWindow` 的`contentRect`：`MiniPlayerWindow(contentRect: (0,0,300,100))`
        static let initialContentSize = NSSize(width: 300, height: 100)
        /// [实测] `kMinWindowWidth`（Double 320.0），`loadWindow` 里无条件装
        static let minWidth: CGFloat = 320
        /// [实测] `kMaxWindowWidth`（Double 600.0）。
        /// `integrate_mini_player_with_immersion` 关（默认）时装成宽度上限，
        /// 宽度被它夹住 → 组 III {6,7,8} 在本窗不可达。
        static let maxWidth: CGFloat = 600
        /// [实测] 分支 B 第一档：`h < 200` → 收起态 0
        static let collapseHeight: CGFloat = 200
        /// [实测] 同上第二档上沿：`200 ≤ h < 250` 是大封面的线性淡入带
        static let expandHeight: CGFloat = 250
        /// [实测] `progress = (h − 200) / 50` 的除数（−50 实测），即淡入带宽度
        static var fadeBand: CGFloat { expandHeight - collapseHeight }
        /// [实测] 分支 B 第三档：`h > width + 200` 才从窗口化方形态展开出面板列。
        /// **不是** 400——旧 nowplaying spec §1.2 的「400」是误读（miniplayer spec §3.2 订正）。
        static let panelHeightOffset: CGFloat = 200
        /// [实测] 分支 A（起始态 ∈ {1,2}，迷你横条且已开面板）的唯一阈值
        static let miniBarPanelHeight: CGFloat = 400
        /// [实测] `setDrawerHeight:` 里的常量 200 —— 抽屉高度的下限
        /// （nowplaying spec §2.2：运行时写进 `drawerHeight` 的值是收起前 inspector 的帧高）
        static let drawerMinHeight: CGFloat = 200
        /// [实测] 状态落地动画块里的 `context.duration`（inspector spec §4.4；
        /// 另一支 40.0 的开关没有动态替换时恒为 false，实际恒 0.4）
        static let stateAnimationDuration: TimeInterval = 0.4

        // MARK: 内容视图的固定几何（[实测] miniplayer spec §11.1，一次性写死）

        /// [实测] `artworkMargin`：迷你横条那颗小封面距内容左沿 / 顶沿的边距。
        /// 顶边那条在 ASM 里是 `artwork.separateTopEdgesByAtLeast(16, to: self)`，即「至少 16」。
        static let artworkMargin: CGFloat = 16
        /// [实测] `artworkSize`：小封面边长 42。
        static let artworkSize: CGFloat = 42
        /// [实测] `outerMargin`= `compactMetrics` 的 m0：迷你横条里标题盘的右边距。
        static let outerMargin: CGFloat = 18
        /// [实测] `drawerHeight`**初值**。收起时被改写成`inspector.frame.height`，
        /// 下限是 `drawerMinHeight`（200）。旧实现拿下限当初值，第一次开歌词只长出 200。
        static let drawerInitialHeight: CGFloat = 600

        // MARK: hover 四常量（[实测] miniplayer spec §11.1，…+200）

        /// [实测] `kMouseInterestTimeoutInSeconds`：指针在窗内不动多久之后把控件层淡掉。
        static let mouseInterestTimeout: TimeInterval = 3.75
        /// [实测] `kMouseInterestExitingWindowTimeoutInSeconds`：指针**离开窗口**之后的那一档，短得多。
        static let mouseInterestExitingWindowTimeout: TimeInterval = 0.3
        /// [实测] `kDelayBeforeStartingRolloverMin` / `Max`：起步计时器的区间。
        /// 规格没读出「按什么在区间里取值」，Amber 取下限（[推]），效果是「手一进来就亮，但擦边不闪」。
        static let delayBeforeStartingRolloverMin: TimeInterval = 0.1
        static let delayBeforeStartingRolloverMax: TimeInterval = 0.3

        /// [实测] miniplayer spec §11.7：换态时大封面位移补偿那条 `CABasicAnimation` 的缓动，
        /// `CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)`——整个原版唯一一处的极强 ease-out。
        ///
        /// Music 补的是「约束整份重建之后封面中心的跳变」，Amber 是手排 frame + 窗口 frame 动画，
        /// 封面的位移本来就跟着窗口走，那条补偿约束没有对应物；这里把这条缓动用在换态动画组上
        /// （大封面的交叉淡化走它），位移那半由窗口 frame 动画带（[推] 的取舍，见 spec §11.7）。
        static var artworkRecenterTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
        }

        // MARK: 浮层版式（[PX] 2026-09-08 录屏；基准 = 顶块下沿）

        /// [PX] 左右内缩。进度条左端 x=45 →（45−13）/2 = 16；标题墨迹左沿 x=46 → 16.5；
        /// ⋯ 圆键右沿 x=620，距窗右沿 651 → 15.5。三处互证，取 16。
        static let horizontalInset: CGFloat = 16

        /// [PX] 副标题行底距顶块下沿：副标题墨迹底 y=416 → 顶下 198.5，
        /// 加 15pt 字体的下伸部到行底约 203 → 320 − 203 = 117。
        static let metadataBottomFromBottom: CGFloat = 117
        /// [PX] 标题行与副标题行的行距（标题行底 182 → 副标题行顶 184）
        static let metadataLineSpacing: CGFloat = 2
        /// [PX] 曲名字号：墨迹宽 232 px = 116 pt，与 17pt semibold 实渲染的 117 对上。
        /// 与 `NowPlaying.titleSize` 同值——两处是同一个`MPContentView`。
        static let titleSize: CGFloat = 17
        /// [PX] 副标题字号：墨迹宽 216 px = 108 pt，与 15pt regular 实渲染的 108 对上。
        static let subtitleSize: CGFloat = 15

        /// [PX] ☆ / ⋯ 两颗圆键直径 52.5 px = 26（= `NowPlaying.metadataAccessorySize`）
        static let accessorySize: CGFloat = 26
        /// [PX] 两颗之间 16 px = 8（= `NowPlaying.metadataAccessorySpacing`）
        static let accessorySpacing: CGFloat = 8
        /// [PX] star 墨迹 28×27 px = 14×13.5 pt → 13pt（= `NowPlaying.favoriteIconSize`）
        static let favoriteIconSize: CGFloat = 13
        /// [PX] ellipsis 墨迹宽 30 px = 15 pt → 15pt
        /// （全屏那边量到的是 16.5，本窗小半档；两处都取自己量到的那一份）
        static let moreIconSize: CGFloat = 15
        /// [PX] 圆键底色：盘内 206 对盘外 170 → 白 0.42（同 `transportActiveOpacity`）
        static let accessoryBackgroundOpacity: CGFloat = 0.42

        /// [PX] 进度条中线距顶块下沿：中线 y=477 → 顶下 229 → 320 − 229 = 91
        static let scrubberCenterFromBottom: CGFloat = 91
        /// [PX] 可见轨道高：y 472…481 共 10 px = 5
        static let scrubberBarHeight: CGFloat = 5
        /// [AX] 命中区高 15，与全屏播放器同一档（`NowPlaying.scrubberHitHeight`）；
        /// 录屏量不到命中盒，只能借这一条。
        static let scrubberHitHeight: CGFloat = 15
        /// [PX] 未播轨道 187 对底色 168 → 白 0.22，取 0.22（已播是纯白 255）
        static let scrubberTrackOpacity: CGFloat = 0.22

        /// [PX] 时间行中线距顶块下沿：墨迹 y 507…522，中线 514.5 → 顶下 247.75 → 72.25
        static let timeRowCenterFromBottom: CGFloat = 72
        /// [PX] 时间行行高（10pt 等宽数字的一行）
        static let timeRowHeight: CGFloat = 13
        /// [PX] 时间字号：「0:33」墨迹宽 42 px = 21 pt，与 10pt 等宽数字的 20 对上
        /// （= `NowPlaying.timeSize`）
        static let timeSize: CGFloat = 10
        /// [PX] 「无损」徽标：字形墨迹宽 33 px = 16.5 pt → 字号约 14；
        /// 文字「无损」墨迹宽 39 px = 19.5 pt，与 10pt 实渲染的 20 对上。
        static let badgeIconSize: CGFloat = 14
        /// [PX] 徽标字形右沿 322 → 文字左沿 333，间隙 11 px = 5.5
        static let badgeSpacing: CGFloat = 5.5

        /// [PX] 传输键行中线距顶块下沿：循环圆底 y 559…623，中心 591 → 顶下 286 → 34
        static let transportCenterFromBottom: CGFloat = 34
        /// [PX] 随机/循环两颗贴边：随机墨迹中心 x=79.5 → 距左沿 33.25；
        /// 循环圆底中心 x=584 → 距右沿 34.5。取 34。
        static let transportEdgeInset: CGFloat = 34
        /// [PX] 中间三颗的中心间距：上一首 101.5 / 播放 160 / 下一首 217.25 → 57.9
        static let transportSpacing: CGFloat = 58
        /// [PX] shuffle 墨迹 39×31 px = 19.5×15.5 pt → 17pt（= `NowPlaying.shuffleIconSize`）
        static let shuffleIconSize: CGFloat = 17
        /// [PX] repeat.1 墨迹 35×31 px → 17pt（= `NowPlaying.repeatIconSize`）
        static let repeatIconSize: CGFloat = 17
        /// [PX] backward.fill 墨迹 62×35 px = 31×17.5 pt → 23pt
        /// （全屏那边是 24.5，本窗小一档）
        static let skipIconSize: CGFloat = 23
        /// [PX] pause.fill 墨迹宽 39 px = 19.5 pt → 33pt（= `NowPlaying.playIconSize`）
        static let playIconSize: CGFloat = 33
        /// [推] 传输键的命中盒。录屏量不到命中区，按「装得下最大的那件」定：
        /// 开启态圆盘 32、play.fill 的墨迹高 27、backward.fill 的墨迹宽 31，取 36。
        /// 附带的好处是随机键中心落在 34 时它的左沿正好是 `horizontalInset` = 16。
        static let transportButtonSize: CGFloat = 36
        /// [PX] 随机/循环「已开启」是字形底下垫一颗圆盘：62×64 px = 32
        static let transportActiveDiameter: CGFloat = 32
        /// [PX] 圆盘 206 对底色 170 → 白 0.42
        static let transportActiveOpacity: CGFloat = 0.42

        // MARK: 封面模糊衬底 `artworkBlur`（[实测] miniplayer spec §11.1/§11.3/§11.8.5）

        /// 控件区底下那一层**封面自己的模糊副本**（Music 的 `artworkBlur` 字段）。
        ///
        /// 两条约束定死了它的位置：`artworkBlur.alignBottomWith(largeArtwork)` 与
        /// `artworkBlur.alignTopWith(scrubberPlatter, offset: −106)`（−106，
        /// 整个原版唯一一处）；显隐是 `big && hasContentToShow && !isFullWindow`
        /// ——**只有窗口化组 II 有，全窗口没有**。
        ///
        /// Amber 没有 scrubber 盘（三个盘在 nib 里，spec §11.10-3 的缺口），拿进度条的**视觉上沿**
        /// 代替它的顶边：`91 + 5/2 + 106 = 199.5`。
        /// [PX] 原版录屏 `录屏2026-09-08 17.01.41.mov` 第 5 帧逐行量到的台阶在封面下沿上方
        /// **198pt**（窗宽 320 标定 2px/pt），与这条算式互证——所以这一条不是 [推]。
        ///
        /// **历史**：这里先后错过两次。第一次判成「模糊 + 半透明」，做成给封面挂 `layer.mask`
        /// 挖透明、露出底下 `.behindWindow` 的玻璃，于是控制区糊的是**窗口背后的桌面**
        /// （用户实机截图打回）；第二次矫枉过正，改成一条高 148 的黑色渐变，
        /// 那又丢了「封面内容糊在进度条底下」这个事实（录屏里看得清清楚楚）。
        /// 正解由 [实测] §11.8.5 给出：它自己画的就是**封面最下面那一条**
        /// （`layer.contents` = 封面、`contentsRect = (0, 0, 1, h/w)` 取底片），
        /// 自上而下由清到糊、再叠一层由透到暗的黑渐变。
        static let artworkBlurTopOffset: CGFloat = 106
        /// [实测] §11.8.5 `BlurView.init`：模糊是私有`CAFilter(kCAFilterVariableBlur)`，
        /// `kCAFilterInputRadius` = **10**（点）。上一版按放大截图估的「顶端 1 / 底端 3.5 像素」
        /// 太轻——原版这条带子底端是实打实糊开的。
        static let artworkBlurRadius: CGFloat = 10
        /// [实测]+[PX] 模糊量的竖向渐变：mask 是一张 1×225 的 `clear → white`，
        /// 渐变画到 `height × 2/3` 处，`drawsAfterEndingLocation` 把白铺满剩下的 1/3；
        /// [PX]（规格笔记 `Tools/px-blurview-geometry.swift` 实测）成像后顶端 alpha ≈ 0、底端 = 1
        /// ——即**自上而下 0 → 满，最下面那 1/3 恒为满**。
        static let artworkBlurRampEnd: CGFloat = 2.0 / 3
        /// [实测] 叠在模糊上的**压暗**：一张 1×255 的 `clear → black(0.3)` 子层，
        /// 渐变画到 `height × 0.5` 处后同样铺满，与模糊同向。
        ///
        /// 一度做成过「白纱」（往下渐白 0.28），那是看错了：原版那条带子发灰**不是纱**，
        /// 是《帶你飛》这张封面的下半截本来就是一张白纸，糊开自然是浅灰
        /// （用户实机打回：「咋又变成一层白色遮罩了」）。黑的这 0.3 是 ASM 定数，
        /// 「浅色封面下控件也看得清」靠的就是它。
        static let artworkBlurDimming: CGFloat = 0.3
        static let artworkBlurDimmingRampEnd: CGFloat = 0.5
        /// 模糊带的高度 = 进度条视觉上沿到封面下沿的距离，再加上那 106。
        static var artworkBlurHeight: CGFloat {
            scrubberCenterFromBottom + scrubberBarHeight / 2 + artworkBlurTopOffset
        }

        // MARK: 收起态（组 I，[PX] 2026-09-08 第二段录屏的实拍 `music_collapsed.png`）

        /// [推] 浮层排全套（标题/副标题/☆/⋯）要的最小可用高度。
        /// = 标题行顶距顶块下沿：117 + 副标题行 19 + 行距 2 + 标题行 20 = 158。
        /// 顶块高减掉安全区（工具条 52）还够 158 才排全套，不够就退成收起态那一组。
        static var metadataTopFromBottom: CGFloat { 158 }

        /// 收起态实拍的标定（下面三条 `collapsed*FromBottom` 全按这一套换算）：
        ///
        /// - 窗口左右边框列 x=8 / x=648 → 宽 640 px = **320 pt**，与 `minWidth` 严丝合缝，
        ///   于是 2 px/pt 与「取边框那一列/那一行」这条判据同时被证实；
        /// - 同一判据在方形态 `crop_square.png` 上给出 x=12/652（640 px）、y=19/660（641 px），
        ///   方形也对上，判据可靠；
        /// - 收起态窗口上边框 y=7、下沿亮线 y=314 → 高 307 px = **153.5 pt**
        ///   （不是任务书里估的 150；红绿灯中心 y=59.5 → 距顶 (59.5−7)/2 = 26.25，
        ///   与实测的「红绿灯中心距顶 26.5」互证，标定无误）。
        /// - 所以「距底」= (314 − 像素中线) / 2。
        ///
        /// 三条与展开态的关系值得记一笔：**进度条↔时间行的 19 pt 完全没变**
        /// （展开 91→72，收起 73→54），只有传输键那一档从 38 收到 23、整块下移 18。
        ///
        /// 横向度量两态**共用**（已验）：`horizontalInset` 16、`transportEdgeInset` 34、
        /// `transportSpacing` 58——所以这里只需要三条纵向偏移。

        /// [PX] 收起态进度条中线距窗底：可见轨道 y 163.5…173.5（10 px = 5 pt，与
        /// `scrubberBarHeight` 一致），中线 168.5 → (314 − 168.5)/2 = 72.75
        static let collapsedScrubberCenterFromBottom: CGFloat = 73
        /// [PX] 收起态时间行中线距窗底：「0:33」墨迹 y 198…214，中线 206 → 54
        static let collapsedTimeRowCenterFromBottom: CGFloat = 54
        /// [PX] 收起态传输键中线距窗底：shuffle 墨迹 y 237…268（中线 252.5）与
        /// play 墨迹 y 234…270（中线 252）两处互证 → (314 − 252)/2 = 31
        static let collapsedTransportCenterFromBottom: CGFloat = 31

        /// [PX] 收起态的自然内容高 = 153.5 pt（上面那条标定），取 154。
        ///
        /// 旧值取的是 [实测] 初始内容矩形的高 100——那是 `loadWindow` 的`contentRect`，
        /// 不是这一档安定下来的尺寸；100 高连「工具条 52 + 进度条 73」都排不下。
        /// 窗是 `fullSizeContentView`，chrome 高为 0，所以窗高 = 内容高。
        static let collapsedContentHeight: CGFloat = 154

        // MARK: 浮层 rollover（nowplaying spec §2.3）

        /// [推] 浮层整体淡入淡出的时长。规格只记了 `rollState` / 双计时器的**结构**，
        /// 没有留下时长；取 0.25，与底栏悬浮变形的 `NowPlaying.scrubMorphDuration` 同档。
        ///
        /// 两档延时不再是 [推]：`kMouseInterestTimeout` 3.75（指针在窗内不动）与
        /// `kMouseInterestExitingWindowTimeout` 0.3（指针离开窗口）都在 spec §11.1 里实测到了，
        /// 见上面的 hover 四常量。
        static let rolloverFadeDuration: TimeInterval = 0.25

        /// [推] 迷你横条静息层里，小封面与标题之间那一格。
        /// ASM 那边是 `titlePlatter.touchLeadingAgainst(artwork)`（间距 0），但标题盘自带内边距，
        /// 而内边距在 nib 里（spec §11.10-3 的缺口），拿不到；取 12 让 42pt 封面与文字不贴死。
        static let miniBarTitleSpacing: CGFloat = 12
    }

    // MARK: - Metal 动态背景（TSLBackdropMetalView）

    /// 「跟着封面走」的那支底衬：三层同一封面、不同锚位、不同周期慢转 → 高斯模糊 →
    /// 上屏时改饱和度 / 亮度钳位 / 明暗因子 / 纱罩。
    ///
    /// 规格正本 backdrop 规格（`[实测]` = 实测的
    /// 字节偏移与常量，`[MSL]` = 着色器给的字段名），接入侧
    /// `miniplayer 规格` §11.8。渲染实现在
    /// `Views/Shell/MiniPlayerBackdropMetalView.swift` + `MiniPlayerBackdrop.metal`。
    ///
    /// **这一节只有数值，没有「怎么用」**：uniform 的取值全是 `[实测]`，
    /// 但着色器如何用 floor/ceiling/padding 做网格扭曲，规格 §七明说没挖出来——
    /// 那部分数学写在 `.metal` 里并逐个标了`[推]`。
    ///
    /// 纱罩浓度 `0.7 − 0.4p` 与律动`10.5 − 9p` 不在这里：它们是**内容宽度**的函数，
    /// 已经在 `NowPlaying.backdropScrimAlpha(contentWidth:)` /
    /// `backdropAnimationInterval(contentWidth:)`，两处共用同一份（spec §11.8.3）。
    enum Backdrop {

        // MARK: uniform 的定数（spec §1.2 / §四 / §十）

        /// [实测]：初值 1.0，`PinchEncoder` 上屏那趟顶成 **2.0**
        /// （`-[PinchEncoder encode:…averageLuminosity:]`）。
        static let saturation: Float = 2.0
        /// [实测]：亮度钳位下界，`buildModels` 一次写死
        /// （浮点对 `{0.07, 0.97}`）。
        static let luminanceFloor: Float = 0.07
        /// [实测]：亮度钳位上界，同上一条。
        static let luminanceCeiling: Float = 0.97
        /// [实测]：`meshWarpTimeScale` 初值（浮点对`{0.0, 3.5}`），
        /// 每帧再按 `speed × 3.5` 重写（spec §3.1）。
        static let meshWarpTimeScaleFactor: Float = 3.5

        /// [实测] 三层模型的周期系数（`prepareImageScaleAndTime`
        /// 写）。★ 它是**周期（秒）不是速率**：数越大转得越慢。
        static let modelTimeScales: [Float] = [120, 90, 70]

        /// [实测] 三层的锚位（各层单位阵掺进第 4 列的平移，
        /// 量纲同 `viewMatrix`，即 clip/NDC 域）。居中 / 偏左上 / 偏左下——
        /// 不是三张同心旋转（spec §十）。
        static let modelTranslations: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(-0.5, 0.7, 0),
            SIMD3(-0.95, -0.7, 0),
        ]

        /// [实测] `Uniforms` 总长（两处`setVertexBytes:length:0x170` / `setFragmentBytes:` 实测）。
        /// 模型数组从起、stride `0x50`，`0x120 + 0x50 = 0x170` 正好吃满——
        /// 这是 `[实测]` 偏移与`[MSL]` 字段顺序两侧对齐的收口证据。
        static let uniformsByteLength = 368

        // MARK: speed / animationInterval（同一个，spec §3.1/§3.2）

        /// [实测] `-[TSLBackdropMetalView init]` 的默认值。
        static let defaultSpeed: Float = 0.5
        /// [实测] `setAnimationInterval:` 的夹取域。上游`10.5 − 9p` 的
        /// 10.5 端**永远够不到**——被这里削成 10.0。
        static let speedRange: ClosedRange<Float> = 0.1...10.0
        /// [实测] spec §3.1：「减弱动态效果」不是停，是把系数顶成 **5.0**
        /// ——比默认 0.5 大十倍，`timeScale` 是周期 ⇒ **慢十倍**。
        static let reduceMotionSpeed: Float = 5.0

        /// `animationInterval` 落地前先夹。
        static func clampSpeed(_ value: Float) -> Float {
            min(max(value, speedRange.lowerBound), speedRange.upperBound)
        }

        /// 三层的实际周期（秒）= `clamp(speed) × {120, 90, 70}`。
        /// 默认 speed 0.5 ⇒ 60 / 45 / 35；迷你窗 p=0 那档 speed 10 ⇒ 1200 / 900 / 700。
        static func modelPeriods(speed: Float) -> [Float] {
            let s = clampSpeed(speed)
            return modelTimeScales.map { s * $0 }
        }

        /// 每帧的 `meshWarpTimeScale` = `speed × 3.5`（spec §3.1）。
        static func meshWarpTimeScale(speed: Float) -> Float {
            clampSpeed(speed) * meshWarpTimeScaleFactor
        }

        // MARK: 交叉淡化（spec §3.3）

        /// [实测] `crossfadeDuration` 的默认值：换封面 **0.5 秒线性**，无缓动。
        static let crossfadeDuration: Float = 0.5

        /// [实测] `updateCrossfade`：`t += (−1/fps) / crossfadeDuration`，
        /// 跌到 0 就收尾（`transitionDidFinish`）。返回下一帧的`textureTransitionMix`。
        static func advanceCrossfade(_ mix: Float, framesPerSecond: Int) -> Float {
            guard mix > 0, framesPerSecond > 0 else { return 0 }
            let next = mix + (-1 / Float(framesPerSecond)) / crossfadeDuration
            return next > 0 ? next : 0
        }

        // MARK: 模糊（spec §2.2）

        /// [实测] `3.0348542587702925 = sqrt(2·ln 100)`——高斯降到峰值 1% 处的半径。
        /// 核宽用它乘、半径反推 σ 用它除，所以这套代码里「半径」= 1% 衰减半径。
        static let oneHundredthRadiusFactor = 3.0348542587702925
        /// [实测] `buildTextures:forView:`**入口一**：`σ = floor(对角线 × 这个数)`，
        /// ≈ 对角线 / 22.029。
        static let diagonalToSigma = 0.04539470697716646
        /// [实测] `blurRadius` 的默认值。
        static let defaultBlurRadius: Float = 50
        /// [实测] `-[TSLBackdropMetalView setBlur:]` 的夹取域。
        static let blurRadiusRange: ClosedRange<Float> = 4...2000
        /// [实测] `MPContentView` 建 backdrop 时那句`setBlur(1000)`（miniplayer spec §11.8.1）。
        static let miniPlayerBlurRadius: Float = 1000
        /// [实测] `setSize:forDevice:forView:fminnm`（Metal 纹理边长上限）。
        static let maxTextureDimension: CGFloat = 16384

        /// **入口一** —— 跟着画布尺寸走：`σ = floor(hypot(drawable 像素宽, 高) × 0.0453947)`。
        /// 稳态下生效的就是这条：`buildTextures:forView:` 每次重建纹理都无条件重算并
        /// 覆盖入口二，没有「blurRadius 已设过就跳过」的分支。
        static func sigma(diagonalPixels: CGFloat) -> Int {
            max(0, Int((Double(diagonalPixels) * diagonalToSigma).rounded(.down)))
        }

        /// **入口二** —— 外部指定半径：`blurRadius = clamp(v, 4, 2000)`、
        /// `σ = ceil(blurRadius / 3.0348542587702925)`。默认 50 → σ 17，`setBlur(1000)` → σ 330。
        /// ⚠ 它**会被入口一无条件覆盖**（见上一条），所以 1000 那个数在稳态下够不到。
        static func sigma(blurRadius: Float) -> Int {
            let r = min(max(blurRadius, blurRadiusRange.lowerBound), blurRadiusRange.upperBound)
            return Int((Double(r) / oneHundredthRadiusFactor).rounded(.up))
        }

        /// [推] 离屏那两张纹理的缩放系数：按 `drawable / 4`（线性）渲染，
        /// MPS 的 σ 同步除以它——这正是原版 `MPSImageGaussianBlur(sigma: σ / imageDownSample)`
        /// 的语义。理由是性能：σ 在迷你窗里就有 40 上下，整幅全分辨率高斯每帧几毫秒，
        /// 而结果是一张糊到看不出边界的底衬，1/4 边长（1/16 像素）肉眼分不出来。
        /// 原版 `imageDownSample` 的实数没读出来，这个 4 是 Amber 自己定的。
        static let offscreenDownsample = 4

        // MARK: 明暗与 scrim（spec §四 + §九）

        /// [实测] 深色支 `factorForDarkMode`。
        static let darkModeFactor: Float = 0.2
        /// [实测] 浅色支 `factorForLightMode` 的**暗封面**档。
        static let lightModeFactorDarkArtwork: Float = 0.38
        /// [实测] 浅色支 `factorForLightMode` 的**亮封面**档。
        static let lightModeFactorBrightArtwork: Float = 0.08
        /// [实测] 两档的阈值：`averageLuminosity < 0.3`——是个两档自适应，不是连续函数。
        static let luminosityThreshold: Float = 0.3
        /// [实测] `PinchEncoder init` 尾部一条同时写
        /// `blackScrimAlpha` 与`whiteScrimAlpha`。
        /// 前者被 `setScrimAlpha:`（即`0.7 − 0.4p`）覆写；后者**全`__text` 无写入方，恒 0.25**。
        static let defaultScrimAlpha: Float = 0.25

        /// 浅色外观下压多白：封面越暗压得越狠（spec §四）。
        static func lightModeFactor(averageLuminosity: Float) -> Float {
            averageLuminosity < luminosityThreshold
                ? lightModeFactorDarkArtwork
                : lightModeFactorBrightArtwork
        }

        // MARK: 平均亮度（spec §八）

        /// [实测] 大图先等比缩进 300 盒再逐像素算（横图 w=300、竖图 h=300）。
        /// 300 在原版里两处形态：double 300.0、
        /// 立即数。
        static let luminanceDownscaleBox = 300
        /// [实测] 触发降采样的像素数阈值（低功耗掉到 1000）。
        static let luminanceDownscaleThreshold = 100_000

        /// [实测] BT.601 的定点系数（none-skip 32bpp 支）：
        /// `Y = (R×4915 + G×9667 + B×1802 +) >> 14` = `0.30005R + 0.59003G + 0.10999B`。
        static func fixedPointLuma(r: Int, g: Int, b: Int) -> Int {
            (r * 4915 + g * 9667 + b * 1802 + 0x2000) >> 14
        }

        // MARK: Amber 自己的省电处理

        /// [推] 三层周期在迷你窗里是 700…1200 秒（speed 被 `10.5 − 9p` 顶到上限 10），
        /// 也就是**一圈要转十几分钟**——按 60fps 画纯属浪费。取 15：
        /// 交叉淡化那 0.5 秒还能分到 7 帧多，是这套动画里唯一「快」的东西。
        /// 每帧推进量 `dt = 1/preferredFramesPerSecond` 与原版同构，所以帧率只影响平滑度，
        /// 不影响任何时间常数。
        static let preferredFramesPerSecond = 15
    }

    // MARK: - 正在播放的电平指示条

    /// Music 详情页音轨行的「正在播放」不是喇叭图标，而是
    /// `TrackNowPlayingIndicatorView`（NSView 子类）画的一组电平条。
    /// 以下取自 Music 界面框架的实测值：
    /// - `init`：`levelViews` 按 4 个元素分配；
    ///   `interLevelSpacing = 3 / backingScaleFactor`、`levelCornerRadius = 1 / backingScaleFactor`
    ///   （即固定 3 个和 1 个设备像素，Retina 上是 1.5pt / 0.5pt）
    /// - `measurementsWithFitting:in:`：`width = min(levelWidth * 4 + 3, fitting)`、`height = maximumLevelHeight`
    /// - `layout`：4 条以`(levelWidth + interLevelSpacing)` 为步进整体居中
    /// - `levelWidth` / `maximumLevelHeight` / `levelColor` 由宿主行设置（都是 var）
    ///
    /// 出处标注：
    /// - [实测] 上述实测值
    enum NowPlayingLevels {
        /// [实测] 电平条数量（init 里按 4 个分配 levelViews）
        static let count = 4
        /// [实测] 条间距 = 3 设备像素
        static var spacing: CGFloat { 3 / scale }
        /// [实测] 条圆角 = 1 设备像素
        static var cornerRadius: CGFloat { 1 / scale }
        /// [实测] 固有宽度 = levelWidth × 4 + 3
        static func width(levelWidth: CGFloat) -> CGFloat { levelWidth * 4 + 3 }

        /// 详情页音轨行用的一档：宽 11（2×4+3），高与原来的 chart.bar.fill 字号齐平
        static let rowLevelWidth: CGFloat = 2
        static let rowMaximumLevelHeight: CGFloat = 11

        /// 暂停时电平停在最高高度的这个比例（Music 暂停不清零，只压平）
        static let idleLevel: CGFloat = 0.28
        /// 电平的最低比例，播放时在 minLevel…1 之间摆动
        static let minLevel: CGFloat = 0.22
        /// 四条各自的摆动周期（秒），互质一点才不会看出同相
        static let periods: [Double] = [0.62, 0.48, 0.71, 0.55]

        private static var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
    }

    // MARK: - 卡片（歌单/专辑网格）

    enum Card {
        /// 封面圆角
        static let artworkCornerRadius: CGFloat = 10
        /// 封面到文字的间距
        static let artworkToText: CGFloat = 8
        /// [PX] 标题/副标题行距
        static let textSpacing: CGFloat = 1
        /// 悬浮播放按钮直径与内边距
        static let playButtonSize: CGFloat = 34
        static let playButtonPadding: CGFloat = 8
        /// [实测] `AMPGridCollectionViewItem.labelViewHeight` → 46
        /// （方形卡片封面下方文字块的固定高度，两行）
        static let labelHeight: CGFloat = 46
    }

    // MARK: - 区块标题

    enum SectionHeader {
        /// [PX] 标题与说明的间距
        static let titleToSubtitle: CGFloat = 2
    }

    // MARK: - 星级评分

    enum Rating {
        /// [PX] 头部信息行星级：字形带 705.0–774.5（宽 69.5、单星 11.5、步进 14.5）。
        /// SF Symbol 星形自带约 3pt 左右边距，间距取 0 时步进正好 14.5。
        static let headerStarSize: CGFloat = 11
        static let headerStarSpacing: CGFloat = 0
        /// [PX] 与同行文字相比星形要上提 1pt 才能与 Music 的 167.0 对齐。
        static let headerStarOffsetY: CGFloat = -1
        /// [PX] 音轨行星级：字形带 1252.5–1311.0（宽 58.5、单星 10.5、步进 12.0）。
        /// 步进比字形+边距还紧，故用负间距收回 1.3。
        static let rowStarSize: CGFloat = 10
        static let rowStarSpacing: CGFloat = -1.3
        /// [AX] 音轨行星级列宽；列右沿固定，加宽后首星左移到 1252.5。
        static let rowWidth: CGFloat = 60
        /// [PX] 未评分的星是去饱和的品牌红，不是灰色：实测 rgb(90,49,52) 压在
        /// rgb(43,43,43) 行底上，反解出 amberKey @0.25。
        static let emptyOpacity: CGFloat = 0.25
    }

    // MARK: - 曲目行

    enum TrackRow {
        static let contentSpacing: CGFloat = 10
        static let verticalPadding: CGFloat = 3
        /// [PX] 行体右内缩：使时长右沿落在 1380、“更多”字形中心落在 1403。
        static let horizontalPadding: CGFloat = 15
        /// [PX] 专辑音轨表行体 45pt；与分隔线共同形成 Music.app 的行节奏。
        /// 参照 [实测] `AlbumDetailsViewController.trackRowHeight` → 46 / 54，
        /// 紧凑档实测 45 与回收值 46 差 1pt，以实测为准。
        static let compactHeight: CGFloat = 45
        /// [实测] `AlbumDetailsViewController.trackRowHeight` 的宽松档 → 54
        static let richHeight: CGFloat = 54
        /// [AX] Apple Music 歌单与榜单曲目行高实测 56pt（连续行间距 y 均为 56）。
        static let playlistRowHeight: CGFloat = 56
        /// [AX] Apple Music 歌单表头高度 32pt。
        static let playlistHeaderHeight: CGFloat = 32
        /// [实测] `TrackArtworkView.layout` → 40（原先 38 是估值）；圆角 5
        static let artworkSize: CGFloat = 40
        static let artworkCornerRadius: CGFloat = 5
        /// [PX] 序号槽位宽：使数字中心落在 262.5、曲名左沿落在 286.5。
        static let indexWidth: CGFloat = 27
        /// 榜单名次列宽。Apple Music 把名次排在**封面右边**、紧挨曲名，
        /// 只占一条窄列：封面右沿 →12→ 名次(16) →12→ 曲名，合计 40pt。
        static let chartRankWidth: CGFloat = 16
        /// 名次列两侧的留白
        static let chartRankGap: CGFloat = 12
        /// [AX] 歌单曲目表左侧收藏星预留槽位 40pt（使第 40pt 处的曲目小封面与上方的 270 大封面左沿精确对齐）
        static let playlistFavoriteAreaWidth: CGFloat = 40
        /// [AX] 歌单表时长列宽 53pt
        static let playlistDurationWidth: CGFloat = 53
        /// [AX] 歌单表右侧“更多”按钮槽宽 40pt
        static let playlistMoreWidth: CGFloat = 40
        /// 收藏键槽位宽
        static let favoriteWidth: CGFloat = 22
        /// 收藏键与行体之间的留白（星形在行体、行悬浮底色之外）
        static let favoriteGap: CGFloat = 4
        /// [PX] 专辑行的收藏键悬挂在行体左侧，不占用标题列宽度。
        static let detailFavoriteOffset: CGFloat = 24
        /// 行体自身的左内缩，使首列位置与旧版一致（8 + 22 + 4 + 6 = 40）
        static let rowBodyInset: CGFloat = 6
        /// 时长列宽
        static let durationWidth: CGFloat = 44
        /// [AX] 星级与时长之间的一列：Music 为 16pt，放「添加到资料库 / 下载」键。
        static let addWidth: CGFloat = 16
        /// [PX] 该键字形中心实测 1332；Amber 行内的 10pt 间距会把它挤到 1319.25，
        /// 用偏移推回原位（星级列已按首星落 1252.5 校准，不能跟着一起动）。
        static let addOffsetX: CGFloat = 12.75
        /// [PX] “更多”字形中心 1403；Music 的槽位比 Amber 原值窄。
        static let moreWidth: CGFloat = 23.5
        /// [实测] `EllipsisButton.intrinsicContentSize` → 28：
        /// 字形只占 23.5 的槽，但命中区是 28×28。
        static let moreButtonSize: CGFloat = 28
        /// 分隔线从曲名列起（不穿过序号与封面）
        static let dividerLeading: CGFloat = 82
        /// 悬浮底色圆角
        static let hoverCornerRadius: CGFloat = 6
        /// [PX] Music.app 选中行使用比 hover 更实的整行灰色状态层。
        static let selectedOpacity: CGFloat = 0.105
        static let hoverOpacity: CGFloat = 0.055
    }

    // MARK: - 资料库「歌曲」表格

    /// Music.app 资料库「歌曲」页不是专辑/歌单那套行组件，而是一张 NSTableView 式的表：
    /// 固定列宽、22pt 紧凑行、斑马纹底色、可排序列头，且页面本身没有大标题（标题在标题栏）。
    /// 校准基线：窗口 1470×923、深色，参照 design-ref/ui-spec/pages/songs.{json,png}
    /// 与 2026-08-15 的实机悬浮/选中态采样。
    enum SongsTable {
        /// [AX] 列头 23pt（22pt 内容 + 1pt 底线），紧贴标题栏（y=52…75）
        static let headerHeight: CGFloat = 23
        /// [PX] 列头底线与列间竖线同为 1pt、同色
        static let separatorWidth: CGFloat = 1
        /// [AX] 行高 22pt（＝中档），行与行之间没有分隔线（靠斑马纹分隔）。
        /// 三档见 `ListViewSize`——这只是中档的值，实际取值走全局偏好。
        static let rowHeight: CGFloat = 22
        /// [PX] 单元格文本左内缩（数字列取同值作右内缩），列头一致
        static let cellInset: CGFloat = 4.5
        /// [PX] 斑马纹：偶数序位行 rgb(53) 压在内容底 rgb(43) 上 → 白 4.7%。
        /// 注意要压在 textColor（纯白）上；用 .primary 会先吃掉 labelColor 自带的 85%。
        static let stripeOpacity: CGFloat = 0.047
        /// [PX] 选中行 rgb(68) → 白 11.8%。**悬浮不改底色**，只让下载/星形显形。
        static let selectedOpacity: CGFloat = 0.118
        /// 正文 12pt（＝中档），列头 12pt。
        ///
        /// 这里原先写的是 13——把量到的「CJK 字形高 12」当成字号反推，多算了一号。
        /// 2026-08-16 与 Music 1.7 同屏逐像素比过：Music 的标题字形纵向占 12.0pt，
        /// Amber 当时占 13.0pt，确实大了一圈；而 `setupListFontFromPrefs:`（`[实测]`）
        /// 三档写死的就是 11 / 12 / 14pt，中档 12 与实测完全对得上。
        static let fontSize: CGFloat = 12
        static let headerFontSize: CGFloat = 12

        // 列宽 [AX]：内容左沿 202.5 起，边界落在 228.5/428.5/455.5/514.5/639.5/764.5/844.5/871.5/950.5/1041.5
        /// 播放指示器槽（无列头文字）
        static let nowPlayingWidth: CGFloat = 26
        static let titleWidth: CGFloat = 200
        static let cloudWidth: CGFloat = 27
        static let durationWidth: CGFloat = 59
        static let artistWidth: CGFloat = 125
        static let albumWidth: CGFloat = 125
        static let genreWidth: CGFloat = 80
        static let favoriteWidth: CGFloat = 27
        static let ratingWidth: CGFloat = 79
        static let playCountWidth: CGFloat = 91

        /// [PX] 正在播放的喇叭 13.5×11.5，且是纯白（textColor）而非 85% 的正文色
        static let nowPlayingIconSize: CGFloat = 12
        /// [PX] 云端列 arrow.down 字形 10×11.5
        static let cloudIconSize: CGFloat = 13
        /// 下载中那圈进度环的线宽 [推]：环的直径沿用图标那一档（13），
        /// Music 的环没有实测样本，取 1.5 —— 再细在 22pt 行里看不清，再粗就成了实心饼。
        static let cloudRingWidth: CGFloat = 1.5
        /// [PX] 心水星字形 12.5×12（已心水实心常显，未心水空心仅悬浮显形，同为品牌红）
        static let favoriteStarSize: CGFloat = 11.5
        /// [PX] ••• 字形带 14.5×2.5，右沿距标题列右边界 4.5。
        /// 本表的 ••• **常显且常为品牌红**，与专辑页「悬浮才转红」不同。
        static let moreSize: CGFloat = 15
        static let moreWidth: CGFloat = 16
        /// [PX] 评分 5 星占 63pt（首星 875.5、末星止 938.5）：单星 10.5、步进 13.1；
        /// 10pt 星形自带 12.9 步进，只需再补 0.2。
        static let ratingStarSize: CGFloat = 10
        static let ratingStarSpacing: CGFloat = 0.2
        /// [PX] 星形自带左边距，评分列左内缩比文本列小
        static let ratingInset: CGFloat = 3
        /// [实测] `AMPTrackDisplayController.calcAutosizeColumnAtIndex:`（331 条）
        /// **不是**「文字实宽 + 10 再夹 16…200」——那是早先按常量猜的读法。逐指令跟下来是按列分流：
        /// - 普通文本列：扫全表取最宽字符串（`findMaxWidthForAllStrings:with:`），下限 **16**；
        /// - 时长列 / 音轨编号列：只把「最长的那首 / 号码最大的那首」装进模板单元测一次，下限同样 16；
        /// - 专辑封面跨行列：固定 **200**（唯一一处 200，与其它列的上限无关）；
        /// - 模板单元建不出来、或量出来 ≤ 0：才回退 **10**（`autosizeColumnAtIndex:` 里兜底）。
        /// 全程没有额外留白，也没有 200 的统一上限。
        static let autoFitMinWidth: CGFloat = 16
        static let autoFitFallbackWidth: CGFloat = 10
        static let albumArtworkAutoFitWidth: CGFloat = 200
        /// [PX] 列头排序箭头字形 6.5×3.5，右沿距列右边界 5.5
        static let sortArrowSize: CGFloat = 9
        // 页面标题的字号与左内缩原先在这里（`titlebarTitleSize = 13` / `titlebarTitleLeading = 11`）。
        // 字号那条 [PX] 量到的 13 就是 `NSFont.systemFontSize`，直接用系统的（见 ContentToolbar）；
        // 左内缩归 `Titlebar.titleLeading` 一处管。两条都已删。

        // 工具栏右端 [AX]：标题槽一直吃到 x=1192，筛选槽 1208 宽 40、高 52（整条工具栏），
        // 紧接着搜索槽 1248 宽 217，搜索框本身 1251,7 宽 211 高 38（右沿距窗口 8）。
        // 筛选与搜索之间没有空档——1208+40 正好是 1248。
        /// 搜索框宽度。Music 是拿一组本地化字符串算出来的
        /// （`MusicFilterBarToolbar.filterFieldWidthCalculationStrings`，跨页面不变宽），
        /// 这里取 zh_CN 的实测结果。
        static let searchFieldWidth: CGFloat = 211
        static let searchFieldHeight: CGFloat = 38

        // 开「显示插图」后的形态 [AX 2026-08-16 实测]：
        // 最左多出一条「插图」列 x=202.5 宽 230（与 ColumnWidths.plist 的 Artwork 同宽，最小 40），
        // 「状态」列由 26 撑到 56——那条槽这时要放曲目编号；行高仍是 22。
        // 表格按专辑分组，插图那一格跨整组的高度（列头写的是「按艺人排列专辑」）。
        static let artworkWidth: CGFloat = 230
        /// [实测] 曲目封面列（字段 37）：`loadColumnsFromSet:` 写死宽 **50**，
        /// 不可移动也不可缩放；开着它时 `desiredRowHeight` 直接返回 **54**。
        static let trackArtworkWidth: CGFloat = 50
        static let trackArtworkRowHeight: CGFloat = 54
        /// 封面在行里的上下留白：行高 54 − 封面，取 `preferredWidthWithAspectRatio:rowHeight:`
        /// 的语义——正方形封面按行高收进来，两边各留一点。
        static let trackArtworkInset: CGFloat = 4
        static let artworkStatusWidth: CGFloat = 56
        /// [PX] 2026-08-16 与 Music 1.7 同屏逐像素量的插图格（列左边界为 0 点）：
        /// 默认档封面 56×56、左内缩 7、顶内缩 2.5；文字左沿恒在 **71**＝内缩 7 + 封面 56 + 间距 8。
        /// 关键一条：**封面不画的时候文字也不左移**——组太矮没画封面时，Music 照样把
        /// 封面那段宽度空在那儿，所以每一组的专辑名左沿都在同一条竖线上。
        /// 把滑杆**往大拉一档**再量，文字左沿跟着挪到 115（＝7 + 100 + 8），可见留白是跟着封面走的。
        /// （旧注释把这一档写成「拉到最大」是错的：115 那次量到的是**中间**那一档＝5 行，
        /// 真正的最大档是 7 行。见下面 `artworkRowSpans`。）
        static let artworkInset: CGFloat = 7
        /// 封面在块内的**顶部留白**（[PX] 2.5）。与下面的 `albumArtMargin` 不是一回事：
        /// 这条只管块里封面往下挪多少，不参与封面边长的计算。
        static let artworkTopInset: CGFloat = 2.5
        static let artworkCoverGap: CGFloat = 8
        /// 「插图大小」滑杆的三档——**档位的本体是跨行数，不是封面边长**。
        /// [实测] `-[AMPTrackDisplayController currArtworkRowSpan]`：
        /// `albumArtworkSize == 1 → 5`、`== 2 → 7`、其余 →`3`。
        static let artworkRowSpans: [Int] = [3, 5, 7]
        /// 封面上下各扣一份的边距，[实测] `currArtworkDimension`：
        /// 封面边长 = `tableView.rowHeight × currArtworkRowSpan − albumArtMargin × 2`
        /// （歌曲页这条路上取的是 `mPlaylist.albumArtMargin()`）。
        /// 报告没直接给值，由上面两条 [PX] 解出来：中档行高 h = 22，
        /// `3h − 2m = 56`（默认档）、`5h − 2m = 100`（往大拉一档）→ 2m = 10、**m = 5**，两点同时成立。
        static let albumArtMargin: CGFloat = 5
        /// [PX] 专辑名 13 半粗、艺人 13、下面一行星级
        static let artworkTitleSize: CGFloat = 13
        static let artworkStarSize: CGFloat = 10
    }

    // MARK: - 资料库网格页（专辑 / 最近添加）

    /// 资料库的专辑网格（`AlbumsGridViewController` 那一族页面：专辑、最近添加）。
    /// 校准基线：design-ref/ui-spec/pages/albums.{json,png}、recently-added.{json,png}
    /// （Music 1.7，窗口 1470×923，内容列 202.5 宽 1267.5）。
    enum LibraryGrid {
        /// [AX] 网格左/右沿距内容列 28.75（专辑页网格 231.25…1441.25，宽 1210）。
        /// [实测] `AMPCollectionGridBaseLayout.prepareLayoutWithTotalViewWidth:` 的
        /// ≥740 档给的是 margin 40 / gutter 20，与实测 28.75 / 10 都对不上——以实测为准，
        /// 断点结构仍按 [实测]（<740 收窄一档）。
        static let margin: CGFloat = 28.75
        /// [AX] 列间距：相邻 cell 左沿 pitch 244 − cell 宽 234 = 10。
        static let gutter: CGFloat = 10
        /// [AX] 行距：同行 cell 高 290（234 封面 + 46 文字 + 10 底垫），相邻两行封面顶
        /// 相差 296 → 行间空 6。与 [实测] rowSpacing = gutter + 4 = 14 差 8，以实测为准。
        static let rowSpacing: CGFloat = 6
        /// [AX] 首行封面顶 110，内容列顶 85 → 网格距顶 25（专辑/最近添加两页一致）。
        static let topPadding: CGFloat = 25
        /// [实测] `AMPGridCollectionViewItem.labelViewHeight` → 46（封面下方文字块定高，
        /// 标题两行 + 艺人一行）。与 `Card.labelHeight` 同源（实测是同一个值），引用那一份。
        static let labelHeight: CGFloat = Card.labelHeight
        /// [AX] cell 高 290 = 封面 234 + 文字 46 + 底垫 10。
        static let cellBottomPad: CGFloat = 10
        /// [实测] `AMPGridCollectionViewItem.prepareForReuse` 的 label 布局常量 12 / 10
        /// （左 12、右 10）；[AX] 文字块 243.5 起、宽 214 与 234−12−10 相符。
        static let labelLeading: CGFloat = 12
        static let labelTrailing: CGFloat = 10

        /// 列数档 [实测] `AMPDynamicGridMetrics`：≥1320 大 / ≥1000 中 / ≥740 小 / <740 xs。
        /// 专辑页与艺人网格同用 3/4/5/6（`gridGMetrics`）一族：
        /// 实测内容列 1267.5 落中档 5 列（1210 = 5×234 + 4×10），若按 `gridCMetrics`
        /// 的 2/3/4/5 只能是 4 列，与 AX 不符，故取 3/4/5/6。
        /// 入参是网格容器宽（内容列宽），不是窗口宽。
        static func columns(forWidth width: CGFloat) -> Int {
            if width >= 1320 { return 6 }
            if width >= 1000 { return 5 }
            if width >= 740 { return 4 }
            return 3
        }

        /// [实测] item 宽 = (width − 2·margin − (cols−1)·gutter) / cols。
        /// 实测复核：1267.5 − 57.5 − 40 = 1170 → 5 列各 234 ✓
        static func itemWidth(containerWidth: CGFloat, columns: Int) -> CGFloat {
            guard columns > 0 else { return containerWidth }
            return (containerWidth - margin * 2 - CGFloat(columns - 1) * gutter) / CGFloat(columns)
        }

        /// [AX] cell 整高 = 封面（列宽的正方形）+ 文字块 46 + 底垫 10（234 → 290）。
        /// `LibraryGridCard` 的自然高就是这个，槽给小了封面会被压。
        static func cellHeight(itemWidth: CGFloat) -> CGFloat { itemWidth + labelHeight + cellBottomPad }

        /// 容器宽（内容列宽）→ cell 尺寸。宽还没定（≤0）时返回 nil：
        /// 此时算出来的列宽没有意义，别拿它去灌布局或建卡片。
        static func itemSize(containerWidth: CGFloat) -> CGSize? {
            guard containerWidth > 0 else { return nil }
            let width = floor(itemWidth(containerWidth: containerWidth,
                                        columns: columns(forWidth: containerWidth)))
            guard width > 0 else { return nil }
            return CGSize(width: width, height: cellHeight(itemWidth: width))
        }

        /// 「最近添加」分区头字号。[PX] recently-added.png「本周」字形带 ~20pt [推]。
        static let sectionHeaderSize: CGFloat = 22
        /// [AX] 「本周」段：分区列表顶 406 → cell 顶 466，分区头整带 60；
        /// 文字约 26 → 头到网格 14 [推]。
        static let sectionHeaderToGrid: CGFloat = 14
        /// 分区之间的空档 [推]。
        static let sectionSpacing: CGFloat = 30
    }

    // MARK: - 资料库艺人页（分栏浏览）

    /// Music 1.7 的「艺人」页是分栏浏览：左列表 + 右详情
    /// （`ItemTracklistSplitViewController` + `ArtistsTracklistSplitViewController`，
    /// 见 `artists 规格` §5）。
    /// 校准基线：design-ref/ui-spec/pages/artists.json、library-artist-detail.{json,png}。
    enum LibraryArtists {
        /// [AX] 左列（列表）整条 298 宽（202.5…500.5，含滚动条），右侧详情从 503.5 起。
        /// [实测] `ItemTracklistSplitViewController.loadView` 的宽度约束是 [150, 350]。
        static let listWidth: CGFloat = 298

        /// [AX] 行高 54（y=85/139/193…），行内容宽 280（212.5…492.5，左右各内缩 10）。
        static let rowHeight: CGFloat = 54
        static let rowHorizontalInset: CGFloat = 10
        /// [AX] 头像 40（截图 222.5…262.5）。
        static let avatarSize: CGFloat = 40
        /// [AX] 行文字左沿 = 行左 + 54（实机 2026-09-07：行 210、文字 264；
        /// 头像占 +10…+50，文字距头像右沿 4）。
        static let rowTitleLeading: CGFloat = 54
        /// [PX] 左列分割线从**文字列**起到行右沿（实机 PNG x 264.4…500.9，行右 500.5），
        /// 选中行的填充会盖住它。
        static let rowSeparatorLeading: CGFloat = 54
        /// 首行固定「所有艺人」（`artists 规格` §5.3 的置顶 section 行，
        /// AX 实录 cell 值）。
        static let allArtistsRowTitle = "所有艺人"

        /// 右侧详情（选中艺人后）：标题「告五人」(543.5,110 72x31)、
        /// 副标题「2张专辑，13首歌曲」(543.5,159 107x15)、专辑块滚动区 (503.5,182 967x692)。
        static let detailTopPadding: CGFloat = 25
        /// [AX] 标题字形带高 31 → 26pt bold（与专辑详情页标题同档）。
        static let detailTitleSize: CGFloat = 26
        /// [AX] 标题底 141 → 副标题顶 159；副标题 13pt。
        static let detailTitleToSubtitle: CGFloat = 18
        static let detailSubtitleSize: CGFloat = 13
        /// [AX] 副标题底 174 → 滚动区顶 182。
        static let detailHeaderToContent: CGFloat = 8
        /// [AX] 详情文字列左沿 543.5，滚动区左沿 503.5 → 40（与专辑详情页头部
        /// leading 40 [实测] 同源）。
        static let detailHorizontal: CGFloat = 40

        /// [PX] 头部四枚圆钮（播放/随机播放/喜爱/更多）：直径 25（PNG 1304…1329）、
        /// 相邻间距 11、末枚右沿距详情右沿 32（1436.9 vs 窗右 1470），与标题行居中。
        /// 圆底比内容底亮约 5% 白（实测 43 → 53）。
        static let headerButtonDiameter: CGFloat = 25
        static let headerButtonGap: CGFloat = 11
        static let headerButtonTrailing: CGFloat = 32
        /// [PX] 圆钮组顶距详情顶 30（Music 圆钮 82…107，详情顶 52）。
        /// 系统默认的「与 26pt 标题字段居中」给出的是圆心 92，实测 Music 是 94.5——
        /// 标题字形（81.5…104.5）与字段（77…107）都对得上，唯独圆钮低 2.5，
        /// 没找到能推出来的锚点，所以按实测直接定顶距。
        static let headerButtonTop: CGFloat = 30
        /// [PX] 选中某位艺人时的固定头：详情顶 52 起，标题字段 77…107、细线 117、
        /// 副标题 125…141，末元素下留 8。
        static let headerHeight: CGFloat = 97
        /// 「所有艺人」时详情面是**按艺人分组**的（Music 实拍：陳婧霏 / 陳粒各一个组头，
        /// 名字 + ▶ ⤨ ★ ⋯ + 细线，组头下面直接是专辑块）。组头**没有副标题**，
        /// 同一套上下留白去掉副标题那一行：细线底 66 + 8 = 74。[推]
        static let groupHeaderHeight: CGFloat = 74
        /// [PX] 标题行下的细线：左与标题字形对齐（543.5 = 详情左 + 40）、右与末枚圆钮
        /// 右沿齐（1440.5）；**y = 117**——标题字形底 104.5 之下 12.5、副标题字形顶 128
        /// 之上 11，正落在两行之间。换算到 26pt 标题字段（frame 77…107）＝字段底往下 10。
        /// 早先的 3.5「往上」是把线画到了标题字里，2026-09-07 重测更正。
        static let headerHairlineGapBelowTitle: CGFloat = 10
        static let headerHairlineTrailing: CGFloat = 32

        /// 专辑块（library-artist-detail，2026-09-07 重测 @2x PNG，窗口原点经红绿灯校准；
        /// 与实机 AX 互核）：封面 359.5 见方（x 531.4…890.9、y 170…529.5）。
        /// 块顶到标题 30，标题到信息行 11，信息行到曲目首行 20，曲目行高 54。
        /// 早先的「内缩 44 / 宽 334」是 ÷1.3605 的错误标定，一并更正。
        static let blockArtworkInset: CGFloat = 30
        /// [PX] 封面随详情宽按 0.371 收放（359.5 / 969），夹在 200…360。
        static let blockArtworkFraction: CGFloat = 0.371
        static let blockArtworkMin: CGFloat = 200
        static let blockArtworkMax: CGFloat = 360
        /// [AX] 文字列左沿 897（两次 AX 会话一致），距封面右沿 890.9 为 6.5。
        static let blockArtworkToColumn: CGFloat = 6.5
        /// [AX] 专辑标题「帶你飛」(923.5,212 57x24)：22pt bold；与曲目表左沿 899.5 差 24。
        static let blockTitleSize: CGFloat = 22
        static let blockTitleIndent: CGFloat = 24
        /// [AX/PX] 封面与专辑标题同顶对齐，块顶距滚动区/块顶部 12pt。
        static let blockTopPadding: CGFloat = 12
        static let blockTitleTop: CGFloat = 12
        /// [PX] 标题字段底 → 信息行字段顶 = 9（Music 块 1：标题 22pt 字段 179…205、
        /// 信息行 13pt 字段 214…230；两行字形 182.5…199.5 与 217…226 也对得上）。
        /// 早先的 11 让信息行低了 2，连带按这一组中线摆的两枚圆钮整体偏低。
        static let blockTitleToMeta: CGFloat = 9
        static let blockMetaSize: CGFloat = 13
        /// [PX] **封面顶 → 曲目首行顶 = 70**（块 1 179→249、块 2 644→714，两块一致）。
        /// 曲目首行顶＝那条分割线所在处。直接记这一个数，不要再用
        /// 「字号 + 间距 + 字号 + 间距」那摞去凑——约束排版走的是字段实高（26 / 16），
        /// 和字号那摞对不上，两套算法迟早打架。
        static let blockArtworkTopToTracks: CGFloat = 70
        /// [PX] 专辑块右侧两枚圆钮（入库 / 更多）：直径 25（PNG 1375.9…1399.9）、
        /// 间距 12、末枚右沿距格右 34（1435.9 vs 格右 1470）；
        /// 竖直居中于「标题 + 信息行」组 [推]（实测圆心 200，组心 195.5）。
        static let blockButtonDiameter: CGFloat = 25
        static let blockButtonGap: CGFloat = 12
        static let blockButtonTrailing: CGFloat = 34
        /// [AX] 曲目行 pitch 54；cell 511×55（897…1408，两会话 511/513），不随详情拉伸。
        static let trackRowHeight: CGFloat = 54
        static let trackCellWidth: CGFloat = 511
        /// 曲目行的列（[PX] 2026-09-07 用 library-artist-detail.png 的选中红行重测，
        /// 格 900…1410.5；与用户提供的 Music 悬浮态截图互核）：
        /// 心水星字形 +5…+14、序号 +23 **左对齐**、歌名字形 +58、
        /// 评分五星 +270…+332、**下载列字形中心距格右 122**、
        /// 时长字形右沿距格右 59.5、⋯ 字形距格右 17…31（命中区 1361…1411 ＝贴格右宽 50）。
        static let trackStarLeading: CGFloat = 4
        static let trackStarSize: CGFloat = 11.5
        static let trackNumberLeading: CGFloat = 22
        static let trackNumberWidth: CGFloat = 16
        static let trackTitleLeading: CGFloat = 58
        static let trackRatingLeading: CGFloat = 269
        static let trackRatingWidth: CGFloat = 71
        /// [PX] 下载列圆心距格右 122（红行 ↓ 字形 1284…1293.5，格右 1410.5）。
        /// 列宽沿用歌曲表的 `SongsTable.cloudWidth`＝27，字形 13pt、进度环线宽 1.5。
        static let trackCloudTrailing: CGFloat = 122
        static let trackCloudWidth: CGFloat = 27
        static let trackCloudIconSize: CGFloat = 13
        static let trackCloudRingWidth: CGFloat = 1.5
        static let trackDurationTrailing: CGFloat = 59.5
        /// [AX] ⋯ 的命中区 1361…1411：贴着格右、宽 50，字形居中即距格右 25。
        /// 早先按「字形右沿距格右 4」摆成宽 24，字形被顶到距格右 12，整簇偏右 13。
        static let trackMoreWidth: CGFloat = 50
        /// [PX] 分割线 1pt，画在**每行的顶边**（不是底边）：所以信息行与曲目首行之间
        /// 有一条（块 2 y=714 ＝首行顶），而末行下面没有（块 1 单曲行底 304 无线）。
        /// 左从 +24 起（序号列左沿）到格右；选中/播放的圆角红底盖住本行那条。
        static let trackSeparatorLeading: CGFloat = 24
        static let trackHighlightCornerRadius: CGFloat = 5
        /// [PX] 圆钮底：内容底色上叠 5% 白（实测 43 → 53）。
        static let circleButtonFillAlpha: CGFloat = 0.05
        /// 「停止下载」那枚是透底 + 品牌红描边圆（Music 实拍：红圈里一个红方块）。
        static let circleButtonRingWidth: CGFloat = 1.5
        /// [AX] 专辑块间距：块 1 封面底 504 → 块 2 封面顶 639（空档 135；AX 会话
        /// 块高 465 − 封面带 346 = 119），取 120。早先的 48 是拍脑袋值，排版过密。
        static let blockSpacing: CGFloat = 120

        /// 「选择艺人」空态文案 [AX]（右侧详情未选中时的居中提示）。
        static let emptyDetailTitle = "选择艺人"
    }

    // MARK: - 显示选项窗口

    /// 「查看显示选项」开出的那扇窗（[AX] 286×655，标题「显示选项」）。
    /// 窗口原点 (592,123)，下面的值都是由 AX 的绝对坐标换算成窗口内相对量。
    enum SongsViewOptions {
        /// [AX] 窗口宽 286
        static let windowWidth: CGFloat = 286
        static let windowHeight: CGFloat = 655
        /// [AX] 「排序方式：」标签左沿 604 → 距窗口左 12；勾选框左列 611 → 19，取整用 20
        static let contentInset: CGFloat = 20
        /// [AX] 标签右沿到弹出菜单左沿 694-688
        static let sortLabelGap: CGFloat = 6
        /// [AX] 弹出菜单 122×20
        static let sortPickerWidth: CGFloat = 122
        static let sortRowPadding: CGFloat = 14
        static let dividerInset: CGFloat = 12
        /// [AX] 两列勾选框左沿 611 / 744，相距 133
        static let checkboxColumnWidth: CGFloat = 133
        /// [AX] 相邻两行勾选框 18 一跳，控件本身就有 18 高，行距按 0 排
        static let rowSpacing: CGFloat = 0
        /// [AX] 上一组末行 479 → 下一组三角 515，扣掉行高约 18
        static let groupSpacing: CGFloat = 18
        /// [AX] 折叠三角 12×12，三角左沿 611 与组内勾选框对齐
        static let triangleSize: CGFloat = 10
        static let triangleGap: CGFloat = 5
        /// [AX] 「显示插图」205 →「始终显示」226，隔 21；两者左沿都是 638（比正文再缩一档）
        static let artworkRowSpacing: CGFloat = 3
        static let artworkIndent: CGFloat = 18
    }

    // MARK: - 设置窗口

    /// 「音乐 › 设置…」那扇窗。数值来自 2026-09-05 对 Music 的 AX 树与截图实录
    /// （`settings 规格` §0/§6，窗口原点 [410, 35]，
    /// 下面都换算成了窗口内的相对量）。
    ///
    /// 内容区是**一栏两列**：标签右对齐到控件列左缘，控件列左对齐；组与组之间通栏
    /// hairline，**没有分组框**（所以不能用 `.formStyle(.grouped)` 那套圆角卡片）。
    enum Settings {
        /// [AX] 四张页的宽度恒 650，高度随内容变（通用 647 / 播放 852 / 文件 332 / 高级 469）
        static let windowWidth: CGFloat = 650
        /// [AX] 帮助键左沿 429 距窗口左 410 是 19，组分隔线也从这一列起，取整 20
        static let contentInset: CGFloat = 20
        /// [AX] 内容组顶 123 → 首行控件 142
        static let contentTop: CGFloat = 19
        /// [AX] 标签右沿 583 → 控件左沿 589
        static let labelGap: CGFloat = 6
        /// [AX] 组内相邻两件相隔 6（勾选框 142 高 18 → 说明 166）
        static let rowSpacing: CGFloat = 6
        /// [AX] 说明相对所属勾选框右缩 20（589 → 609），即与勾选框的**文字**对齐
        static let descriptionIndent: CGFloat = 20
        /// [AX] 控件列 589→1041 宽 452（说明文字 432 = 452−20 的缩进），
        /// 标签列吃掉剩下的 152 并右对齐——所以标签靠的是控件列，不是窗口左沿
        static let controlColumnWidth: CGFloat = 452
        /// [AX] 上一组末行底 296 → 下一组首行 311，分隔线落在这 15 的中间
        static let groupSpacing: CGFloat = 15
        /// [PX] 正文 13、说明 11（说明行高 16）、节标题 13 加粗
        static let labelSize: CGFloat = 13
        static let descriptionSize: CGFloat = 11
        /// [AX] 取消 / 好各 52×26，两者相隔 10
        static let buttonWidth: CGFloat = 52
        static let buttonHeight: CGFloat = 26
        static let buttonSpacing: CGFloat = 10
        /// [PX] 按钮行上方那条通栏细线离按钮约 10；[AX] 按钮底距窗口底 22
        static let bottomBarTop: CGFloat = 10
        static let bottomBarBottom: CGFloat = 22
        /// [AX] 高级页那三颗还原键定宽 116.5（三行按钮左沿对齐靠的就是它）
        static let wideButtonWidth: CGFloat = 116.5
        /// [AX] 文件页「更改…」「重设」各 62.5×26，相隔 6
        static let smallButtonWidth: CGFloat = 62.5
        /// [AX] 声音增强器滑杆 245 宽（`Sound Enhancer Slider`，量程 0–255）
        static let sliderWidth: CGFloat = 245

        /// 「导入设置…」子对话框（[AX] 2026-09-05 补测，独立 `AXDialog`，原点 [463,176]）。
        enum Import {
            /// [AX] 544×353，比主设置窗窄
            static let windowWidth: CGFloat = 544
            static let windowHeight: CGFloat = 353
            /// [AX] 标签左沿 477 → 距窗口左 14
            static let contentInset: CGFloat = 14
            /// [AX] 标题文字 y=184 → 距窗口顶 8
            static let titleTop: CGFloat = 8
            /// [AX] 首行控件 y=224 → 距窗口顶 48，扣掉标题那一行
            static let contentTop: CGFloat = 24
            /// [AX] 控件列 629 → 距窗口左 166，于是标签列 146；两者相加加间距等于内容宽
            static let controlColumnWidth: CGFloat = 364
            /// [AX] 两颗 popup 都是 253×26。**只作记录**：真按这个宽度写 frame，
            /// SwiftUI 会把自然宽的 popup 在框里居中，反而离开控件列。
            static let popupWidth: CGFloat = 253
            /// [AX] 「详细信息」下面那个**有框**的规格说明 274×60
            static let detailBoxWidth: CGFloat = 274
            static let detailBoxHeight: CGFloat = 60
            /// [AX] 这扇窗的取消/好是 86×23（主设置窗是 52×26），底距 20
            static let buttonWidth: CGFloat = 86
            static let buttonBottom: CGFloat = 20
        }
    }

    // MARK: - 目录艺人页（hero + 货架）

    /// Music 的目录艺人页**不是详情表格，是一张目录页**（`catalogpage 规格`：
    /// `ArtistDetailPageView` 与主页/新发现同走`CatalogPagePresenter`）：
    /// 满幅艺人大图 hero → 「最新發行 + 熱門歌曲」并排一条带 → 「專輯」货架。
    ///
    /// 下面这些数量自 `design-ref/ui-spec/pages/catalog-artist.png`（@2x 全屏截图，
    /// 窗口 1468×922 pt、侧栏 203、内容列 1265，与 `songs.json` 等 [AX] 页同一套坐标）。
    /// 标 [PX] 的是从那张图上量的，只有一张样本，实机验收后按需要再收敛
    /// （不要为了对上某一位艺人的照片去调这些数）。
    enum ArtistPage {

        // MARK: hero

        /// [PX] hero **段**高 = 0.72 × 视口高：1470×923 实机段底 ~664（「最新發行」标题
        /// 685 ≈ 段底 + 25 段距）。宽幅图按内容列宽铺出来只有 ~580——名字与三枚圆键
        /// **锚在段底**，正好骑在图底的渐糊带上（实机播放圆心 ~614 > 图底 580），
        /// 整体靠下；所以段高跟视口走、不跟图高走。
        static let heroHeightRatio: CGFloat = 0.72
        /// [实测] `artistpage` 的`viewWillLayout` 取不到值时的兜底常量 385，
        /// 当作 hero 的下限用（窄窗口下大图不至于塌成一条）。
        static let heroMinHeight: CGFloat = 385

        /// hero 段高 = `heroHeightRatio` × 视口高，下限`heroMinHeight`。
        /// 布局（`artistHeroSection`）与钉住的背景层（`ArtistBackdropView`）共用，
        /// 两处必须给同一个数；图在里面按 fit-width 铺、顶对齐、不裁切。
        static func heroHeight(viewportHeight: CGFloat) -> CGFloat {
            max(heroHeightRatio * viewportHeight, heroMinHeight).rounded()
        }

        /// [PX] 艺人名字形带高 36（「告五人」三字宽 116.5 → 单字 38.8）→ 40pt bold。
        static let heroNameSize: CGFloat = 40
        /// [PX] 名字基线在按钮行顶上方 20.5（实机 1470×923：基线 ~563、按钮顶 580）。
        static let heroNameToButtons: CGFloat = 20.5
        /// [PX] 白底播放圆直径 69（图上 138 px），两侧圆键 45，相邻边距 27。
        static let heroPlayDiameter: CGFloat = 69
        static let heroSideDiameter: CGFloat = 45
        static let heroButtonSpacing: CGFloat = 27
        /// [PX] 按钮行底距 hero **段底** ~15（实机 1470×923：段底 664、按钮底 649；
        /// 窗口缩到 1000×640 重测仍是 ~15）——按钮整排骑在图底那条渐糊带上。
        static let heroButtonsBottom: CGFloat = 15

        // MARK: hero 背景层（钉住不随滚，见 `ArtistBackdropView` 类注释）

        /// [推] 清晰带的位置（占**图自然高**的比例，图按 fit-width 铺）：实机截图上
        /// 清楚的部分到图高的四成半，往下渐变进模糊，七成处已完全糊。
        /// 参考图目测，验收后按需要再收敛。
        static let backdropSharpFadeStart: CGFloat = 0.45
        static let backdropSharpFadeEnd: CGFloat = 0.72
        /// [推] 滚动时清晰图淡出的滚动距离：实机（告五人页）滚 ~230pt 后顶部已全糊，
        /// 240 是照两帧截图定的。
        static let backdropScrollFadeDistance: CGFloat = 240
        /// [推] 压暗层：模糊区顶端不压、页面底压到 0.55——栏目卡压在模糊图上要读得清，
        /// 实机滚到深处整页也就是这种「暗化的模糊图」的成色。
        static let backdropScrimBottom: CGFloat = 0.55

        // MARK: 「最新發行」卡（并排带的左半）

        /// [PX] 封面 162.5（左沿 236 = 内容列 203 + 34，右沿 398.5）。
        static let releaseArtwork: CGFloat = 162
        /// [PX] 封面右沿 398.5 → 文字左沿 413。
        static let releaseArtworkToText: CGFloat = 14.5
        /// [PX] 整块 236 → ~600，即 364 宽。
        static let releaseWidth: CGFloat = 364
        /// [PX] 「最新發行」右沿 600 → 「熱門歌曲」那一列的左沿 632，即两半之间 32。
        static let releaseToShelfGap: CGFloat = 32
        /// [PX] 发行日期 12pt 次要色、专辑名 16pt 主色最多两行、「N 首歌曲」13pt 次要色。
        static let releaseDateSize: CGFloat = 12
        static let releaseTitleSize: CGFloat = 16
        static let releaseCountSize: CGFloat = 13
        /// [PX] 三行之间各 4；末行下面 12 接那枚 ＋ 圆键（直径 28）。
        static let releaseLineSpacing: CGFloat = 4
        static let releaseTextToButton: CGFloat = 12
        static let releaseAddButtonSize: CGFloat = 28
    }

    // MARK: - 详情页头部

    enum Detail {
        /// 艺人等页沿用的方形封面（歌手页仍用它派生头像尺寸）
        static let artworkSize: CGFloat = 200
        /// [AX] Music 封面 frame 270×270（可见画面比 frame 略小，余量给阴影）。
        static let albumArtworkSize: CGFloat = 270
        /// [AX] 封面右沿 512.5 → 标题左沿 543.5。
        static let albumHeaderSpacing: CGFloat = 31
        /// [实测] `Music.AlbumHeaderLockup.setLayoutIsVertical:` / `setFrameSize:` 拿宽度和
        /// 实测的 **600.0** 比：窄于 600 时头部改成竖排——
        /// 封面在上、文字在下、整块居中。同一段里还有 250 / 750 / 1000 三个浮点常量，
        /// 是简介宽度一类的次级夹取，尚未对上具体用途。
        static let albumHeaderVerticalBreakpoint: CGFloat = 600
        /// 竖排时封面缩一档，否则 270 的封面会把首屏全占满
        static let albumArtworkSizeCompact: CGFloat = 200
        /// 竖排时封面与文字块的间距
        static let albumHeaderVerticalSpacing: CGFloat = 16
        /// [AX] 封面顶边与内容区顶边齐平。
        static let albumContentTop: CGFloat = 0
        /// [PX] 标题/艺人/信息行为紧贴的三行，行框之间不额外留白。
        static let albumHeaderTextSpacing: CGFloat = 0
        /// [PX] 标题字形顶 104.0 → 艺人字形顶 135.5（间距 31.5）。
        static let albumArtistTop: CGFloat = 1
        /// [AX] 内容区左沿 202.5 → 封面左沿 242.5。
        static let albumContentHorizontal: CGFloat = 40
        /// [PX] 标题字形顶 104.0（26pt 时反推文本框顶边）。
        static let albumTitleTop: CGFloat = 47.5
        /// [PX] 标题字形带 104.0–127.0（高 23.5、11 字宽 270.0）。
        /// 早前把 ★ 的字形带（101.0 起）算进了标题，才误判成 29pt。
        static let albumTitleSize: CGFloat = 26
        /// [PX] 艺人字形带 135.5–157.5（高 22.5）。
        static let albumArtistSize: CGFloat = 26
        /// 信息行字号。实测 Music 与 13pt 更接近（无损二字宽 25.0 对 24.5、
        /// Mandopop 宽 60.5 对 62.5），此处按要求再降一档到 12。
        static let albumMetaSize: CGFloat = 12
        /// [PX] 简介字距 13.0、行距 16.5，即 13pt。
        static let albumDescriptionSize: CGFloat = 13
        /// [PX] 简介末行右端的「更多」：Music 字形宽 21.5、高 10.5，反推约 11pt。
        static let albumMoreSize: CGFloat = 11
        /// [PX] 艺人字形顶 135.5 → 信息行字形顶 167.5（间距 32）。
        static let albumMetaTop: CGFloat = 5
        /// [PX] 信息行字形顶 167.5 → 简介首行字形顶 233.5（间距 66）。
        static let albumDescriptionTop: CGFloat = 50
        /// [PX] 折叠简介显示两行，“更多”压在末行右端。
        static let albumDescriptionLines: Int = 2
        /// [AX] 简介框底 265 → 按钮行顶 285。“更多”压在末行右端，不额外占高。
        static let albumActionsTop: CGFloat = 21
        /// [PX] Music 简介行距 16.5；13pt 系统字默认 15，补 1.5。
        static let albumDescriptionLineSpacing: CGFloat = 1.5
        /// [AX] 圆键 38×38、播放胶囊 132×38、相邻间距 10。
        static let albumActionSize: CGFloat = 38
        static let albumActionIconSize: CGFloat = 16
        static let albumPlayLabelSize: CGFloat = 15
        static let albumPlayWidth: CGFloat = 132
        static let albumActionSpacing: CGFloat = 10
        /// [AX] 按钮行底 323 → 首行音轨顶 342。
        static let albumTrackListTop: CGFloat = 19
        /// [PX] 标题字形右沿 815.5 → ★ 起点 824.5；★ 字形 22×21。
        static let albumFavoriteGap: CGFloat = 9
        static let albumFavoriteStarSize: CGFloat = 21
        /// [PX] ★ 字形带 101.0–122.0，比标题（104.0–127.0）高 3；
        /// 基线对齐会让它落到 105.5，需上提 4.5。
        static let albumFavoriteStarOffsetY: CGFloat = -4.5
        /// [PX] 信息行内「· 无损 ☆☆☆☆☆」的元素间距（年份 649 → 无损 662 → 星级 705）。
        static let albumMetaSpacing: CGFloat = 5
        /// [AX] 末行音轨底 894 → 版权信息框顶 923。
        static let albumFooterTop: CGFloat = 29
        /// [AX] 版权信息左沿 253.5，比封面左沿再缩进 11。
        static let albumFooterLeading: CGFloat = 11
        /// [AX] Apple Music 歌单封面实测 270×270（与专辑完全一致，可见画面略小，余量给阴影）。
        static let playlistArtworkSize: CGFloat = 270
        /// 歌单封面竖排折叠时的紧凑尺寸
        static let playlistArtworkSizeCompact: CGFloat = 200
        /// 歌单头部折叠为竖排的断点宽度
        static let playlistHeaderVerticalBreakpoint: CGFloat = 600
        /// [实测] macOS 27（26A5425a）基线，`playlists 规格` §2.1.1 实测的视图树：
        /// `docStack` 里每一段都用
        /// `addAndAlignSubview:topMargin:leadingMargin:bottomMargin:trailingMargin:` 包一层，
        /// 四参顺序是 **top / leading / bottom / trailing**。三段的实测值：
        /// - `headerMargins` = **0 / 40 / 30 / 40**
        /// - `footerMargins` = **0 / 40 / 0 / 40**
        /// - `suggestedMargins` = **20 / 40 / 20 / 40**
        ///
        /// 即整页左右统一 40，头部底下留 30、页脚上下贴死 0、建议歌曲货架上下各 20。
        /// 唯一例外是 `artistsShelf`（精选艺人货架）——它**故意没有这层边距包装**，
        /// `shelf.view` 直接当`AMPCollapsableView` 的唯一子视图。
        static let playlistContentHorizontal: CGFloat = 40
        static let playlistContentTop: CGFloat = 0
        /// [AX] 封面顶 85 → 歌单标题顶 136（下沉 51pt）
        static let playlistHeaderTopPadding: CGFloat = 51
        /// [AX] 头部底 355 → 表头顶 393（间距 38pt）
        ///
        /// 与 [实测] 交叉验证过：§2.1.1 的 `headerMargins` 底边距只有 **30**，
        /// 差的 8 落在 `Music.MusicTrackTableLockup` 自己内部（曲目表那件的上内边距）。
        /// 两个证据自洽——Amber 这条是「头部底 → 列头顶」的端到端距离，所以取 38 才对，
        /// 不能照 `headerMargins` 写成 30。
        static let playlistTableTopSpacing: CGFloat = 38
        /// [AX] 歌单页末行底 1825（`playlist-detail.json` 最后一条`AXRow` y=1769 h=56）
        /// → 页脚文字框顶 **1862**，间距 **37**。
        ///
        /// 同一把尺量专辑页：末行底 927（y=881 h=46）→ 版权行顶 956，得 29，
        /// 正是既有的 `albumFooterTop`——量法对得上，所以歌单页这 37 不是量错。
        /// 从前歌单页错用了通用的 `footerTop`（8）。
        ///
        /// [实测] §2.1.1 的 `footerMargins` 上边距是 **0**，
        /// 说明这 37 全在页脚那件 lockup 自己内部，不是 `docStack` 的容器边距——
        /// 两个证据不冲突，Amber 这条按端到端的 37 写。
        static let playlistFooterTop: CGFloat = 37
        /// [AX] 封面右沿 512.5 → 标题左沿 543.5（间距 31）
        static let playlistHeaderSpacing: CGFloat = 31
        static let playlistTitleSize: CGFloat = 26
        static let playlistCuratorSize: CGFloat = 18
        static let playlistMetaSize: CGFloat = 12
        static let playlistActionSize: CGFloat = 38
        static let playlistPlayWidth: CGFloat = 132
        /// [PX] 左上角内缩曲线在距顶 9.5pt 处收敛，对应连续圆角 10。
        static let artworkCornerRadius: CGFloat = 10
        /// 歌手圆形头像
        static let artistAvatarSize: CGFloat = 140
        /// 封面与文字块的间距
        static let headerSpacing: CGFloat = 20
        static let contentHorizontal: CGFloat = 34
        static let contentTop: CGFloat = 12
        static let metadataSpacing: CGFloat = 3
        static let actionSpacing: CGFloat = 8
        static let footerTop: CGFloat = 8
    }

    // MARK: - 操作按钮（播放/随机播放胶囊）

    enum ActionButton {
        /// [实测] `PlatPillButton.contentEdgeInsets` → 5 / 10（纵 5、横 10），
        /// `imageEdgeInsets` → 10。原先的 18/7 是没有对照的估值。
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 5
        static let cornerRadius: CGFloat = 8
        /// [实测] `PlatPillButton.imageEdgeInsets` → 10
        static let iconToText: CGFloat = 10
    }

    // MARK: - 全屏播放器（Music 的「播放中」整窗播放器）

    /// 结构照 `NowPlayingView` 的组件树复刻 [TYPE]：
    /// `MacContentView(contentWidthFraction:)` 定内容列宽 →
    /// `ArtworkContainerView` / `MetadataLabels`（eyebrow/title/subtitle）/
    /// `MacTimeControlView`（进度条 + 两端`MacTimeControlLabel` + 中间
    /// `TimeControlAccessoryView`）/ `TransportControlsView`（只有 leading/center/trailing
    /// **三颗**，随机与循环属于 `FooterButtons`）/ `HeaderLayoutView` + `FooterButtons`
    /// 两组玻璃胶囊；歌词等副内容走 `FullWindowHostedContentView`。
    ///
    /// 数值来自 2026-08-16 对 Music 1.7「播放中」窗口的实测
    /// （窗口 1440×923、深色、歌词开）：`Tools/ui-spec.swift Music --runtime --screenshot`
    /// 拿 AX frame，再对同一张截图逐像素量字形外框。
    enum NowPlaying {
        // MARK: 进出场

        /// 「播放中」是从窗口底部整块推上来、退出时整块落回去，不是淡入淡出。
        ///
        /// [AX] Music 上点「关闭播放中」到该视图离开 AX 树，三次实测 366 / 394 / 380ms，
        /// 所以整段过渡在 0.3–0.4s 量级，明显比原来那个 0.25s 淡入淡出慢。
        ///
        /// 曲线本身没量出来，两条路都堵死了：AX frame 不跟随动画过程（只在插入/移除时跳变），
        /// `CGWindowListCreateImage` 在这版 macOS 上已被移除、连拍取像素也走不通。
        /// 而且同一套探针量 Amber 自己得到的是近乎恒定的 160–200ms（SwiftUI 丢弃 overlay 子树的
        /// 时刻，与动画时长无关），两边不可比，别拿它反推参数。
        /// 下面这组是按「无可见回弹的推拉」取的，要调手感直接改这两个数。[推]
        static let transitionResponse: Double = 0.45
        static let transitionDamping: Double = 0.9

        // MARK: 内容列

        /// [AX] 内容列宽 = 窗口宽 × 0.28（1440 → 403）。
        /// 对应 `MacContentLayout.contentWidthFraction` [TYPE]。
        static let contentWidthFraction: CGFloat = 0.28
        /// [AX] 封面是正方形，边长 = 内容列宽（403×403.5，0.5 是取整误差）。
        /// 对应 `MacContentLayout.artworkAspectRatio` [TYPE]。
        static let artworkAspectRatio: CGFloat = 1
        /// 封面有播放 / 暂停两个尺寸，格子不变、只有画出来的那张缩放，
        /// 所以下面的曲名与传输键不会跟着上下动。
        /// [TYPE] `ArtworkContainerView.Layout(scale:)` + `__artworkScale`。
        /// [AX] 暂停态实测：格子 403×403.5，里面那张 294.5×294.75，同心，
        /// 294.5 / 403 = 0.7308。
        static let artworkPlayingScale: CGFloat = 1
        static let artworkPausedScale: CGFloat = 0.7308
        /// 窗口太矮时封面让位给下方控件，至少给整块留这么多上下留白。[推]
        static let minVerticalMargin: CGFloat = 24
        /// 未实测：封面在深色底上四角与背景同为近黑，像素扫不出边界。
        static let artworkCornerRadius: CGFloat = 10

        /// [PX] 整块（封面顶 182 … 传输键底 746.5）中心 464.25，窗口中心 461.5，
        /// 即比正中低 2.75pt。
        static let contentOffsetY: CGFloat = 2.75

        // MARK: 竖向堆叠（自封面往下）

        /// [AX] 封面底 585.5 → 元数据行顶 604.5
        static let artworkToMetadata: CGFloat = 19
        /// [AX] 元数据行 604.5…642：标题行 + 副标题行
        static let metadataHeight: CGFloat = 37.5
        /// [AX] 元数据行底 642 → 进度条命中区顶 659
        static let metadataToScrubber: CGFloat = 17
        /// [AX] 进度条命中区高（`AXSlider` 403×15）
        static let scrubberHitHeight: CGFloat = 15
        /// [PX] 可见轨道高 6，在命中区里居中
        static let scrubberBarHeight: CGFloat = 6
        /// [AX] 轨道底 674 → 时间行顶 675.85
        static let scrubberToTime: CGFloat = 1.85
        /// [AX] 时间行高
        static let timeRowHeight: CGFloat = 13
        /// [AX] 时间行底 688.85 → 传输键行顶 699
        static let timeToTransport: CGFloat = 10.15
        /// [AX] 传输键行高（上一首/下一首的 48×48 命中盒）
        static let transportRowHeight: CGFloat = 48

        // MARK: 字号与字形（[PX] 字形外框反解，见 Tools 里的符号标定脚本）

        /// [PX] 曲名字形高 15.5 → 17pt；`NowPlayingMetadataViewSpecs.FullScreen.Fonts.title` [TYPE]
        static let titleSize: CGFloat = 17
        /// [PX] 副标题 15pt；`…Fonts.subtitle` [TYPE]
        static let subtitleSize: CGFloat = 15
        /// [AX] 心水/更多两颗圆按钮 26×26，间距 8，右沿与内容列右沿齐平
        static let metadataAccessorySize: CGFloat = 26
        static let metadataAccessorySpacing: CGFloat = 8
        /// [PX] star 字形 14.25×13.25 → 13pt。心水与更多两颗都是**纯白**，
        /// 不跟副标题那档 0.55（glyph-diff 实测参考侧白度 1.00）。
        static let favoriteIconSize: CGFloat = 13
        static let metadataAccessoryOpacity: CGFloat = 1
        /// [PX] ellipsis 字形 15×3 → 16.5pt
        static let moreIconSize: CGFloat = 16.5
        /// [PX] 时间标签数字高 7.25 → 10pt
        static let timeSize: CGFloat = 10
        /// [PX] 「无损」徽标与时间同档
        static let badgeSize: CGFloat = 10

        /// [PX] shuffle 字形 19.25×15.25 → 17pt
        static let shuffleIconSize: CGFloat = 17
        /// [PX] repeat 字形 18×15.25 → 与 shuffle 同档（`edgeButtonFont` 按图标给字号 [TYPE]）
        static let repeatIconSize: CGFloat = 17
        /// [PX] backward.fill / forward.fill 字形 32.5×19 → 24.5pt
        static let skipIconSize: CGFloat = 24.5
        /// [PX] play.fill 字形 24×27 → 33pt
        static let playIconSize: CGFloat = 33
        /// [AX] 上一首/下一首字形中心离内容列中心 ±86
        static let skipOffsetFromCenter: CGFloat = 86
        /// [AX] 随机/循环 30×30 命中盒，贴内容列左右沿
        static let edgeButtonSize: CGFloat = 30

        // MARK: 前景不透明度（[PX] (峰值-底色)/(255-底色)）

        /// 曲名是纯白，不是 systemPrimary 的 85%
        static let titleOpacity: CGFloat = 1
        static let subtitleOpacity: CGFloat = 0.55
        /// 时间标签与徽标比 secondary 还暗一档
        static let timeOpacity: CGFloat = 0.30
        /// 随机/循环关闭态
        static let edgeButtonOpacity: CGFloat = 0.55
        /// 上一首/下一首
        static let skipOpacity: CGFloat = 0.725
        /// 播放/暂停
        static let playOpacity: CGFloat = 0.85

        // MARK: 顶部两组玻璃胶囊

        /// [PX] 三组胶囊高度一致，全圆角
        static let capsuleHeight: CGFloat = 36
        /// [PX] 左上胶囊 x 100.6…176.1（让开红绿灯），两颗键
        static let headerLeadingInset: CGFloat = 100.5
        static let headerTop: CGFloat = 8
        static let headerLeadingWidth: CGFloat = 76
        /// [PX] xmark 字形 13×13 → 16.5pt
        static let closeIconSize: CGFloat = 16.5
        /// [PX] pip.enter 字形 21.5×17.5 → 17pt
        static let miniPlayerIconSize: CGFloat = 17
        /// [PX] 右上胶囊 x 1214.6…1431.9（宽 217），距窗口右沿 8
        static let headerTrailingInset: CGFloat = 8
        static let headerTrailingWidth: CGFloat = 217
        /// [PX] AirPlay 占胶囊左端 40 宽的槽（字形中心离胶囊左沿 20.4）
        static let airPlaySlotWidth: CGFloat = 40
        /// [PX] AirPlay 与音量条之间的 1pt 竖分隔线，落在胶囊内 42.4
        /// （`NowPlayingView.VolumeControlLayoutAdjustment.PlatterDivider` [TYPE]）
        static let volumeDividerWidth: CGFloat = 1
        static let volumeDividerHeight: CGFloat = 18
        /// [PX] 分隔线到轨道左沿（轨道 52.15…166.15）
        static let dividerToVolumeTrack: CGFloat = 11.15
        /// [PX] 轨道右沿到喇叭槽左沿
        static let volumeTrackToSpeaker: CGFloat = 6.25
        /// [PX] 喇叭槽 36 宽，字形中心离胶囊左沿 190.4
        static let speakerSlotWidth: CGFloat = 36
        /// [PX] 喇叭槽右沿到胶囊右沿
        static let speakerTrailingInset: CGFloat = 8.6
        /// [PX] 音量轨道 114×6，滑块是 24×13 的胶囊（不是圆点）
        static let volumeTrackWidth: CGFloat = 114
        static let volumeKnobWidth: CGFloat = 24
        static let volumeKnobHeight: CGFloat = 13
        /// [PX] speaker.wave.2.fill 字形 18×14 → 16.5pt。
        /// 同一条胶囊里只有这颗不是纯白：关闭/迷你播放器/AirPlay 都是 1.00，喇叭 0.85。
        static let volumeIconSize: CGFloat = 16.5
        static let volumeIconOpacity: CGFloat = 0.85

        // MARK: 底部玻璃胶囊（`FooterButtons`）

        /// [PX] 每颗键占 36 宽的槽，两颗 → 72
        static let footerButtonSlot: CGFloat = 36
        /// [PX] 距窗口右沿 10、底 11.5
        static let footerTrailingInset: CGFloat = 10
        /// 两个玻璃组之间的空隙。[TYPE] 底栏按钮是按
        /// `FooterLayoutGlassGroup(ids:)` 分组的，一组一颗玻璃；翻译键自成一组，
        /// 所以它与歌词/待播那颗胶囊之间有一道缝。
        /// [PX] 按 Music 截图折算（胶囊高 36 为尺），缝约 6。
        static let footerGlassGroupSpacing: CGFloat = 6
        static let footerBottomInset: CGFloat = 11.5
        /// [PX] 开启态是 30 直径的浅色圆片，图标反相
        static let footerActiveCircle: CGFloat = 30
        /// [PX] 圆片 (210,210,209) 压在玻璃 (46,45,40) 上 → 白 0.78
        static let footerActiveCircleOpacity: CGFloat = 0.78
        /// [PX] quote.bubble.fill 16pt、list.bullet 15pt；关闭态是**纯白**
        static let lyricsIconSize: CGFloat = 16
        static let queueIconSize: CGFloat = 15.5
        static let footerIconOpacity: CGFloat = 1
        /// 反应键（`EmojiReactionPicker` [TYPE]）另起一组，放左下
        static let reactionIconSize: CGFloat = 15

        // MARK: 歌词（`FullWindowHostedContentView`）

        /// [AX] 歌词面板顶 88、距窗口右沿 52、底部给底栏留 64
        static let hostedContentTop: CGFloat = 88
        static let hostedContentTrailing: CGFloat = 52
        static let hostedContentBottom: CGFloat = 64
        /// [AX] 面板宽 668、歌词文字 630 → 左右各内缩 19
        static let hostedContentInset: CGFloat = 19

        // MARK: 背景（`NowPlayingViewModel.Backdrop`）

        /// [PX] 背景不是纯色，也不是「原图大模糊」——Music 那片场压得很平：
        /// 非内容区亮度中位数 31.5、p95 45.2、最大 54.5，
        /// RGB 落在 (23,23,22)…(107,83,36) 之间。
        /// 复刻法：封面降成 12×12 方块均值 → 每块的 HSB 夹进下面这两个区间 →
        /// 拉伸铺满再模糊。见 `NSImage.amberBackdropField`。
        static let backdropGrid = 12
        /// [PX] 亮度 0.09…0.42（= 23/255 … 107/255）
        static let backdropBrightness: ClosedRange<CGFloat> = 0.09...0.42
        /// [PX] 最亮处 (107,83,36) 的饱和度
        static let backdropMaxSaturation: CGFloat = 0.66
        /// [PX] 最亮处 (107,83,36) 的相对亮度 = 83/255。无彩色方块靠 HSB 亮度夹不住，
        /// 要再按相对亮度压一次，白底封面才不会把背景洗成浅灰。
        static let backdropMaxLuminance: CGFloat = 83.0 / 255
        /// 方块均值拉伸后本身就很软，模糊只是抹掉插值留下的棱
        static let backdropBlur: CGFloat = 60

        /// [实测] §2.1：纱罩浓度与律动速度**都是内容视图宽度的
        /// 分段线性函数**——400pt 以下恒 0.7 / 10.5，800pt 以上恒 0.3 / 1.5。
        ///
        /// ```
        /// p = clamp((w − 400) / 400, 0, 1)    // −400 与 ÷400 是两条 fmov 立即数
        /// scrimAlpha        = 0.7 + (−0.4)×p  // 0.7 → 0.3，越宽越透
        /// animationInterval = 10.5 + (−9)×p   // 10.5 → 1.5，越宽律动越快
        /// ```
        ///
        /// **翻案**（规格笔记批次 33）：上一版按「窗口内容高度、偏移 ε≈0.011」写，
        /// 两处都错——自变量是宽度，那条 mov 是负立即数 −400。
        /// `setTotalWindowContentHeight:` 那条路只发 KVO 通知与改抽屉高，**不动纱罩**；
        /// 纱罩挂在 `setFrameSize:` 真身尾段，无条件执行（原先记的「KVO 闸挡住每帧重算」
        /// 同样不成立）。整窗尺寸下宽度远大于 800，所以 p 照旧恒为 1。
        static func backdropProgress(contentWidth: CGFloat) -> CGFloat {
            min(max((contentWidth - 400) / 400, 0), 1)
        }

        static func backdropScrimAlpha(contentWidth: CGFloat) -> CGFloat {
            0.7 - 0.4 * backdropProgress(contentWidth: contentWidth)
        }

        static func backdropAnimationInterval(contentWidth: CGFloat) -> TimeInterval {
            10.5 - 9 * backdropProgress(contentWidth: contentWidth)
        }

        /// 上面那片色域（`backdropBrightness` 一带）是在整窗尺寸下采的，
        /// 即 p = 1、纱罩已经是 0.3 的那一档——**采到的像素里已经含这 0.3**。
        /// 所以视图层只补「比基线更浓的那一部分」；窗宽 ≥ 800 时补 0。
        static let backdropCalibratedScrim: CGFloat = 0.3

        // MARK: 抽屉（歌词 / 待播清单）

        /// [实测] §2.2 `MPContentView.setDrawerHeight:`（段）常量 **200**：
        /// 抽屉有 200 的下限语义。
        static let drawerMinHeight: CGFloat = 200

        // MARK: 待播清单盘（trackSectionsPlatter）

        /// [实测] §6.5 在 NowPlayingView 的 Swift 函数区里直读到的布局常量：
        /// **16 / 8 / 4 / −16 / 0.5 / 1.0**（间距与插值基），
        /// 动画名 `trackSectionsPlatter.expanded` / `.collapsed`，
        /// 另有专用视图标识 `NowPlayingView.TrackSectionsScrollableContentFade`
        /// （音轨列表滚动内容渐隐）。
        static let platterPadding: CGFloat = 16
        static let platterRowSpacing: CGFloat = 8
        static let platterCornerRadius: CGFloat = 16
        static let platterInnerSpacing: CGFloat = 4
        /// 滚动内容渐隐带占盘高的比例（`TrackSectionsScrollableContentFade`，比例未回收）[推]
        static let platterFadeFraction: CGFloat = 0.06

        // MARK: 动态封面视差（NowPlayingArtworkMotionReplicatorLayer）

    }

    // MARK: - 歌词滚动

    /// Music 的同步歌词不是一个字号走到底，而是按歌词栏可用宽度分档。
    ///
    /// - `[实测]` `TSLLyricsControllerWrapper.breakpointForWidth:` 回收出 4 个断点：
    ///   **300 / 528 / 672 / 760**
    /// - `[资源]` `TextStyles.plist` 给出每一档的字号：
    ///   | id | 用途 | 字号 | 字重 |
    ///   | ---: | --- | ---: | --- |
    ///   | 10200 | Timed Lyrics (Sidebar) | 24 | Bold |
    ///   | 10201–10204 | Fullscreen 歌词行 small/medium/large/x-large | 28 / 38 / 50 / 72 | Bold |
    ///   | 10205–10208 | Fullscreen 副行同上四档 | 13 / 17 / 20 / 24 | Bold |
    ///   | 10209–10212 | Fullscreen 次级副行同上四档 | 13 / 17 / 20 / 24 | Medium |
    ///
    /// Amber 把「翻译行」对到副行那一档（Music 那一行放的是曲名/歌手，位置与角色相同）。
    /// - Note: 同步歌词的**行为与外观参数**不在这里，在 `Amber/Lyrics/LyricsSpecs.swift`
    ///   ——那是原版 79 个字段的逐字复刻，每条都带实测出处，
    ///   比这边早先那份 `Sync` 摘抄硬得多。这里只留宽度断点与字号档位。
    enum Lyrics {
        /// 歌词列最大宽度。[推] 由断点上限反推：最大的一档从 760 起，
        /// 列宽若还夹在 460 就永远只能落到 small，四档等于白设。
        static let maxWidth: CGFloat = 760

        /// [实测] 宽度断点
        static let breakpoints: [CGFloat] = [300, 528, 672, 760]

        enum SizeClass: CaseIterable {
            /// 窄于 300：Music 的侧栏歌词样式
            case sidebar
            case small, medium, large, xLarge

            /// [资源] 10200 / 10201–10204
            var lineSize: CGFloat {
                switch self {
                case .sidebar: return 24
                case .small:   return 28
                case .medium:  return 38
                case .large:   return 50
                case .xLarge:  return 72
                }
            }

            /// [资源] 10205–10208（副行）。侧栏档没有对应条目，取最小的一档。
            var secondarySize: CGFloat {
                switch self {
                case .sidebar, .small: return 13
                case .medium:          return 17
                case .large:           return 20
                case .xLarge:          return 24
                }
            }

            /// [PX] 2026-08-16 实测（歌词栏 630 宽 → medium 档 38pt）：
            /// 相邻两行**顶距** 95 = 2.5 倍字号。
            var linePitch: CGFloat { lineSize * 2.5 }

            /// 尾部创作者（「创作者：A、B」）。比正文小一大截，不跟正文抢视线。[推]
            var creditsSize: CGFloat { max(secondarySize, (lineSize * 0.42).rounded()) }

            /// 间奏三个**点**相对 `LyricsSpecs` 基线（点 12 / 间距 8）的放大倍率。
            ///
            /// [AX+PX] 2026-09-03 同窗口读 Music 的 50pt 档：点直径 21、中心间距 34
            /// （= 点 21 + 间距 13）、间奏行高 42。也就是**点跟着字号放大（×1.75），
            /// 行高几乎不动**（基线 40 → 42）——所以这个系数只给点和点间距用，
            /// 不要拿去缩放 `instrumentalBreakViewHeight`，否则轮到间奏时会撑开
            /// 一大块，看着像「弹出来」。
            ///
            /// 取 `/28` 而不是`/26`：50pt 档给 21.4 / 14.3，最贴实测的 21 / 13；
            /// 且最小的整窗档（28pt）正好回到 ASM 基线 12 / 8。
            ///
            /// 侧栏档不缩：`LyricsSpecs` 的 12 / 8 实测得到的就是侧栏那一档，
            /// 再乘 24/28 等于把基线又缩一次。[AX] 侧栏间奏行高 40（`lyrics-panel.json`
            /// 的 `乐器间奏` 按钮 218×40）也正是基线的 `instrumentalBreakViewHeight`。
            var interludeScale: CGFloat { self == .sidebar ? 1 : lineSize / 28 }

            /// 行距（「顶距 − 行盒」）。**不随字号缩放**，是个常量：
            ///
            /// - [PX] 38pt 档实测顶距 95、行盒 45.1 → 行距 49.9
            /// - [AX] 2026-09-03 同窗口（1470×923）读 Music 整窗歌词的 50pt 档：
            ///   单行行盒 61、相邻行顶距 109 → 行距 48
            ///
            /// 早先只有 38pt 那一个点，被写成了 `linePitch − 1.19×字号`（= 1.31×字号），
            /// 在 38 档恰好对上、换到 50 档就给到 65.5，行会散开一大截。
            /// 侧栏档另有实测基线 `LyricsSpecs.lineSpacing = 25`。
            var lineSpacing: CGFloat { self == .sidebar ? 25 : 48 }
        }

        /// 右下角那颗翻译浮动键。
        ///
        /// [AX] `lyrics-panel.json`（窗口`[0, 33, 1470, 923]`）：
        /// `AXButton 翻译 [1421, 915, 34, 26]`——右沿 1455 距面板右 1470 是 **15**，
        /// 底 941 距窗底 956 也是 **15**。它是窗口的直接子件，不在歌词组里面，
        /// 所以是「浮在歌词上」而不是跟着滚。
        ///
        /// [PX] 同图取色：面板底 #373737（0.218）、键内 #545454（0.332）匀色无渐变，
        /// 折算成白色叠加约 **14.6%**——就是 `amberGlass(clear:)` 那一档的量级。
        enum TranslationButton {
            static let size = CGSize(width: 34, height: 26)
            static let inset: CGFloat = 15
            /// [PX] 从同图量的圆角，约 8pt（26 高的小胶囊，接近 squircle）。
            static let cornerRadius: CGFloat = 8
            /// [PX] 图标墨迹高约 16.7pt（键内上下各留 ~4.7），SF Symbol `translate` 取 14pt。
            static let iconSize: CGFloat = 14
        }

        /// [实测] 落在哪一档由歌词栏的可用宽度决定
        static func sizeClass(forWidth width: CGFloat) -> SizeClass {
            if width < breakpoints[0] { return .sidebar }
            if width < breakpoints[1] { return .small }
            if width < breakpoints[2] { return .medium }
            if width < breakpoints[3] { return .large }
            return .xLarge
        }
    }

    // MARK: - 目录页（主页 / 新发现 / 广播）

    /// 「主页 / 新发现 / 广播」在 Music 里共用一套目录页引擎（`catalogpage 规格`：
    /// 三个页面在 CatalogPagePresenter 这层没有分叉，内容是服务端下发的分段列表；
    /// 货架排布方式也是下发字段，见 `lockup 规格` §0）。这里收 Music 1.7 三页的
    /// 实测排版常量，参照 design-ref/ui-spec/pages/{home,new,radio}.{json,png}。
    ///
    /// 截图坐标修正：三张 png 相对 AX 有 +35.5pt 横向、+4.3pt 纵向的整体偏移
    /// （用页面标题、段标题、卡片标题三处独立对上同一个偏移验证），下文 [PX] 均已折算。
    enum Catalog {
        /// [AX] 内容左沿 202.5 → 标题/段标题/卡片 236.5。
        /// 这是 ≥740 档的值；窄档是 20，随宽度取值见 `Shelf.margin(containerWidth:)`。
        static let leadingMargin: CGFloat = 34
        /// [AX] 货架相邻卡片 pitch 266−246 / 199.7−179.5 / 399.3−379.3。
        /// 这是 ≥1000 档的值；窄档 12 / 中档 16，随宽度取值见 `Shelf.gutter(containerWidth:)`。
        static let shelfGap: CGFloat = 20

        /// 货架的动态网格：**卡宽跟着内容列宽走**，与资料库网格（`LibraryGrid`）同一条路子。
        ///
        /// 出处：2026-09-08 对 Music 1.7 主页/新发现/广播实扫（窗口 900…1470 逐 20 拉宽，
        /// 每档读 AX 的卡 frame）。三条结论：
        ///
        /// 1. **档位断点落在内容列宽上，不是窗口宽**——同为 1470 窗口，内容列 1012 与
        ///    1267.5（`design-ref/ui-spec/pages/home.json`，无右侧面板）落在不同档。
        /// 2. 每档的左内缩、卡间距、以及算卡宽时让出的总余量都换一组数（见下表）。
        /// 3. **列数可以是小数**——小数部分就是右沿露出的那半张卡。实扫窄档 hero 1.5 列、
        ///    海报 2.25 列，代进公式与实测逐点吻合（误差 <0.3）。
        ///
        /// 公式与 `LibraryGrid.itemWidth` 同形，只是让出的余量左右不等：
        ///
        ///     卡宽 = (内容列宽 − reserve − (列数 − 1) × gutter) / 列数
        ///
        /// 复核（内容列 1267.5，即 home.json 那一态）：方卡 6 列 → 179.58（[AX] 179.5）、
        /// 海报 4.5 列 → 246.1（246）、hero 3 列 → 379.17（379）、曲目列 3 列 → 379.17（379）。
        enum Shelf {
            /// 卡型分组：同一组共用一张列数表。
            enum Family {
                /// 海报卡（powerswoosh）
                case poster
                /// 方卡 / 电台方卡 / 视频卡（三者实扫同宽）
                case square
                /// hero（editorial-card）
                case hero
                /// 节目宽卡（horizontal-lockup）
                case episode
                /// 多列曲目
                case track

                /// 各档列数。索引与 `breakpoints` 对齐：0 = <740，1 = ≥740，2 = ≥1000，
                /// 3 = ≥1260，4 = ≥1580 [推]，5 = ≥1940 [推]。
                /// 0…2 档 [AX] 实扫，3 档 [AX] home.json 反解，4/5 档本机 1470 屏够不到，
                /// 按「每档加一列」外推 [推]。
                var columns: [CGFloat] {
                    switch self {
                    case .poster: return [2.25, 3, 4, 4.5, 5.5, 6.5]
                    case .square: return [3, 4, 5, 6, 7, 8]
                    case .hero, .episode, .track: return [1.5, 2, 3, 3, 4, 5]
                    }
                }

                /// [AX] 节目宽卡在三档实扫里都比同列数的 hero 宽整整 2
                /// （367.5/382/296 对 365.5/380/294），差值不随宽度变，按常量补。
                var widthAdjust: CGFloat { self == .episode ? 2 : 0 }
            }

            /// [AX] 实扫定位到的两个断点：内容列 722 还是 20/12 档、742 已是 34/16 档；
            /// 962 还是 16 档、982 已是 20 档 —— 740 与 1000 与 [实测] `AMPDynamicGridMetrics`
            /// 的档位同址。1260 由 home.json（内容列 1267.5：方卡 6 列、海报 4.5 列，
            /// 而实扫 1012 是 5/4 列）坐实在 (1012, 1267.5] 之间，取 web 断点表的 1260。
            /// 1580 / 1940 同取 web 断点表 [推]（本机 1470 屏的内容列到不了）。
            static let breakpoints: [CGFloat] = [740, 1000, 1260, 1580, 1940]

            /// [AX] 内容列左内缩：窄档 20，其余 34。
            static let margins: [CGFloat] = [20, 34, 34, 34, 34, 34]
            /// [AX] 卡间距：12 / 16 / 20（≥1000 起不再变，1267.5 那一态也是 20）。
            static let gutters: [CGFloat] = [12, 16, 20, 20, 20, 20]
            /// [AX] 算卡宽时让出的总余量（左内缩 + 右侧余量）：68 / 86 / 90。
            /// 右侧那半边（48 / 52 / 56）比左内缩大——货架右沿留着给下一张卡露头，
            /// 不是段的 `contentInsets`（段左右仍各`margin`，卡贴着内容列边缘被裁）。
            static let reserves: [CGFloat] = [68, 86, 90, 90, 90, 90]

            static func tier(forWidth width: CGFloat) -> Int {
                breakpoints.reduce(0) { $0 + (width >= $1 ? 1 : 0) }
            }

            static func margin(containerWidth: CGFloat) -> CGFloat {
                margins[tier(forWidth: containerWidth)]
            }

            static func gutter(containerWidth: CGFloat) -> CGFloat {
                gutters[tier(forWidth: containerWidth)]
            }

            /// 铺满内容列的段（大横幅、链接组、热门结果）能用的净宽。
            static func innerWidth(containerWidth: CGFloat) -> CGFloat {
                max(0, containerWidth - margin(containerWidth: containerWidth) * 2)
            }

            static func cardWidth(_ family: Family, containerWidth: CGFloat) -> CGFloat {
                let index = tier(forWidth: containerWidth)
                let columns = family.columns[index]
                let usable = containerWidth - reserves[index] - (columns - 1) * gutters[index]
                // 宽还没定（上屏前 bounds 是 0）时别交出 0：0 宽的槽会让组合布局
                // 把整段算崩（资料库网格那次实测是几秒吃掉几十 GB）。
                return max(1, usable / columns)
            }
        }
        /// [PX] 页面大标题「首頁」字形带高 27.9 → ~32pt bold
        static let titleSize: CGFloat = 32
        /// [AX] 标题字形底 123 → 首段标题顶 146（主页）
        static let titleToHeading: CGFloat = 23
        /// [推] 标题到首段无标题内容：探新 hero 卡顶 143 − 标题底 123 = 20
        static let titleToContent: CGFloat = 20
        /// [AX] 上一段卡底 → 下一段标题顶：主页 506→531.15、探新 455→480、732→757、广播 334.5→360
        static let sectionSpacing: CGFloat = 25
        /// [AX] 段标题底 165 → 卡顶 178
        static let headingToContent: CGFloat = 13
        /// [AX] 段标题 AX 带 19 高 → 15pt semibold（与 SectionHeader 同源）
        static let headingSize: CGFloat = 15

        /// 段标题的「种子头」（主页「更多类似作品 + 种子名」那种）：
        /// [WEB] 40 缩略图 + 右侧两行（headline 15/400 次要色、标题 17/700），
        /// 折到 App 的 15pt 段标题上：缩略图 36、headline 13。
        static let seedThumbSize: CGFloat = 36
        static let seedHeadlineSize: CGFloat = 13
        static let seedGap: CGFloat = 12

        /// 海报卡（主页「专属精选推荐」/「为你制作的歌单」，Apple 内部叫 powerswoosh）
        /// [AX] 246×328 = 3:4，[WEB] 圆角 10、文字压在图底的 chin 上。
        /// 宽随内容列走（`Shelf.cardWidth(.poster,…)`），这两个数是内容列 1267.5 那一态的
        /// 验收值；高恒等于宽 × 4/3（实扫 900…1470 各档比值都是 1.3333）。
        static let posterWidth: CGFloat = 246
        static let posterHeight: CGFloat = 328
        static let posterAspect: CGFloat = 4.0 / 3.0
        static let posterCornerRadius: CGFloat = 10
        /// [WEB] chin 左右内缩 16（31−15），末行字形底距图底 15
        static let posterTextInset: CGFloat = 16
        static let posterBottomInset: CGFloat = 15
        /// [WEB] eyebrow 11/600 纯白、标题 13/600 纯白（`powerswoosh__title` clamp 3 行）、
        /// 第三行（`__description` / `__subtitle`）11/400 纯白（clamp 2 行）——
        /// 第三行 2026-09-03 在 music.apple.com/cn/home 复测是 11 不是 13。
        static let posterEyebrowSize: CGFloat = 11
        static let posterTitleSize: CGFloat = 13
        static let posterDescSize: CGFloat = 11
        /// [WEB] chin 两行 46 / 三行 62（图高 338），折到 328：45 / 60
        static let posterChinTwoLine: CGFloat = 45
        static let posterChinThreeLine: CGFloat = 60

        /// 方卡（product-lockup）[AX] 图 179.5 + 文字块 37（216.5−179.5）
        /// [WEB] 标题 12/400 主色(0.92)、副标题 12/400 次要色(0.64)，图底 +4 起第一行、行距 16
        static let squareWidth: CGFloat = 179.5
        static let squareTextHeight: CGFloat = 37
        static let squareTextTop: CGFloat = 4
        static let squareTextSize: CGFloat = 13

        /// hero 卡（探新首段 / 广播首段，Apple 内部叫 editorial-card）
        /// [AX] 379×312；[WEB] 文字**在图上方**三行：
        /// eyebrow 11/600 次要色、标题 17/400 主色、副标题 17/400 次要色；图圆角 10；
        /// 描述 12/400 纯白压在图内左下角（内缩 16、距底 16）。折到 App：标题/副标题 15。
        ///
        /// [PX] 文字带 **60**、图 **252**（60+252 = [AX] 的 312）：在 new.png 上逐行数墨迹，
        /// eyebrow 2.5→11.5、标题 16.5→30.5、副标题 35.5→50.5，图顶整整落在 60，图铺到卡底。
        /// 三行字排在这 60 里，末行与图之间余出的空白就是那道呼吸（Music 是 9.5）。
        /// 旧值 49+235=284 比 [AX] 少 28 —— 字带不够高，中文的第三行会压到图上。
        ///
        /// 宽随内容列走（`Shelf.cardWidth(.hero,…)`）：文字带 60 不随宽变（实扫三档
        /// 卡高 − 图高都是 60±1），图高按 252/379 这个比例跟着宽走。
        static let heroWidth: CGFloat = 379
        static let heroTextHeight: CGFloat = 60
        static let heroArtworkHeight: CGFloat = 252
        static let heroArtworkRatio: CGFloat = 252.0 / 379.0
        static let heroCornerRadius: CGFloat = 10
        static let heroEyebrowSize: CGFloat = 11
        static let heroTitleSize: CGFloat = 15
        static let heroDescSize: CGFloat = 12
        static let heroDescInset: CGFloat = 16

        /// 大横幅（主页「推荐歌单」，Apple 内部叫 super-hero-lockup）：整宽一张图，
        /// **一句描述居中压在图底**，段里只有一张卡。
        /// [WEB] 圆角 14；描述 15/400 纯白（--title-3-tall）、宽 60%、居中、距图底 21；
        /// 可读性渐变高 175（透明 → 黑 0.4）；悬停时整图罩 rgba(51,51,51,.3)，
        /// 播放键在左下角内缩 10。[推] 图网页量到 1074×460，App 端没采到 AX，
        /// 宽度跟着内容列走、高按这个比例折算。
        static let bannerAspect: CGFloat = 1074.0 / 460.0
        static let bannerCornerRadius: CGFloat = 14
        static let bannerDescSize: CGFloat = 15
        static let bannerDescWidthRatio: CGFloat = 0.6
        static let bannerDescBottomInset: CGFloat = 21
        static let bannerScrimHeight: CGFloat = 175
        static let bannerHoverScrim: CGFloat = 0.3
        static let bannerControlInset: CGFloat = 10

        /// 电台方卡。Apple 的台标图自带台名，Amber 的封面没有，用白字压图复刻上半，
        /// 下半跟普通方卡一样两行。[WEB] 台名 17/700 白字。
        static let stationNameSize: CGFloat = 17
        static let stationCornerRadius: CGFloat = 6

        /// 链接组（新发现「探索更多」，网页组件叫 `link-box`）：三列网格、**列优先**填
        /// （实测 7 条排成 3 列 × 3 行，第一列装前三条）。
        /// [WEB] 格子高 58、圆角 10、底色白 0.05、左右内缩 16；文字 15/400 用主题色，
        /// 右端一个 6×10 的 ›；列间距 20、行间距 24（行距 82 − 格高 58）。
        static let linkColumns = 3
        static let linkHeight: CGFloat = 58
        static let linkCornerRadius: CGFloat = 10
        static let linkTextInset: CGFloat = 16
        static let linkTextSize: CGFloat = 15
        static let linkColumnGap: CGFloat = 20
        static let linkRowGap: CGFloat = 24

        /// 视频卡（新发现「观看艺人分享」，网页组件叫 `vertical-video`）：16:9 图 + 图下两行。
        /// [WEB] 图 253.5×142.6（圆角 7）、标题 12/400 主色（clamp 2 行）、
        /// 第二行是艺人名（访谈那种没有艺人的写时长）12/400 次要色。
        /// [AX] 2026-09-08 实扫广播页「觀看精彩訪談」：**卡宽与方卡完全相同**
        /// （176.5 / 182 / 168.5 逐档一致），图是严格 16:9，图下文字块 35（不是方卡的 37）。
        /// 卡高 134.38 / 137.38 / 129.72 = 宽×9/16 + 35，三档都对得上。
        /// 旧值 228.5×128.5 是没实测时按网页折算的 [推]，现按实扫改成随宽度算。
        static let videoAspect: CGFloat = 9.0 / 16.0
        static let videoTextHeight: CGFloat = 35
        static let videoWidth: CGFloat = 228.5
        static let videoHeight: CGFloat = 128.5

        /// 节目宽卡（horizontal-lockup）[AX] 381×118；[WEB] 图圆角 5、标题 15/400 垂直居中
        static let episodeWidth: CGFloat = 381
        static let episodeHeight: CGFloat = 118
        /// [PX] 卡内方图 94.3（=118−2×12），贴卡左沿
        static let episodeArtworkSize: CGFloat = 94
        static let episodeCornerRadius: CGFloat = 5
        static let episodeTitleSize: CGFloat = 15

        /// 多列曲目行（探新「必聽新歌」）[AX] 列宽 379、行高 56（pitch 56，行紧贴）
        static let trackColumnWidth: CGFloat = 379
        static let trackRowHeight: CGFloat = 56
        /// [PX] 行分隔线从文字列起（图 40 + 间距 12）
        static let trackDividerLeading: CGFloat = 52

        /// 热门搜索结果的横卡（Music 的 `TopSearchLockupComponentItem`，
        /// `search-musicui 规格` §2：`TopSearchGridLayoutConfiguration` 排 4 列 × 278×77）。
        /// 这一组数**照 Amber 旧版 SwiftUI 的 `TopResultsCardGrid` / `TopResultsCard` 原样搬**
        /// （`TopSearchLockupView.swift`，迁移「像素一个不改」）：网格是自适应列
        /// （[实测] 断点 740/1000/1320/1680 的列数阶梯，旧版用 `GridItem(.adaptive(minimum: 250),
        /// spacing: 22)` + 行距 20 等价实现，1175 内容宽落在 4 列档），
        /// 卡高 76、圆角 10、底色 `labelColor` 7%。
        static let topResultMinWidth: CGFloat = 250
        static let topResultColumnGap: CGFloat = 22
        static let topResultRowGap: CGFloat = 20
        static let topResultHeight: CGFloat = 76
        static let topResultCornerRadius: CGFloat = 10
        static let topResultBackgroundAlpha: CGFloat = 0.07
        /// 卡内（旧版 `TopResultsCard`）：`HStack(spacing: 12)` + 左右内缩 12，
        /// 封面 44（艺人切圆、歌曲圆角 4），右侧两行 13/600 主色与 11/400 次要色（行距 3），
        /// 尾标 11/500 次要色（艺人 chevron、歌曲 ellipsis）。
        static let topResultArtworkSize: CGFloat = 44
        static let topResultArtworkCornerRadius: CGFloat = 4
        static let topResultInset: CGFloat = 12
        static let topResultGap: CGFloat = 12
        static let topResultTitleSize: CGFloat = 13
        static let topResultSubtitleSize: CGFloat = 11
        static let topResultLineGap: CGFloat = 3
        static let topResultIconSize: CGFloat = 11

        /// `LazyVGrid(.adaptive(minimum: 250), spacing: 22)` 的列数：内容列宽里塞得下几列
        /// 就几列（至少一列），余下的宽由各列平分。与落地页砖块网格同一条算法。
        static func topResultColumns(forWidth width: CGFloat) -> Int {
            max(1, Int((width + topResultColumnGap) / (topResultMinWidth + topResultColumnGap)))
        }

        /// MV 缩略图右下角的时长角标（旧版 `MVCard`）：10/500 白字，
        /// 左右内缩 5、上下 2，底色黑 0.65、圆角 3，距图边 6。
        static let videoBadgeTextSize: CGFloat = 10
        static let videoBadgeHPadding: CGFloat = 5
        static let videoBadgeVPadding: CGFloat = 2
        static let videoBadgeCornerRadius: CGFloat = 3
        static let videoBadgeInset: CGFloat = 6
        static let videoBadgeBackgroundAlpha: CGFloat = 0.65
    }

    // MARK: - 待播清单面板（Music 的 NativePlayQueueViewController）

    /// 侧栏「播放列表」面板的度量，出处一律是
    /// playqueue 规格 §3（27 基线）。
    ///
    /// 系统默认能给的一律不在这里立常量（AGENTS.md 界面层第 6 条）：
    /// 字号走 `NSFont` 语义档、栈间距走`NSStackView` 默认、行内缩走
    /// `NSTableView.style = .inset` 的默认——实测值只写进注释当验收标尺。
    /// 留在这里的都是 Music 自己的设计常量（有 [实测] 出处）。
    enum PlayQueue {
        /// [实测] playqueue spec §3.2：`rowHeight = 46`。**只是兜底**——delegate 的
        /// `heightOfRow` 对每一行都返回值，46 在 Music 里一行都没生效。照抄是为了同构。
        static let fallbackRowHeight: CGFloat = 46
        /// [实测] playqueue spec §3.5：曲目行与两条信息行（重复 / 其他 N 首）都是 48
        static let rowHeight: CGFloat = 48
        /// [实测] playqueue spec §3.5：历史 / 队列分区头，以及没有「来自…」的继续播放分区头
        static let headerHeight: CGFloat = 44
        /// [实测] playqueue spec §3.5：带「来自：…」副行的继续播放分区头
        static let headerWithSourceHeight: CGFloat = 58
        /// [实测] playqueue spec §3.5：空状态行 = `max(可视高 − 表格上下内缩 − 58, 55)`
        static let emptyRowHeightInset: CGFloat = 58
        static let emptyRowMinHeight: CGFloat = 55
        /// [实测] playqueue spec §3.5：懒测「自动连播」分区头时，控制器根视图还没载入的兜底宽
        static let autoplayHeaderFallbackWidth: CGFloat = 270

        /// Music 读的是私有属性 `_styleContentInsets`（`NSTableView` 按`style` 给的行内缩）。
        /// 没有公开等价物，这里按 `.inset` 样式的实测内缩取值：**左右各 10、上下 0**。[推]
        /// 只有两处用得上它：空状态行高（上下）与自动连播头的懒测宽（左右）。
        static let insetStyleHorizontalInset: CGFloat = 10
        static let insetStyleVerticalInset: CGFloat = 0

        // MARK: 分区头（§3.6）

        /// [实测] playqueue spec §3.6：标题与「来自…」副行竖排，间距 2
        static let headerTitleStackSpacing: CGFloat = 2
        /// [实测] playqueue spec §3.6：[标题竖排, 「清除」容器] 横排，间距 12
        static let headerStackSpacing: CGFloat = 12
        /// [实测] playqueue spec §3.6：整条 `totalStack` 贴分区头底部，`offset: -8`
        static let headerStackBottomInset: CGFloat = 8
        /// [实测] playqueue spec §3.6：自动连播分区头的内容容器上下内缩 11
        static let autoplayHeaderVerticalInset: CGFloat = 11

        // MARK: 信息行 / 空状态行（§3.7）

        /// [实测] playqueue spec §3.7：`repeat` 图标与文本横排间距 4，整体居中
        static let repeatingInfoSpacing: CGFloat = 4
        /// [实测] playqueue spec §3.7：`square.grid.2x2.fill` 图标 40×40
        static let moreCountIconSize: CGFloat = 40
        /// [实测] playqueue spec §3.7：图标左沿 offset 2、文本右沿 offset −2、两者间距 12
        static let moreCountIconLeading: CGFloat = 2
        static let moreCountTextSpacing: CGFloat = 12
        static let moreCountTextTrailing: CGFloat = 2
        /// [实测] playqueue spec §3.7：空状态文案左右内缩 20
        static let emptyMessageHorizontalInset: CGFloat = 20

        // MARK: 曲目行（§3.8）

        /// [实测] playqueue spec §3.8：封面 34×34，左沿贴格子（offset 0）
        static let artworkSize: CGFloat = 34
        /// [实测] playqueue spec §3.8：封面到标题 12
        static let artworkToTitleSpacing: CGFloat = 12
        /// [实测] playqueue spec §3.8：••• 28×28，右沿 offset −2
        static let moreButtonSize: CGFloat = 28
        static let moreButtonTrailingInset: CGFloat = 2

        // MARK: 顶部设置头（§3.9）

        /// [实测] playqueue spec §3.9：`kMargin = 10`（栈左右内缩）、`kSpacing = 8`（按钮间距）
        static let settingsMargin: CGFloat = 10
        static let settingsSpacing: CGFloat = 8
        /// [实测] playqueue spec §3.9：栈顶距头顶 8（`topMarginConstraint`），栈底贴头底
        static let settingsTopInset: CGFloat = 8
        /// [实测] playqueue spec §3.9：两颗按钮等宽约束的优先级。Music 是
        /// `NSLayoutPriority(500) - 10` **现算**出来的（不是立即数），值 = 490。
        static let settingsEqualWidthPriority: NSLayoutConstraint.Priority = .init(490)

        // MARK: 滚动（§3.11）

        /// [实测] playqueue spec §3.11：选区变化 / keyUp / 滚动结束都重置这个定时器，
        /// 到点把面板滑回「正在播的那一行」。Music 的 `kInterestTimeout` 也是同一个 5.0。
        static let scrollBackInterval: TimeInterval = 5
        /// [实测] playqueue spec §3.11：惯性吸附阈值上限 `min(rowHeight × N, 200)`
        static let snapThresholdLimit: CGFloat = 200
        /// [实测] playqueue spec §3.11：`w > 600` 才画水平网格线。面板列恒 258 宽，
        /// 所以实际恒无网格线——照做，是为了宽度真变时行为一致。
        static let gridLineWidthThreshold: CGFloat = 600
    }

    // MARK: - 显示简介（Get Info）面板

    /// 「显示简介」面板的外壳几何。**整块是绝对坐标规格**：
    /// `getinfo 样本` 把每一件控件的窗口坐标 frame 都量下来了，
    /// 而行距是 25 / 26 / 36 / 37 混着走的（§4.1 分组处加宽、§4.5 组间 37），
    /// 按「行序 × 行距」反推只会推错。所以逐条照抄实测，标 [AX]。
    ///
    /// 坐标系：**窗口左上角为原点、y 向下**。承载它的视图一律 `isFlipped = true`，
    /// 这样描述符里的数就是 `frame.origin`，不用每处再做一次 725 − y 的翻转。
    ///
    /// 三问的结论（AGENTS.md 界面层第 6 条）：
    /// 1. 系统给不出这些数——这是 Music 自己的对话框版式，不是任何标准控件的默认布局；
    /// 2. 正文 14pt **不是**系统默认（`NSFont.systemFontSize` = 13），实测硬结论，写死；
    /// 3. 分段控件与底部按钮的 13pt **就是**系统默认，所以下面只留注释当验收值，
    ///    代码里不设 font，让 AppKit 自己给。
    enum InfoPanel {

        // MARK: 窗口与三层分区（sample §1）

        /// [AX] 589 × 725，`AXDialog`，不可改大小
        static let windowWidth: CGFloat = 589
        static let windowHeight: CGFloat = 725
        /// [AX][PX] 头部 y = 0..113（背景比内容区亮一档），间隙 114..123
        static let headerHeight: CGFloat = 114
        /// [AX][PX] 内容区背景从 y = 148 起；层与层之间**不画分隔线**，只有背景色差
        static let contentTop: CGFloat = 148
        /// [AX] 内容滚动区 `0,159,589,502`（详细信息 / 选项 / 分类 / 文件四页同值）
        static let contentOriginY: CGFloat = 159
        static let contentHeight: CGFloat = 502
        /// [AX][PX] 底部区从 y = 662 起，与内容区同色、无分隔线
        static let footerTop: CGFloat = 662

        // MARK: 头部（sample §2）

        /// [AX][资源] 封面 `12,12,90,90`，与切片`InfoPanelAlbumArtDrag` 的 90×90 一致
        static let artworkInset: CGFloat = 12
        static let artworkSize: CGFloat = 90
        /// [AX] 三行文本左沿 114 = 12 + 90 + 12
        static let headerTextX: CGFloat = 114
        /// [AX] 标题 y=24.5、高 26，**宽度随文本收缩**（不定宽）
        static let headerTitleY: CGFloat = 24.5
        static let headerTitleHeight: CGFloat = 26
        /// [AX] 第 2、3 行 y=50.5 / 70.5，**定宽 426**、高 17
        static let headerSubtitleY: CGFloat = 50.5
        static let headerThirdLineY: CGFloat = 70.5
        static let headerSubtitleWidth: CGFloat = 426
        static let headerSubtitleHeight: CGFloat = 17
        /// [AX] 喜爱按钮 `544,46.5,26,19`，右边距 19（与「好」按钮同）
        static let favoriteFrame = CGRect(x: 544, y: 46.5, width: 26, height: 19)

        // MARK: 分段控件（sample §3）

        /// [AX] `AXRadioGroup` `11,123,566,26`，两侧各留 2pt 内边距
        static let tabGroupFrame = CGRect(x: 11, y: 123, width: 566, height: 26)
        /// [AX] 6 段**等宽 94、高 24、段间无间隙**；首段左沿 13、末段右沿 577
        static let tabSegmentWidth: CGFloat = 94
        static let tabSegmentHeight: CGFloat = 24
        static let tabFirstSegmentX: CGFloat = 13
        static let tabSegmentY: CGFloat = 125
        /// [RES] 六段标题，顺序照实测
        static let tabTitles = ["详细信息", "插图", "歌词", "选项", "分类", "文件"]

        // MARK: 内容区表单（sample §4.1）

        /// [AX] 标签列一律 `x=25, w=86`，**右对齐贴到 x=111**；高 17
        static let labelX: CGFloat = 25
        static let labelWidth: CGFloat = 86
        static let labelHeight: CGFloat = 17
        /// [AX] 控件左沿三档：可编辑文本框 115、勾选框/弹出菜单/组合框 118、只读与整行控件 114
        static let fieldX: CGFloat = 115
        static let checkBoxX: CGFloat = 118
        static let readOnlyX: CGFloat = 114
        /// [AX] 单行文本框高恒 24
        static let fieldHeight: CGFloat = 24
        /// [推] 文档视图底部留白。实测的滚动条滑块比例反推内容高约 521
        /// （最后一件控件下沿只到 606，即文档坐标 447），差值落在这里；
        /// 没有第二个样本佐证具体数值，取一个不影响任何一行位置的保守值。
        static let contentBottomPadding: CGFloat = 16

        // MARK: 底部（sample §5）

        /// [AX] 「上一个」`19,678.5,29,27`、「下一个」`45,678.5,29,27`——
        /// **水平重叠 3pt**（19+29 = 48 > 45），是并排分段的画法而不是两颗独立按钮。
        static let navSegmentFrame = CGRect(x: 19, y: 678.5, width: 55, height: 27)
        static let navSegmentWidth: CGFloat = 29
        /// [AX] 取消 `412,680,75,26`、好`495,680,75,26`（右边距 19）
        static let cancelFrame = CGRect(x: 412, y: 680, width: 75, height: 26)
        static let okFrame = CGRect(x: 495, y: 680, width: 75, height: 26)
        /// [AX] 中段「按 Tab 换内容」的槽位左沿：插图页「添加插图」`82,680,101,26`、
        /// 歌词页「自定义歌词」`82,682.5,99,21`，其余四页空着。
        static let slotX: CGFloat = 82
        static let addArtworkFrame = CGRect(x: 82, y: 680, width: 101, height: 26)
        static let customLyricsFrame = CGRect(x: 82, y: 682.5, width: 99, height: 21)

        // MARK: 字体（sample §7）

        /// [PX] 正文（标签 / 值 / 勾选框标签 / 头部第 2、3 行）**14.0pt regular**。
        /// 系统默认 `NSFont.systemFontSize` = 13，实测 14 —— 差一档，只能写死。
        static let bodyFontSize: CGFloat = 14
        /// [PX] 头部标题 **21.0pt light**（NCC 1.0000；regular 只有 0.9587，
        /// 判别余量很大——它比正文还细，不是「加粗大字」）
        static let headerTitleFontSize: CGFloat = 21
        // [PX] 分段控件文字与底部按钮文字是 13.0pt regular ＝ 系统默认，
        // 所以代码里不设 font。这行只当验收标尺。

        // MARK: 取值域（sample §4.7）

        /// [AX] 音量调整值域 −255…255，`AXAllowedValues` 给 11 个吸附档、步长 51；
        /// `AXValueDescription` 用百分比 ⇒ ±255 ↔ ±100%，51 = 20%
        static let volumeAdjustmentRange: ClosedRange<Int> = -255...255
        static let volumeAdjustmentStep = 51
        /// [AX] 评分 `AXSlider` subrole `AXRatingIndicator`，0…5 整星，frame`116,497.5,62,14`
        static let ratingMax = 5
    }
}
