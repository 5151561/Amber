import AVFoundation
import CoreAudio
import Foundation

/// 当前默认输出设备的画像。
struct AudioOutput: Equatable, Sendable {
    var deviceID: AudioDeviceID = 0
    var name: String = ""
    /// `kAudioDevicePropertyTransportType`：`'bltn'`（内建）/ `'bltooth'` / `'usb '` /
    /// `'hdmi'` / `'dprt'` / `'thun'` / `'agg '` / `'virt'` / `'airp'` …
    var transport: UInt32 = 0
    /// `kAudioDevicePropertyDataSource`：内建设备靠它区分扬声器 `'ispk'` 与耳机口 `'hdpn'`。
    var dataSource: UInt32 = 0
    var channelCount: Int = 2
    /// 这台设备的物理格式里有没有出现编码 AC-3（`kAudioFormat60958AC3`）。
    /// HDMI 直通的先决条件，见 §4.5 与 `Tools/audio-probe.swift`。
    var advertisesEncodedAC3 = false

    /// 这个输出适合走沉浸声吗。
    ///
    /// **没有任何 API 能回答「这台输出支持杜比全景声」**——CoreAudio 只告诉你传输方式、
    /// 声道数和物理格式。所以按 Music 的实际表现反推一条规则：
    /// 内建扬声器 / 蓝牙 / 双声道 USB 耳机（会走头部跟踪或双耳下混）取沉浸声；
    /// HDMI / DisplayPort / 雷雳 / 聚合 / 虚拟 / AirPlay / 多声道 USB 接口一律不取——
    /// 这些路径上 macOS 只会把 E-AC-3 解码成多声道 PCM 再往外送，
    /// 拿无损档反而是更高的实际质量。
    var prefersAtmos: Bool {
        AudioOutputRules.prefersAtmos(transport: transport, channelCount: channelCount)
    }
}

/// 传输方式的判定。抽成纯函数，测试不用真设备。
enum AudioOutputRules {

    static let builtIn = kAudioDeviceTransportTypeBuiltIn
    static let bluetooth = kAudioDeviceTransportTypeBluetooth
    static let bluetoothLE = kAudioDeviceTransportTypeBluetoothLE
    static let usb = kAudioDeviceTransportTypeUSB
    static let hdmi = kAudioDeviceTransportTypeHDMI
    static let displayPort = kAudioDeviceTransportTypeDisplayPort
    static let thunderbolt = kAudioDeviceTransportTypeThunderbolt
    static let aggregate = kAudioDeviceTransportTypeAggregate
    static let virtual = kAudioDeviceTransportTypeVirtual
    static let airPlay = kAudioDeviceTransportTypeAirPlay

    static func prefersAtmos(transport: UInt32, channelCount: Int) -> Bool {
        switch transport {
        case builtIn, bluetooth, bluetoothLE:
            return true
        case usb:
            // USB 耳机是双声道；多声道的 USB 是接口/声卡，后面接的是什么谁也不知道。
            return channelCount <= 2
        default:
            return false
        }
    }

    /// `allowedAudioSpatializationFormats` 的折算。
    /// 「关闭」不做空间化；「自动」只对多声道内容开（AVFoundation 的出厂值）；
    /// 「始终打开」连双声道也允许上混。
    static func spatializationFormats(for mode: DolbyAtmosMode) -> AVAudioSpatializationFormats {
        switch mode {
        case .off: return []
        case .automatic: return .multichannel
        case .alwaysOn: return .monoStereoAndMultichannel
        }
    }
}

/// 默认输出设备的监视器。
///
/// 只盯两件事：默认输出设备换了没有、当前设备的声道配置变了没有。
/// 回调统一回到主线程，值真的变了才发一次 `objectWillChange`——
/// CoreAudio 的属性监听会在插拔时连发好几遍同样的值。
///
/// `@safe`：类里有不安全类型的存储（下面那两个监听块，见它们自己的注释），
/// 但对外只露一个 `output`——`AudioOutput` 整个是标量值类型。裸指针进不来也出不去，
/// 「不安全存储包在安全接口里」正是 `@safe` 这条注解要写的事。
@safe
@MainActor
@Observable
final class AudioOutputMonitor {

    private(set) var output = AudioOutput()

    // 这两个监听块**不是可观察状态，是注销时要还回去的句柄**，标 `@ObservationIgnored`
    // 的理由与批 8 给 `LibraryStore` 那几个回调标的同一条：回调不是状态。
    // 界面只看 `output`，这两个字段私有、全仓只有本文件读（`deinit` 与 `observeStreams`
    // 各一处），没有任何观察者。
    //
    // 不标的代价是实打实的：`AudioObjectPropertyListenerBlock` 的类型里带
    // `UnsafePointer<AudioObjectPropertyAddress>`，而 `@Observable` 会给每个存储属性
    // 展开一套 `_x` 私有存储 + `init/get/set`，**展开出来的代码**逐句报 strict memory
    // safety——那些代码不在本文件里，没有一行可以逐条标 `unsafe`。标上之后
    // 宏不再展开这两个字段，28 条警告一起消失。
    @ObservationIgnored private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    /// 当前挂着流配置监听的设备。同样是内部记账而不是状态：它只在 `refresh` 里
    /// 跟 `output.deviceID` 比一比，观察它只会把同一次换设备重复发一轮。
    @ObservationIgnored private var listenedDevice: AudioDeviceID = 0

