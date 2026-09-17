import AppKit
import CoreGraphics
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

/// 迷你/全窗播放器底衬的**第二支**：跟着封面走的 Metal 动态背景，
/// 对应 Music 的 `TSLBackdropMetalView`（`MPContentView.backdrop` +56 的`style == 1` 那一路）。
///
/// 规格正本 backdrop 规格，接入侧
/// `miniplayer 规格` §11.8。数值 token 全在 `MusicMetrics.Backdrop`，
/// 着色器在同目录的 `MiniPlayerBackdrop.metal`。
///
/// **管线三段**（spec §一的三个类）：
///
/// | 原类 | 这里 | 干什么 |
/// | --- | --- | --- |
/// | `TSLBackdropMetalView`（`MTKView` 子类） | 本类 | 持 368 字节 uniform、每帧推进时间、下发两个编码器 |
/// | `OffscreenBackdropEncoder` | `encodeOffscreen` + `MPSImageGaussianBlur` | 三层旋转封面 → 高斯模糊 |
/// | `PinchEncoder` | `encodePinch` | 上屏：饱和度 / 亮度钳位 / 明暗因子 / 纱罩 |
///
/// **哪些是 [实测]、哪些是 [推]**：uniform 的**取值**（saturation 2.0、floor 0.07、
/// ceiling 0.97、三层周期系数 120/90/70、三层平移、speed 夹取域 [0.1,10]、
/// 减弱动态顶成 5.0、σ 的两个入口、交叉淡化 0.5 秒线性、明暗两档 0.38/0.08）
/// 全是实测，逐条落在 `MusicMetrics.Backdrop`；
/// **怎么用**这些数（着色器里的旋转/扭曲数学、层不透明度、离屏缩放系数、帧率）
/// 在原版里没挖出来（spec §七第 2 项），是 Amber 自拟的 `[推]`，各自在注释里标了。
///
/// **安全降级**：设备 / 库 / 管线 / 纹理任何一步拿不到，本视图就是一块**透明的空视图**
/// ——不崩、不画，调用方（`MiniPlayerContentView`）照旧能在它上面摞别的层。
@MainActor
final class MiniPlayerBackdropMetalView: MTKView {

    private typealias B = MusicMetrics.Backdrop

    // MARK: - 对外契约（与 `TSLBackdropMetalView` 的那几个属性同名同义）

    /// [实测] `-[TSLBackdropMetalView setCGImage:]`：封面一落地就换纹理，
    /// 并在 CPU 上算一次平均亮度（**换图才算，不是每帧**，spec §八）。
    /// 换图触发 0.5 秒线性交叉淡化（spec §3.3）。
    var cgImage: CGImage? {
        didSet {
            guard cgImage !== oldValue else { return }
            adoptArtwork(cgImage)
        }
    }

    /// [实测] `-[TSLBackdropMetalView setScrimAlpha:]` 转发到`PinchEncoder.blackScrimAlpha`
    /// ——**只动深色支**。写入方是 `MPContentView` 的`0.7 − 0.4p`（spec §11.8.3）。
    /// 默认 0.25（`PinchEncoder init` 一条同时写两个 scrim）。
    var scrimAlpha: CGFloat = CGFloat(B.defaultScrimAlpha)

    /// [实测] `animationInterval` 与`speed` 是**同一个字段**，setter 夹到`[0.1, 10]`。
    /// 上游 `10.5 − 9p` 的 10.5 端够不到——被这里削成 10.0。
    var animationInterval: Float {
        get { speed }
        set { speed = B.clampSpeed(newValue) }
    }

