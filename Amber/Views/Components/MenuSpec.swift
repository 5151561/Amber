import AppKit
import SwiftUI

// MARK: - 菜单的装配基建

/// 「一张表 + 两个渲染器」。
///
/// Music 的右键菜单不是一处一份手写 `NSMenu`：一个菜单项 = 一个自带`title` / `isValid` /
/// `executeWithCompletion:` 的`AMPAction` 子类，菜单由
/// `+[AMPAction createMenuForActions:hideDisabled:]` 把**一串 action** 装配出来
/// （[实测] contextmenu spec §1.3：全二进制只有 4 处调用它，其余界面宿主逐个 `createMenuItem` 手拼）。
/// 各界面的差别是**调用方给哪几个 action、按什么顺序**（§5.1 矩阵 + 实测项序），
/// 不是各写各的菜单——这一点很重要：项序差异是 Music 有意为之，不是漂移。
///
/// 所以本文件只管「怎么把一串 `Entry` 变成菜单」：
/// 动作定义在 `TrackActions` / `CollectionActions`（一个动作一份，≈ 那 25 个`AMPAction` 子类），
/// 项序由各界面各出一份数组（≈ 那 4 个调用方各传各的数组）。
///
/// **禁用即隐藏**：Music 装配末尾统一把 `!isEnabled && !isSeparatorItem` 的项`setHidden:YES`
/// （目录三处传 `hideDisabled:YES`；播放器与队列各自实现了一份等价逻辑，
/// [实测] nowplaying §4.6 / playqueue）。于是 `run == nil` 的项不摆出来——
/// **Amber 还没有的能力照样列在原位**，哪天接上线把 nil 换成动作即可，
/// 它连同该出现的分隔线一起自然出现，不用回来重排顺序。
enum MenuSpec {

    /// 菜单里的一项。
    indirect enum Entry {
        case separator
        /// 一条命令。`run == nil` = 这条现在不可用（Amber 还没有它，或当前对象不适用），
        /// 按「禁用即隐藏」不摆出来。
        case command(Command)
        /// 子菜单。父项本身没有动作，子项全不可用时整条不摆。
        case submenu(Command, [Entry])
        /// **带标题的一段**（AppKit 的 `NSMenuItem.sectionHeader(title:)`、SwiftUI 的`Section`），
        /// 子项就摆在同一层、不缩进。用在同一份菜单里要分辨「哪些是本机的、哪些是账号里的」
        /// 的地方——「添加到播放列表 ▸」下面那份账号歌单就是这么分段的。`[Amber]`
        /// 一条能用的子项都没有时整段不摆（连标题一起）。
        case section(String, [Entry])
    }

    struct Command {
        let title: String
        /// 菜单项左侧的字形。Music 只给少数几条配了图（[实测] contextmenu spec §3.2：
        /// 插播 / 加入待播 / 创建电台 / 分享）。
        var symbol: String?
        /// 现成的图（系统给的那种，比如共享服务各自的图标）。与 `symbol` 二选一，它优先。
        /// 两条渲染路都画：AppKit 直接给 `NSMenuItem.image`，SwiftUI 走`Label` 的 icon 位。
        var image: NSImage?
        /// **显示用**的快捷键。真正生效的绑定在主菜单里——弹出式菜单里的 key equivalent
        /// 只在菜单开着时才管用，摆在这里是为了告诉用户「这条还有个快捷键」，与 Music 一致。
        var key: (String, NSEvent.ModifierFlags)?
        /// 打勾态。nil = 普通项；非 nil = 可勾选项（评分子菜单那六项就是这么来的）。
        var isOn: Bool?
        var run: (() -> Void)?

        init(_ title: String, symbol: String? = nil, image: NSImage? = nil,
             key: (String, NSEvent.ModifierFlags)? = nil,
             isOn: Bool? = nil, run: (() -> Void)? = nil) {
            self.title = title
            self.symbol = symbol
            self.image = image
            self.key = key
            self.isOn = isOn
            self.run = run
        }
    }
}

// MARK: - 分享

extension MenuSpec {

