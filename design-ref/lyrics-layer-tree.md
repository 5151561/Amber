# 歌词层树与逐帧语义

> 本文是**规格文档**：只写层怎么搭、每帧改什么、各项数值取多少，以及怎么验收。
> 具体取值表在 `lyrics-spec.md`，本文不重复；两处冲突时以那边为准。
> 层名照 Amber 现有实现写（`SBS_TextContentLayer` / `TextContentLayer` / `InstrumentalContentLayer`）。

## 1. 层树

```
SyncedLyricsLineView (NSView, flipped)
└── lineLayer : SyncedLyricsLineLayer
    ├── backgroundLayer       // 悬停底板，懒建，insertSublayer(at: 0)
    └── containerLayer        // 构造时唯一立即创建的层
        └── contentLayer      // 懒建，四选一：
            ├── SBS_TextContentLayer        // 逐字
            ├── TextContentLayer            // 整行
            ├── InstrumentalContentLayer    // 间奏
            └── 多行内容层                   // 主行 + 音译行 + 翻译行
                ├── mainLineLayer
                ├── transliterationLineLayer
                └── translationLineLayer
```

- 行层与逐字内容层的**无参 `init` 是 `unimplemented initializer`，直接调用会崩**。
  真实构造只走 `initWithLayer:`。照搭时不要把无参 `init` 当入口。
- 构造里只 `alloc/init` 了 `containerLayer`；`contentLayer` 与 `backgroundLayer` 都是 nil。
- `backgroundLayer` 插在 index 0，底板永远在最底。
- 行层的 `layoutSublayers` 只做三件事：内容层铺满 bounds、底板铺满、
  底板再外扩 `highlightViewMargin` **各边 16**（`(-16, -16, W+32, H+32)`）。
  它一行文字几何都不算；文本几何在逐字内容层（按 alignment 给 textLayer 一个 x）
  与文本层自己的 `layoutSublayers`（重建 CTLine）里。

## 2. 逐帧

```
CADisplayLink → 每帧回调
  t = provider.now() − anchor
  for view in visibleLineViews:
      layer = view.lineLayer.contentLayer as? SBS_TextContentLayer
      if layer.progress != t:
          layer.progress = t
          for textLayer in [layer.textLayer, layer.backgroundTextLayer]:
              if !(t < old && old − t < 0.5):     // 回退 < 0.5s 丢弃
                  textLayer.progress = t; applyProgress(t, animated: true)
```

- **进度是绝对秒**，不是 0…1。
- `applyProgress` 三分支：
  - `isSelected == false` → 词级静态处理，无缩放；
  - `isSelected && animated` → 走带提前量的那条（`progress + animationHeadstart`），
    `animationHeadstart = 0.10`；
  - `isSelected && !animated` → 包 `CATransaction` 后投递。
- 每帧只改：渐变宽度、`backgroundTextLayer` 的 progress、音节层 `position`、
  滚动容器 bounds。**不重建 CTLine**（缓存键是 `lastSizedWidth` + `adjustedText`）；
  **整行没有任何仿射变换写入**——字形尺寸全程不变（见 `lyrics-spec.md` §1.1：
  放大只发生在逐音节强调那条路上）。

## 3. 渐变层几何（入口与实体同一处实现）

令 `W/H = bounds`、`fw = featherWidth`、`pad = outerPadding.height`：

| direction | gradient 条 | fill |
| --- | --- | --- |
| `1`（RTL） | `(0, −pad, fw, H+2pad)` | `(fw, 0, max(W−fw,0), H)` |
| 其它（LTR） | `(W−fw, −pad, fw, H+2pad)` | `(min(0,W−fw), 0, max(W−fw,0), H)` |

`horizontalPaddingLayer`：`x = RTL ? fill.maxX : fill.minX − outer.width`，
`frame = (x, −outer.height, outer.width, 2·outer.height)`（高度**不含** bounds.height）。

`fw = 30.0`。以本表为准：RTL 时 gradient 条贴在左边、宽度就是 `fw`。

## 4. 逐音节放大

**机制、时刻表与四个实现坑都在 `lyrics-spec.md` §1.1 / §1.1.1**，这里只留与层树相关的一条：

- 缩放落在**音节层**（逐字形一层）的 `affineTransform` 上，不是 `layer.transform`，
  也不在行层或内容层上；因此「行层有没有被拉伸」这个问题永远查不到它。

`[实测-证伪]` 2026-10-27 与参考实现同帧对拍：**整行字宽/字重全程不变**，
唱到与未唱的字形尺寸一致。`emphasizingScaleRange` 在本仓只喂两处不画字的地方
（渐变纵向余量、辉光栅格化倍率），**行层不写 `transform`**。
曾经把它接到行层 `transform` 上，效果是整行「越唱越大」，与截图不符，已回退。

`syllableLift`：配置里是 `2.0`（**y 减**），但那是字形落点坐标系里的微调；
`[PX]` 量到已唱字高出 3.5–4.2pt，且既然没有放大的贡献，抬升就是纯平移，
本仓取 **4**。

## 5. 辉光

- 门控：`glyphs.count > 0 && duration > 0`。**没有 1 秒阈值**。
- `alpha = progress × 0.4`（`glowRange 0…0.4`），`T = min(duration, 3)`，ζ = 1。
- 实现是 `CALayer.shadowOpacity`，收尾只有一句 `setShadowOpacity:`。
- 布局预留：`padding = |ascent·1.14 + 2·glowRadius − h| / 2`，`glowRadius = 5`（不是 16）。

## 6. 悬停

- 判据：`highlighted == isHighlighted` 直接 return。
- 底板：`cornerCurve .continuous`、`cornerRadius 16`、`opacity 0`、插 index 0。
  可见色是 **8% 白**（另一档 alpha 为 0 的颜色对象不用）。
- 两条动画：底板 `opacity 0↔1`、`containerLayer.opacity 1↔0.85`；
  另有弹簧 `进 (2,300,50) / 出 (1,322,24)` 驱动 `touchDownTransform`。
- 模糊：传 `3.0` → 取 `min(x, 4.0)` → 走 KVC `filters.gaussianBlur.inputRadius`。
  **3.0 与 4.0 上限确证。**

## 7. 弹簧三组

| 组 | 值 | 用途 |
| --- | --- | --- |
| 一 | (1, 100, 18) | 打包成 timing 值 |
| 二 | (1, 150, 30) | 只为取 `settlingDuration` |
| 三 | (1, 130, 30) | 同上 |

`[推断]` 哪一组属于「翻行」还没由消费端闭合（Amber 现用第一组当翻行、第二组当副行）；
阻尼比 0.9 / 1.22 / 1.32，都在「快而不弹」的区间，观感差别小于帧率噪声。

## 8. 仍未闭合

1. ~~`PartialRunLayer` 的粒度~~ —— **已结案（2026-10-28，两轮独立复核）**：
   不存在按 CTRun / 音节的绘制层。歌词内容层只有 `textLayer` + `backgroundTextLayer`
   两个整行文本层；`PartialRunLayer` 无任何引用、初始化即崩，属死代码。
   **以后不再开这个题，也不要照报告去重写层树。**
2. 逐音节落点公式的纵向基准（见 `lyrics-spec.md` §1.1 的闭合状态）。
3. 翻行弹簧归属（见 §7）。
