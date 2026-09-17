import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 「显示简介」（Get Info）面板。Music 的 `InfoPanelWindowController`（spec §1.1）。
///
/// **全 AppKit，没有一处 `NSHostingView`**——AGENTS.md 界面层第 1、2 条：骨架是 AppKit，
/// SwiftUI 只作叶子，而这扇窗从头到尾都是标准控件摆在实测坐标上，没有哪一格
/// 「真有 SwiftUI 才能做的控件」。
///
/// 几何全部照 `getinfo 样本` 的实测绝对坐标，度量在
/// `MusicMetrics.InfoPanel`，逐字段的 frame 在`InfoPanelTabs`。
///
/// **本批只做单选。** spec §5 的多选行为（4 Tab 裁剪、混合态占位、脏标记批量覆写）
/// 三条**全是 `[推]`**，而且多选态一次都没采过（sample §9 #1）——
/// 所以 `init(tracks:)` 收到多首时只取第一首，不照着`[推]` 编一套多选界面。
/// 「上一个 / 下一个」仍在传进来的这一批里前后走，这是 Music 单选态本来就有的行为。
@MainActor
final class InfoPanelWindowController: NSWindowController, NSWindowDelegate, InfoPanelFormHost {

    private typealias M = MusicMetrics.InfoPanel

    // MARK: 状态

    private let appState: AppState
    /// 传进来的这一批（「上一个 / 下一个」在其中走）
    private let tracks: [Track]
    private var nav: InfoPanelCursor
    /// 每一首各自那份草稿 + 初始值（Music 的双适配器，spec §1.2）
    private var book = InfoPanelDraftBook()

    private var track: Track { tracks[nav.index] }

    /// 面板全程编辑的这一份。点「好」才一次性提交，点「取消」（Esc）全丢。
    /// 这是 Music 双适配器语义的复刻（spec §1.2）：`draft` ↔ `mITTrackInfoAdapter`、
    /// `initial` ↔ `mInitialValuesITTrackInfoAdapter`，后者只用来判断「到底改没改」。
    var draft: InfoPanelDraft

    private var tab: InfoPanelTabs.Tab = .details

    // MARK: 视图

    private let root = FlippedView(frame: NSRect(x: 0, y: 0,
                                                 width: MusicMetrics.InfoPanel.windowWidth,
                                                 height: MusicMetrics.InfoPanel.windowHeight))
    private let header = HeaderView(frame: NSRect(x: 0, y: 0,
                                                  width: MusicMetrics.InfoPanel.windowWidth,
                                                  height: MusicMetrics.InfoPanel.headerHeight))
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let albumLabel = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton()
    private let tabControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let navControl = NSSegmentedControl()
    /// [AX] 底部中段 x=82 的「按 Tab 换内容」槽位：插图页放「添加插图」、
    /// 歌词页放「自定义歌词」勾选框，其余四页空着。
    private let addArtworkButton = NSButton()
    private let customLyricsBox = NSButton()

    /// 歌词页那块（异步取词，首次切进去是转圈——[AX] 实测约 3 秒后才出文本）
    private let lyricsTextView = NSTextView()
    private let lyricsSpinner = NSProgressIndicator()
    private var lyricsTask: Task<Void, Never>?
    /// 音源取回来的词（只读那一份）。自定义歌词关掉时回落到它。
    private var providerLyrics: String = ""

    private var artworkDropView: ArtworkDropView?

    /// 「类型」那一格的异步回填（资料库里那份专辑没有流派时才去问音源）。
    /// 每首只问一次——问到空也算问过，否则每切一次 Tab 就再发一次请求。
    private var genreTask: Task<Void, Never>?
    private var genreProbed: Set<String> = []

    /// 文件页那几项「真读文件」的结果，按曲目 id 存一份：来回切 Tab 不重读。
    private var fileFacts: [String: InfoPanelFileFacts] = [:]
    /// 云端曲目探到的字节数，按曲目 id 存。**存了 0 也算探过**，不再重探。
    private var cloudBytes: [String: Int] = [:]
    private var fileProbeTask: Task<Void, Never>?

    // MARK: - 对外 API

    /// - Parameter tracks: 一首＝单选态；多首时**只取第一首**（多选态见类型注释）。
    init(tracks: [Track], appState: AppState) {
        precondition(!tracks.isEmpty, "显示简介至少要有一首曲目")
        self.appState = appState
        self.tracks = tracks
        self.nav = InfoPanelCursor(count: tracks.count)
        let first = tracks[0]
        let start = InfoPanelDraft(info: Self.info(for: first, library: appState.library),
                                   rating: appState.library.rating(for: first.id),
                                   isFavorite: appState.library.isFavorite(first))
        self.draft = start
        self.book.start(start, for: first.id)

        // [AX] 589×725、`AXDialog`、不可改大小。头部是内容的一部分（y=0 起），
        // 所以 `.fullSizeContentView` + 透明标题栏；红绿灯三颗全隐——实测那扇窗的
        // AX 树里一颗窗口按钮都没有（与设置窗同一套路）。`.closable` 留着是为了 ⌘W。
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: M.windowWidth, height: M.windowHeight),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "歌曲信息"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // [PX] 内容区 / 窗口背景实测 #29292A，`underPageBackgroundColor` 深色解析出 #282828，
        // 差 1/255 ——用语义色，实测值只当验收标尺（sample §6 那一节自己就是这么写的）。
        panel.backgroundColor = .underPageBackgroundColor
        super.init(window: panel)

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = root
        // **要显式设**：`NSWindowController` 只在自己从 nib 载入窗口时才顺手当上 delegate，
        // `init(window:)` 传进来的这一扇不会（同族的坑见记忆里`loadWindow` 那条）。
        panel.delegate = self
        root.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        buildHeader()
        buildTabControl()
        buildContent()
        buildFooter()
        reloadTrack()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 打开面板时那一份简介。
    ///
    /// **「类型」要从所属专辑补**：`Track` 上没有流派这一项，音源是挂在专辑节点上给的
    ///（`LibraryStore.genre(for:)` 就是查那一份）。不补的话面板上「类型」永远空着，
    /// 而歌曲表的「类型」列明明显示得出来——同一个事实两处不一致。
    /// 只在用户没编辑过的时候补：他一旦手填过，那份就是权威。
    private static func info(for track: Track, library: LibraryStore) -> TrackInfo {
        var info = TrackInfoStore.shared.info(for: track)
        if info.genre.isEmpty, let genre = library.genre(for: track) { info.genre = genre }
        return info
    }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 头部（sample §2）

