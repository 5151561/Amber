import XCTest
@testable import Amber

/// 「显示简介」面板的**纯计算**测试：描述符表的完备性、导航边界、草稿语义。
/// 一扇窗都不开——布局的正确性在这里只体现为「描述符表与实测表逐条一致」。
///
/// 实测原文：`getinfo 样本` §4.1–§4.6 与附录的 AX 元素树。
/// 这些断言就是那份取样的机读版：**哪天谁顺手改了某一行的 y，这里立刻炸**。
@MainActor
final class InfoPanelLayoutTests: XCTestCase {

    private typealias M = MusicMetrics.InfoPanel

    // MARK: - 外壳几何（sample §1 / §3 / §5）

    func testWindowAndLayerGeometryMatchesSample() {
        XCTAssertEqual(M.windowWidth, 589)
        XCTAssertEqual(M.windowHeight, 725)
        XCTAssertEqual(M.headerHeight, 114)
        XCTAssertEqual(M.contentTop, 148)
        XCTAssertEqual(M.contentOriginY, 159)
        XCTAssertEqual(M.contentHeight, 502)
        XCTAssertEqual(M.footerTop, 662)
        // 内容滚动区下沿 159 + 502 = 661，正好接上底部区起点 662
        XCTAssertEqual(M.contentOriginY + M.contentHeight + 1, M.footerTop)
    }

    func testHeaderGeometryMatchesSample() {
        // 文本列左沿 114 = 封面左边距 12 + 封面 90 + 12
        XCTAssertEqual(M.headerTextX, M.artworkInset + M.artworkSize + M.artworkInset)
        XCTAssertEqual(M.headerTitleY, 24.5)
        XCTAssertEqual(M.headerSubtitleY, 50.5)
        XCTAssertEqual(M.headerThirdLineY, 70.5)
        XCTAssertEqual(M.headerSubtitleWidth, 426)
        XCTAssertEqual(M.favoriteFrame, CGRect(x: 544, y: 46.5, width: 26, height: 19))
        // 喜爱按钮右边距 19，与「好」按钮右边距一致
        XCTAssertEqual(M.windowWidth - M.favoriteFrame.maxX, 19)
        XCTAssertEqual(M.windowWidth - M.okFrame.maxX, 19)
    }

    func testTabSegmentsAreEqualWidthWithoutGaps() {
        XCTAssertEqual(M.tabGroupFrame, CGRect(x: 11, y: 123, width: 566, height: 26))
        XCTAssertEqual(M.tabTitles, ["详细信息", "插图", "歌词", "选项", "分类", "文件"])
        // 6 段等宽 94、段间无间隙：首段 13，末段右沿 577
        let lefts = (0..<6).map { M.tabFirstSegmentX + CGFloat($0) * M.tabSegmentWidth }
        XCTAssertEqual(lefts, [13, 107, 201, 295, 389, 483])
        XCTAssertEqual(lefts.last! + M.tabSegmentWidth, 577)
        // **内边距只有左边那 2pt**。sample §3 写的是「容器 11..577 两侧各留 2pt 内边距」，
        // 但那句归纳与它自己列的数对不上：6 × 94 = 564，13 + 564 = 577 = 容器右沿，
        // 右边一点不剩。容器宽 566 = 564 + 2 也只够左边那一份。
        // 实测的**数**是自洽的，错的是那一句话，所以按数走。
        XCTAssertEqual(M.tabFirstSegmentX - M.tabGroupFrame.minX, 2)
        XCTAssertEqual(M.tabGroupFrame.maxX - 577, 0)
    }

    func testFooterGeometryMatchesSample() {
        // 「上一个」19,·,29 与「下一个」45,·,29 **水平重叠 3pt**——并排分段的画法
        XCTAssertEqual(M.navSegmentFrame.minX, 19)
        XCTAssertEqual(M.navSegmentWidth, 29)
        XCTAssertEqual(M.navSegmentFrame.minX + M.navSegmentWidth - 45, 3)
        XCTAssertEqual(M.cancelFrame, CGRect(x: 412, y: 680, width: 75, height: 26))
        XCTAssertEqual(M.okFrame, CGRect(x: 495, y: 680, width: 75, height: 26))
        // 插图页的按钮与歌词页的勾选框占**同一个** x=82 槽位
        XCTAssertEqual(M.addArtworkFrame.minX, M.slotX)
        XCTAssertEqual(M.customLyricsFrame.minX, M.slotX)
    }

