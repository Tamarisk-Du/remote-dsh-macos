import Foundation
import RemoteDSHCore
import Testing

@Suite("RemoteDSHConfigurationTests")
struct RemoteDSHConfigurationTests {
    @Test("valid neutral configuration decodes and expands leading tilde")
    func validConfiguration() throws {
        let fixture = try ConfigurationFixture()
        let plist: [String: Any] = [
            "sshAlias": "model-host",
            "sshLocalPort": 18080,
            "harnessPort": 3080,
            "harnessLauncherPath": "~/.local/bin/remote-dsh-launcher",
            "displayModelName": "Remote Model",
            "futureKey": "ignored"
        ]

        let result = try fixture.load(plist)

        #expect(result.sshAlias == "model-host")
        #expect(result.sshLocalPort == 18080)
        #expect(result.harnessPort == 3080)
        #expect(result.harnessLauncherPath == fixture.launcher.path)
        #expect(result.displayModelName == "Remote Model")
    }

    @Test("missing configuration file is rejected")
    func missingConfigurationFile() throws {
        let fixture = try ConfigurationFixture()
        try expectError(.missingFile(fixture.configurationURL)) {
            try RemoteDSHConfigurationLoader().load(
                from: fixture.configurationURL,
                homeDirectory: fixture.home
            )
        }
    }

    @Test(arguments: ["", "-host", "host name", String(repeating: "a", count: 129)])
    func invalidAliasesAreRejected(alias: String) throws {
        let fixture = try ConfigurationFixture()
        try expectError(.invalidSSHAlias) {
            try fixture.load(["sshAlias": alias])
        }
    }

    @Test(arguments: [0, 65536])
    func invalidSSHLocalPortsAreRejected(port: Int) throws {
        let fixture = try ConfigurationFixture()
        try expectError(.invalidSSHLocalPort) {
            try fixture.load(["sshLocalPort": port])
        }
    }

    @Test(arguments: [0, 65536])
    func invalidHarnessPortsAreRejected(port: Int) throws {
        let fixture = try ConfigurationFixture()
        try expectError(.invalidHarnessPort) {
            try fixture.load(["harnessPort": port])
        }
    }

    @Test("identical ports are rejected")
    func identicalPortsAreRejected() throws {
        let fixture = try ConfigurationFixture()
        try expectError(.identicalPorts) {
            try fixture.load(["harnessPort": 18080])
        }
    }

    @Test("relative launcher path without a leading tilde is rejected")
    func relativeLauncherIsRejected() throws {
        let fixture = try ConfigurationFixture()
        try expectError(.invalidLauncherPath) {
            try fixture.load(["harnessLauncherPath": "bin/remote-dsh-launcher"])
        }
    }

    @Test("home directory is not a launcher")
    func homeDirectoryIsRejected() throws {
        let fixture = try ConfigurationFixture()
        try expectError(.launcherIsHomeDirectory) {
            try fixture.load(["harnessLauncherPath": fixture.home.path])
        }
    }

    @Test("launcher directory is rejected")
    func launcherDirectoryIsRejected() throws {
        let fixture = try ConfigurationFixture()
        try expectError(.launcherIsNotRegularFile) {
            try fixture.load(["harnessLauncherPath": fixture.home.appending(path: "bin").path])
        }
    }

    @Test("non-executable launcher is rejected")
    func nonExecutableLauncherIsRejected() throws {
        let fixture = try ConfigurationFixture()
        let nonExecutable = fixture.home.appending(path: "non-executable")
        FileManager.default.createFile(atPath: nonExecutable.path, contents: Data())
        try expectError(.launcherIsNotExecutable) {
            try fixture.load(["harnessLauncherPath": nonExecutable.path])
        }
    }

    @Test("absolute executable launcher is accepted")
    func absoluteExecutableLauncherIsAccepted() throws {
        let fixture = try ConfigurationFixture()
        let result = try fixture.load(["harnessLauncherPath": fixture.launcher.path])
        #expect(result.harnessLauncherPath == fixture.launcher.path)
    }

    @Test("runtime endpoints use only configured ports")
    func runtimeEndpointsUseConfiguredPorts() {
        let configuration = RemoteDSHConfiguration(
            sshAlias: "model-host",
            sshLocalPort: 19000,
            harnessPort: 3900,
            harnessLauncherPath: "/tmp/remote-dsh-launcher",
            displayModelName: nil
        )
        let endpoints = RuntimeEndpoints(configuration: configuration)

        #expect(endpoints.host == "127.0.0.1")
        #expect(endpoints.sshLocalPort == 19000)
        #expect(endpoints.harnessPort == 3900)
        #expect(endpoints.harnessBaseURL == URL(string: "http://127.0.0.1:3900/")!)
    }

    private func expectError(
        _ expected: RemoteDSHConfigurationError,
        operation: () throws -> Any
    ) throws {
        do {
            _ = try operation()
            Issue.record("Expected \(expected)")
        } catch let error as RemoteDSHConfigurationError {
            #expect(error == expected)
        }
    }
}

private struct ConfigurationFixture {
    let root: URL
    let home: URL
    let launcher: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RemoteDSHConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        launcher = home.appending(path: ".local/bin/remote-dsh-launcher")

        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: launcher.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    }

    var configurationURL: URL {
        root.appending(path: "config.plist")
    }

    func load(_ overrides: [String: Any] = [:]) throws -> RemoteDSHConfiguration {
        var plist: [String: Any] = [
            "sshAlias": "model-host",
            "sshLocalPort": 18080,
            "harnessPort": 3080,
            "harnessLauncherPath": "~/.local/bin/remote-dsh-launcher"
        ]
        overrides.forEach { plist[$0.key] = $0.value }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: configurationURL)
        return try RemoteDSHConfigurationLoader().load(from: configurationURL, homeDirectory: home)
    }
}
