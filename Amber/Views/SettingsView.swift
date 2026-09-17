import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口的页。Music 是通用／播放／文件／高级 四张，Amber 在「播放」后面多插一张自己的「音源」。
enum SettingsTab: Hashable {
    case general, playback, providers, files, advanced
}

// 设置窗的复刻实录见 `settings 规格`（2026-09-05，AX 树 +
// 深色截图 + 补测的「导入设置…」子对话框）：
//
// - 窗口是 `AXDialog`，**标题 = 当前 tab 名**，顶上一条工具栏——这三件（含红绿灯全隐）
//   由 `SettingsWindowController` 的`NSTabViewController(tabStyle: .toolbar)` 给。
// - 内容区是**一个无标题 group 装全部控件**：两列（标签右对齐 : 控件左对齐），
//   组与组之间通栏 hairline，**没有分组框**。
// - 底部一行按钮，`好` 带 default_action（回车提交），所以窗口里编辑的是草稿。
//
// **Music 有的每一条都抄了**，包括 Amber 还没有的功能——那些是占位：控件照抄、值照存
// （见 `SettingsValues` 各字段的注释，写「占位」的就是还没有消费者的），
// 功能补上时直接接线，不用再动这一层。唯一没抄的是左下角的「帮助」键：Amber 没有帮助书。
//
// 文案逐字照 Music 的 AX 实测值，只在两种情况下改写：把「音乐」换成「Amber」，
// 以及把苹果专有的服务（Apple Music 云资料库 / iTunes Store 购买 / 隔空播放）换成
// Amber 的对应物或删掉——句子里留着一个 Amber 永远不会有的东西，比不抄更糟。

// MARK: - 草稿

/// 跨五张 pane 共享的那一份草稿。
///
/// 五张页各自装在 `SettingsWindowController` 的一个`NSHostingController` 里，
/// 是**各自独立的一棵** SwiftUI 树，`@Binding` 没法跨树共享，所以抬成一个引用类型，
/// 由窗口控制器建一份、注入给五张页。
@MainActor
@Observable
final class SettingsDraftModel {
    var draft = SettingsDraft()

    /// 「取消 / 好」按完要关掉的那扇窗，由 `SettingsWindowController` 填成
    /// 「关我自己那扇」——不能就手关 key window，那可能是别人。
    ///
    /// 标 `@ObservationIgnored`：它不是状态，参与观察只会白记一次依赖。
    @ObservationIgnored var close: () -> Void = {}

    /// 每次开窗重新抓一遍各 store 的当前值。
    func refresh(settings: AppSettings,
                 providerSettings: ProviderSettingsStore,
                 listViewSize: ListViewSizeStore,
                 qqLogin: QQLoginStore) {
        draft = SettingsDraft(settings: settings,
                              providerSettings: providerSettings,
                              listViewSize: listViewSize,
                              qqLogin: qqLogin)
    }
}

/// 设置窗口里正在编辑的一份值。
///
/// Music 的设置是**按「好」才生效**的——窗口底下那对取消/好就是这个意思
/// （`[AX]` 好带 default_action）。Amber 的偏好本来都是 didSet 即时落盘，
/// 所以窗口里改的是这份草稿，`好` 时一次性写回各个 store，`取消` 直接丢掉。
///
/// 只装得下**值类**偏好。登录/退出、还原缓存这些是按下去当场就发生的动作，
/// 取消撤不回来——Music 的「还原警告 / 还原缓存」也是当场就做。
struct SettingsDraft: Equatable {
    /// 复刻 Music 设置窗那一整套（含占位项）
    var values = SettingsValues()
    // 下面四样在 Amber 里本来就有自己的 store，不并进 SettingsValues：
    // 它们在设置窗以外也有读者（表格、音源切换、取流），搬家只会多一层转发。
    var enabledProviders: Set<ProviderKind> = ProviderSettingsStore.initialEnabled
    var defaultProvider: ProviderKind = .qq
    var listSize: ListViewSize = .medium
    var quality: StreamQuality = .standard

    init() {}

    @MainActor
    init(settings: AppSettings,
         providerSettings: ProviderSettingsStore,
         listViewSize: ListViewSizeStore,
         qqLogin: QQLoginStore) {
        values = settings.values
        enabledProviders = Set(providerSettings.orderedEnabled)
        defaultProvider = providerSettings.defaultProvider
        listSize = listViewSize.size
        quality = qqLogin.quality
    }

    /// 至少要留一个源：最后一个开着的不许关（与 `ProviderSettingsStore.canDisable` 同义，
    /// 只是这里判的是草稿而不是已落盘的那份）。
    func canDisable(_ kind: ProviderKind) -> Bool {
        !(enabledProviders.count == 1 && enabledProviders.contains(kind))
    }

    mutating func setEnabled(_ on: Bool, for kind: ProviderKind) {
        if on {
            enabledProviders.insert(kind)
        } else {
            guard canDisable(kind) else { return }
            enabledProviders.remove(kind)
            // 默认源被关掉了就顺移到还开着的第一个，popup 里不能停在一个已关的源上
            if !enabledProviders.contains(defaultProvider), let fallback = orderedEnabled.first {
                defaultProvider = fallback
            }
        }
    }

