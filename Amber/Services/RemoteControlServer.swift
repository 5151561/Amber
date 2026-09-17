import AppKit
import AsyncAlgorithms
import Foundation
import Network
import os

// MARK: - 被控端

/// 遥控器能对播放器做的全部事。抽一层协议只为两件事：
/// ① 服务端不直接依赖 `PlayerController`，测试可以喂一个假的；
/// ② `PlayerController` 的适配写在`RemoteControlServer+Player.swift` 里，
///    播放器本体一行不动（它归另一位负责人）。
@MainActor
protocol RemoteControlTarget: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteTogglePlayPause()
    func remoteNext()
    func remotePrevious()
    /// 定位到毫秒
    func remoteSeek(toMilliseconds ms: Int)
    /// 0…100（DACP 的 `dmcp.volume` 就是这个量程）
    var remoteVolume: Int { get set }
    func remoteSetShuffle(_ on: Bool)
    /// DACP 的 `dacp.repeatstate`：0 关 / 1 单曲 / 2 全部
    func remoteSetRepeat(_ state: Int)
    func snapshot() -> RemotePlayState
    /// 播放状态变了就发一下（不含进度跳动——那会把长轮询打成每秒十次）。
    ///
    /// 每次读都开一条新流；订阅方的 `Task` 一取消，流自己注销。
    var remoteChanges: AsyncStream<Void> { get }
}

/// 一次播放状态的快照，`cmst` 容器就按它拼。
struct RemotePlayState: Equatable {
    var hasTrack = false
    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var elapsedMs = 0
    var totalMs = 0
    /// 0…100
    var volume = 100
    var shuffle = false
    /// DACP 口径：0 关 / 1 单曲 / 2 全部
    var repeatState = 0
    /// 给 `canp` / `asai` 用的稳定 id（拿 track id 折的），换歌时必须变，
    /// 否则遥控 App 认为还是同一首、不去重取封面。
    var trackKey: UInt32 = 0
    var albumKey: UInt64 = 0
    var artworkURL: String?

    /// `dacp.playerstate`：2 停 / 3 暂停 / 4 播放
    var playerState: UInt8 {
        guard hasTrack else { return 2 }
        return isPlaying ? 4 : 3
    }
}

// MARK: - 服务端

/// iOS「遥控」App 的配对与控制。
///
/// ## 协议出处
///
/// 苹果从未公开 DACP/DMAP。下面这套是社区实现的共识，多份开源实现彼此一致，
/// 本实现按它们落地。分三档标注：
///
/// - **格式类可当事实**：DMAP 的 tag+长度+载荷编码、配对码是
///   `MD5(Pair ‖ 每位 PIN 的 ASCII + NUL)`、配对回信是`cmpa{cmpg,cmnm,cmty}`、
///   `_touch-remote._tcp` 的 TXT 里有`DvNm`/`Pair`/`DvTy`。这些在各实现之间逐字节相同。
/// - **`[推]` 具体取值**：`OSsi=0x1F6`、`Ver=131073`、`DvSv=2306`、`mpro`/`apro` 的版本号、
///   控制命令回 204 还是 200、修订号从 2 起算、`_daap._tcp` 到底需不需要。
///   这些抄的是公开实现里最常见的一档，**没有对着真机抓包核过**。
/// - **明确没做**：资料库浏览（`/databases/1/items`、`/browse`）本轮不做，
///   一律回空表，遥控 App 的「资料库」标签页会是空的但不会报错。
///
/// ## 广播
///
/// 三个 Bonjour 服务，各占一个 `NWListener`（Network.framework 一个 listener 只能挂一个
/// service），三个都指向同一份 HTTP 处理：
/// `_touch-able._tcp`（遥控 App 找资料库靠它）、`_dacp._tcp`、`_daap._tcp`。
@MainActor
@Observable
final class RemoteControlServer {

    /// 设置窗那一行要能观察到它，而设置窗那棵树里只有 `AppState`；
    /// 为了不逼着别人的文件先长出一个属性来，本体做成单例，
    /// `AppState` 只负责`configure(target:)` + `start()`（见文件末尾的「接线」注释）。
    static let shared = RemoteControlServer()

