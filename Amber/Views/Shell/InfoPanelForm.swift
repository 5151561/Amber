import AppKit

/// 「显示简介」面板的**描述符 + 构建器**。
///
/// 形状照 Music 自己的：`InfoPanelDetailsViewController` 不给每个 Tab 手写布局，
/// 而是解释一张 `DetailItemDescriptor` 数组动态建控件（behavior spec §1.3 列了
/// 25 种 `InfoPanelDetailItem…View`）。这里是同一件事的 AppKit 版——
/// `InfoPanelTabs` 出六张`[InfoPanelField]`，`InfoPanelFormView` 把表变成控件树。
/// 以后补「媒体种类 × Tab」的变体只是多几张表，不是多几份布局代码。
///
/// **坐标一律是窗口坐标、y 向下**（`getinfo 样本` 的实测原样）。
/// 表单视图 `isFlipped = true`，摆放时只减一个内容区原点`contentOriginY`。
/// 为什么不按「行序 + 组间距」反推：实测的行距是 25 / 26 / 36 / 37 混着走的，
/// 反推必错——这个面板的规格**就是**绝对坐标。

// MARK: - 草稿

/// 面板全程编辑的这一份。点「好」才一次性提交，点「取消」全丢。
/// 对应 Music 的双适配器（spec §1.2 `mITTrackInfoAdapter` /
/// `mInitialValuesITTrackInfoAdapter`）：`InfoPanelWindowController` 同时留着
/// 初始值那一份，用来判断到底改没改。
struct InfoPanelDraft: Equatable {
    /// 契约里那一份（`Amber/Services/TrackInfoStore.swift`，批次 A 实现）
    var info: TrackInfo
    /// 评分与喜爱不在 `TrackInfo` 里——它们是`LibraryStore` 的东西，
    /// 但面板上跟其它字段一样要攒到「好」才写，所以一起进草稿。
    var rating: Int = 0
    var isFavorite: Bool = false
    /// 插图页的改动。nil = 没动过。
    var artwork: ArtworkEdit? = nil

    enum ArtworkEdit: Equatable {
        case replace(Data)
        case remove
    }
}

// MARK: - 描述符

/// 只读字段的取值来源。值不在草稿里，由宿主现算（文件属性 / 资料库统计）。
enum InfoPanelReadOnlyField: Equatable {
    /// [AX] 详细信息页 ITID 22：拼好的整句 `4 （上次播放时间：星期四 17:25）`，不是两个字段
    case playCount
    case kind, duration, size, dateModified, dateAdded, cloudStatus, copyright
    /// [RES] 241 里成套的三条（45 `bit rate` / 46 `sample rate` / 111 `channels`，
    /// zh_CN 作「位速率」「采样速率」「声道」），**只在有本地文件时才出现**——
    /// 实测那份样本是 Apple Music 云端曲目，云端曲目上没有这三行。
    case bitRate, sampleRate, channels
}

/// 弹出菜单的取值域。两条都是 [AX] 实测（sample §4.7）。
enum InfoPanelPopUpKind: Equatable {
    /// [AX] 本次样本（Apple Music 云端曲目）上只有当前值一项；
    /// 本地文件的完整选项集未采（sample §9 #3）。这里给 `MediaKind.allCases` 全集。
    case mediaKind
    /// [AX] 24 项，首项后一条分隔线
    case equalizer
}

/// 时间输入框绑的是哪一头。开始是非可选，停止可选（nil = 用曲目原时长）。
enum InfoPanelTimeKind: Equatable { case start, stop }

/// 字段上挂的动作（不改草稿，交给宿主办）。
enum InfoPanelFieldAction: Equatable { case resetPlayCount }

