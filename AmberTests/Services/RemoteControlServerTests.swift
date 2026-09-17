import Combine
import XCTest
@testable import Amber

/// 一个假的被控端，只记下「谁被叫了」。
@MainActor
private final class FakeRemoteTarget: RemoteControlTarget {

    var state = RemotePlayState()
    private(set) var calls: [String] = []
    private let subject = PassthroughSubject<Void, Never>()

    func remotePlay() { calls.append("play") }
    func remotePause() { calls.append("pause") }
    func remoteTogglePlayPause() { calls.append("playpause") }
    func remoteNext() { calls.append("next") }
    func remotePrevious() { calls.append("previous") }
    func remoteSeek(toMilliseconds ms: Int) { calls.append("seek:\(ms)") }

    var remoteVolume: Int {
        get { state.volume }
        set { state.volume = newValue; calls.append("volume:\(newValue)") }
    }

    func remoteSetShuffle(_ on: Bool) { calls.append("shuffle:\(on)") }
    func remoteSetRepeat(_ state: Int) { calls.append("repeat:\(state)") }
    func snapshot() -> RemotePlayState { state }
    var remoteChanges: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
}

/// DACP 路由：登录鉴权、播放状态容器、控制命令的分发。
/// **不起监听器**——测试里只调 `handle(_:)` 这条纯路由，不占端口、不碰 Bonjour。
@MainActor
final class RemoteControlServerTests: XCTestCase {

    private var target: FakeRemoteTarget!
    private var pairings: RemotePairingStore!
    private var server: RemoteControlServer!

    private static let guid = "00ABCDEF00000001"

    override func setUp() async throws {
        target = FakeRemoteTarget()
        pairings = RemotePairingStore(storage: MemoryPairingStorage())
        server = RemoteControlServer(target: target, pairingStore: pairings,
                                     libraryID: "0102030405060708", displayName: "Amber 测试")
    }

    private func request(_ target: String) -> RemoteHTTPRequest {
        let raw = Data("GET \(target) HTTP/1.1\r\n\r\n".utf8)
        return RemoteHTTPRequest.parse(raw)!.request
    }

    private func body(_ response: RemoteHTTPResponse) -> [DMAPRawNode] {
        DMAPDecoder.parse(response.body)
    }

    // MARK: /server-info