    /// 「分享 ▸」：一条**自己列服务**的子菜单（拷贝链接 + 系统里装了的那些共享服务）。
    ///
    /// **为什么不用 `NSSharingServicePicker.standardShareMenuItem`**（macOS 13 起
    /// 官方给的那一条，`sharingServices(forItems:)` 的弃用说明也让人改用它）：
    /// [实测 2026-09-09 swift 探针] 它**不是**一条带子菜单的项——
    /// `submenu` 恒为 nil（`menu.update()` 之后也还是 nil），它只是一条标题
    /// 「Share…」、action 是 `_performStandardShareMenuItem:`、target 是
    /// `SHKSharingServicePicker` 的普通项：点下去由那个 picker 自己弹一个浮层。
    /// 弹出式菜单里没有可锚的矩形，于是浮层从**屏幕左上角**冒出来，跟点的那一项对不上。
    /// [实机 2026-09-09 用户打回] 就是这个现象。
    ///
    /// 它适用的场合是工具栏按钮 / 控件上挂的菜单（系统知道锚在哪），右键菜单不适用。
    /// 所以这里回到 `sharingServices(forItems:)`：虽然 macOS 13 起标了弃用，
    /// 但这台机器上照样回 9 条（隔空投送 / 信息 / 邮件 / 备忘录 / 无边记 / 日记 /
    /// 提醒事项 / 阅读列表 + 第三方的 LocalSend），每条 `perform(withItems:)`
    /// 自己开自己的窗，**根本不需要锚点**。项集与形态也与 Music 的「分享 ▸」一致。
    ///
    /// 一条链接都没有、或系统一个服务都不给时返回一条不可用的项＝不摆
    /// （本地导入的歌没有网页版页面）。
    @MainActor
    static func shareEntry(_ command: Command, urls: [URL]) -> Entry {
        guard !urls.isEmpty else { return .command(.init(command.title, symbol: command.symbol)) }
        var children: [Entry] = [
            // Music 的分享子菜单头一条就是「拷贝链接」；Amber 那条「拷贝」拷的是
            // 「歌名 — 歌手」，不是链接，两条各管各的。
            .command(.init("拷贝链接", run: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
            })),
        ]
        let services = sharingServices(for: urls)
        if !services.isEmpty {
            children.append(.separator)
            children += services.map { service in
                .command(.init(service.menuItemTitle, image: service.image, run: {
                    service.perform(withItems: urls)
                }))
            }
        }
        return .submenu(command, children)
    }

    /// 全工程唯一一处调它的地方。**这条弃用警告是故意留着的**：它是「哪天 Apple
    /// 真把这条拿掉了，回来看一眼」的提醒。真拿掉（返回空表）也塌不了——
    /// 上面那句「一个服务都不给就只剩拷贝链接」会兜住，分享不会整条消失。
    private static func sharingServices(for urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls)
    }
}

// MARK: - 摘项

extension MenuSpec {

    /// 摘掉不可用项，再把因此空掉的分隔线并掉（开头/结尾/连着两条都不留）。
    ///
    /// **这一步是 Amber 的取舍,不是实测**：目录三处传的 `hideDisabled:YES` 在框架侧
    /// （`+createMenuForActions:hideDisabled:`，旧基线`…`）——那 257 条本次没读，
    /// 因此不知道 Music 会不会折叠因隐藏而空掉的分隔线；队列那份则**明确不折叠**
    /// （只 `setHidden:` 项，不动分隔线）。Amber 一律折叠：
    /// 不折叠就会出现连着两条分隔线，而 Amber 缺的能力比 Music 多得多，空段会非常显眼。
    static func visible(_ entries: [Entry]) -> [Entry] {
        var out: [Entry] = []
        for entry in entries where entry.isAvailable {
            if case .separator = entry {
                guard let last = out.last, !last.isSeparator else { continue }
            }
            out.append(entry)
        }
        if let last = out.last, last.isSeparator { out.removeLast() }
        return out
    }
}

extension MenuSpec.Entry {

    var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }

    /// 禁用即隐藏：没接线的命令不摆出来；子菜单一条能用的都没有时整条不摆。
    var isAvailable: Bool {
        switch self {
        case .separator: return true
        case let .command(command): return command.run != nil
        case let .submenu(_, children), let .section(_, children):
            return children.contains(where: \.isAvailable)
        }
    }
}

// MARK: - AppKit 渲染

extension MenuSpec {

    /// 把表渲染成 `NSMenu`。
    @MainActor
    static func makeMenu(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        fill(menu, with: entries)
        return menu
    }