    /// 已启用的源，按 ProviderKind 的声明顺序（与 store 侧同一种排法）
    var orderedEnabled: [ProviderKind] {
        ProviderKind.allCases.filter(enabledProviders.contains)
    }

    @MainActor
    func apply(settings: AppSettings,
               providerSettings: ProviderSettingsStore,
               listViewSize: ListViewSizeStore,
               qqLogin: QQLoginStore) {
        settings.values = values
        // 先开后关：反过来的话，中间会短暂只剩零个源，被「最后一个不许关」挡住。
        for kind in ProviderKind.allCases where enabledProviders.contains(kind) {
            providerSettings.setEnabled(true, for: kind)
        }
        for kind in ProviderKind.allCases where !enabledProviders.contains(kind) {
            providerSettings.setEnabled(false, for: kind)
        }
        providerSettings.defaultProvider = defaultProvider
        listViewSize.size = listSize
        qqLogin.quality = quality
    }
}

// MARK: - 页骨架

private typealias M = MusicMetrics.Settings

/// 正文内那三条蓝链的去向。
///
/// Music 指向的是它自己的支持文章。Amber 不是 Apple，编一个假的文章号只会 404，
/// 所以指向**真实可达**的公开页：讲的是同一个技术概念，读者点过去不会扑空。
private enum SettingsLinks {
    static let musicGuide = "https://support.apple.com/zh-cn/guide/music/welcome/mac"
    static let dolbyAtmos = "https://www.dolby.com/technologies/dolby-atmos/"
}

/// 一页设置：上面两列网格，下面按钮行，宽度恒 650（[AX]），高度随内容。
private struct SettingsPane<Content: View>: View {
    /// 「好」按下时要写回哪一份草稿。
    /// 放在 content 前面：尾随闭包要落在最后一个参数上才不触发 backward matching 警告。
    var model: SettingsDraftModel
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: M.labelGap,
                 verticalSpacing: M.rowSpacing) {
                content
            }
            .padding(.horizontal, M.contentInset)
            .padding(.top, M.contentTop)
            .padding(.bottom, M.groupSpacing)
            SettingsButtonRow(model: model)
        }
        .frame(width: M.windowWidth)
    }
}

/// 底部按钮行：通栏细线 + 右下角成对的「取消 / 好」（[AX] 各 52×26，相隔 10）。
private struct SettingsButtonRow: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(QQLoginStore.self) private var qqLogin
    @Environment(ProviderSettingsStore.self) private var providerSettings
    @EnvironmentObject private var listViewSize: ListViewSizeStore
    var model: SettingsDraftModel

    var body: some View {
        VStack(spacing: 0) {
            // 组分隔线内缩 20，这一条通栏——[PX] 两者不是同一条线
            Divider()
            HStack(spacing: M.buttonSpacing) {
                Spacer(minLength: 0)
                // Esc 也是取消（[AX] 那颗只是普通按钮，但对话框的惯例如此）
                // 文字外面套一层撑满的 frame：只给按钮定宽的话，AppKit 按钮不跟着长，
                // 只是把自然宽的那颗在框里居中，两颗就成了 50/37 的不等宽。
                Button { model.close() } label: { Text("取消").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: M.buttonWidth, height: M.buttonHeight)
                Button {
                    model.draft.apply(settings: settings,
                                      providerSettings: providerSettings,
                                      listViewSize: listViewSize,
                                      qqLogin: qqLogin)
                    // 「歌曲更改时」勾上了才去要通知授权：没勾就别打扰
                    //（方法自己会挡住重复请求，用户拒过之后再调也不会弹）
                    if model.draft.values.notifyOnSongChange {
                        Task { await NowPlayingCenter.shared.requestNotificationAuthorizationIfNeeded() }
                    }
                    model.close()
                } label: {
                    Text("好").frame(maxWidth: .infinity)
                }
                // [AX] 好带 default_action：回车提交
                .keyboardShortcut(.defaultAction)
                .frame(width: M.buttonWidth, height: M.buttonHeight)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, M.bottomBarTop)
            .padding(.bottom, M.bottomBarBottom)
            .padding(.horizontal, M.contentInset)
        }
    }
}

// MARK: - 行

// 这几件必须是**函数**而不是 View 类型：`GridRow` 只有作为`Grid` 的直接子节点才
// 参与分列，包进一个自定义 View 里会被当成一个整格。
//
// [HIG] 这一层的标签列（`settingsRow("列表大小：")`）只是屏幕上的一行文字，
// 不是控件的可达名称：AX 树读的是控件**自己**的 label。所以每颗 popup 都要
// 传一个真标签，再用 `.labelsHidden()` 把它藏起来——版式一模一样，
// 但 VoiceOver 从「弹出式按钮，中」变成「列表大小，弹出式按钮，中」。
// `Picker("", …)` 不等于「没有标签」，那是一个空名字，念出来只剩当前值。

