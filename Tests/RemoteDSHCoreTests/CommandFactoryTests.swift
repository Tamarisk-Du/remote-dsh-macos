import RemoteDSHCore
import Testing

@Suite("CommandFactoryTests")
struct CommandFactoryTests {
    @Test("tunnel command keeps the validated alias as one final operand")
    func tunnelCommandIsFixed() {
        let configuration = configuration(sshAlias: "model-host")

        let command = CommandFactory.tunnel(
            configuration: configuration,
            home: "/var/empty/example-home",
            user: "example",
            temporaryDirectory: "/private/tmp/example/",
            sshAuthSock: "/private/tmp/ssh-agent.sock"
        )

        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "model-host"
        ])
        #expect(command.environment == [
            "HOME": "/var/empty/example-home",
            "USER": "example",
            "LOGNAME": "example",
            "SHELL": "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp/example/",
            "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock"
        ])
        #expect(command.currentDirectory == nil)
    }

    @Test("option-shaped text inside an alias is never split into an SSH option")
    func aliasTextRemainsOneOperand() {
        let command = CommandFactory.tunnel(
            configuration: configuration(sshAlias: "model-host-oProxyCommand"),
            home: "/var/empty/example-home",
            user: "example",
            temporaryDirectory: "/private/tmp/example/"
        )

        #expect(command.arguments == [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "model-host-oProxyCommand"
        ])
    }

    @Test("harness uses the validated launcher and only the allowed environment")
    func harnessCommandUsesConfiguration() {
        let command = CommandFactory.harness(
            configuration: configuration(),
            home: "/var/empty/example-home",
            user: "example",
            temporaryDirectory: "/private/tmp/example/"
        )

        #expect(command.executable == "/opt/remote-dsh/bin/launcher")
        #expect(command.arguments.isEmpty)
        #expect(command.environment == [
            "HOME": "/var/empty/example-home",
            "USER": "example",
            "LOGNAME": "example",
            "SHELL": "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp/example/",
            "DEEPSEEK_HARNESS_NO_OPEN": "1"
        ])
        #expect(command.currentDirectory == nil)
    }

    private func configuration(sshAlias: String = "model-host") -> RemoteDSHConfiguration {
        RemoteDSHConfiguration(
            sshAlias: sshAlias,
            sshLocalPort: 43116,
            harnessPort: 43117,
            harnessLauncherPath: "/opt/remote-dsh/bin/launcher",
            displayModelName: nil
        )
    }
}
