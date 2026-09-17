import SwiftUI

/// **过渡期垫片。后续阶段各页改成 AppKit 时整个文件删掉。**
///
/// 全项目有 21 处 `NavigationLink(value: Route…)`（目录卡片、曲目行、详情页、搜索结果、
/// 资料库网格）。骨架换成 AppKit 之后窗口里已经没有 `NavigationStack` 了，SwiftUI 那个
/// `NavigationLink` 就成了一颗按下去什么都不发生的按钮——21 处逐个改成 `Button` 是
/// 21 处纯噪声的 diff，而这些视图在阶段 3~5 本来就要整个换掉。
///
/// 所以在 Amber 模块里定义一个**同名**的 `NavigationLink`：Swift 的名字查找优先本模块，
/// 那 21 处调用点一个字都不用动，语义变成「登记一次导航意图」——
/// `AppState.push(_:)` 置 `pendingRoute`，`ContentNavigationController` 订阅它入栈。
///
/// 只提供 `init(value:label:)` 这一个入口（那 21 处用的都是它）。
/// 别在新代码里用它：新代码应该直接调 `appState.push(route)`，或者等这一页
/// 换成 AppKit 之后走响应链（计划 §2 铁律 4）。
struct NavigationLink<Label: View>: View {
    private let route: Route
    private let label: Label

    @Environment(AppState.self) private var appState

    init(value: Route, @ViewBuilder label: () -> Label) {
        self.route = value
        self.label = label()
    }

    var body: some View {
        Button {
            appState.push(route)
        } label: {
            label
        }
        .buttonStyle(.plain)
    }
}