/// 一件字段控件。frame 全是实测绝对坐标。
///
/// `Equatable` 是给 `InfoPanelFormView.describes(_:)` 用的：异步回调回来时要先问
/// 「现在这张表单描述的还是同一组行吗」，是就只回写值、不重建（见 `refreshValues`）。
enum InfoPanelControl: Equatable {
    /// 单行文本框
    case text(NSRect, key: WritableKeyPath<InfoPanelDraft, String>)
    /// 数字输入框（年份 / bpm）
    case number(NSRect, key: WritableKeyPath<InfoPanelDraft, Int?>)
    /// 两个数字夹一个「/」（音轨、光盘编号）
    case numberPair(first: NSRect, second: NSRect, secondITID: Int,
                    slash: NSRect,
                    firstKey: WritableKeyPath<InfoPanelDraft, Int?>,
                    secondKey: WritableKeyPath<InfoPanelDraft, Int?>)
    /// 勾选框（标题写在框右边）
    case checkBox(NSRect, title: String, key: WritableKeyPath<InfoPanelDraft, Bool>)
    /// 组合框（类型 / 流派）
    case comboBox(NSRect, key: WritableKeyPath<InfoPanelDraft, String>)
    /// 弹出菜单
    case popUp(NSRect, kind: InfoPanelPopUpKind)
    /// 勾选框 + 时间输入框（开始 / 停止）
    case timeToggle(check: NSRect, checkITID: Int, field: NSRect,
                    enabledKey: WritableKeyPath<InfoPanelDraft, Bool>,
                    time: InfoPanelTimeKind)
    /// 滑块（音量调整）
    case slider(NSRect, key: WritableKeyPath<InfoPanelDraft, Int>)
    /// 评分（0…5 整星）
    case rating(NSRect)
    /// 多行文本域（注释）
    case textArea(NSRect, key: WritableKeyPath<InfoPanelDraft, String>)
    /// 详细信息页首行：**没有静态标签**，标签位是一个弹出菜单
    /// （[AX] ITID 65534，实测只有「标题」/「作品名称」两项）
    case firstField(popUp: NSRect, field: NSRect)
    /// 只读文本（文件页全体 + 详细信息页的播放次数）
    case readOnly(NSRect, InfoPanelReadOnlyField)
    /// 只读文本 + 右边一颗按钮（播放次数 + 「重设」）
    case readOnlyWithButton(NSRect, InfoPanelReadOnlyField,
                            button: NSRect, title: String, action: InfoPanelFieldAction)
    /// 路径面包屑（文件页「位置」）。[AX] 是 `AXList` 里逐段`AXStaticText`，不是一行文本。
    case pathBreadcrumb(NSRect)
}

/// 表里的一行。
struct InfoPanelField: Equatable {
    /// 标签文案。nil ＝ 这一行没有静态标签（详细信息页首行）。
    var label: String?
    /// [AX] 标签自己的 y（与控件 y 不一定相等，实测常差 3~4pt）
    var labelY: CGFloat?
    /// [AX] `AXIdentifier` 里那个`ITID:<十进制>`，Music 内部字段编号在 AX 层的直接暴露。
    /// 单测拿它与实测表逐条对。nil ＝ 实测里这一行没有 ITID（路径面包屑）。
    var itid: Int?
    var control: InfoPanelControl

    /// 主控件的 frame（单测用它对实测 y）
    var controlFrame: NSRect {
        switch control {
        case let .text(f, _), let .number(f, _), let .checkBox(f, _, _),
             let .comboBox(f, _), let .popUp(f, _), let .slider(f, _),
             let .rating(f), let .textArea(f, _), let .readOnly(f, _),
             let .pathBreadcrumb(f):
            return f
        case let .numberPair(f, _, _, _, _, _): return f
        case let .timeToggle(_, _, f, _, _): return f
        case let .firstField(_, f): return f
        case let .readOnlyWithButton(f, _, _, _, _): return f
        }
    }
}

// MARK: - 宿主

@MainActor
protocol InfoPanelFormHost: AnyObject {
    var draft: InfoPanelDraft { get set }
    /// 只读字段现算
    func readOnlyText(_ field: InfoPanelReadOnlyField) -> String
    /// 路径面包屑的各段（已本地化显示名）
    func pathComponents() -> [String]
    /// 「类型」组合框的候选流派
    func genreOptions() -> [String]
    func perform(_ action: InfoPanelFieldAction)
    /// 动作办不办得到（办不到就把按钮置灰，而不是摆一颗按了没反应的键）
    func isEnabled(_ action: InfoPanelFieldAction) -> Bool
    /// 表单里的值可能已经与草稿对不上了，请宿主刷新一遍。
    /// **不是「重建」**：宿主走的是「把值写回已有控件」那条（`InfoPanelFormView.refreshValues`），
    /// 只有行数真变了才退回整块换 `documentView`。
    func formValuesDidChange()
}

// MARK: - 构建器

/// 把一张 `[InfoPanelField]` 变成控件树。全 AppKit、全标准控件——
/// 项目里那条经验（`am-table-cell-controls-not-custom-draw`）反过来也成立：
/// 看着像系统控件的就用系统控件，`controlSize` / frame 调尺寸，不自绘。
@MainActor
final class InfoPanelFormView: NSView {

    private typealias M = MusicMetrics.InfoPanel

    /// tag 编码：`index * 10 + slot`。slot 0 = 主控件、1 = 副控件（数对的第二格、
    /// 时间行的勾选框）。字段数远小于 100，够用。
    private static let slotBase = 10

    private let fields: [InfoPanelField]
    private weak var host: (any InfoPanelFormHost)?
    /// 反查用：控件 → 字段序号，`controlTextDidChange` 那条路要用
    private var textViewFields: [ObjectIdentifier: Int] = [:]
    /// 已装上的控件，键沿用 tag 那套编码（`index * slotBase + slot`）：
    /// slot 0 = 主控件，slot 1 = 副控件（数对的第二格、时间行的勾选框、
    /// 首行那颗弹出菜单、播放次数右边的「重设」）。
    ///
    /// `refreshValues()` 按它定位要回写的那一件——**不靠 `viewWithTag`**：
    /// 静态标签、数对中间那条「/」、只读格都不设 tag（默认 0），
    /// 会跟 0 号字段的主控件撞上；而按钮那两件的 tag 本来就只带 index、不带 slot。
    private var installed: [Int: NSView] = [:]

