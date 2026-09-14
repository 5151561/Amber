import SwiftUI

/// 音质气泡（Music.app 的 audioBadge 点开的那一枚）：一行档位名、一行真实规格，
/// 底下一颗直达设置「播放」页的按钮。
///
/// 迷你播放器的波形键与整窗播放器进度条下的「无损」徽标共用这一枚——两处点开
/// 必须说同一件事，各写一份迟早会分叉。
///
/// 数字是从播放中的 asset 读出来的实际值（见 `StreamFormat`），不是设置里选的档位：
/// 阶梯会降级，两者经常对不上，气泡按实际拿到的那一档报。
struct AudioQualityPopover: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if let format = player.streamFormat {
                Text(format.tierName)
                    .font(.system(size: 15, weight: .semibold))
                Text(format.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(player.isLoading ? "正在载入…" : "音质未知")
                    .font(.system(size: 15, weight: .semibold))
                Text("规格要等这一路流就绪才读得到")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            // 设置窗是 AppKit 的，直接叫 `AuxiliaryWindows` 开——页码当参数带过去，
            // 不像从前的 `SettingsLink` 只能开窗、选页得另想办法。
            Button("音频质量设置") {
                AuxiliaryWindows.shared.showSettings(tab: .playback)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 180)
    }
}
