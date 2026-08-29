import Foundation

public enum CoordinatorFailure: Error, Equatable, Sendable {
    case foreignHarness
    case tunnelLaunchFailed(String)
    case tunnelStartupTimedOut
    case harnessLaunchFailed(String)
    case harnessStartupTimedOut
    case tunnelUnavailable
    case ownedChildStillRunning(Int32)
    case shutdownTimedOut([Int32])
}

public enum CoordinatorStatus: Equatable, Sendable {
    case idle
    case checkingTunnel
    case startingTunnel
    case checkingHarness
    case startingHarness
    case ready
    case failed(CoordinatorFailure)
}

public struct ShutdownReport: Equatable, Sendable {
    public let timedOutPIDs: [Int32]

    public init(timedOutPIDs: [Int32]) {
        self.timedOutPIDs = timedOutPIDs
    }
}

enum CoordinatorJoinOperation: Equatable, Sendable {
    case start
    case retry
    case shutdown
}

@MainActor
public final class ProcessCoordinator {
    public private(set) var status: CoordinatorStatus = .idle
    public var ownsTunnel: Bool { ownedTunnel != nil }
    public var ownsHarness: Bool { ownedHarness != nil }

    private let endpoints: RuntimeEndpoints
    private let probe: any PortProbing
    private let api: any HarnessAPI
    private let launcher: any ProcessLaunching
    private let workspacePathPolicy: WorkspacePathPolicy
    private let tunnelCommand: CommandSpec
    private let harnessCommand: CommandSpec
    private let pollInterval: Duration
    private let tunnelTimeout: Duration
    private let harnessTimeout: Duration
    private let probeTimeout: Duration
    private let monitorInterval: Duration
    private let terminationTimeout: Duration
    private let retryDelays: [Duration]
    private let timing: any CoordinatorTiming

    private struct OwnedChild {
        let launchID: UInt64
        let handle: any ManagedProcessHandle
        var replacementBlocked = false
    }