    override var isFlipped: Bool { true }

    init(fields: [InfoPanelField], host: any InfoPanelFormHost) {
        self.fields = fields
        self.host = host
        // 文档视图至少铺满可视区；内容更长时按最后一件控件的下沿加一点留白。
        let bottom = fields.map { $0.controlFrame.maxY }.max() ?? M.contentOriginY
        let height = max(M.contentHeight,
                         bottom - M.contentOriginY + M.contentBottomPadding)
        super.init(frame: NSRect(x: 0, y: 0, width: M.windowWidth, height: height))
        for (index, field) in fields.enumerated() { install(field, at: index) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 摆放

    /// 实测 y 是窗口坐标；表单视图的原点在内容滚动区的左上角。
    private func place(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY - M.contentOriginY,
               width: rect.width, height: rect.height)
    }

    private static var bodyFont: NSFont { .systemFont(ofSize: M.bodyFontSize) }

    private func install(_ field: InfoPanelField, at index: Int) {
        if let text = field.label, let y = field.labelY {
            // [AX] 标签列 x=25 w=86，**右对齐贴到 x=111**；次文本灰、14pt regular
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.font = Self.bodyFont
            label.textColor = .secondaryLabelColor
            label.frame = place(NSRect(x: M.labelX, y: y,
                                       width: M.labelWidth, height: M.labelHeight))
            addSubview(label)
        }
        switch field.control {
        case let .text(frame, key):
            mount(makeTextField(frame, index: index, slot: 0,
                                value: host.map { $0.draft[keyPath: key] } ?? ""), index)
        case let .number(frame, key):
            mount(makeTextField(frame, index: index, slot: 0,
                                value: Self.string(host?.draft[keyPath: key] ?? nil)), index)
        case let .numberPair(first, second, _, slash, firstKey, secondKey):
            mount(makeTextField(first, index: index, slot: 0,
                                value: Self.string(host?.draft[keyPath: firstKey] ?? nil)), index)
            // [AX] 「/」是一个独立的 AXStaticText，宽 5
            let divider = NSTextField(labelWithString: "/")
            divider.font = Self.bodyFont
            divider.textColor = .secondaryLabelColor
            divider.frame = place(slash)
            addSubview(divider)
            mount(makeTextField(second, index: index, slot: 1,
                                value: Self.string(host?.draft[keyPath: secondKey] ?? nil)), index, 1)
        case let .checkBox(frame, title, key):
            let box = NSButton(checkboxWithTitle: title, target: self,
                               action: #selector(checkBoxChanged(_:)))
            box.font = Self.bodyFont
            box.tag = index * Self.slotBase
            box.state = (host?.draft[keyPath: key] ?? false) ? .on : .off
            // **宽度取实测值与文字实际需要的较大者**。实测里「记住播放位置」与
            //「随机播放时跳过」报的都是 118 宽——那是 Music 的 AX frame，
            // 它那边的文字画得出来；照抄到 14pt 的 AppKit 勾选框上，后者就被
            // 截成「随机播放时…」。截断比差几点更失真，所以让文字说了算。
            var box_frame = place(frame)
            box_frame.size.width = max(box_frame.width, box.intrinsicContentSize.width.rounded(.up))
            box.frame = box_frame
            mount(box, index)
        case let .comboBox(frame, key):
            let combo = NSComboBox(frame: place(frame))
            combo.font = Self.bodyFont
            combo.tag = index * Self.slotBase
            combo.target = self
            combo.action = #selector(comboChanged(_:))
            combo.delegate = self
            combo.completes = true
            // [缺口] Music 那份候选流派列表 **AX 不可达**（sample §4.7）：`AXComboBox`
            // 按下后子树里只有箭头 `AXButton`，既没有 AXMenu 也没有 AXList。
            // 所以**不编一份「Music 的流派表」**，改用用户自己资料库里真实出现过的流派
            //（见 `genreOptions()`）——那是本机的事实，不是对 Music 的猜测。
            // 组合框照旧可手打（Music 那个也支持）。
            combo.addItems(withObjectValues: host?.genreOptions() ?? [])
            combo.numberOfVisibleItems = 12
            combo.stringValue = host?.draft[keyPath: key] ?? ""
            mount(combo, index)
        case let .popUp(frame, kind):
            mount(makePopUp(frame, kind: kind, index: index), index)
        case let .timeToggle(check, _, fieldFrame, enabledKey, time):
            // [AX] 勾选框在左、16×16 无标题；时间框在右
            let box = NSButton(checkboxWithTitle: "", target: self,
                               action: #selector(checkBoxChanged(_:)))
            box.tag = index * Self.slotBase + 1
            box.state = (host?.draft[keyPath: enabledKey] ?? false) ? .on : .off
            box.frame = place(check)
            mount(box, index, 1)
            let value: String
            switch time {
            case .start: value = Self.timeString(host?.draft.info.startTime ?? 0)
            case .stop: value = (host?.draft.info.stopTime).flatMap { $0 }.map(Self.timeString) ?? ""
            }
            let text = makeTextField(fieldFrame, index: index, slot: 0, value: value)
            text.isEnabled = box.state == .on
            mount(text, index)
        case let .slider(frame, key):
            let slider = NSSlider(frame: place(frame))
            slider.minValue = Double(M.volumeAdjustmentRange.lowerBound)
            slider.maxValue = Double(M.volumeAdjustmentRange.upperBound)
            // [AX] `AXAllowedValues` 给 11 个吸附档、步长 51。**不设 numberOfTickMarks**：
            // 那会把刻度画出来，而实测的滑块 frame 只有 20 高、位图里没有刻度线。
            // 吸附放在 action 里做，效果与 allowedValues 一致、外观不变。
            slider.doubleValue = Double(host?.draft[keyPath: key] ?? 0)
            slider.tag = index * Self.slotBase
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            mount(slider, index)
        case let .rating(frame):
            // [AX] subrole `AXRatingIndicator`、0…5 整星 ⇒ 就是 NSLevelIndicator 的 rating 样式
            let stars = NSLevelIndicator(frame: place(frame))
            stars.levelIndicatorStyle = .rating
            stars.minValue = 0
            stars.maxValue = Double(M.ratingMax)
            stars.numberOfTickMarks = 0
            stars.isEditable = true
            stars.doubleValue = Double(host?.draft.rating ?? 0)
            stars.tag = index * Self.slotBase
            stars.target = self
            stars.action = #selector(ratingChanged(_:))
            mount(stars, index)
        case let .textArea(frame, key):
            mount(makeTextArea(frame, index: index,
                               value: host.map { $0.draft[keyPath: key] } ?? "",
                               editable: true), index)
        case let .firstField(popUpFrame, fieldFrame):
            // [AX] ITID 65534，实测**只有两项**：标题 / 作品名称。
            let popUp = NSPopUpButton(frame: place(popUpFrame), pullsDown: false)
            popUp.font = Self.bodyFont
            popUp.addItems(withTitles: InfoPanelTabs.firstFieldTitles)
            popUp.selectItem(at: (host?.draft.info.useWorkAndMovement ?? false) ? 1 : 0)
            popUp.target = self
            popUp.action = #selector(firstFieldSelectorChanged(_:))
            mount(popUp, index, 1)
            let useWork = host?.draft.info.useWorkAndMovement ?? false
            let value = useWork ? (host?.draft.info.workName ?? "")
                                : (host?.draft.info.title ?? "")
            mount(makeTextField(fieldFrame, index: index, slot: 0, value: value), index)
        case let .readOnly(frame, kind):
            mount(makeReadOnly(frame, text: host?.readOnlyText(kind) ?? "", kind: kind), index)
        case let .readOnlyWithButton(frame, kind, buttonFrame, title, action):
            mount(makeReadOnly(frame, text: host?.readOnlyText(kind) ?? "", kind: kind), index)
            let button = NSButton(title: title, target: self,
                                  action: #selector(fieldButtonClicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index * Self.slotBase
            button.frame = place(buttonFrame)
            button.isEnabled = host?.isEnabled(action) ?? false
            fieldActions[index] = action
            mount(button, index, 1)
        case let .pathBreadcrumb(frame):
            mount(makeBreadcrumb(frame), index)
        }
    }

    private var fieldActions: [Int: InfoPanelFieldAction] = [:]

    /// 装一件控件并记下位置。静态标签、数对中间那条「/」不记——它们没有值要回写。
    private func mount(_ view: NSView, _ index: Int, _ slot: Int = 0) {
        installed[index * Self.slotBase + slot] = view
        addSubview(view)
    }

    private func mounted(_ index: Int, _ slot: Int = 0) -> NSView? {
        installed[index * Self.slotBase + slot]
    }

    // MARK: 就地回写（§1 故障 8）

    /// 这张表单描述的还是不是同一组行。
    ///
    /// 目前唯一会变的是文件页的行数（`hasLocalFile` 翻转 → 多出位速率 / 采样速率 / 声道
    /// 三行，其后各行整体下移）。逐条比而不是只比个数：以后再加「媒体种类 × Tab」的
    /// 变体表时，同样行数不同形状不会被悄悄当成「没变」。
    func describes(_ other: [InfoPanelField]) -> Bool { fields == other }

    /// 把宿主草稿里的值写回**已有控件**——一件视图都不建、不拆。
    ///
    /// 为什么要有这条路：面板上的异步回调（音源流派、文件属性探测）和「重设播放次数」
    /// 这类动作回来时，原先一律整块换 `scrollView.documentView`。正在编辑的文本框连同
    /// field editor 一起没了——输入焦点丢失、输入法正在组的字被吞、滚动位置顶回顶部
    /// （design-ref/reactive-ui-review.md §1 故障 8）。切 Tab 仍然整块换：那是用户主动的，
    /// 也是 spec §6-2 建议的做法。
    ///
    /// **正在编辑的那一件跳过。** 用户改过的值本来就在草稿里（文本框是边打边进草稿的，
    /// 见 `controlTextDidChange`），回写只会写回同一个字符串；但输入法的组字还没进
    /// `stringValue`，动一下 field editor 就把它吞了。这与`probeGenreIfNeeded` 那条
    /// 「只回填、不覆盖」是同一个态度：用户手上的东西不动。
    func refreshValues() {
        guard let host else { return }
        for (index, field) in fields.enumerated() {
            switch field.control {
            case let .text(_, key):
                setText(index, 0, host.draft[keyPath: key])
            case let .number(_, key):
                setText(index, 0, Self.string(host.draft[keyPath: key]))
            case let .numberPair(_, _, _, _, firstKey, secondKey):
                setText(index, 0, Self.string(host.draft[keyPath: firstKey]))
                setText(index, 1, Self.string(host.draft[keyPath: secondKey]))
            case let .checkBox(_, _, key):
                setState(index, 0, host.draft[keyPath: key])
            case let .comboBox(_, key):
                guard let combo = mounted(index) as? NSComboBox, !isEditing(combo) else { break }
                let options = host.genreOptions()
                if (combo.objectValues as? [String]) != options {
                    combo.removeAllItems()
                    combo.addItems(withObjectValues: options)
                }
                let value = host.draft[keyPath: key]
                if combo.stringValue != value { combo.stringValue = value }
            case let .popUp(_, kind):
                guard let popUp = mounted(index) as? NSPopUpButton else { break }
                switch kind {
                case .mediaKind:
                    let all = TrackInfo.MediaKind.allCases
                    popUp.selectItem(at: all.firstIndex(of: host.draft.info.mediaKind) ?? 0)
                case .equalizer:
                    popUp.selectItem(withTitle: host.draft.info.equalizerPreset
                                     ?? EqualizerPreset.names.first ?? "无")
                }
            case let .timeToggle(_, _, _, enabledKey, time):
                let on = host.draft[keyPath: enabledKey]
                setState(index, 1, on)
                switch time {
                case .start: setText(index, 0, Self.timeString(host.draft.info.startTime))
                case .stop: setText(index, 0, host.draft.info.stopTime.map(Self.timeString) ?? "")
                }
                (mounted(index) as? NSTextField)?.isEnabled = on
            case let .slider(_, key):
                (mounted(index) as? NSSlider)?.doubleValue = Double(host.draft[keyPath: key])
            case .rating:
                (mounted(index) as? NSLevelIndicator)?.doubleValue = Double(host.draft.rating)
            case let .textArea(_, key):
                setTextArea(index, host.draft[keyPath: key])
            case .firstField:
                let useWork = host.draft.info.useWorkAndMovement
                (mounted(index, 1) as? NSPopUpButton)?.selectItem(at: useWork ? 1 : 0)
                setText(index, 0, useWork ? host.draft.info.workName : host.draft.info.title)
            case let .readOnly(_, kind):
                setReadOnly(index, kind, host.readOnlyText(kind))
            case let .readOnlyWithButton(_, kind, _, _, action):
                setReadOnly(index, kind, host.readOnlyText(kind))
                (mounted(index, 1) as? NSButton)?.isEnabled = host.isEnabled(action)
            case .pathBreadcrumb:
                // 面包屑没有「值」可写：它是按路径段现算的一串标签。段没变就一件都不动，
                // 变了也只重填这一个容器，整张表单照旧留着。
                guard let container = mounted(index) else { break }
                let names = host.pathComponents()
                guard container.subviews.compactMap({ ($0 as? NSTextField)?.stringValue }) != names
                else { break }
                container.subviews.forEach { $0.removeFromSuperview() }
                fillBreadcrumb(container, names)
            }
        }
    }

    /// 正在编辑的控件绝不能被写回覆盖（理由见 `refreshValues`）。
    private func isEditing(_ view: NSView?) -> Bool {
        if let control = view as? NSControl { return control.currentEditor() != nil }
        if let scroll = view as? NSScrollView, let textView = scroll.documentView as? NSTextView {
            return textView.window?.firstResponder === textView
        }
        return false
    }

    private func setText(_ index: Int, _ slot: Int, _ value: String) {
        guard let field = mounted(index, slot) as? NSTextField,
              !isEditing(field), field.stringValue != value else { return }
        field.stringValue = value
    }

    private func setState(_ index: Int, _ slot: Int, _ on: Bool) {
        guard let box = mounted(index, slot) as? NSButton else { return }
        box.state = on ? .on : .off
    }

    private func setTextArea(_ index: Int, _ value: String) {
        guard let scroll = mounted(index) as? NSScrollView,
              let textView = scroll.documentView as? NSTextView,
              !isEditing(scroll), textView.string != value else { return }
        textView.string = value
    }

    /// 只读格：版权那一行是 `AXTextArea`（装的是滚动视图），其余是文本框。
    private func setReadOnly(_ index: Int, _ kind: InfoPanelReadOnlyField, _ text: String) {
        if kind == .copyright { setTextArea(index, text) } else { setText(index, 0, text) }
    }

    // MARK: 各类控件

    private func makeTextField(_ frame: NSRect, index: Int, slot: Int, value: String) -> NSTextField {
        let text = NSTextField(frame: place(frame))
        text.font = Self.bodyFont
        // [AX] 实测这些框的 subrole 报的是 `AXSearchField`——那多半是 Music 自己的
        // 控件子类报出来的，不是圆角搜索框（位图里是方角、边框 #5E5E5F、
        // 底色与窗口同色）。这里照外观用标准的方角有边框文本框，不去凑那个 subrole。
        text.isBezeled = true
        text.bezelStyle = .squareBezel
        text.isEditable = true
        text.stringValue = value
        text.tag = index * Self.slotBase + slot
        text.delegate = self
        return text
    }

    private func makeReadOnly(_ frame: NSRect, text: String, kind: InfoPanelReadOnlyField) -> NSView {
        // [AX] 文件页全只读，但控件**仍是 AXTextField 不是 AXStaticText**——
        // 照办：不可编辑但仍有文本框外观的 NSTextField，**不换成 label**。
        if kind == .copyright {
            // [AX] 版权那一行是 AXTextArea
            return makeTextArea(frame, index: -1, value: text, editable: false)
        }
        let field = ReadOnlyTextField(frame: place(frame))
        field.font = Self.bodyFont
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.isEditable = false
        // 改不动，但选得中、复制得走（`canBecomeKeyView` 才是 Tab 键那条线，见类型注释）
        field.isSelectable = true
        field.stringValue = text
        return field
    }

    private func makeTextArea(_ frame: NSRect, index: Int, value: String, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView(frame: place(frame))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView: NSTextView = editable
            ? NSTextView(frame: scroll.contentView.bounds)
            : ReadOnlyTextView(frame: scroll.contentView.bounds)
        textView.font = Self.bodyFont
        textView.isEditable = editable
        // 只读那一份要显式关掉输入法那一套：`isEditable = false` 之外，
        // 富文本粘贴、拖放、拼写替换都得断，否则拖一段文字进去照样能改出内容。
        if !editable {
            textView.isSelectable = true
            textView.isFieldEditor = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.registerForDraggedTypes([])
        }
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.string = value
        textView.delegate = self
        if index >= 0 { textViewFields[ObjectIdentifier(textView)] = index }
        scroll.documentView = textView
        return scroll
    }

    private func makePopUp(_ frame: NSRect, kind: InfoPanelPopUpKind, index: Int) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: place(frame), pullsDown: false)
        popUp.font = Self.bodyFont
        popUp.tag = index * Self.slotBase
        popUp.target = self
        popUp.action = #selector(popUpChanged(_:))
        switch kind {
        case .mediaKind:
            popUp.addItems(withTitles: TrackInfo.MediaKind.allCases.map(\.displayName))
            let current = host?.draft.info.mediaKind ?? .music
            popUp.selectItem(at: TrackInfo.MediaKind.allCases.firstIndex(of: current) ?? 0)
        case .equalizer:
            // [AX] 24 项，**首项后一条分隔线**
            for (offset, name) in EqualizerPreset.names.enumerated() {
                popUp.addItem(withTitle: name)
                if offset == 0 { popUp.menu?.addItem(.separator()) }
            }
            let current = host?.draft.info.equalizerPreset
            popUp.selectItem(withTitle: current ?? EqualizerPreset.names.first ?? "无")
        }
        return popUp
    }

    /// [AX] 「位置」是 `AXList`（AXTitle「路径」）里逐段`AXStaticText`，
    /// 每段宽度随文字变、高 28 —— 不是一行文本。
    private func makeBreadcrumb(_ frame: NSRect) -> NSView {
        let container = NSView(frame: place(frame))
        fillBreadcrumb(container, host?.pathComponents() ?? [])
        return container
    }

    /// 段是现算的，所以填段这一半单拎出来：文件属性探回来时只重填这一个容器
    /// （见 `refreshValues`），不动整张表单。
    private func fillBreadcrumb(_ container: NSView, _ components: [String]) {
        var x: CGFloat = 1   // [AX] 首段 110 相对 AXList 的 109，左内缩 1
        for name in components {
            let segment = NSTextField(labelWithString: name)
            segment.font = Self.bodyFont
            segment.alignment = .center
            segment.lineBreakMode = .byTruncatingMiddle
            let width = segment.intrinsicContentSize.width + 20
            segment.frame = NSRect(x: x, y: 1, width: width, height: 28)
            container.addSubview(segment)
            x += width
        }
    }

    // MARK: 取值 / 写回

    private static func string(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    /// [AX] 停止时间实测精确到毫秒（`2:39.962`），开始时间是`0:00`。
    static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        let whole = Int(secs)
        let millis = Int((secs - Double(whole)) * 1000 + 0.5)
        if millis == 0 { return String(format: "%d:%02d", minutes, whole) }
        return String(format: "%d:%02d.%03d", minutes, whole, millis)
    }

    /// `m:ss` / `m:ss.mmm` / `ss` 都收。整句解不出来就返回 nil（保持原值）。
    static func timeValue(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let secondsPart = String(parts[parts.count - 1])
        guard let seconds = Double(secondsPart) else { return nil }
        guard parts.count == 2 else { return seconds }
        guard let minutes = Double(parts[0]) else { return nil }
        return minutes * 60 + seconds
    }

    // MARK: 动作

    @objc private func checkBoxChanged(_ sender: NSButton) {
        let (index, slot) = decode(sender.tag)
        guard let host, index < fields.count else { return }
        let on = sender.state == .on
        switch fields[index].control {
        case let .checkBox(_, _, key):
            host.draft[keyPath: key] = on
        case let .timeToggle(_, _, fieldFrame, enabledKey, _) where slot == 1:
            host.draft[keyPath: enabledKey] = on
            // 勾掉就把时间框一起灰掉（Music 的开始/停止就是这么联动的）
            for case let field as NSTextField in subviews
            where field.frame == place(fieldFrame) { field.isEnabled = on }
        default:
            break
        }
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        let (index, _) = decode(sender.tag)
        guard let host, index < fields.count,
              case let .popUp(_, kind) = fields[index].control else { return }
        switch kind {
        case .mediaKind:
            let all = TrackInfo.MediaKind.allCases
            let selected = sender.indexOfSelectedItem
            if selected >= 0 && selected < all.count { host.draft.info.mediaKind = all[selected] }
        case .equalizer:
            let title = sender.titleOfSelectedItem ?? ""
            host.draft.info.equalizerPreset = (title == EqualizerPreset.names.first) ? nil : title
        }
    }

    @objc private func comboChanged(_ sender: NSComboBox) {
        let (index, _) = decode(sender.tag)
        guard let host, index < fields.count,
              case let .comboBox(_, key) = fields[index].control else { return }
        host.draft[keyPath: key] = sender.stringValue
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let (index, _) = decode(sender.tag)
        guard let host, index < fields.count,
              case let .slider(_, key) = fields[index].control else { return }
        // [AX] 11 个吸附档、步长 51
        let step = Double(M.volumeAdjustmentStep)
        let snapped = Int((sender.doubleValue / step).rounded() * step)
        sender.doubleValue = Double(snapped)
        host.draft[keyPath: key] = snapped
    }

    @objc private func ratingChanged(_ sender: NSLevelIndicator) {
        host?.draft.rating = Int(sender.doubleValue.rounded())
    }

    @objc private func fieldButtonClicked(_ sender: NSButton) {
        let (index, _) = decode(sender.tag)
        guard let action = fieldActions[index] else { return }
        host?.perform(action)
    }

    @objc private func firstFieldSelectorChanged(_ sender: NSPopUpButton) {
        host?.draft.info.useWorkAndMovement = sender.indexOfSelectedItem == 1
        // [缺口] Music 切到「作品名称」后会展开乐章名 / 乐章编号那几行（spec §4.1 的
        // `0x49` / `0x3c` / `0x3d`+`0x3e`），但**实测没采到那个形态**（样本是流行乐）。
        // 这里只把首行改绑到 `workName`，不编一套没量过的行——**行数不变**，
        // 所以这一下只要把首行那个文本框的值换掉，整张表单原样留着。
        host?.formValuesDidChange()
    }

    private func decode(_ tag: Int) -> (index: Int, slot: Int) {
        (tag / Self.slotBase, tag % Self.slotBase)
    }
}

// MARK: - 文本实时进草稿

extension InfoPanelFormView: NSTextFieldDelegate, NSTextViewDelegate, NSComboBoxDelegate {

    /// 边打边进草稿，不等 `controlTextDidEndEditing`。
    /// 两个理由：① Return 被绑成「好」，等结束编辑会丢掉最后一次输入；
    /// ② 「上一个 / 下一个」切曲目时要求「把当前页的编辑先收进草稿」——
    /// 实时写就不需要在切换处再收一次尾。草稿本来就要点「好」才落地，不影响取消语义。
    func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSControl else { return }
        if let combo = control as? NSComboBox { comboChanged(combo); return }
        guard let text = control as? NSTextField else { return }
        let (index, slot) = decode(text.tag)
        guard let host, index < fields.count else { return }
        let value = text.stringValue
        switch fields[index].control {
        case let .text(_, key):
            host.draft[keyPath: key] = value
        case let .number(_, key):
            host.draft[keyPath: key] = Int(value.trimmingCharacters(in: .whitespaces))
        case let .numberPair(_, _, _, _, firstKey, secondKey):
            let key = slot == 1 ? secondKey : firstKey
            host.draft[keyPath: key] = Int(value.trimmingCharacters(in: .whitespaces))
        case let .timeToggle(_, _, _, _, time):
            switch time {
            case .start: host.draft.info.startTime = Self.timeValue(value) ?? 0
            case .stop: host.draft.info.stopTime = Self.timeValue(value)
            }
        case .firstField:
            if host.draft.info.useWorkAndMovement {
                host.draft.info.workName = value
            } else {
                host.draft.info.title = value
            }
        default:
            break
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        // 选中项要等 runloop 转一圈才进 stringValue
        DispatchQueue.main.async { [weak self] in self?.comboChanged(combo) }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let index = textViewFields[ObjectIdentifier(textView)],
              let host, index < fields.count,
              case let .textArea(_, key) = fields[index].control else { return }
        host.draft[keyPath: key] = textView.string
    }
}

// MARK: - 只读那两件控件

/// 文件页的只读格。
///
/// [AX] Music 那边这些格的 AX 角色**仍是 `AXTextField`**（版权那行是`AXTextArea`），
/// 不是 `AXStaticText` —— 所以不能图省事换成 label，得留着文本框这一身。
/// 「改不动」靠 `isEditable = false`，「Tab 键不停在这儿」靠`canBecomeKeyView`：
/// 键视图循环问的是 `canBecomeKeyView`，鼠标点击走的是`acceptsFirstResponder`，
/// 两条是分开的——只按掉前者，于是 Tab 跳过它，而用户照样点得进去选文字复制。
/// （改用 `refusesFirstResponder` 会把两条一起按掉，连选中复制都没了。）
private final class ReadOnlyTextField: NSTextField {
    override var canBecomeKeyView: Bool { false }
}

/// 同上，版权那一行的 `AXTextArea` 版。
private final class ReadOnlyTextView: NSTextView {
    override var canBecomeKeyView: Bool { false }
}

// MARK: - 「上一个 / 下一个」与草稿簿

/// 底部那对导航键走到哪。纯值语义，不牵扯窗口，好单测。
///
/// [AX] 两颗键的 frame 水平重叠 3pt，是并排分段的画法；启用条件实测**没采到**
/// （sample 只采了单选态），这里按 Music 单选态的常识：走到头就灰掉，
/// 只有一首时两头都灰。
struct InfoPanelCursor: Equatable {
    let count: Int
    private(set) var index: Int

    init(count: Int, index: Int = 0) {
        self.count = max(1, count)
        self.index = min(max(0, index), self.count - 1)
    }

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index < count - 1 }

    /// 走得动就走并返回 true；走到头返回 false、位置不动。
    @discardableResult
    mutating func move(by delta: Int) -> Bool {
        let target = index + delta
        guard target >= 0, target < count, target != index else { return false }
        index = target
        return true
    }
}

/// 面板开着的这段时间里，每一首各自那份草稿。
///
/// Music 的双适配器语义（spec §1.2）：`initials` 是
/// `mInitialValuesITTrackInfoAdapter`——只用来判断「到底改没改」；
/// `edits` 是`mITTrackInfoAdapter`。点「好」一次性提交`pending()` 那几份，
/// 点「取消」整本丢掉（连 store 都没碰过，所以「丢」就是什么都不做）。
struct InfoPanelDraftBook: Equatable {
    private var initials: [String: InfoPanelDraft] = [:]
    private var edits: [String: InfoPanelDraft] = [:]

    /// 第一次为某一首建草稿：初始值与当前值同时记下。
    mutating func start(_ draft: InfoPanelDraft, for id: String) {
        if initials[id] == nil { initials[id] = draft }
        edits[id] = draft
    }

    /// 切走之前把编到一半的收起来。
    mutating func keep(_ draft: InfoPanelDraft, for id: String) {
        edits[id] = draft
    }

    /// 走回来时拿回刚才那份（没编过返回 nil，由调用方现建）。
    func draft(for id: String) -> InfoPanelDraft? { edits[id] }

    func initialDraft(for id: String) -> InfoPanelDraft? { initials[id] }

    /// 「好」要提交的那几份：**与初始值不同的才算**。
    func pending() -> [String: InfoPanelDraft] {
        edits.filter { initials[$0.key] != $0.value }
    }

    /// 「取消」：全丢。草稿从头到尾没往任何 store 写过一笔，所以丢＝清空。
    mutating func discardAll() {
        edits = initials
    }
}
