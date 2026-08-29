import Foundation

public struct HostDescription: Decodable, Equatable, Sendable {
    public let version: String
    public let cwd: String
    public let provider: String?
    public let model: String?
    public let attachedSessions: Int
    public let home: String
    public let canOpenPath: Bool

    @_spi(RemoteDSHTesting)
    public init(
        version: String,
        cwd: String,
        provider: String?,
        model: String?,
        attachedSessions: Int,
        home: String,
        canOpenPath: Bool
    ) {
        self.version = version
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.attachedSessions = attachedSessions
        self.home = home
        self.canOpenPath = canOpenPath
    }
}

public struct WorkspaceView: Decodable, Equatable, Sendable {
    public let workspaceId: String
    public let path: String
    public let title: String
    public let sessionIds: [String]
    public let createdAt: String
    public let updatedAt: String

    @_spi(RemoteDSHTesting)
    public init(
        workspaceId: String,
        path: String,
        title: String,
        sessionIds: [String],
        createdAt: String,
        updatedAt: String
    ) {
        self.workspaceId = workspaceId
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceCreateValue: Decodable, Equatable, Sendable {
    public let workspace: WorkspaceView
    public let created: Bool

    @_spi(RemoteDSHTesting)
    public init(workspace: WorkspaceView, created: Bool) {
        self.workspace = workspace
        self.created = created
    }
}

public protocol HarnessAPI: Sendable {
    func describe() async throws -> HostDescription
    func createWorkspace(path: String) async throws -> WorkspaceCreateValue
}

public enum HarnessClientError: Error, Equatable, Sendable {
    case invalidHTTPStatus(Int)
    case unexpectedResponseURL
    case invalidResponse
    case rpcIDMismatch
    case rpcFailure
}

public final class HarnessClient: HarnessAPI, @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 10

    private let baseURL: URL
    private let session: URLSession
    private let redirectDelegate: RedirectRejectingSessionDelegate?
    private let rpcID: @Sendable () -> String

    public init(
        baseURL: URL,
        session: URLSession? = nil,
        rpcID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.baseURL = baseURL
        self.rpcID = rpcID
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let redirectDelegate = RedirectRejectingSessionDelegate()
            self.redirectDelegate = redirectDelegate
            self.session = Self.redirectRejectingSession(delegate: redirectDelegate)
        }
    }

    public func describe() async throws -> HostDescription {
        try await call(method: "host.describe", payload: EmptyPayload(), as: HostDescription.self)
    }

    public func createWorkspace(path: String) async throws -> WorkspaceCreateValue {
        try await call(
            method: "workspace.create",
            payload: WorkspaceCreatePayload(path: path),
            as: WorkspaceCreateValue.self
        )
    }

    private static func redirectRejectingSession(
        delegate: RedirectRejectingSessionDelegate
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func call<Payload: Encodable, Value: Decodable>(
        method: String,
        payload: Payload,
        as: Value.Type
    ) async throws -> Value {
        let id = rpcID()
        let body = ClientRequest(rpcID: id, method: method, payload: payload)
        let requestURL = baseURL.appending(path: "api/\(method)")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HarnessClientError.invalidHTTPStatus(-1)
        }
        guard Self.sameOrigin(response.url, baseURL) else {
            throw HarnessClientError.unexpectedResponseURL
        }
        guard (200...299).contains(response.statusCode) else {
            throw HarnessClientError.invalidHTTPStatus(response.statusCode)
        }

        let envelope: ServerResponse<Value>
        do {
            envelope = try JSONDecoder().decode(ServerResponse<Value>.self, from: data)
        } catch {
            throw HarnessClientError.invalidResponse
        }
        guard envelope.type == "server-response" else {
            throw HarnessClientError.invalidResponse
        }
        guard envelope.rpcID == id else {
            throw HarnessClientError.rpcIDMismatch
        }
        guard envelope.result.ok, let value = envelope.result.value else {
            throw HarnessClientError.rpcFailure
        }
        return value
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.user == nil
            && lhs.password == nil
            && rhs.user == nil
            && rhs.password == nil
    }

    private struct EmptyPayload: Encodable {}
    private struct WorkspaceCreatePayload: Encodable { let path: String }

    private struct ClientRequest<Payload: Encodable>: Encodable {
        let type = "client-request"
        let rpcID: String
        let method: String
        let payload: Payload

        enum CodingKeys: String, CodingKey {
            case type
            case rpcID = "rpcId"
            case method
            case payload
        }
    }

    private struct ServerResponse<Value: Decodable>: Decodable {
        let type: String
        let rpcID: String
        let result: Result

        enum CodingKeys: String, CodingKey {
            case type
            case rpcID = "rpcId"
            case result
        }

        struct Result: Decodable {
            let ok: Bool
            let value: Value?
        }
    }
}

private final class RedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
