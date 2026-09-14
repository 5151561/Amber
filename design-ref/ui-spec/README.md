# macOS UI Specification 采集

这组工具从目标 `.app` 生成可重复对照的结构化规格（技术栈、资源清单、运行时辅助功能树），
再用相同环境的截图做像素校准。只用公开的辅助功能接口与屏幕截图，不涉及对程序代码的分析。

> **采集产物一律不入库。** `pages/`、`am/`、`sweep/` 与`music-static.json` 都在`.gitignore` 里：
> 运行时的辅助功能树会带上本机资料库里的歌名、播放列表名与账号名，截图同理。
> 代码注释里引用的 `design-ref/ui-spec/pages/*.json` 需要按下面的步骤在本机自行采集。

## 1. 静态扫描 Bundle

不启动目标 App、不需要额外权限：

```bash
swift Tools/ui-spec.swift /System/Applications/Music.app \
  --output design-ref/ui-spec/music-static.json
```

输出包含：

- Bundle ID、版本、可执行文件与架构；
- 启发式技术栈判断（AppKit / SwiftUI / Catalyst / Electron / Qt / Web UI）及证据；
- `Contents/MacOS` 内被分析的主程序与调试 dylib，以及它们动态链接的 Framework；
- NIB、Storyboard、Assets.car、图片、PDF、CSS、JS、ASAR 等资源清单。

技术栈识别不是对程序代码的分析结果。混合 App 会同时列出多个命中项；`technology.primary` 只是便于工具消费的主分类。

## 2. 采集运行时 UI Tree

先在“系统设置 → 隐私与安全性 → 辅助功能”中允许当前终端，然后运行：

```bash
swift Tools/ui-spec.swift Music --runtime \
  --screenshot design-ref/ui-spec/music-reference.png \
  --output design-ref/ui-spec/music-runtime.json
```

如果 App 尚未运行，可显式加 `--launch`。这会启动目标 App，因此默认不开启。

每个 AX 节点尽可能记录：

- role、subrole、identifier、title、description、value；
- enabled、focused、selected、min/max value；
- 屏幕坐标 `frame`；
- 以所属窗口左上角为原点的 `frameInWindow`；
- children 与实际 childCount。

AX 只能提供应用主动暴露的语义与几何信息。SwiftUI 私有布局、字体、颜色、圆角和阴影通常仍需截图或项目内设计 token 校准。

## 3. 多宽度扫描 → 拟合布局规则

单次采样只能给出「这一个窗口尺寸下的最终 frame」，等于一个方程一个解，反推不出布局规则。
把宽度当自变量扫一遍，规则就能解出来：

```bash
swift Tools/ui-spec.swift Music \
  --widths 980,1040,1100,1180,1280,1360,1440 \
  --screenshot-dir design-ref/ui-spec/sweep/album-detail/shots \
  --state default \
  -o design-ref/ui-spec/sweep/album-detail/sweep.json

python3 Tools/fit-layout.py design-ref/ui-spec/sweep/album-detail/sweep.json \
  --report design-ref/ui-spec/sweep/album-detail/rules.md \
  --json design-ref/ui-spec/sweep/album-detail/rules.json
```

采集端的两个要点：

- **记录实际宽度而非请求宽度。** 窗口有最小宽度（Music 是 980），请求 900 实际得到 980；
  拟合的自变量必须是 `windowSize.width`。
- **等布局稳定再采。** 工具会连续两次编码 AX 树、节点数一致才认；`settled: false`
  表示三次都没稳定，加大 `--settle`。不做这一步时首个样本会整层缺失容器
  （实测 `AXOutline` 不出现），几百个节点被判成「只在部分宽度出现」。

拟合端把每个节点的 x/y/w/h 以及对父节点的 leading/trailing/top/bottom 表达成 W 的函数：

- `constant` — 固定值，可直接进`MusicMetrics`；
- `linear` — 给出`k·W + b` 与语义（跟随右边缘 / 水平居中 / 按比例）；
- `piecewise` — 有断点，报告先给断点位置汇总，再列细节。

报告的四段按价值排序：

1. **断点位置** — 哪两个宽度之间发生跳变、涉及多少类结构。缩小采样间隔可以把断点逼到 1pt。
   实测 Music 资料库「歌曲」表在 **1215 → 1220** 之间跳变，横向滚动条同时消失，两个信号互相印证。
2. **随宽度变化** — 线性规则，直接对应 SwiftUI 里该用 `frame(maxWidth:)` 还是居中约束。
3. **高频常量** — 计数是「用到该值的结构类数量」，克隆行只算一类。
   实测行高 22 命中 75 类结构、leading 26 命中 30 类，这种才是 token。
4. **只在部分宽度出现** — 响应式显隐，直接给出组件的出现条件。

