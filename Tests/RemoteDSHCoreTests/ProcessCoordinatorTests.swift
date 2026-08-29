import Foundation
import Testing
@testable import RemoteDSHCore

@Suite("Process coordinator", .serialized)
struct ProcessCoordinatorTests {
    @Test("concurrent starts share one in-flight lifecycle operation")
    @MainActor
    func concurrentStartsLaunchOnlyOnce() async throws {
        let gate = AsyncGate()
        let enrollment = WaiterEnrollmentGate(expected: .start)
        let secondCompleted = TaskCompletionFlag()
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, false, true, true],
            harnessSequence: [.ready, .ready],
            tunnelGates: [gate, nil],
            waiterEnrollmentGate: enrollment
        )

        let first = Task { @MainActor in try await fixture.coordinator.start() }
        await gate.waitForArrivals(1)
        let second = Task { @MainActor in
            try await fixture.coordinator.start()
            await secondCompleted.markCompleted()
        }
        await enrollment.wait()
        #expect(await secondCompleted.value == false)
        await gate.releaseAll()
        _ = try? await first.value
        _ = try? await second.value

        #expect(fixture.launcher.commands.filter { $0 == fixture.tunnelCommand }.count == 1)
        #expect(await secondCompleted.value)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("concurrent starts remain joined and receive the same failure")
    @MainActor
    func concurrentStartsShareFailure() async {
        let gate = AsyncGate()
        let enrollment = WaiterEnrollmentGate(expected: .start)
        let secondCompleted = TaskCompletionFlag()
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.foreign],
            tunnelGates: [gate],
            waiterEnrollmentGate: enrollment
        )
        let first = Task { @MainActor in await capturedStartFailure(fixture.coordinator) }
        await gate.waitForArrivals(1)
        let second = Task { @MainActor in
            let failure = await capturedStartFailure(fixture.coordinator)
            await secondCompleted.markCompleted()
            return failure
        }
        await enrollment.wait()
        #expect(await secondCompleted.value == false)

        await gate.releaseAll()
        let firstFailure = await first.value
        let secondFailure = await second.value

        #expect(firstFailure == .foreignHarness)
        #expect(secondFailure == firstFailure)
    }

    @Test("concurrent retries remain joined until shared recovery completes")
    @MainActor
    func concurrentRetriesJoin() async throws {
        let gate = AsyncGate()
        let enrollment = WaiterEnrollmentGate(expected: .retry)
        let secondCompleted = TaskCompletionFlag()
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, true],
            harnessSequence: [.ready],
            tunnelGates: [nil, gate],
            waiterEnrollmentGate: enrollment
        )
        try await fixture.coordinator.start()
        let first = Task { @MainActor in await fixture.coordinator.retry() }
        await gate.waitForArrivals(1)
        let second = Task { @MainActor in
            await fixture.coordinator.retry()
            await secondCompleted.markCompleted()
        }
        await enrollment.wait()
        #expect(await secondCompleted.value == false)

        await gate.releaseAll()
        await first.value
        await second.value

        #expect(await secondCompleted.value)
        #expect(fixture.launcher.commands.isEmpty)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("concurrent shutdown callers receive the same shared report")
    @MainActor
    func concurrentShutdownsJoin() async throws {
        let sleepGate = AsyncGate()
        let enrollment = WaiterEnrollmentGate(expected: .shutdown)
        let secondCompleted = TaskCompletionFlag()
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready],
            processStops: [true, false],
            sleepGate: sleepGate,
            waiterEnrollmentGate: enrollment
        )
        try await fixture.coordinator.start()
        let first = Task { @MainActor in await fixture.coordinator.shutdown() }
        await sleepGate.waitForArrivals(1)
        let second = Task { @MainActor in
            let report = await fixture.coordinator.shutdown()
            await secondCompleted.markCompleted()
            return report
        }
        await enrollment.wait()
        #expect(await secondCompleted.value == false)

        await sleepGate.releaseAll()
        let firstReport = await first.value
        let secondReport = await second.value

        #expect(firstReport == ShutdownReport(timedOutPIDs: [202]))
        #expect(secondReport == firstReport)
        #expect(await secondCompleted.value)
    }

    @Test("shutdown invalidates a startup suspended in a probe")
    @MainActor
    func shutdownPreventsSuspendedStartFromLaunching() async {
        let gate = AsyncGate()
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.ready],
            tunnelGates: [gate]
        )
        let startup = Task { @MainActor in try await fixture.coordinator.start() }
        await gate.waitForArrivals(1)

        let report = await fixture.coordinator.shutdown()
        await gate.releaseAll()
        _ = try? await startup.value

        #expect(report.timedOutPIDs.isEmpty)
        #expect(fixture.launcher.commands.isEmpty)
        #expect(fixture.coordinator.status == .idle)
    }

    @Test("shutdown invalidates recovery suspended after its backoff")
    @MainActor
    func shutdownPreventsSuspendedRecoveryFromLaunching() async throws {
        let gate = AsyncGate()
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, false, false],
            harnessSequence: [.ready],
            tunnelGates: [nil, nil, gate]
        )
        try await fixture.coordinator.start()
        let recovery = Task { @MainActor in await fixture.coordinator.retry() }
        await gate.waitForArrivals(1)

        _ = await fixture.coordinator.shutdown()
        await gate.releaseAll()
        await recovery.value

        #expect(fixture.launcher.commands.isEmpty)
        #expect(fixture.coordinator.status == .idle)
    }

    @Test("starts tunnel before Harness when both are absent")
    @MainActor
    func startsBothWhenBothAreAbsent() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready]
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand, fixture.harnessCommand])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("configured endpoints drive the tunnel and Harness probes")
    @MainActor
    func configuredEndpointsDriveProbes() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.ready]
        )

        try await fixture.coordinator.start()

        #expect(await fixture.portProbe.requestedPorts == [43117, 43118])
        _ = await fixture.coordinator.shutdown()
    }

    @Test("attaches without launching when both services exist")
    @MainActor
    func attachesWithoutLaunchingWhenServicesExist() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.ready]
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands.isEmpty)
        #expect(fixture.coordinator.ownsTunnel == false)
        #expect(fixture.coordinator.ownsHarness == false)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("shutdown terminates retained owned handles in Harness then tunnel order")
    @MainActor
    func shutdownTerminatesOwnedHarnessBeforeOwnedTunnel() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready]
        )
        try await fixture.coordinator.start()

        let report = await fixture.coordinator.shutdown()

        #expect(fixture.terminationOrder.values == [.harness, .tunnel])
        #expect(report.timedOutPIDs.isEmpty)
        #expect(fixture.coordinator.ownsHarness == false)
        #expect(fixture.coordinator.ownsTunnel == false)
    }

    @Test("foreign Harness listener is rejected without launching or terminating anything")
    @MainActor
    func foreignHarnessIsUntouched() async {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.foreign]
        )

        await #expect(throws: CoordinatorFailure.foreignHarness) {
            try await fixture.coordinator.start()
        }
        #expect(fixture.coordinator.status == .failed(.foreignHarness))
        let report = await fixture.coordinator.shutdown()

        #expect(fixture.launcher.commands.isEmpty)
        #expect(fixture.terminationOrder.values.isEmpty)
        #expect(report.timedOutPIDs.isEmpty)
    }

    @Test("existing tunnel plus free Harness starts only Harness")
    @MainActor
    func existingTunnelStartsOnlyHarness() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.free, .ready]
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.harnessCommand])
        #expect(fixture.coordinator.ownsTunnel == false)
        #expect(fixture.coordinator.ownsHarness)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("SSH launch race rechecks the port and attaches to the winner")
    @MainActor
    func sshPortRaceRechecksAndAttaches() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.ready],
            launchFailures: [TestLaunchError.expected]
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel == false)
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
        #expect(fixture.terminationOrder.values.isEmpty)
    }

    @Test("SSH child exit after launch attaches to the process that won the port")
    @MainActor
    func exitedSSHChildDoesNotClaimExternalWinner() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.ready],
            tunnelStartsRunning: false
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel == false)
        _ = await fixture.coordinator.shutdown()
        #expect(fixture.tunnelHandle.terminateCount == 0)
    }

    @Test("exited Harness child does not claim a valid external Harness race winner")
    @MainActor
    func exitedHarnessChildDoesNotClaimExternalWinner() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.free, .ready],
            harnessStartsRunning: false
        )

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.harnessCommand])
        #expect(fixture.coordinator.ownsHarness == false)
        _ = await fixture.coordinator.shutdown()
        #expect(fixture.harnessHandle.terminateCount == 0)
    }

    @Test("timed-out owned child reports its exact PID and is never force-killed")
    @MainActor
    func timedOutChildReportsExactPID() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready],
            processStops: [true, false]
        )
        try await fixture.coordinator.start()

        let report = await fixture.coordinator.shutdown()

        #expect(report.timedOutPIDs == [202])
        #expect(fixture.harnessHandle.terminateCount == 1)
        #expect(fixture.harnessHandle.isRunning)
        #expect(fixture.tunnelHandle.terminateCount == 1)
    }

    @Test("stop menu terminates only an App-owned Harness and leaves tunnel running")
    @MainActor
    func stopOwnedHarnessLeavesTunnelRunning() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready]
        )
        try await fixture.coordinator.start()

        let report = await fixture.coordinator.stopOwnedHarness()

        #expect(report.timedOutPIDs.isEmpty)
        #expect(fixture.terminationOrder.values == [.harness])
        #expect(fixture.coordinator.ownsHarness == false)
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.tunnelHandle.isRunning)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("successful Stop allows Harness restart without relaunching the owned tunnel")
    @MainActor
    func startAfterSuccessfulStopRestartsOnlyHarness() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, true],
            harnessSequence: [.free, .ready, .free, .ready]
        )
        try await fixture.coordinator.start()
        let report = await fixture.coordinator.stopOwnedHarness()

        #expect(report.timedOutPIDs.isEmpty)
        #expect(fixture.coordinator.status == .idle)
        #expect(fixture.coordinator.ownsTunnel)

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [
            fixture.tunnelCommand, fixture.harnessCommand, fixture.harnessCommand
        ])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("unexpected exit of an App-owned Harness publishes failure")
    @MainActor
    func unexpectedOwnedHarnessExitPublishesFailure() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.free, .ready]
        )
        try await fixture.coordinator.start()

        fixture.harnessHandle.simulateUnexpectedExit()
        for _ in 0..<4 { await Task.yield() }

        #expect(fixture.coordinator.ownsHarness == false)
        guard case .failed(.harnessLaunchFailed(let detail)) = fixture.coordinator.status else {
            Issue.record("expected an exact unexpected-Harness-exit failure")
            return
        }
        #expect(detail.contains("202"))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("unexpected Harness exit restarts only Harness while retaining its healthy owned tunnel")
    @MainActor
    func unexpectedHarnessExitRestartsWithHealthyOwnedTunnel() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, true],
            harnessSequence: [.free, .ready, .free, .ready]
        )
        try await fixture.coordinator.start()
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)

        fixture.harnessHandle.simulateUnexpectedExit()
        for _ in 0..<4 { await Task.yield() }

        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness == false)
        guard case .failed(.harnessLaunchFailed) = fixture.coordinator.status else {
            Issue.record("expected unexpected Harness exit failure")
            return
        }

        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [
            fixture.tunnelCommand, fixture.harnessCommand, fixture.harnessCommand
        ])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("Harness exit during tunnel recovery invalidates recovery before it can republish ready")
    @MainActor
    func harnessExitDuringTunnelRecoveryRemainsFailed() async throws {
        let recoveryGate = AsyncGate()
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, false, true],
            harnessSequence: [.free, .ready],
            sleepGate: recoveryGate
        )
        try await fixture.coordinator.start()
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)

        let recovery = Task { @MainActor in await fixture.coordinator.retry() }
        await recoveryGate.waitForArrivals(1)
        fixture.harnessHandle.simulateUnexpectedExit()
        for _ in 0..<4 { await Task.yield() }

        guard case .failed(.harnessLaunchFailed) = fixture.coordinator.status else {
            Issue.record("expected failure while recovery remained barrier-suspended")
            await recoveryGate.releaseAll()
            await recovery.value
            return
        }

        await recoveryGate.releaseAll()
        await recovery.value

        guard case .failed(.harnessLaunchFailed) = fixture.coordinator.status else {
            Issue.record("recovery overwrote unexpected Harness exit with false readiness")
            return
        }
        #expect(fixture.coordinator.ownsHarness == false)
        #expect(fixture.launcher.commands == [fixture.tunnelCommand, fixture.harnessCommand])
        _ = await fixture.coordinator.shutdown()
    }

    @Test("stop menu retains exact ownership when Harness ignores termination")
    @MainActor
    func stopOwnedHarnessTimeoutRetainsHandle() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true],
            harnessSequence: [.free, .ready],
            processStops: [true, false]
        )
        try await fixture.coordinator.start()

        let report = await fixture.coordinator.stopOwnedHarness()

        #expect(report.timedOutPIDs == [202])
        #expect(fixture.coordinator.ownsHarness)
        #expect(fixture.harnessHandle.terminateCount == 1)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("Harness exiting after Stop timeout becomes restartable without relaunching tunnel")
    @MainActor
    func lateExitAfterStopTimeoutRestartsOnlyHarness() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, true],
            harnessSequence: [.free, .ready, .free, .ready],
            processStops: [true, false]
        )
        try await fixture.coordinator.start()
        let report = await fixture.coordinator.stopOwnedHarness()
        #expect(report.timedOutPIDs == [202])
        #expect(fixture.coordinator.ownsHarness)

        fixture.harnessHandle.simulateUnexpectedExit()
        for _ in 0..<4 { await Task.yield() }

        #expect(fixture.coordinator.status == .idle)
        #expect(fixture.coordinator.ownsHarness == false)
        try await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [
            fixture.tunnelCommand, fixture.harnessCommand, fixture.harnessCommand
        ])
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("stop menu is a no-op for an attached external Harness")
    @MainActor
    func stopAttachedHarnessIsNoOp() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.ready]
        )
        try await fixture.coordinator.start()

        let report = await fixture.coordinator.stopOwnedHarness()

        #expect(report.timedOutPIDs.isEmpty)
        #expect(fixture.launcher.commands.isEmpty)
        #expect(fixture.terminationOrder.values.isEmpty)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("tunnel recovery uses 1, 3, 10 second delays and at most three launches")
    @MainActor
    func tunnelRecoveryUsesBoundedBackoff() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, false, false, false, false, false, false],
            harnessSequence: [.ready],
            tunnelTimeout: .nanoseconds(1)
        )
        try await fixture.coordinator.start()

        await fixture.coordinator.retry()

        #expect(fixture.sleeper.recorded.filter { $0 >= .seconds(1) && $0 != .seconds(5) } == [
            .seconds(1), .seconds(3), .seconds(10)
        ])
        #expect(fixture.launcher.commands == [
            fixture.tunnelCommand, fixture.tunnelCommand, fixture.tunnelCommand
        ])
        #expect(fixture.coordinator.status == .failed(.tunnelUnavailable))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("recovery never launches another tunnel while a timed-out owned child remains")
    @MainActor
    func recoveryRetainsTimedOutTunnelAndStopsLaunching() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, false, false, false],
            harnessSequence: [.ready],
            processStops: [false, true],
            tunnelTimeout: .nanoseconds(1)
        )
        try await fixture.coordinator.start()

        await fixture.coordinator.retry()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.tunnelHandle.isRunning)
        #expect(fixture.coordinator.status == .failed(.tunnelUnavailable))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("replacing a disappeared external tunnel changes ownership to App-owned")
    @MainActor
    func externalTunnelReplacementBecomesOwned() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, false, false, true],
            harnessSequence: [.ready]
        )
        try await fixture.coordinator.start()
        #expect(fixture.coordinator.ownsTunnel == false)

        await fixture.coordinator.retry()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.status == .ready)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("owned Harness does not block recovery of its owned tunnel")
    @MainActor
    func ownedHarnessAllowsTunnelRecovery() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, false, false, true],
            harnessSequence: [.free, .ready]
        )
        try await fixture.coordinator.start()

        await fixture.coordinator.retry()

        #expect(fixture.launcher.commands == [
            fixture.tunnelCommand, fixture.harnessCommand, fixture.tunnelCommand
        ])
        #expect(fixture.coordinator.ownsTunnel)
        #expect(fixture.coordinator.ownsHarness)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("exited recovery child attaches to an external tunnel race winner")
    @MainActor
    func exitedRecoveryChildDoesNotClaimExternalWinner() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, false, false, true],
            harnessSequence: [.ready],
            tunnelStartsRunning: false
        )
        try await fixture.coordinator.start()

        await fixture.coordinator.retry()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel == false)
        _ = await fixture.coordinator.shutdown()
        #expect(fixture.tunnelHandle.terminateCount == 0)
    }

    @Test("delayed callback from an old PID cannot clear its replacement")
    @MainActor
    func delayedOldTerminationCallbackUsesLaunchIdentity() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, false, false, true],
            harnessSequence: [.ready],
            tunnelFiresCallbackOnTerminate: false,
            replacementTunnelPID: 101
        )
        try await fixture.coordinator.start()

        await fixture.coordinator.retry()
        #expect(fixture.coordinator.ownsTunnel)
        fixture.tunnelHandle.fireTerminationCallback()
        for _ in 0..<4 { await Task.yield() }

        #expect(fixture.coordinator.ownsTunnel)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("running tunnel retained after startup timeout blocks sequential restart")
    @MainActor
    func startAfterTunnelTimeoutDoesNotReplaceOwnedChild() async {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, false, false],
            harnessSequence: [.ready],
            tunnelTimeout: .nanoseconds(1)
        )
        _ = try? await fixture.coordinator.start()

        _ = try? await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.tunnelCommand])
        #expect(fixture.coordinator.ownsTunnel)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("running Harness retained after startup timeout blocks sequential restart")
    @MainActor
    func startAfterHarnessTimeoutDoesNotReplaceOwnedChild() async {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true, true],
            harnessSequence: [.free, .free, .free],
            harnessTimeout: .nanoseconds(1)
        )
        _ = try? await fixture.coordinator.start()

        _ = try? await fixture.coordinator.start()

        #expect(fixture.launcher.commands == [fixture.harnessCommand])
        #expect(fixture.coordinator.ownsHarness)
        _ = await fixture.coordinator.shutdown()
    }

    @Test("timed-out shutdown remains failed and blocks restart from forgetting child")
    @MainActor
    func startAfterTimedOutShutdownRetainsOwnedChild() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, true, true],
            harnessSequence: [.free, .ready, .ready],
            processStops: [true, false]
        )
        try await fixture.coordinator.start()
        let report = await fixture.coordinator.shutdown()

        _ = try? await fixture.coordinator.start()

        #expect(report.timedOutPIDs == [202])
        #expect(fixture.coordinator.ownsHarness)
        #expect(fixture.coordinator.status == .failed(.shutdownTimedOut([202])))
        #expect(fixture.launcher.commands == [fixture.tunnelCommand, fixture.harnessCommand])
    }

    @Test("tunnel deadline includes check duration and starts no boundary check")
    @MainActor
    func tunnelDeadlineIncludesCheckDuration() async {
        let fixture = CoordinatorFixture(
            tunnelSequence: [false, false, true],
            harnessSequence: [.ready],
            tunnelTimeout: .seconds(15),
            tunnelCheckDurations: [.zero, .seconds(15), .zero]
        )

        _ = try? await fixture.coordinator.start()

        #expect(await fixture.portProbe.tunnelProbeCount == 2)
        #expect(fixture.coordinator.status == .failed(.tunnelStartupTimedOut))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("Harness deadline includes describe duration and starts no boundary check")
    @MainActor
    func harnessDeadlineIncludesCheckDuration() async {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.free, .free, .ready],
            harnessTimeout: .seconds(30),
            describeDurations: [.seconds(30), .zero]
        )

        _ = try? await fixture.coordinator.start()

        #expect(fixture.api.describeCount == 1)
        #expect(fixture.coordinator.status == .failed(.harnessStartupTimedOut))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("system timing cancels a check at its monotonic deadline")
    func systemTimingBoundsCheck() async {
        let timing = SystemCoordinatorTiming()
        let clock = ContinuousClock()
        let started = clock.now
        let gate = AsyncGate()

        let result = await timing.run(until: timing.now() + .milliseconds(20)) {
            await gate.arriveAndWait()
            return true
        }
        await gate.releaseAll()

        #expect(result == false)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test("system timing rejects true completed after deadline when timer callback is late")
    func systemTimingRejectsLateOperationWinner() async {
        let operationGate = AsyncGate()
        let timerGate = AsyncGate()
        let control = InjectedTimingControl()
        let timing = SystemCoordinatorTiming(
            now: control.now,
            sleeper: { _ in await timerGate.arriveAndWait() }
        )
        let run = Task {
            await timing.run(until: .seconds(10)) {
                await operationGate.arriveAndWait()
                return true
            }
        }
        await operationGate.waitForArrivals(1)
        await timerGate.waitForArrivals(1)

        control.advance(to: .seconds(11))
        await operationGate.releaseAll()
        let result = await run.value
        await timerGate.releaseAll()

        #expect(result == false)
    }

    @Test("ready state schedules the production five-second monitor cadence")
    @MainActor
    func readySchedulesMonitor() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.ready]
        )

        try await fixture.coordinator.start()
        for _ in 0..<10 where fixture.sleeper.recorded.contains(.seconds(5)) == false {
            await Task.yield()
        }

        #expect(fixture.sleeper.recorded.contains(.seconds(5)))
        _ = await fixture.coordinator.shutdown()
    }

    @Test("workspace registration canonicalizes through WorkspacePathPolicy")
    @MainActor
    func workspaceRegistrationUsesPathPolicy() async throws {
        let fixture = CoordinatorFixture(
            tunnelSequence: [true],
            harnessSequence: [.ready]
        )
        let paths = WorkspacePathTestFixture.createDirectoryWithSymlink()
        defer { WorkspacePathTestFixture.remove(paths.root) }

        let result = try await fixture.coordinator.createWorkspace(path: paths.symlink)

        #expect(result.created)
        #expect(fixture.api.createdPaths == [paths.project])
    }
}

