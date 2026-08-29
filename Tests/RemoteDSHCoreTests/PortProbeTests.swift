import Testing
@testable import RemoteDSHCore

@Suite("Port probe")
struct PortProbeTests {
    @Test("open loopback listener reports ready")
    func openLoopbackListenerReportsReady() async throws {
        let fixture = try await LoopbackListenerFixture.started()
        defer { fixture.cancel() }

        #expect(
            await TCPPortProbe().isListening(
                host: "127.0.0.1", port: fixture.port, timeout: .seconds(1)
            )
        )
    }

    @Test("closed loopback port reports false")
    func closedLoopbackPortReportsFalse() async throws {
        let fixture = try await LoopbackListenerFixture.started()
        let port = fixture.port
        fixture.cancel()
        await fixture.waitUntilCancelled()

        #expect(
            await TCPPortProbe().isListening(
                host: "127.0.0.1", port: port, timeout: .milliseconds(200)
            ) == false
        )
    }
}
