import Foundation

/// 记录所有经过它的请求的假 `URLProtocol`，用来证明某段代码「一个请求都没发」。
///
/// 只通过 `makeSession()` 创建的会话生效；不要用 `URLProtocol.registerClass` 全局注册：
/// 测试宿主就是 App 本身，全局注册会把宿主自己的请求也记进来。
/// 静态状态用锁保护，请求在 URLSession 的内部队列上回调，不属于主 actor。
nonisolated final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    /// 保护静态状态的锁。
    private static let lock = NSLock()
    /// 已记录的请求，按到达顺序排列。
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    /// 返回给调用方的响应体。
    nonisolated(unsafe) private static var body = Data(#"{"products":[]}"#.utf8)

    /// 到目前为止记录下的请求。
    static var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    /// 返回给调用方的响应体，默认是空目录 `{"products":[]}`。
    static var responseBody: Data {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }

    /// 清空已记录的请求，并把响应体恢复为默认值。
    static func reset() {
        lock.withLock {
            requests = []
            body = Data(#"{"products":[]}"#.utf8)
        }
    }

    /// 创建只走本协议的临时会话，不会碰到真实网络。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let url = request.url ?? URL(string: "https://invalid.example")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
