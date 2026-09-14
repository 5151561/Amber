import AppKit

/// 六个 Tab 各一份字段描述符。
///
/// **每一条的 frame 都是 `getinfo 样本` §4.1–§4.6 与附录元素树里的
/// 实测窗口坐标，一个数都没有反推。** ITID 是 Music 内部字段编号在 AX 层的直接暴露
/// （`AXIdentifier = "ITID:<十进制>"`），留在表里给`InfoPanelLayoutTests` 逐条对。
///
/// 插图（Tab 1）与歌词（Tab 2）**不在这里**：它们的内容区 AX 只暴露一个标题
/// （sample §4.2「AX 不暴露拖放区里的图像元素」、§4.3 是一整块 AXTextArea），
/// 没有字段行可描述，由 `InfoPanelWindowController` 直接摆自定义视图。
enum InfoPanelTabs {

    private typealias M = MusicMetrics.InfoPanel

    /// 六段的下标。顺序 = 分段控件上从左到右（sample §3）。
    enum Tab: Int, CaseIterable {
        case details = 0, artwork, lyrics, options, sorting, file
        var title: String { M.tabTitles[rawValue] }
        /// 只有这四页是描述符驱动的
        var isDescriptorDriven: Bool {
            self != .artwork && self != .lyrics
        }
    }

    /// [AX] 详细信息页首行那颗弹出菜单（ITID 65534）展开实测**只有这两项**。
    /// 是古典音乐乐章系统的切换开关，不是多字段菜单。
    static let firstFieldTitles = ["标题", "作品名称"]

    /// - Parameter hasLocalFile: 这首曲目在本机有没有一份真文件。有的话文件页多三行
    ///   （位速率 / 采样速率 / 声道），见 `fileWithLocalRows` 的注释。
    static func fields(for tab: Tab, hasLocalFile: Bool = false) -> [InfoPanelField] {
        switch tab {
        case .details: return details
        case .options: return options
        case .sorting: return sorting
        case .file: return hasLocalFile ? fileWithLocalRows : file
        case .artwork, .lyrics: return []
        }
    }

    // MARK: - Tab 0 详细信息（sample §4.1）