@MainActor
private final class CoordinatorFixture {
    let endpoints = RuntimeEndpoints(configuration: RemoteDSHConfiguration(
        sshAlias: "model-host",
        sshLocalPort: 43117,
        harnessPort: 43118,
        harnessLauncherPath: "/usr/bin/true",
        displayModelName: "Remote Model"
    ))
    let tunnelCommand = CommandSpec(
        executable: "/usr/bin/ssh",
        arguments: ["model-host"],
        environment: [:]
    )
    let harnessCommand = CommandSpec(
        executable: "/usr/bin/true",
        arguments: [],
        environment: ["REMOTE_DSH_PRODUCT_NAME": "Remote DSH"]
    )
    let terminationOrder = TerminationRecorder()
    let sleeper: FakeSleeper
    let timing: FakeCoordinatorTiming
    let tunnelHandle: FakeProcessHandle
    let harnessHandle: FakeProcessHandle
    let launcher: FakeLauncher
    let api: FakeHarnessAPI
    let portProbe: FakePortProbe
    let coordinator: ProcessCoordinator

    init(
        tunnelSequence: [Bool],
        harnessSequence: [HarnessEndpointState],
        launchFailures: [Error?] = [],
        processStops: [Bool] = [true, true],
        tunnelStartsRunning: Bool = true,
        harnessStartsRunning: Bool = true,
        tunnelTimeout: Duration = .seconds(1),
        harnessTimeout: Duration = .seconds(1),
        tunnelGates: [AsyncGate?] = [],
        tunnelFiresCallbackOnTerminate: Bool = true,
        replacementTunnelPID: Int32 = 102,
        tunnelCheckDurations: [Duration] = [],
        describeDurations: [Duration] = [],
        sleepGate: AsyncGate? = nil,
        waiterEnrollmentGate: WaiterEnrollmentGate? = nil
    ) {
        timing = FakeCoordinatorTiming(sleepGate: sleepGate)
        sleeper = timing.sleeper
        tunnelHandle = FakeProcessHandle(
            pid: 101,
            service: .tunnel,
            stopsOnTerminate: processStops.first ?? true,
            startsRunning: tunnelStartsRunning,
            firesCallbackOnTerminate: tunnelFiresCallbackOnTerminate,
            recorder: terminationOrder
        )
        harnessHandle = FakeProcessHandle(
            pid: 202,
            service: .harness,
            stopsOnTerminate: processStops.dropFirst().first ?? true,
            startsRunning: harnessStartsRunning,
            firesCallbackOnTerminate: true,
            recorder: terminationOrder
        )
        launcher = FakeLauncher(
            tunnelCommand: tunnelCommand,
            harnessCommand: harnessCommand,
            tunnelHandles: [
                tunnelHandle,
                FakeProcessHandle(pid: replacementTunnelPID, service: .tunnel, stopsOnTerminate: true, startsRunning: true, firesCallbackOnTerminate: true, recorder: terminationOrder),
                FakeProcessHandle(pid: 103, service: .tunnel, stopsOnTerminate: true, startsRunning: true, firesCallbackOnTerminate: true, recorder: terminationOrder)
            ],
            harnessHandles: [
                harnessHandle,
                FakeProcessHandle(pid: 203, service: .harness, stopsOnTerminate: true, startsRunning: true, firesCallbackOnTerminate: true, recorder: terminationOrder)
            ],
            failures: launchFailures
        )
        portProbe = FakePortProbe(
            tunnelValues: tunnelSequence,
            harnessStates: harnessSequence,
            tunnelGates: tunnelGates,
            tunnelCheckDurations: tunnelCheckDurations,
            timing: timing
        )
        api = FakeHarnessAPI(
            probe: portProbe,
            describeDurations: describeDurations,
            timing: timing
        )
        coordinator = ProcessCoordinator(
            endpoints: endpoints,
            probe: portProbe,
            api: api,
            launcher: launcher,
            workspacePathPolicy: WorkspacePathPolicy(
                home: FileManager.default.temporaryDirectory.path
            ),
            tunnelCommand: tunnelCommand,
            harnessCommand: harnessCommand,
            pollInterval: .milliseconds(1),
            tunnelTimeout: tunnelTimeout,
            harnessTimeout: harnessTimeout,
            probeTimeout: .milliseconds(7),
            monitorInterval: .seconds(5),
            terminationTimeout: .milliseconds(2),
            retryDelays: [.seconds(1), .seconds(3), .seconds(10)],
            timing: timing,
            sleep: sleeper.sleep
        )
        coordinator.waiterEnrollmentObserver = waiterEnrollmentGate?.observe
    }
}

