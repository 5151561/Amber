#!/usr/bin/swift

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct Options {
    var appArgument = ""
    var outputPath: String?
    var includeRuntime = false
    var launch = false
    var screenshotPath: String?
    var maxDepth = 25
    var maxChildren = 500
    var widths: [Double] = []
    var settle: Double = 0.7
    var screenshotDir: String?
    var stateLabel = "default"
    var restoreSize = true

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 1

        func requireValue(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError("\(flag) 缺少参数")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            switch arguments[index] {
            case "--output", "-o":
                result.outputPath = try requireValue(after: arguments[index])
            case "--runtime":
                result.includeRuntime = true
            case "--launch":
                result.launch = true
                result.includeRuntime = true
            case "--screenshot":
                result.screenshotPath = try requireValue(after: arguments[index])
                result.includeRuntime = true
            case "--widths":
                let value = try requireValue(after: arguments[index])
                let parsed = value
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .compactMap { Double($0) }
                guard !parsed.isEmpty, parsed.allSatisfy({ $0 >= 320 }) else {
                    throw CLIError("--widths 需要逗号分隔的宽度（>= 320），例如 900,1100,1280,1440")
                }
                result.widths = parsed.sorted()
                result.includeRuntime = true
            case "--settle":
                let value = try requireValue(after: arguments[index])
                guard let seconds = Double(value), seconds >= 0 else {
                    throw CLIError("--settle 必须是非负秒数")
                }
                result.settle = seconds
            case "--screenshot-dir":
                result.screenshotDir = try requireValue(after: arguments[index])
                result.includeRuntime = true
            case "--state":
                result.stateLabel = try requireValue(after: arguments[index])
            case "--keep-size":
                result.restoreSize = false
            case "--max-depth":
                let value = try requireValue(after: arguments[index])
                guard let depth = Int(value), depth >= 0 else {
                    throw CLIError("--max-depth 必须是非负整数")
                }
                result.maxDepth = depth
            case "--max-children":
                let value = try requireValue(after: arguments[index])
                guard let count = Int(value), count > 0 else {
                    throw CLIError("--max-children 必须是正整数")
                }
                result.maxChildren = count
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                if arguments[index].hasPrefix("-") {
                    throw CLIError("未知参数：\(arguments[index])")
                }
                guard result.appArgument.isEmpty else {
                    throw CLIError("只能指定一个 App")
                }
                result.appArgument = arguments[index]
            }
            index += 1
        }

        guard !result.appArgument.isEmpty else {
            throw CLIError("请指定 .app 路径、Bundle ID 或 App 名称")
        }
        return result
    }
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func printUsage() {
    print("""
    用法：swift Tools/ui-spec.swift <App路径|Bundle ID|App名> [选项]

    静态分析（无需权限）：
      swift Tools/ui-spec.swift /System/Applications/Music.app -o music-ui.json

    运行时 AX 树（终端需要“辅助功能”权限）：
      swift Tools/ui-spec.swift Music --runtime -o music-ui.json

    多宽度扫描（把“一次采样”变成“可拟合的规则”）：
      swift Tools/ui-spec.swift Music --widths 900,1100,1280,1440 \\
        --screenshot-dir design-ref/ui-spec/sweep/album-detail \\
        -o design-ref/ui-spec/sweep/album-detail.json

    可选参数：
      --runtime               加入运行中 App 的 Accessibility UI Tree
      --launch                App 未运行时启动它（同时启用 --runtime）
      --screenshot <png>      截取目标 App 最前方窗口（需要“屏幕录制”权限）
      --widths <w1,w2,...>    依次把主窗口改成这些宽度，每个宽度采一次 AX 树
      --settle <秒>           改尺寸后等待布局稳定的时间，默认 0.7
      --screenshot-dir <目录>  扫描时每个宽度各存一张 PNG
      --state <名称>          标注本次扫描的状态（如 sidebar-collapsed），写入 JSON
      --keep-size             扫描结束后不恢复窗口原尺寸
      --max-depth <n>         AX 树最大深度，默认 25
      --max-children <n>      单节点最多子元素数，默认 500
      --output, -o <json>     写入 JSON；未指定时输出到 stdout
    """)
}

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func resolveApp(_ argument: String) throws -> URL {
    let fileManager = FileManager.default
    let expanded = NSString(string: argument).expandingTildeInPath
    if fileManager.fileExists(atPath: expanded) {
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else {
            throw CLIError("目标不是 .app Bundle：\(url.path)")
        }
        return url
    }

    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: argument) {
        return url.standardizedFileURL
    }

    let name = argument.hasSuffix(".app") ? argument : argument + ".app"
    let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
    for root in roots {
        let candidate = URL(fileURLWithPath: root).appendingPathComponent(name)
        if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    throw CLIError("找不到 App：\(argument)")
}