    func testBodyFontIsOneNotchLargerThanSystemDefault() {
        // [PX] 正文 14pt；系统默认 13pt。差一档是实测硬结论，不是笔误。
        XCTAssertEqual(M.bodyFontSize, 14)
        XCTAssertEqual(NSFont.systemFontSize, 13)
        XCTAssertEqual(M.headerTitleFontSize, 21)
    }

    // MARK: - 标签列（sample §4.1）

    func testEveryLabelIsRightAlignedToX111() {
        // 标签列一律 x=25, w=86，右对齐贴到 x=111
        XCTAssertEqual(M.labelX + M.labelWidth, 111)
        for tab in InfoPanelTabs.Tab.allCases where tab.isDescriptorDriven {
            for field in InfoPanelTabs.fields(for: tab) where field.label != nil {
                XCTAssertNotNil(field.labelY, "\(tab) 的「\(field.label!)」有标签就该有 labelY")
            }
        }
    }

    func testControlLeadingEdgesUseOnlyTheThreeMeasuredColumns() {
        // [AX] 控件左沿只有三档：可编辑文本框 115、勾选框/弹出/组合框 118、只读与整行 114
        let allowed: Set<CGFloat> = [114, 115, 116, 118, 6, 109, 134]
        for tab in InfoPanelTabs.Tab.allCases where tab.isDescriptorDriven {
            for field in InfoPanelTabs.fields(for: tab) {
                XCTAssertTrue(allowed.contains(field.controlFrame.minX),
                              "\(tab) 里出现了实测之外的左沿 \(field.controlFrame.minX)")
            }
        }
    }

    // MARK: - 六个 Tab 的字段序 / ITID / y（sample §4.1–§4.6）

    func testDetailsTabMatchesSample() {
        let fields = InfoPanelTabs.details
        XCTAssertEqual(fields.count, 16)
        XCTAssertEqual(fields.map(\.itid),
                       [2, 4, 3, 71, 18, 158, 39, 8, 7, 11, 24, 31, 25, 35, 22, 14])
        XCTAssertEqual(fields.map { $0.controlFrame.minY },
                       [167, 192, 217, 242, 267, 291, 317, 346, 379, 404, 429, 453, 497.5, 516, 544, 578])
        XCTAssertEqual(fields.map(\.label),
                       [nil, "艺人", "专辑", "专辑艺人", "作曲者", nil, "归类", "类型",
                        "年份", "音轨", "光盘编号", "合辑", "评分", "bpm", "播放次数", "注释"])
        // 音轨 / 光盘编号是两个数字夹一个「/」，第二格的 ITID 是 52 / 49
        XCTAssertEqual(secondITIDs(of: fields), [52, 49])
    }

    func testOptionsTabMatchesSample() {
        let fields = InfoPanelTabs.options
        XCTAssertEqual(fields.count, 7)
        XCTAssertEqual(fields.map(\.itid), [60, 50, 51, 94, 112, 74, 17])
        XCTAssertEqual(fields.map { $0.controlFrame.minY }, [166.5, 204, 229, 269, 294, 329, 379.5])
        // 「播放」这个标签只出现一次，下辖两个复选框——第二个没有标签
        XCTAssertEqual(fields[3].label, "播放")
        XCTAssertNil(fields[4].label)
        // 开始 / 停止的勾选框在左、16×16，ITID 65486 / 65485
        XCTAssertEqual(checkITIDs(of: fields), [65486, 65485])
    }

    func testSortingTabIsFivePairsNotTwoColumns() {
        let fields = InfoPanelTabs.sorting
        // spec 原先猜的「六行两列」是错的：实测是 5 组上下配对共 10 行
        XCTAssertEqual(fields.count, 10)
        XCTAssertEqual(fields.map(\.itid), [2, 78, 3, 79, 71, 81, 4, 80, 18, 82])
        XCTAssertEqual(fields.map { $0.controlFrame.minY },
                       [167, 192, 229, 254, 291, 316, 353, 378, 415, 440])
        // 组顺序是标题 → 专辑 → **专辑艺人 → 艺人** → 作曲者，
        // 专辑艺人排在艺人前面，与详细信息页的顺序不同
        XCTAssertEqual(fields.map(\.label),
                       ["标题", "分类设为", "专辑", "分类设为", "专辑艺人", "分类设为",
                        "艺人", "分类设为", "作曲者", "分类设为"])
        // 组内两行间距 25，组间 37
        let tops = fields.map { $0.controlFrame.minY }
        XCTAssertEqual(stride(from: 0, to: 10, by: 2).map { tops[$0 + 1] - tops[$0] },
                       [25, 25, 25, 25, 25])
        XCTAssertEqual(stride(from: 1, to: 9, by: 2).map { tops[$0 + 1] - tops[$0] },
                       [37, 37, 37, 37])
    }

