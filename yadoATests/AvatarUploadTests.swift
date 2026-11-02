import Foundation
import Testing
import UIKit
@testable import yadoA

@Suite("头像上传")
struct AvatarUploadTests {
    /// 固定的签名时间：2026-10-16 08:00:00 UTC。
    private let signingDate = ISO8601DateFormatter().date(from: "2026-10-16T08:00:00Z")!

    private let signer = OSSRequestSigner(
        credentials: OSSCredentials(accessKeyID: "LTAI_TEST", accessKeySecret: "secret_test"),
        region: "cn-guangzhou"
    )

    @Test("对象路径为 应用前缀/用户 ID/随机 ID.jpg，公开地址走头像访问域名")
    func objectKeyFollowsPathRule() {
        let fileID = UUID(uuidString: "5F0E2A1C-1111-2222-3333-444455556666")!
        let key = AvatarUploadConfig.objectKey(userID: "user1", fileID: fileID)

        #expect(key == "yadoA/user1/5f0e2a1c-1111-2222-3333-444455556666.jpg")
        #expect(
            AvatarUploadConfig.publicURL(forObjectKey: key).absoluteString
                == "https://avatar.yado1225.top/yadoA/user1/5f0e2a1c-1111-2222-3333-444455556666.jpg"
        )
        #expect(AvatarUploadConfig.objectKey(userID: "user1") != AvatarUploadConfig.objectKey(userID: "user1"))
    }

    @Test("规范请求按 V4 格式拼接：请求头排序小写，后跟空的附加头列表与 UNSIGNED-PAYLOAD")
    func canonicalRequestFormat() {
        let canonical = OSSRequestSigner.canonicalRequest(
            method: "PUT",
            canonicalURI: "/yado-avatars/yadoA/user1/a.jpg",
            headers: ["x-oss-date": "20261016T080000Z", "content-type": "image/jpeg"]
        )
        #expect(
            canonical == """
            PUT
            /yado-avatars/yadoA/user1/a.jpg

            content-type:image/jpeg
            x-oss-date:20261016T080000Z


            UNSIGNED-PAYLOAD
            """
        )
    }

    @Test("签名结果与参考实现一致")
    func authorizationMatchesReferenceVector() {
        let authorization = signer.authorizationHeader(
            method: "PUT",
            canonicalURI: "/yado-avatars/yadoA/user1/a.jpg",
            headers: [
                "content-type": "image/jpeg",
                "x-oss-content-sha256": "UNSIGNED-PAYLOAD",
                "x-oss-date": "20261016T080000Z",
                "x-oss-forbid-overwrite": "true",
            ],
            date: signingDate
        )
        #expect(
            authorization == "OSS4-HMAC-SHA256 Credential=LTAI_TEST/20261016/cn-guangzhou/oss/aliyun_v4_request,"
                + "Signature=c3f412bf43c260e5ae90dbbd13aab593f5702cdfab15deb91a9d022be5c55865"
        )
    }

    @Test("上传请求使用虚拟主机域名，带齐签名所需的请求头")
    func signedPutRequestHeaders() {
        let request = signer.signedPutRequest(
            host: AvatarUploadConfig.uploadHost,
            bucket: AvatarUploadConfig.bucket,
            objectKey: "yadoA/user1/a.jpg",
            contentType: "image/jpeg",
            body: Data([0xFF, 0xD8]),
            date: signingDate
        )

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://yado-avatars.oss-cn-guangzhou.aliyuncs.com/yadoA/user1/a.jpg")
        #expect(request.value(forHTTPHeaderField: "x-oss-date") == "20261016T080000Z")
        #expect(request.value(forHTTPHeaderField: "x-oss-content-sha256") == "UNSIGNED-PAYLOAD")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(request.value(forHTTPHeaderField: "x-oss-security-token") == nil)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
                "c3f412bf43c260e5ae90dbbd13aab593f5702cdfab15deb91a9d022be5c55865"
            ) == true
        )
    }

    @Test("STS 凭证会附带安全令牌请求头")
    func securityTokenIsSentForSTSCredentials() {
        let stsSigner = OSSRequestSigner(
            credentials: OSSCredentials(accessKeyID: "STS.id", accessKeySecret: "secret", securityToken: "token"),
            region: "cn-guangzhou"
        )
        let request = stsSigner.signedPutRequest(
            host: AvatarUploadConfig.uploadHost,
            bucket: AvatarUploadConfig.bucket,
            objectKey: "yadoA/user1/a.jpg",
            contentType: "image/jpeg",
            body: Data(),
            date: signingDate
        )
        #expect(request.value(forHTTPHeaderField: "x-oss-security-token") == "token")
    }

    @Test("URI 编码保留非保留字符，路径中可保留斜杠")
    func uriEncoding() {
        #expect(OSSRequestSigner.uriEncode("yadoA/a b+c~.jpg", keepingSlash: true) == "yadoA/a%20b%2Bc~.jpg")
        #expect(OSSRequestSigner.uriEncode("a/b", keepingSlash: false) == "a%2Fb")
    }

    @Test("从 OSS 的 XML 错误响应中解析错误码")
    func parsesOSSErrorCode() {
        let xml = "<?xml version=\"1.0\"?><Error><Code>AccessDenied</Code><Message>x</Message></Error>"
        #expect(AvatarUploader.ossErrorCode(in: Data(xml.utf8)) == "AccessDenied")
        #expect(AvatarUploader.ossErrorCode(in: Data("oops".utf8)) == nil)
    }

    @Test("头像图片居中裁成正方形，并限制最大边长")
    func imageProcessorCropsToSquare() throws {
        let wide = makeImage(size: CGSize(width: 1600, height: 900))
        let wideOutput = try #require(UIImage(data: try AvatarImageProcessor.process(wide)))
        #expect(wideOutput.size.width == AvatarImageProcessor.outputSide)
        #expect(wideOutput.size.height == AvatarImageProcessor.outputSide)

        // 小图不放大，只裁成正方形
        let small = makeImage(size: CGSize(width: 300, height: 200))
        let smallOutput = try #require(UIImage(data: try AvatarImageProcessor.process(small)))
        #expect(smallOutput.size == CGSize(width: 200, height: 200))
    }

    @Test("无法解析的数据视为无效图片")
    func invalidImageDataThrows() {
        #expect(throws: AvatarUploadError.invalidImage) {
            try AvatarImageProcessor.process(Data("not an image".utf8))
        }
    }

    @Test("每种头像错误都有中英文文案")
    func avatarErrorsAreLocalized() {
        let errors: [AvatarUploadError] = [
            .notConfigured, .invalidImage, .notSignedIn, .network, .rejected(status: 403, code: "AccessDenied"),
        ]
        for error in errors {
            for identifier in ["en", "zh-Hans"] {
                #expect(
                    AccountLocalization.string(error.localizationKey, locale: Locale(identifier: identifier))
                        != error.localizationKey
                )
            }
        }
    }

    /// 生成指定像素尺寸的纯色测试图片。
    private func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
