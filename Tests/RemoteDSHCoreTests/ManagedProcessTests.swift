import Testing
@testable import RemoteDSHCore

@Suite("Foundation process launcher", .serialized)
struct ManagedProcessTests {
    @Test("drains both pipes, calls back, caps output, and sanitizes diagnostics")
    func drainsAndSanitizesDiagnostics() async throws {
        let signal = ProcessTerminationSignal()
        let command = CommandSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/yes x | /usr/bin/head -c 200000; "
                    + "printf 'REMOTE_MODEL_API_KEY=secret\\n' >&2"
            ],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: "/tmp"
        )

        let handle = try FoundationProcessLauncher().launch(command) { pid in
            Task { await signal.finish(pid: pid) }
        }
        let timing = SystemCoordinatorTiming()
        let completed = await timing.run(until: timing.now() + .seconds(2)) {
            await signal.wait()
            return true
        }

        #expect(completed)
        #expect(await signal.pid == handle.processIdentifier)
        #expect(handle.isRunning == false)
        let diagnostic = handle.sanitizedDiagnostic()
        #expect(diagnostic.count <= 4_000)
        #expect(diagnostic.contains("secret") == false)
        #expect(diagnostic.contains("[REDACTED]"))
    }

    @Test("terminate targets the retained exact child and invokes its callback")
    func terminatesRetainedChild() async throws {
        let signal = ProcessTerminationSignal()
        let command = CommandSpec(
            executable: "/bin/sleep",
            arguments: ["30"],
            environment: [:]
        )

        let handle = try FoundationProcessLauncher().launch(command) { pid in
            Task { await signal.finish(pid: pid) }
        }
        #expect(handle.isRunning)
        handle.terminate()
        let timing = SystemCoordinatorTiming()
        let completed = await timing.run(until: timing.now() + .seconds(2)) {
            await signal.wait()
            return true
        }

        #expect(completed)
        #expect(await signal.pid == handle.processIdentifier)
        #expect(handle.isRunning == false)
    }
}

private actor ProcessTerminationSignal {
    private var finishedPID: Int32?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pid: Int32? { finishedPID }

    func finish(pid: Int32) {
        guard finishedPID == nil else { return }
        finishedPID = pid
        let current = continuations
        continuations.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if finishedPID != nil { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
