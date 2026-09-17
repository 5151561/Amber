# Swift 6.4 工具链：把还没用上的部分用起来

> 2026-09-17 一轮做完。起因是一个疑问：「刚从 Swift 5 升到 6.0，为什么不直接 6.4？
> 然后感觉很多新特性也没用上。」
>
> 与 [appkit-rewrite-plan.md](appkit-rewrite-plan.md) 的分工：那份管「界面骨架换成什么」，
> 这份管「语言与工具链这一层欠了什么」。两份在**阶段 9 / 阶段 4** 这一格是同一件事
> （剥离 Combine），各自记各自那一面。铁律仍以 `AGENTS.md` 为唯一副本。

## 0. 先纠正前提：没有「6.4 语言模式」

语言模式只有 4 / 4.2 / 5 / 6——编译器原话：

```
error: invalid value '7' in '-swift-version 7'
note: valid arguments to '-language-mode' are '4', '4.2', '5', '6'
```

Xcode 里 `SWIFT_VERSION = 6.0` 的 `.0` 只是显示格式。**编译器本来就是 6.4**
（Xcode 27 beta / swiftlang-6.4.0.30.4）。6.1→6.4 给的是新的 upcoming feature 开关和新
API，不是新语言模式；下一个语言模式是 7，尚未开放。

「新特性没用上」这句对一半：`@concurrent`（17 处）、`Atomic`（17 处）当时已经在用；
`nonisolated(nonsending)` 由 `SWIFT_APPROACHABLE_CONCURRENCY = YES` 默认打开，
代码里 0 处显式写法**是对的，不是缺口**。

## 1. 分阶段与状态

所有开关集中在 [Support/SwiftFeatures.xcconfig](../Support/SwiftFeatures.xcconfig)，
每阶段只改那一个文本文件，回退就是注释一行。

| 阶段 | 内容 | 代价（实测，`swiftc -emit-sil -wmo` 全模块） | 状态 |
| :-: | --- | --- | --- |
| 0 | 文档收口 + `SwiftFeatures.xcconfig` 载体 | — | **已完成** |
| 1 | `InternalImportsByDefault`、`ImmutableWeakCaptures` | 各 0 条 | **已完成** |
| 2 | `MemberImportVisibility` | 139 error → 实际只缺 13 行 `import` | **已完成** |
| 3 | `ExistentialAny` | +67 warning，纯机械加 `any` | **已完成** |
| 4 | **剥离 Combine** → `@Observable` + `Observations` + `swift-async-algorithms` | 23 个 `ObservableObject` / 167 个 `@Published` / 112 处 `.sink` | **已完成**（12 批，见 appkit-rewrite-plan.md 阶段 9 的补记） |
| 5 | **`Span` 取代手写字节解析** | 3 个文件 | **已完成** |
| 6 | **strict memory safety 全量标注** | +502 warning | **已完成**（7 批） |

阶段 1–3 的四个开关是 Swift 7 语言模式会默认打开的（`-print-supported-features` 里
`enabled_in = 7`），提前开等于把那笔债现在还掉，而不是等语言模式 7 落地时一次性爆。

## 2. 计划里被实测推翻的假设

这一节比阶段表值钱：下次再想做同样的事，先看这里。

1. **`Observations` 的 `dropFirst()` 会吞改动。** 订阅登记之后、`Task` 第一次跑起来之前
   的那段窗口里如果值就变了，首个元素已经是**新值**，`dropFirst()` 把它整个吞掉、
   而且等多久都不来。`TaskBag.observe` 因此在调用点同步取一份基线。
2. **事件流没换 `AsyncChannel`，换了自写的 `EventChannel`。** `AsyncChannel.send` 是
   `async`、带背压，而 `LibraryStore.notify(_:)` 是被几十处同步调用的同步方法；
   `AsyncStream` 又是单消费者，而 `changes(affecting:)` 的设计就是每页各订各的。
3. **`struct Row` 改 `~Escapable` 做不了**，两道独立的坎：`Row` 借的是 `sqlite3_stmt`
   的行缓冲，唯一写得出的标注要开两个实验特性（`LifetimeDependence` + `Lifetimes`）；
   就算都打开，`db.value(sql) { $0 }` 照样不报错（`T` 被推成 `Void`），拦截点落在再下一行。
