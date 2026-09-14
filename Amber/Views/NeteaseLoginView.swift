import AppKit
import SwiftUI

/// 网易云音乐登录面板。
///
/// 两条路上下并列，版式照 `QQLoginView` 那扇（「扫码」+「粘贴 cookie」）：
/// **扫码登录**在上，**浏览器 Cookie 导入**在下，中间一条分隔线。
/// 不用 Picker 切——两段加起来还没有原来手机号那一段高，铺开比多一次点击好。
///
/// 手机号登录（短信 / 密码）那一段已经删了：两条通道上都被风控拦住，
/// 详见 `NeteaseLoginStore` 与 `NeteaseWeapi.swift` 的说明。
///
/// 与 `QQLoginView` 的一处差异仍然成立：**没有「已拒绝登录」态**。
/// 网易云在手机上点取消不会回一个专门的码，就一直停在 802（已扫码待确认），
/// 所以 `QRLoginState.refused` 在这条路上不会出现。
struct NeteaseLoginView: View {
    @EnvironmentObject private var neteaseLogin: NeteaseLoginStore

    /// 关掉这扇面板。与 `QQLoginView` 同：AppKit 宿主传的是 `endSheet`。
    var onDismiss: (() -> Void)?

    /// 粘进来的 Cookie 只活在这个 `@State` 里，随面板一起消失；
    /// 校验通过后只有裁剩的 `MUSIC_U` / `__csrf` 进 Keychain，原串一个字都不留。
    @State private var cookieText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("网易云音乐登录")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if neteaseLogin.isLoggedIn {
                Label(accountLine, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("退出登录", role: .destructive) {
                    neteaseLogin.logout()
                }
            } else {
                qrSection
                Divider()
                cookieSection
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear {
            neteaseLogin.cancelQRLogin()
        }
        // 登录成功后立刻把粘进来的原串抹掉：它是一份完整的会话凭证，
        // 没有理由在面板还开着的时候继续躺在内存里（面板关掉时随 @State 一起消失）。
        .onChange(of: neteaseLogin.isLoggedIn) { _, loggedIn in
            if loggedIn { cookieText = "" }
        }
    }

    private func close() {
        neteaseLogin.cancelQRLogin()
        onDismiss?()
    }

    /// 昵称拿得到就写昵称，否则退到 uid——两个都没有时只说「已登录」，
    /// 不编一个「未知用户」出来。
    private var accountLine: String {
        if let nickname = neteaseLogin.credential?.nickname, !nickname.isEmpty {
            return "已登录 · \(nickname)"
        }
        if let uid = neteaseLogin.credential?.uid { return "已登录 · uid \(uid)" }
        return "已登录"
    }

    // MARK: - 扫码登录

    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch neteaseLogin.qrState {
            case .idle:
                Button {
                    neteaseLogin.startQRLogin()
                } label: {
                    Label("网易云扫码登录", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.neteaseRed)

            case .loadingQR, .waitingScan, .scanned, .authorizing:
                VStack(spacing: 10) {
                    if let data = neteaseLogin.qrImageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 168, height: 168)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        ProgressView()
                            .frame(width: 168, height: 168)
                    }
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        neteaseLogin.cancelQRLogin()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

            case .refused, .expired, .failed:
                VStack(spacing: 10) {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 风控给了验证页时多这一颗：那一页过完才谈得上继续，
                    // 光有一句「安全风险」等于把用户唯一的出路扔了。
                    if let challenge = neteaseLogin.qrChallenge {
                        Button("去完成验证") { NSWorkspace.shared.open(challenge.url) }
                    }
                    Button("重新获取二维码") {
                        neteaseLogin.startQRLogin()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// `QRLoginState.statusText` 是照 QQ 写的（「请使用 QQ 扫描二维码」），
    /// 这一条在网易云这边要换掉；其余几条两家措辞一致，原样用。
    private var statusText: String {
        neteaseLogin.qrState == .waitingScan
            ? "请使用网易云音乐 App 扫描二维码"
            : neteaseLogin.qrState.statusText
    }

    // MARK: - 浏览器 Cookie 导入

    private var cookieSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或粘贴浏览器 Cookie（在浏览器里登录 music.163.com 后导出，需含 MUSIC_U）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("认三种格式：开发者工具里复制的 name=value; 串、Cookie Editor 导出的 JSON、cookies.txt")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $cookieText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
            if case .failed(let message) = neteaseLogin.cookieState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if neteaseLogin.cookieState.isBusy {
                Text(neteaseLogin.cookieState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                neteaseLogin.loginWithCookie(cookieText)
            } label: {
                Text("登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.neteaseRed)
            .disabled(!canSubmitCookie)
        }
    }

    private var canSubmitCookie: Bool {
        !neteaseLogin.cookieState.isBusy
            && !cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
