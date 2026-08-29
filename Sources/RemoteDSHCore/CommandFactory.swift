import Foundation

public struct CommandSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: String?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public enum CommandFactory {
    private static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func tunnel(
        configuration: RemoteDSHConfiguration,
        home: String,
        user: String,
        temporaryDirectory: String,
        sshAuthSock: String? = nil
    ) -> CommandSpec {
        CommandSpec(
            executable: "/usr/bin/ssh",
            arguments: [
                "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                configuration.sshAlias
            ],
            environment: allowlistedEnvironment(
                home: home,
                user: user,
                temporaryDirectory: temporaryDirectory,
                sshAuthSock: sshAuthSock
            )
        )
    }

    public static func harness(
        configuration: RemoteDSHConfiguration,
        home: String,
        user: String,
        temporaryDirectory: String
    ) -> CommandSpec {
        var environment = allowlistedEnvironment(
            home: home,
            user: user,
            temporaryDirectory: temporaryDirectory,
            sshAuthSock: nil
        )
        environment["DEEPSEEK_HARNESS_NO_OPEN"] = "1"
        return CommandSpec(
            executable: configuration.harnessLauncherPath,
            arguments: [],
            environment: environment
        )
    }

    private static func allowlistedEnvironment(
        home: String,
        user: String,
        temporaryDirectory: String,
        sshAuthSock: String?
    ) -> [String: String] {
        var environment = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "SHELL": "/bin/zsh",
            "PATH": path,
            "TMPDIR": temporaryDirectory
        ]
        if let sshAuthSock {
            environment["SSH_AUTH_SOCK"] = sshAuthSock
        }
        return environment
    }
}
