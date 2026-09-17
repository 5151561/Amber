# Amber — Apple Music 风格 macOS 音乐播放器

复刻 Apple Music UI 的 macOS 原生应用，聚合 **QQ音乐** 与 **网易云音乐** 两个 provider。

- 纯 Swift 原生栈：SwiftUI + AppKit + AVFoundation + URLSession，**零第三方依赖**
- macOS 26+（Tahoe 及以后）；本机安装使用项目配置的 Apple Development 长期签名
- 匿名访问（无需登录）：免费歌曲可播放（128k），VIP/付费曲目播放时自动跳过并提示

## 功能

- **首页**：推荐歌单网格、排行榜横向卡片、新碟上架（两平台独立首页）
- **搜索**：单曲 / 专辑 / 歌手 / 歌单 四类，同时搜索两个平台并按平台分组展示
- **详情页**：歌单、专辑、歌手（热门单曲 + 专辑）
- **播放**：播放队列、随机 / 循环（全部/单曲）、自动连播、双击曲目播放
- **全屏播放器**：Apple Music 风渐变背景、大封面、可拖进度条、音量、**同步滚动歌词**（含翻译副行，点击歌词跳转）
- **系统集成**：控制中心 / 媒体键 / Touch Bar（MPNowPlayingInfoCenter + MPRemoteCommandCenter）
- **资料库**：喜欢的音乐、最近播放（JSON 持久化到 `~/Library/Application Support/Amber/`）
- 底部迷你播放条，两个平台用红/绿徽标区分

## QQ 音乐登录与音质

菜单栏 **Amber → 登录 QQ 音乐…**（⌘L），两种方式：

- **QQ 扫码登录**（推荐）：面板内生成二维码，手机 QQ 扫码确认后自动换取 musicid/musickey。
  流程对齐 L-1124/QQMusicApi：`ssl.ptlogin2.qq.com/ptqrshow` 取码（qrsig）→`ptqrlogin` 轮询
  （66 未扫 / 67 已扫 / 0 确认 / 65 过期）→ `check_sig` 取 p_skey →`oauth2/authorize` 拿 code →
  `QQConnectLogin.LoginServer.QQLogin` 换凭证，全部请求在应用内完成，无中间服务
- **粘贴 cookie**：浏览器登录 y.qq.com 后复制 Cookie（需含 `qqmusic_key`/`qm_keyst` 与`uin`）

登录能力：

