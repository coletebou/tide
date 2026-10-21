import Foundation
import Testing
@testable import TideSSH

/// Keys ssh-keygen writes now, so no private key lives in the repository.
struct SSHUserKeyTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tide-keys-\(UUID().uuidString)")

    /// The public key Tide derives from the private one must be the one in
    /// ssh-keygen's .pub file, and the stored form must read back the same.
    @Test(arguments: ["ed25519", "ecdsa:256", "ecdsa:384", "ecdsa:521"])
    func readsKeysThatSSHKeygenWrote(kind: String) throws {
        let parts = kind.split(separator: ":").map(String.init)
        let path = try sshKeygen(["-t", parts[0], "-N", ""] + (parts.count > 1 ? ["-b", parts[1]] : []), name: kind.replacingOccurrences(of: ":", with: "-"), in: directory)
        let key = try SSHUserKey(openSSHPrivateKey: String(contentsOfFile: path, encoding: .utf8))
        let published = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        #expect(KnownHosts.split(openSSHKey: key.publicKeyLine)?.keyType == KnownHosts.split(openSSHKey: published)?.keyType)
        #expect(KnownHosts.split(openSSHKey: key.publicKeyLine)?.key == KnownHosts.split(openSSHKey: published)?.key)
        let restored = try SSHUserKey(kind: key.kind, rawRepresentation: key.rawRepresentation)
        #expect(restored.publicKeyLine == key.publicKeyLine)
    }

    @Test func refusesKeysItCannotUse() throws {
        let encrypted = try sshKeygen(["-t", "ed25519", "-N", "a passphrase"], name: "encrypted", in: directory)
        #expect(throws: SSHKeyError.encrypted) { try SSHUserKey(openSSHPrivateKey: String(contentsOfFile: encrypted, encoding: .utf8)) }
        let rsa = try sshKeygen(["-t", "rsa", "-b", "2048", "-N", ""], name: "rsa", in: directory)
        #expect(throws: SSHKeyError.unsupported("ssh-rsa")) { try SSHUserKey(openSSHPrivateKey: String(contentsOfFile: rsa, encoding: .utf8)) }
        #expect(throws: SSHKeyError.notOpenSSH) { try SSHUserKey(openSSHPrivateKey: "ssh-ed25519 AAAA not a private key") }
        let text = try String(contentsOfFile: try sshKeygen(["-t", "ed25519", "-N", ""], name: "cut", in: directory), encoding: .utf8)
        let lines = text.split(separator: "\n")
        let truncated = ([lines[0], lines[1]] + [lines[lines.count - 1]]).joined(separator: "\n")
        #expect(throws: SSHKeyError.self) { try SSHUserKey(openSSHPrivateKey: truncated) }
    }

    @Test func generatesEd25519KeysForAuthorizedKeys() {
        let key = SSHUserKey.generateEd25519()
        #expect(key.typeName == "ED25519")
        #expect(key.publicKeyLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
    }
}
