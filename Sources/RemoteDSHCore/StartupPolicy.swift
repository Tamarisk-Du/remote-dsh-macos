import Foundation

public typealias TunnelFactory = @Sendable (
    RemoteDSHConfiguration,
    String,
    String,
    String,
    String?
) -> CommandSpec

public typealias HarnessFactory = @Sendable (
    RemoteDSHConfiguration,
    String,
    String,
    String
) -> CommandSpec

public struct PreparedRuntime: Equatable, Sendable {
    public let configuration: RemoteDSHConfiguration
    public let endpoints: RuntimeEndpoints
    public let tunnelCommand: CommandSpec
    public let harnessCommand: CommandSpec

    public init(
        configuration: RemoteDSHConfiguration,
        endpoints: RuntimeEndpoints,
        tunnelCommand: CommandSpec,
        harnessCommand: CommandSpec
    ) {
        self.configuration = configuration
        self.endpoints = endpoints
        self.tunnelCommand = tunnelCommand
        self.harnessCommand = harnessCommand
    }
}

public enum StartupPolicy {
    public static func prepare(
        configURL: URL,
        homeDirectory: URL,
        user: String,
        temporaryDirectory: String,
        sshAuthSock: String?,
        loader: RemoteDSHConfigurationLoader = .init(),
        tunnelFactory: TunnelFactory,
        harnessFactory: HarnessFactory
    ) -> Result<PreparedRuntime, RemoteDSHConfigurationError> {
        do {
            let configuration = try loader.load(
                from: configURL,
                homeDirectory: homeDirectory
            )
            let endpoints = RuntimeEndpoints(configuration: configuration)
            let home = homeDirectory.path
            let tunnelCommand = tunnelFactory(
                configuration,
                home,
                user,
                temporaryDirectory,
                sshAuthSock
            )
            let harnessCommand = harnessFactory(
                configuration,
                home,
                user,
                temporaryDirectory
            )
            return .success(PreparedRuntime(
                configuration: configuration,
                endpoints: endpoints,
                tunnelCommand: tunnelCommand,
                harnessCommand: harnessCommand
            ))
        } catch let error as RemoteDSHConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.invalidPlist)
        }
    }
}

public struct ConfigurationFailurePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(path: String, field: String, detail: String) {
        title = "Remote DSH for macOS needs configuration"
        self.detail = "Configuration: \(path)\nField: \(field)\n\(DiagnosticSanitizer.clean(detail))"
    }
}
