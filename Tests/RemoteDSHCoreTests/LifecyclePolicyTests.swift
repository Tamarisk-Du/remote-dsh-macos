import Testing
@testable import RemoteDSHCore

@Suite("Lifecycle policy")
struct LifecyclePolicyTests {
    @Test("both absent starts tunnel then harness")
    func bothAbsentStartsTunnelThenHarness() {
        let input = StartupObservation(tunnelReady: false, harness: .free)
        #expect(LifecyclePolicy.actions(for: input) == [.startTunnel, .startHarness])
    }

    @Test("existing services are attached")
    func existingServicesAreAttached() {
        let input = StartupObservation(tunnelReady: true, harness: .ready)
        #expect(LifecyclePolicy.actions(for: input) == [.attachTunnel, .attachHarness])
    }

    @Test("foreign harness port fails closed")
    func foreignHarnessPortFailsClosed() {
        let input = StartupObservation(tunnelReady: true, harness: .foreign)
        #expect(LifecyclePolicy.actions(for: input) == [.attachTunnel, .rejectForeignHarness])
    }

    @Test("shutdown contains only owned services in safe order")
    func shutdownContainsOnlyOwnedServicesInSafeOrder() {
        #expect(LifecyclePolicy.shutdownOrder(ownsHarness: true, ownsTunnel: false) == [.harness])
        #expect(LifecyclePolicy.shutdownOrder(ownsHarness: true, ownsTunnel: true) == [.harness, .tunnel])
    }
}