    private func buildHeader() {
        header.autoresizingMask = [.width]
        root.addSubview(header)

        // [AX][资源] 封面 12,12,90,90
        artworkView.frame = NSRect(x: M.artworkInset, y: M.artworkInset,
                                   width: M.artworkSize, height: M.artworkSize)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 4
        artworkView.layer?.masksToBounds = true
        header.addSubview(artworkView)

        // [PX] 标题 21pt **light**（NCC 1.0000，regular 只有 0.9587——比正文还细，
        // 与「加粗大字」的直觉相反，但判别余量很大）；宽度随文本收缩，不定宽。
        titleLabel.font = .systemFont(ofSize: M.headerTitleFontSize, weight: .light)
        titleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(titleLabel)

        for label in [artistLabel, albumLabel] {
            label.font = .systemFont(ofSize: M.bodyFontSize)
            label.lineBreakMode = .byTruncatingTail
            header.addSubview(label)
        }
        artistLabel.frame = NSRect(x: M.headerTextX, y: M.headerSubtitleY,
                                   width: M.headerSubtitleWidth, height: M.headerSubtitleHeight)
        albumLabel.frame = NSRect(x: M.headerTextX, y: M.headerThirdLineY,
                                  width: M.headerSubtitleWidth, height: M.headerSubtitleHeight)

        // [AX] 喜爱按钮 544,46.5,26,19，右边距 19（与「好」按钮同）
        favoriteButton.frame = M.favoriteFrame
        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .inline
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        header.addSubview(favoriteButton)
    }

    private func layoutHeaderTitle() {
        // 宽度随文本收缩：实测 81 = 四个汉字实宽，不是定宽。
        //
        // **不能问 `intrinsicContentSize`**：这个 label 设了
        // `lineBreakMode = .byTruncatingTail`，那时它报回来的是「截断之后」的宽度
        // ——拿它当 frame 宽，于是永远差一点点、永远画出省略号（实机「两点钟」
        // 被画成「两点…」）。直接问字体要排版宽，再补 NSTextField 自己那圈内边距。
        let font = titleLabel.font ?? .systemFont(ofSize: M.headerTitleFontSize, weight: .light)
        let inked = (titleLabel.stringValue as NSString)
            .size(withAttributes: [.font: font]).width
        let width = min(inked.rounded(.up) + 4,
                        M.favoriteFrame.minX - M.headerTextX - 8)
        titleLabel.frame = NSRect(x: M.headerTextX, y: M.headerTitleY,
                                  width: max(0, width), height: M.headerTitleHeight)
    }

    // MARK: - 分段控件（sample §3）

    private func buildTabControl() {
        tabControl.segmentCount = M.tabTitles.count
        tabControl.trackingMode = .selectOne
        // 段内文字 13pt regular ＝ `NSFont.systemFontSize` 的默认值，所以**不设 font**。
        for (index, title) in M.tabTitles.enumerated() {
            tabControl.setLabel(title, forSegment: index)
            // [AX] 6 段等宽 94、段间无间隙
            tabControl.setWidth(M.tabSegmentWidth, forSegment: index)
        }
        tabControl.selectedSegment = 0
        tabControl.frame = M.tabGroupFrame
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        root.addSubview(tabControl)
    }

    // MARK: - 内容区

    private func buildContent() {
        // [AX] 四个描述符驱动的 Tab 的滚动区都是 0,159,589,502
        scrollView.frame = NSRect(x: 0, y: M.contentOriginY,
                                  width: M.windowWidth, height: M.contentHeight)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        root.addSubview(scrollView)

        lyricsSpinner.style = .spinning
        lyricsSpinner.isDisplayedWhenStopped = false
        // [AX] 转圈 278.5,394,32,32
        lyricsSpinner.frame = NSRect(x: 278.5, y: 394, width: 32, height: 32)
        root.addSubview(lyricsSpinner)
    }

    /// 切 Tab ＝ 换内容区的 `documentView`（spec §6-2 的复刻建议，也是 Music 自己的做法）。
    private func reloadContent() {
        lyricsTask?.cancel()
        lyricsTask = nil
        fileProbeTask?.cancel()
        fileProbeTask = nil
        lyricsSpinner.stopAnimation(nil)
        artworkDropView = nil

        switch tab {
        case .artwork:
            scrollView.frame = NSRect(x: 0, y: 165, width: M.windowWidth, height: 496)
            scrollView.documentView = makeArtworkView()
        case .lyrics:
            scrollView.frame = NSRect(x: 0, y: M.contentOriginY,
                                      width: M.windowWidth, height: M.contentHeight)
            scrollView.documentView = makeLyricsView()
            loadLyrics()
        default:
            scrollView.frame = NSRect(x: 0, y: M.contentOriginY,
                                      width: M.windowWidth, height: M.contentHeight)
            // 有没有本地文件是**同步**就知道的（问下载索引那一下），
            // 所以行数一开始就定死，不会先摆 8 行再跳成 11 行。
            let fields = InfoPanelTabs.fields(for: tab, hasLocalFile: facts().fileURL != nil)
            scrollView.documentView = InfoPanelFormView(fields: fields, host: self)
            if tab == .file { probeFileFacts() }
        }
        scrollView.contentView.scroll(to: .zero)
        updateFooterSlot()
    }

