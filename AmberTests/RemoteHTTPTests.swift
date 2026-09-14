import XCTest
@testable import Amber

/// 手写的那点 HTTP。遥控器发的请求行里带 `0x` 十六进制、点号参数名与被百分号编码的中文，
/// 这几样是最容易在解析上栽的。
final class RemoteHTTPTests: XCTestCase {

    private func buffer(_ text: String) -> Data { Data(text.utf8) }

    func testParsesRequestLineAndHeaders() {
        let raw = "GET /ctrl-int/1/playpause?session-id=123 HTTP/1.1\r\n"
            + "Host: 192.168.1.10:3689\r\nViewer-Only-Client: 1\r\n\r\n"
        let parsed = RemoteHTTPRequest.parse(buffer(raw))
        XCTAssertEqual(parsed?.request.method, "GET")
        XCTAssertEqual(parsed?.request.path, "/ctrl-int/1/playpause")
        XCTAssertEqual(parsed?.request.query["session-id"], "123")
        XCTAssertEqual(parsed?.request.headers["viewer-only-client"], "1")
        XCTAssertEqual(parsed?.consumed, raw.utf8.count)
    }

    func testIncompleteHeaderReturnsNil() {
        XCTAssertNil(RemoteHTTPRequest.parse(buffer("GET /server-info HTTP/1.1\r\nHost: x\r\n")))
    }

    func testWaitsForBodyWhenContentLengthPresent() {
        let head = "POST /ctrl-int/1/cue HTTP/1.1\r\nContent-Length: 4\r\n\r\n"
        XCTAssertNil(RemoteHTTPRequest.parse(buffer(head + "ab")))
        let parsed = RemoteHTTPRequest.parse(buffer(head + "abcd"))
        XCTAssertEqual(parsed?.request.body, Data("abcd".utf8))
        XCTAssertEqual(parsed?.consumed, (head + "abcd").utf8.count)
    }

    /// keep-alive 上会连着来两条，一条一条切。
    func testParsesOneRequestAtATime() {
        let raw = "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n"
        var data = buffer(raw)
        guard let first = RemoteHTTPRequest.parse(data) else { return XCTFail("第一条没解出来") }
        XCTAssertEqual(first.request.path, "/a")
        data.removeFirst(first.consumed)
        XCTAssertEqual(RemoteHTTPRequest.parse(data)?.request.path, "/b")
    }

    /// DACP 的参数名带点号、值带 `0x`，还有 `query=('dmap.itemname:*x*')` 这种
    /// 会把 `URLComponents` 直接顶成 nil 的字面量。
    func testQueryKeepsDottedNamesAndLiterals() {
        let (path, query) = RemoteHTTPRequest.splitTarget(
            "/ctrl-int/1/setproperty?dmcp.volume=64&session-id=0x1F&query=('dmap.itemname:*a*')")
        XCTAssertEqual(path, "/ctrl-int/1/setproperty")
        XCTAssertEqual(query["dmcp.volume"], "64")
        XCTAssertEqual(query["session-id"], "0x1F")
        XCTAssertEqual(query["query"], "('dmap.itemname:*a*')")
    }

    func testIntReadsBothDecimalAndHex() {
        let raw = "GET /login?pairing-guid=0x00ABCDEF00000001&revision-number=12 HTTP/1.1\r\n\r\n"
        let request = RemoteHTTPRequest.parse(buffer(raw))!.request
        XCTAssertEqual(request.int("revision-number"), 12)
        XCTAssertEqual(request.int("pairing-guid"), 0x00AB_CDEF_0000_0001)
        // 原始串也要留着：guid 是按字符串比的，不能被转成数字丢掉前导零
        XCTAssertEqual(request.query["pairing-guid"], "0x00ABCDEF00000001")
    }

    func testPercentEncodedValueIsDecoded() {
        let (_, query) = RemoteHTTPRequest.splitTarget("/x?name=%E5%91%A8%E6%9D%B0%E4%BC%A6")
        XCTAssertEqual(query["name"], "周杰伦")
    }

    // MARK: 应答

    /// 只取报头那一段来读：体是二进制 DMAP，整份按 UTF-8 解会得到 nil。
    private func headerText(_ data: Data) -> String {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let end = data.range(of: separator)?.upperBound ?? data.endIndex
        return String(data: data[data.startIndex..<end], encoding: .utf8) ?? ""
    }

    func testDmapResponseCarriesTaggedContentType() {
        let response = RemoteHTTPResponse.dmap(.container("mlog", [.u32("mstt", 200)]))
        let text = headerText(response.serialized(serverName: "Amber/1.0"))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/x-dmap-tagged\r\n"))
        // mlog 自己 8 字节头 + 一个 12 字节的 mstt
        XCTAssertTrue(text.contains("Content-Length: 20\r\n"))
        // 长轮询要求连接留着
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
    }

    func testNoContentHasEmptyBody() {
        let text = headerText(RemoteHTTPResponse.noContent.serialized(serverName: "Amber/1.0"))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
    }

    // MARK: 客户端侧（读手机的回信）

    func testClientResponseParsesBodyByContentLength() {
        let body = DMAPNode.container("cmpa", [.u64("cmpg", 1)]).encoded
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        raw.append(body)
        let response = RemoteHTTPClientResponse.parse(raw)
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(response?.body, body)
    }

    func testClientResponseWaitsForFullBody() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\nshort".utf8)
        XCTAssertNil(RemoteHTTPClientResponse.parse(raw))
    }
}