private enum TestLaunchError: Error { case expected }

private actor FakePortProbe: PortProbing {
    private var tunnelValues: [Bool]
    private var harnessStates: [HarnessEndpointState]
    private var lastTunnel = false
    private var lastHarness: HarnessEndpointState = .free
    private var tunnelGates: [AsyncGate?]
    private var tunnelCheckDurations: [Duration]
    private let timing: FakeCoordinatorTiming
    private(set) var tunnelProbeCount = 0
    private(set) var requestedPorts: [UInt16] = []

    init(
        tunnelValues: [Bool],
        harnessStates: [HarnessEndpointState],
        tunnelGates: [AsyncGate?],
        tunnelCheckDurations: [Duration],
        timing: FakeCoordinatorTiming
    ) {
        self.tunnelValues = tunnelValues
        self.harnessStates = harnessStates
        self.tunnelGates = tunnelGates
        self.tunnelCheckDurations = tunnelCheckDurations
        self.timing = timing
    }

    func isListening(host: String, port: UInt16, timeout: Duration) async -> Bool {
        requestedPorts.append(port)
        if port == 43117 {
            tunnelProbeCount += 1
            if tunnelGates.isEmpty == false, let gate = tunnelGates.removeFirst() {
                await gate.arriveAndWait()
            }
            if tunnelCheckDurations.isEmpty == false {
                timing.advance(by: tunnelCheckDurations.removeFirst())
            }
            if tunnelValues.isEmpty == false { lastTunnel = tunnelValues.removeFirst() }
            return lastTunnel
        }
        if harnessStates.isEmpty == false { lastHarness = harnessStates.removeFirst() }
        return lastHarness != .free
    }

    func consumeHarnessStateForAPI() -> HarnessEndpointState {
        if harnessStates.isEmpty == false { lastHarness = harnessStates.removeFirst() }
        return lastHarness
    }
}

