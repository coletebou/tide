import Testing
@testable import TideSSH

// Two Ed25519 keys made with ssh-keygen, with the fingerprints `ssh-keygen -l`
// printed for them, and hashed entries `ssh-keygen -H` wrote for the first. They are
// public keys, so the secret scanner is told to let them through.
private let key = "AAAAC3NzaC1lZDI1NTE5AAAAIJN+o5V5iOgCtr2/ojge9+2IXuCKOoGklVrWL0i3xgh5" // gitleaks:allow
private let keyFingerprint = "SHA256:xEy7v8/ZBVp6/jKpIcSQHe6pDbJSSFALDuQpvaN9Zhk"
private let other = "AAAAC3NzaC1lZDI1NTE5AAAAIB8SRn5sTQCub6otps8eUGL3MH8z2QV11CyF7bRNbrWX" // gitleaks:allow
private let otherFingerprint = "SHA256:M8OzUyO2CKx6Ym9l7s4bJXaZohxkvVn+YFLe+UuOXVo"
private let hashedExample = "|1|oD9DCdVxNySAz+efSheUYdVXFd0=|MS6WAnaWRWEMQUPliLN4Httxc3c="
private let hashedExample2222 = "|1|oghwvkRaOSexvxCq/Cku/PUSay0=|i1bix+A7HzqWeJgac5ESLGZUn38="
private let ed25519 = "ssh-ed25519"

struct KnownHostsTests {
    @Test func fingerprintsAsSSHKeygenDoes() {
        #expect(KnownHosts.fingerprint(key) == keyFingerprint)
        #expect(KnownHosts.fingerprint(other) == otherFingerprint)
        #expect(KnownHosts.fingerprint("not base64!") == nil)
    }

    @Test func namesNonStandardPortsInBrackets() {
        #expect(KnownHosts.name(host: "Example.com", port: 22) == "example.com")
        #expect(KnownHosts.name(host: "127.0.0.1", port: 2222) == "[127.0.0.1]:2222")
    }

    @Test func checksPlainEntries() {
        let hosts = KnownHosts("example.com \(ed25519) \(key)\n[example.com]:2222 \(ed25519) \(other)\n")
        #expect(hosts.verdict(host: "example.com", port: 22, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "EXAMPLE.COM", port: 22, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "example.com", port: 2222, keyType: ed25519, key: other) == .trusted)
        #expect(hosts.verdict(host: "example.com", port: 2222, keyType: ed25519, key: key) == .changed(known: [otherFingerprint]))
        #expect(hosts.verdict(host: "example.org", port: 22, keyType: ed25519, key: key) == .unknown)
        // A known key of another type is not a change: OpenSSH asks, as for a new host.
        #expect(hosts.verdict(host: "example.com", port: 22, keyType: "ecdsa-sha2-nistp256", key: other) == .unknown)
    }

    @Test func readsHashedNamesThatSSHKeygenWrote() {
        let hosts = KnownHosts("\(hashedExample) \(ed25519) \(key)\n\(hashedExample2222) \(ed25519) \(key)\n")
        #expect(hosts.verdict(host: "example.com", port: 22, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "example.com", port: 2222, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "example.com", port: 2200, keyType: ed25519, key: key) == .unknown)
        #expect(hosts.verdict(host: "example.org", port: 22, keyType: ed25519, key: key) == .unknown)
    }

    @Test func honorsWildcardsNegationsAndMarkers() {
        let hosts = KnownHosts("""
        # Fleet hosts
        *.example.com,!bad.example.com \(ed25519) \(key)
        @revoked * \(ed25519) \(other)
        @cert-authority *.corp \(ed25519) \(key)
        build-?.lan \(ed25519) \(key)
        """)
        #expect(hosts.verdict(host: "a.example.com", port: 22, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "bad.example.com", port: 22, keyType: ed25519, key: key) == .unknown)
        #expect(hosts.verdict(host: "a.example.com", port: 22, keyType: ed25519, key: other) == .revoked)
        // A certificate authority's key does not vouch for itself as a host key.
        #expect(hosts.verdict(host: "x.corp", port: 22, keyType: ed25519, key: key) == .unknown)
        #expect(hosts.verdict(host: "build-7.lan", port: 22, keyType: ed25519, key: key) == .trusted)
        #expect(hosts.verdict(host: "build-17.lan", port: 22, keyType: ed25519, key: key) == .unknown)
    }

