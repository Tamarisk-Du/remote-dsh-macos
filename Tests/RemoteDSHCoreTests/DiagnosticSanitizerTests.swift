import RemoteDSHCore
import Testing

@Suite("DiagnosticSanitizerTests")
struct DiagnosticSanitizerTests {
    @Test("prefixed authorization assignments are fully redacted")
    func prefixedAuthorizationAssignmentIsRedacted() {
        let output = DiagnosticSanitizer.clean("SERVICE_AUTHORIZATION=omega")

        #expect(output == "SERVICE_AUTHORIZATION=[REDACTED]")
        #expect(output.contains("omega") == false)
    }

    @Test("authorization schemes and credentials are fully redacted")
    func authorizationSchemeAndCredentialAreRedacted() {
        let encodedCredential = "c2Vj" + "cmV0"
        let diagnostic = "Authorization: Basic \(encodedCredential)"

        let output = DiagnosticSanitizer.clean(diagnostic)

        #expect(output == "Authorization: [REDACTED]")
        #expect(output.contains("Basic") == false)
        #expect(output.contains(encodedCredential) == false)
    }

    @Test("credential assignments and authorization headers are redacted generically")
    func credentialsAreRedacted() {
        let diagnostic = """
        SERVICE_API_KEY=alpha token=beta password='gamma' Cookie=delta
        Authorization=epsilon
        Authorization: Bearer zeta
        """

        let output = DiagnosticSanitizer.clean(diagnostic)

        for secret in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
            #expect(output.contains(secret) == false)
        }
        #expect(output.components(separatedBy: "[REDACTED]").count == 7)
    }

    @Test("unsafe controls are replaced and diagnostic output is bounded")
    func controlsAndLengthAreBounded() {
        let diagnostic = "prefix\u{0000}\u{001B}" + String(repeating: "x", count: 5_000)

        let output = DiagnosticSanitizer.clean(diagnostic)

        #expect(output.contains("\u{0000}") == false)
        #expect(output.contains("\u{001B}") == false)
        #expect(output.count == 4_000)
    }
}