private final class FakeHarnessAPI: HarnessAPI, @unchecked Sendable {
    private let probe: FakePortProbe
    private var describeDurations: [Duration]
    private let timing: FakeCoordinatorTiming
    private(set) var createdPaths: [String] = []
    private(set) var describeCount = 0

    init(probe: FakePortProbe, describeDurations: [Duration], timing: FakeCoordinatorTiming) {
        self.probe = probe
        self.describeDurations = describeDurations
        self.timing = timing
    }

    func describe() async throws -> HostDescription {
        describeCount += 1
        if describeDurations.isEmpty == false { timing.advance(by: describeDurations.removeFirst()) }
        guard await probe.consumeHarnessStateForAPI() == .ready else { throw TestLaunchError.expected }
        return HostDescription(
            version: "test",
            cwd: FileManager.default.temporaryDirectory.path,
            provider: nil,
            model: "Remote Model",
            attachedSessions: 0,
            home: FileManager.default.temporaryDirectory.path,
            canOpenPath: true
        )
    }

    func createWorkspace(path: String) async throws -> WorkspaceCreateValue {
        createdPaths.append(path)
        return WorkspaceCreateValue(
            workspace: WorkspaceView(
                workspaceId: "w1", path: path, title: "test", sessionIds: [],
                createdAt: "now", updatedAt: "now"
            ),
            created: true
        )
    }
}

