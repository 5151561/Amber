import SwiftUI

/// 歌词面板右下角的翻译浮动键。侧栏与整窗播放器共用这一颗。
///
/// [实测] Music 歌词面板控制器上的四件套：
///
/// ```
/// translationButton                 NSButton（字段）
/// drawsTranslationButton            Bool；直接喂 translationButton.setHidden:
/// translationButtonClicked →
/// toggleTranslation / toggleTransliteration   菜单两项的 action
/// ```
///
/// 点击那条的 sels 是
/// `sendTranslationButtonClickEvent` + `bounds` + `popUpMenuPositioningItem:atLocation:inView:`
/// ——所以它**不是一个 on/off 开关，而是弹一个菜单**，落点由按钮自身 bounds 的
/// 宽高算出。整窗那颗是同一颗的 SwiftUI 版（建 `SwiftUI.Button`、
/// 挂 `mcui.nowPlayingAutomationIdentifier("lyricsTranslationButton")`，
/// 走 `PresentingNSMenuContext.present(menu:)`），
/// 菜单与动作完全相同，所以这里也只做一份。
///
/// 菜单两项对应 `toggleTranslation` / `toggleTransliteration`，文案取自 Music 自己的
/// `UserInterface.strings`：`LYRICS_SHOW_TRANSLATION` / `LYRICS_HIDE_TRANSLATION`
/// = 显示翻译 / 隐藏翻译，`LYRICS_SHOW_PRONUNCIATION` / `LYRICS_HIDE_PRONUNCIATION`
/// = 显示发音 / 隐藏发音（Music 界面上说「发音」，不说「音译」）。
///
/// **两项永远都在，没有内容的那项置灰**——这是照 Music 实机来的。
/// 整颗键的显隐才是 `drawsTranslationButton` 管的事：两样都没有就整颗不画。
struct LyricsTranslationButton: View {

    /// 这颗键摆在哪。两边是**两种控件**，不是同一个东西挪位置。
    enum Placement {
        /// 侧栏：自带玻璃的独立浮片，浮在歌词之上。
        /// [AX] `lyrics-panel.json` 的`AXButton 翻译 [1421, 915, 34, 26]`。
        case floating
        /// 整窗：并进右下那颗玻璃胶囊，占一个 36 的槽。
        ///
        /// [TYPE] 整窗这颗登记的是 `NowPlayingLookupID("lyricsFooterButton")`
        /// 而底栏是
        /// `NowPlayingView.FooterButtons` → `GroupResolvingFooterLayoutView`
        /// （持 `NowPlayingFooterLayout.Layout`）→ `FooterLayoutGlassGroup`
        /// （`ids: [NowPlayingButtonID]`）——一颗玻璃胶囊里装一串按钮 id，
        /// 每颗 `FooterButtonView` 还从环境读`_hasGlassGroupSiblings`。
        /// 也就是说整窗这颗**是底栏按钮组里的一员**，不是浮在歌词上的独立浮片；
        /// `Lyrics.footerButton` 那个字段名说的就是这件事。
        case footerSlot
    }

    /// 这首歌有没有译文 / 发音。两样都没有就整颗不画
    /// （[实测] `drawsTranslationButton → setHidden:`）；只缺一样就把那一项置灰。
    let hasTranslation: Bool
    let hasTransliteration: Bool
    var placement: Placement = .floating

    @AppStorage(LyricsTranslationOptions.showTranslationKey)
    private var showTranslation = LyricsTranslationOptions.showTranslationDefault
    @AppStorage(LyricsTranslationOptions.showTransliterationKey)
    private var showTransliteration = LyricsTranslationOptions.showTransliterationDefault

    private typealias M = MusicMetrics.Lyrics.TranslationButton
    private typealias NP = MusicMetrics.NowPlaying

    private var slotSize: CGSize {
        switch placement {
        case .floating: return M.size
        case .footerSlot: return CGSize(width: NP.footerButtonSlot, height: NP.capsuleHeight)
        }
    }

    var body: some View {
        if hasTranslation || hasTransliteration {
            Menu {
                // 图标：翻译是 `character.bubble`（气泡里一个 A），
                // 发音那颗 [推] 取 `captions.bubble`——按 Music 实机的图形选的，
                // 没有更硬的依据。
                Button {
                    showTranslation.toggle()
                } label: {
                    Label(showTranslation ? "隐藏翻译" : "显示翻译",
                          systemImage: "character.bubble")
                }
                .disabled(!hasTranslation)

                Button {
                    showTransliteration.toggle()
                } label: {
                    Label(showTransliteration ? "隐藏发音" : "显示发音",
                          systemImage: "captions.bubble")
                }
                .disabled(!hasTransliteration)
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: M.iconSize, weight: .medium))
                    .foregroundStyle(placement == .floating
                                     ? AnyShapeStyle(.white)
                                     : AnyShapeStyle(.white.opacity(NP.footerIconOpacity)))
                    .frame(width: slotSize.width, height: slotSize.height)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: slotSize.width, height: slotSize.height)
            // 底栏那档的玻璃由胶囊本身提供，这里不能再叠一层。
            .modifier(FloatingGlass(enabled: placement == .floating,
                                    cornerRadius: M.cornerRadius))
            .accessibilityLabel("翻译")
            .help("翻译")
        }
    }

    private struct FloatingGlass: ViewModifier {
        let enabled: Bool
        let cornerRadius: CGFloat

        func body(content: Content) -> some View {
            if enabled {
                content.amberGlass(in: RoundedRectangle(cornerRadius: cornerRadius,
                                                     style: .continuous),
                                interactive: true)
            } else {
                content
            }
        }
    }
}

/// 翻译开关的落盘位置与默认值。
///
/// Music 把默认值放在服务端 bag 里（读
/// `lyricsFeatureDefaults` → `translationsEnabledByDefault`），另有
/// `lyricsTranslationLocale` 记选中的语言。Amber 没有 bag，就落两个本地开关。
///
/// 两条副行**默认都关**：歌词面板先给干净的原文，要看译文/发音自己去右下角开。
enum LyricsTranslationOptions {
    static let showTranslationKey = "lyricsShowTranslation"
    static let showTranslationDefault = false
    static let showTransliterationKey = "lyricsShowTransliteration"
    static let showTransliterationDefault = false
}

extension Array where Element == LyricLine {

    /// 这份歌词里有没有译文。
    var hasTranslation: Bool {
        contains { ($0.translation?.isEmpty == false) }
    }

    /// 这份歌词里有没有发音（音译）。
    ///
    /// 两条都要看：发音落到音节上（「贴在字底下」那套排版）之后，整行那条
    /// `transliteration` 就撤了——只认它的话，菜单里「显示发音」会在**发音明明有**
    /// 的时候被置灰。
    var hasTransliteration: Bool {
        contains { line in
            line.transliteration?.isEmpty == false
                || line.syllables.contains { $0.transliteration?.isEmpty == false }
        }
    }
}
