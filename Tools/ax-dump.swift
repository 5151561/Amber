// 校准工具：转储目标 App 的 AX 元素树（角色 / 标题 / frame），
// 用于对照 Music.app 逐项校准 MusicMetrics。
//
// 用法：swift Tools/ax-dump.swift <App名> [最大深度，默认 25]
// 需要为运行它的终端授予「辅助功能」权限。
// frame 为屏幕坐标（左上原点），配合窗口原点即可换算相对位置。

import AppKit
import ApplicationServices

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
    attr(element, name) as? String
}

func rect(of element: AXUIElement) -> CGRect? {
    guard let posValue = attr(element, kAXPositionAttribute),
          let sizeValue = attr(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func fmt(_ v: CGFloat) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

func dump(_ element: AXUIElement, depth: Int, maxDepth: Int) {
    guard depth <= maxDepth else { return }
    let role = stringAttr(element, kAXRoleAttribute) ?? "?"
    let subrole = stringAttr(element, kAXSubroleAttribute).map { " (\($0))" } ?? ""
    let title = [stringAttr(element, kAXTitleAttribute),
                 stringAttr(element, kAXDescriptionAttribute),
                 stringAttr(element, kAXValueAttribute)]
        .compactMap { $0 }.first { !$0.isEmpty }.map { " \"\($0.prefix(40))\"" } ?? ""
    let frame = rect(of: element).map {
        "  [\(fmt($0.origin.x)), \(fmt($0.origin.y)), \(fmt($0.width)), \(fmt($0.height))]"
    } ?? ""
    print(String(repeating: "  ", count: depth) + role + subrole + title + frame)

    if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            dump(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift ax-dump.swift <App名> [最大深度]\n".utf8))
    exit(1)
}
let appName = args[1]
let maxDepth = args.count >= 3 ? Int(args[2]) ?? 25 : 25

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == appName || $0.bundleIdentifier?.hasSuffix(appName) == true
}) else {
    FileHandle.standardError.write(Data("未找到运行中的 App：\(appName)\n".utf8))
    exit(2)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let windows = attr(axApp, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
    FileHandle.standardError.write(Data("读不到窗口：请为终端授予「辅助功能」权限\n".utf8))
    exit(3)
}
for window in windows {
    dump(window, depth: 0, maxDepth: maxDepth)
}
