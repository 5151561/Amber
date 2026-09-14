import AppKit

// 导入撞名的替换询问。
//
// 出处：library 规格 §10.4（`[RES]`，基线 macOS 27.0
// 正式版 26A428 / Music 1.7.0）。
// 那一节把「撞名」拆成三条互不相干的链，本文件只做第三条——**导入时的同名撞车**，
// 语义是「**替换**」而不是「去重」：Music 不会把重复的那首悄悄跳过，而是停下来问一句
// 「要不要拿正在导入的这份换掉资料库里那份」。
//
// 关键结构证据是 res 500 idx **124/125/126 连号**：同一件事按「资料库里那份的版本新旧」
// 分了三个分支，且**措辞随分支变强**——124/125 是中性的「你想…吗」，
// 126（拿旧的覆盖新的）升级成「**确定**要…吗」。所以这三条不是同一句的复数变体，
// 是三个独立的判定结果，代码里也就得真按三个分支走，不能挑一句通用的糊过去。

/// 撞名询问里**不碰 AppKit 的那一半**：选哪个分支、那个分支该念哪句话。
///
/// 单独拎出来是为了能离线单测（`AmberTests/ImportReplaceTests.swift`）——弹窗那半截
/// 要真起一个 `NSAlert` 才跑得动，规则这半截不该跟着一起被挡在测试之外。
enum ImportReplacePrompt {

    /// 三个分支＝res 500 的三条连号串。
    enum Branch: Equatable {
        /// idx 124：没有版本判定（两边的时间有一边取不到，或干脆一样新）
        case unversioned
        /// idx 125：资料库里那份**更旧**
        case existingIsOlder
        /// idx 126：资料库里那份**更新**（拿旧的覆盖新的，措辞升级成「确定要」）
        case existingIsNewer
    }

    /// 分支判据。`[推]`：spec 只说了语义是「已有的更旧 / 更新」，没说这个「版本」
    /// 具体拿什么比。Amber 手里能代表「版本」的只有**文件的修改时间**（本地曲目没有
    /// 云端版本号、没有 iTunes 的 `dateModified` 字段），所以就按修改时间比。
    ///
    /// 两边只要有一边取不到时间就回落 124：那时「谁新谁旧」根本没结论，
    /// 硬猜一个方向会把 126 那句「确定要」念错人——问句的强度是有代价的。
    /// 时间**相等**也回落 124，同理（相等不是「更旧」也不是「更新」）。
    static func branch(existingModified: Date?, incomingModified: Date?) -> Branch {
        guard let existingModified, let incomingModified else { return .unversioned }
        if existingModified < incomingModified { return .existingIsOlder }
        if existingModified > incomingModified { return .existingIsNewer }
        return .unversioned
    }

    /// 单条撞名的问句。原文保留 `%1$S` 的写法，是为了让「这句就是 res 500 idx N」
    /// 一眼可核（拿本地化资源导出脚本按 `--lang zh_CN --res 500` 直接对）。
    ///
    /// 填坑不走 `String(format:)`：`%S` 在 CoreFoundation 那套里要的是 UTF-16 指针，
    /// Swift 的 `String(format:)` 喂不进去（`%@` 才是 Swift 侧的对应写法），
    /// 照着原样替换反而既准确又不会因为曲目名里带个 `%` 就炸。
    static func message(for branch: Branch, title: String) -> String {
        let template: String
        switch branch {
        // res 500 idx 124 [RES]
        case .unversioned:
            template = "音乐资料库中已经存在项目“%1$S”。你想使用正在移动的项目进行替换吗？"
        // res 500 idx 125 [RES]
        case .existingIsOlder:
            template = "音乐资料库中已经存在项目“%1$S”的较旧版本。你想使用正在移动的项目进行替换吗？"
        // res 500 idx 126 [RES]
        case .existingIsNewer:
            template = "音乐资料库中已经存在项目“%1$S”的较新版本。确定要使用正在移动的项目进行替换吗？"
        }
        return template.replacingOccurrences(of: "%1$S", with: title)
    }

    /// 一批里撞了多条时的问句（res 9003 idx 3 `[RES]`）。这句没有`%1$S`——
    /// 它本来就是「一首或多首」的说法，一次问完全部。
    static let batchMessage = "一首或多首要导入的所选歌曲已经导入。你想替换现有歌曲并重新导入这些文件吗？"
}

/// 弹窗那一半。形状照抄 `DownloadRemovalAlert`：有宿主窗就贴 sheet，没有就`runModal`。
@MainActor
enum ImportReplaceAlert {

    /// 单条撞名：三分支各念各的，按钮用通用按钮表那一对。
    ///
    /// 按钮文案 `替换` / `不替换` 是 res 23987 idx 17/18`[推]`——spec 给了 124–126 三句
    /// 问话却没给按钮。判据：问句本身就是「你想…**替换**吗」，而通用按钮表里正好摆着
    /// 这一对反义词；导入侧那句批量版（9003）的按钮也是同一个「替换 / 不替换」句式，
    /// 只是加了「现有」二字。
    static func confirm(branch: ImportReplacePrompt.Branch, trackTitle: String,
                        in window: NSWindow?) async -> Bool {
        await ask(message: ImportReplacePrompt.message(for: branch, title: trackTitle),
                  replaceTitle: "替换", keepTitle: "不替换", in: window)
    }

    /// 一批里撞了多条：一次问完，答案作用于全部撞名条目。
    /// 按钮 `替换现有` / ` 不替换` 是 res 9003 idx 5/6，实测，不是推的。
    static func confirmBatch(in window: NSWindow?) async -> Bool {
        await ask(message: ImportReplacePrompt.batchMessage,
                  replaceTitle: "替换现有", keepTitle: "不替换", in: window)
    }

    /// 返回 true＝用户选了「替换」。
    ///
    /// spec 只给了这一句问话，没有配套的补充说明串，所以 `informativeText` 空着——
    /// 自己编一句「解释」等于往复刻里掺私货。
    private static func ask(message: String, replaceTitle: String, keepTitle: String,
                            in window: NSWindow?) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.addButton(withTitle: replaceTitle)
            alert.addButton(withTitle: keepTitle)
            // [推] 「替换」会把资料库里已有的那条连同它的下载一起去掉，是破坏性的，
            // 交给系统那套护栏（防误触 + 警示外观），与 `DownloadRemovalAlert` 同一处理。
            alert.buttons[0].hasDestructiveAction = true
            // 这里第二颗不叫「取消」而叫「不替换」，但它担的就是「什么都别动」这个角色，
            // 该能用 esc 退出去。NSAlert 只对英文 "Cancel" 自动绑 esc，中文标题一律得手补
            // （与 `DownloadRemovalAlert` 里那条同因）。
            alert.buttons[1].keyEquivalent = "\u{1b}"

            guard let window else {
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
                return
            }
            // 隔一拍再贴。「文件 ▸ 导入…」那张选取面板也是贴在这扇窗上的 sheet，
            // 它的完成回调回来时自己还没撤干净，紧接着 `beginSheetModal` 会被吞掉——
            // 别处那两处（`MissingFileLocator` / `LibraryDeleteAlert`）被吞掉只是少弹一张，
            // 这里被吞掉是**导入整条卡死**：continuation 永远等不到答复。
            DispatchQueue.main.async {
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
    }
}
