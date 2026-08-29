import Foundation

public enum WorkspacePathError: Error, Equatable, Sendable {
    case notDirectory
    case homeDirectoryRejected
}

public struct WorkspacePathPolicy: Sendable {
    public let home: String

    public init(home: String) {
        self.home = URL(fileURLWithPath: home)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    public func canonicalProjectPath(_ rawPath: String) throws -> String {
        let url = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspacePathError.notDirectory
        }
        guard url.path != home else {
            throw WorkspacePathError.homeDirectoryRejected
        }
        return url.path
    }
}
