public enum HarnessEndpointState: Equatable, Sendable {
    case free
    case ready
    case foreign
}

public struct StartupObservation: Equatable, Sendable {
    public let tunnelReady: Bool
    public let harness: HarnessEndpointState

    public init(tunnelReady: Bool, harness: HarnessEndpointState) {
        self.tunnelReady = tunnelReady
        self.harness = harness
    }
}

public enum StartupAction: Equatable, Sendable {
    case startTunnel
    case attachTunnel
    case startHarness
    case attachHarness
    case rejectForeignHarness
}

public enum OwnedService: Equatable, Sendable {
    case harness
    case tunnel
}

public enum LifecyclePolicy {
    public static func actions(for observation: StartupObservation) -> [StartupAction] {
        let tunnel: StartupAction = observation.tunnelReady ? .attachTunnel : .startTunnel
        switch observation.harness {
        case .free: return [tunnel, .startHarness]
        case .ready: return [tunnel, .attachHarness]
        case .foreign: return [tunnel, .rejectForeignHarness]
        }
    }

    public static func shutdownOrder(ownsHarness: Bool, ownsTunnel: Bool) -> [OwnedService] {
        var result: [OwnedService] = []
        if ownsHarness { result.append(.harness) }
        if ownsTunnel { result.append(.tunnel) }
        return result
    }
}
