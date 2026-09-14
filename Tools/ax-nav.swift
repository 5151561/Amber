#!/usr/bin/swift
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }

func labels(_ e: AXUIElement) -> [String] {
    [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute)].compactMap { $0 }
}
func descendantText(_ e: AXUIElement, depth: Int = 0) -> String {
    if depth > 6 { return "" }
    return (labels(e) + children(e).map { descendantText($0, depth: depth + 1) }).joined(separator: " ")
}
func find(_ e: AXUIElement, depth: Int = 0, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
    if test(e) { return e }
    guard depth < 30 else { return nil }
    for c in children(e) { if let hit = find(c, depth: depth + 1, test) { return hit } }
    return nil
}
func findAll(_ e: AXUIElement, depth: Int = 0, _ test: (AXUIElement) -> Bool, into acc: inout [AXUIElement]) {
    if test(e) { acc.append(e) }
    guard depth < 30 else { return }
    for c in children(e) { findAll(c, depth: depth + 1, test, into: &acc) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: axnav.swift <sidebar|press|clicktext|type|typeonly> <text> [bundleID|应用名]"); exit(1)
}
let mode = args[0], target = args[1]
let appHint = args.count >= 3 ? args[2] : "com.apple.Music"

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == appHint || $0.localizedName == appHint
        || $0.bundleURL?.deletingPathExtension().lastPathComponent == appHint
}) else {
    print("\(appHint) 未运行"); exit(1)
}
app.activate()
Thread.sleep(forTimeInterval: 0.4)
let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let window = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first else {
    print("无窗口"); exit(1)
}

switch mode {
case "sidebar":
    guard let outline = find(window, { role($0) == "AXOutline" }) else { print("找不到边栏"); exit(1) }
    var rows: [AXUIElement] = []
    findAll(outline, { str($0, kAXSubroleAttribute) == "AXOutlineRow" }, into: &rows)
    guard let row = rows.first(where: { descendantText($0).contains(target) }) else {
        print("找不到边栏项：\(target)"); exit(1)
    }
    var err = AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
    if err != .success { err = AXUIElementPerformAction(row, kAXPressAction as CFString) }
    print(err == .success ? "已选中：\(target)" : "选中失败(\(err.rawValue))：\(target)")
case "press":
    var hits: [AXUIElement] = []
    findAll(window, { ["AXButton", "AXMenuButton", "AXLink"].contains(role($0)) && labels($0).contains { $0.contains(target) } }, into: &hits)
    guard let el = hits.first else { print("找不到控件：\(target)"); exit(1) }
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    print(err == .success ? "已点击：\(labels(el).first ?? target)" : "点击失败(\(err.rawValue))")
case "clicktext":
    var hits: [AXUIElement] = []
    findAll(window, { labels($0).contains { $0 == target } }, into: &hits)
    if hits.isEmpty {
        findAll(window, { labels($0).contains { $0.contains(target) } }, into: &hits)
    }
    guard let el = hits.last else { print("找不到文本：\(target)"); exit(1) }
    var pv: CFTypeRef?; var sv: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv)
    _ = AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv)
    var origin = CGPoint.zero; var size = CGSize.zero
    guard let pv, let sv,
          AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sv as! AXValue, .cgSize, &size) else { print("无法读取位置"); exit(1) }
    let pt = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    print("已点击坐标 \(Int(pt.x)),\(Int(pt.y))：\(target)")
case "type", "typeonly":
    guard let field = find(window, { str($0, kAXSubroleAttribute) == "AXSearchField" || role($0) == "AXTextField" }) else {
        print("找不到搜索框"); exit(1)
    }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in target.unicodeScalars {
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        var unit = UniChar(ch.value)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.4)
    if mode == "type" {
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
    print("已输入：\(target)")
default:
    print("未知模式"); exit(1)
}
Thread.sleep(forTimeInterval: 0.3)
