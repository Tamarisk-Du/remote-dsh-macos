import Foundation

public struct RemoteDSHConfiguration: Equatable, Sendable {
    public let sshAlias: String
    public let sshLocalPort: UInt16
    public let harnessPort: UInt16
    public let harnessLauncherPath: String
    public let displayModelName: String?

    public init(
        sshAlias: String,
        sshLocalPort: UInt16,
        harnessPort: UInt16,
        harnessLauncherPath: String,
        displayModelName: String?
    ) {
        self.sshAlias = sshAlias
        self.sshLocalPort = sshLocalPort
        self.harnessPort = harnessPort
        self.harnessLauncherPath = harnessLauncherPath
        self.displayModelName = displayModelName
    }
}

public enum RemoteDSHConfigurationError: Error, Equatable, LocalizedError {
    case missingFile(URL)
    case invalidPlist
    case invalidSSHAlias
    case invalidSSHLocalPort
    case invalidHarnessPort
    case identicalPorts
    case invalidLauncherPath
    case launcherIsHomeDirectory
    case launcherIsNotRegularFile
    case launcherIsNotExecutable

    public var fieldName: String {
        switch self {
        case .missingFile, .invalidPlist:
            "configuration file"
        case .invalidSSHAlias:
            "sshAlias"
        case .invalidSSHLocalPort:
            "sshLocalPort"
        case .invalidHarnessPort:
            "harnessPort"
        case .identicalPorts:
            "sshLocalPort and harnessPort"
        case .invalidLauncherPath, .launcherIsHomeDirectory, .launcherIsNotRegularFile, .launcherIsNotExecutable:
            "harnessLauncherPath"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            "Configuration file is missing: \(url.path)"
        case .invalidPlist:
            "Configuration file is not a valid property list."
        case .invalidSSHAlias:
            "sshAlias must contain 1 to 128 ASCII letters, digits, dots, underscores, or hyphens and cannot start with a hyphen."
        case .invalidSSHLocalPort:
            "sshLocalPort must be between 1 and 65535."
        case .invalidHarnessPort:
            "harnessPort must be between 1 and 65535."
        case .identicalPorts:
            "sshLocalPort and harnessPort must differ."
        case .invalidLauncherPath:
            "harnessLauncherPath must be an absolute path or begin with ~/."
        case .launcherIsHomeDirectory:
            "harnessLauncherPath cannot be the home directory."
        case .launcherIsNotRegularFile:
            "harnessLauncherPath must identify a regular file."
        case .launcherIsNotExecutable:
            "harnessLauncherPath must identify an executable file."
        }
    }
}

public struct RemoteDSHConfigurationLoader {
    private struct Payload: Decodable {
        let sshAlias: String
        let sshLocalPort: Int
        let harnessPort: Int
        let harnessLauncherPath: String
        let displayModelName: String?
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func defaultURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RemoteDSH", isDirectory: true)
            .appendingPathComponent("config.plist", isDirectory: false)
    }

    public func load(from url: URL, homeDirectory: URL) throws -> RemoteDSHConfiguration {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RemoteDSHConfigurationError.missingFile(url)
        }

        let payload = try decodePayload(at: url)
        try validateAlias(payload.sshAlias)
        let sshPort = try validatedPort(payload.sshLocalPort, error: .invalidSSHLocalPort)
        let harnessPort = try validatedPort(payload.harnessPort, error: .invalidHarnessPort)
        guard sshPort != harnessPort else {
            throw RemoteDSHConfigurationError.identicalPorts
        }
        let launcher = try validatedLauncher(payload.harnessLauncherPath, homeDirectory: homeDirectory)

        return RemoteDSHConfiguration(
            sshAlias: payload.sshAlias,
            sshLocalPort: sshPort,
            harnessPort: harnessPort,
            harnessLauncherPath: launcher.path,
            displayModelName: payload.displayModelName
        )
    }

    private func decodePayload(at url: URL) throws -> Payload {
        do {
            return try PropertyListDecoder().decode(Payload.self, from: Data(contentsOf: url))
        } catch {
            throw RemoteDSHConfigurationError.invalidPlist
        }
    }

    private func validateAlias(_ alias: String) throws {
        guard alias.count >= 1, alias.count <= 128, alias.first != "-" else {
            throw RemoteDSHConfigurationError.invalidSSHAlias
        }

        let validCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard alias.unicodeScalars.allSatisfy(validCharacters.contains) else {
            throw RemoteDSHConfigurationError.invalidSSHAlias
        }
    }

    private func validatedPort(
        _ port: Int,
        error: RemoteDSHConfigurationError
    ) throws -> UInt16 {
        guard (1...65535).contains(port) else {
            throw error
        }
        return UInt16(port)
    }

    private func validatedLauncher(_ path: String, homeDirectory: URL) throws -> URL {
        let expandedPath: String
        if path.hasPrefix("~/") {
            expandedPath = homeDirectory.path + String(path.dropFirst())
        } else if path.hasPrefix("/") {
            expandedPath = path
        } else {
            throw RemoteDSHConfigurationError.invalidLauncherPath
        }

        let launcher = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let standardizedHome = homeDirectory.standardizedFileURL
        guard launcher != standardizedHome else {
            throw RemoteDSHConfigurationError.launcherIsHomeDirectory
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: launcher.path)
        } catch {
            throw RemoteDSHConfigurationError.launcherIsNotRegularFile
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RemoteDSHConfigurationError.launcherIsNotRegularFile
        }
        guard fileManager.isExecutableFile(atPath: launcher.path) else {
            throw RemoteDSHConfigurationError.launcherIsNotExecutable
        }
        return launcher
    }
}
