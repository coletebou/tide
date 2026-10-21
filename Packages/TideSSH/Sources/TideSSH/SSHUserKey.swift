import CryptoKit
import Foundation
import NIOSSH

/// A key Tide can log in with: Ed25519 or NIST ECDSA, the kinds SwiftNIO SSH
/// signs with. RSA is not among them, and a SHA-1 `ssh-rsa` signature is one
/// OpenSSH 8.8 and later refuse anyway.
public enum SSHUserKey: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    /// A new Ed25519 key, the kind `ssh-keygen` makes by default.
    public static func generateEd25519() -> SSHUserKey {
        .ed25519(Curve25519.Signing.PrivateKey())
    }

    var nioKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): NIOSSHPrivateKey(p521Key: key)
        }
    }

    /// The public key as one authorized_keys line: "ssh-ed25519 AAAA...".
    public var publicKeyLine: String {
        String(openSSHPublicKey: nioKey.publicKey)
    }

    /// "ED25519" or "ECDSA", as ssh names key types in its messages.
    public var typeName: String {
        switch self {
        case .ed25519: "ED25519"
        case .p256, .p384, .p521: "ECDSA"
        }
    }

    /// The key's kind and private bytes, to keep it somewhere safe such as
    /// the Keychain; `init(kind:rawRepresentation:)` reads them back.
    public var kind: String {
        switch self {
        case .ed25519: "ed25519"
        case .p256: "p256"
        case .p384: "p384"
        case .p521: "p521"
        }
    }

    public var rawRepresentation: Data {
        switch self {
        case .ed25519(let key): key.rawRepresentation
        case .p256(let key): key.rawRepresentation
        case .p384(let key): key.rawRepresentation
        case .p521(let key): key.rawRepresentation
        }
    }

    public init(kind: String, rawRepresentation raw: Data) throws {
        switch kind {
        case "ed25519": self = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case "p256": self = .p256(try P256.Signing.PrivateKey(rawRepresentation: raw))
        case "p384": self = .p384(try P384.Signing.PrivateKey(rawRepresentation: raw))
        case "p521": self = .p521(try P521.Signing.PrivateKey(rawRepresentation: raw))
        default: throw SSHKeyError.unsupported(kind)
        }
    }

    /// The first line of an OpenSSH private key file.
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"

    /// Reads an OpenSSH private key, as `ssh-keygen` writes it, if it has no
    /// passphrase.
    public init(openSSHPrivateKey text: String) throws {
        let body = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard text.contains(Self.pemHeader), let data = Data(base64Encoded: body) else { throw SSHKeyError.notOpenSSH }
        var reader = SSHWireReader(data)
        guard try reader.bytes(15) == Array("openssh-key-v1\u{0}".utf8) else { throw SSHKeyError.notOpenSSH }
        let cipher = try reader.text()
        _ = try reader.text() // KDF name
        _ = try reader.string() // KDF options
        guard cipher == "none" else { throw SSHKeyError.encrypted }
        guard try reader.uint32() == 1 else { throw SSHKeyError.unsupported("files with more than one key") }
        let publicBlob = try reader.string()
        var secrets = SSHWireReader(Data(try reader.string()))
        // Two equal check numbers: a wrong passphrase or a damaged file breaks them.
        let check = try secrets.uint32()
        guard try secrets.uint32() == check else { throw SSHKeyError.corrupt }
        let type = try secrets.text()
        switch type {
        case "ssh-ed25519":
            _ = try secrets.string() // public key
            let secret = try secrets.string() // seed, then public key
            guard secret.count == 64 else { throw SSHKeyError.corrupt }
            self = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret.prefix(32))))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try secrets.text() // curve name
            _ = try secrets.string() // public point
            let scalar = try secrets.mpint()
            switch type {
            case "ecdsa-sha2-nistp256": self = .p256(try P256.Signing.PrivateKey(rawRepresentation: Self.padded(scalar, to: 32)))
            case "ecdsa-sha2-nistp384": self = .p384(try P384.Signing.PrivateKey(rawRepresentation: Self.padded(scalar, to: 48)))
            default: self = .p521(try P521.Signing.PrivateKey(rawRepresentation: Self.padded(scalar, to: 66)))
            }
        default:
            throw SSHKeyError.unsupported(type)
        }
        // The private half must belong to the public key the file lists.
        guard let listed = KnownHosts.split(openSSHKey: publicKeyLine)?.key, Data(base64Encoded: listed) == Data(publicBlob) else { throw SSHKeyError.corrupt }
    }

    /// A big-endian scalar at exactly `length` bytes: an mpint drops leading
    /// zeros and may add one to keep the sign bit clear.
    private static func padded(_ bytes: [UInt8], to length: Int) throws -> Data {
        let trimmed = bytes.drop { $0 == 0 }
        guard trimmed.count <= length else { throw SSHKeyError.corrupt }
        return Data(repeating: 0, count: length - trimmed.count) + Data(trimmed)
    }
}

public enum SSHKeyError: Error, Equatable, LocalizedError {
    case notOpenSSH
    case encrypted
    case unsupported(String)
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .notOpenSSH:
            "This is not an OpenSSH private key. Tide reads keys that begin with \(SSHUserKey.pemHeader)."
        case .encrypted:
            "This key is protected by a passphrase, which Tide cannot read yet. Copy it without one (ssh-keygen -p -N '' -f <file> on a copy), or create a key in Tide."
        case .unsupported("ssh-rsa"):
            "Tide cannot log in with RSA keys. Use an Ed25519 or ECDSA key; ssh-keygen -t ed25519 makes one."
        case .unsupported(let what):
            "Tide cannot use \(what)."
        case .corrupt:
            "This key file is damaged: its parts do not fit together."
        }
    }
}

/// Reads SSH wire types: big-endian uint32, length-prefixed strings, mpints.
struct SSHWireReader {
    private var storage: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        storage = Array(data)
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= storage.count else { throw SSHKeyError.corrupt }
        defer { offset += count }
        return Array(storage[offset..<(offset + count)])
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws -> [UInt8] {
        try bytes(Int(try uint32()))
    }

    mutating func text() throws -> String {
        String(decoding: try string(), as: UTF8.self)
    }

    mutating func mpint() throws -> [UInt8] {
        try string()
    }
}
