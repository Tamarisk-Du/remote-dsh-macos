import Foundation
import Network

public protocol PortProbing: Sendable {
    func isListening(host: String, port: UInt16, timeout: Duration) async -> Bool
}

public struct TCPPortProbe: PortProbing, Sendable {
    public init() {}

    public func isListening(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        let completion = ProbeCompletion()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            completion.finish(false, cancelling: connection)
        }

        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        completion.finish(true, cancelling: connection)
                    case .failed, .cancelled:
                        completion.finish(false, cancelling: connection)
                    default:
                        break
                    }
                }
                if completion.isFinished {
                    connection.cancel()
                } else {
                    connection.start(queue: DispatchQueue(label: "TCPPortProbe"))
                }
            }
        }, onCancel: {
            completion.finish(false, cancelling: connection)
        })

        timeoutTask.cancel()
        connection.cancel()
        return result
    }
}

private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Bool, cancelling connection: NWConnection) {
        connection.cancel()
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
