import Testing
import RemoteDSHCore

@Suite("App presentation policy")
struct AppPresentationPolicyTests {
    @Test("ready owned Harness presents WebView and enables ready actions")
    func readyOwnedHarnessEnablesReadyActions() {
        let projection = AppPresentationPolicy.project(
            status: .ready,
            ownsHarness: true,
            operationInFlight: false
        )

        #expect(projection.content == .harness)
        #expect(projection.menu == AppMenuAvailability(
            openProject: true,
            reload: true,
            openBrowser: true,
            stopHarness: true,
            retry: false
        ))
    }

    @Test("ownership-only change disables Stop without replacing ready WebView")
    func attachedHarnessDisablesOnlyStop() {
        let projection = AppPresentationPolicy.project(
            status: .ready,
            ownsHarness: false,
            operationInFlight: false
        )

        #expect(projection.content == .harness)
        #expect(projection.menu.stopHarness == false)
        #expect(projection.menu.openProject)
        #expect(projection.menu.reload)
        #expect(projection.menu.openBrowser)
        #expect(projection.menu.retry == false)
    }

    @Test("final failure presents status and enables only Retry")
    func finalFailureEnablesOnlyRetry() {
        let projection = AppPresentationPolicy.project(
            status: .failed(.tunnelUnavailable),
            ownsHarness: false,
            operationInFlight: false
        )

        #expect(projection.content == .status(.failed(.tunnelUnavailable)))
        #expect(projection.menu == AppMenuAvailability(
            openProject: false,
            reload: false,
            openBrowser: false,
            stopHarness: false,
            retry: true
        ))
    }

    @Test("progress and in-flight operations disable competing actions")
    func progressAndOperationsDisableActions() {
        let progress = AppPresentationPolicy.project(
            status: .startingHarness,
            ownsHarness: false,
            operationInFlight: false
        )
        let stopping = AppPresentationPolicy.project(
            status: .ready,
            ownsHarness: true,
            operationInFlight: true
        )

        #expect(progress.menu == .allDisabled)
        #expect(stopping.menu == .allDisabled)
    }
}