/// 「标签：控件」一行。标签列吃掉控件列以外的宽度并右对齐（[AX] 标签右沿 583 → 控件 589）。
@ViewBuilder
private func settingsRow<Control: View>(_ label: String,
                                        @ViewBuilder control: () -> Control) -> some View {
    GridRow(alignment: .firstTextBaseline) {
        Text(label)
            .font(.system(size: M.labelSize))
            .frame(maxWidth: .infinity, alignment: .trailing)
        control()
            .frame(width: M.controlColumnWidth, alignment: .leading)
    }
}

/// 没有标签的一行（组里第二件起的勾选框都是这样）。
@ViewBuilder
private func settingsRow<Control: View>(@ViewBuilder control: () -> Control) -> some View {
    GridRow(alignment: .firstTextBaseline) {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        control()
            .frame(width: M.controlColumnWidth, alignment: .leading)
    }
}

/// 节标题（Music 的「无损音频 / 空间音频 / 视频质量」）：加粗，与控件列同缩进，
/// [PX] 不是大字标题。
@ViewBuilder
private func settingsSection(_ title: String) -> some View {
    settingsRow {
        Text(title)
            .font(.system(size: M.labelSize, weight: .bold))
    }
}

/// 辅助说明：次级灰，相对控件列右缩 20——即与它上面那个勾选框的**文字**对齐（[PX]）。
/// 文本按 markdown 解析，所以正文内嵌的蓝链（Music 那三条 AXTextArea + AXLink）
/// 直接写 `[文字](链接)` 就行。
@ViewBuilder
private func settingsDescription(_ text: String) -> some View {
    settingsRow {
        Text(.init(text))
            .font(.system(size: M.descriptionSize))
            .foregroundStyle(.secondary)
            .tint(.blue)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, M.descriptionIndent)
    }
}

/// 组与组之间的通栏 hairline（[PX] 无分组框，只有这条线）。
@ViewBuilder
private func settingsDivider() -> some View {
    GridRow {
        Divider()
            .gridCellColumns(2)
            // 网格自己的行距是 6，两边各补 1.5 凑成实录的 15
            .padding(.vertical, (M.groupSpacing - 2 * M.rowSpacing) / 2)
    }
}

/// 高级页那三行「标签： [按钮]」。[AX] 它们**不走主标签列**：标签缩在控件列里
/// （591 = 控件列 569 + 22），右对齐到按钮左沿，按钮定宽 116.5。
@ViewBuilder
private func settingsButtonRow(_ label: String,
                               button title: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
    settingsRow {
        HStack(spacing: M.labelGap) {
            Text(label)
                .font(.system(size: M.labelSize))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .frame(width: M.wideButtonWidth)
            .disabled(disabled)
        }
        .padding(.leading, M.descriptionIndent)
    }
}

// MARK: - 通用

/// 通用页。[AX] 自上而下六组：资料库 / 听歌历史 / 更大字体 / 显示+列表大小 / 通知 / 隐私链接。
struct GeneralSettingsPane: View {
    @Bindable var model: SettingsDraftModel
    @Environment(QQLoginStore.self) private var qqLogin
    @State private var showingPrivacy = false

