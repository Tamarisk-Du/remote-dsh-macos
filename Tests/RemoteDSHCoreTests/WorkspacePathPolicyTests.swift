import Foundation
import RemoteDSHCore
import Testing

@Suite("WorkspacePathPolicyTests")
struct WorkspacePathPolicyTests {
    @Test("the whole canonical home directory is rejected")
    func homeDirectoryIsRejected() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        #expect(throws: WorkspacePathError.homeDirectoryRejected) {
            try WorkspacePathPolicy(home: fixture.home.path)
                .canonicalProjectPath(fixture.home.path)
        }
    }

    @Test("an existing symlinked project directory is canonicalized")
    func symlinkedDirectoryIsCanonicalized() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        let path = try WorkspacePathPolicy(home: fixture.home.path)
            .canonicalProjectPath(fixture.projectLink.path)

        #expect(path == fixture.project.path)
    }

    @Test("missing paths and ordinary files are rejected")
    func nonDirectoriesAreRejected() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        #expect(throws: WorkspacePathError.notDirectory) {
            try WorkspacePathPolicy(home: fixture.home.path)
                .canonicalProjectPath(fixture.root.appending(path: "missing").path)
        }
        #expect(throws: WorkspacePathError.notDirectory) {
            try WorkspacePathPolicy(home: fixture.home.path)
                .canonicalProjectPath(fixture.file.path)
        }
    }
}

private struct WorkspaceFixture {
    let root: URL
    let home: URL
    let project: URL
    let projectLink: URL
    let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RemoteDSHWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        project = root.appending(path: "project", directoryHint: .isDirectory)
        projectLink = root.appending(path: "project-link")
        file = root.appending(path: "ordinary-file")

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projectLink, withDestinationURL: project)
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