跨状态对比：分别用 `--state sidebar-expanded` / `--state sidebar-collapsed` 采集，
再把多个 JSON 一起传给 `fit-layout.py`，报告会按状态分节。

> `design-ref/ui-spec/sweep/` 已在`.gitignore` 中：原始扫描包含资料库里的歌名等文本，不入库。
> 需要留档时只提交 `rules.md`，并先检查其中不含个人内容。

## 4. Pixel Diff

保证 macOS 版本、窗口尺寸、显示缩放、字体、外观和页面状态相同，然后对参考图与 Amber 截图执行：

```bash
swift Tools/pixel-diff.swift \
  design-ref/ui-spec/music-reference.png \
  design-ref/ui-spec/am-candidate.png \
  --output design-ref/ui-spec/diff.png \
  --report design-ref/ui-spec/diff.json \
  --threshold 2
```

热图中透明像素表示无显著差异，红色表示差异强度。JSON 会报告差异像素比例、MAE、RMSE、最大通道差和差异包围盒。

## 5. 逐区域外观比对

`pixel-diff.swift` 给的是整窗差异热图，回答「哪里不一样」；`glyph-diff.py` 回答
「差在哪一项」——因为 **AX 只报 hit box，图标画多大、什么颜色、有没有被虚化，它一个字都不说**。

```bash
python3 Tools/glyph-diff.py music.png am.png \
  -r "播放:536.5,859,36,36" -r "音量:1126.5,859,36,36"

# 或从 ui-spec 的 JSON 里按 AX 标识取框（两侧不同名时写 参考=候选）
python3 Tools/glyph-diff.py music.json am.json \
  --pairs "shuffleButton=shuffle" --crops out/
```

三项指标各自回答一个问题：

| 指标 | 怎么算 | 抓什么 |
| --- | --- | --- |
| 外框 | autocontrast 后过半阈值的包围盒 | 图标画多大，与亮度无关 |
| 等效白度 | (峰值 − 底色) / (255 − 底色) | 前景不透明度，直接对到 `MusicGrays` 的语义档位 |
| 边缘锐度 | 归一化后的水平梯度均值 | 有没有被虚化 |

实测抓到的、AX 完全看不见的差异：上一首键字号大了三成（墨量是 Music 的 1.8 倍）、
未激活的随机与循环该是白 25% 却画成了纯白、进度条悬浮时 Music 会把中央内容虚化
（标题锐度 26.3 → 4.0）而 Amber 只是降了不透明度。

两条使用注意：

- **文本区域的外框差异多半只是文案不同**（「有太多不能講」比「又到天黑」宽），
  这时只看白度与锐度；图标区域才该逐项都对上。
- **计时类观察不能用 AX 轮询**。高频遍历 AX 树会卡住目标 App 的主线程，动画根本不推进
  ——实测轮询 6 秒都等不到 Music 的悬浮变形，改成固定间隔截图后测出它在 0.2–0.3 秒之间完成。
  每次采样前还要把鼠标移开复位，否则单发 `mouseMoved` 不触发`mouseEntered`，
  会得出「有延迟」的错误结论。

## 6. 建议的校准闭环

1. 固定外观与页面状态，对 Music 做一次多宽度扫描，拿到规则而不是某一次的取值。
2. 断点用二分逼近：先粗扫定位区间，再在区间内加密采样。
3. 把 `constant` 写进`MusicMetrics`；`linear` 落成 SwiftUI 的对齐/填充约束，
   而不是硬编码坐标；`piecewise` 落成显式断点。
4. 对 Amber 用同样的宽度列表扫一遍，两份 `rules.json` 逐条对比，差异即待办。
   **对比前先把两侧都归零。** 参照 App 自己的持久化状态会污染测量：实测 Music 的
   「类型」列宽 249、Amber 80，看着像差 169，查 Music 自己的
   `zh_CN.lproj/ColumnWidths.plist`，Genre 的`default-column-width` 就是 80 ——
   是那台机器上的 Music 被拖宽过。同理 Amber 侧要先
   `defaults delete com.changlepan.Amber songsTableColumns`，
   否则量到的是自己拖出来的列宽和列序。
5. 用同尺寸截图跑 pixel diff 定位差异区域，再用 `glyph-diff.py` 逐区域看差在
   字号、颜色还是虚化——**盒子对齐不等于外观一致**，AX 全绿时外观仍可能一眼就不同。
6. 每次改动都保留采集条件；不同 macOS 或显示 scale 的结果不要直接混比。

抄相对关系而不是绝对坐标：AppKit 的 `alignmentRectInsets`、NSTextField 的 baseline 偏移
在 SwiftUI 里没有对应物，照抄绝对 y 会稳定差 1–2pt。拟合出的 leading/top 才是可移植的量。

不要把登录凭证、账号文本或私人歌单等 AX value 提交到仓库。运行时 JSON 可能包含屏幕上可见的文字，应在提交前检查。