    var body: some View {
        SettingsPane(model: model) {
            // [AX] Music 把账号邮箱拼进标题里（「同步资料库(kizztrx@gmail.com)」），
            // Amber 拼 QQ 的 uin——同一件事：这条同步是跟着账号走的。
            settingsRow("资料库：") {
                Toggle(syncTitle, isOn: $model.draft.values.syncLibrary)
            }
            settingsDescription("显示你在 QQ 音乐账号里收藏和创建的全部内容。同步后，账号里的歌单会出现在本机资料库中。")
            settingsRow {
                Toggle("自动下载", isOn: $model.draft.values.automaticDownloads)
            }
            settingsDescription("将音乐添加到资料库时自动下载，使音乐可离线播放。")
            settingsRow {
                Toggle("下载杜比全景声", isOn: $model.draft.values.downloadDolbyAtmos)
            }
            settingsRow {
                Toggle("始终检查可用的下载", isOn: $model.draft.values.alwaysCheckForDownloads)
            }

            settingsDivider()

            settingsRow {
                Toggle("使用听歌历史记录", isOn: $model.draft.values.useListeningHistory)
            }
            settingsDescription("此 Mac 上播放的音乐将会出现在「最近播放」中，并计入播放次数、影响资料库里按播放次数的排序。")

            settingsDivider()

            settingsRow("更大字体：") {
                Picker("更大字体", selection: $model.draft.values.largerText) {
                    ForEach(LargerTextTarget.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            settingsDescription("同时显示时，选择要以更大字体显示歌词还是发音。")

            settingsDivider()

            settingsRow("显示：") {
                Toggle("iTunes Store", isOn: $model.draft.values.showITunesStore)
            }
            settingsRow {
                Toggle("星级评分", isOn: $model.draft.values.showStarRatings)
            }
            settingsRow {
                Toggle("歌曲列表复选框", isOn: $model.draft.values.songListCheckboxes)
            }
            settingsRow("列表大小：") {
                Picker("列表大小", selection: $model.draft.listSize) {
                    ForEach(ListViewSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                // [PX] Music 的 popup 一律宽随内容（62.5~302.5）。**不要写死宽度**：
                // SwiftUI 会把窄按钮在框里居中，于是控件列左沿就对不上说明文字了。
                .fixedSize()
            }

            settingsDivider()

            settingsRow("通知：") {
                Toggle("歌曲更改时", isOn: $model.draft.values.notifyOnSongChange)
            }

            settingsDivider()

            // [AX] id=GeneralPrefsprivacyLinkButton，[PX] 红/粉色文字、独占一行，
            // 左沿 609 与说明文字同缩进（不是与勾选框同列）
            settingsRow {
                Button("了解数据的管理方式…") { showingPrivacy = true }
                    .buttonStyle(.plain)
                    .font(.system(size: M.labelSize))
                    .foregroundStyle(Color.amberKey)
                    .padding(.leading, M.descriptionIndent)
            }
        }
        // Music 这颗键开的是 Apple 的「数据与隐私」页。Amber 没有服务端，实话实说更有用。
        .alert("Amber 怎么处理你的数据", isPresented: $showingPrivacy) {
            Button("好", role: .cancel) {}
        } message: {
            Text("Amber 没有自己的服务器。资料库、播放历史、设置都只存在这台 Mac 上；"
                 + "网络请求只发给你启用的音源（QQ 音乐／网易云音乐）和它们的封面 CDN。"
                 + "QQ 账号的 cookie 存在本机钥匙串里，只用于向 QQ 音乐取流与取歌单。")
        }
    }

    private var syncTitle: String {
        if let uin = qqLogin.credential?.uin { return "同步资料库(uin \(uin))" }
        return "同步资料库"
    }
}

// MARK: - 播放

/// 播放页。[AX] 自上而下：歌曲过渡 / 声音增强器+音量平衡 / 无损音频 / 空间音频 / 视频质量。
struct PlaybackSettingsPane: View {
    @Bindable var model: SettingsDraftModel

    var body: some View {
        SettingsPane(model: model) {
            settingsRow {
                Toggle("歌曲过渡", isOn: $model.draft.values.crossfade)
            }
            settingsDescription("歌曲开头和结尾无缝衔接。专辑和部分类型仍将在无过渡的状态下播放。")
            // [AX] 勾选框关着时整颗 popup 禁用灰显
            settingsRow("过渡效果样式：") {
                Picker("过渡效果样式", selection: $model.draft.values.crossfadeStyle) {
                    ForEach(CrossfadeStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.draft.values.crossfade)
            }
            settingsDescription("根据对音乐调性和拍速的分析，歌曲会在最佳时间节点过渡。"
                                + "[进一步了解…](\(SettingsLinks.musicGuide))")

            settingsDivider()

            // [AX] 这颗勾选框的标题自带冒号（id=SoundEnhancerCheckbox）
            settingsRow {
                Toggle("声音增强器：", isOn: $model.draft.values.soundEnhancer)
            }
            settingsRow {
                VStack(alignment: .leading, spacing: 0) {
                    // [AX] 滑杆 245 宽、量程 0–255，两端标签「低」「高」贴在滑杆两头下面
                    Slider(value: $model.draft.values.soundEnhancerLevel, in: 0...255)
                        .frame(width: M.sliderWidth)
                        .disabled(!model.draft.values.soundEnhancer)
                    HStack(spacing: 0) {
                        Text("低")
                        Spacer(minLength: 0)
                        Text("高")
                    }
                    .font(.system(size: M.descriptionSize))
                    .foregroundStyle(.secondary)
                    .frame(width: M.sliderWidth)
                }
            }
            settingsRow {
                Toggle("音量平衡", isOn: $model.draft.values.soundCheck)
            }
            settingsDescription("自动将歌曲播放音量调节到相同水平。")

            settingsDivider()

            settingsSection("无损音频")
            settingsRow {
                Toggle("启用无损音频", isOn: $model.draft.values.losslessEnabled)
            }
            settingsRow("流播放：") {
                qualityPicker("无损流播放质量", selection: $model.draft.quality)
            }
            settingsRow("下载：") {
                qualityPicker("无损下载质量", selection: $model.draft.values.downloadQuality)
            }
            settingsDescription("无损文件保留了原始音频的所有细节。打开此设置将显著消耗更多数据。")

            settingsDivider()

            settingsSection("空间音频")
            settingsRow("杜比全景声：") {
                Picker("杜比全景声", selection: $model.draft.values.dolbyAtmos) {
                    ForEach(DolbyAtmosMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            settingsDescription("以杜比全景声和其他杜比音效格式播放支持的歌曲。"
                                + "[关于杜比全景声…](\(SettingsLinks.dolbyAtmos))")
            settingsRow("HDMI直通：") {
                Picker("HDMI直通", selection: $model.draft.values.hdmiPassthrough) {
                    ForEach(HDMIPassthrough.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            // [推] 追加的这一句不是 Music 的文案：Music 自己走的是系统私有通路，
            // 第三方 App 没有，说明里不写清楚就成了一个骗人的开关（见 AppSettings.hdmiPassthrough）。
            settingsDescription("连接支持的设备时，使用“HDMI直通”以杜比全景声和其他杜比音效格式播放支持的音频。"
                                + "macOS 未向第三方 App 开放杜比直通，此选项暂不改变输出方式；"
                                + "接 HDMI 时「杜比全景声＝自动」会改用无损档。"
                                + "[关于HDMI直通…](\(SettingsLinks.musicGuide))")

            settingsDivider()

            settingsSection("视频质量")
            settingsRow("流播放：") {
                Picker("视频流播放质量", selection: $model.draft.values.videoStreamQuality) {
                    ForEach(VideoStreamQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            settingsRow("下载：") {
                Picker("视频下载质量", selection: $model.draft.values.videoDownloadQuality) {
                    ForEach(VideoDownloadQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// 无损那两颗 popup。Music 那边是固定三档（高质量 AAC 256 / 无损 / 高解析度无损），
    /// Amber 的取流档位是音源给的 13 档，装进同一个位置。
    ///
    /// [推] 「启用无损音频」关掉时两颗禁用——Music 只拍到了开着的那一态，但它把这两颗
    /// 归在「无损音频」节里，跟着节开关走是唯一说得通的读法。
    private func qualityPicker(_ label: String, selection: Binding<StreamQuality>) -> some View {
        Picker(label, selection: selection) {
            ForEach(StreamQuality.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.qualities) { Text($0.displayName).tag($0) }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!model.draft.values.losslessEnabled)
    }
}

// MARK: - 音源

/// 音源页（Amber 比 Music 多出来的那一张）：开关每个音源、选默认源、看各源的账号状态。
struct ProviderSettingsPane: View {
    @Bindable var model: SettingsDraftModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: LibraryStore
    @Environment(QQLoginStore.self) private var qqLogin
    @Environment(NeteaseLoginStore.self) private var neteaseLogin
    @Environment(ProviderSettingsStore.self) private var providerSettings
    /// 两扇登录面板共用一条呈现状态。
    ///
    /// 从前是两条 `@State` + 链在同一个视图上的两个`.sheet(isPresented:)`，两处都关不掉：
    /// 同一个视图挂两个 `.sheet` 时 SwiftUI 只认得住一个，另一个连 isPresented 变回 false
    /// 都收不到；QQ 那扇还额外少传 `onDismiss`，它的关闭键去调了
    /// `AuxiliaryWindows.dismissQQLogin()`——那收的是挂在**主窗**上的 AppKit sheet，
    /// 跟设置窗里这一扇没有关系。面板关不掉，设置窗的红绿灯又是全隐的，
    /// 只剩「取消 / 好」而它们被 sheet 挡着，整个 App 就卡在那里。
    @State private var loginSheet: LoginSheet?

    /// 呈现哪一扇登录面板
    private enum LoginSheet: String, Identifiable {
        case qq, netease
        var id: String { rawValue }
    }

    var body: some View {
        SettingsPane(model: model) {
            // 组里只有第一行带标签，其余行跟着控件列排（Music 每一组都是这个排法）
            settingsRow("来源：") {
                providerToggle(ProviderKind.allCases[0])
            }
            settingsDescription(status(ProviderKind.allCases[0]))
            ForEach(ProviderKind.allCases.dropFirst()) { kind in
                settingsRow { providerToggle(kind) }
                settingsDescription(status(kind))
            }
            settingsDescription("关掉的来源不再出现在「搜索」和「主页」的来源切换里；"
                                + "资料库中已添加的该来源内容仍可播放。至少要保留一个来源。")

            settingsDivider()

            settingsRow("默认来源：") {
                Picker("默认来源", selection: $model.draft.defaultProvider) {
                    ForEach(model.draft.orderedEnabled) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            settingsDescription("启动 Amber 时选中的来源。")

            settingsDivider()

            settingsRow("QQ 音乐账号：") {
                Button(qqLogin.isLoggedIn ? "账号…" : "登录…") { loginSheet = .qq }
            }
            settingsDescription(qqLogin.isLoggedIn
                                ? "登录后才取得到 VIP 曲目与账号里的歌单。"
                                : "扫码登录后才取得到 VIP 曲目与账号里的歌单。")

            settingsRow("网易云音乐账号：") {
                Button(neteaseLogin.isLoggedIn ? "账号…" : "登录…") { loginSheet = .netease }
            }
            // 网易云免登录也能取到 320k（匿名 token 那条路），所以这里的说法与 QQ 不同：
            // 登录换来的是无损以上的档位、VIP 曲目和账号里的歌单，不是「能不能出声」。
            settingsDescription(neteaseLogin.isLoggedIn
                                ? "登录后才取得到 VIP 曲目、无损以上档位与账号里的歌单。"
                                // 网易云两条路：扫码，或把浏览器里的 Cookie 粘进来。
                                // 措辞里不点名具体哪条——面板打开就看得见，这行说的是「登录换来什么」。
                                : "未登录也可播放免费曲目（最高 320k）；登录后才取得到 VIP 曲目、无损以上档位与账号里的歌单。")
        }
        // 登录是当场生效的动作，不进草稿——「取消」撤不回一次登录/退出。
        // 一个 `.sheet(item:)` 管两扇：两扇面板的关闭键都显式传`onDismiss`，
        // 收的就是这条状态，不再借道 `AuxiliaryWindows`（那条是主窗那扇 sheet 的）。
        .sheet(item: $loginSheet) { which in
            switch which {
            case .qq:
                QQLoginView(onDismiss: { loginSheet = nil })
                    .environmentObject(appState)
                    .environmentObject(player)
                    .environmentObject(library)
                    .environment(qqLogin)
                    .environment(providerSettings)
                    .environmentObject(player.clock)
            case .netease:
                NeteaseLoginView { loginSheet = nil }
                    .environment(neteaseLogin)
            }
        }
    }

    private func providerToggle(_ kind: ProviderKind) -> some View {
        Toggle(kind.displayName, isOn: Binding(
            get: { model.draft.enabledProviders.contains(kind) },
            set: { model.draft.setEnabled($0, for: kind) }))
            // 最后一个开着的源不能关
            .disabled(model.draft.enabledProviders.contains(kind) && !model.draft.canDisable(kind))
    }

    private func status(_ kind: ProviderKind) -> String {
        switch kind {
        case .netease:
            if let nickname = neteaseLogin.credential?.nickname, !nickname.isEmpty {
                return "已登录 · \(nickname)。"
            }
            if let uid = neteaseLogin.credential?.uid { return "已登录 · uid \(uid)。" }
            return "未登录，可播放免费曲目（最高 320k）。"
        case .qq:
            if let uin = qqLogin.credential?.uin { return "已登录 · uin \(uin)。" }
            return "未登录，仅可播放免费曲目。"
        }
    }
}

// MARK: - 文件

/// 文件页。[AX] 只有一组：媒体位置面包屑 + 更改/重设 + 两条勾选 + 导入设置…
struct FilesSettingsPane: View {
    @Bindable var model: SettingsDraftModel
    @State private var showingImportSettings = false

    var body: some View {
        SettingsPane(model: model) {
            settingsRow("媒体位置：") {
                // [AX] AXList 高 24，四段各带文件夹图标；[PX] 段间是灰色的 ›
                MediaFolderPathView(url: model.draft.values.mediaFolder)
            }
            settingsRow {
                HStack(spacing: 6) {
                    // [AX] 更改… / 重设 各 62.5×26，相隔 6
                    Button { chooseFolder() } label: {
                        Text("更改…").frame(maxWidth: .infinity)
                    }
                    .frame(width: M.smallButtonWidth)
                    Button { model.draft.values.mediaFolderPath = nil } label: {
                        Text("重设").frame(maxWidth: .infinity)
                    }
                    .frame(width: M.smallButtonWidth)
                }
            }
            settingsRow {
                Toggle("保持“媒体”文件夹有序", isOn: $model.draft.values.keepMediaFolderOrganized)
            }
            settingsDescription("将文件放入专辑和艺人文件夹中，并基于光盘编号、音轨编号和歌曲标题来命名文件。")
            settingsRow {
                Toggle("添加到资料库时将文件拷贝到“媒体”文件夹", isOn: $model.draft.values.copyFilesToMediaFolder)
            }
            settingsRow {
                Button("导入设置…") { showingImportSettings = true }
            }
        }
        .sheet(isPresented: $showingImportSettings) {
            // 子对话框自己也有一对取消/好，改的是草稿里的三个字段（见 ImportSettingsView）
            ImportSettingsView(values: $model.draft.values)
        }
    }

    /// 「更改…」开的是标准选取文件夹面板。选完只落到草稿里，一样要按「好」才生效。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.draft.values.mediaFolder
        panel.prompt = "选取"
        if panel.runModal() == .OK, let url = panel.url {
            model.draft.values.mediaFolderPath = url.path
        }
    }
}

/// 「媒体位置：」那条面包屑。[PX] 每段是「文件夹图标 + 名字」，段间一个灰色的 ›；
/// 图标是**真实的文件夹图标**（个人文件夹、音乐文件夹各有各的图形），所以这里也走
/// `NSWorkspace.icon(forFile:)`，不用一律`folder` 字形糊过去。
private struct MediaFolderPathView: View {
    let url: URL

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("›")
                        .font(.system(size: M.labelSize))
                        .foregroundStyle(.tertiary)
                }
                Image(nsImage: icon(for: segment.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(segment.name)
                    .font(.system(size: M.labelSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 24)
        .lineLimit(1)
    }

    /// 目录还没在磁盘上建出来时（Amber 的「媒体」文件夹默认位置就还不存在），
    /// `icon(forFile:)` 会回一张通用**文稿**图标——面包屑上冒出两张白纸很出戏，
    /// 这种情况直接用通用文件夹图标。
    private func icon(for path: String) -> NSImage {
        FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .folder)
    }

    /// 从个人文件夹往下切（Music 面包屑的第一段就是用户名）。
    private var segments: [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let full = url.standardizedFileURL
        guard full.path.hasPrefix(home.path) else {
            // 选到了个人文件夹以外，整条路径从根切
            return pathSegments(of: full, from: URL(fileURLWithPath: "/"))
        }
        let head = (name: FileManager.default.displayName(atPath: home.path), path: home.path)
        return [head] + pathSegments(of: full, from: home)
    }

    private func pathSegments(of url: URL, from base: URL) -> [(name: String, path: String)] {
        var current = base
        var out: [(name: String, path: String)] = []
        for component in url.pathComponents.dropFirst(base.pathComponents.count) {
            current.appendPathComponent(component)
            // 「音乐」这类系统文件夹要显示本地化名字（Music 的面包屑上就是「音乐」不是 Music）
            out.append((FileManager.default.displayName(atPath: current.path), current.path))
        }
        return out
    }
}

/// 「导入设置…」子对话框。[AX] 2026-09-05 补测：独立 544×353 的 `AXDialog`，
/// 自己带一对 86×23 的取消/好，「详细信息」下面那段规格文字**有一个框**
/// （整个设置窗唯一一处有框的地方）。
private struct ImportSettingsView: View {
    @Binding var values: SettingsValues
    @Environment(\.dismiss) private var dismiss
    /// 这扇窗自己也是「按好才生效」，所以再套一层草稿
    @State private var encoder: ImportEncoder = .aac
    @State private var preset: ImportPreset = .iTunesPlus
    @State private var errorCorrection = false

    private typealias IM = MusicMetrics.Settings.Import

    var body: some View {
        VStack(spacing: 0) {
            Text("导入设置")
                .font(.system(size: M.labelSize, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, IM.titleTop)

            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: M.labelGap,
                 verticalSpacing: M.rowSpacing) {
                importRow("导入时使用：") {
                    Picker("导入时使用", selection: $encoder) {
                        ForEach(ImportEncoder.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    // [AX] Music 这两颗都是 253 宽的等宽 popup，但给 SwiftUI 的 Picker
                    // 写死 frame 只会把自然宽的那颗在框里居中、离开控件列（见主设置窗那条注释），
                    // 两害相权取对齐：宽随内容。
                    .fixedSize()
                }
                importRow("设置：") {
                    Picker("导入设置预置", selection: $preset) {
                        ForEach(ImportPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                importRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("详细信息")
                            .font(.system(size: M.descriptionSize))
                            .foregroundStyle(.secondary)
                        Text(encoder.detail(preset: preset))
                            .font(.system(size: M.descriptionSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(7)
                            .frame(width: IM.detailBoxWidth, height: IM.detailBoxHeight,
                                   alignment: .topLeading)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor)))
                    }
                }
                importRow {
                    Toggle("读取音乐光盘时使用纠错功能", isOn: $errorCorrection)
                }
                importRow {
                    Text("如果音乐光盘的音频质量出现问题，请使用此选项。这可能会降低导入速度。")
                        .font(.system(size: M.descriptionSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, M.descriptionIndent)
                }
                importRow {
                    // Music 这句是「注：这些设置不适用于从Apple Music或iTunes Store下载的歌曲。」
                    Text("注：这些设置不适用于在线取流播放的歌曲。")
                        .font(.system(size: M.descriptionSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, M.rowSpacing)
                }
            }
            .padding(.horizontal, IM.contentInset)
            .padding(.top, IM.contentTop)

            Spacer(minLength: 0)

            HStack(spacing: M.buttonSpacing) {
                Spacer(minLength: 0)
                // [AX] 这扇窗的取消/好是 86×23，比主设置窗那对宽
                Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: IM.buttonWidth)
                Button {
                    values.importEncoder = encoder
                    values.importPreset = preset
                    values.importUseErrorCorrection = errorCorrection
                    dismiss()
                } label: {
                    Text("好").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: IM.buttonWidth)
            }
            .padding(.horizontal, IM.contentInset)
            .padding(.bottom, IM.buttonBottom)
        }
        .frame(width: IM.windowWidth, height: IM.windowHeight)
        .onAppear {
            encoder = values.importEncoder
            preset = values.importPreset
            errorCorrection = values.importUseErrorCorrection
        }
    }

    @ViewBuilder
    private func importRow<Control: View>(_ label: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: M.labelSize))
                .frame(maxWidth: .infinity, alignment: .trailing)
            control()
                .frame(width: IM.controlColumnWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func importRow<Control: View>(@ViewBuilder control: () -> Control) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            control()
                .frame(width: IM.controlColumnWidth, alignment: .leading)
        }
    }
}

// MARK: - 高级

/// 高级页。[AX] 三组：资料库三条 / 三颗还原键 / 窗口两条。
/// 三颗还原键**按下即生效**，不等「好」——Music 那边也是当场就做。
struct AdvancedSettingsPane: View {
    @Bindable var model: SettingsDraftModel
    @EnvironmentObject private var appState: AppState
    /// 遥控器（iOS「遥控」App）的配对与广播。单例：这一行要显示的配对数在设置窗里
    /// 就得能看见，而设置窗这棵树上只有 `AppState`——不为一行界面逼别人的文件先长属性。
    private let remote = RemoteControlServer.shared
    @State private var cacheCleared = false
    @State private var warningsRestored = false
    @State private var showingPairing = false

    var body: some View {
        SettingsPane(model: model) {
            settingsRow("资料库：") {
                Toggle("添加与删除播放列表歌曲", isOn: $model.draft.values.syncPlaylistSongsWithLibrary)
            }
            settingsDescription("添加到你创建的播放列表的歌曲也将添加到资料库。从资料库删除的歌曲也将从这些播放列表移除。")
            settingsRow {
                Toggle("添加与删除喜爱歌曲", isOn: $model.draft.values.syncFavoriteSongsWithLibrary)
            }
            settingsDescription("你喜爱的歌曲也将添加到资料库。从资料库删除的歌曲也将从喜爱的项目移除。")
            settingsRow {
                Toggle("自动更新已导入歌曲的插图", isOn: $model.draft.values.autoUpdateImportedArtwork)
            }
            settingsDescription("这可让“Amber”更新导入至“资料库”中歌曲的插图和元数据。")

            settingsDivider()

            // [AX] Music 那行标签是「“音乐”未与任何遥控器配对：」，一台都没配时按钮禁用；
            // 配上之后文案变成「已与 N 个遥控器配对：」、按钮亮起。按下即生效，不进草稿
            //（与它下面那两颗还原键同一口径）。
            settingsButtonRow(remotePairingLabel, button: "忽略所有遥控器",
                              disabled: remote.pairedDevices.isEmpty) {
                remote.forgetAll()
            }
            // Music 没有这一行——它的配对是遥控器主动找上门时弹对话框。Amber 反过来，
            // 由这里去浏览 `_touch-remote._tcp` 并把 PIN 送过去（见 RemoteControlServer.pair）。
            settingsButtonRow("", button: "配对遥控器…") { showingPairing = true }
            settingsButtonRow("还原所有对话框警告：",
                              button: warningsRestored ? "已还原" : "还原警告") {
                appState.restoreSuppressedWarnings()
                warningsRestored = true
            }
            // Music 是「还原音乐商店缓存」，Amber 没有商店，清的是封面与歌词那两份缓存
            settingsButtonRow("还原音源缓存：", button: cacheCleared ? "已清空" : "还原缓存") {
                ImageCache.shared.clear()
                appState.lyricsStore.clear()
                cacheCleared = true
            }

            settingsDivider()

            settingsRow("窗口：") {
                Toggle("在其他所有窗口前端显示迷你播放程序", isOn: $model.draft.values.miniPlayerOnTop)
            }
            settingsRow {
                Toggle("在其他所有窗口前端播放视频", isOn: $model.draft.values.videoOnTop)
            }
        }
        .sheet(isPresented: $showingPairing) {
            RemotePairingSheet(remote: remote)
        }
    }

    private var remotePairingLabel: String {
        let count = remote.pairedDevices.count
        return count == 0 ? "“Amber”未与任何遥控器配对：" : "“Amber”已与 \(count) 个遥控器配对："
    }
}

// MARK: - 配对遥控器

/// 「配对遥控器…」的小表单。设置窗里的这一张是叶子，写成 SwiftUI 不违反骨架约束。
///
/// 流程：浏览 `_touch-remote._tcp` → 选一台 → 输它屏幕上显示的 4 位数字 →
/// 我们把 `MD5(Pair ‖ PIN)` 送到手机上那个 HTTP 服务，对得上就回一份配对 GUID。
private struct RemotePairingSheet: View {
    let remote: RemoteControlServer
    @Environment(\.dismiss) private var dismiss

    @State private var selection: DiscoveredRemote.ID?
    @State private var pin = ""
    @State private var isPairing = false

    private var selected: DiscoveredRemote? {
        remote.discovered.first { $0.id == selection }
    }

    private var canPair: Bool {
        selected != nil && RemotePairing.isValidPIN(pin) && !isPairing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配对遥控器")
                .font(.system(size: 13, weight: .bold))
            Text("在 iPhone 或 iPad 上打开“遥控”App，选择“Amber”，然后把它显示的 4 位密码输在这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(remote.discovered) { device in
                    HStack(spacing: 6) {
                        Image(systemName: "iphone")
                        Text(device.name)
                        Spacer()
                        Text(device.deviceType)
                            .foregroundStyle(.secondary)
                    }
                    .tag(device.id)
                }
            }
            .frame(height: 120)
            .overlay {
                if remote.discovered.isEmpty {
                    // 空列表要说清在等什么，否则看起来像坏了
                    Text("正在查找同一网络里的“遥控”App…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("密码：")
                TextField("0000", text: $pin)
                    .frame(width: 70)
                    .onChange(of: pin) { _, value in
                        // 只留数字、最多四位：遥控 App 上就是四格数字
                        let digits = value.filter(\.isNumber)
                        if digits != value || digits.count > 4 {
                            pin = String(digits.prefix(4))
                        }
                    }
                if isPairing { ProgressView().controlSize(.small) }
            }

            if let error = remote.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("配对") { startPairing() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPair)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            remote.lastError = nil
            // 手机配对成功后立刻回头连我们广播的服务，所以先把摊子支起来再浏览。
            remote.start()
            remote.startBrowsing()
        }
        .onDisappear { remote.stopBrowsing() }
    }

    private func startPairing() {
        guard let device = selected else { return }
        isPairing = true
        remote.lastError = nil
        Task {
            do {
                try await remote.pair(device, pin: pin)
                isPairing = false
                dismiss()
            } catch {
                isPairing = false
                remote.lastError = (error as? any LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
