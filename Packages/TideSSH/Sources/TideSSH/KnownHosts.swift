import CryptoKit
import Foundation

/// The host keys a user trusts, in OpenSSH's known_hosts format. Tide reads
/// what OpenSSH writes (host patterns, hashed host names, `@revoked` and
/// `@cert-authority` markers, comments) and adds plain entries, so the file
/// means the same thing to `ssh` on a Mac.
public struct KnownHosts: Equatable, Sendable {
    /// What the file says about a host's key.
    public enum Verdict: Equatable, Sendable {
        /// The file lists this key for the host.
        case trusted
        /// The file lists no key of this type for the host.
        case unknown
        /// The file lists a different key of this type for the host, by these
        /// fingerprints: the host was reinstalled, or someone is in between.
        case changed(known: [String])
        /// The file marks this key as revoked.
        case revoked
    }

    private struct Entry: Equatable, Sendable {
        var marker: String?
        var hosts: String
        var keyType: String
        var key: String
    }

    /// The file's text, with any entries added since it was read.
    public private(set) var text: String
    private var entries: [Entry]

    public init(_ text: String = "") {
        self.text = text
        entries = text.split(whereSeparator: \.isNewline).compactMap { Self.parse(String($0)) }
    }

    /// What the file says about `key` (base64, as known_hosts writes it), of
    /// type `keyType`, presented by `host` on `port`. Checked as OpenSSH does:
    /// a revoked key loses, a listed key wins, and another key of the same
    /// type means the key changed.
    public func verdict(host: String, port: Int, keyType: String, key: String) -> Verdict {
        let name = Self.name(host: host, port: port)
        let matching = entries.filter { Self.matches(name, $0.hosts) }
        if matching.contains(where: { $0.marker == "@revoked" && $0.key == key }) { return .revoked }
        let plain = matching.filter { $0.marker == nil && $0.keyType == keyType }
        if plain.contains(where: { $0.key == key }) { return .trusted }
        return plain.isEmpty ? .unknown : .changed(known: plain.map { Self.fingerprint($0.key) ?? $0.key })
    }

    /// Trusts `key` for the host from now on.
    public mutating func add(host: String, port: Int, keyType: String, key: String) {
        let name = Self.name(host: host, port: port)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\(name) \(keyType) \(key)\n"
        entries.append(Entry(marker: nil, hosts: name, keyType: keyType, key: key))
    }

    /// Forgets the host's keys: its hashed lines, and its name in plain lines,
    /// dropping a line it was the only name on. Wildcard patterns, which may
    /// stand for other hosts too, stay, and so do `@revoked` and
    /// `@cert-authority` lines, as `ssh-keygen -R` keeps them.
    public mutating func remove(host: String, port: Int) {
        let name = Self.name(host: host, port: port)
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let entry = Self.parse(line), entry.marker == nil else {
                kept.append(line)
                continue
            }
            if entry.hosts.hasPrefix("|1|") {
                if !Self.hashedMatches(name, entry.hosts) { kept.append(line) }
                continue
            }
            let patterns = entry.hosts.split(separator: ",").map(String.init)
            let others = patterns.filter { $0.lowercased() != name }
            if others.count == patterns.count {
                kept.append(line)
            } else if !others.isEmpty, let range = line.range(of: entry.hosts) {
                kept.append(line.replacingCharacters(in: range, with: others.joined(separator: ",")))
            }
        }
        text = kept.joined(separator: "\n")
        entries = text.split(whereSeparator: \.isNewline).compactMap { Self.parse(String($0)) }
    }

    /// The host as known_hosts names it: bare on port 22, else `[host]:port`.
    /// OpenSSH lowercases host names before it looks them up.
    public static func name(host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    /// OpenSSH's fingerprint of a base64 key blob: "SHA256:" and the digest
    /// in base64 without padding, as `ssh-keygen -l` prints it.
    public static func fingerprint(_ key: String) -> String? {
        guard let blob = Data(base64Encoded: key) else { return nil }
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// The type and base64 blob of a public key in OpenSSH's one-line form,
    /// "ssh-ed25519 AAAA... comment".
    public static func split(openSSHKey: String) -> (keyType: String, key: String)? {
        let fields = openSSHKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        return (String(fields[0]), String(fields[1]))
    }

    private static func parse(_ line: String) -> Entry? {
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = fields.first, !first.hasPrefix("#") else { return nil }
        var marker: String?
        if first.hasPrefix("@") {
            marker = first
            fields.removeFirst()
        }
        guard fields.count >= 3 else { return nil }
        return Entry(marker: marker, hosts: fields[0], keyType: fields[1], key: fields[2])
    }

    /// Whether a host field names `name`: a hashed name, or comma-separated
    /// patterns where `*` and `?` are wildcards and a `!` pattern excludes.
    private static func matches(_ name: String, _ field: String) -> Bool {
        if field.hasPrefix("|1|") { return hashedMatches(name, field) }
        var matched = false
        for pattern in field.split(separator: ",") {
            if pattern.hasPrefix("!") {
                if wildcard(String(pattern.dropFirst()), matches: name) { return false }
            } else if wildcard(String(pattern), matches: name) {
                matched = true
            }
        }
        return matched
    }

    /// `|1|salt|hash`, where the hash is HMAC-SHA1 of the name keyed by the salt.
    private static func hashedMatches(_ name: String, _ field: String) -> Bool {
        let parts = field.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let salt = Data(base64Encoded: String(parts[2])), let hash = Data(base64Encoded: String(parts[3])) else { return false }
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
        return Data(code) == hash
    }

    private static func wildcard(_ pattern: String, matches name: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let name = Array(name.lowercased())
        var p = 0
        var n = 0
        var star: Int?
        var resume = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1
                n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                resume = n
                p += 1
            } else if let star {
                p = star + 1
                resume += 1
                n = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
