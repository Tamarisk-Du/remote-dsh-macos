import Foundation
import RemoteDSHCore
import Testing

@Suite("NavigationPolicyTests")
struct NavigationPolicyTests {
    private let allowedOrigin = URL(string: "http://127.0.0.1:43117/")!

    @Test("exact-origin Harness paths and exact about blank stay embedded")
    func allowedDestinationsStayEmbedded() {
        #expect(destination("http://127.0.0.1:43117/session/1") == .embedded)
        #expect(destination("http://127.0.0.1:43117/api/status?fresh=1#state") == .embedded)
        #expect(destination("about:blank") == .embedded)
    }

    @Test("genuine external HTTP and HTTPS destinations open externally")
    func externalDestinationsOpenExternally() {
        #expect(destination("http://example.com/help") == .externalBrowser)
        #expect(destination("https://example.com/help") == .externalBrowser)
    }

    @Test(
        "loopback aliases, origin changes, credentials, and non-web schemes are rejected",
        arguments: [
            "http://localhost:43117/",
            "http://127.1:43117/",
            "http://[::1]:43117/",
            "http://user:password@127.0.0.1:43117/",
            "http://127.0.0.1/",
            "http://127.0.0.1:43118/",
            "https://127.0.0.1:43117/",
            "file:///private/tmp/example",
            "javascript:alert(1)",
            "about:blank#fragment"
        ]
    )
    func unsafeDestinationsAreRejected(_ rawURL: String) {
        #expect(destination(rawURL) == .reject)
    }

    private func destination(_ rawURL: String) -> NavigationDestination {
        NavigationPolicy.destination(for: URL(string: rawURL)!, allowedOrigin: allowedOrigin)
    }
}