    private(set) var isListening = false
    private(set) var pairedDevices: [PairedRemote] = []
    private(set) var discovered: [DiscoveredRemote] = []
    /// 配对失败的原因，配对表单显示它。
    var lastError: String?

    static let log = Logger(subsystem: "com.changlepan.Amber", category: "remote")

    /// 弱引用：单例不该把播放器吊住。
    private weak var target: (any RemoteControlTarget)?
    private let pairingStore: RemotePairingStore
    /// 16 位 hex，既是 `_touch-able._tcp` 的服务名也是`DbId`。
    /// 换一个就等于换了一台「新电脑」，已配对的遥控器会找不到，所以生成一次就存起来。
    let libraryID: String
    /// 资料库对外显示的名字。Music 报的是电脑名。
    let displayName: String

    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: RemoteHTTPConnection] = [:]
    private var browser: NWBrowser?
    /// session-id → 最后一次活动时间。30 分钟不动就作废。
    private var sessions: [Int: Date] = [:]
    private let gate = RemoteRevisionGate()
    private var changeTask: Task<Void, Never>?

    private static let sessionIdleTimeout: TimeInterval = 30 * 60
    /// 长轮询挂起的上限。到点回当前状态，让客户端重新发一轮（连接不至于被中间设备掐掉）。
    private static let pollTimeout: TimeInterval = 30
    static let serverIdentification = "Amber/1.0"

    /// `pairingStore` 用可选而不是直接给默认值：默认参数在**调用方**的隔离域里求值，
    /// 而 `RemotePairingStore` 是`@MainActor` 的，写成默认值会在非隔离处调用时报错。
    init(target: (any RemoteControlTarget)? = nil,
         pairingStore: RemotePairingStore? = nil,
         libraryID: String? = nil,
         displayName: String = Host.current().localizedName ?? "Amber") {
        let pairingStore = pairingStore ?? RemotePairingStore()
        self.target = target
        self.pairingStore = pairingStore
        self.displayName = displayName
        if let libraryID {
            self.libraryID = libraryID
        } else {
            let key = "AmberRemoteLibraryID"
            if let saved = UserDefaults.standard.string(forKey: key), saved.count == 16 {
                self.libraryID = saved
            } else {
                let fresh = RemotePairing.randomLibraryID()
                UserDefaults.standard.set(fresh, forKey: key)
                self.libraryID = fresh
            }
        }
        pairedDevices = pairingStore.devices
    }

    func configure(target: any RemoteControlTarget) {
        self.target = target
        // 攒 50 ms 再报：把连点几下的抖动合成一次修订。
        //
        // 以前这里还有第二个理由——`objectWillChange` 是「就要变了」，立刻取快照会拿到
        // 旧值。换成 `Observations` 之后事件在值**落定之后**才到，那个理由没了；
        // 合抖动这个还在，所以 debounce 留着。
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            for await _ in target.remoteChanges.debounce(for: .milliseconds(50)) {
                guard let self else { return }
                self.gate.bump()
            }
        }
    }

    // MARK: 启停

    func start() {
        guard listeners.isEmpty else { return }
        for spec in serviceSpecs() {
            do {
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = true
                let listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: spec.name, type: spec.type,
                                                     domain: nil,
                                                     txtRecord: NWTXTRecord(spec.txt))
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated { self?.handleListenerState(state, type: spec.type) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated { self?.accept(connection) }
                }
                listener.start(queue: .main)
                listeners.append(listener)
            } catch {
                Self.log.error("起 \(spec.type, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        isListening = !listeners.isEmpty
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        gate.cancelAll()
        sessions.removeAll()
        isListening = false
    }

    private struct ServiceSpec {
        let type: String
        let name: String
        let txt: [String: String]
    }

    private func serviceSpecs() -> [ServiceSpec] {
        // [推] 这几个 TXT 值抄的是公开实现里最常见的一档，没对真机核过。
        // `Ver=131073` =，`DvSv=2306` = 0x902，`OSsi=0x1F6` 是 iTunes 报的系统标识。
        let touchable = [
            "txtvers": "1",
            "DbId": libraryID,
            "CtlN": displayName,
            "OSsi": "0x1F6",
            "Ver": "131073",
            "DvSv": "2306",
            "DvTy": "iTunes",
        ]
        return [
            ServiceSpec(type: "_touch-able._tcp", name: libraryID, txt: touchable),
            // AirPlay 接收端反控发端走这一条；遥控 App 不一定用得上，一并广播不花钱。
            ServiceSpec(type: "_dacp._tcp", name: "iTunes_Ctrl_\(libraryID)",
                        txt: ["txtvers": "1", "Ver": "131073", "DbId": libraryID]),
            // [推] 遥控 App 是否要求资料库同时是个 DAAP 共享，没核实过。
            // 本轮不做资料库浏览，这一条只是让「这台电脑在线」这件事多一个证据。
            ServiceSpec(type: "_daap._tcp", name: displayName,
                        txt: ["txtvers": "1", "Database ID": libraryID,
                              "Machine ID": libraryID, "Machine Name": displayName,
                              "Password": "0", "Version": "196616"]),
        ]
    }

    private func handleListenerState(_ state: NWListener.State, type: String) {
        switch state {
        case .ready:
            isListening = true
        case .failed(let error):
            Self.log.error("\(type, privacy: .public) 断了：\(error.localizedDescription, privacy: .public)")
            isListening = listeners.contains { $0.state == .ready }
        case .cancelled:
            isListening = listeners.contains { $0.state == .ready }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = RemoteHTTPConnection(connection: connection,
                                           serverName: Self.serverIdentification) { [weak self] request in
            guard let self else { return .error(503, "Service Unavailable") }
            return await self.handle(request)
        }
        connections[ObjectIdentifier(wrapper)] = wrapper
        wrapper.onClose = { [weak self] closed in
            self?.connections.removeValue(forKey: ObjectIdentifier(closed))
        }
        wrapper.start()
    }

    // MARK: 配对

    /// 开始浏览 `_touch-remote._tcp`。配对表单打开时调，关掉时`stopBrowsing()`。
    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_touch-remote._tcp", domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.updateDiscovered(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discovered = []
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredRemote] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            guard case .bonjour(let txt) = result.metadata else { continue }
            // Pair 是算配对码的原料，拿不到就没法配——这种条目不列出来更诚实。
            guard let pair = txt["Pair"], !pair.isEmpty else { continue }
            found.append(DiscoveredRemote(id: name,
                                          name: txt["DvNm"] ?? "遥控器",
                                          pairID: pair,
                                          deviceType: txt["DvTy"] ?? "",
                                          endpoint: result.endpoint))
        }
        discovered = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    enum PairingError: LocalizedError {
        case badPIN
        case rejected
        case noReply

        var errorDescription: String? {
            switch self {
            case .badPIN: return "请输入遥控器上显示的 4 位数字。"
            case .rejected: return "密码不对，请对照遥控器上显示的数字重试。"
            case .noReply: return "连不上这台遥控器，确认它和这台电脑在同一个网络里。"
            }
        }
    }

    /// 配对。整个握手是**我们去连手机**：手机上的遥控 App 自己起了个 HTTP 服务，
    /// 我们把算好的配对码送过去，对得上它就回一份 `cmpa`，里面装着往后用来认人的 GUID。
    func pair(_ device: DiscoveredRemote, pin: String) async throws {
        guard RemotePairing.isValidPIN(pin) else { throw PairingError.badPIN }
        // 手机拿到配对码后会立刻回头连我们广播的那个 touch-able 服务，先把摊子支起来。
        start()

        let code = RemotePairing.pairingCode(pairID: device.pairID, pin: pin)
        let path = "/pair?pairingcode=\(code)&servicename=\(libraryID)"
        let response: RemoteHTTPClientResponse
        do {
            response = try await RemoteHTTPClient.get(device.endpoint, path: path)
        } catch {
            throw PairingError.noReply
        }
        // PIN 不对时遥控 App 直接把连接掐了或回非 200，两种都当密码错。
        guard response.status == 200,
              let container = DMAPDecoder.find("cmpa", in: response.body),
              let guidNode = container.child("cmpg") else {
            throw PairingError.rejected
        }
        let paired = PairedRemote(guid: guidNode.hexValue,
                                  name: container.child("cmnm")?.stringValue ?? device.name,
                                  deviceType: container.child("cmty")?.stringValue ?? device.deviceType,
                                  pairedAt: Date())
        pairingStore.add(paired)
        pairedDevices = pairingStore.devices
        Self.log.info("已配对遥控器 \(paired.name, privacy: .public)")
    }

    /// 设置 › 高级 ›「忽略所有遥控器」：清空配对表并停掉广播。
    /// 与 Music 一样是**按下即生效**，不进设置窗那份草稿。
    func forgetAll() {
        pairingStore.removeAll()
        pairedDevices = []
        // 已经连上的会话一并作废，否则手上那台遥控器还能接着控制。
        sessions.removeAll()
        stop()
    }

    // MARK: 路由

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        pruneSessions()
        let path = request.path

        switch path {
        case "/server-info":
            return .dmap(serverInfo())
        case "/content-codes":
            return .dmap(DMAPCodes.contentCodesResponse())
        case "/login":
            return login(request)
        case "/logout":
            if let id = request.int("session-id") { sessions.removeValue(forKey: id) }
            return .noContent
        case "/update":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            let revision = await gate.revision(after: request.int("revision-number") ?? 1,
                                               timeout: Self.pollTimeout)
            return .dmap(.container("mupd", [.u32("mstt", 200), .u32("musr", UInt32(revision))]))
        case "/databases":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            return .dmap(databases())
        case "/databases/1/containers":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            return .dmap(containers())
        case "/ctrl-int":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            return .dmap(controlInt())
        case "/ctrl-int/1/playstatusupdate":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            let revision = await gate.revision(after: request.int("revision-number") ?? 1,
                                               timeout: Self.pollTimeout)
            return .dmap(playStatus(revision: revision))
        case "/ctrl-int/1/nowplayingartwork":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            if let data = await artwork(width: request.int("mw") ?? 0,
                                        height: request.int("mh") ?? 0) {
                return .image(data, type: "image/png")
            }
            return RemoteHTTPResponse()  // 没封面就回 200 空体，遥控 App 会显示占位图
        case "/ctrl-int/1/getproperty":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            return .dmap(getProperty(request))
        case "/ctrl-int/1/setproperty":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            setProperty(request)
            return .noContent
        case "/ctrl-int/1/playpause", "/ctrl-int/1/play", "/ctrl-int/1/pause",
             "/ctrl-int/1/stop", "/ctrl-int/1/nextitem", "/ctrl-int/1/previtem":
            guard validSession(request) else { return .error(503, "Service Unavailable") }
            transport(path)
            return .noContent
        default:
            // 资料库浏览本轮不做：回一份**语法合法的空表**，遥控 App 的资料库页会是空的，
            // 但不会弹错误、也不会把整个连接判死。
            if path.hasSuffix("/items") {
                return .dmap(emptyListing("adbs"))
            }
            if path.contains("/browse/") {
                return .dmap(emptyListing("abro"))
            }
            // 其余未实现的控制命令（cue / playspec / playqueue…）静默吃掉
            if path.hasPrefix("/ctrl-int/") {
                return .noContent
            }
            return .error(404, "Not Found")
        }
    }

    // MARK: 各应答体

    private func serverInfo() -> DMAPNode {
        .container("msrv", [
            .u32("mstt", 200),
            // [推] 版本号抄常见实现：DMAP 2.0.0 / DAAP 3.0.0
            DMAPNode("mpro", .version(2, 0, 0)),
            DMAPNode("apro", .version(3, 0, 0)),
            .string("minm", displayName),
            .u8("mslr", 1),          // 要登录
            .u8("msal", 1),          // 支持自动登出
            .u32("mstm", 1800),      // 会话超时 30 分钟，与 sessionIdleTimeout 一致
            .u32("msdc", 1),         // 一个资料库
            .u8("msup", 1),          // 支持 /update
            .u8("mspi", 1),          // 有 persistent id
            .u8("msex", 1),
            .u8("msbr", 0),          // 本轮不做浏览
            .u8("msqy", 0),          // 本轮不做查询
            .u8("msix", 0),
            .u8("msrs", 0),
            .u8("msas", 0),          // 不需要密码（配对本身就是鉴权）
            .u8("msau", 0),
        ])
    }

    private func databases() -> DMAPNode {
        .container("avdb", [
            .u32("mstt", 200),
            .u8("muty", 0),
            .u32("mtco", 1),
            .u32("mrco", 1),
            .container("mlcl", [
                .container("mlit", [
                    .u32("miid", 1),
                    .u64("mper", 1),
                    .string("minm", displayName),
                    .u32("mimc", 0),   // 本轮不报曲目
                    .u32("mctc", 1),
                ]),
            ]),
        ])
    }

    private func containers() -> DMAPNode {
        .container("aply", [
            .u32("mstt", 200),
            .u8("muty", 0),
            .u32("mtco", 1),
            .u32("mrco", 1),
            .container("mlcl", [
                .container("mlit", [
                    .u32("miid", 1),
                    .u64("mper", 1),
                    .string("minm", displayName),
                    .u32("mimc", 0),
                    .u8("abpl", 1),   // 这是「资料库」那个根歌单
                ]),
            ]),
        ])
    }

    private func emptyListing(_ code: String) -> DMAPNode {
        .container(code, [
            .u32("mstt", 200),
            .u8("muty", 0),
            .u32("mtco", 0),
            .u32("mrco", 0),
            .container("mlcl", []),
        ])
    }

    /// [推] `caci` 报的是「这一路控制接口支持什么」。取值抄公开实现。
    private func controlInt() -> DMAPNode {
        .container("caci", [
            .u32("mstt", 200),
            .u8("muty", 0),
            .u32("mtco", 1),
            .u32("mrco", 1),
            .container("mlcl", [
                .container("mlit", [
                    .u32("miid", 1),
                    .u8("cmik", 1),
                    .u8("cmsp", 1),
                    .u8("cmsv", 1),
                    .u8("cass", 1),
                    .u8("casu", 1),
                ]),
            ]),
        ])
    }

    func playStatus(revision: Int) -> DMAPNode {
        let state = target?.snapshot() ?? RemotePlayState()
        var children: [DMAPNode] = [
            .u32("mstt", 200),
            .u32("cmsr", UInt32(max(0, revision))),
            .u8("caps", state.playerState),
            .u8("cash", state.shuffle ? 1 : 0),
            .u8("carp", UInt8(clamping: state.repeatState)),
            .u8("cavc", 1),            // 音量可控
            .u32("caas", 2),           // [推] 可用的随机档位掩码
            .u32("caar", 6),           // [推] 可用的循环档位掩码
        ]
        guard state.hasTrack else { return .container("cmst", children) }
        // canp = 四个 u32：资料库 / 歌单 / 歌单项 / 曲目。换歌时后两个必须变。
        var nowPlayingIDs = Data()
        for value in [UInt32(1), UInt32(1), state.trackKey, state.trackKey] {
            nowPlayingIDs.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                              UInt8(truncatingIfNeeded: value >> 16),
                                              UInt8(truncatingIfNeeded: value >> 8),
                                              UInt8(truncatingIfNeeded: value)])
        }
        children.append(contentsOf: [
            DMAPNode("canp", .data(nowPlayingIDs)),
            .string("cann", state.title),
            .string("cana", state.artist),
            .string("canl", state.album),
            .string("cang", state.genre),
            .u64("asai", state.albumKey),
            .u32("cmmk", 1),           // 媒体类型：音乐
            .u32("cant", UInt32(max(0, state.totalMs - state.elapsedMs))),
            .u32("cast", UInt32(max(0, state.totalMs))),
        ])
        return .container("cmst", children)
    }

    private func getProperty(_ request: RemoteHTTPRequest) -> DMAPNode {
        let wanted = (request.query["properties"] ?? "").split(separator: ",").map(String.init)
        var children: [DMAPNode] = [.u32("mstt", 200)]
        if wanted.isEmpty || wanted.contains("dmcp.volume") {
            children.append(.u32("cmvo", UInt32(clamping: target?.remoteVolume ?? 0)))
        }
        return .container("cmgt", children)
    }

    private func setProperty(_ request: RemoteHTTPRequest) {
        guard let target else { return }
        if let volume = request.int("dmcp.volume") {
            target.remoteVolume = min(100, max(0, volume))
        }
        if let ms = request.int("dacp.playingtime") {
            target.remoteSeek(toMilliseconds: max(0, ms))
        }
        if let shuffle = request.int("dacp.shufflestate") {
            target.remoteSetShuffle(shuffle != 0)
        }
        if let state = request.int("dacp.repeatstate") {
            target.remoteSetRepeat(state)
        }
    }

    private func transport(_ path: String) {
        guard let target else { return }
        switch path {
        case "/ctrl-int/1/playpause": target.remoteTogglePlayPause()
        case "/ctrl-int/1/play": target.remotePlay()
        case "/ctrl-int/1/pause", "/ctrl-int/1/stop": target.remotePause()
        case "/ctrl-int/1/nextitem": target.remoteNext()
        case "/ctrl-int/1/previtem": target.remotePrevious()
        default: break
        }
    }

    private func artwork(width: Int, height: Int) async -> Data? {
        guard let urlString = target?.snapshot().artworkURL,
              let image = await ImageCache.shared.image(for: urlString) else { return nil }
        let size = NSSize(width: width > 0 ? CGFloat(width) : image.size.width,
                          height: height > 0 ? CGFloat(height) : image.size.height)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scaled = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: 会话

    private func login(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let guid = request.query["pairing-guid"],
              pairingStore.contains(guid: guid) else {
            // 没配过的一律 503：遥控 App 见到这个就回到「请配对」那一屏。
            return .error(503, "Service Unavailable")
        }
        let id = Int.random(in: 1...Int(Int32.max))
        sessions[id] = Date()
        return .dmap(.container("mlog", [.u32("mstt", 200), .u32("mlid", UInt32(id))]))
    }

    private func validSession(_ request: RemoteHTTPRequest) -> Bool {
        guard let id = request.int("session-id"), sessions[id] != nil else { return false }
        sessions[id] = Date()
        return true
    }

    private func pruneSessions() {
        let deadline = Date().addingTimeInterval(-Self.sessionIdleTimeout)
        sessions = sessions.filter { $0.value > deadline }
    }

    /// 测试用：不走真的 `/login` 就塞一个会话进去。
    func installSessionForTesting(_ id: Int) { sessions[id] = Date() }
}

