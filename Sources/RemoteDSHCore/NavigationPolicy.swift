import Darwin
import Foundation

public enum NavigationDestination: Equatable, Sendable {
    case embedded
    case externalBrowser
    case reject
}

public enum NavigationPolicy {
    public static func destination(for url: URL, allowedOrigin: URL) -> NavigationDestination {
        if url.absoluteString == "about:blank" {
            return .embedded
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil else {
            return .reject
        }

        if host == "127.0.0.1" {
            return matchesAllowedOrigin(url, allowedOrigin: allowedOrigin) ? .embedded : .reject
        }

        let classificationHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard isLoopbackHost(classificationHost) == false else {
            return .reject
        }
        return .externalBrowser
    }

    private static func matchesAllowedOrigin(_ url: URL, allowedOrigin: URL) -> Bool {
        guard allowedOrigin.host == "127.0.0.1",
              let allowedScheme = allowedOrigin.scheme?.lowercased(),
              allowedScheme == "http",
              allowedOrigin.port != nil,
              allowedOrigin.user == nil,
              allowedOrigin.password == nil else {
            return false
        }
        return url.scheme?.lowercased() == allowedScheme
            && url.host == allowedOrigin.host
            && url.port == allowedOrigin.port
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if let address = legacyIPv4Address(host), address >> 24 == 127 {
            return true
        }

        var address = in6_addr()
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let isIPv6Loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isMappedIPv4Loopback = bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
            && bytes[12] == 127
        let isCompatibleIPv4Loopback = bytes[0..<12].allSatisfy { $0 == 0 }
            && bytes[12] == 127
        return isIPv6Loopback || isMappedIPv4Loopback || isCompatibleIPv4Loopback
    }

    private static func legacyIPv4Address(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let values = parts.compactMap(parseIPv4Component)
        guard values.count == parts.count else { return nil }

        let address: UInt64
        switch values.count {
        case 1 where values[0] <= 0xffff_ffff:
            address = values[0]
        case 2 where values[0] <= 0xff && values[1] <= 0xff_ffff:
            address = values[0] << 24 | values[1]
        case 3 where values[0] <= 0xff && values[1] <= 0xff && values[2] <= 0xffff:
            address = values[0] << 24 | values[1] << 16 | values[2]
        case 4 where values.allSatisfy({ $0 <= 0xff }):
            address = values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3]
        default:
            return nil
        }
        return UInt32(address)
    }

    private static func parseIPv4Component(_ component: Substring) -> UInt64? {
        guard component.isEmpty == false else { return nil }
        if component.hasPrefix("0x") || component.hasPrefix("0X") {
            let digits = component.dropFirst(2)
            return digits.isEmpty ? nil : UInt64(digits, radix: 16)
        }
        if component.count > 1, component.first == "0" {
            return UInt64(component.dropFirst(), radix: 8)
        }
        return UInt64(component, radix: 10)
    }
}