private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch {
        return (-1, error.localizedDescription)
    }
}

private func relativePath(_ url: URL, base: URL) -> String {
    let path = url.standardizedFileURL.path
    let prefix = base.standardizedFileURL.path + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

private func fileInventory(at appURL: URL) -> [String: Any] {
    let fileManager = FileManager.default
    let resourceURL = appURL.appendingPathComponent("Contents/Resources")
    guard let enumerator = fileManager.enumerator(
        at: resourceURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return ["root": "Contents/Resources", "fileCount": 0, "totalBytes": 0, "byExtension": [:]]
    }

    var count = 0
    var totalBytes = 0
    var byExtension: [String: Int] = [:]
    var notable: [String: [String]] = [:]
    let notableExtensions: Set<String> = [
        "nib", "storyboard", "storyboardc", "car", "png", "jpg", "jpeg", "heic", "tiff",
        "pdf", "svg", "icns", "strings", "stringsdict", "css", "html", "js", "asar", "qml"
    ]

    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { continue }
        count += 1
        totalBytes += values.fileSize ?? 0
        let ext = url.pathExtension.lowercased().isEmpty ? "(none)" : url.pathExtension.lowercased()
        byExtension[ext, default: 0] += 1
        if notableExtensions.contains(ext), notable[ext, default: []].count < 40 {
            notable[ext, default: []].append(relativePath(url, base: appURL))
        }
    }

    return [
        "root": "Contents/Resources",
        "fileCount": count,
        "totalBytes": totalBytes,
        "byExtension": byExtension,
        "notableFiles": notable
    ]
}

private func frameworkNames(at appURL: URL) -> [String] {
    let root = appURL.appendingPathComponent("Contents/Frameworks")
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return contents.map(\.lastPathComponent).sorted()
}

private func executableBinaries(at appURL: URL, mainExecutableName: String?) -> [URL] {
    let root = appURL.appendingPathComponent("Contents/MacOS")
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    var binaries = contents.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    if let mainExecutableName {
        let main = root.appendingPathComponent(mainExecutableName).standardizedFileURL
        if FileManager.default.fileExists(atPath: main.path),
           !binaries.contains(where: { $0.standardizedFileURL.path == main.path }) {
            binaries.append(main)
        }
    }
    var unique: [String: URL] = [:]
    for binary in binaries { unique[binary.standardizedFileURL.path] = binary.standardizedFileURL }
    return unique.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func linkedLibraries(executableURLs: [URL]) -> [String] {
    var libraries = Set<String>()
    for executableURL in executableURLs {
        let result = run("/usr/bin/otool", ["-L", executableURL.path])
        guard result.status == 0 else { continue }
        for line in result.output.split(separator: "\n").dropFirst() {
            if let library = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                libraries.insert(String(library))
            }
        }
    }
    return libraries.sorted()
}