    func testFileTabIsReadOnlyAndMatchesSample() {
        let fields = InfoPanelTabs.file
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(fields.map(\.itid), [9, 13, 12, 10, 16, 134, nil, 124])
        XCTAssertEqual(fields.map { $0.controlFrame.minY },
                       [170, 195, 220, 257, 282, 319, 338.5, 370])
        // 全只读：只许出现 readOnly 与路径面包屑两种控件
        for field in fields {
            switch field.control {
            case .readOnly, .pathBreadcrumb: break
            default: XCTFail("文件页出现了可编辑控件：\(field.label ?? "?")")
            }
        }
        // 「位置」是面包屑，没有 ITID
        XCTAssertNil(fields[6].itid)
        if case .pathBreadcrumb(let frame) = fields[6].control {
            XCTAssertEqual(frame, CGRect(x: 109, y: 338.5, width: 469, height: 30))
        } else {
            XCTFail("「位置」应当是路径面包屑")
        }
        // 实测那份样本是**云端曲目**（sample §0），所以这 8 行就是云端曲目的全部——
        // 描述符默认给的也必须是这一份。
        XCTAssertEqual(InfoPanelTabs.fields(for: .file).map(\.label),
                       fields.map(\.label))
    }

    /// 本机有真文件时多出的三行：位速率 / 采样速率 / 声道。
    ///
    /// 标签文案是 [RES]（资源表 241 的 45/46/111，zh_CN 作「位速率」「采样速率」「声道」），
    /// **行位是 [推]**——云端曲目上实测没有这三行，所以这里只能按这一页已有的
    /// 组内行距 25pt 推，其后各行整体下移 75。这条断言就是那个推法的机读版。
    func testFileTabWithLocalFileInsertsThreeInferredRows() {
        let cloud = InfoPanelTabs.file
        let local = InfoPanelTabs.fileWithLocalRows
        XCTAssertEqual(local.count, cloud.count + 3)
        XCTAssertEqual(InfoPanelTabs.fields(for: .file, hasLocalFile: true).map(\.label),
                       local.map(\.label))
        XCTAssertEqual(local.map(\.label),
                       ["种类", "时长", "大小", "位速率", "采样速率", "声道",
                        "修改日期", "添加日期", "云端状态", "位置", "版权"])
        // 「大小」之前的三行与实测表逐条相同（一个数都没动）
        for index in 0..<3 {
            XCTAssertEqual(local[index].controlFrame, cloud[index].controlFrame)
            XCTAssertEqual(local[index].itid, cloud[index].itid)
            XCTAssertEqual(local[index].labelY, cloud[index].labelY)
        }
        // 新三行：接着「大小」的 220 按 25pt 往下排，标签照这一页的规矩比控件高 1
        XCTAssertEqual(local[3...5].map { $0.controlFrame.minY }, [245, 270, 295])
        XCTAssertEqual(local[3...5].map(\.labelY), [246, 271, 296])
        // 这三行 AX 从没采到过，不许编 ITID
        XCTAssertEqual(local[3...5].map(\.itid), [nil, nil, nil])
        // 其后各行 = 实测表同一行整体下移 75（= 3 × 25），ITID 原样
        for index in 3..<cloud.count {
            let shifted = local[index + 3]
            XCTAssertEqual(shifted.itid, cloud[index].itid)
            XCTAssertEqual(shifted.controlFrame.minY, cloud[index].controlFrame.minY + 75)
            XCTAssertEqual(shifted.controlFrame.minX, cloud[index].controlFrame.minX)
            XCTAssertEqual(shifted.controlFrame.width, cloud[index].controlFrame.width)
            XCTAssertEqual(shifted.labelY, cloud[index].labelY.map { $0 + 75 })
        }
        // 仍然全只读
        for field in local {
            switch field.control {
            case .readOnly, .pathBreadcrumb: break
            default: XCTFail("文件页出现了可编辑控件：\(field.label ?? "?")")
            }
        }
        // 最后一行的下沿仍在内容区 502pt 之内，不用滚动
        XCTAssertLessThanOrEqual(local.map { $0.controlFrame.maxY }.max() ?? 0,
                                 M.contentOriginY + M.contentHeight)
    }