    /// 异步回调 / 动作回来之后刷新内容区。**不换 `documentView`。**
    ///
    /// 描述符驱动的四个 Tab 一律走「把值写回已有控件」那条
    /// （`InfoPanelFormView.refreshValues`）：正在编辑的文本框、它的 field editor、
    /// 输入法正在组的字、滚动位置全部原样留着（§1 故障 8）。上面那条整块换
    /// `documentView` 的路只留给用户主动切 Tab / 切曲目。
    ///
    /// 只有**行数真的变了**才退回重建：文件页的 `hasLocalFile` 一翻转就多出
    /// 位速率 / 采样速率 / 声道三行、其后各行整体下移，旧控件与新表对不上了。
    /// 今天这一条走不到（`facts().fileURL` 是同步就知道的，探测不改它），
    /// 留着是为了让「什么时候才允许重建」这件事写在代码里。
    private func refreshFormValues() {
        guard tab.isDescriptorDriven else { return }
        let fields = InfoPanelTabs.fields(for: tab, hasLocalFile: facts().fileURL != nil)
        guard let form = scrollView.documentView as? InfoPanelFormView,
              form.describes(fields) else {
            reloadContent()
            return
        }
        form.refreshValues()
    }

    // MARK: 插图页（sample §4.2，交互部分是 [推]）