private final class FakeLauncher: ProcessLaunching, @unchecked Sendable {
    private let tunnelCommand: CommandSpec
    private let harnessCommand: CommandSpec
    private var tunnelHandles: [FakeProcessHandle]
    private var harnessHandles: [FakeProcessHandle]
    private var failures: [Error?]
    private(set) var commands: [CommandSpec] = []

    init(
        tunnelCommand: CommandSpec,
        harnessCommand: CommandSpec,
        tunnelHandles: [FakeProcessHandle],
        harnessHandles: [FakeProcessHandle],
        failures: [Error?]
    ) {
        self.tunnelCommand = tunnelCommand
        self.harnessCommand = harnessCommand
        self.tunnelHandles = tunnelHandles
        self.harnessHandles = harnessHandles
        self.failures = failures
    }

    func launch(
        _ command: CommandSpec,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ManagedProcessHandle {
        commands.append(command)
        if failures.isEmpty == false, let failure = failures.removeFirst() { throw failure }
        let handle: FakeProcessHandle
        if command == tunnelCommand {
            handle = tunnelHandles.removeFirst()
        } else {
            #expect(command == harnessCommand)
            handle = harnessHandles.removeFirst()
        }
        handle.onTermination = onTermination
        return handle
    }
}

private final class FakeProcessHandle: ManagedProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32
    private let service: OwnedService
    private let stopsOnTerminate: Bool
    private let firesCallbackOnTerminate: Bool
    private let recorder: TerminationRecorder
    private var running: Bool
    private var terminations = 0
    var onTermination: (@Sendable (Int32) -> Void)?