    /// 行距 25pt，分组之间加宽到 ~30pt（291→317、453→497）——混着走，
    /// 所以不反推，逐行抄 y。
    static let details: [InfoPanelField] = [
        // 第一行**没有静态标签**：标签位就是那颗弹出菜单。
        InfoPanelField(label: nil, labelY: nil, itid: 2,
                       control: .firstField(popUp: NSRect(x: 6, y: 167, width: 106, height: 26),
                                            field: NSRect(x: 115, y: 167, width: 457, height: 24))),
        InfoPanelField(label: "艺人", labelY: 196, itid: 4,
                       control: .text(NSRect(x: 115, y: 192, width: 457, height: 24),
                                      key: \.info.artist)),
        InfoPanelField(label: "专辑", labelY: 221, itid: 3,
                       control: .text(NSRect(x: 115, y: 217, width: 457, height: 24),
                                      key: \.info.album)),
        InfoPanelField(label: "专辑艺人", labelY: 246, itid: 71,
                       control: .text(NSRect(x: 115, y: 242, width: 457, height: 24),
                                      key: \.info.albumArtist)),
        InfoPanelField(label: "作曲者", labelY: 271, itid: 18,
                       control: .text(NSRect(x: 115, y: 267, width: 457, height: 24),
                                      key: \.info.composer)),
        // [AX] 这一行在元素树里前面**没有** AXStaticText——勾选框自带文字，不占标签列。
        InfoPanelField(label: nil, labelY: nil, itid: 158,
                       control: .checkBox(NSRect(x: 118, y: 291, width: 457, height: 27),
                                          title: "在所有视图中显示作曲者",
                                          key: \.info.showComposerInAllViews)),
        InfoPanelField(label: "归类", labelY: 321, itid: 39,
                       control: .text(NSRect(x: 115, y: 317, width: 457, height: 24),
                                      key: \.info.grouping)),
        InfoPanelField(label: "类型", labelY: 347, itid: 8,
                       control: .comboBox(NSRect(x: 118, y: 346, width: 97, height: 26),
                                          key: \.info.genre)),
        InfoPanelField(label: "年份", labelY: 383, itid: 7,
                       control: .number(NSRect(x: 115, y: 379, width: 79, height: 24),
                                        key: \.info.year)),
        InfoPanelField(label: "音轨", labelY: 408, itid: 11,
                       control: .numberPair(first: NSRect(x: 115, y: 404, width: 29, height: 24),
                                            second: NSRect(x: 160, y: 404, width: 29, height: 24),
                                            secondITID: 52,
                                            slash: NSRect(x: 151, y: 408, width: 5, height: 17),
                                            firstKey: \.info.trackNumber,
                                            secondKey: \.info.trackCount)),
        InfoPanelField(label: "光盘编号", labelY: 433, itid: 24,
                       control: .numberPair(first: NSRect(x: 115, y: 429, width: 29, height: 24),
                                            second: NSRect(x: 160, y: 429, width: 29, height: 24),
                                            secondITID: 49,
                                            slash: NSRect(x: 151, y: 433, width: 5, height: 17),
                                            firstKey: \.info.discNumber,
                                            secondKey: \.info.discCount)),
        InfoPanelField(label: "合辑", labelY: 458, itid: 31,
                       control: .checkBox(NSRect(x: 118, y: 453, width: 457, height: 27),
                                          title: "专辑是多个艺人的歌曲合辑",
                                          key: \.info.isCompilation)),
        InfoPanelField(label: "评分", labelY: 495, itid: 25,
                       control: .rating(NSRect(x: 116, y: 497.5, width: 62, height: 14))),
        InfoPanelField(label: "bpm", labelY: 520, itid: 35,
                       control: .number(NSRect(x: 115, y: 516, width: 79, height: 24),
                                        key: \.info.bpm)),
        // [AX] 值是拼好的整句「4 （上次播放时间：星期四 17:25）」，不是分开两个字段。
        InfoPanelField(label: "播放次数", labelY: 545, itid: 22,
                       control: .readOnlyWithButton(NSRect(x: 114, y: 544, width: 376, height: 24),
                                                    .playCount,
                                                    button: NSRect(x: 500, y: 541, width: 75, height: 26),
                                                    title: "重设", action: .resetPlayCount)),
        InfoPanelField(label: "注释", labelY: 582, itid: 14,
                       control: .textArea(NSRect(x: 115, y: 578, width: 457, height: 28),
                                          key: \.info.comments)),
    ]

    // MARK: - Tab 3 选项（sample §4.4）

    static let options: [InfoPanelField] = [
        InfoPanelField(label: "媒体种类", labelY: 171, itid: 60,
                       control: .popUp(NSRect(x: 118, y: 166.5, width: 78, height: 26),
                                       kind: .mediaKind)),
        // 「开始 / 停止」是复选框 + 时间输入框的组合，复选框在左（16×16、无标题）。
        InfoPanelField(label: "开始", labelY: 208, itid: 50,
                       control: .timeToggle(check: NSRect(x: 118, y: 208.5, width: 16, height: 16),
                                            checkITID: 65486,
                                            field: NSRect(x: 134, y: 204, width: 73, height: 24),
                                            enabledKey: \.info.startTimeEnabled,
                                            time: .start)),
        InfoPanelField(label: "停止", labelY: 233, itid: 51,
                       control: .timeToggle(check: NSRect(x: 118, y: 233.5, width: 16, height: 16),
                                            checkITID: 65485,
                                            field: NSRect(x: 134, y: 229, width: 73, height: 24),
                                            enabledKey: \.info.stopTimeEnabled,
                                            time: .stop)),
        // [AX] 「播放」这个标签只出现一次，下辖两个复选框——第二个没有标签。
        InfoPanelField(label: "播放", labelY: 270, itid: 94,
                       control: .checkBox(NSRect(x: 118, y: 269, width: 118, height: 19),
                                          title: "记住播放位置",
                                          key: \.info.rememberPlaybackPosition)),
        InfoPanelField(label: nil, labelY: nil, itid: 112,
                       control: .checkBox(NSRect(x: 118, y: 294, width: 118, height: 19),
                                          title: "随机播放时跳过",
                                          key: \.info.skipWhenShuffling)),
        InfoPanelField(label: "音量调整", labelY: 330, itid: 74,
                       control: .slider(NSRect(x: 118, y: 329, width: 202, height: 20),
                                        key: \.info.volumeAdjustment)),
        InfoPanelField(label: "均衡器", labelY: 384, itid: 17,
                       control: .popUp(NSRect(x: 118, y: 379.5, width: 119, height: 26),
                                       kind: .equalizer)),
    ]