    /// 文件页的值**不许来自草稿**：这一页一格都不可编辑，所以描述符里
    /// 不能出现任何绑着 `WritableKeyPath` 的控件（上面两条按控件种类查的是形状，
    /// 这条查的是「有没有一条写回草稿的路」）。
    func testFileTabHasNoWritableBinding() {
        for field in InfoPanelTabs.file + InfoPanelTabs.fileWithLocalRows {
            if case .readOnly = field.control { continue }
            if case .pathBreadcrumb = field.control { continue }
            XCTFail("文件页的「\(field.label ?? "?")」挂了可写绑定")
        }
    }

    func testArtworkAndLyricsTabsHaveNoDescriptors() {
        // AX 不暴露这两页内容区的内部元素（sample §4.2 / §4.3），
        // 所以它们不是描述符驱动的，由控制器直接摆自定义视图。
        XCTAssertTrue(InfoPanelTabs.fields(for: .artwork).isEmpty)
        XCTAssertTrue(InfoPanelTabs.fields(for: .lyrics).isEmpty)
        XCTAssertFalse(InfoPanelTabs.Tab.artwork.isDescriptorDriven)
        XCTAssertFalse(InfoPanelTabs.Tab.lyrics.isDescriptorDriven)
    }

    func testFirstFieldSelectorHasExactlyTwoChoices() {
        // [AX] ITID 65534 展开实测**只有两项**，不是多字段菜单
        XCTAssertEqual(InfoPanelTabs.firstFieldTitles, ["标题", "作品名称"])
    }

    func testSharedFieldIDsAreConsistentAcrossTabs() {
        // 同一字段跨 Tab 共用 ITID：标题 2 / 专辑 3 / 专辑艺人 71 / 艺人 4 / 作曲者 18
        let details = Dictionary(uniqueKeysWithValues:
            InfoPanelTabs.details.compactMap { field -> (Int, String?)? in
                field.itid.map { ($0, field.label) } })
        for (itid, label) in [(3, "专辑"), (71, "专辑艺人"), (4, "艺人"), (18, "作曲者")] {
            XCTAssertEqual(details[itid] ?? nil, label)
        }
        let sorting = InfoPanelTabs.sorting.compactMap(\.itid)
        XCTAssertEqual(Set(sorting).intersection([2, 3, 71, 4, 18]), [2, 3, 71, 4, 18])
        // 排序值是另外 5 个连号
        XCTAssertEqual(Set(sorting).subtracting([2, 3, 71, 4, 18]), [78, 79, 80, 81, 82])
    }

    // MARK: - 取值域（sample §4.7）

    func testVolumeAdjustmentSnapsToElevenStops() {
        XCTAssertEqual(M.volumeAdjustmentRange, -255...255)
        XCTAssertEqual(M.volumeAdjustmentStep, 51)
        let stops = stride(from: -255, through: 255, by: 51).map { $0 }
        XCTAssertEqual(stops.count, 11)
        XCTAssertEqual(stops, [-255, -204, -153, -102, -51, 0, 51, 102, 153, 204, 255])
    }

    func testEqualizerListMatchesSample() {
        // [AX] 菜单里是 24 项，但其中一条是首项后的**分隔线**——真预设 23 个。
        // `names` 收的是预设名，所以是 23；分隔线由界面自己在首项后插。
        XCTAssertEqual(EqualizerPreset.names.count, 23)
        XCTAssertEqual(EqualizerPreset.names.first, "无")
        XCTAssertEqual(EqualizerPreset.names.last, "R&B")
    }

    // MARK: - 时间输入框的来回

    func testTimeStringRoundTrip() {
        // [AX] 开始 `0:00`、停止`2:39.962`
        XCTAssertEqual(InfoPanelFormView.timeString(0), "0:00")
        XCTAssertEqual(InfoPanelFormView.timeString(159.962), "2:39.962")
        XCTAssertEqual(InfoPanelFormView.timeValue("0:00"), 0)
        XCTAssertEqual(InfoPanelFormView.timeValue("2:39.962")!, 159.962, accuracy: 0.0005)
        XCTAssertEqual(InfoPanelFormView.timeValue("90"), 90)
        XCTAssertNil(InfoPanelFormView.timeValue(""))
        XCTAssertNil(InfoPanelFormView.timeValue("绿"))
    }