    /// [实测] `-[TSLBackdropMetalView setBlur:]`：`blurRadius = clamp(v, 4, 2000)`、
    /// `σ = ceil(blurRadius / 3.0348542587702925)`。
    ///
    /// ⚠ **入口一无条件覆盖它**：每次重建纹理都会用画布对角线重算
    /// `σ = floor(hypot(w, h) × 0.0453947)` 写进同一个编码器，没有「已设过就跳过」的分支
    /// （spec §2.2）。`MPContentView` 建 backdrop 时那句`setBlur(1000)` 发生在还没有
    /// drawable 尺寸的时候，所以稳态下生效的永远是对角线那条。这里照原样实现，
    /// 是为了让「1000 被覆盖」这件事在代码里看得见，而不是悄悄不做。
    func setBlur(_ value: Float) {
        blurRadius = min(max(value, B.blurRadiusRange.lowerBound), B.blurRadiusRange.upperBound)
        blurSigma = B.sigma(blurRadius: blurRadius)
        rebuildBlurFilter()
    }

    // MARK: - 状态

    private var uniforms = MiniPlayerBackdropUniforms()
    /// [实测] 的默认值。
    private var speed: Float = B.defaultSpeed
    /// [实测] 的默认值。
    private var blurRadius: Float = B.defaultBlurRadius
    private var blurSigma: Int = B.sigma(blurRadius: B.defaultBlurRadius)
    /// [实测] spec §八：CPU 上、每张封面算一次。浅色支的两档压暗（0.38/0.08）吃它。
    private var averageLuminosity: Float = 0
    /// [实测] `viewDidChangeEffectiveAppearance`：`bestMatch(from: [.aqua, .darkAqua]) == .darkAqua`。
    private var isDarkMode = true
    /// [实测] spec §3.1：`NSWorkspace.accessibilityDisplayShouldReduceMotion` 命中时
    /// 把 speed 顶成 5.0——**慢十倍，不是停**。
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // MARK: - Metal 家什（任何一件缺席都进降级路径）

    private let commandQueue: MTLCommandQueue?
    private var rotationPipeline: MTLRenderPipelineState?
    private var pinchPipeline: MTLRenderPipelineState?
    private var linearSampler: MTLSamplerState?

    /// 离屏那两张：三层旋转的结果 → 高斯模糊的结果。按 `offscreenDownsample` 缩着渲（[推]）。
    private var offscreenTexture: MTLTexture?
    private var blurredTexture: MTLTexture?
    private var offscreenSize: CGSize = .zero
    private var blurFilter: MPSImageGaussianBlur?
    /// [实测] `perfShadersWorkOnThisDevice`（x8）：MPS 支不可用时原版走手写两趟高斯。
    /// Amber 不做手写那条——不可用就不糊（背景仍是三层旋转的封面，只是清晰），见类注释的降级约定。
    private var supportsPerformanceShaders = false

    /// 交叉淡化的三张槽位：source = 旧图、destination = 新图、pending = 还没轮到的下一张。
    private var sourceTexture: MTLTexture?
    private var destinationTexture: MTLTexture?
    private var pendingTexture: MTLTexture?
    /// [实测] `OffscreenBackdropEncoder.transitionNeeded`。
    private var transitionNeeded = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var occlusionObserver: NSObjectProtocol?

    private var isRenderable: Bool {
        device != nil && commandQueue != nil && rotationPipeline != nil && pinchPipeline != nil
    }

    // MARK: - 生命周期

    init() {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)

        // 底衬要能透出窗后的东西（没封面时它就是一块全透明的视图）。
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = true
        // [推] Amber 自己的省电处理：三层周期在迷你窗里是 700…1200 秒（speed 被顶到上限 10），
        // 一圈转十几分钟，按 60fps 画纯属浪费。理由与取值见 `Backdrop.preferredFramesPerSecond`。
        preferredFramesPerSecond = B.preferredFramesPerSecond
        // 没封面 / 窗口不可见时 `isPaused = true`（也是 Amber 自己的省电处理 [推]）。
        // 帧循环由 isPaused 单独驱动，停下之后要补的最后一帧走 `draw()` 直画。
        enableSetNeedsDisplay = false
        isPaused = true

        // 背景不吃鼠标：底衬底下压着的是「拖窗背景」那一层。
        setAccessibilityElement(false)