    /// 往一份**现成的**菜单里重灌项。给「件不换、内容每次弹之前现造」那种菜单用
    /// （工具栏右端那颗 ••• 就是：`NSMenuToolbarItem` 认的是它建件时那一份`menu` 实例，
    /// 换实例它不认，只能就地重灌）。
    @MainActor
    static func fill(_ menu: NSMenu, with entries: [Entry]) {
        menu.removeAllItems()
        append(visible(entries), to: menu)
    }

    /// 摘完项之后逐条挂上去。分段是**平铺**的（标题 + 子项都在同一层），
    /// 所以这一步得能往同一个菜单里继续追加，不能只有「一串 Entry 换一份新菜单」那条路。
    @MainActor
    private static func append(_ entries: [Entry], to menu: NSMenu) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .command(command):
                menu.addItem(ClosureMenuItem(command))
            case let .submenu(command, children):
                let item = ClosureMenuItem(command)
                item.submenu = makeMenu(children)
                menu.addItem(item)
            case let .section(title, children):
                let rows = visible(children)
                guard !rows.isEmpty else { continue }
                menu.addItem(.sectionHeader(title: title))
                append(rows, to: menu)
            }
        }
    }
}

/// 带闭包的菜单项。
///
/// `NSMenuItem` 只弱引用`target`，所以动作不能挂在即用即造的控制器上（控制器会先被释放，
/// 点哪一项都没反应）；这里让菜单项**自己**当 target，菜单持有项、项持有闭包，
/// 一条链上没有第三方要照看。
///
/// 与 Music 同构：那边 `createMenuItem` 也是`target = self`（action 对象自己），
/// `representedObject` 回指 action（[实测] contextmenu spec §1.2）——右键菜单不走响应链，
/// 走响应链的是主菜单那套第一响应者命令。
final class ClosureMenuItem: NSMenuItem {

    private let run: (() -> Void)?

    init(_ command: MenuSpec.Command) {
        run = command.run
        super.init(title: command.title, action: nil, keyEquivalent: command.key?.0 ?? "")
        if let (_, modifiers) = command.key { keyEquivalentModifierMask = modifiers }
        if let ready = command.image {
            image = ready
        } else if let symbol = command.symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let isOn = command.isOn { state = isOn ? .on : .off }
        // 子菜单的父项没有动作，接上就会被点亮。
        guard command.run != nil else { return }
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { run?() }
}

// MARK: - SwiftUI 渲染

extension MenuSpec {

    /// SwiftUI 侧的渲染：单列一个具名视图，好让子菜单递归回自己。
    struct Rows: View {
        let entries: [Entry]

        init(_ entries: [Entry]) { self.entries = entries }

        var body: some View {
            ForEach(Array(MenuSpec.visible(entries).enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .separator:
                    Divider()
                case let .command(command):
                    row(command)
                case let .submenu(command, children):
                    // 子菜单的父项也要带图标（「分享 ▸」那一条）。
                    Menu { Rows(children) } label: { label(command) }
                case let .section(title, children):
                    Section(title) { Rows(children) }
                }
            }
        }

        /// 可勾选项走 `Toggle`（菜单里就是打勾那一栏），普通项走`Button`。
        @ViewBuilder
        private func row(_ command: Command) -> some View {
            if let isOn = command.isOn {
                Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in command.run?() }))
            } else {
                Button(action: { command.run?() }) { label(command) }
            }
        }

        /// 项的脸：有图就画 `Label`，没有就一行字。
        ///
        /// **这一条从前是漏的**：SwiftUI 这边一直只画 `Button(title)`，于是同一张表
        /// 在 AppKit 里有图标（插播 / 加入待播 / 分享）、在 SwiftUI 里没有——
        /// 整窗播放器与歌曲表那几处菜单走的正是这一条路。[实机打回 2026-09-09]
        @ViewBuilder
        func label(_ command: Command) -> some View {
            if let image = command.image {
                // 共享服务那些是彩色图标，不能当模板画（`isTemplate == false`）。
                Label { Text(command.title) } icon: { Image(nsImage: image) }
            } else if let symbol = command.symbol {
                Label(command.title, systemImage: symbol)
            } else {
                Text(command.title)
            }
        }
    }
}
