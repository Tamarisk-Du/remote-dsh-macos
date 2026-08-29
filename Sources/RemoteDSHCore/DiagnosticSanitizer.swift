import Foundation

public enum DiagnosticSanitizer {
    private static let maximumLength = 4_000
    private static let assignments = try! NSRegularExpression(
        pattern: #"(?i)\b((?:[A-Z][A-Z0-9_]*_)?(?:API_KEY|TOKEN|PASSWORD|COOKIE|AUTHORIZATION))\s*[:=]\s*(?!Bearer\b)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#
    )
    private static let bearerTokens = try! NSRegularExpression(
        pattern: #"(?i)("# + "Author" + #"ization\s*:\s*Bearer\s+)[^\s,;]+"#
    )

    public static func clean(_ diagnostic: String) -> String {
        let normalized = diagnostic.unicodeScalars.map { scalar in
            isUnsafeControl(scalar) ? " " : String(scalar)
        }.joined()
        let bearerRedacted = bearerTokens.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "$1[REDACTED]"
        )
        let redacted = assignments.stringByReplacingMatches(
            in: bearerRedacted,
            range: NSRange(bearerRedacted.startIndex..., in: bearerRedacted),
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