        buildModels()
        buildPipelines()
        // blurRadius 的初值 50（[实测] §3.4）由属性初始化式给；`setBlur(1000)` 是**工厂**
        // 那一句（§11.8.1），不在 init 里 —— 见 `MiniPlayerContentView.makeBackdrop`。
        observeSystemChanges()
        updateAppearanceFlag()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 观察者令牌不是 `Sendable`，非隔离的 `deinit` 取不到它们。标`isolated`：
    /// 主线程上释放时照旧同步跑完，注销时机不变。
    isolated deinit {
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// [实测] `viewDidChangeEffectiveAppearance`。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceFlag()
        // 明暗因子与纱罩是每帧从 `applyPinchUniforms` 重写的，跑着的时候下一帧就换过来；
        // 停着的时候本来就没封面可画，不用补帧。
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            // 窗被别的窗完全盖住、或缩到程序坞里，系统会发这条——那就没必要再画了 [推]。
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePausedState() }
            }
        }
        updatePausedState()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePausedState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePausedState()
    }

    // MARK: - 装配

    /// [实测] `prepareImageScaleAndTime` + `buildModels`：
    /// 三层各是单位阵掺一列平移，周期系数 120/90/70；floor/ceiling 一次写死。
    private func buildModels() {
        uniforms.floorValue = B.luminanceFloor
        uniforms.ceilingValue = B.luminanceCeiling
        uniforms.meshWarpTimeScale = B.meshWarpTimeScaleFactor   // 初值 3.5，每帧再按 speed 重写
        uniforms.saturation = 1.0                                // 初值 1.0，上屏那趟顶成 2.0
        for index in 0..<3 {
            var model = MiniPlayerBackdropModel()
            let t = B.modelTranslations[index]
            model.mtx.columns.3 = SIMD4(t.x, t.y, t.z, 1)
            model.timeScale = B.modelTimeScales[index]
            uniforms[model: index] = model
        }
    }

    private func buildPipelines() {
        guard let device, let library = device.makeDefaultLibrary() else { return }
        guard let rotationVertex = library.makeFunction(name: "backdrop_rotation_vertex"),
              let rotationFragment = library.makeFunction(name: "backdrop_rotation_fragment"),
              let pinchVertex = library.makeFunction(name: "backdrop_pinch_vertex"),
              let pinchFragment = library.makeFunction(name: "backdrop_pinch_fragment")
        else { return }

        let rotation = MTLRenderPipelineDescriptor()
        rotation.vertexFunction = rotationVertex
        rotation.fragmentFunction = rotationFragment
        rotation.colorAttachments[0].pixelFormat = .bgra8Unorm
        // 三层叠加：后层按自己的 alpha 压前层（层 alpha 见 .metal 里的 kLayerAlpha，[推]）。
        rotation.colorAttachments[0].isBlendingEnabled = true
        rotation.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rotation.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rotation.colorAttachments[0].sourceAlphaBlendFactor = .one
        rotation.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pinch = MTLRenderPipelineDescriptor()
        pinch.vertexFunction = pinchVertex
        pinch.fragmentFunction = pinchFragment
        pinch.colorAttachments[0].pixelFormat = colorPixelFormat

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        // 旋转会把采样点甩到方图之外；夹边就是原版那种「边缘拉丝再被糊掉」的样子。
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge

        rotationPipeline = try? device.makeRenderPipelineState(descriptor: rotation)
        pinchPipeline = try? device.makeRenderPipelineState(descriptor: pinch)
        linearSampler = device.makeSamplerState(descriptor: sampler)
        supportsPerformanceShaders = MPSSupportsMTLDevice(device)
    }

    private func observeSystemChanges() {
        let center = NSWorkspace.shared.notificationCenter
        // 「减弱动态效果」是可以随时改的，改完要当场生效。
        let token = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        workspaceObservers.append(token)
    }

    private func updateAppearanceFlag() {
        isDarkMode = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - 省电：没封面 / 看不见就停（[推]，Amber 自己的处理，原版没这条）

    /// 宿主说「现在该不该跑」。
    ///
    /// 下面那三条判据（窗口可见、没被遮挡、`isHidden`）对迷你播放器够用，对**整窗播放器
    /// 不够**：那一块收起时是**位移到窗外 + alpha 0**，不是`isHidden`
    /// （`isHidden` 会连带把里面那棵 SwiftUI 的更新一起停掉，见
    /// `NowPlayingContainerViewController.hideAfterCollapse` 与 reactive-ui-review 故障 16），
    /// 三条判据一条都不命中，背景于是在没人看的时候一直画。所以多留这一位由宿主推。
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            updatePausedState()
        }
    }

    /// 停了之后还要**再画一帧**，否则上一首的背景会留在屏幕上（MTKView 停下来只是不再
    /// 驱动帧循环，drawable 里的内容还在）——所以转成暂停时补一次 `draw()` 直画。
    private func updatePausedState() {
        let visible = window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor
        let shouldRun = isActive && isRenderable && visible
            && (sourceTexture != nil || destinationTexture != nil)
        isPaused = !shouldRun
        if !shouldRun, window != nil { draw() }
    }

    // MARK: - 封面进背景（[实测] `setCGImage:`，spec §八）

    private func adoptArtwork(_ image: CGImage?) {
        guard let image, let device else {
            sourceTexture = nil
            destinationTexture = nil
            pendingTexture = nil
            transitionNeeded = false
            uniforms.textureTransitionMix = 0
            averageLuminosity = 0
            updatePausedState()
            return
        }
        // [实测] spec §八：亮度在 CPU 上、每张封面算一次（换图才重算，不是每帧）。
        averageLuminosity = MiniPlayerBackdropLuminance.average(of: image)

        // [实测] spec §八：纹理 sRGB + mipmap 入 GPU。
        // [推] 原版把取像素与建纹理都甩进 `dispatch_async` 的全局队列；Amber 同步做——
        // 一首歌换一次、300 盒的亮度是 9 万像素，代价可以忽略，换来的是不用把
        // CGImage 跨线程递（Swift 并发下它不是 Sendable）。
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .generateMipmaps: true,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]
        guard let texture = try? loader.newTexture(cgImage: image, options: options) else {
            updatePausedState()
            return
        }
        if sourceTexture == nil && destinationTexture == nil {
            // 第一张：直接上，不淡（没有「旧图」可淡）。
            sourceTexture = texture
            destinationTexture = texture
            uniforms.textureTransitionMix = 0
        } else {
            pendingTexture = texture
            transitionNeeded = true          // [实测] 下一帧 updateCrossfade 把 mix 置 1.0 起淡
        }
        updatePausedState()
    }

    // MARK: - 每帧（[实测] `populateCommandBuffer:`，spec §3.1）

    private func stepFrame() {
        let fps = max(1, preferredFramesPerSecond)
        uniforms.time += 1 / Float(fps)                       // 单调累加，不取模

        // [实测] 减弱动态 → 5.0（比默认 0.5 大十倍；timeScale 是周期 ⇒ 慢十倍，不是停）。
        let s = reduceMotion ? B.reduceMotionSpeed : speed
        uniforms.meshWarpTimeScale = s * B.meshWarpTimeScaleFactor
        for index in 0..<3 {
            uniforms[model: index].timeScale = s * B.modelTimeScales[index]
        }
        updateCrossfade(framesPerSecond: fps)
        applyPinchUniforms()
    }

    /// [实测] `updateCrossfade`：1 → 0 线性，0.5 秒，无缓动。
    private func updateCrossfade(framesPerSecond: Int) {
        var t = uniforms.textureTransitionMix
        if t > 0 {
            t = B.advanceCrossfade(t, framesPerSecond: framesPerSecond)
            uniforms.textureTransitionMix = t
            if t == 0 {
                // transitionDidFinish：新图从此就是「当前图」。
                sourceTexture = destinationTexture
            }
        }
        if t == 0, transitionNeeded, let pending = pendingTexture {
            if sourceTexture == nil { sourceTexture = pending }
            destinationTexture = pending
            pendingTexture = nil
            transitionNeeded = false
            uniforms.textureTransitionMix = 1.0               // 开始新一轮
        }
    }

    /// [实测] `-[PinchEncoder encode:…dark:averageLuminosity:]`（spec §四）。
    private func applyPinchUniforms() {
        uniforms.saturation = B.saturation                    // 初值 1.0 在这一趟被顶成 2.0
        if isDarkMode {
            uniforms.factorForDarkMode = B.darkModeFactor
            uniforms.factorForLightMode = 0
            uniforms.blackScrimAlpha = Float(scrimAlpha)
            // 原版只写生效的那一支，另一支停在 uniform 的初值 0；但外观切换后旧值会留着，
            // 所以这里每帧把不生效的那支显式清零——着色器可以无条件叠两个 scrim。[推]
            uniforms.whiteScrimAlpha = 0
        } else {
            uniforms.factorForDarkMode = 0
            uniforms.factorForLightMode = B.lightModeFactor(averageLuminosity: averageLuminosity)
            uniforms.whiteScrimAlpha = B.defaultScrimAlpha    // [实测] 无写入方，恒 0.25
            uniforms.blackScrimAlpha = 0
        }
    }

    // MARK: - 纹理与 σ（[实测] `buildTextures:forView:`，spec §2.2 入口一）

    private func rebuildBlurFilter() {
        guard let device, supportsPerformanceShaders, blurSigma > 0 else {
            blurFilter = nil
            return
        }
        // [实测] 原版 `MPSImageGaussianBlur(sigma: σ / imageDownSample)`——σ 按离屏缩放系数除。
        // 系数本身是 [推]（见 `Backdrop.offscreenDownsample`）。
        let sigma = Float(blurSigma) / Float(B.offscreenDownsample)
        let filter = MPSImageGaussianBlur(device: device, sigma: max(sigma, 0.1))
        // [实测] `setOptions: 6` = allowReducedPrecision | disableInternalTiling。
        filter.options = MPSKernelOptions(rawValue: 6)
        filter.edgeMode = .clamp
        blurFilter = filter
    }

    private func ensureOffscreenTextures() {
        guard let device else { return }
        let drawableSize = self.drawableSize
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }
        guard drawableSize != offscreenSize || offscreenTexture == nil else { return }
        offscreenSize = drawableSize

        // [实测] 入口一，**无条件覆盖 `setBlur:` 定的那个 σ**：
        // σ = floor(hypot(drawable 像素宽, 高) × 0.04539470697716646)。
        let diagonal = (drawableSize.width * drawableSize.width
            + drawableSize.height * drawableSize.height).squareRoot()
        blurSigma = B.sigma(diagonalPixels: diagonal)
        rebuildBlurFilter()

        // [实测] 边长夹到 16384；[推] 再按 offscreenDownsample 缩着渲。
        let clampedWidth = min(drawableSize.width, B.maxTextureDimension)
        let clampedHeight = min(drawableSize.height, B.maxTextureDimension)
        let width = max(1, Int(clampedWidth) / B.offscreenDownsample)
        let height = max(1, Int(clampedHeight) / B.offscreenDownsample)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        offscreenTexture = device.makeTexture(descriptor: descriptor)
        blurredTexture = device.makeTexture(descriptor: descriptor)

        // 着色器要靠这两个数把 NDC 方形化（[推]，借了原版无写入方的 padding 槽）。
        uniforms.padding = SIMD4(Float(width), Float(height), 0, 0)
    }

    // MARK: - 画

    override func draw(_ dirtyRect: NSRect) {
        guard isRenderable,
              let queue = commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer()
        else { return }

        stepFrame()
        ensureOffscreenTextures()

        // 没封面（或纹理没建起来）：清成透明就收工——降级路径，视图看着像不存在。
        guard let source = sourceTexture ?? destinationTexture,
              let offscreen = offscreenTexture,
              let rotation = rotationPipeline,
              let pinch = pinchPipeline,
              let sampler = linearSampler
        else {
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
                encoder.endEncoding()
            }
            buffer.present(drawable)
            buffer.commit()
            return
        }
        let destination = destinationTexture ?? source

        encodeOffscreen(buffer: buffer, target: offscreen, pipeline: rotation, sampler: sampler,
                        source: source, destination: destination)

        // MPS 那条支（spec §2.3 的「真」分支）。拿不到就把没糊的那张直接上屏。
        var pinchSource = offscreen
        if let filter = blurFilter, let blurred = blurredTexture {
            filter.encode(commandBuffer: buffer, sourceTexture: offscreen, destinationTexture: blurred)
            pinchSource = blurred
        }

        encodePinch(buffer: buffer, descriptor: descriptor, pipeline: pinch,
                    sampler: sampler, source: pinchSource)

        buffer.present(drawable)
        buffer.commit()
    }

    /// 离屏趟：三层各画一个铺满的四边形，后层按自己的 alpha 压前层。
    private func encodeOffscreen(buffer: MTLCommandBuffer, target: MTLTexture,
                                 pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                                 source: MTLTexture, destination: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(destination, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        // [实测] uniform 走 index 1（原版 `setFragmentBytes:length:0x170 atIndex:1`）。
        withUnsafeBytes(of: &uniforms) { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }
        for index in 0..<3 {
            var layer = UInt32(index)
            encoder.setFragmentBytes(&layer, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    /// 上屏趟：饱和度 / 亮度钳位 / 明暗因子 / 纱罩，全在 `backdrop_pinch_fragment` 里。
    private func encodePinch(buffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor,
                             pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                             source: MTLTexture) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        withUnsafeBytes(of: &uniforms) { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

// MARK: - 368 字节的 uniform 块

/// 单层旋转模型。stride 80 字节（`float4x4` 64 + `float` 4 + 补白 12）。[实测] spec §1.2
struct MiniPlayerBackdropModel {
    var mtx: simd_float4x4 = matrix_identity_float4x4
    var timeScale: Float = 0
    /// 补白，只为把 stride 顶到 80 与 MSL 的 `struct BackdropModel` 对齐。
    var reserved: (Float, Float, Float) = (0, 0, 0)
}

/// `Uniforms`：368 字节，字段顺序 = 着色器声明顺序 [MSL]，偏移 = 实测写入点 [实测]。
/// 布局与 `MiniPlayerBackdrop.metal` 里的`BackdropUniforms` 逐字段对齐，
/// 总长由 `MiniPlayerWindowTests.testBackdropUniformsAre368Bytes` 钉住。
struct MiniPlayerBackdropUniforms {
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var time: Float = 0
    var textureTransitionMix: Float = 0
    var meshWarpTimeScale: Float = 3.5
    var saturation: Float = 1
    var whiteScrimAlpha: Float = 0
    var blackScrimAlpha: Float = 0
    var factorForDarkMode: Float = 0
    var factorForLightMode: Float = 0
    var floorValue: Float = 0.07
    var ceilingValue: Float = 0.97
    /// （16 对齐，前面自动补到 0x68…0x6f）。原版静态全零、无写入方；
    /// Amber 借 xy 传离屏画布的像素宽高，着色器拿它把 NDC 方形化。[推]
    var padding: SIMD4<Float> = .zero
    /// stride 0x50，三层吃满到 0x170。
    var models: (MiniPlayerBackdropModel, MiniPlayerBackdropModel, MiniPlayerBackdropModel) =
        (MiniPlayerBackdropModel(), MiniPlayerBackdropModel(), MiniPlayerBackdropModel())

    /// 三层按下标读写（元组下标在 Swift 里没有，包一层）。
    subscript(model index: Int) -> MiniPlayerBackdropModel {
        get {
            switch index {
            case 0: return models.0
            case 1: return models.1
            default: return models.2
            }
        }
        set {
            switch index {
            case 0: models.0 = newValue
            case 1: models.1 = newValue
            default: models.2 = newValue
            }
        }
    }
}

// MARK: - 平均亮度（[实测] spec §八）

/// 浅色支两档压暗（0.38 / 0.08，阈值 `averageLuminosity < 0.3`）吃的那个数。
///
/// **和 ASM 不一样的地方，说清楚**：spec §八实测到的**主路径**（premulLast 32bpp
/// 算的是 `Σ byte0 × 255 / byte2`——对 RGBA 内存布局就是 **R×255/B**，
/// 除数不是 alpha，与 premulFirst 支（除数 = α）不对称，spec 自己把语义标了存疑 `[推]`
/// （「Apple 的本意 vs 源码笔误」）。照抄它的可观察后果 spec 也写了：
/// 输出通常 ≫0.3，只有蓝主导或全跳空才落到 0.38 档——**阈值判定退化成噪声**。
///
/// 所以这里按**教科书的 BT.601** 实现（`0.299R + 0.587G + 0.114B`，用 spec 在
/// none-skip 支实测到的那套定点系数 4915/9667/1802），
/// 跳过 α == 0 的像素、归一化 `avg = Σ / (N × 255)` 这两条骨架照 ASM。
enum MiniPlayerBackdropLuminance {

    private typealias B = MusicMetrics.Backdrop

    /// [实测] 大图先等比缩进 300 盒再算（横图 w=300、竖图 h=300）。
    ///
    /// [推] 原版按「像素数 > 100000 才降采样」分路，小图直接 `CGDataProviderCopyData`
    /// 取原像素、再按 alphaInfo × bpp 分七八个支；Amber 统一重绘成 RGBA8 预乘位图——
    /// 少七个分支，也躲开上面说的那条存疑算式。降采样阈值照 ASM 保留：
    /// 小图按原尺寸重绘，大图缩进 300 盒。
    static func average(of image: CGImage) -> Float {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }

        var targetWidth = width
        var targetHeight = height
        if width * height > B.luminanceDownscaleThreshold {
            let box = B.luminanceDownscaleBox
            if width >= height {
                targetWidth = box
                targetHeight = max(1, box * height / width)
            } else {
                targetHeight = box
                targetWidth = max(1, box * width / height)
            }
        }

        let bytesPerRow = targetWidth * 4
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        // data: nil 让 CoreGraphics 自己管这块位图的生命周期——比借一个 Swift 数组的
        // 指针出去安全（那种写法里指针一出闭包就无效了）。
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let base = context.data
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        let raw = UnsafeRawBufferPointer(start: base, count: context.bytesPerRow * targetHeight)
        return average(premultipliedRGBA: [UInt8](raw))
    }

    /// 纯函数那一半：RGBA8（预乘、A 在 byte3）→ [0, 1]。
    ///
    /// [实测] 骨架：α == 0 的像素整个跳过（计数也不进）；`avg = Σ / (N × 255)`；N == 0 时原样返回 Σ。
    /// 亮度本身走 BT.601 定点式（见上面的类型注释，这一处**故意**不照抄主路径那条存疑算式）。
    static func average(premultipliedRGBA pixels: [UInt8]) -> Float {
        var sum = 0
        var count = 0
        var index = 0
        while index + 3 < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha != 0 {
                // 预乘还原：α < 255 时颜色已经被乘过一遍，除回去才是 BT.601 该吃的值。
                var r = Int(pixels[index])
                var g = Int(pixels[index + 1])
                var b = Int(pixels[index + 2])
                if alpha < 255 {
                    r = min(255, r * 255 / alpha)
                    g = min(255, g * 255 / alpha)
                    b = min(255, b * 255 / alpha)
                }
                sum += B.fixedPointLuma(r: r, g: g, b: b)
                count += 1
            }
            index += 4
        }
        guard count > 0 else { return Float(sum) }
        return Float(sum) / Float(count * 255)
    }
}
