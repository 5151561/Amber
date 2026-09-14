# Apple Music 网页版设计规格(music.apple.com 实扒)

来源:`https://music.apple.com/assets/index~b1eee1f138.css`(2026-08-13 抓取,903 KB)。
网页版与 Mac Music.app 共用一套设计语言,可作为设计 token 参照;**与 Mac 端 AX 实测冲突时以实测为准**(见 memory 的 apple-music-parity-specs)。

本目录文件:

| 文件 | 内容 |
|---|---|
| `index.css` | 原始压缩 CSS(全量,含全部组件样式) |
| `index.formatted.css` | 格式化版,23477 行,便于 grep / 阅读 |
| `tokens-light.txt` | 亮色 `:root` 全部 588 个 token(Safari/Mac 渲染分支) |
| `tokens-dark.txt` | 暗色覆盖的 337 个 token |
| `tokens-diff.txt` | 明暗值不同的 token 对照表 |

注:CSS 里有 `@supports not (font:-apple-system-body)` 的非 Safari 回退分支(如 systemPrimary 在 Chrome 下是 .88/.92 透明度),token 导出已剔除,保持 Mac 基准。

## 核心语义色

| Token | Light | Dark |
|---|---|---|
| `systemPrimary` | rgba(0,0,0,.85) | hsla(0,0%,100%,.85) |
| `systemSecondary` | — | hsla(0,0%,100%,.55) |
| `systemTertiary` | — | hsla(0,0%,100%,.25) |
| `systemQuaternary` | rgba(0,0,0,.1) | hsla(0,0%,100%,.1) |
| `systemQuinary` | rgba(0,0,0,.05) | hsla(0,0%,100%,.05) |
| `pageBG` | #fff | #1f1f1f |
| `keyColor` / `musicKeyColor`(品牌红) | #fa586a | #fa2d48 |
| `keyColor-pressed` | #ff7183 | #ff4661 |
| `keyColor-rollover` | #ff8a9c | #ff5f7a |
| `keyColorBG` | #d60017 | #fa233b |
| `labelDivider` | rgba(0,0,0,.15) | hsla(0,0%,100%,.1) |
| `navSidebarBG` | #fafafa(不透明变体) | #282828 |
| `navSidebarSelectedState` | rgba(31,31,31,.04) | hsla(0,0%,100%,.05)/.08 |

完整清单在 `tokens-*.txt`,含全部 systemRed/Orange/… 系统色、vibrant 变体、IC(increase-contrast)变体。

## 玻璃材质(顶部胶囊播放器 / 迷你播放器共用)

```
--glassMaterialBackground-onLight:  rgba(245,245,247,.55)   (高对比降级: #f2f2f2)
--glassMaterialBackground-onDark:   rgba(38,38,40,.6)       (高对比降级: #0e0e0e)
--glassMaterialShadowColor-onLight: rgba(0,0,0,.1)
--glassMaterialShadowColor-onDark:  rgba(0,0,0,.2)
--glassMaterialInnerStroke-onLight: #000  (alpha .05)
--glassMaterialInnerStroke-onDark:  #fff  (alpha .2;prefers-dark 下 .25)
```

材质配方(`.chrome-player:before`):
- `backdrop-filter: saturate(220%) blur(16px)`
- `background: var(--glassMaterialBackground)`
- `box-shadow: 0 10px 40px var(--glassMaterialShadowColor)`

内描边(`:after`,模拟 0.5px 高光环):
- `box-shadow: inset ±.5px ±.5px var(--glassMaterialInnerStroke)` 四角组合
- opacity = InnerStrokeAlpha(light .05 / dark .2)

## 顶部胶囊播放器(chrome-player,对应悬浮胶囊)

源:`index.formatted.css:8559`

- 容器:高 **56px**,max-width **668px**,`border-radius: 1000px`(全圆),`padding-inline: 16px`
- 布局:`grid-template-columns: auto 1fr auto`(播放控制 | LCD | 右侧动作)
- LCD 区:`padding-inline: 16px`,marquee 行 padding 28px
- 播放控制(`.playback-controls`,formatted:8628):
  - 按钮 24×24,图标宽 30px,间距 `gap: 8px`
  - 主控制组图标 34×34,stop 图标 29×29
  - shuffle/repeat 按钮 24×24,skip 图标宽 28px