    /// [AX] 内容区只有一个 `AXScrollArea`（AXTitle「专辑插图」）套一个同名
    /// `AXStaticText`（`66,172,60,19`）——**AX 不暴露拖放区里的图像元素**，
    /// 所以除了那行标题，画廊的几何全是 `[推]`（spec §4.2 明说了）。
    /// 这里做到：显示当前封面、拖图进来、右键移除；底部「添加插图」开 `NSOpenPanel`。
    /// 多图画廊与右下角缩放滑块**没做**——没有任何实测依据可照。
    private func makeArtworkView() -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: M.windowWidth, height: 496))
        let label = NSTextField(labelWithString: "专辑插图")
        label.font = .systemFont(ofSize: M.bodyFontSize)
        label.frame = NSRect(x: 66, y: 172 - 165, width: 60, height: 19)
        container.addSubview(label)

        // [推] 画廊本体的位置与尺寸没有实测值（AX 不暴露拖放区里的图像元素）。
        // **按内容区的宽度铺开**而不是钉死 180×180：那一页除了这块什么都没有，
        // 钉死就成了左上角一枚小方块、右边一大片空白。左右各留 66（与「专辑插图」
        // 那行标题同一左沿，那是实测的 `66,172,60,19`），高度取正方形。
        let side = M.windowWidth - 66 * 2
        let drop = ArtworkDropView(frame: NSRect(x: 66, y: 200 - 165, width: side, height: side))
        drop.onImageData = { [weak self] data in
            self?.draft.artwork = .replace(data)
            self?.refreshArtworkPreview()
        }
        drop.onRemove = { [weak self] in
            self?.draft.artwork = .remove
            self?.refreshArtworkPreview()
        }
        container.addSubview(drop)
        artworkDropView = drop
        refreshArtworkPreview()
        return container
    }

    private func refreshArtworkPreview() {
        let image: NSImage?
        switch draft.artwork {
        case .replace(let data): image = NSImage(data: data)
        case .remove: image = nil
        case nil: image = artworkView.image
        }
        artworkDropView?.image = image
    }

    // MARK: 歌词页（sample §4.3）

    private func makeLyricsView() -> NSView {
        // [AX] AXGroup → AXScrollArea → AXTextArea，frame 21,158,547,482
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: M.windowWidth, height: M.contentHeight))
        let box = NSScrollView(frame: NSRect(x: 21, y: 158 - M.contentOriginY, width: 547, height: 482))
        box.borderType = .noBorder
        box.hasVerticalScroller = true
        box.drawsBackground = false
        lyricsTextView.frame = box.contentView.bounds
        lyricsTextView.autoresizingMask = [.width]
        lyricsTextView.font = .systemFont(ofSize: M.bodyFontSize)
        lyricsTextView.isRichText = false
        lyricsTextView.drawsBackground = false
        lyricsTextView.delegate = self
        box.documentView = lyricsTextView
        container.addSubview(box)
        applyLyricsEditability()
        return container
    }

    private func applyLyricsEditability() {
        let custom = draft.info.customLyrics
        lyricsTextView.isEditable = custom != nil
        lyricsTextView.string = custom ?? providerLyrics
        customLyricsBox.state = custom != nil ? .on : .off
    }

    /// [AX] 首次切进去树里只有一个 `AXBusyIndicator`，约 3 秒后才出`AXTextArea`——
    /// 歌词是异步取的。照它：没缓存就摆一个 `NSProgressIndicator`。
    private func loadLyrics() {
        if draft.info.customLyrics != nil { applyLyricsEditability(); return }
        let current = track
        if let cached = appState.lyricsStore.cachedLyrics(for: current) {
            providerLyrics = Self.plainText(cached)
            applyLyricsEditability()
            return
        }
        providerLyrics = ""
        applyLyricsEditability()
        lyricsSpinner.startAnimation(nil)
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let lines = await appState.lyricsStore.lyrics(for: current,
                                                          using: appState.provider(current.kind))
            guard !Task.isCancelled, self.track.id == current.id else { return }
            self.lyricsSpinner.stopAnimation(nil)
            self.providerLyrics = Self.plainText(lines)
            if self.draft.info.customLyrics == nil { self.applyLyricsEditability() }
        }
    }

    private static func plainText(_ lines: [LyricLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: - 底部（sample §5）

    private func buildFooter() {
        // [AX] 上一个 19,678.5,29,27 / 下一个 45,678.5,29,27 —— **水平重叠 3pt**，
        // 那不是两颗独立按钮的间距，是并排分段控件的画法。所以这里用
        // 一个两段的 NSSegmentedControl（momentary），不是两颗 NSButton。
        navControl.segmentCount = 2
        navControl.trackingMode = .momentary
        navControl.setImage(NSImage(systemSymbolName: "chevron.left",
                                    accessibilityDescription: "上一个"), forSegment: 0)
        navControl.setImage(NSImage(systemSymbolName: "chevron.right",
                                    accessibilityDescription: "下一个"), forSegment: 1)
        navControl.setWidth(M.navSegmentWidth, forSegment: 0)
        navControl.setWidth(M.navSegmentWidth, forSegment: 1)
        navControl.frame = M.navSegmentFrame
        navControl.target = self
        navControl.action = #selector(navigate)
        root.addSubview(navControl)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPanel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"          // Esc（spec §1.1）
        cancel.frame = M.cancelFrame
        root.addSubview(cancel)

        let ok = NSButton(title: "好", target: self, action: #selector(commit))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"                  // Return（spec §1.1）
        ok.frame = M.okFrame
        root.addSubview(ok)

        addArtworkButton.title = "添加插图"
        addArtworkButton.bezelStyle = .rounded
        addArtworkButton.target = self
        addArtworkButton.action = #selector(addArtwork)
        addArtworkButton.frame = M.addArtworkFrame
        root.addSubview(addArtworkButton)

        customLyricsBox.setButtonType(.switch)
        customLyricsBox.title = "自定义歌词"
        customLyricsBox.target = self
        customLyricsBox.action = #selector(toggleCustomLyrics)
        customLyricsBox.frame = M.customLyricsFrame
        root.addSubview(customLyricsBox)

        updateFooterSlot()
    }

    private func updateFooterSlot() {
        addArtworkButton.isHidden = tab != .artwork
        customLyricsBox.isHidden = tab != .lyrics
        // 单选且只有一首时前后都走不动
        navControl.setEnabled(nav.canGoPrevious, forSegment: 0)
        navControl.setEnabled(nav.canGoNext, forSegment: 1)
    }

    // MARK: - 换曲目

    private func reloadTrack() {
        let current = track
        titleLabel.stringValue = draft.info.title.isEmpty ? current.title : draft.info.title
        artistLabel.stringValue = draft.info.artist.isEmpty ? current.artistName : draft.info.artist
        albumLabel.stringValue = draft.info.album.isEmpty ? current.albumName : draft.info.album
        layoutHeaderTitle()
        updateFavoriteButton()
        artworkView.image = ImageCache.shared.memoryCachedImage(for: current.artworkURL)
        if artworkView.image == nil {
            let url = current.artworkURL
            Task { [weak self] in
                let image = await ImageCache.shared.image(for: url)
                guard let self, self.track.artworkURL == url else { return }
                self.artworkView.image = image
                self.refreshArtworkPreview()
            }
        }
        reloadContent()
        probeGenreIfNeeded()
    }

    /// 「类型」空着时去音源要一次曲目级流派。
    ///
    /// 三层取值，逐层往下：① 用户编辑过的那份（`TrackInfo.genre`）；② 资料库里所属专辑的
    /// 流派（`LibraryStore.genre(for:)`，开面板时就填好了）；③ 音源的曲目级流派
    /// （`MusicProvider.trackGenre`，QQ 走歌曲详情、网易云回落到专辑 tags，两条都带缓存）。
    ///
    /// **只回填、不覆盖**：回来时用户已经自己填过了就不动他的值；曲目已经切走了也不动
    /// （面板上「上一个 / 下一个」走得比请求快是常事）。问到空也记一笔，免得每次
    /// `reloadTrack` 都再发一次。
    private func probeGenreIfNeeded() {
        let current = track
        guard draft.info.genre.isEmpty, !genreProbed.contains(current.id) else { return }
        genreProbed.insert(current.id)
        genreTask?.cancel()
        genreTask = Task { [weak self] in
            guard let provider = self?.appState.provider(current.kind) else { return }
            let genre = await provider.trackGenre(current)
            guard let self, !Task.isCancelled, let genre, !genre.isEmpty,
                  self.track.id == current.id, self.draft.info.genre.isEmpty else { return }
            self.draft.info.genre = genre
            self.book.keep(self.draft, for: current.id)
            // 「类型」那一格就在详细信息页上，别的页没什么可刷。
            if self.tab == .details { self.refreshFormValues() }
        }
    }

    private func updateFavoriteButton() {
        let on = draft.isFavorite
        // [资源] 四态切片 `InfoPanelRatingLoveLiked` / `Disliked` / `Unliked` / `Mixed`。
        // Amber 的资料库只有「心水 / 非心水」两态，所以只用到其中两态；
        // Mixed 是多选态的（本批不做）。已喜爱实心星 [PX] #FA2F47 ＝ 品牌红。
        favoriteButton.image = NSImage(systemSymbolName: on ? "star.fill" : "star",
                                       accessibilityDescription: on ? "已喜爱" : "喜爱")
        favoriteButton.contentTintColor = on ? .amberKey : .secondaryLabelColor
        favoriteButton.toolTip = on ? "已喜爱" : "喜爱"
    }

    /// 切上一个 / 下一个之前，把当前这一首的草稿收进草稿簿——
    /// 走回来时还是刚才编到一半的样子（文本框是边打边进草稿的，不用再收一次尾）。
    private func move(by delta: Int) {
        book.keep(draft, for: track.id)
        guard nav.move(by: delta) else { return }
        let next = track
        if let saved = book.draft(for: next.id) {
            draft = saved
        } else {
            let fresh = InfoPanelDraft(info: Self.info(for: next, library: appState.library),
                                       rating: appState.library.rating(for: next.id),
                                       isFavorite: appState.library.isFavorite(next))
            book.start(fresh, for: next.id)
            draft = fresh
        }
        reloadTrack()
    }

    #if DEBUG
    /// 实机自证用（`-getinfo … -tab N`，见`AppDelegate.applyDebugLaunchArguments`）：
    /// 分段控件要点一下才换页，而实机验收驱动不了鼠标（见 AGENTS）。
    func debugSelectTab(_ index: Int) {
        guard InfoPanelTabs.Tab(rawValue: index) != nil else { return }
        tabControl.selectedSegment = index
        tabChanged()
    }
    #endif

    // MARK: - 动作

    @objc private func tabChanged() {
        guard let next = InfoPanelTabs.Tab(rawValue: tabControl.selectedSegment) else { return }
        tab = next
        reloadContent()
    }

    @objc private func navigate() {
        move(by: navControl.selectedSegment == 0 ? -1 : 1)
    }

    @objc private func toggleFavorite() {
        draft.isFavorite.toggle()
        updateFavoriteButton()
    }

    @objc private func cancelPanel() {
        // 全丢：草稿从头到尾没往任何 store 写过一笔，所以「丢」就是不提交。
        book.discardAll()
        close()
    }

    /// 关窗时把三条在飞的异步都停掉（取词、探文件、问流派）：窗都没了，回填给谁看。
    func windowWillClose(_ notification: Notification) {
        lyricsTask?.cancel()
        fileProbeTask?.cancel()
        genreTask?.cancel()
    }

    /// 「好」＝一次性提交。三处：`TrackInfoStore.update`（含写回 Track 本体那几项）、
    /// 评分、喜爱。只提交**真的改过**的那几样（对着 `initial` 比）。
    @objc private func commit() {
        book.keep(draft, for: track.id)
        let pending = book.pending()
        for candidate in tracks {
            guard let edited = pending[candidate.id] else { continue }
            apply(edited, to: candidate)
        }
        close()
    }

    private func apply(_ edited: InfoPanelDraft, to target: Track) {
        let library = appState.library
        // `TrackInfoStore.update` 自己会与`info(for:)` 比，一致就什么都不做。
        TrackInfoStore.shared.update(edited.info, for: target, library: library)
        if edited.rating != library.rating(for: target.id) {
            library.setRating(edited.rating, for: target.id)
        }
        if edited.isFavorite != library.isFavorite(target) {
            library.toggleFavorite(target)
        }
        switch edited.artwork {
        case .replace(let data):
            // 落到既有的那个封面目录（`ImportService` 本来就往这儿写内嵌封面），
            // 不新开一处。**在线曲目只改 `Track.artworkURL`**；写回本地文件的标签
            // 是另一件事（`AudioTagWriter` 那一族），不在这一批里做。
            if let url = ImportWorker.writeArtwork(data, id: target.id,
                                                   folder: ImportService.defaultArtworkFolder) {
                _ = library.updateTrack(id: target.id) { $0.artworkURL = url.absoluteString }
            }
        case .remove:
            _ = library.updateTrack(id: target.id) { $0.artworkURL = nil }
        case nil:
            break
        }
    }

    @objc private func addArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            self?.draft.artwork = .replace(data)
            self?.refreshArtworkPreview()
        }
    }

    /// [RES] 取消勾选要二次确认，文案是 spec §4.3 的实测串。
    @objc private func toggleCustomLyrics() {
        if customLyricsBox.state == .on {
            draft.info.customLyrics = providerLyrics
            applyLyricsEditability()
            return
        }
        let alert = NSAlert()
        alert.messageText = "确定要移除自定义歌词吗？"
        alert.informativeText = "关闭自定义歌词将移除这首歌曲中的自定义歌词。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.draft.info.customLyrics = nil
            }
            self.applyLyricsEditability()
        }
    }

    /// [spec §1.1] ⌘← / ⌘→ ＝ 上一个 / 下一个。Esc 与 Return 由两颗按钮的
    /// `keyEquivalent` 接（那是 AppKit 自己的路，不用在这儿再判一次）。
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!):
            move(by: -1); return true
        case String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!):
            move(by: 1); return true
        default:
            return false
        }
    }

    // MARK: - InfoPanelFormHost

    func readOnlyText(_ field: InfoPanelReadOnlyField) -> String {
        facts().text(for: field)
    }

    func pathComponents() -> [String] {
        facts().pathComponents()
    }

    /// 当前这首的只读事实。异步读回来的那两样（文件规格、云端字节数）从缓存里带上，
    /// 没读到就是 nil，对应的格子空着。
    private func facts() -> InfoPanelFacts {
        InfoPanelFacts(track: track, library: appState.library,
                       downloads: appState.downloads,
                       file: fileFacts[track.id],
                       cloudBytes: cloudBytes[track.id])
    }

    /// 文件页露面时才去读文件 / 探云端大小，读完把这一页重建一次填上值。
    ///
    /// 两件事都**只做一次**（按曲目 id 缓存），也都**只在文件页**做——
    /// 别的页用不上这些值，没必要为了一格只读文本去开销解析和网络。
    private func probeFileFacts() {
        let current = track
        let url = facts().fileURL
        // 都在手上了就不用再动
        if url != nil ? (fileFacts[current.id] != nil) : (cloudBytes[current.id] != nil) { return }
        // 云端曲目：本机导入的那种（`local:` 前缀）没有音源可问，直接算探过了
        if url == nil, current.isLocal {
            cloudBytes[current.id] = 0
            return
        }
        let provider = url == nil ? appState.provider(current.kind) : nil
        fileProbeTask = Task { [weak self] in
            var read: InfoPanelFileFacts?
            var bytes: Int?
            if let url {
                read = await InfoPanelFileFacts.read(url)
            } else if let provider {
                bytes = await InfoPanelFacts.cloudByteCount(of: current) {
                    try await provider.trackStreamURL(track: $0)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if let read { self.fileFacts[current.id] = read }
            if let bytes { self.cloudBytes[current.id] = bytes }
            // 面板这会儿可能已经翻到别的曲目 / 别的页了，那就只留着缓存，不动界面
            guard self.track.id == current.id, self.tab == .file else { return }
            self.refreshFormValues()
        }
    }

    /// 「类型」组合框的候选：**用户资料库里真实出现过的流派**，去重后按字母序。
    ///
    /// Music 那份候选表 AX 不可达（sample §4.7），与其编一份假的，不如让本机的事实说话
    /// ——用户库里已经有的流派正是他最可能再填的那几个。当前值不在库里时补进去，
    /// 免得下拉里看不见自己刚填的那条。
    func genreOptions() -> [String] {
        var seen = Set<String>()
        for album in appState.library.libraryAlbums {
            if let genre = album.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
               !genre.isEmpty { seen.insert(genre) }
        }
        let current = draft.info.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { seen.insert(current) }
        return seen.sorted()
    }

    func perform(_ action: InfoPanelFieldAction) {
        switch action {
        case .resetPlayCount:
            // 当场生效，不进草稿：Music 这颗按钮按下去就清了，「取消」也收不回来
            // `[推]`——`InfoPanelFooterViewController` 一个方法都没定性过
            //（getinfo spec §7 缺口 #5），但它与其它字段的差别是明摆着的：
            // 别的字段是「改一个值」，它是一条动作，摆在字段行外面。
            appState.library.resetPlayCount(for: track.id)
            refreshFormValues()
        }
    }

    func isEnabled(_ action: InfoPanelFieldAction) -> Bool {
        switch action {
        // 没播过就没什么可重设的
        case .resetPlayCount: return appState.library.playCount(for: track.id) > 0
        }
    }

    func formValuesDidChange() { refreshFormValues() }
}

// MARK: - 歌词文本域回写

extension InfoPanelWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === lyricsTextView, draft.info.customLyrics != nil else { return }
        draft.info.customLyrics = textView.string
    }
}