// 接线：`AppState` 里加这两处（本文件不改别人的文件，代码留在这里给 lead 抄）
//
//   init() 末尾，`NowPlayingCenter.shared.configure(player: player)` 那一带：
//       RemoteControlServer.shared.configure(target: player)
//
//   runLaunchTasksOnce() 里，`measureDownloadedTracks()` 之后：
//       RemoteControlServer.shared.start()

// MARK: - 修订号闸门

/// 长轮询用的修订号。`/update` 与`/playstatusupdate` 都是「我手上是第 N 版，
/// 有新的再回我」，所以要能把请求挂起到状态真的变了为止。
///
/// [推] 起始值 2：客户端第一次问按惯例送 `revision-number=1`，那一发必须立刻回当前状态，
/// 否则遥控 App 会白着屏等到超时。
@MainActor
final class RemoteRevisionGate {

    private final class Waiter {
        var continuation: CheckedContinuation<Int, Never>?
    }

    private(set) var revision = 2
    private var waiters: [Waiter] = []

    func bump() {
        revision += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            let continuation = waiter.continuation
            waiter.continuation = nil
            continuation?.resume(returning: revision)
        }
    }

    /// 等到修订号超过 `after`；到`timeout` 还没动静就回当前值。
    func revision(after: Int, timeout: TimeInterval) async -> Int {
        if revision > after { return revision }
        let waiter = Waiter()
        waiters.append(waiter)
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(waiter)
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            waiter.continuation = continuation
        }
        timer.cancel()
        return result
    }

    func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            let continuation = waiter.continuation
            waiter.continuation = nil
            continuation?.resume(returning: revision)
        }
    }

    private func expire(_ waiter: Waiter) {
        guard let continuation = waiter.continuation else { return }
        waiter.continuation = nil
        waiters.removeAll { $0 === waiter }
        continuation.resume(returning: revision)
    }
}

