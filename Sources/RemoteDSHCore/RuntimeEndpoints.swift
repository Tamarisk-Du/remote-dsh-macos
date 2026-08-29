import Foundation

public struct RuntimeEndpoints: Equatable, Sendable {
    public let host: String
    public let sshLocalPort: UInt16
    public let harnessPort: UInt16
    public let harnessBaseURL: URL

    public init(configuration: RemoteDSHConfiguration) {
        host = "127.0.0.1"
        sshLocalPort = configuration.sshLocalPort
        harnessPort = configuration.harnessPort
        harnessBaseURL = URL(string: "http://127.0.0.1:\(configuration.harnessPort)/")!
    }
}