    // MARK: - Tab 4 分类（sample §4.5）

    /// **不是两列并排**（spec 原先猜错了），是 5 组「原字段 / 分类设为」上下配对共 10 行。
    /// 组内两行间距 25，组间 37。组顺序标题 → 专辑 → **专辑艺人 → 艺人** → 作曲者，
    /// 专辑艺人排在艺人**前面**，与详细信息页的顺序不同。
    /// 原字段行的 ITID 与详细信息页是同一套（同一字段跨 Tab 共用编号）。
    static let sorting: [InfoPanelField] = [
        InfoPanelField(label: "标题", labelY: 171, itid: 2,
                       control: .text(NSRect(x: 115, y: 167, width: 457, height: 24),
                                      key: \.info.title)),
        InfoPanelField(label: "分类设为", labelY: 196, itid: 78,
                       control: .text(NSRect(x: 115, y: 192, width: 457, height: 24),
                                      key: \.info.sortTitle)),
        InfoPanelField(label: "专辑", labelY: 233, itid: 3,
                       control: .text(NSRect(x: 115, y: 229, width: 457, height: 24),
                                      key: \.info.album)),
        InfoPanelField(label: "分类设为", labelY: 258, itid: 79,
                       control: .text(NSRect(x: 115, y: 254, width: 457, height: 24),
                                      key: \.info.sortAlbum)),
        InfoPanelField(label: "专辑艺人", labelY: 295, itid: 71,
                       control: .text(NSRect(x: 115, y: 291, width: 457, height: 24),
                                      key: \.info.albumArtist)),
        InfoPanelField(label: "分类设为", labelY: 320, itid: 81,
                       control: .text(NSRect(x: 115, y: 316, width: 457, height: 24),
                                      key: \.info.sortAlbumArtist)),
        InfoPanelField(label: "艺人", labelY: 357, itid: 4,
                       control: .text(NSRect(x: 115, y: 353, width: 457, height: 24),
                                      key: \.info.artist)),
        InfoPanelField(label: "分类设为", labelY: 382, itid: 80,
                       control: .text(NSRect(x: 115, y: 378, width: 457, height: 24),
                                      key: \.info.sortArtist)),
        InfoPanelField(label: "作曲者", labelY: 419, itid: 18,
                       control: .text(NSRect(x: 115, y: 415, width: 457, height: 24),
                                      key: \.info.composer)),
        InfoPanelField(label: "分类设为", labelY: 444, itid: 82,
                       control: .text(NSRect(x: 115, y: 440, width: 457, height: 24),
                                      key: \.info.sortComposer)),
    ]

    // MARK: - Tab 5 文件（sample §4.6）

    /// 全只读，但控件**仍是 AXTextField 不是 AXStaticText**——照办。左沿 114、宽 459。
    static let file: [InfoPanelField] = [
        InfoPanelField(label: "种类", labelY: 171, itid: 9,
                       control: .readOnly(NSRect(x: 114, y: 170, width: 459, height: 24), .kind)),
        InfoPanelField(label: "时长", labelY: 196, itid: 13,
                       control: .readOnly(NSRect(x: 114, y: 195, width: 459, height: 24), .duration)),
        InfoPanelField(label: "大小", labelY: 221, itid: 12,
                       control: .readOnly(NSRect(x: 114, y: 220, width: 459, height: 24), .size)),
        InfoPanelField(label: "修改日期", labelY: 258, itid: 10,
                       control: .readOnly(NSRect(x: 114, y: 257, width: 459, height: 24), .dateModified)),
        InfoPanelField(label: "添加日期", labelY: 283, itid: 16,
                       control: .readOnly(NSRect(x: 114, y: 282, width: 459, height: 24), .dateAdded)),
        InfoPanelField(label: "云端状态", labelY: 320, itid: 134,
                       control: .readOnly(NSRect(x: 114, y: 319, width: 459, height: 24), .cloudStatus)),
        // [AX] 「位置」是路径面包屑（AXList 里逐段 AXStaticText），没有 ITID。
        InfoPanelField(label: "位置", labelY: 345, itid: nil,
                       control: .pathBreadcrumb(NSRect(x: 109, y: 338.5, width: 469, height: 30))),
        InfoPanelField(label: "版权", labelY: 371, itid: 124,
                       control: .readOnly(NSRect(x: 114, y: 370, width: 459, height: 24), .copyright)),
    ]

