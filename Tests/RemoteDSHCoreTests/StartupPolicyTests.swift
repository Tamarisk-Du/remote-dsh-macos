import Foundation
import RemoteDSHCore
import Testing

@Suite("StartupPolicyTests")
struct StartupPolicyTests {
    @Test("missing configuration stops before command preparation")
    func missingConfigurationStopsBeforeCommands() {
        let configURL = URL(fileURLWithPath: "/var/empty/remote-dsh/config.plist")
        let calls = FactoryCallRecorder()

        let result = StartupPolicy.prepare(
            configURL: configURL,
            homeDirectory: URL(fileURLWithPath: "/var/empty/remote-dsh-home"),
            user: "example",
            temporaryDirectory: "/var/empty/remote-dsh-tmp",
            sshAuthSock: nil,
            tunnelFactory: calls.tunnel,
            harnessFactory: calls.harness
        )

        #expect(calls.tunnelCalls == 0)
        #expect(calls.harnessCalls == 0)
        guard case .failure(.missingFile(configURL)) = result else {
            Issue.record("missing configuration must stop before process preparation")
            return
        }
    }

    @Test("invalid configuration stops before command preparation")
    func invalidConfigurationStopsBeforeCommands() throws {
        let fixture = try StartupPolicyFixture()
        defer { fixture.remove() }
        try fixture.writeConfiguration(sshAlias: "invalid alias")
        let calls = FactoryCallRecorder()

        let result = StartupPolicy.prepare(
            configURL: fixture.configurationURL,
            homeDirectory: fixture.home,
            user: "example",
            temporaryDirectory: fixture.temporaryDirectory.path,
            sshAuthSock: "/var/empty/remote-dsh-agent.sock",
            tunnelFactory: calls.tunnel,
            harnessFactory: calls.harness
        )

        #expect(calls.tunnelCalls == 0)
        #expect(calls.harnessCalls == 0)
        #expect(result == .failure(.invalidSSHAlias))
    }

    @Test("valid configuration prepares configured endpoints and commands once")
    func validConfigurationPreparesRuntimeOnce() throws {
        let fixture = try StartupPolicyFixture()
        defer { fixture.remove() }
        try fixture.writeConfiguration(
            sshAlias: "model-host",
            sshLocalPort: 43116,
            harnessPort: 43117,
            displayModelName: "Remote Model"
        )
        let calls = FactoryCallRecorder()

        let result = StartupPolicy.prepare(
            configURL: fixture.configurationURL,
            homeDirectory: fixture.home,
            user: "example",
            temporaryDirectory: fixture.temporaryDirectory.path,
            sshAuthSock: "/var/empty/remote-dsh-agent.sock",
            tunnelFactory: calls.tunnel,
            harnessFactory: calls.harness
        )

        #expect(calls.tunnelCalls == 1)
        #expect(calls.harnessCalls == 1)
        guard case .success(let runtime) = result else {
            Issue.record("valid configuration must prepare the runtime")
            return
        }
        #expect(runtime.configuration.sshAlias == "model-host")
        #expect(runtime.configuration.displayModelName == "Remote Model")
        #expect(runtime.endpoints.host == "127.0.0.1")
        #expect(runtime.endpoints.sshLocalPort == 43116)
        #expect(runtime.endpoints.harnessPort == 43117)
        #expect(runtime.endpoints.harnessBaseURL == URL(string: "http://127.0.0.1:43117/")!)
        #expect(runtime.tunnelCommand == FactoryCallRecorder.tunnelCommand)
        #expect(runtime.harnessCommand == FactoryCallRecorder.harnessCommand)
    }

    @Test("configuration failure presentation keeps context and redacts credentials")
    func configurationFailurePresentationIsSafe() {
        let path = "/var/empty/remote-dsh/config.plist"
        let presentation = ConfigurationFailurePresentation(
            path: path,
            field: "sshAlias",
            detail: "Authorization: " + "Bearer " + "do-not-display"
        )

        #expect(presentation.title == "Remote DSH for macOS needs configuration")
        #expect(presentation.detail.contains(path))
        #expect(presentation.detail.contains("sshAlias"))
        #expect(presentation.detail.contains("do-not-display") == false)
    }
}

private final class FactoryCallRecorder: @unchecked Sendable {
    static let tunnelCommand = CommandSpec(
        executable: "/usr/bin/false",
        arguments: ["tunnel"],
        environment: [:]
    )
    static let harnessCommand = CommandSpec(
        executable: "/usr/bin/false",
        arguments: ["harness"],
        environment: [:]
    )

    private let lock = NSLock()
    private var tunnelCount = 0
    private var harnessCount = 0

    var tunnelCalls: Int { lock.withLock { tunnelCount } }
    var harnessCalls: Int { lock.withLock { harnessCount } }

    func tunnel(
        configuration: RemoteDSHConfiguration,
        home: String,
        user: String,
        temporaryDirectory: String,
        sshAuthSock: String?
    ) -> CommandSpec {
        lock.withLock { tunnelCount += 1 }
        return Self.tunnelCommand
    }

    func harness(
        configuration: RemoteDSHConfiguration,
        home: String,
        user: String,
        temporaryDirectory: String
    ) -> CommandSpec {
        lock.withLock { harnessCount += 1 }
        return Self.harnessCommand
    }
}

private struct StartupPolicyFixture {
    let root: URL
    let home: URL
    let launcher: URL
    let configurationURL: URL
    let temporaryDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RemoteDSHStartupPolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        launcher = home.appending(path: ".local/bin/remote-dsh-launcher")
        configurationURL = root.appending(path: "config.plist")
        temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: launcher.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    }

    func writeConfiguration(
        sshAlias: String,
        sshLocalPort: Int = 43116,
        harnessPort: Int = 43117,
        displayModelName: String? = nil
    ) throws {
        var plist: [String: Any] = [
            "sshAlias": sshAlias,
            "sshLocalPort": sshLocalPort,
            "harnessPort": harnessPort,
            "harnessLauncherPath": launcher.path
        ]
        if let displayModelName {
            plist["displayModelName"] = displayModelName
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: configurationURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