private func detectTechnology(frameworks: [String], links: [String], inventory: [String: Any]) -> [String: Any] {
    let haystack = (frameworks + links).joined(separator: "\n").lowercased()
    let extensions = inventory["byExtension"] as? [String: Int] ?? [:]
    var evidence: [String: [String]] = [:]

    func add(_ technology: String, _ reason: String) {
        evidence[technology, default: []].append(reason)
    }

    if haystack.contains("electron framework") || (extensions["asar"] ?? 0) > 0 {
        add("Electron", haystack.contains("electron framework") ? "Electron Framework" : "存在 .asar 资源")
    }
    if haystack.contains("qtcore") || haystack.contains("qtwidgets") || (extensions["qml"] ?? 0) > 0 {
        add("Qt", "检测到 Qt Framework 或 QML")
    }
    if haystack.contains("uikitformac") || haystack.contains("uikitmac") || haystack.contains("macabi") {
        add("Mac Catalyst", "链接 UIKit for Mac / macabi")
    }
    if haystack.contains("swiftui.framework") || haystack.contains("swiftui.framework/versions") {
        add("SwiftUI", "链接 SwiftUI.framework")
    }
    if haystack.contains("appkit.framework") {
        add("AppKit", "链接 AppKit.framework")
    }
    let interfaceBuilderCount = (extensions["nib"] ?? 0) + (extensions["storyboard"] ?? 0) + (extensions["storyboardc"] ?? 0)
    if interfaceBuilderCount > 0 {
        add("AppKit", "包含 \(interfaceBuilderCount) 个 NIB/Storyboard 资源")
    }
    if (extensions["html"] ?? 0) + (extensions["css"] ?? 0) + (extensions["js"] ?? 0) > 20 {
        add("Web UI", "包含大量 HTML/CSS/JavaScript 资源")
    }

    let priority = ["Electron", "Qt", "Mac Catalyst", "SwiftUI", "AppKit", "Web UI"]
    let primary = priority.first(where: { evidence[$0] != nil }) ?? "Unknown"
    return [
        "primary": primary,
        "detected": priority.filter { evidence[$0] != nil },
        "evidence": evidence,
        "note": "技术栈为启发式识别；SwiftUI 与 AppKit 混用时会同时列出。"
    ]
}

private func staticSpecification(appURL: URL) throws -> [String: Any] {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
        throw CLIError("无法读取 Info.plist：\(infoURL.path)")
    }
    let executableName = info["CFBundleExecutable"] as? String
    let executableURL = executableName.map { appURL.appendingPathComponent("Contents/MacOS/\($0)") }
    let binaries = executableBinaries(at: appURL, mainExecutableName: executableName)
    let frameworks = frameworkNames(at: appURL)
    let links = linkedLibraries(executableURLs: binaries)
    let inventory = fileInventory(at: appURL)
    var architectures: [String] = []
    if let executableURL {
        let result = run("/usr/bin/lipo", ["-archs", executableURL.path])
        if result.status == 0 {
            architectures = result.output.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    let selectedInfoKeys = [
        "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName", "CFBundleShortVersionString",
        "CFBundleVersion", "LSMinimumSystemVersion", "DTPlatformVersion", "DTSDKName", "NSPrincipalClass"
    ]
    var bundleInfo: [String: Any] = ["path": appURL.path]
    for key in selectedInfoKeys where info[key] != nil { bundleInfo[key] = info[key] }
    if let executableName { bundleInfo["executable"] = "Contents/MacOS/\(executableName)" }
    bundleInfo["architectures"] = architectures

    return [
        "bundle": bundleInfo,
        "technology": detectTechnology(frameworks: frameworks, links: links, inventory: inventory),
        "analyzedBinaries": binaries.map { relativePath($0, base: appURL) },
        "linkedLibraries": links,
        "embeddedFrameworks": frameworks,
        "resources": inventory
    ]
}

private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func axString(_ element: AXUIElement, _ name: String) -> String? {
    axAttribute(element, name) as? String
}

private func axPoint(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let raw = axAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &result) ? result : nil
}

private func axSize(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let raw = axAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == .cgSize else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value, .cgSize, &result) ? result : nil
}

/// SwiftUI 的占位元素（LazyVStack 常驻列头、零高容器等）frame 会是 (inf, inf)，
/// 非有限值不是合法 JSON，JSONSerialization 会整份写失败。统一压成 0 保住整棵树。
private func number(_ value: CGFloat) -> Double {
    let result = Double(value)
    return result.isFinite ? result : 0
}

