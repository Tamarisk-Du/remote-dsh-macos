import Darwin
import Foundation

enum ScanError: Error {
    case unsupportedText(String)
    case denylistMatch(String)
    case patternMatch(String, String)
}

func report(_ error: ScanError) {
    let message: String
    switch error {
    case let .unsupportedText(path):
        message = "PUBLIC_TREE_FAIL rule=utf8 entry=\(path)"
    case let .denylistMatch(path):
        message = "PUBLIC_TREE_FAIL rule=denylist entry=\(path)"
    case let .patternMatch(rule, path):
        message = "PUBLIC_TREE_FAIL rule=\(rule) entry=\(path)"
    }
    fputs("\(message)\n", stderr)
}

func matches(_ pattern: String, in text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

let arguments = CommandLine.arguments
guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "path") else {
    fputs("PUBLIC_TREE_FAIL rule=arguments\n", stderr)
    exit(2)
}

let displayPath = arguments[1]
let contentPath = arguments[2]
let denylistPath = arguments[3]
let contentIsPath = arguments.count == 5

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: contentPath), options: .mappedIfSafe)
    guard let text = String(data: data, encoding: .utf8) else {
        throw ScanError.unsupportedText(displayPath)
    }

    let denylist = try String(contentsOfFile: denylistPath, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    for value in denylist where !value.isEmpty {
        if text.localizedCaseInsensitiveContains(value) || displayPath.localizedCaseInsensitiveContains(value) {
            throw ScanError.denylistMatch(displayPath)
        }
    }

    let privateArtifactComponents = [
        "." + "super" + "powers",
        "docs/" + "live-",
        "live-" + "acceptance",
        "." + "remote-dsh-" + "backups",
        "." + "session",
        "." + "workspace"
    ]
    for component in privateArtifactComponents
    where displayPath.localizedCaseInsensitiveContains(component)
        || (contentIsPath && text.localizedCaseInsensitiveContains(component)) {
        throw ScanError.patternMatch("private-artifact", displayPath)
    }

    let absoluteHomePath = #"/(?:Users|home)/[[:alnum:]_.-]+"#
    let credentialAssignment = #"(?i)\b(?:api[_-]?key|password|secret|token|credential)\s*[:=]\s*(?!example(?:[-_a-z0-9]*)?\b)(?!<[^>]*>)[\"']?[A-Za-z0-9._~+/=-]{8,}"#
    let bearerAuthorization = #"(?i)\b(?:authorization\s*:\s*)?bearer\s+(?!do-not-display(?![A-Za-z0-9._~+/=-]))[A-Za-z0-9._~+/=-]{8,}"#
    let cookieValue = #"(?i)\b(?:cookie|set-cookie)\s*[:=]\s*[^;\s]{8,}"#
    let pemHeader = "-----" + "BEGIN " + "PRIVATE " + "KEY" + "-----"
    let rules = [
        ("absolute-home-path", absoluteHomePath),
        ("credential-assignment", credentialAssignment),
        ("bearer-authorization", bearerAuthorization),
        ("private-key", pemHeader),
        ("cookie", cookieValue)
    ]
    for (rule, pattern) in rules where matches(pattern, in: text) {
        throw ScanError.patternMatch(rule, displayPath)
    }
} catch let error as ScanError {
    report(error)
    exit(1)
} catch {
    fputs("PUBLIC_TREE_FAIL rule=scan-error entry=\(displayPath)\n", stderr)
    exit(1)
}
