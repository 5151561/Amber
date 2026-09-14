import AppKit

/// `NSApplication` 子类。存在的唯一理由是把**无修饰的空格键**（「控制 ▸ 播放/暂停」，
/// Music 就是这颗键）在任何焦点下都送到主菜单。
///
/// [实测 probe 2026-09-08] 独立探针（一张 `NSTableView` + 一条无修饰空格的菜单项 +
/// 一条 ⌘K，往自己进程 `postToPid` 投真事件）逐条量出 AppKit 的派发顺序：
///
/// | 焦点 | 按键 | 实际路径 |
/// |---|---|---|
/// | 窗口本身 | 空格 | `sendEvent` → 视图层 `performKeyEquivalent`（没人接）→ **主菜单接了** |
/// | 表格 | 空格 | `sendEvent` → **`NSTableView.keyDown` 先拿走**（type-select 吃一个字符）→ 主菜单再也轮不到 |
/// | 窗口 / 表格 | ⌘K | `sendEvent` → `performKeyEquivalent` → **主菜单接了**（与焦点无关） |
///
/// 即：**带 ⌘/⌥/⌃ 的等价键先于第一响应者，无修饰的等价键在第一响应者之后**——
/// 无修饰键先走 `keyDown` 派给第一响应者，只有整条响应链都不接（`noResponderFor:`）
/// 时 AppKit 才回头把它当等价键交给视图层与菜单。归档的 Cocoa Event Handling Guide
/// 也是这么写的：「应用对象沿 key 窗口的视图树发 `performKeyEquivalent:`，
/// 视图树里没人接，`NSApp` 才把它交给菜单栏里的菜单」。
///
/// 后果就是「点了没反应」：Amber 启动后第一响应者默认落在侧栏那张 `NSOutlineView` 上，
/// 各页的曲目表、集合视图、任何拿到焦点的按钮也一样，空格全被它们吃掉，
/// 播放/暂停只有在「焦点恰好不在任何控件上」时才生效。
///
/// 这个类原先写的是**反过来**的补救（判定第一响应者是可编辑 `NSTextView` 就把空格
/// 投给窗口，免得菜单抢走搜索框里的空格），前提本身不成立：文本框是第一响应者时
/// `keyDown` 本来就先到它那儿，菜单根本抢不到。那份覆写既没用，还绕过了
/// `NSApp` 的正常处理。现在换成正确的方向——
///
/// **抢在 `super.sendEvent(_:)` 之前问一次主菜单**，菜单接了就到此为止；
/// 唯一让路的是**接受文本输入的第一响应者**（`NSTextInputClient`：`NSTextView`
/// 的字段编辑器、`WKWebView` 的内容视图都在此列，`NSTableView` / `NSButton` 都不是
/// ——见同一份探针），那里的空格仍旧是一个空格。
///
/// 菜单项被 `validateMenuItem` 判成禁用时（没有正在播的曲目），
/// `performKeyEquivalent` 返回 false，事件照常落回响应链——曲目表上那条
/// 「空格＝播放选中行」的兜底就是靠这一档还在（`TrackTableView` / `SongsTableView`）。
///
/// 只拦空格这一颗：无修饰的字母键是 `NSTableView` 的输入跳行（type-select），
/// 泛化成「任何无修饰等价键都先问菜单」会把它抢走。将来再加无修饰快捷键时，
/// 得连同这条一起想清楚。
///
/// Info.plist 的 `NSPrincipalClass` 指向这个类；Swift 类名会被改写成
/// `Amber.AmberApplication`，所以必须用 `@objc(AmberApplication)` 钉住 ObjC 侧的名字。
/// 但**真正把这份子类造出来的是 `AppDelegate.main()` 里那句 `AmberApplication.shared`**：
/// 认 `NSPrincipalClass` 的是 `NSApplicationMain()`，`+sharedApplication` 不认
/// （实测见 `AmberApp.swift` 的 `main()` 注释）。Info.plist 那条留着是给系统与将来
/// 可能换回 `NSApplicationMain` 的路径用的，不是这里生效的原因。
@objc(AmberApplication)
final class AmberApplication: NSApplication {

    override func sendEvent(_ event: NSEvent) {
        if shouldOfferToMainMenu(event), mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        super.sendEvent(event)
    }

    /// keyDown、干净的空格、且第一响应者不接受文本输入。
    private func shouldOfferToMainMenu(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // 只认「干净的空格」：带 ⌘/⌃/⌥ 的组合另有归属（那些也不需要这条路，
        // 它们本来就先于第一响应者）；Shift-空格在文本里仍是空格。
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .function, .numericPad, .capsLock])
        guard modifiers.isEmpty else { return false }
        guard event.charactersIgnoringModifiers == " " else { return false }
        guard let responder = keyWindow?.firstResponder else { return true }
        return !acceptsTextInput(responder)
    }

    private func acceptsTextInput(_ responder: NSResponder) -> Bool {
        // 只读的 NSTextView（歌词、说明文字）不算在输入里，空格照旧是播放/暂停。
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextInputClient
    }
}