4. **`@unsafe` 不豁免函数体**，只朝外传播（逼调用点写 `unsafe`）。Swift 6.4 **没有区域
   标记**：`unsafe do/for/if` 不成立，也钻不进闭包体。三个杠杆只有：表达式级 `unsafe`、
   `@safe` 外壳、`@unsafe`（朝外）。所以计划里「五个回调标 `@unsafe` 就罩住 51 处
   `dsp.pointee`」不成立，改成一个约束在 `Pointee == TapDSP` 上的 `@safe` 外壳。
5. **`Span` 改写不会顺带消掉 SMS 警告**，两者基本正交——`AudioTagWriter` 改写前 SMS 是 0 条，
   改写后因 `unsafeLoadUnaligned` 变成 2 条。Span 仍排在 SMS 之前，理由是「别标注完又重写」。
6. **`String(format: "%.Nf")` 没有等价的安全替代。** `FormatStyle` 舍入的是最短十进制
   表示、`%f` 舍入的是二进制真值，半分点上分家（60 万样本差分：`%.1f` 差 49 条、
   `%.3f` 差 5998 条；22050 Hz 是真实分歧）。所以 `fixed(_:)` 是 `@safe` **外壳**不是替换。
7. **`load(fromByteOffset:as:_:)` 带 `ByteOrder` 参数的那版要 macOS 27**，部署目标 26 下
   只能写两步：`s.load(…, as: UInt32.self).bigEndian`。
8. **类型化通知（`NotificationCenter.addObserver(of:for:)`）现在还用不上**：整族 AppKit
   message 是 `@available(macOS 27.0, *)`；`UserDefaults.DidChangeMessage` macOS 26 就有，
   却是 `AsyncMessage` 而非 `MainActorMessage`，碰不到主 actor 隔离的自己。

## 3. strict memory safety 的三档判据

新代码碰到裸指针时按这个次序选，**不许跳档**（`AGENTS.md` 里有同一条的短版）：

1. **能改成安全代码的先改，不标注。** 例：`String(format:)` → `Models.swift` 的
   「数字成串」三件套；QRC 的手写 `inflate` → `NSData.decompressed(using: .zlib)`。
2. **无安全替代但反复出现 → `@safe` 外壳。** 判据：同一个不安全声明全仓被用 **≥3 次**。
   现成的在 [Amber/Safety/AppKitSafeAccess.swift](../Amber/Safety/AppKitSafeAccess.swift)
   （AppKit 的 `unowned(unsafe)` 反向指针 84 处）与 `AudioTap.rt`。
3. **一次性的、或本质不安全的 → 表达式级 `unsafe` + 契约注释**（「不安全在哪、谁保证它
   安全」）。函数级 `@unsafe` 只用于「这个函数本身就是不安全契约的一部分」，
   例：AudioTap 的五个 `@convention(c)` 回调。

**不要全量套 `MIGRATE` 的 fix-it**：它会把第一、二档一起降成第三档，502 条就永久固化成
噪音。反向哨兵是 `[#UnnecessaryUnsafe]`——标过头编译器会指出来，而且**开关关着时也报**，
所以平时的 warning 基线就能兜住。

## 4. 明确不做

- **Swift Testing 迁移**（1119 个 XCTest 方法）——本轮不含。
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**——此前已实测否决：`AudioTap` 的
  `@convention(c)` 函数指针形不成、六个 AppKit 子类的 `deinit`/`init` 隔离域对不上。
- **`Mutex` 取代 `OSAllocatedUnfairLock`**（9 处）——现状能用，换了无收益。
- **`InlineArray` 用在 DES 的 block/state 上**——合身，但那是性能优化不是本轮主题。

## 5. 这一轮看出来、按纪律没动的三条

都在实时音频路径上，改动要单独一轮 + 单独实机听：

1. **`TapShared.dsp` 是唯一跨线程却非原子的字段**（`tapPrepare`/`tapUnprepare` 写、
   `tapProcess` 读），全靠「MediaToolbox 串行发三个回调」这个假设，而同类字段全是 `Atomic`。
   假设若不成立就是实时路径上的 use-after-free。**这一条最值得单独查。**
2. `AudioTap.init?()` 的失败路径上有个理论过度释放窗口：`status == noErr` 但 `tapRef`
   为 nil 时会 release 一次，而 MediaToolbox 可能仍会调 finalize 再 release。
3. 六个实时辅助函数若改收 `inout TapDSP`，契约 ③ 那 56 处会作为**安全代码**消失、
   连 `@safe` 外壳都不需要——那是签名改动，涉及实时路径上的独占性检查。