    @Test func addsAndRemovesEntriesKeepingTheRest() {
        var hosts = KnownHosts("# keep me\nexample.com \(ed25519) \(key)")
        hosts.add(host: "127.0.0.1", port: 2222, keyType: ed25519, key: other)
        #expect(hosts.text == "# keep me\nexample.com \(ed25519) \(key)\n[127.0.0.1]:2222 \(ed25519) \(other)\n")
        #expect(hosts.verdict(host: "127.0.0.1", port: 2222, keyType: ed25519, key: other) == .trusted)
        hosts.remove(host: "example.com", port: 22)
        #expect(hosts.text == "# keep me\n[127.0.0.1]:2222 \(ed25519) \(other)\n")
        #expect(hosts.verdict(host: "example.com", port: 22, keyType: ed25519, key: key) == .unknown)
        #expect(KnownHosts(hosts.text) == hosts)
    }

    /// Forgetting one host must not forget a revocation, or trust that
    /// patterns and other names on its line give other hosts.
    @Test func forgettingAHostKeepsRevocationsPatternsAndOtherNames() {
        let lines = [
            "@revoked * \(ed25519) \(other)",
            "*.example.com \(ed25519) \(key)",
            "a.example.com,b.example.com \(ed25519) \(key)",
            "\(hashedExample) \(ed25519) \(key)",
        ]
        var hosts = KnownHosts(lines.joined(separator: "\n"))
        hosts.remove(host: "a.example.com", port: 22)
        #expect(hosts.text == [lines[0], lines[1], "b.example.com \(ed25519) \(key)", lines[3]].joined(separator: "\n"))
        #expect(hosts.verdict(host: "b.example.com", port: 22, keyType: ed25519, key: other) == .revoked)
        #expect(hosts.verdict(host: "a.example.com", port: 22, keyType: ed25519, key: key) == .trusted, "the wildcard line still covers it")
        hosts.remove(host: "example.com", port: 22)
        #expect(!hosts.text.contains(hashedExample))
        #expect(hosts.text.contains("@revoked *"))
    }

    @Test func splitsOpenSSHPublicKeys() {
        let split = KnownHosts.split(openSSHKey: "\(ed25519) \(key) vector")
        #expect(split?.keyType == ed25519)
        #expect(split?.key == key)
        #expect(KnownHosts.split(openSSHKey: "garbage") == nil)
    }
}

struct SSHTargetTests {
    @Test func parsesWhatPeopleType() throws {
        let target = try #require(SSHTarget("runner@127.0.0.1:2222"))
        #expect(target == SSHTarget(user: "runner", host: "127.0.0.1", port: 2222))
        #expect(target.description == "runner@127.0.0.1:2222")
        #expect(SSHTarget(" ssh://me@example.com/ ") == SSHTarget(user: "me", host: "example.com"))
        #expect(SSHTarget("me@example.com")?.description == "me@example.com")
        #expect(SSHTarget("me@corp.com@jump.example.com") == SSHTarget(user: "me@corp.com", host: "jump.example.com"))
    }

    @Test func handlesIPv6Addresses() {
        #expect(SSHTarget("me@[::1]:2200") == SSHTarget(user: "me", host: "::1", port: 2200))
        #expect(SSHTarget("me@[::1]:2200")?.description == "me@[::1]:2200")
        #expect(SSHTarget("me@fe80::1") == SSHTarget(user: "me", host: "fe80::1"))
        #expect(SSHTarget("me@fe80::1")?.description == "me@[fe80::1]")
    }

    @Test func refusesIncompleteTargets() {
        for text in ["example.com", "@example.com", "me@", "me@host:", "me@host:99999", "me@host:abc", "me@[::1", "me@[::1]x", "me@two words"] {
            #expect(SSHTarget(text) == nil, "\(text)")
        }
    }
}