- **登录后**：VIP/付费曲目可播放，最高杜比全景声 / 臻品母带（需超级会员）
- **音质**：13 档 —— 杜比全景声（E-AC-3 JOC）/ 臻品全景声 5.1（6 声道 FLAC）/ 臻品母带（24bit·192k FLAC）/ 臻品音质 / 无损 FLAC / Vorbis 640k / 320k / AAC 192k / Vorbis 192k / 128k / AAC 96k / Vorbis 96k / AAC 48k。选的档位这首歌没有时按阶梯自动往下降
- 登录态凭证存 **Keychain**，音质偏好存 UserDefaults；凭证过期（接口 code 1000/104400/104401）自动清除并提示
- 登录请求格式对齐 [qmdec](https://github.com/Sophomoresty/qmdec)：`comm{uin, g_tk:5381}` + Cookie 头 +`QQMusic/21` UA，取流用桌面客户端参数（ct=1 / cv=13030508）
- **取流是明文的**：所有档位（含杜比全景声、臻品母带）的 vkey 都不返回 ekey，取回的头字节就是 `fLaC`/`ftyp`/`OggS`/`ID3`，CDN 也支持 byte range，交给 AVPlayer 直接播即可——QMC 只加密客户端下载到本地的`.mflac`。网易云登录未接入（匿名 128k）

## 构建与运行

需要完整版 Xcode 16+（支持 file-system-synchronized 工程格式）。

首次构建先配一下签名身份——Team ID 不入库，两种给法任选其一：

```bash
cp Support/Signing.local.xcconfig.example Support/Signing.local.xcconfig
# 编辑它，把 AMBER_DEVELOPMENT_TEAM 填成自己的 Team ID
```

或者设环境变量（`Tools/` 下的脚本优先读它）：

```bash
export AMBER_TEAM_ID=XXXXXXXXXX
```

Team ID 在「钥匙串访问」的证书详情里，或 Xcode → Settings → Accounts → Manage Certificates 都能看到。
`Support/Signing.local.xcconfig` 已在 `.gitignore` 里，Xcode 里 ⌘R 和命令行脚本读的是同一份。

日常改完代码想看效果，只用这一条：

```bash
./Tools/run.sh
```

它做四件事：构建 → 长期签名安装到 `/Applications/Amber.app` → 退掉旧进程 → 启动并打印构建戳。

**不要再手动 `open` 某个 DerivedData 里的`Amber.app`。** 多份同`bundle id` 的 Amber 同时存在时，
双击 / Spotlight / `open -b` 命中哪一份是不确定的，很容易跑到几小时前的旧版本。
`run.sh` 装完会把 DerivedData 里的产物从 LaunchServices 注销并删除，磁盘上只留`/Applications` 一份；
派生数据也统一收在 `build/DerivedData`，不再每次换目录名。

构建戳写进 bundle，随时可以核对跑的是哪一版：

```bash
/usr/libexec/PlistBuddy -c 'Print :AmberBuildCommit' /Applications/Amber.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :AmberBuildDate'   /Applications/Amber.app/Contents/Info.plist
```

只装不启动时用签名安装脚本（`run.sh` 内部也是调它）：

```bash
./Tools/build-install-signed.sh
```

脚本用 `Apple Development` 身份签名，并在复制前检查 Designated Requirement。不要在安装构建中传入
`CODE_SIGNING_ALLOWED=NO`，也不要对产物执行 `codesign -`；ad-hoc 签名会让
Designated Requirement 退化为每次编译都会变化的 CDHash，导致 Keychain 反复请求授权。

或在 Xcode 中打开 `Amber.xcodeproj` 直接 ⌘R。单元测试：

```bash
xcodebuild -project Amber.xcodeproj -scheme Amber test
```

## 打包分发

给别人用的 dmg：

```bash
./Tools/make-dmg.sh
```

产物落在 `build/dist/Amber-<版本>-<commit>.dmg`（Debug 构建会多个`-debug` 后缀，免得同 commit 互相覆盖），
里面是 `Amber.app` 加一个`Applications` 快捷方式，拖进去就装。

第二个参数选签名档位，默认 `signed`（Apple Development 长期签名）；要不带证书的包就传 `adhoc`，
文件名会多一个 `-adhoc` 后缀：

```bash
./Tools/make-dmg.sh Release adhoc
```

两档各有各的底线：要的是哪种签名就必须拿到哪种——`signed` 档拒收 ad-hoc 或换了 Team 的产物，
`adhoc` 档反过来拒收带真证书的产物，不会因为证书没配上而静默退档。代价见下面那节。

这个脚本和 `run.sh` 各管一头：它构建到独立的`build/DerivedDataDist`，不碰`/Applications/Amber.app`，
也不启动任何东西；打完包同样会把产物从 LaunchServices 注销并删掉。
**本机安装照旧只走 `run.sh` / `build-install-signed.sh`，那两条永远不接受 ad-hoc。**

### 对方首次打开

dmg **没有经过 Apple 公证**，所以对方下载后第一次打开会被 Gatekeeper 拦。两种绕法，任选其一：

- 在 `Amber.app` 上**右键 → 打开**，弹窗里再点一次「打开」
- 或者装好后跑一次：

```bash
xattr -dr com.apple.quarantine /Applications/Amber.app
```

只需做一次，之后正常双击。这是绝大多数未公证的开源 macOS 应用的常态。

### 为什么不用 ad-hoc 签名

公证需要 Developer ID（$99/年的付费账号），暂时不做；但**签名身份不能退到 ad-hoc**，
原因和本机开发时那条约束是同一个：登录凭证存在 Keychain 里，而 Keychain 条目绑定签名的
Designated Requirement。

- **Apple Development 签名**（当前做法）：DR 绑定证书，跨版本不变 → 用户升级 Amber 后 QQ/网易**登录态保留**
- **ad-hoc 签名**：DR 退化成每次编译都变的 CDHash → 用户**每升级一次就要重新登录一次**

两者对 Gatekeeper 来说都要走一遍上面的首次打开流程，ad-hoc 并不会更省事，却白白牺牲登录态。

所以 `make-dmg.sh` 的 `adhoc` 档是给「这台机器上没有可用证书」这种场合留的后门，不是默认路线：
发出去之后再换回 `signed`，对方那次升级同样要重新登录一次（DR 从 CDHash 变成证书，两边对不上）。

> **证书有效期**：当前签名证书到 **2027-02-25** 到期，且开发签名用的是 `--timestamp=none`（无安全时间戳），
> 证书过期后已发出去的旧 dmg 会开始验签失败。到期前在 Xcode 里重新生成证书（免费 Apple ID 也能签）并重新发一版即可。

## UI 规格采集与像素校准

`Tools/ui-spec.swift` 可将任意 macOS`.app` 的技术栈、Bundle 资源以及运行时 Accessibility UI Tree 输出为 JSON；`Tools/pixel-diff.swift` 用于比较同尺寸截图并生成差异热图。完整用法与权限说明见 [design-ref/ui-spec/README.md](design-ref/ui-spec/README.md)。

## 架构

```
Amber/
├── App/           AppDelegate 入口（AmberApplication 子类 + 代码建的 NSMenu 主菜单）、
│                  AppState（provider 注册表/导航/提示）
├── Models/        统一模型：Track / Album / Artist / Playlist / LibraryPlaylist / LyricLine
├── Providers/
│   ├── MusicProvider.swift   统一的 provider 协议（UI 层不感知具体平台）
│   ├── Netease/   网易云客户端（明文 REST API）
│   └── QQMusic/   QQ 音乐客户端（musicu.fcg JSON 协议）
├── Player/        PlayerController（AVPlayer 队列）/ NowPlayingCenter / LRC·QRC 解析
├── Services/      ImageCache（内存+磁盘）/ LibraryStore（收藏·最近播放）
└── Views/
    ├── Shell/     AppKit 骨架：MainWindowController（窗口 + NSToolbar）/
    │              RootViewController（窗口根玻璃 + 迷你播放器 + 整窗播放器 + toast）/
    │              MainSplitViewController（侧栏·内容·面板三列）/
    │              ContentNavigationController（自己的 push·pop 栈，VC 常驻）/
    │              PageHosting（SwiftUI 叶子的宿主与页模型）/ AuxiliaryWindows（附属窗）
    └── …          侧栏（NSOutlineView）/ 首页 / 搜索 / 详情页 / 迷你播放器 /
                   全屏播放器 / 歌词（NSViewController + CALayer）——
                   页面正按 design-ref/appkit-rewrite-plan.md 分阶段换成 AppKit，
                   过渡期仍是 SwiftUI 的那几页由 NSHostingView 包着挂在导航栈上
```

### Provider 接口要点

- 歌曲 ID 带前缀：`ne:347230` / `qq:0039MnYb0qxYhV`
- 播放地址**惰性解析**（播放时才请求取流），协议层用 `ProviderError.unavailable` 表达"VIP 曲目匿名不可播"
- 两平台接口均非官方公开，接口可能变动；因协议层已隔离，修复只需改对应 client

### 已知限制

- **未登录**：网易云 128k mp3；QQ 音乐标准音质，付费/VIP 曲目播放时自动跳过并提示
- 网易云 weapi/eapi 网关对匿名请求已失效，客户端走老版明文 `/api/*`（专辑详情在`interface.music.163.com`）
- QQ 歌单详情主接口可能触发风控（code=10004），已内置老版 `fcg_ucc_getcdinfo_byids_cp` 兜底
- DTS:X（`DT03`）与 Sony 360 Reality Audio（`RA01`-`RA04`，MPEG-H `mhm1`）线上有、也能取到明文，但 **macOS 没有解码器**——`AVURLAsset.isPlayable` 为 false，落地后用`AVAssetReader` 解直接失败，播放器只会空转不出声，故不列入音质档位；杜比同族的`D004`/`D008`/`D009` 是 AC-4，同样解不了。档位前缀码与实测容器见 [qmdec](https://github.com/Sophomoresty/qmdec) 的`download.py`

## 免责声明

本项目仅供个人学习与技术研究，勿用于商业用途。音乐版权归各平台及权利人所有。
