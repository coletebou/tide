import Foundation

/// Where to connect, as typed into Remote-SSH: Connect to Host...:
/// `user@host`, with a port when it is not 22 (`user@host:2222`,
/// `user@[::1]:2222`), optionally as an `ssh://` URL.
public struct SSHTarget: Hashable, Sendable, CustomStringConvertible {
    public var user: String
    public var host: String
    public var port: Int

    public init(user: String, host: String, port: Int = 22) {
        self.user = user
        self.host = host
        self.port = port
    }

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.lowercased().hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        // The last @ separates the user, which may itself contain one.
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let user = String(rest[..<at])
        var host = rest[rest.index(after: at)...]
        var port = 22
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") {
                guard let number = Int(after.dropFirst()) else { return nil }
                port = number
            } else if !after.isEmpty {
                return nil
            }
            host = host[host.index(after: host.startIndex)..<close]
        } else if let colon = host.firstIndex(of: ":"), colon == host.lastIndex(of: ":") {
            // One colon is a port; more is an IPv6 address without brackets.
            guard let number = Int(host[host.index(after: colon)...]) else { return nil }
            port = number
            host = host[..<colon]
        }
        guard !user.isEmpty, !host.isEmpty, !host.contains(where: \.isWhitespace), (1...65535).contains(port) else { return nil }
        self.init(user: user, host: String(host), port: port)
    }

    /// `user@host`, with the port when it is not 22.
    public var description: String {
        let host = self.host.contains(":") ? "[\(self.host)]" : self.host
        return port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }
}