    init(
        pid: Int32,
        service: OwnedService,
        stopsOnTerminate: Bool,
        startsRunning: Bool,
        firesCallbackOnTerminate: Bool,
        recorder: TerminationRecorder
    ) {
        processIdentifier = pid
        self.service = service
        self.stopsOnTerminate = stopsOnTerminate
        self.firesCallbackOnTerminate = firesCallbackOnTerminate
        running = startsRunning
        self.recorder = recorder
    }

    var isRunning: Bool { running }
    var terminateCount: Int { terminations }

    func terminate() {
        terminations += 1
        recorder.append(service)
        guard stopsOnTerminate else { return }
        running = false
        if firesCallbackOnTerminate { fireTerminationCallback() }
    }

    func fireTerminationCallback() { onTermination?(processIdentifier) }

    func simulateUnexpectedExit() {
        running = false
        fireTerminationCallback()
    }

    func sanitizedDiagnostic() -> String { "fake" }
}

private actor AsyncGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForArrivals(_ count: Int) async {
        while arrivals < count { await Task.yield() }
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class TerminationRecorder: @unchecked Sendable {
    private var storage: [OwnedService] = []
    var values: [OwnedService] { storage }
    func append(_ value: OwnedService) { storage.append(value) }
}

private final class FakeSleeper: @unchecked Sendable {
    private var storage: [Duration] = []
    private var oneShotGate: AsyncGate?
    var recorded: [Duration] { storage }

    init(oneShotGate: AsyncGate? = nil) { self.oneShotGate = oneShotGate }

    func sleep(for duration: Duration) async throws {
        storage.append(duration)
        if duration == .seconds(5) {
            try await Task.sleep(for: .seconds(3_600))
        } else if let gate = oneShotGate {
            oneShotGate = nil
            await gate.arriveAndWait()
        }
    }
}

private final class FakeCoordinatorTiming: CoordinatorTiming, @unchecked Sendable {
    let sleeper: FakeSleeper
    private var current = Duration.zero

    init(sleepGate: AsyncGate? = nil) {
        sleeper = FakeSleeper(oneShotGate: sleepGate)
    }

    func now() -> Duration { current }

    func sleep(for duration: Duration) async throws {
        try await sleeper.sleep(for: duration)
        current += duration
    }

    func run(
        until deadline: Duration,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard current < deadline else { return false }
        let result = await operation()
        return current <= deadline ? result : false
    }

    func advance(by duration: Duration) { current += duration }
}

@MainActor
private func capturedStartFailure(_ coordinator: ProcessCoordinator) async -> CoordinatorFailure? {
    do {
        try await coordinator.start()
        return nil
    } catch let failure as CoordinatorFailure {
        return failure
    } catch {
        return nil
    }
}

private actor TaskCompletionFlag {
    private var completed = false
    var value: Bool { completed }
    func markCompleted() { completed = true }
}

@MainActor
private final class WaiterEnrollmentGate {
    private let expected: CoordinatorJoinOperation
    private var enrolled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: CoordinatorJoinOperation) {
        self.expected = expected
    }

    func observe(_ operation: CoordinatorJoinOperation) {
        #expect(operation == expected)
        enrolled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        guard enrolled == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class InjectedTimingControl: @unchecked Sendable {
    private var current = Duration.zero
    func now() -> Duration { current }
    func advance(to value: Duration) { current = value }
}