// MARK: - 小件

/// y 向下的容器。实测坐标全是窗口左上角为原点，翻一次就不用每处再减一遍。
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// [PX] 头部那一块比内容区亮一档（#323233 vs #29292A）——整扇窗唯一一条自家色 token。
private final class HeaderView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.amberInfoPanelHeader.setFill()
        bounds.fill()
    }
}

/// 插图页的拖放区。[推]：AX 不暴露内部元素，行为照 spec §4.2 的描述做
/// （从访达拖图进来、`InfoPanelAlbumArtDrag` 那张占位图的语义）。
private final class ArtworkDropView: NSView {
    var onImageData: ((Data) -> Void)?
    var onRemove: (() -> Void)?
    var image: NSImage? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "移除插图", action: #selector(remove), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)

        guard let image, image.size.width > 0, image.size.height > 0 else {
            // 没有插图：画一个空框当拖放靶子
            NSColor.separatorColor.setStroke()
            border.lineWidth = 1
            border.stroke()
            return
        }

        // **按比例贴合、居中，再用圆角裁掉**——从前是 `draw(in: bounds)`，那是拉伸填充：
        // 非正方形的封面会被压扁，而边框还留在原处，看着就是「图没跟着框走」。
        let scale = min(frame.width / image.size.width, frame.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: target, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
        // 边框贴着图本身走，不是贴着那个方框
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        outline.lineWidth = 1
        outline.stroke()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        data(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = data(from: sender) else { return false }
        onImageData?(payload)
        return true
    }

    private func data(from sender: any NSDraggingInfo) -> Data? {
        let board = sender.draggingPasteboard
        if let url = NSURL(from: board) as URL?,
           let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image) {
            return try? Data(contentsOf: url)
        }
        if let image = NSImage(pasteboard: board) { return image.tiffRepresentation }
        return nil
    }

