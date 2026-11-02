import Foundation
import Testing
@testable import yadoA

@Suite("登录账号资料")
struct AccountProfileTests {
    @Test("用户名规则与 Logto 一致：字母或下划线开头，只含字母、数字和下划线")
    func usernameValidationMatchesLogto() {
        #expect(AccountProfile.isValidUsername("yado"))
        #expect(AccountProfile.isValidUsername("_yado_1225"))
        #expect(AccountProfile.isValidUsername("Yado2"))

        #expect(!AccountProfile.isValidUsername(""))
        #expect(!AccountProfile.isValidUsername("1yado"))
        #expect(!AccountProfile.isValidUsername("yado.async"))
        #expect(!AccountProfile.isValidUsername("yado async"))
        #expect(!AccountProfile.isValidUsername("芽豆"))
        #expect(!AccountProfile.isValidUsername(String(repeating: "a", count: AccountProfile.usernameMaxLength + 1)))
    }

    @Test("展示名称优先昵称，昵称为空白时回退到用户名")
    func displayNamePrefersName() {
        #expect(AccountProfile(name: "芽豆", username: "yado").displayName == "芽豆")
        #expect(AccountProfile(name: "  ", username: "yado").displayName == "yado")
        #expect(AccountProfile(name: nil, username: nil).displayName == nil)
    }

    @Test("Logto 错误码归类为界面可展示的错误")
    func logtoErrorCodesMapToProfileErrors() {
        #expect(AccountProfileError.from(logtoCode: "user.username_already_in_use") == .usernameTaken)
        #expect(AccountProfileError.from(logtoCode: "user.username_too_long") == .invalidUsername)
        #expect(AccountProfileError.from(logtoCode: "guard.invalid_input") == .invalidUsername)
        #expect(AccountProfileError.from(logtoCode: "session.invalid_credentials") == .wrongPassword)
        #expect(
            AccountProfileError.from(logtoCode: "session.verification_blocked_too_many_attempts") == .tooManyAttempts
        )
        #expect(AccountProfileError.from(logtoCode: "account_center.field_not_editable") == .notAllowed)
        #expect(AccountProfileError.from(logtoCode: "http.500") == .unknown("http.500"))
    }

    @Test("每种错误都有中英文文案")
    func profileErrorsAreLocalized() {
        let errors: [AccountProfileError] = [
            .usernameTaken, .invalidUsername, .wrongPassword, .tooManyAttempts, .notAllowed, .network, .unknown(nil),
        ]
        for error in errors {
            #expect(AccountLocalization.string(error.localizationKey, locale: Locale(identifier: "en")) != error.localizationKey)
            #expect(
                AccountLocalization.string(error.localizationKey, locale: Locale(identifier: "zh-Hans"))
                    != error.localizationKey
            )
        }
    }

    @Test("只读用户名的占位与说明都有中英文文案")
    func readonlyUsernameTextsAreLocalized() {
        let keys = ["profile.edit.username.unset", "profile.edit.username.readonly_hint", "profile.edit.footnote"]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "en")) != key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "zh-Hans")) != key)
        }
    }
}
