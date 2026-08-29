import Foundation
import Network
import RemoteDSHCore

struct WorkspacePathTestFixture: Sendable {
    let root: String
    let home: String
    let project: String
    let symlink: String

    static func createDirectoryWithSymlink() -> WorkspacePathTestFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RemoteDSHCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        let symlink = root.appending(path: "project-link")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: project)
        return WorkspacePathTestFixture(
            root: root.path,
            home: home.path,
            project: project.path,
            symlink: symlink.path
        )
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

final class LoopbackListenerFixture: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let cancellation: ListenerCancellation

    private init(listener: NWListener, port: UInt16, cancellation: ListenerCancellation) {
        self.listener = listener
        self.port = port
        self.cancellation = cancellation
    }

    static func started() async throws -> LoopbackListenerFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let startup = ListenerStartup()
        let cancellation = ListenerCancellation()
        listener.newConnectionHandler = { connection in
            connection.cancel()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.succeed(port: listener.port?.rawValue)
            case .failed(let error):
                startup.fail(error)
            case .cancelled:
                startup.fail(URLError(.cancelled))
                cancellation.markCancelled()
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "RemoteDSHLoopbackListenerFixture"))
        let port = try await startup.value()
        return LoopbackListenerFixture(listener: listener, port: port, cancellation: cancellation)
    }

    func cancel() {
        listener.cancel()
    }

    func waitUntilCancelled() async {
        await cancellation.wait()
    }
}

private final class ListenerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?

    func value() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed(port: UInt16?) {
        guard let port else {
            fail(URLError(.cannotConnectToHost))
            return
        }
        finish(.success(port))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class ListenerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markCancelled() {
        lock.lock()
        guard cancelled == false else {
            lock.unlock()
            return
        }
        cancelled = true
        let continuations = continuations
        self.continuations = []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
