import Foundation

/// 按主机名返回预设状态码和响应体的假 `URLProtocol`，并记下收到的请求（含请求体）。
///
/// 每个测试用 `register(statusCode:body:)` 拿到一个独有的主机地址，测试并行执行时互不干扰；
/// 只通过 `makeSession()` 创建的会话生效，不要用 `URLProtocol.registerClass` 全局注册（测试宿主就是 App 本身）。
/// 静态状态用锁保护，请求在 URLSession 的内部队列上回调，不属于主 actor。
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// 一个主机地址对应的预设响应。
    private struct Stub {
        /// HTTP 状态码。
        let statusCode: Int
        /// 响应体；为空时不回传数据（如 204）。
        let body: Data
    }

    /// 保护静态状态的锁。
    private static let lock = NSLock()
    /// 主机名 → 预设响应。
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    /// 主机名 → 收到的请求，按到达顺序排列。
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    /// 登记一个预设响应，返回只对应它的服务地址（不含路径）。
    ///
    /// - Parameters:
    ///   - statusCode: 返回的 HTTP 状态码。
    ///   - body: 返回的响应体。
    static func register(statusCode: Int, body: Data = Data()) -> URL {
        let host = "\(UUID().uuidString.lowercased()).stub.invalid"
        lock.withLock { stubs[host] = Stub(statusCode: statusCode, body: body) }
        guard let url = URL(string: "https://\(host)") else {
            preconditionFailure("测试地址不合法：\(host)")
        }
        return url
    }

    /// 发到指定服务地址的请求；请求体已从流里读出，放在 `httpBody`。
    ///
    /// - Parameter endpoint: `register` 返回的地址。
    static func recordedRequests(for endpoint: URL) -> [URLRequest] {
        lock.withLock { requests[endpoint.host() ?? ""] ?? [] }
    }

    /// 创建只走本协议的临时会话，不会碰到真实网络。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // URLSession 会把 httpBody 转成流，记录前读回来，方便断言
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.readAll(stream)
        }
        let host = request.url?.host() ?? ""
        let stub = Self.lock.withLock { () -> Stub? in
            Self.requests[host, default: []].append(recorded)
            return Self.stubs[host]
        }
        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// 把请求体流整个读出来。
    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