    private var ownedTunnel: OwnedChild?
    private var ownedHarness: OwnedChild?
    private var harnessRestartPending = false
    private var intentionalHarnessTerminationLaunchID: UInt64?
    private var nextLaunchID: UInt64 = 1
    private var lifecycleGeneration: UInt64 = 0
    private var activeLifecycle: UInt64?
    private var shutdownInProgress = false
    private var monitorTask: Task<Void, Never>?
    private var recoveryInProgress = false
    private var shuttingDown = false
    private var startupInFlight = false
    private var startupWaiters: [CheckedContinuation<Void, any Error>] = []
    private var retryInFlight = false
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<ShutdownReport, Never>] = []
    var waiterEnrollmentObserver: (@MainActor @Sendable (CoordinatorJoinOperation) -> Void)?

    public init(
        endpoints: RuntimeEndpoints,
        probe: any PortProbing,
        api: any HarnessAPI,
        launcher: any ProcessLaunching,
        workspacePathPolicy: WorkspacePathPolicy,
        tunnelCommand: CommandSpec,
        harnessCommand: CommandSpec,
        pollInterval: Duration = .milliseconds(250),
        tunnelTimeout: Duration = .seconds(15),
        harnessTimeout: Duration = .seconds(30),
        probeTimeout: Duration = .seconds(1),
        monitorInterval: Duration = .seconds(5),
        terminationTimeout: Duration = .seconds(3),
        retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)],
        timing: (any CoordinatorTiming)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.endpoints = endpoints
        self.probe = probe
        self.api = api
        self.launcher = launcher
        self.workspacePathPolicy = workspacePathPolicy
        self.tunnelCommand = tunnelCommand
        self.harnessCommand = harnessCommand
        self.pollInterval = pollInterval
        self.tunnelTimeout = tunnelTimeout
        self.harnessTimeout = harnessTimeout
        self.probeTimeout = probeTimeout
        self.monitorInterval = monitorInterval
        self.terminationTimeout = terminationTimeout
        self.retryDelays = retryDelays
        self.timing = timing ?? makeClosureCoordinatorTiming(sleep)
    }

    deinit {
        monitorTask?.cancel()
    }

    public func start() async throws {
        if startupInFlight {
            try await withCheckedThrowingContinuation { continuation in
                startupWaiters.append(continuation)
                waiterEnrollmentObserver?(.start)
            }
            return
        }
        startupInFlight = true
        do {
            try await performStart()
            completeStartup(with: nil)
        } catch {
            completeStartup(with: error)
            throw error
        }
    }

    private func performStart() async throws {
        // LifecyclePolicy is a pure simultaneous-snapshot policy. This coordinator
        // intentionally performs the tunnel step before observing the Harness endpoint so each
        // suspension can be generation-checked and exact child ownership retained.
        guard status != .ready else { return }
        let restartingHarness = harnessRestartPending
            && ownedHarness == nil
            && ownedTunnel != nil
        guard let operation = try beginLifecycle(
            allowOwnedTunnelRecovery: restartingHarness
        ) else { throw CancellationError() }
        defer { finishLifecycle(operation) }
        monitorTask?.cancel()
        monitorTask = nil
        shuttingDown = false

        try setStatus(.checkingTunnel, operation: operation)
        let tunnelDeadline = timing.now() + tunnelTimeout
        let tunnelReady = await tunnelIsReady(until: tunnelDeadline)
        try ensureCurrent(operation)
        if tunnelReady == false {
            guard timing.now() < tunnelDeadline else {
                try fail(.tunnelStartupTimedOut, operation: operation)
            }
            try await startTunnelHandlingRace(operation: operation, deadline: tunnelDeadline)
            try ensureCurrent(operation)
        }

        try setStatus(.checkingHarness, operation: operation)
        let harnessDeadline = timing.now() + harnessTimeout
        let harnessState = await harnessEndpointState(until: harnessDeadline)
        try ensureCurrent(operation)
        guard timing.now() < harnessDeadline || harnessState == .ready else {
            try fail(.harnessStartupTimedOut, operation: operation)
        }
        switch harnessState {
        case .ready:
            break
        case .foreign:
            try fail(.foreignHarness, operation: operation)
        case .free:
            try await startHarness(operation: operation, deadline: harnessDeadline)
            try ensureCurrent(operation)
        }

        try setStatus(.ready, operation: operation)
        harnessRestartPending = false
        beginMonitoring()
    }

    public func retry() async {
        if retryInFlight {
            await withCheckedContinuation { continuation in
                retryWaiters.append(continuation)
                waiterEnrollmentObserver?(.retry)
            }
            return
        }
        retryInFlight = true
        await performRetry()
        completeRetry()
    }

    private func performRetry() async {
        guard let operation = try? beginLifecycle(allowOwnedTunnelRecovery: true) else { return }
        await recoverTunnel(operation: operation)
        let shouldMonitor = isCurrent(operation) && status == .ready && shuttingDown == false
        finishLifecycle(operation)
        if shouldMonitor {
            beginMonitoring()
        }
    }

    private func recoverTunnel(operation: UInt64) async {
        guard isCurrent(operation), recoveryInProgress == false, shuttingDown == false else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }

        let initiallyReady = await tunnelIsReady()
        guard isCurrent(operation) else { return }
        if initiallyReady {
            try? setStatus(.ready, operation: operation)
            return
        }

        if let child = ownedTunnel {
            let timedOutPID = await terminate(child.handle)
            guard isCurrent(operation) else { return }
            if timedOutPID != nil {
                if ownedTunnel?.launchID == child.launchID {
                    ownedTunnel?.replacementBlocked = true
                }
                try? setStatus(.failed(.tunnelUnavailable), operation: operation)
                return
            }
            if ownedTunnel?.launchID == child.launchID {
                ownedTunnel = nil
            }
        }

        for delay in retryDelays {
            do {
                try await timing.sleep(for: delay)
            } catch {
                return
            }
            guard isCurrent(operation), Task.isCancelled == false, shuttingDown == false else { return }

            let readyBeforeLaunch = await tunnelIsReady()
            guard isCurrent(operation) else { return }
            if readyBeforeLaunch {
                try? setStatus(.ready, operation: operation)
                return
            }

            try? setStatus(.startingTunnel, operation: operation)
            do {
                guard isCurrent(operation), ownedTunnel == nil else { return }
                let child = try launchOwned(tunnelCommand, service: .tunnel, operation: operation)
                guard isCurrent(operation), ownedTunnel == nil else { return }
                ownedTunnel = child
                let deadline = timing.now() + tunnelTimeout
                let becameReady = await waitForTunnel(until: deadline)
                guard isCurrent(operation) else { return }
                if becameReady {
                    if child.handle.isRunning == false, ownedTunnel?.launchID == child.launchID {
                        ownedTunnel = nil
                    }
                    try? setStatus(.ready, operation: operation)
                    return
                }
                let timedOutPID = await terminate(child.handle)
                guard isCurrent(operation) else { return }
                if timedOutPID != nil {
                    if ownedTunnel?.launchID == child.launchID {
                        ownedTunnel?.replacementBlocked = true
                    }
                    try? setStatus(.failed(.tunnelUnavailable), operation: operation)
                    return
                }
                if ownedTunnel?.launchID == child.launchID {
                    ownedTunnel = nil
                }
            } catch {
                guard isCurrent(operation) else { return }
                let raceWinnerReady = await tunnelIsReady()
                guard isCurrent(operation) else { return }
                if raceWinnerReady {
                    try? setStatus(.ready, operation: operation)
                    return
                }
            }
        }
        try? setStatus(.failed(.tunnelUnavailable), operation: operation)
    }

    public func createWorkspace(path: String) async throws -> WorkspaceCreateValue {
        let canonicalPath = try workspacePathPolicy.canonicalProjectPath(path)
        return try await api.createWorkspace(path: canonicalPath)
    }

    public func stopOwnedHarness() async -> ShutdownReport {
        guard activeLifecycle == nil, shutdownInProgress == false,
              let child = ownedHarness else {
            return ShutdownReport(timedOutPIDs: [])
        }
        lifecycleGeneration &+= 1
        let operation = lifecycleGeneration
        activeLifecycle = operation
        defer { finishLifecycle(operation) }
        intentionalHarnessTerminationLaunchID = child.launchID
        let timedOutPID = await terminate(child.handle)
        guard isCurrent(operation) else {
            return ShutdownReport(timedOutPIDs: timedOutPID.map { [$0] } ?? [])
        }
        if timedOutPID == nil, ownedHarness?.launchID == child.launchID {
            ownedHarness = nil
        } else if timedOutPID != nil, ownedHarness?.launchID == child.launchID {
            ownedHarness?.replacementBlocked = true
            status = .failed(.ownedChildStillRunning(child.handle.processIdentifier))
        }
        if timedOutPID == nil {
            if intentionalHarnessTerminationLaunchID == child.launchID {
                intentionalHarnessTerminationLaunchID = nil
            }
            harnessRestartPending = true
            monitorTask?.cancel()
            monitorTask = nil
            status = .idle
        }
        return ShutdownReport(timedOutPIDs: timedOutPID.map { [$0] } ?? [])
    }

    public func shutdown() async -> ShutdownReport {
        if shutdownInProgress {
            return await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
                waiterEnrollmentObserver?(.shutdown)
            }
        }
        shutdownInProgress = true
        let report = await performShutdown()
        completeShutdown(with: report)
        return report
    }

    private func performShutdown() async -> ShutdownReport {
        lifecycleGeneration &+= 1
        let shutdownGeneration = lifecycleGeneration
        activeLifecycle = nil
        shuttingDown = true
        harnessRestartPending = false
        monitorTask?.cancel()
        monitorTask = nil
        var timedOutPIDs: [Int32] = []

        if let child = ownedHarness {
            let timedOutPID = await terminate(child.handle)
            guard lifecycleGeneration == shutdownGeneration, shutdownInProgress else {
                return ShutdownReport(timedOutPIDs: timedOutPIDs)
            }
            if let pid = timedOutPID { timedOutPIDs.append(pid) }
            if timedOutPID == nil, ownedHarness?.launchID == child.launchID {
                ownedHarness = nil
            } else if timedOutPID != nil, ownedHarness?.launchID == child.launchID {
                ownedHarness?.replacementBlocked = true
            }
        }
        if let child = ownedTunnel {
            let timedOutPID = await terminate(child.handle)
            guard lifecycleGeneration == shutdownGeneration, shutdownInProgress else {
                return ShutdownReport(timedOutPIDs: timedOutPIDs)
            }
            if let pid = timedOutPID { timedOutPIDs.append(pid) }
            if timedOutPID == nil, ownedTunnel?.launchID == child.launchID {
                ownedTunnel = nil
            } else if timedOutPID != nil, ownedTunnel?.launchID == child.launchID {
                ownedTunnel?.replacementBlocked = true
            }
        }
        status = timedOutPIDs.isEmpty ? .idle : .failed(.shutdownTimedOut(timedOutPIDs))
        intentionalHarnessTerminationLaunchID = nil
        return ShutdownReport(timedOutPIDs: timedOutPIDs)
    }

    private func startTunnelHandlingRace(operation: UInt64, deadline: Duration) async throws {
        try setStatus(.startingTunnel, operation: operation)
        do {
            guard ownedTunnel == nil else {
                try fail(.ownedChildStillRunning(ownedTunnel!.handle.processIdentifier), operation: operation)
            }
            let child = try launchOwned(tunnelCommand, service: .tunnel, operation: operation)
            try ensureCurrent(operation)
            guard ownedTunnel == nil else { throw CancellationError() }
            ownedTunnel = child
            let ready = await waitForTunnel(until: deadline)
            try ensureCurrent(operation)
            guard ready else {
                if child.handle.isRunning, ownedTunnel?.launchID == child.launchID {
                    ownedTunnel?.replacementBlocked = true
                }
                try fail(.tunnelStartupTimedOut, operation: operation)
            }
            if child.handle.isRunning == false, ownedTunnel?.launchID == child.launchID {
                ownedTunnel = nil
            }
        } catch let failure as CoordinatorFailure {
            throw failure
        } catch {
            try ensureCurrent(operation)
            if await tunnelIsReady(until: deadline) {
                try ensureCurrent(operation)
                return
            }
            try ensureCurrent(operation)
            try fail(.tunnelLaunchFailed(sanitized(error)), operation: operation)
        }
    }

    private func startHarness(operation: UInt64, deadline: Duration) async throws {
        try setStatus(.startingHarness, operation: operation)
        do {
            guard ownedHarness == nil else {
                try fail(.ownedChildStillRunning(ownedHarness!.handle.processIdentifier), operation: operation)
            }
            let child = try launchOwned(harnessCommand, service: .harness, operation: operation)
            try ensureCurrent(operation)
            guard ownedHarness == nil else { throw CancellationError() }
            ownedHarness = child
            let ready = await waitForHarness(until: deadline)
            try ensureCurrent(operation)
            guard ready else {
                if child.handle.isRunning, ownedHarness?.launchID == child.launchID {
                    ownedHarness?.replacementBlocked = true
                }
                try fail(.harnessStartupTimedOut, operation: operation)
            }
            if child.handle.isRunning == false, ownedHarness?.launchID == child.launchID {
                ownedHarness = nil
            }
        } catch let failure as CoordinatorFailure {
            throw failure
        } catch {
            try ensureCurrent(operation)
            try fail(.harnessLaunchFailed(sanitized(error)), operation: operation)
        }
    }

    private func launchOwned(
        _ command: CommandSpec,
        service: OwnedService,
        operation: UInt64
    ) throws -> OwnedChild {
        try ensureCurrent(operation)
        let launchID = nextLaunchID
        nextLaunchID &+= 1
        let handle = try launcher.launch(command) { [weak self] pid in
            Task { @MainActor [weak self] in
                self?.ownedChildTerminated(launchID: launchID, pid: pid, service: service)
            }
        }
        try ensureCurrent(operation)
        return OwnedChild(launchID: launchID, handle: handle)
    }

    private func ownedChildTerminated(launchID: UInt64, pid: Int32, service: OwnedService) {
        switch service {
        case .harness:
            guard ownedHarness?.launchID == launchID,
                  ownedHarness?.handle.processIdentifier == pid else { return }
            let wasIntentionalStop = intentionalHarnessTerminationLaunchID == launchID
            ownedHarness = nil
            if wasIntentionalStop {
                intentionalHarnessTerminationLaunchID = nil
            }
            guard shuttingDown == false else { return }
            if wasIntentionalStop {
                harnessRestartPending = true
                monitorTask?.cancel()
                monitorTask = nil
                status = .idle
                return
            }
            harnessRestartPending = true
            monitorTask?.cancel()
            monitorTask = nil
            lifecycleGeneration &+= 1
            status = .failed(.harnessLaunchFailed("Harness process exited unexpectedly (PID \(pid))."))
        case .tunnel:
            guard ownedTunnel?.launchID == launchID,
                  ownedTunnel?.handle.processIdentifier == pid else { return }
            ownedTunnel = nil
        }
    }

    private func harnessEndpointState(until deadline: Duration) async -> HarnessEndpointState {
        let listening = await timing.run(until: deadline) { [endpoints, probe, probeTimeout] in
            await probe.isListening(
                host: endpoints.host,
                port: endpoints.harnessPort,
                timeout: probeTimeout
            )
        }
        guard listening else {
            return .free
        }
        let valid = await timing.run(until: deadline) { [api] in
            do {
                _ = try await api.describe()
                return true
            } catch {
                return false
            }
        }
        return valid ? .ready : .foreign
    }

    private func tunnelIsReady() async -> Bool {
        await tunnelIsReady(until: timing.now() + probeTimeout)
    }

    private func tunnelIsReady(until deadline: Duration) async -> Bool {
        await timing.run(until: deadline) { [endpoints, probe, probeTimeout] in
            await probe.isListening(
                host: endpoints.host,
                port: endpoints.sshLocalPort,
                timeout: probeTimeout
            )
        }
    }

    private func waitForTunnel(until deadline: Duration) async -> Bool {
        await poll(until: deadline) { [endpoints, probe, probeTimeout] in
            await probe.isListening(
                host: endpoints.host,
                port: endpoints.sshLocalPort,
                timeout: probeTimeout
            )
        }
    }

    private func waitForHarness(until deadline: Duration) async -> Bool {
        await poll(until: deadline) { [api] in
            do {
                _ = try await api.describe()
                return true
            } catch {
                return false
            }
        }
    }

    private func poll(
        until deadline: Duration,
        check: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        while timing.now() < deadline {
            if await timing.run(until: deadline, operation: check) { return true }
            guard timing.now() < deadline else { return false }
            let remaining = deadline - timing.now()
            let delay = min(pollInterval, remaining)
            do {
                try await timing.sleep(for: delay)
            } catch {
                return false
            }
        }
        return false
    }

    private func terminate(_ handle: any ManagedProcessHandle) async -> Int32? {
        let pid = handle.processIdentifier
        handle.terminate()
        let deadline = timing.now() + terminationTimeout
        while handle.isRunning, timing.now() < deadline {
            let remaining = deadline - timing.now()
            let delay = min(pollInterval, remaining)
            do {
                try await timing.sleep(for: delay)
            } catch {
                break
            }
        }
        return handle.isRunning ? pid : nil
    }

    private func beginMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Task.isCancelled == false, self.shuttingDown == false {
                do {
                    try await self.timing.sleep(for: self.monitorInterval)
                } catch {
                    return
                }
                guard Task.isCancelled == false, self.shuttingDown == false else { return }
                if await self.tunnelIsReady() == false {
                    guard Task.isCancelled == false, self.shuttingDown == false else { return }
                    await self.retry()
                    if self.status == .failed(.tunnelUnavailable) { return }
                }
            }
        }
    }

    private func completeStartup(with error: (any Error)?) {
        startupInFlight = false
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func completeRetry() {
        retryInFlight = false
        let waiters = retryWaiters
        retryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func completeShutdown(with report: ShutdownReport) {
        shutdownInProgress = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume(returning: report) }
    }

    private func beginLifecycle(allowOwnedTunnelRecovery: Bool = false) throws -> UInt64? {
        guard activeLifecycle == nil, shutdownInProgress == false else { return nil }
        pruneExitedChildren()
        if let child = ownedHarness, child.handle.isRunning,
           allowOwnedTunnelRecovery == false {
            throw CoordinatorFailure.ownedChildStillRunning(child.handle.processIdentifier)
        }
        if let child = ownedTunnel, child.handle.isRunning,
           allowOwnedTunnelRecovery == false || child.replacementBlocked {
            throw CoordinatorFailure.ownedChildStillRunning(child.handle.processIdentifier)
        }
        lifecycleGeneration &+= 1
        let operation = lifecycleGeneration
        activeLifecycle = operation
        return operation
    }

    private func finishLifecycle(_ operation: UInt64) {
        if activeLifecycle == operation { activeLifecycle = nil }
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        activeLifecycle == operation
            && lifecycleGeneration == operation
            && shutdownInProgress == false
    }

    private func ensureCurrent(_ operation: UInt64) throws {
        guard isCurrent(operation) else { throw CancellationError() }
    }

    private func setStatus(_ newStatus: CoordinatorStatus, operation: UInt64) throws {
        try ensureCurrent(operation)
        status = newStatus
    }

    private func pruneExitedChildren() {
        if let child = ownedHarness, child.handle.isRunning == false { ownedHarness = nil }
        if let child = ownedTunnel, child.handle.isRunning == false { ownedTunnel = nil }
    }

    private func fail(_ failure: CoordinatorFailure, operation: UInt64) throws -> Never {
        try ensureCurrent(operation)
        status = .failed(failure)
        throw failure
    }

    private func sanitized(_ error: Error) -> String {
        DiagnosticSanitizer.clean(String(describing: error))
    }
}
