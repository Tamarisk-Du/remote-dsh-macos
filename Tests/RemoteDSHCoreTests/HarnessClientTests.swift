import Foundation
import Network
import RemoteDSHCore
import Testing

@Suite("HarnessClientTests", .serialized)
struct HarnessClientTests {
    @Test("describe posts the RPC envelope to the configured base URL")
    func describeUsesConfiguredBaseURL() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:43117/api/host.describe")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let envelope = try #require(request.rpcEnvelope)
            #expect(envelope["type"] as? String == "client-request")
            #expect(envelope["rpcId"] as? String == "fixed-id")
            #expect(envelope["method"] as? String == "host.describe")
            #expect((envelope["payload"] as? [String: Any])?.isEmpty == true)
            return StubResponse(statusCode: 200, body: Self.hostResponse(rpcID: "fixed-id"))
        }

        let value = try await client(rpcID: { "fixed-id" }).describe()

        #expect(value.version == "1.0.0")
        #expect(value.cwd == "/var/tmp")
    }

    @Test("workspace creation preserves the configured origin and requested path")
    func createWorkspaceUsesConfiguredBaseURL() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:43117/api/workspace.create")
            let envelope = try #require(request.rpcEnvelope)
            #expect(envelope["method"] as? String == "workspace.create")
            let payload = try #require(envelope["payload"] as? [String: Any])
            #expect(payload["path"] as? String == "/var/tmp/project")
            return StubResponse(statusCode: 200, body: Self.workspaceResponse(rpcID: "fixed-id"))
        }

        let value = try await client(rpcID: { "fixed-id" })
            .createWorkspace(path: "/var/tmp/project")

        #expect(value.workspace.workspaceId == "workspace-1")
        #expect(value.created)
    }

    @Test("HTTP failures, mismatched RPC identifiers, and malformed responses are rejected")
    func invalidResponsesAreRejected() async {
        StubURLProtocol.handler = { _ in StubResponse(statusCode: 503, body: "") }
        await #expect(throws: HarnessClientError.invalidHTTPStatus(503)) {
            try await client().describe()
        }

        StubURLProtocol.handler = { _ in
            StubResponse(statusCode: 200, body: Self.hostResponse(rpcID: "other-id"))
        }
        await #expect(throws: HarnessClientError.rpcIDMismatch) {
            try await client(rpcID: { "fixed-id" }).describe()
        }

        StubURLProtocol.handler = { _ in StubResponse(statusCode: 200, body: "{}") }
        await #expect(throws: HarnessClientError.invalidResponse) {
            try await client().describe()
        }
    }

    @Test("a final response URL outside the configured origin is rejected")
    func crossOriginFinalResponseIsRejected() async {
        StubURLProtocol.handler = { _ in
            StubResponse(
                statusCode: 200,
                body: Self.hostResponse(rpcID: "fixed-id"),
                responseURL: URL(string: "http://127.0.0.1:43118/api/host.describe")!
            )
        }

        await #expect(throws: HarnessClientError.unexpectedResponseURL) {
            try await client(rpcID: { "fixed-id" }).describe()
        }
    }

    @Test("default isolated session rejects a real cross-origin loopback redirect")
    func defaultSessionRejectsRealRedirect() async throws {
        let fixture = try await LoopbackRedirectFixture.started()
        defer { fixture.cancel() }
        let client = HarnessClient(baseURL: fixture.baseURL)

        await #expect(throws: HarnessClientError.invalidHTTPStatus(302)) {
            try await client.describe()
        }
        #expect(fixture.redirectTargetRequestCount == 0)
    }

    private func client(
        rpcID: @escaping @Sendable () -> String = { "generated-id" }
    ) -> HarnessClient {
        HarnessClient(
            baseURL: URL(string: "http://127.0.0.1:43117/")!,
            session: StubURLProtocol.session(),
            rpcID: rpcID
        )
    }

    private static func hostResponse(rpcID: String) -> String {
        """
        {"type":"server-response","rpcId":"\(rpcID)","result":{"ok":true,"value":{"version":"1.0.0","cwd":"/var/tmp","attachedSessions":0,"home":"/var/empty/example-home","canOpenPath":true}}}
        """
    }

    private static func workspaceResponse(rpcID: String) -> String {
        """
        {"type":"server-response","rpcId":"\(rpcID)","result":{"ok":true,"value":{"workspace":{"workspaceId":"workspace-1","path":"/var/tmp/project","title":"project","sessionIds":[],"createdAt":"2026-08-29T00:00:00Z","updatedAt":"2026-08-29T00:00:00Z"},"created":true}}}
        """
    }
}

private struct StubResponse: Sendable {
    let statusCode: Int
    let body: String
    let responseURL: URL?

    init(statusCode: Int, body: String, responseURL: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try Self.handler?(request) ?? StubResponse(statusCode: 500, body: "")
            let httpResponse = HTTPURLResponse(
                url: response.responseURL ?? request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private extension URLRequest {
    var rpcEnvelope: [String: Any]? {
        let body: Data?
        if let httpBody {
            body = httpBody
        } else if let httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while httpBodyStream.hasBytesAvailable {
                let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        } else {
            body = nil
        }
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class LoopbackRedirectFixture: @unchecked Sendable {
    let baseURL: URL
    var redirectTargetRequestCount: Int { targetCounter.value }

    private let redirectListener: NWListener
    private let targetListener: NWListener
    private let targetCounter: LockedCounter

    private init(
        baseURL: URL,
        redirectListener: NWListener,
        targetListener: NWListener,
        targetCounter: LockedCounter
    ) {
        self.baseURL = baseURL
        self.redirectListener = redirectListener
        self.targetListener = targetListener
        self.targetCounter = targetCounter
    }

    static func started() async throws -> LoopbackRedirectFixture {
        let queue = DispatchQueue(label: "RemoteDSHLoopbackRedirectFixture")
        let targetCounter = LockedCounter()
        let targetListener = try NWListener(using: loopbackParameters(), on: .any)
        targetListener.newConnectionHandler = { connection in
            targetCounter.increment()
            Self.respond(
                on: connection,
                queue: queue,
                response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            )
        }
        let targetPort = try await start(targetListener, queue: queue)

        let redirectListener = try NWListener(using: loopbackParameters(), on: .any)
        redirectListener.newConnectionHandler = { connection in
            Self.respond(
                on: connection,
                queue: queue,
                response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(targetPort)/redirect-target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
        }
        let redirectPort = try await start(redirectListener, queue: queue)

        return LoopbackRedirectFixture(
            baseURL: URL(string: "http://127.0.0.1:\(redirectPort)/")!,
            redirectListener: redirectListener,
            targetListener: targetListener,
            targetCounter: targetCounter
        )
    }

    func cancel() {
        redirectListener.cancel()
        targetListener.cancel()
    }

    private static func loopbackParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return parameters
    }

    private static func start(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let startup = ListenerStartup()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.finish(.success(listener.port?.rawValue ?? 0))
            case let .failed(error):
                startup.finish(.failure(error))
            case .cancelled:
                startup.finish(.failure(URLError(.cancelled)))
            default:
                break
            }
        }
        listener.start(queue: queue)
        let port = try await startup.value()
        guard port != 0 else { throw URLError(.cannotConnectToHost) }
        return port
    }

    private static func respond(on connection: NWConnection, queue: DispatchQueue, response: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, error in
            guard error == nil else {
                connection.cancel()
                return
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
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

    func finish(_ result: Result<UInt16, Error>) {
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
