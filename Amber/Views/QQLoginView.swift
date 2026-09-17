import SwiftUI

/// QQ 音乐登录面板（最小可用版，视觉细节后续再打磨）。
/// 两种方式：QQ 扫码登录，或粘贴 y.qq.com 的 cookie。
///
/// 这扇面板现在是 `AuxiliaryWindows.presentQQLogin()` 用 `beginSheet` 挂在主窗上的
/// 一个 `NSHostingController`。**`@Environment(\.dismiss)` 在这种 sheet 里是空操作**
/// ——那扇窗不是 SwiftUI 呈现的，环境里没有对应的 action，所以关自己走 `onDismiss`。
struct QQLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(QQLoginStore.self) private var qqLogin

    /// 关掉这扇面板。给了就用给的（AppKit 宿主传的是 `endSheet`）；
    /// 没给就走 `AuxiliaryWindows`——旧壳那条 `.sheet(isPresented:)` 也认它，
    /// 因为它顺手把 `appState.showingQQLogin` 置回了 false。
    var onDismiss: (() -> Void)?

    @State private var cookieText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("QQ 音乐登录")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    qqLogin.cancelQRLogin()
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if qqLogin.isLoggedIn {
                Label("已登录 · uin \(qqLogin.credential?.uin ?? "")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("退出登录", role: .destructive) {
                    qqLogin.logout()
                }
            } else {
                qrSection
                Divider()
                cookieSection
            }

            // 音质档位归「设置 › 播放」管，这里不再放第二份：设置窗是「按『好』才生效」的
            // 草稿式编辑，这扇 sheet 却是即时写，两处同时改同一条偏好会互相盖掉。
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear {
            qqLogin.cancelQRLogin()
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            AuxiliaryWindows.shared.dismissQQLogin()
        }
    }

    // MARK: - 扫码登录

    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch qqLogin.qrState {
            case .idle:
                Button {
                    qqLogin.startQRLogin()
                } label: {
                    Label("QQ 扫码登录", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.qqGreen)

            case .loadingQR, .waitingScan, .scanned, .authorizing:
                VStack(spacing: 10) {
                    if let data = qqLogin.qrImageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 168, height: 168)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        ProgressView()
                            .frame(width: 168, height: 168)
                    }
                    Text(qqLogin.qrState.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        qqLogin.cancelQRLogin()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

            case .refused, .expired, .failed:
                VStack(spacing: 10) {
                    Text(qqLogin.qrState.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新获取二维码") {
                        qqLogin.startQRLogin()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 粘贴 cookie

    private var cookieSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或粘贴浏览器 Cookie（需含 qqmusic_key 和 uin）")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $cookieText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                do {
                    try qqLogin.login(cookieString: cookieText)
                    errorMessage = nil
                    cookieText = ""
                    appState.showToast("QQ音乐登录成功")
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Text("登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.qqGreen)
            .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