    @objc private func remove() { image = nil; onRemove?() }
}

// MARK: - 文件页那几条只读事实

/// 文件页（Tab 5）与详细信息页「播放次数」那一行的值，全是现算的，不进草稿。
///
/// 值的口径尽量对上实测样本（sample §4.6：`无损音频` / `2:40` / `17 MB` /
/// `2026/9/7 20:26` / `Apple Music`）；Amber 没有的项按 Amber 自己的事实说。
struct InfoPanelFacts {
    let track: Track
    let library: LibraryStore
    let downloads: DownloadStore
    /// 真读那份文件读回来的东西（异步，见 `InfoPanelFileFacts`）。
    /// 还没读完时是 nil，那几格先空着，读完宿主重建这一页再填上。
    var file: InfoPanelFileFacts?
    /// 云端曲目（本机没有文件）探到的字节数。0 = 探过但没拿到，nil = 还没探。
    var cloudBytes: Int?

    /// 曲目落地在本机的那份文件。本地性只有下载索引一处回答。
    @MainActor
    var fileURL: URL? { downloads.fileURL(for: track.id) }

    @MainActor
    func text(for field: InfoPanelReadOnlyField) -> String {
        switch field {
        case .playCount:
            // [AX] 实测是拼好的整句：`4 （上次播放时间：星期四 17:25）`
            let count = library.playCount(for: track.id)
            guard let last = library.lastPlayedAt[track.id] else { return "\(count)" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "EEEE HH:mm"
            return "\(count) （上次播放时间：\(formatter.string(from: last))）"
        case .kind:
            return kindText
        case .duration:
            // 有文件就报**文件里的**时长（`AVURLAsset` 解出来的那个），不报音源给的
            // `Track.duration`——两者会差（音源的时长是编辑填的，剪过的文件更是对不上），
            // 而这一页说的是「这份文件是什么」。云端没有文件，才回落到音源那一个。
            if fileURL != nil {
                guard let seconds = file?.duration else { return "" }
                return InfoPanelFormView.timeString(seconds.rounded())
            }
            return InfoPanelFormView.timeString(track.duration.rounded())
        case .size:
            // 本地文件：直接读文件属性，这条最准，同步就能拿到。
            if let url = fileURL,
               let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }
            // 云端曲目：宿主异步探回来的那个数（见 `InfoPanelFacts.cloudByteCount`）。
            guard let bytes = cloudBytes, bytes > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        case .bitRate:
            // [RES] 185/8 `%S kbps`。无损档这个数也有意义（Music 自己也显示），
            // 所以不像音质气泡那样只给有损档看。
            guard let rate = file?.format?.dataRate, rate > 0 else { return "" }
            return "\(Int((rate / 1000).rounded())) kbps"
        case .sampleRate:
            // [RES] 185/7 `%S kHz`；spec §4.6 的样例是`44.100 kHz` / `48.000 kHz`
            // / `96.000 kHz`，即固定三位小数。
            guard let rate = file?.format?.sampleRate, rate > 0 else { return "" }
            // 采样率是整数赫兹，「固定三位小数的 kHz」就是从右边数三位点一刀：
            // 44100 → `44.100`。这样既躲开 `String(format:)` 的可变参数（strict memory
            // safety 判它不安全），也不经过 locale——`%.3f` 从前也不看 locale。
            let hz = Int(rate.rounded())
            return "\(hz / 1000).\((hz % 1000).zeroPadded(to: 3)) kHz"
        case .channels:
            // [RES] 185/4「单声道」、185/5「立体声」；多声道那条 [RES] 5002/23。
            // spec §4.6 写的就是「立体声 / 多声道」这个口径，不报具体声道数。
            guard let count = file?.format?.channels, count > 0 else { return "" }
            switch count {
            case 1: return "单声道"
            case 2: return "立体声"
            default: return "多声道"
            }
        case .dateModified:
            guard let url = fileURL,
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate
            else { return "" }
            return Self.stamp(date)
        case .dateAdded:
            guard let date = library.addedAt[track.id] else { return "" }
            return Self.stamp(date)
        case .cloudStatus:
            // Music 这一格填的是曲目的来源（样本上是 `Apple Music`）。
            if track.isLocal { return "本机文件" }
            if downloads.isDownloaded(track.id) { return "\(track.kind.displayName)（已下载）" }
            return track.kind.displayName
        case .copyright:
            // 本地文件从标签里读（`©cpy` / `TCOP` / Vorbis `COPYRIGHT`，见
            // `InfoPanelFileFacts.copyright`）。
            // [缺口] 云端曲目**留空**：`Track` 没有版权字段，两家音源的曲目接口也不给
            // 版权声明。QQ 的歌曲详情有个 `company`（唱片公司），但那是发行方不是
            // `℗ …` 那句版权声明，填进来就是拿一件事冒充另一件事——宁可空着。
            return file?.copyright ?? ""
        }
    }