    /// 本机有真文件时的文件页：在上面那 8 行的「大小」之后插三行。
    ///
    /// **行位是 `[推]`，标签文案是`[RES]`。** 两句都要看清楚：
    /// - `[RES]` 资源表 241 里这三条是成套的字段名（45`bit rate` / 46 `sample rate` /
    ///   111 `channels`，zh_CN 作「位速率」「采样速率」「声道」），
    ///   spec §4.6 的「音频格式属性」也是按 **种类 → 大小 → 位速率 → 采样速率 → 声道**
    ///   这个次序列的，所以插在「大小」后面、三行的先后都有据；
    /// - `[AX]` **没有**这三行的实测行位——那份样本采的是 Apple Music 云端曲目
    ///   （sample §0），云端曲目上 Music 压根不显示这三行。所以 y 是照这一页
    ///   已有的组内行距 25pt 推的（220 → 245 → 270 → 295），其后各行整体下移 75
    ///   （= 3 × 25），组间那 37pt 的空档原样保留（295 → 332，与原来的 220 → 257 同宽）。
    ///
    /// ITID 留 `nil`：这三行 AX 从没采到过，编一个号出来只会让单测拿着假数去对。
    static let fileWithLocalRows: [InfoPanelField] = [
        InfoPanelField(label: "种类", labelY: 171, itid: 9,
                       control: .readOnly(NSRect(x: 114, y: 170, width: 459, height: 24), .kind)),
        InfoPanelField(label: "时长", labelY: 196, itid: 13,
                       control: .readOnly(NSRect(x: 114, y: 195, width: 459, height: 24), .duration)),
        InfoPanelField(label: "大小", labelY: 221, itid: 12,
                       control: .readOnly(NSRect(x: 114, y: 220, width: 459, height: 24), .size)),
        // ↓ 三行 [RES]+[推]
        InfoPanelField(label: "位速率", labelY: 246, itid: nil,
                       control: .readOnly(NSRect(x: 114, y: 245, width: 459, height: 24), .bitRate)),
        InfoPanelField(label: "采样速率", labelY: 271, itid: nil,
                       control: .readOnly(NSRect(x: 114, y: 270, width: 459, height: 24), .sampleRate)),
        InfoPanelField(label: "声道", labelY: 296, itid: nil,
                       control: .readOnly(NSRect(x: 114, y: 295, width: 459, height: 24), .channels)),
        // ↓ 以下与上面那张实测表逐条同构，只是 y 各加 75
        InfoPanelField(label: "修改日期", labelY: 333, itid: 10,
                       control: .readOnly(NSRect(x: 114, y: 332, width: 459, height: 24), .dateModified)),
        InfoPanelField(label: "添加日期", labelY: 358, itid: 16,
                       control: .readOnly(NSRect(x: 114, y: 357, width: 459, height: 24), .dateAdded)),
        InfoPanelField(label: "云端状态", labelY: 395, itid: 134,
                       control: .readOnly(NSRect(x: 114, y: 394, width: 459, height: 24), .cloudStatus)),
        InfoPanelField(label: "位置", labelY: 420, itid: nil,
                       control: .pathBreadcrumb(NSRect(x: 109, y: 413.5, width: 469, height: 30))),
        InfoPanelField(label: "版权", labelY: 446, itid: 124,
                       control: .readOnly(NSRect(x: 114, y: 445, width: 459, height: 24), .copyright)),
    ]
}
