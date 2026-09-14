import Foundation

// MARK: - 请求

/// 一条 HTTP/1.1 请求。手写解析：遥控 App 只发 GET（少数实现会发 POST 且无体），
/// 请求都很短，为这点流量拉一整套 HTTP 栈不值当。
struct RemoteHTTPRequest: Equatable {
    let method: String
    /// 不含查询串的路径，如 `/ctrl-int/1/playstatusupdate`
    let path: String
    let query: [String: String]
    /// 键一律小写
    let headers: [String: String]
    let body: Data

    /// 从缓冲区里切出**一条完整**请求。数据还不够就回 `nil`（继续收）。
    /// 返回值里的 `consumed` 是这条请求吃掉的字节数，调用方据此推进缓冲区。
    static func parse(_ buffer: Data) -> (request: RemoteHTTPRequest, consumed: Int)? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // CRLF CRLF
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            return nil  // 体还没收全
        }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])

        let (path, query) = splitTarget(target)
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        return (RemoteHTTPRequest(method: method, path: path, query: query,
                                  headers: headers, body: body), consumed)
    }

    /// 拆 `/a/b?x=1&y=2`。DACP 的查询串里有 `'`、`[`、`]`、`:`、`*` 这些字面量
    /// （比如 `query=('dmap.itemname:*abc*')`），所以不能拿 `URLComponents` 去啃——
    /// 它会因为非法字符整条返回 nil。`+` **不当空格**（DACP 不用表单编码）。
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else {
            return (target.removingPercentEncoding ?? target, [:])
        }
        let path = String(target[target.startIndex..<mark])
        let rest = String(target[target.index(after: mark)...])
        var query: [String: String] = [:]
        for pair in rest.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0])
            let raw = kv.count > 1 ? String(kv[1]) : ""
            query[key.removingPercentEncoding ?? key] = raw.removingPercentEncoding ?? raw
        }
        return (path.removingPercentEncoding ?? path, query)
    }

    func int(_ key: String) -> Int? {
        guard let raw = query[key] else { return nil }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return Int(raw.dropFirst(2), radix: 16)
        }
        return Int(raw)
    }
}

// MARK: - 应答

struct RemoteHTTPResponse {
    var status = 200
    var reason = "OK"
    var headers: [String: String] = [:]
    var body = Data()

    /// DMAP 应答。遥控 App 认的是 `application/x-dmap-tagged`。
    static func dmap(_ node: DMAPNode) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: 200, reason: "OK",
                           headers: ["Content-Type": "application/x-dmap-tagged"],
                           body: node.encoded)
    }

    /// 控制类命令（playpause / nextitem / setproperty…）的应答。
    /// [推] 苹果实现回什么没抓过包；这里跟随公开实现回 204 空体。
    static let noContent = RemoteHTTPResponse(status: 204, reason: "No Content")

    static func error(_ status: Int, _ reason: String) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: status, reason: reason)
    }

    static func image(_ data: Data, type: String) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: 200, reason: "OK",
                           headers: ["Content-Type": type], body: data)
    }

    /// 序列化成可直接写进 socket 的字节。
    func serialized(serverName: String) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["DAAP-Server"] = serverName
        all["Date"] = RemoteHTTPResponse.rfc1123.string(from: Date())
        // 长轮询要求连接一直留着，别回 close
        all["Connection"] = "keep-alive"
        for key in all.keys.sorted() {
            text += "\(key): \(all[key]!)\r\n"
        }
        text += "\r\n"
        var out = Data(text.utf8)
        out.append(body)
        return out
    }

    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}

/// 客户端侧解析出来的一条应答（配对时读手机的回信用）。
struct RemoteHTTPClientResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    /// 头收全了就能解出 status 与 Content-Length；体不够返回 nil。
    static func parse(_ buffer: Data) -> RemoteHTTPClientResponse? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = buffer.range(of: separator),
              let headerText = String(data: buffer[buffer.startIndex..<headerRange.lowerBound],
                                      encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()]
                = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if let length = headers["content-length"].flatMap(Int.init) {
            guard available >= length else { return nil }
            return RemoteHTTPClientResponse(
                status: status, headers: headers,
                body: Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]))
        }
        // 没给 Content-Length 的只能等对方关连接，交由调用方在 EOF 时再解一次
        return RemoteHTTPClientResponse(status: status, headers: headers,
                                        body: Data(buffer[bodyStart...]))
    }
}
