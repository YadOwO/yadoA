import Foundation

enum AccountAmountParser {
    static func amount(from text: String, locale: Locale = .current) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.first != "-" else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let parts = value.components(separatedBy: decimalSeparator)
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isWholeNumber) })
        else { return nil }

        let canonicalValue = decimalSeparator == "."
            ? value
            : value.replacingOccurrences(of: decimalSeparator, with: ".")

        return Decimal(
            string: canonicalValue,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
