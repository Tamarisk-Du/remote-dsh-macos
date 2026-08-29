import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ATOMIC_INSTALL_FAIL \(message)\n".utf8))
    exit(1)
}

private func standardizedAbsolutePath(_ rawPath: String, role: String) -> String {
    guard rawPath.hasPrefix("/") else {
        fail("rule=absolute-path role=\(role)")
    }
    return URL(fileURLWithPath: rawPath).standardizedFileURL.path
}

private func fileStatus(_ path: String) -> stat? {
    var value = stat()
    let result = path.withCString { lstat($0, &value) }
    if result == 0 {
        return value
    }
    if errno == ENOENT {
        return nil
    }
    fail("rule=inspect-path")
}

private func requireRealDirectory(_ path: String, role: String) -> stat {
    guard let value = fileStatus(path) else {
        fail("rule=missing-directory role=\(role)")
    }
    guard value.st_mode & S_IFMT == S_IFDIR else {
        fail("rule=real-directory role=\(role)")
    }
    return value
}

private func renamePath(_ source: String, to destination: String) -> Int32 {
    source.withCString { sourcePath in
        destination.withCString { destinationPath in
            rename(sourcePath, destinationPath)
        }
    }
}

private func swapPaths(_ first: String, _ second: String) -> Int32 {
    first.withCString { firstPath in
        second.withCString { secondPath in
            renameatx_np(
                AT_FDCWD,
                firstPath,
                AT_FDCWD,
                secondPath,
                UInt32(RENAME_SWAP)
            )
        }
    }
}

guard CommandLine.arguments.count == 4 else {
    fail("rule=arguments usage='AtomicBundleInstall CANDIDATE.app DESTINATION.app BACKUP_DIRECTORY'")
}

let candidate = standardizedAbsolutePath(CommandLine.arguments[1], role: "candidate")
let destination = standardizedAbsolutePath(CommandLine.arguments[2], role: "destination")
let backupDirectory = standardizedAbsolutePath(CommandLine.arguments[3], role: "backup-directory")
let candidateParent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
let destinationParent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
let backupParent = URL(fileURLWithPath: backupDirectory).deletingLastPathComponent().path

guard candidate != destination, candidateParent == destinationParent else {
    fail("rule=sibling-candidate")
}
guard backupParent == destinationParent,
      URL(fileURLWithPath: backupDirectory).lastPathComponent == ".remote-dsh-backups" else {
    fail("rule=backup-directory")
}

let parentStatus = requireRealDirectory(destinationParent, role: "destination-parent")
let candidateStatus = requireRealDirectory(candidate, role: "candidate")
let backupStatus = requireRealDirectory(backupDirectory, role: "backup-directory")
guard candidateStatus.st_dev == parentStatus.st_dev,
      backupStatus.st_dev == parentStatus.st_dev else {
    fail("rule=same-filesystem")
}

guard let destinationStatus = fileStatus(destination) else {
    guard renamePath(candidate, to: destination) == 0 else {
        fail("rule=atomic-rename errno=\(errno)")
    }
    print("ATOMIC_INSTALL_PASS action=renamed")
    exit(0)
}

guard destinationStatus.st_mode & S_IFMT == S_IFDIR else {
    fail("rule=real-directory role=destination")
}
guard destinationStatus.st_dev == candidateStatus.st_dev else {
    fail("rule=same-filesystem")
}

let destinationName = URL(fileURLWithPath: destination).lastPathComponent
var backupPath: String?
for sequence in 0..<10_000 {
    let proposed = URL(fileURLWithPath: backupDirectory)
        .appendingPathComponent("\(destinationName).before-install.\(getpid()).\(sequence)")
        .path
    if fileStatus(proposed) == nil {
        backupPath = proposed
        break
    }
}
guard let backupPath else {
    fail("rule=backup-name-exhausted")
}

guard swapPaths(candidate, destination) == 0 else {
    fail("rule=atomic-swap errno=\(errno)")
}

if renamePath(candidate, to: backupPath) != 0 {
    let archiveErrno = errno
    guard swapPaths(candidate, destination) == 0 else {
        fail("rule=rollback-failed archive-errno=\(archiveErrno) rollback-errno=\(errno)")
    }
    fail("rule=backup-archive target-restored=true errno=\(archiveErrno)")
}

print("ATOMIC_INSTALL_PASS action=swapped backup=\(backupPath)")
