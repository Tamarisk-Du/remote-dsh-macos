public enum AppContentPresentation: Equatable, Sendable {
    case status(CoordinatorStatus)
    case harness
}

public struct AppMenuAvailability: Equatable, Sendable {
    public static let allDisabled = AppMenuAvailability(
        openProject: false,
        reload: false,
        openBrowser: false,
        stopHarness: false,
        retry: false
    )

    public let openProject: Bool
    public let reload: Bool
    public let openBrowser: Bool
    public let stopHarness: Bool
    public let retry: Bool

    public init(
        openProject: Bool,
        reload: Bool,
        openBrowser: Bool,
        stopHarness: Bool,
        retry: Bool
    ) {
        self.openProject = openProject
        self.reload = reload
        self.openBrowser = openBrowser
        self.stopHarness = stopHarness
        self.retry = retry
    }
}

public struct AppPresentation: Equatable, Sendable {
    public let content: AppContentPresentation
    public let menu: AppMenuAvailability

    public init(content: AppContentPresentation, menu: AppMenuAvailability) {
        self.content = content
        self.menu = menu
    }
}

public enum AppPresentationPolicy {
    public static func project(
        status: CoordinatorStatus,
        ownsHarness: Bool,
        operationInFlight: Bool
    ) -> AppPresentation {
        let content: AppContentPresentation = status == .ready ? .harness : .status(status)
        guard operationInFlight == false else {
            return AppPresentation(content: content, menu: .allDisabled)
        }

        let menu: AppMenuAvailability
        switch status {
        case .ready:
            menu = AppMenuAvailability(
                openProject: true,
                reload: true,
                openBrowser: true,
                stopHarness: ownsHarness,
                retry: false
            )
        case .idle, .failed:
            menu = AppMenuAvailability(
                openProject: false,
                reload: false,
                openBrowser: false,
                stopHarness: false,
                retry: true
            )
        case .checkingTunnel, .startingTunnel, .checkingHarness, .startingHarness:
            menu = .allDisabled
        }
        return AppPresentation(content: content, menu: menu)
    }
}