    /// 种类。
    ///
    /// **有文件就按文件里真实的 `formatID` 说**，不按扩展名猜——扩展名是可以骗人的
    /// （`.m4a` 里装的可能是 ALAC 也可能是 AAC，改个后缀更是一秒的事）。
    /// 文案照 [RES] 3301 那张种类表（Music 自己的措辞，注意「音频文件」前不带空格）。
    @MainActor
    private var kindText: String {
        guard let url = fileURL else {
            // 云端曲目：没有文件可读。
            //
            // **不能只看 `losslessAvailable`**：那一位说的是「音源**有**无损档」，
            // 不是「这个账号此刻**取得到**无损档」——两者常常对不上（会员过期、
            // 偏好选的就是有损档）。实机上撞见过一次自相矛盾的显示：
            // 「无损音频」配 4:02 / 9.7 MB，折回去才 320 kbps。
            //
            // 所以有了探到的大小就用它算平均码率来判：那是**实际会拿到的那一档**
            // （大小正是对着实际取流地址探的，见 `cloudByteCount`）。
            // 700 kbps 这条线取在有损档的天花板（320）与 CD 无损的地板（约 900）之间，
            // 两边都留足余量。`[推]`——Music 怎么判这一格没有实测证据。
            if let bytes = cloudBytes, bytes > 0, track.duration > 1 {
                let kbps = Double(bytes) * 8 / track.duration / 1000
                if kbps >= 700 { return "无损音频" }                    // [RES] 241/212
                return "\(Int(kbps.rounded())) kbps 音频"
            }
            // 还没探到（刚打开 / 探失败）：只说音源那一位，措辞照实测样本
            // （[RES] 241/212「无损音频」= spec §4.6 的无损徽标）。
            return (track.losslessAvailable == true) ? "无损音频" : "在线曲目"
        }
        // 还没解出来（面板刚打开的头一瞬）：宁可空着，也不先摆一个按扩展名猜的值
        // 再跳变成另一个。
        guard let format = file?.format else { return "" }
        switch format.formatID {
        case kAudioFormatAppleLossless:
            return "Apple保真压缩音频文件"                 // [RES] 3301/21
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_Spatial:
            return "AAC音频文件"                          // [RES] 3301/12
        case kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3:
            return "MPEG音频文件"                         // [RES] 3301/33
        case kAudioFormatLinearPCM:
            // 同一种编码、两个容器，只有靠容器分——这一处用扩展名是分容器不是猜编码。
            return ["aif", "aiff", "aifc"].contains(url.pathExtension.lowercased())
                ? "AIFF音频文件"                          // [RES] 3301/35
                : "WAV音频文件"                           // [RES] 3301/36
        default:
            // FLAC / Opus 这些 Music 资源表里没有对应串（它自己不放这些格式），
            // 照 3301 的构词自拟：`FLAC音频文件`。
            return StreamFormat.codecName(format.formatID) + "音频文件"
        }
    }

