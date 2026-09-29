# 构建、签名与打包

## 签名身份

Team ID 不入库，两种给法任选其一：

- 复制 `Support/Signing.local.xcconfig.example` 为 `Support/Signing.local.xcconfig`，填 `AMBER_DEVELOPMENT_TEAM`（已在 `.gitignore` 里，Xcode ⌘R 与脚本读同一份）
- 或设环境变量 `AMBER_TEAM_ID`（脚本优先读它）

Team ID 在「钥匙串访问」的证书详情，或 Xcode → Settings → Accounts → Manage Certificates 里能看到。

## 本机构建与运行

| 命令 | 作用 |
| --- | --- |
| `./Tools/run.sh` | 构建 → 长期签名安装到 `/Applications/Amber.app` → 退掉旧进程 → 启动并打印构建戳 |
| `./Tools/run.sh Release` | 同上，优化版（`-O` + wholemodule），用来判断卡顿是不是 `-Onone` 造成的 |
| `./Tools/build-install-signed.sh` | 只构建安装、不启动（`run.sh` 内部也调它） |

**不要手动 `open` DerivedData 里的 `Amber.app`。** 同 bundle id 存在多份时，双击 / Spotlight / `open -b` 命中哪份不确定。
`run.sh` 装完会把构建产物从 LaunchServices 注销并删除，磁盘上只留 `/Applications` 一份。

核对跑的是哪一版：

```bash
/usr/libexec/PlistBuddy -c 'Print :AmberBuildCommit' /Applications/Amber.app/Contents/Info.plist
```

单元测试：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Amber.xcodeproj -scheme Amber -derivedDataPath build/DerivedData test
```

## 打包 dmg

```bash
./Tools/make-dmg.sh
```

产物在 `build/dist/Amber-<版本>-<commit>.dmg`（Debug 构建带 `-debug` 后缀），内含 `Amber.app` 与 `Applications` 快捷方式。
它构建到独立的 `build/DerivedDataDist`，不碰 `/Applications/Amber.app`，也不启动任何东西。

第二个参数选签名档位，默认 `signed`；没有可用证书时可传 `adhoc`（文件名多 `-adhoc` 后缀）：

```bash
./Tools/make-dmg.sh Release adhoc
```

两档都拒绝退档：`signed` 拒收 ad-hoc 或换了 Team 的产物，`adhoc` 拒收带真证书的产物。

## 为什么不用 ad-hoc 签名

登录凭证存在钥匙串里，条目绑定签名的 Designated Requirement：

- **Apple Development 签名**：DR 绑定证书，跨版本不变 → 升级后登录态保留
- **ad-hoc 签名**：DR 退化成每次编译都变的 CDHash → 每升级一次就要重新登录，本机开发时钥匙串还会反复请求授权

两者对 Gatekeeper 都要走一遍首次打开流程，ad-hoc 并不更省事。所以安装构建里不要传 `CODE_SIGNING_ALLOWED=NO`，也不要 `codesign -`；
`adhoc` 档只是给「这台机器没证书」留的后门，发出去之后再换回 `signed`，对方那次升级同样要重新登录。

> **证书有效期**：当前签名证书 **2027-02-25** 到期，开发签名用的是 `--timestamp=none`，过期后已发出的旧 dmg 会验签失败。到期前重新生成证书并重发一版即可。

## 其它工具

- `ui-spec.swift`：把任意 `.app` 的技术栈、资源与运行时 AX 树导出为 JSON
- `pixel-diff.swift`：比较同尺寸截图并生成差异热图

完整用法见 [design-ref/ui-spec/README.md](../design-ref/ui-spec/README.md)。
