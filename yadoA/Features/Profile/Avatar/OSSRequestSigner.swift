import CryptoKit
import Foundation

/// 阿里云 OSS V4 签名（`OSS4-HMAC-SHA256`）的最小实现，只覆盖头像上传用到的单次 PutObject。
///
/// 不引入 OSS SDK，直接用 URLSession 发请求；请求体不参与签名（`UNSIGNED-PAYLOAD`），
/// 由 HTTPS 保证传输完整性。算法见阿里云文档“在 Header 中包含 V4 签名”。
struct OSSRequestSigner {
    /// 签名算法标识。
    static let algorithm = "OSS4-HMAC-SHA256"
    /// 请求体不参与签名时的固定哈希值。
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// 签名所用凭证。
    let credentials: OSSCredentials
    /// 存储桶所在地域，如 `cn-guangzhou`。
    let region: String

    /// 生成上传单个对象的已签名请求。
    ///
    /// - Parameters:
    ///   - host: 虚拟主机风格的桶域名，如 `yado-avatars.oss-cn-guangzhou.aliyuncs.com`。
    ///   - bucket: 存储桶名称。
    ///   - objectKey: 对象路径，不以 `/` 开头。
    ///   - contentType: 对象的 MIME 类型。
    ///   - body: 对象内容。
    ///   - date: 签名时间，默认当前时间；测试时可固定。
    /// - Returns: 带 `Authorization` 等请求头、可直接发送的 PUT 请求。
    func signedPutRequest(
        host: String,
        bucket: String,
        objectKey: String,
        contentType: String,
        body: Data,
        date: Date = Date()
    ) -> URLRequest {
        let encodedKey = Self.uriEncode(objectKey, keepingSlash: true)
        var request = URLRequest(url: URL(string: "https://\(host)/\(encodedKey)")!)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.timeoutInterval = 30

        // 参与签名的请求头，键统一小写
        var headers: [String: String] = [
            "content-type": contentType,
            "x-oss-content-sha256": Self.unsignedPayload,
            "x-oss-date": Self.timestamp(date),
            // 文件名每次随机，正常不会重名；禁止覆盖进一步避免误写别人的同名对象
            "x-oss-forbid-overwrite": "true",
        ]
        if let token = credentials.securityToken {
            headers["x-oss-security-token"] = token
        }

        let authorization = authorizationHeader(
            method: "PUT",
            canonicalURI: "/\(bucket)/\(encodedKey)",
            headers: headers,
            date: date
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    /// 计算 `Authorization` 请求头的值。
    ///
    /// - Parameters:
    ///   - method: HTTP 方法。
    ///   - canonicalURI: `/{bucket}/{已编码的对象路径}`。
    ///   - headers: 参与签名的请求头，键必须为小写。
    ///   - date: 签名时间，必须与 `x-oss-date` 一致。
    func authorizationHeader(method: String, canonicalURI: String, headers: [String: String], date: Date) -> String {
        let day = Self.day(date)
        let scope = "\(day)/\(region)/oss/aliyun_v4_request"

        let stringToSign = [
            Self.algorithm,
            Self.timestamp(date),
            scope,
            Self.sha256Hex(Self.canonicalRequest(method: method, canonicalURI: canonicalURI, headers: headers)),
        ].joined(separator: "\n")

        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(day: day)))
        return "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(scope),Signature=\(signature)"
    }

    /// 规范请求：方法、URI、查询串（为空）、规范请求头、附加头列表（为空）与请求体哈希，以换行连接。
    ///
    /// 规范请求头每行以换行结尾，因此与后面的附加头列表之间会出现一个空行，这是协议要求的格式。
    static func canonicalRequest(method: String, canonicalURI: String, headers: [String: String]) -> String {
        let canonicalHeaders = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        return [method, canonicalURI, "", canonicalHeaders, "", unsignedPayload].joined(separator: "\n")
    }

    /// 按 RFC 3986 编码：保留字母、数字与 `-_.~`，路径中可选择保留 `/`。
    static func uriEncode(_ value: String, keepingSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepingSlash {
            allowed.insert("/")
        }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 私有方法

    /// 逐级派生签名密钥：`aliyun_v4{Secret}` → 日期 → 地域 → `oss` → `aliyun_v4_request`。
    private func signingKey(day: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("aliyun_v4\(credentials.accessKeySecret)".utf8))
        for component in [day, region, "oss", "aliyun_v4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)))
        }
        return key
    }

    /// UTC 时间戳，格式 `yyyyMMdd'T'HHmmss'Z'`。
    private static func timestamp(_ date: Date) -> String {
        utcFormatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
    }

    /// UTC 日期，格式 `yyyyMMdd`。
    private static func day(_ date: Date) -> String {
        utcFormatter("yyyyMMdd").string(from: date)
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static func sha256Hex(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