// MARK: - 一条连接

/// 一条来自遥控器的 TCP 连接。HTTP/1.1 keep-alive，一次处理一条请求——
/// 长轮询挂着的那条必须先答完再读下一条，否则应答顺序就错位了。
@MainActor
final class RemoteHTTPConnection {

    var onClose: ((RemoteHTTPConnection) -> Void)?

    private let connection: NWConnection
    private let serverName: String
    private let handler: (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private var buffer = Data()
    private var isHandling = false
    private var isClosed = false

    init(connection: NWConnection, serverName: String,
         handler: @escaping (RemoteHTTPRequest) async -> RemoteHTTPResponse) {
        self.connection = connection
        self.serverName = serverName
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drain()
                }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.receive()
            }
        }
    }

    private func drain() {
        guard !isHandling, !isClosed else { return }
        guard let (request, consumed) = RemoteHTTPRequest.parse(buffer) else { return }
        buffer.removeFirst(consumed)
        isHandling = true
        Task { [weak self] in
            guard let self else { return }
            let response = await self.handler(request)
            self.send(response)
        }
    }

    private func send(_ response: RemoteHTTPResponse) {
        guard !isClosed else { return }
        connection.send(content: response.serialized(serverName: serverName),
                        completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHandling = false
                self.drain()
            }
        })
    }
}