private func rectJSON(origin: CGPoint, size: CGSize) -> [String: Double] {
    ["x": number(origin.x), "y": number(origin.y), "width": number(size.width), "height": number(size.height)]
}

private func simpleAXValue(_ raw: CFTypeRef?) -> Any? {
    guard let raw else { return nil }
    if let string = raw as? String { return string }
    if let number = raw as? NSNumber { return number }
    if let strings = raw as? [String] { return strings }
    return nil
}

private final class AXTreeEncoder {
    let maxDepth: Int
    let maxChildren: Int
    var totalNodes = 0
    var truncatedNodes = 0
    private var visited = Set<CFHashCode>()

    init(maxDepth: Int, maxChildren: Int) {
        self.maxDepth = maxDepth
        self.maxChildren = maxChildren
    }

    func encode(_ element: AXUIElement, depth: Int, windowOrigin: CGPoint?) -> [String: Any] {
        totalNodes += 1
        var result: [String: Any] = [:]
        let attributes: [(String, String)] = [
            ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute),
            ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
            ("help", kAXHelpAttribute), ("identifier", kAXIdentifierAttribute),
            ("value", kAXValueAttribute), ("roleDescription", kAXRoleDescriptionAttribute),
            ("orientation", kAXOrientationAttribute), ("enabled", kAXEnabledAttribute),
            ("focused", kAXFocusedAttribute), ("selected", kAXSelectedAttribute),
            ("minValue", kAXMinValueAttribute), ("maxValue", kAXMaxValueAttribute)
        ]
        for (jsonName, axName) in attributes {
            if let value = simpleAXValue(axAttribute(element, axName)) { result[jsonName] = value }
        }

        if let origin = axPoint(element, kAXPositionAttribute), let size = axSize(element, kAXSizeAttribute) {
            result["frame"] = rectJSON(origin: origin, size: size)
            if let windowOrigin {
                result["frameInWindow"] = rectJSON(
                    origin: CGPoint(x: origin.x - windowOrigin.x, y: origin.y - windowOrigin.y),
                    size: size
                )
            }
        }

        guard depth < maxDepth else {
            if axAttribute(element, kAXChildrenAttribute) != nil {
                result["truncated"] = "maxDepth"
                truncatedNodes += 1
            }
            return result
        }

        let identity = CFHash(element)
        guard !visited.contains(identity) else {
            result["truncated"] = "cycle"
            truncatedNodes += 1
            return result
        }
        visited.insert(identity)
        defer { visited.remove(identity) }

        if let allChildren = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement], !allChildren.isEmpty {
            let children = Array(allChildren.prefix(maxChildren))
            result["children"] = children.map { encode($0, depth: depth + 1, windowOrigin: windowOrigin) }
            result["childCount"] = allChildren.count
            if allChildren.count > children.count {
                result["omittedChildCount"] = allChildren.count - children.count
                truncatedNodes += 1
            }
        }
        return result
    }
}

private func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
    (axAttribute(element, name) as? NSNumber)?.boolValue
}

private func axSetSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
    var target = size
    guard let value = AXValueCreate(.cgSize, &target) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
}

/// 扫描要改的是「主窗口」；AXWindows 的顺序不保证是 z-order，拿 AXMainWindow 更稳。
private func mainWindow(of axApp: AXUIElement, fallback: [AXUIElement]) -> AXUIElement? {
    if let raw = axAttribute(axApp, kAXMainWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
        return (raw as! AXUIElement)
    }
    return fallback.first
}

/// 反复 setSize 直到 AX 报告的尺寸稳定：有些窗口有最小宽度或分栏吸附，
/// 请求值和实际值可能不同，必须记录实际值，否则拟合的自变量是错的。
private func applyWidth(_ width: Double, to window: AXUIElement, settle: Double) -> CGSize? {
    guard let current = axSize(window, kAXSizeAttribute) else { return nil }
    _ = axSetSize(window, CGSize(width: width, height: current.height))
    let deadline = Date().addingTimeInterval(2.0)
    var last = current
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        guard let now = axSize(window, kAXSizeAttribute) else { break }
        if abs(now.width - last.width) < 0.01 && abs(now.width - width) < 1.0 { break }
        last = now
    }
    Thread.sleep(forTimeInterval: settle)
    return axSize(window, kAXSizeAttribute)
}