    /// [AX] 面包屑实测是 `changlepan / 音乐 / Music / 媒体 / Apple Music`：
    /// **是所在文件夹的各段、不含文件名，也不含开头的 `/` 与`Users`**，
    /// 而且每段取的是本地化显示名（`Music` 那层显示成「音乐」）。
    @MainActor
    func pathComponents() -> [String] {
        guard let url = fileURL else { return [] }
        var components = url.deletingLastPathComponent().pathComponents
        if components.first == "/" { components.removeFirst() }
        if components.first == "Users" { components.removeFirst() }
        var prefix = URL(fileURLWithPath: "/")
        var walked: [String] = []
        for raw in url.deletingLastPathComponent().pathComponents where raw != "/" {
            prefix.appendPathComponent(raw)
            walked.append(FileManager.default.displayName(atPath: prefix.path))
        }
        // 与上面的裁剪对齐：显示名那一串也要丢掉 `Users`
        if walked.count > components.count {
            walked.removeFirst(walked.count - components.count)
        }
        return walked
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 真读那份文件

/// 文件页里**只有打开文件才知道**的那几项：真实格式、文件里的时长、标签里的版权。
///
/// 全部经 `AVURLAsset` 解析，**必须在主线程之外 await**（一份 FLAC 的解析在慢盘上
/// 是几十毫秒起步，摆在主线程上就是面板一打开先卡一下）。
/// 拿不到就留 nil，对应的格子空着——不猜、不回落到「按扩展名说」。
struct InfoPanelFileFacts: Sendable {
    /// 音轨的真实规格。`StreamFormat.read(from url:)` 读的是格式描述，
    /// 与迷你播放器那颗音质气泡同一份模型、同一条路子。
    var format: StreamFormat?
    /// 文件里的时长（秒）
    var duration: TimeInterval?
    /// 标签里的版权声明
    var copyright: String?

    static func read(_ url: URL) async -> InfoPanelFileFacts {
        let asset = AVURLAsset(url: url)
        var facts = InfoPanelFileFacts()
        facts.format = await StreamFormat.read(from: asset)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            facts.duration = duration.seconds
        }
        facts.copyright = await Self.copyright(of: asset)
        return facts
    }

    /// 版权标签。三种容器三套键，一次全试：
    /// - MP4 / M4A：iTunes 的 `©cpy`（`.iTunesMetadataCopyright`）
    /// - MP3：ID3 的 `TCOP`（`.id3MetadataCopyright`）
    /// - FLAC：Vorbis 注释的 `COPYRIGHT`
    ///
    /// 前两套 AVFoundation 有现成的标识符，Vorbis 那套它不一定认（Amber 自己写的 FLAC
    /// 还前置了一段 ID3，一旦有 ID3 AVFoundation 就不再吐 Vorbis 了），
    /// 所以最后再按键名兜一道底。
    private static func copyright(of asset: AVURLAsset) async -> String? {
        var items = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        guard !items.isEmpty else { return nil }
        let identifiers: [AVMetadataIdentifier] = [
            .commonIdentifierCopyrights, .iTunesMetadataCopyright,
            .id3MetadataCopyright, .quickTimeMetadataCopyright,
        ]
        var candidates = identifiers.flatMap {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: $0)
        }
        // Vorbis `COPYRIGHT` 走不到上面那几个标识符，按键名再捞一遍
        candidates += items.filter {
            ($0.key as? String)?.uppercased() == "COPYRIGHT"
        }
        for item in candidates {
            if let text = try? await item.load(.stringValue),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

extension InfoPanelFacts {
    /// 云端曲目（本机没有文件）那一格「大小」的来源。
    ///
    /// **走的是「实际会拿到的那一份流有多大」，不是「偏好里选了哪一档」。**
    /// 先按播放那条路解出可播地址（`trackStreamURL`，档位、降级、会员权限的账
    /// 全由音源那边算完了），再对这个地址要一次 `Range: bytes=0-0`，从
    /// `Content-Range` 的总长度读字节数。这样拿到的就是这个账号此刻真能取到的那一档。
    ///
    /// 为什么不走别的路：
    /// - `Track` 上没有大小字段，音源的曲目 JSON 里那几个`size`（网易`sq`/`hr`/…、
    ///   QQ `file.size_*`）现有解析**只用来判有没有无损档，数值当场丢掉了**，
    ///   捡回来要动音源层，超出这次的改动范围；
    /// - 网易有一条现成的 `songQualityDetail(songID:)` 能给每档的字节数，但它答的是
    ///   「这首歌**存在**哪些档」而不是「你**拿得到**哪一档」（那份接口注释自己写明了），
    ///   而且 QQ 那边没有对等的现成方法，两家会一家有一家没有；
    /// - 已下载的曲目根本不走这条——上面 `.size` 那一支直接读落盘文件，最准。
    ///
    /// 这是一条**为了一个只读字段新开的网络链路**，所以：只在文件页真的露面时才发，
    /// 每首只探一次（宿主按曲目 id 缓存），**失败一律留空**，绝不弹错、绝不阻塞面板。
    static func cloudByteCount(of track: Track,
                               resolve: (Track) async throws -> URL) async -> Int {
        guard let url = try? await resolve(track) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 只要第一个字节：服务端答 206 时 `Content-Range: bytes 0-0/<总长>`。
        // 用 `bytes(for:)` 而不是`data(for:)`——前者拿到响应头就能收手，
        // 万一服务端不认 Range 直接回 200，也不会把整首歌拖下来。
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse else { return 0 }
        stream.task.cancel()
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let bytes = Int(total) {
            return bytes
        }
        // 服务端忽略了 Range（回 200）：此时 Content-Length 就是整份的长度
        if http.statusCode == 200, http.expectedContentLength > 0 {
            return Int(http.expectedContentLength)
        }
        return 0
    }
}