// MARK: - 客户端（配对时去连手机）

/// 只为配对存在的一发 HTTP GET。用 `NWConnection` 而不是`URLSession`：
/// `NWBrowser` 给的是 Bonjour 服务端点，直接拿它建连接就行，
/// 不用自己解析出 host / port 再拼 URL（链路本地地址还要带 `%en0` 这类作用域）。
@MainActor
enum RemoteHTTPClient {

    enum ClientError: Error { case timeout, failed, malformed }

    static func get(_ endpoint: NWEndpoint, path: String,
                    timeout: TimeInterval = 10) async throws -> RemoteHTTPClientResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        // 这一发请求的全部保证都在末尾那句 `connection.start(queue: .main)` 上：
        // NWConnection 的 handler 一律投递到主队列，所以这两个可变量和下面两个局部函数
        // 自始至终只在主线程上被碰。但 Network 那几个 handler 的类型是 `@Sendable`，
        // 编译器只能按「可能并发」算，于是这里手工担保一次——与本文件那 8 处
        // `MainActor.assumeIsolated` 靠的是同一条事实。
        nonisolated(unsafe) var buffer = Data()
        nonisolated(unsafe) var finished = false

        return try await withCheckedThrowingContinuation { continuation in
            // 标 `@Sendable` 而不是 `@MainActor`：两者不能并存（主 actor 上的同步局部函数
            // 不许是 `@Sendable`），而这两个函数要被上面说的那些 handler 捕获。
            // 它们实际仍然只在主线程上跑：每个调用点不是裹在 `assumeIsolated` 里，
            // 就是在继承了主 actor 的 `Task` 里。
            // 下面每一次碰 `buffer` / `finished` 都要标 `unsafe`：它们是
            // `nonisolated(unsafe)`，「谁保证它安全」就写在上面那段——全部只在主线程上被碰。
            // 标记逐处出现是对的，这两个变量正是本文件唯一靠人担保、编译器管不了的地方。
            @Sendable func finish(_ result: Result<RemoteHTTPClientResponse, any Error>) {
                guard unsafe !finished else { return }
                unsafe finished = true
                connection.cancel()
                continuation.resume(with: result)
            }

            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, isComplete, error in
                    MainActor.assumeIsolated {
                        if let data { unsafe buffer.append(data) }
                        if let response = unsafe RemoteHTTPClientResponse.parse(buffer),
                           response.headers["content-length"] != nil {
                            finish(.success(response))
                            return
                        }
                        if isComplete {
                            // 没给 Content-Length 的，收到 EOF 再解一次
                            if let response = unsafe RemoteHTTPClientResponse.parse(buffer) {
                                finish(.success(response))
                            } else {
                                finish(.failure(ClientError.malformed))
                            }
                            return
                        }
                        if error != nil {
                            finish(.failure(ClientError.failed))
                            return
                        }
                        read()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        let request = "GET \(path) HTTP/1.1\r\nHost: remote\r\n"
                            + "User-Agent: \(RemoteControlServer.serverIdentification)\r\n"
                            + "Connection: close\r\n\r\n"
                        connection.send(content: Data(request.utf8),
                                        completion: .contentProcessed { _ in })
                        read()
                    case .failed, .cancelled:
                        finish(.failure(ClientError.failed))
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(.failure(ClientError.timeout))
            }
        }
    }
}