private func sweepSpecification(
    axApp: AXUIElement,
    windows: [AXUIElement],
    pid: pid_t,
    options: Options
) -> [String: Any] {
    guard let window = mainWindow(of: axApp, fallback: windows) else {
        return ["error": "找不到主窗口"]
    }
    if axBool(window, "AXFullScreen") == true {
        return ["error": "主窗口处于全屏；扫描前请退出全屏"]
    }
    var settable: DarwinBoolean = false
    if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
       settable == false {
        return ["error": "主窗口的 AXSize 不可写"]
    }

    let originalSize = axSize(window, kAXSizeAttribute)
    var samples: [[String: Any]] = []

    // 预热：从原尺寸跳到第一个采样宽度是最大的一跳，重排最久。
    // 不预热的话第一份样本会缺整层容器（实测 AXOutline 整个不出现），拟合样本随即塌掉。
    if let first = options.widths.first {
        _ = applyWidth(first, to: window, settle: options.settle)
    }

    for width in options.widths {
        guard let actual = applyWidth(width, to: window, settle: options.settle) else {
            samples.append(["requestedWidth": width, "error": "改尺寸后读不到 AXSize"])
            continue
        }
        // 连续两次编码得到同样的节点数才认为布局稳定；否则重采。
        var encoder = AXTreeEncoder(maxDepth: options.maxDepth, maxChildren: options.maxChildren)
        var origin = axPoint(window, kAXPositionAttribute)
        var tree = encoder.encode(window, depth: 0, windowOrigin: origin)
        var attempts = 0
        var stable = false
        while attempts < 3 {
            let probe = AXTreeEncoder(maxDepth: options.maxDepth, maxChildren: options.maxChildren)
            origin = axPoint(window, kAXPositionAttribute)
            let next = probe.encode(window, depth: 0, windowOrigin: origin)
            if probe.totalNodes == encoder.totalNodes {
                stable = true
                encoder = probe
                tree = next
                break
            }
            encoder = probe
            tree = next
            attempts += 1
            Thread.sleep(forTimeInterval: options.settle)
        }
        var sample: [String: Any] = [
            "requestedWidth": width,
            "windowSize": ["width": number(actual.width), "height": number(actual.height)],
            "window": tree,
            "nodeCount": encoder.totalNodes,
            "truncatedNodeCount": encoder.truncatedNodes,
            "settled": stable,
            "settleAttempts": attempts
        ]
        if let directory = options.screenshotDir {
            let name = String(format: "w%04d.png", Int(actual.width.rounded()))
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory),
                withIntermediateDirectories: true
            )
            sample["screenshot"] = captureScreenshot(pid: pid, outputPath: path)
        }
        samples.append(sample)
    }

    if options.restoreSize, let originalSize {
        _ = axSetSize(window, originalSize)
    }

    var result: [String: Any] = [
        "state": options.stateLabel,
        "settleSeconds": options.settle,
        "requestedWidths": options.widths,
        "samples": samples,
        "note": "拟合时用 windowSize.width 作自变量，不要用 requestedWidth。"
    ]
    if let originalSize {
        result["originalSize"] = ["width": number(originalSize.width), "height": number(originalSize.height)]
    }
    return result
}

private func runningApplication(for appURL: URL, bundleID: String?) -> NSRunningApplication? {
    let targetPath = appURL.standardizedFileURL.path
    return NSWorkspace.shared.runningApplications.first { app in
        if let bundleID, app.bundleIdentifier == bundleID { return true }
        return app.bundleURL?.standardizedFileURL.path == targetPath
    }
}

private func launchApplication(at appURL: URL) throws -> NSRunningApplication {
    let semaphore = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?
    var launchError: Error?
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        launched = app
        launchError = error
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 15)
    if let launchError { throw launchError }
    guard let launched else { throw CLIError("启动 App 超时") }
    Thread.sleep(forTimeInterval: 1.0)
    return launched
}