- LCD 内部(`.player-lcd`,formatted:8648):
  - 网格:`"artwork metadata after-metadata" / "progress progress progress"`,行高 `34px auto`,总高 56px,`padding-top: 8px`,列间距 8px
  - 封面:aspect 1:1,`border-radius: 6px`,hover 时 `scale: 1.1`(.15s ease-out),悬浮遮罩 rgba(51,51,51,.3)
  - 主标题:`font: var(--body-emphasized)`(600 13px),`color: systemPrimary`
  - 副标题:`font: var(--callout-medium)`(500 12px),`color: systemSecondary`,与主标题间距 2px
  - 进度区:`padding-block: 4px`
- 进度条(`.progress`,formatted:9064):
  - 常态 compact:高 **2px**,thumb 透明,elapsed 色 `systemPrimary`,轨道 `systemQuaternary`
  - hover 展开:高 **7px**,背后 `blur(4px)` 遮罩(56px 高),时间标签显示 `systemPrimary`
  - 过渡 `opacity .25s`
- 音量图标 24×24,fill `systemPrimary`
- 播放中角标(如"电台"badge):`background: systemTertiary`,`color: pageBG`,`border-radius: 1000px`,`padding: 2px 6px`,`font: footnote-emphasized`(600 10px)

## 迷你播放器(mini-player)

源:`index.formatted.css:8441`

- 主体高 **56px**(app 容器内 52px),max-width 736px,`gap: 11px`,padding-inline start 8px / end 15px(app 内 16/16)
- 玻璃材质与胶囊播放器同配方;带进度条时网格 `calc(h - 3px) 0 3px`(进度条 3px 贴底)
- 播放按钮宽 **41px**(图标 35×35),右 margin 9px;skip 图标 25×25
- 元数据行高 40px(app 内 32px),`gap: 8px`
- 封面 **32px**,`border-radius: 6px`,内描边 inset ±.5px
- 主标题 `--body-emphasized`(600 13px)systemPrimary;副标题 `--callout-medium`(500 12px)systemSecondary
- explicit 徽标 10px
- 进度条 thumb 透明

## 侧栏导航条目

源:`index.formatted.css:3948`

- 条目:`border-radius: 6px`,`padding: 4px`,`margin-bottom: 2px`
- 内容行:`gap: 8px`(app 容器内 6px→2px @≥484px),图标 flex-basis 24px(桌面)
- 图标 fill:选中/默认 `systemPrimary`(app 内),web 默认 `keyColor`
- 选中态字体:`--title-navigation`(400 14px/1.43,app 容器内)

## 字体阶(核心)

字体族:`-apple-system, BlinkMacSystemFont, "Apple Color Emoji", "SF Pro", "SF Pro Icons", "Helvetica Neue", Helvetica, Arial, sans-serif`

| Token | 规格 |
|---|---|
| `--title-1` | 400 22px/1.18 |
| `--title-2` | 400 17px/1.29 |
| `--title-3` | 400 15px/1.33 |
| `--title-navigation` | 400 14px/1.43 |
| `--headline` | 700 13px/1.23 |
| `--body` / `-emphasized` | 400/600 13px/1.23 |
| `--body-reduced` | 400 14px/1.43 |
| `--callout` / `-medium` / `-emphasized` | 400/500/600 12px/1.25 |
| `--footnote` | 400 10px/1.3(emphasized 600) |
| `--caption-1` | 400 10px/1.3 |

每档还有 `-tall` / `-short` 行高变体与 locale 字体族回退,见 `tokens-light.txt`。

## 其他杂项

- z-index 体系:default 1,bubbles 50,gpu 1001,web-chrome 9901,contextual-menus 9951,modal 10001
- 全局过渡:`opacity .1s ease-in`
- 分隔线:`.5px solid var(--labelDivider)`
- 圆角习惯:小封面/条目 6px,胶囊 1000px
- 检索方法:`grep -n '<组件名>' index.formatted.css`,组件类名形如 `.chrome-player.svelte-xxx`、`.mini-player__body` 等