    // MARK: - 上一个 / 下一个

    func testCursorBoundsForSingleTrack() {
        var cursor = InfoPanelCursor(count: 1)
        XCTAssertFalse(cursor.canGoPrevious)
        XCTAssertFalse(cursor.canGoNext)
        XCTAssertFalse(cursor.move(by: 1))
        XCTAssertFalse(cursor.move(by: -1))
        XCTAssertEqual(cursor.index, 0)
    }

    func testCursorWalksTheBatchAndStopsAtBothEnds() {
        var cursor = InfoPanelCursor(count: 3)
        XCTAssertFalse(cursor.canGoPrevious)
        XCTAssertTrue(cursor.move(by: 1))
        XCTAssertTrue(cursor.canGoPrevious)
        XCTAssertTrue(cursor.canGoNext)
        XCTAssertTrue(cursor.move(by: 1))
        XCTAssertEqual(cursor.index, 2)
        XCTAssertFalse(cursor.canGoNext)
        // 走到头不动，也**不回绕**
        XCTAssertFalse(cursor.move(by: 1))
        XCTAssertEqual(cursor.index, 2)
    }

    // MARK: - 草稿：提交 / 丢弃

    private func draft(title: String, rating: Int = 0) -> InfoPanelDraft {
        var info = TrackInfo()
        info.title = title
        return InfoPanelDraft(info: info, rating: rating, isFavorite: false)
    }

    func testUntouchedDraftIsNotSubmitted() {
        var book = InfoPanelDraftBook()
        book.start(draft(title: "原样"), for: "a")
        XCTAssertTrue(book.pending().isEmpty, "没编过的一首不该进提交清单")
    }

    func testEditedDraftIsSubmittedOnce() {
        var book = InfoPanelDraftBook()
        book.start(draft(title: "原样"), for: "a")
        book.keep(draft(title: "改过"), for: "a")
        XCTAssertEqual(book.pending().count, 1)
        XCTAssertEqual(book.pending()["a"]?.info.title, "改过")
        // 改回原样就又不算改过了（对着初始值比，不是脏标记）
        book.keep(draft(title: "原样"), for: "a")
        XCTAssertTrue(book.pending().isEmpty)
    }

    func testCancelDiscardsEveryEdit() {
        var book = InfoPanelDraftBook()
        book.start(draft(title: "甲"), for: "a")
        book.start(draft(title: "乙"), for: "b")
        book.keep(draft(title: "甲改", rating: 4), for: "a")
        book.keep(draft(title: "乙改"), for: "b")
        XCTAssertEqual(book.pending().count, 2)
        book.discardAll()
        XCTAssertTrue(book.pending().isEmpty)
        XCTAssertEqual(book.draft(for: "a")?.info.title, "甲")
        XCTAssertEqual(book.draft(for: "a")?.rating, 0)
    }

    func testWalkingAwayAndBackKeepsTheHalfFinishedEdit() {
        var book = InfoPanelDraftBook()
        book.start(draft(title: "甲"), for: "a")
        book.keep(draft(title: "甲编到一半"), for: "a")
        book.start(draft(title: "乙"), for: "b")
        // 走回来还是刚才那份
        XCTAssertEqual(book.draft(for: "a")?.info.title, "甲编到一半")
        XCTAssertEqual(book.initialDraft(for: "a")?.info.title, "甲")
    }

    func testRatingAndFavoriteRideAlongInTheDraft() {
        // 评分与喜爱不在 TrackInfo 里（它们是 LibraryStore 的），
        // 但面板上跟别的字段一样要攒到「好」才写，所以必须进草稿。
        var book = InfoPanelDraftBook()
        var start = draft(title: "甲")
        book.start(start, for: "a")
        start.rating = 5
        start.isFavorite = true
        book.keep(start, for: "a")
        XCTAssertEqual(book.pending()["a"]?.rating, 5)
        XCTAssertEqual(book.pending()["a"]?.isFavorite, true)
    }

    // MARK: 小工具

    private func secondITIDs(of fields: [InfoPanelField]) -> [Int] {
        fields.compactMap { field in
            if case let .numberPair(_, _, secondITID, _, _, _) = field.control { return secondITID }
            return nil
        }
    }

    private func checkITIDs(of fields: [InfoPanelField]) -> [Int] {
        fields.compactMap { field in
            if case let .timeToggle(_, checkITID, _, _, _) = field.control { return checkITID }
            return nil
        }
    }
}