    /// 每次现造一份而不是立一个静态常量：`AudioObject*PropertyListenerBlock` 那两个
    /// 函数要的是 `inout`，静态常量还得先抄进一个 var 才能取地址，不如现造。
    private nonisolated static func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // 下面这一族 `unsafe` 全是同一条契约，写在这里，逐处不再重复：
    //
    // **不安全在哪**：CoreAudio 是 C API。监听块的签名里带
    // `UnsafePointer<AudioObjectPropertyAddress>`（块体压根不看它，两个参数都 `_`）；
    // `AudioObjectGetPropertyData` 那一族按 `&size` 报的字节数往 `&value` 里写，
    // 类型与长度全靠调用方自己对——对错了就是越界写或按错误类型解释内存。
    //
    // **谁保证它安全**：长度一律由 `MemoryLayout<T>.size` 或先问一次
    // `AudioObjectGetPropertyDataSize` 得出，与接收变量的类型同源；每次调用都验
    // `== noErr` 才用结果，失败一律走空值分支。`&address` / `&value` 是 Swift 现场
    // 取局部变量地址，生命周期不出这一次调用，不会逃逸。
    //
    // 监听块另有一条**实时线程契约**：CoreAudio 在自己的 HAL 线程上回调，
    // 这里两个块体都只发一个 `Task { @MainActor }` 就返回，不做任何会阻塞的事
    //（不加锁、不分配大块、不读文件）——真正的活都在主 actor 上的 `refresh()` 里。
    // 传给 `AddPropertyListenerBlock` 的 `.main` 只管派发队列，管不住这条约束。
    init(observing: Bool = true) {
        refresh()
        guard observing else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        unsafe defaultDeviceListener = block
        var address = Self.defaultDeviceAddress()
        unsafe AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    /// `isolated deinit`：监听块的类型不是 `Sendable`，非隔离的 deinit 摸不了。
    /// 注销时机不变——监视器由主 actor 上的 `AppState` 持有，最后一次释放本来就在主 actor 上，
    /// 隔离的 deinit 在那里是就地同步跑的。
    isolated deinit {
        if let defaultDeviceListener = unsafe defaultDeviceListener {
            var address = Self.defaultDeviceAddress()
            unsafe AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address,
                .main, defaultDeviceListener)
        }
    }

    /// 重新读一遍默认输出设备的画像。值没变就不发布。
    func refresh() {
        let fresh = Self.readDefaultOutput()
        if fresh.deviceID != listenedDevice { observeStreams(of: fresh.deviceID) }
        guard fresh != output else { return }
        output = fresh
    }

    private func observeStreams(of device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if listenedDevice != 0, let deviceListener = unsafe deviceListener {
            unsafe AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, .main, deviceListener)
        }
        listenedDevice = device
        guard device != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        unsafe deviceListener = block
        unsafe AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
    }

    // MARK: - CoreAudio 读取

    static func readDefaultOutput() -> AudioOutput {
        var output = AudioOutput()
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultDeviceAddress()
        guard unsafe AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                &size, &device) == noErr, device != 0 else {
            return output
        }
        output.deviceID = device
        output.name = stringProperty(device, kAudioObjectPropertyName) ?? ""
        output.transport = uint32Property(device, kAudioDevicePropertyTransportType,
                                          scope: kAudioObjectPropertyScopeGlobal) ?? 0
        output.dataSource = uint32Property(device, kAudioDevicePropertyDataSource,
                                           scope: kAudioDevicePropertyScopeOutput) ?? 0
        output.channelCount = outputChannelCount(device)
        output.advertisesEncodedAC3 = advertisesEncodedAC3(device)
        return output
    }

    static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        // 这一行还挂着一条**与 strict memory safety 无关**的老警告：
        //「forming 'UnsafeMutableRawPointer' to a variable of type 'Optional<CFString>'」。
        // 它在阶段 6 之前就在（基线 16 条里的一条），换 `Unmanaged<CFString>` 能消，
        // 但那是改所有权语义、要真机验设备名，不归标注这一批管——留给后面单独处置。
        guard unsafe AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value as String
    }

    static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard unsafe AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard unsafe AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        // `AudioBufferList` 是尾部变长结构，没法用定长 Swift 类型接，只能按
        // CoreAudio 自己报的 `size` 开一块裸内存。安全由三件事保：字节数就是刚问来的
        // 那个 `size`（同一个变量，中间没人改）、对齐按 `AudioBufferList` 取、
        // `defer` 在所有出口释放。`assumingMemoryBound` 的前提是这块内存确实被
        // CoreAudio 按 `AudioBufferList` 写过——上一行验了 `== noErr`，没写成就不走到这里。
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { unsafe raw.deallocate() }
        guard unsafe AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = unsafe UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        // 闭包体要自己标：`$1` 是 `AudioBuffer`，本身就是不安全类型
        //（里面是 `mData` 那根裸指针）。这里只读 `mNumberChannels` 这个标量字段，
        // 一次也没碰 `mData`。
        return unsafe list.reduce(0) { unsafe $0 + Int($1.mNumberChannels) }
    }

    /// 这台设备公布的物理格式里有没有编码 AC-3。见 §4.5：公开 SDK 里连
    /// E-AC-3 的 IEC-60958 传输 ID 都没有，所以最好的情况也只有 `cac3`。
    static func advertisesEncodedAC3(_ device: AudioDeviceID) -> Bool {
        for stream in outputStreams(device) {
            for format in physicalFormats(stream) where format.mFormatID == kAudioFormat60958AC3 {
                return true
            }
        }
        return false
    }

    static func outputStreams(_ device: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard unsafe AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard unsafe AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func physicalFormats(_ stream: AudioStreamID) -> [AudioStreamBasicDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard unsafe AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var ranged = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: count)
        guard unsafe AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &ranged) == noErr else {
            return []
        }
        return ranged.map(\.mFormat)
    }
}
