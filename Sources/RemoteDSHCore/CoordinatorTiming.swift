import Foundation

public protocol CoordinatorTiming: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
    func run(
        until deadline: Duration,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool
}

public struct SystemCoordinatorTiming: CoordinatorTiming, Sendable {
    private let nowProvider: @Sendable () -> Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    public init() {
        let clock = ContinuousClock()
        let origin = clock.now
        nowProvider = { origin.duration(to: clock.now) }
        sleeper = { duration in try await clock.sleep(for: duration) }
    }

    @_spi(RemoteDSHTesting)
    public init(
        now: @escaping @Sendable () -> Duration,
        sleeper: @escaping @Sendable (Duration) async throws -> Void
    ) {
        nowProvider = now
        self.sleeper = sleeper
    }

    public func now() -> Duration {
        nowProvider()
    }

    public func sleep(for duration: Duration) async throws {
        try await sleeper(duration)
    }

    public func run(
        until deadline: Duration,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let remaining = deadline - now()
        guard remaining > .zero else { return false }

        let race = FirstBoolResult()
        let operationTask = Task {
            let result = await operation()
            race.finish(result && now() < deadline)
        }
        let timeoutTask = Task {
            do {
                try await sleeper(remaining)
                race.finish(false)
            } catch {
                return
            }
        }
        let result = await withTaskCancellationHandler(operation: {
            await race.value()
        }, onCancel: {
            race.finish(false)
        })
        operationTask.cancel()
        timeoutTask.cancel()
        return result
    }
}

private final class FirstBoolResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private struct ClosureCoordinatorTiming: CoordinatorTiming, Sendable {
    private let system = SystemCoordinatorTiming()
    private let sleeper: @Sendable (Duration) async throws -> Void

    init(sleeper: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleeper = sleeper
    }

    func now() -> Duration { system.now() }

    func sleep(for duration: Duration) async throws {
        try await sleeper(duration)
    }

    func run(
        until deadline: Duration,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await system.run(until: deadline, operation: operation)
    }
}

func makeClosureCoordinatorTiming(
    _ sleeper: @escaping @Sendable (Duration) async throws -> Void
) -> any CoordinatorTiming {
    ClosureCoordinatorTiming(sleeper: sleeper)
}
