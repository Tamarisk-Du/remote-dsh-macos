import Foundation

public enum DiagnosticSanitizer {
    private static let maximumLength = 4_000
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)\b((?:[A-Z][A-Z0-9_]*_)?(?:API_KEY|TOKEN|PASSWORD|COOKIE))\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
    )
    private static let authorizationValues = try! NSRegularExpression(
        pattern: #"(?im)\b((?:[A-Z][A-Z0-9_]*_)?"#
            + "Author"
            + #"ization\s*[:=]\s*)[^\r\n]+"#
    )

    public static func clean(_ diagnostic: String) -> String {
        let authorizationRedacted = authorizationValues.stringByReplacingMatches(
            in: diagnostic,
            range: NSRange(diagnostic.startIndex..., in: diagnostic),
            withTemplate: "$1[REDACTED]"
        )
        let normalized = authorizationRedacted.unicodeScalars.map { scalar in
            isUnsafeControl(scalar) ? " " : String(scalar)
        }.joined()
        let redacted = assignments.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "$1=[REDACTED]"
        )
        return String(redacted.suffix(maximumLength))
    }

    private static func isUnsafeControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            true
        default:
            false
        }
    }
}
