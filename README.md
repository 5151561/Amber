<div align="center">

<img src=".github/icon.png" width="128" alt="Amber">

# Amber

Apple Music 风格的 macOS 原生音乐播放器，聚合 **QQ 音乐** 与 **网易云音乐**

[![Release](https://img.shields.io/github/v/release/5151561/Amber?style=flat-square&color=F07A2B)](https://github.com/5151561/Amber/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/5151561/Amber/total?style=flat-square&color=F07A2B)](https://github.com/5151561/Amber/releases)
![macOS](https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen?style=flat-square)

</div>

## 功能

- **双平台聚合**：首页推荐、排行榜、新碟、广播、搜索（单曲 / 专辑 / 歌手 / 歌单），两边结果并排展示
- **扫码登录**：QQ 音乐与网易云都支持，凭证存钥匙串；登录后可播 VIP 曲目
- **高音质**：QQ 音乐最高杜比全景声 / 臻品母带，所选档位没有时自动逐级降档
- **歌词**：同步滚动、逐字高亮、翻译与罗马音，点击跳转
- **播放**：队列、随机 / 循环、淡入淡出过渡、音效增强、MV
- **资料库**：收藏、最近播放、下载与本地导入
- **系统集成**：控制中心、媒体键、正在播放

纯 Swift + AppKit / SwiftUI / AVFoundation，零第三方依赖。

## 安装

从 [Releases](https://github.com/5151561/Amber/releases/latest) 下载 dmg，把 Amber 拖进「应用程序」。

安装包未经 Apple 公证，首次打开会被拦下：在 Amber 上**右键 → 打开**，或执行一次

```bash
xattr -dr com.apple.quarantine /Applications/Amber.app
```

## 从源码构建

需要 Xcode 26。先配签名 Team ID：

```bash
cp Support/Signing.local.xcconfig.example Support/Signing.local.xcconfig
```

填好 `AMBER_DEVELOPMENT_TEAM` 后，构建、安装并启动：

```bash
./Tools/run.sh
```

签名约束、打包 dmg 与其它工具见 [Tools/README.md](Tools/README.md)。

## 免责声明

本项目仅供个人学习与技术研究，勿用于商业用途。两个平台的接口均非官方公开，随时可能变动；音乐版权归各平台及权利人所有。