private func windowNumber(for pid: pid_t) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    return list.first(where: {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
        ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    })?[kCGWindowNumber as String] as? Int
}

private func captureScreenshot(pid: pid_t, outputPath: String) -> [String: Any] {
    guard let number = windowNumber(for: pid) else {
        return ["requestedPath": outputPath, "error": "找不到屏幕上的主窗口"]
    }
    let absolute = URL(fileURLWithPath: outputPath).standardizedFileURL.path
    let result = run("/usr/sbin/screencapture", ["-x", "-l", String(number), absolute])
    if result.status == 0, FileManager.default.fileExists(atPath: absolute) {
        return ["path": absolute, "windowNumber": number]
    }
    return [
        "requestedPath": absolute,
        "windowNumber": number,
        "error": result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "截图失败；请检查屏幕录制权限" : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    ]
}

private func runtimeSpecification(
    appURL: URL,
    bundleID: String?,
    options: Options
) -> [String: Any] {
    var app = runningApplication(for: appURL, bundleID: bundleID)
    if app == nil, options.launch {
        do { app = try launchApplication(at: appURL) }
        catch { return ["available": false, "error": "启动失败：\(error.localizedDescription)"] }
    }
    guard let app else {
        return ["available": false, "error": "App 未运行；先启动它，或添加 --launch"]
    }

    var result: [String: Any] = [
        "available": true,
        "pid": Int(app.processIdentifier),
        "accessibilityTrusted": AXIsProcessTrusted()
    ]
    guard AXIsProcessTrusted() else {
        result["error"] = "当前终端没有“辅助功能”权限，无法读取 AX UI Tree"
        if let screenshotPath = options.screenshotPath {
            result["screenshot"] = captureScreenshot(pid: app.processIdentifier, outputPath: screenshotPath)
        }
        return result
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let windows = axAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
        result["error"] = "无法读取 AXWindows；目标 App 可能尚未完成启动"
        return result
    }
    result["coordinateSystem"] = "screen and window-relative points; origins are top-left"

    if !options.widths.isEmpty {
        // 取色和某些控件绘制依赖窗口是否 key，扫描前先激活。
        app.activate()
        Thread.sleep(forTimeInterval: 0.4)
        result["sweep"] = sweepSpecification(
            axApp: axApp,
            windows: windows,
            pid: app.processIdentifier,
            options: options
        )
        result["windowCount"] = windows.count
        return result
    }

    let encoder = AXTreeEncoder(maxDepth: options.maxDepth, maxChildren: options.maxChildren)
    result["windows"] = windows.map { window -> [String: Any] in
        let origin = axPoint(window, kAXPositionAttribute)
        return encoder.encode(window, depth: 0, windowOrigin: origin)
    }
    result["windowCount"] = windows.count
    result["nodeCount"] = encoder.totalNodes
    result["truncatedNodeCount"] = encoder.truncatedNodes
    if let screenshotPath = options.screenshotPath {
        result["screenshot"] = captureScreenshot(pid: app.processIdentifier, outputPath: screenshotPath)
    }
    return result
}

do {
    let options = try Options.parse(CommandLine.arguments)
    let appURL = try resolveApp(options.appArgument)
    var document = try staticSpecification(appURL: appURL)
    let bundle = document["bundle"] as? [String: Any]
    if options.includeRuntime {
        document["runtime"] = runtimeSpecification(
            appURL: appURL,
            bundleID: bundle?["CFBundleIdentifier"] as? String,
            options: options
        )
    }
    document["schemaVersion"] = 1
    document["generatedAt"] = ISO8601DateFormatter().string(from: Date())
    document["measurement"] = [
        "geometryUnit": "point",
        "pixelCalibration": "Use the same macOS version, window size, display scale and appearance for comparisons."
    ]

    guard JSONSerialization.isValidJSONObject(document) else {
        throw CLIError("内部错误：生成结果不是合法 JSON")
    }
    let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    if let outputPath = options.outputPath {
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        print("已写入 UI specification：\(outputURL.path)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    stderr("错误：\(error)")
    printUsage()
    exit(1)
}