    func testServerInfoAnnouncesLoginRequired() async {
        let response = await server.handle(request("/server-info"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/x-dmap-tagged")
        let root = body(response).first
        XCTAssertEqual(root?.code, "msrv")
        XCTAssertEqual(root?.child("mstt")?.uintValue, 200)
        XCTAssertEqual(root?.child("minm")?.stringValue, "Amber 测试")
        XCTAssertEqual(root?.child("mslr")?.uintValue, 1)
        XCTAssertEqual(root?.child("msdc")?.uintValue, 1)
    }

    // MARK: /login

    func testLoginRejectsUnknownGuid() async {
        let response = await server.handle(request("/login?pairing-guid=0x1234567890ABCDEF"))
        XCTAssertEqual(response.status, 503)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testLoginWithoutGuidIsRejected() async {
        let response = await server.handle(request("/login"))
        XCTAssertEqual(response.status, 503)
    }

    func testLoginAcceptsPairedGuidAndIssuesSession() async {
        pairings.add(PairedRemote(guid: Self.guid, name: "iPhone",
                                  deviceType: "iPhone", pairedAt: Date()))
        let response = await server.handle(request("/login?pairing-guid=0x\(Self.guid.lowercased())"))
        XCTAssertEqual(response.status, 200)
        let root = body(response).first
        XCTAssertEqual(root?.code, "mlog")
        XCTAssertEqual(root?.child("mstt")?.uintValue, 200)
        let session = root?.child("mlid")?.uintValue ?? 0
        XCTAssertGreaterThan(session, 0)

        // 拿到的会话号立刻能用
        let status = await server.handle(
            request("/ctrl-int/1/playstatusupdate?session-id=\(session)&revision-number=1"))
        XCTAssertEqual(status.status, 200)
    }

    func testControlRequiresValidSession() async {
        let response = await server.handle(request("/ctrl-int/1/playpause?session-id=999"))
        XCTAssertEqual(response.status, 503)
        XCTAssertTrue(target.calls.isEmpty)
    }

    func testLogoutInvalidatesSession() async {
        server.installSessionForTesting(42)
        _ = await server.handle(request("/logout?session-id=42"))
        let after = await server.handle(request("/ctrl-int/1/playpause?session-id=42"))
        XCTAssertEqual(after.status, 503)
    }

    // MARK: 播放状态

    func testPlayStatusWithoutTrackReportsStopped() async {
        server.installSessionForTesting(1)
        let response = await server.handle(
            request("/ctrl-int/1/playstatusupdate?session-id=1&revision-number=1"))
        let root = body(response).first
        XCTAssertEqual(root?.code, "cmst")
        XCTAssertEqual(root?.child("caps")?.uintValue, 2)      // 停
        XCTAssertNil(root?.child("cann"))                       // 没歌就不报曲名
        XCTAssertEqual(root?.child("cavc")?.uintValue, 1)      // 音量可控
    }

    func testPlayStatusCarriesTrackFields() async {
        target.state = RemotePlayState(hasTrack: true, isPlaying: true, title: "傻鱼",
                                       artist: "告五人", album: "运气来得若有似无",
                                       genre: "", elapsedMs: 30_000, totalMs: 210_000,
                                       volume: 80, shuffle: true, repeatState: 2,
                                       trackKey: 0xDEAD_BEEF, albumKey: 7,
                                       artworkURL: nil)
        server.installSessionForTesting(1)
        let response = await server.handle(
            request("/ctrl-int/1/playstatusupdate?session-id=1&revision-number=1"))
        let root = body(response).first
        XCTAssertEqual(root?.child("caps")?.uintValue, 4)      // 播放中
        XCTAssertEqual(root?.child("cash")?.uintValue, 1)
        XCTAssertEqual(root?.child("carp")?.uintValue, 2)
        XCTAssertEqual(root?.child("cann")?.stringValue, "傻鱼")
        XCTAssertEqual(root?.child("cana")?.stringValue, "告五人")
        XCTAssertEqual(root?.child("canl")?.stringValue, "运气来得若有似无")
        XCTAssertEqual(root?.child("cast")?.uintValue, 210_000)
        // cant 是**剩余**毫秒，不是已播的
        XCTAssertEqual(root?.child("cant")?.uintValue, 180_000)
        XCTAssertEqual(root?.child("asai")?.uintValue, 7)
        // canp = 四个 u32，后两个是曲目 id
        XCTAssertEqual(root?.child("canp")?.payload.count, 16)
        XCTAssertEqual(root?.child("canp")?.payload.suffix(4), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testPausedReportsThree() async {
        target.state.hasTrack = true
        target.state.isPlaying = false
        server.installSessionForTesting(1)
        let response = await server.handle(
            request("/ctrl-int/1/playstatusupdate?session-id=1&revision-number=1"))
        XCTAssertEqual(body(response).first?.child("caps")?.uintValue, 3)
    }

    // MARK: 控制命令

    func testTransportCommandsDispatch() async {
        server.installSessionForTesting(1)
        for (path, expected) in [("playpause", "playpause"), ("play", "play"),
                                 ("pause", "pause"), ("stop", "pause"),
                                 ("nextitem", "next"), ("previtem", "previous")] {
            let response = await server.handle(request("/ctrl-int/1/\(path)?session-id=1"))
            XCTAssertEqual(response.status, 204, path)
            XCTAssertEqual(target.calls.last, expected, path)
        }
    }

    func testSetPropertyMapsEveryKnob() async {
        server.installSessionForTesting(1)
        _ = await server.handle(request("/ctrl-int/1/setproperty?dmcp.volume=64&session-id=1"))
        _ = await server.handle(request("/ctrl-int/1/setproperty?dacp.playingtime=42000&session-id=1"))
        _ = await server.handle(request("/ctrl-int/1/setproperty?dacp.shufflestate=1&session-id=1"))
        _ = await server.handle(request("/ctrl-int/1/setproperty?dacp.repeatstate=1&session-id=1"))
        XCTAssertEqual(target.calls, ["volume:64", "seek:42000", "shuffle:true", "repeat:1"])
    }

    func testVolumeIsClampedToDacpRange() async {
        server.installSessionForTesting(1)
        _ = await server.handle(request("/ctrl-int/1/setproperty?dmcp.volume=500&session-id=1"))
        XCTAssertEqual(target.calls.last, "volume:100")
    }

    func testGetPropertyReportsVolume() async {
        target.state.volume = 37
        server.installSessionForTesting(1)
        let response = await server.handle(
            request("/ctrl-int/1/getproperty?properties=dmcp.volume&session-id=1"))
        let root = body(response).first
        XCTAssertEqual(root?.code, "cmgt")
        XCTAssertEqual(root?.child("cmvo")?.uintValue, 37)
    }

    // MARK: 资料库（本轮只保证「不报错」）

    func testDatabasesReportsOneLibrary() async {
        server.installSessionForTesting(1)
        let response = await server.handle(request("/databases?session-id=1"))
        let root = body(response).first
        XCTAssertEqual(root?.code, "avdb")
        XCTAssertEqual(root?.child("mrco")?.uintValue, 1)
        XCTAssertEqual(root?.find("minm")?.stringValue, "Amber 测试")
    }

    func testItemsReturnEmptyButValidListing() async {
        server.installSessionForTesting(1)
        let response = await server.handle(
            request("/databases/1/containers/1/items?session-id=1&meta=dmap.itemid"))
        XCTAssertEqual(response.status, 200)
        let root = body(response).first
        XCTAssertEqual(root?.code, "adbs")
        XCTAssertEqual(root?.child("mstt")?.uintValue, 200)
        XCTAssertEqual(root?.child("mrco")?.uintValue, 0)
        XCTAssertEqual(root?.child("mlcl")?.children.count, 0)
    }

    func testUnknownPathIs404() async {
        let response = await server.handle(request("/nope"))
        XCTAssertEqual(response.status, 404)
    }

    // MARK: 修订号

    func testFirstPollReturnsImmediately() async {
        let gate = RemoteRevisionGate()
        let revision = await gate.revision(after: 1, timeout: 5)
        XCTAssertEqual(revision, 2)
    }

    func testPollWakesOnBump() async {
        let gate = RemoteRevisionGate()
        Task { gate.bump() }
        let revision = await gate.revision(after: 2, timeout: 5)
        XCTAssertEqual(revision, 3)
    }

    func testPollGivesUpAtTimeout() async {
        let gate = RemoteRevisionGate()
        let revision = await gate.revision(after: 2, timeout: 0.05)
        XCTAssertEqual(revision, 2)
    }

    // MARK: 忽略所有遥控器

    func testForgetAllClearsPairingsAndSessions() async {
        pairings.add(PairedRemote(guid: Self.guid, name: "iPhone",
                                  deviceType: "iPhone", pairedAt: Date()))
        server = RemoteControlServer(target: target, pairingStore: pairings,
                                     libraryID: "0102030405060708", displayName: "Amber 测试")
        XCTAssertEqual(server.pairedDevices.count, 1)
        server.installSessionForTesting(7)

        server.forgetAll()
        XCTAssertTrue(server.pairedDevices.isEmpty)
        XCTAssertFalse(server.isListening)
        // 之前发出去的会话号立刻作废
        let control = await server.handle(request("/ctrl-int/1/playpause?session-id=7"))
        XCTAssertEqual(control.status, 503)
        // 再登录也不认了
        let login = await server.handle(request("/login?pairing-guid=0x\(Self.guid)"))
        XCTAssertEqual(login.status, 503)
    }
}
