import Foundation
import Observation
import Security
import TideCore
import TideSSH
import UIKit

/// What Tide keeps about SSH beyond one window: the key it logs in with
/// (in the Keychain, on this device only), recent hosts, and the known hosts
/// file. UI tests get a key from their environment and keep nothing.
@Observable
final class RemoteSSH {
    static let shared = RemoteSSH()

    private(set) var key: SSHUserKey?
    private(set) var recentHosts: [SSHTarget]

    private static let recentHostsKey = "tide.ssh.recentHosts"
    private static let keychainService = "com.coletebou.tide.ssh"
    private static let keychainAccount = "login-key"

    private init() {
        if WorkspaceLauncher.isUITesting {
            recentHosts = []
            key = ProcessInfo.processInfo.environment["TIDE_UI_TEST_SSH_KEY"]
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { try? SSHUserKey(openSSHPrivateKey: String(decoding: $0, as: UTF8.self)) }
        } else {
            recentHosts = (UserDefaults.standard.stringArray(forKey: Self.recentHostsKey) ?? []).compactMap(SSHTarget.init)
            key = Self.loadKeychainKey()
        }
    }

    // MARK: Known hosts

    /// In the user directory, beside settings.json, in OpenSSH's format.
    var knownHostsURL: URL {
        Workbench.userDirectory.appendingPathComponent("ssh/known_hosts")
    }

    func knownHosts() -> KnownHosts {
        KnownHosts((try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? "")
    }

    func trust(_ prompt: SSHHostKeyPrompt) throws {
        var hosts = knownHosts()
        hosts.add(host: prompt.target.host, port: prompt.target.port, keyType: prompt.keyType, key: prompt.key)
        try save(hosts)
    }

    func forgetHostKey(of target: SSHTarget) throws {
        var hosts = knownHosts()
        hosts.remove(host: target.host, port: target.port)
        try save(hosts)
    }

    private func save(_ hosts: KnownHosts) throws {
        try FileManager.default.createDirectory(at: knownHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hosts.text.write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }

    // MARK: Recent hosts

    func remember(_ target: SSHTarget) {
        recentHosts.removeAll { $0 == target }
        recentHosts.insert(target, at: 0)
        if recentHosts.count > 20 { recentHosts.removeLast(recentHosts.count - 20) }
        if !WorkspaceLauncher.isUITesting { UserDefaults.standard.set(recentHosts.map(\.description), forKey: Self.recentHostsKey) }
    }

    // MARK: The key

    func setKey(_ key: SSHUserKey) throws {
        if !WorkspaceLauncher.isUITesting { try Self.saveKeychainKey(key) }
        self.key = key
    }

    private struct StoredKey: Codable {
        var kind: String
        var raw: Data
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
    }

    private static func loadKeychainKey() -> SSHUserKey? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(StoredKey.self, from: data) else { return nil }
        return try? SSHUserKey(kind: stored.kind, rawRepresentation: stored.raw)
    }

    private static func saveKeychainKey(_ key: SSHUserKey) throws {
        let data = try JSONEncoder().encode(StoredKey(kind: key.kind, raw: key.rawRepresentation))
        SecItemDelete(keychainQuery as CFDictionary)
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "The Keychain refused the key (\(status))."])
        }
    }
}

/// Resumes a continuation once, with whichever answer comes first. The
/// answers cross from the prompt to the waiting connection, so they are Sendable.
private final class Reply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func callAsFunction(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

extension Workbench {
    /// Remote-SSH: Connect to Host... The typed `user@host[:port]` comes
    /// first, then recent hosts.
    func showConnectToHost() {
        let recent = RemoteSSH.shared.recentHosts.map { target in
            QuickInputItem(id: "ssh-host:\(target)", label: target.description, icon: .symbol("server.rack")) { [weak self] in
                self?.connect(to: target)
            }
        }
        showPick(.init(title: "Connect to Host", placeholder: "user@host, or user@host:port", items: recent, textItem: { [weak self] text in
            guard let target = SSHTarget(text) else { return nil }
            return QuickInputItem(id: "ssh-typed", label: target.description, description: "Connect", icon: .symbol("arrow.right.circle")) {
                self?.connect(to: target)
            }
        }))
    }

    /// Opens a terminal with a shell on the host.
    func connect(to target: SSHTarget) {
        let ssh = RemoteSSH.shared
        ssh.remember(target)
        let options = SSHSessionOptions(keys: ssh.key.map { [$0] } ?? [], knownHosts: ssh.knownHosts(), trustHostKey: { [weak self] prompt in
            await self?.askToTrust(prompt) ?? false
        }, password: { [weak self] attempt in
            await self?.askForPassword(target, attempt: attempt)
        })
        terminals.add(TerminalSession(connection: SSHTerminalConnection(target: target, options: options), title: target.description, workbench: self))
        showPanel(.terminal)
    }

    /// Asks, as ssh does, about a host key the known hosts do not list.
    /// Trusting it adds it to them.
    func askToTrust(_ prompt: SSHHostKeyPrompt) async -> Bool {
        let trusted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let reply = Reply(continuation)
            showPick(.init(
                title: "The authenticity of \(prompt.target.host) can't be established",
                placeholder: "\(prompt.displayType) key fingerprint is \(prompt.fingerprint)",
                items: [
                    QuickInputItem(id: "ssh-trust", label: "Continue", description: "Trust this key and remember it", detail: prompt.fingerprint, icon: .symbol("checkmark.shield")) { reply(true) },
                    QuickInputItem(id: "ssh-refuse", label: "Cancel", description: "Do not connect", icon: .symbol("xmark")) { reply(false) },
                ],
                onCancel: { reply(false) }
            ))
        }
        if trusted {
            do {
                try RemoteSSH.shared.trust(prompt)
            } catch {
                show(error: error, prefix: "Tide could not save the host key")
            }
        }
        return trusted
    }

    func askForPassword(_ target: SSHTarget, attempt: Int) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let reply = Reply(continuation)
            showPick(.init(
                title: attempt == 1 ? "Password for \(target)" : "Permission denied, please try again",
                placeholder: "Password for \(target)",
                items: [],
                onCancel: { reply(nil) },
                onSubmitText: { reply($0) },
                isSecure: true
            ))
        }
    }

    /// Remote-SSH: Forget Host Key... For a host whose key changed on purpose.
    func showForgetHostKey() {
        let forget: (SSHTarget) -> Void = { [weak self] target in
            do {
                try RemoteSSH.shared.forgetHostKey(of: target)
                self?.toast("Forgot the host key for \(KnownHosts.name(host: target.host, port: target.port)). The next connection asks about it again.")
            } catch {
                self?.show(error: error, prefix: "Tide could not change the known hosts")
            }
        }
        let recent = RemoteSSH.shared.recentHosts.map { target in
            QuickInputItem(id: "ssh-forget:\(target)", label: target.description, icon: .symbol("server.rack")) { forget(target) }
        }
        showPick(.init(title: "Forget Host Key", placeholder: "user@host, or user@host:port", items: recent, textItem: { text in
            SSHTarget(text).map { target in
                QuickInputItem(id: "ssh-forget-typed", label: target.description, description: "Forget its host key", icon: .symbol("trash")) { forget(target) }
            }
        }))
    }

    /// Remote-SSH: Create SSH Key. An Ed25519 key, like ssh-keygen's default;
    /// its public key goes on the clipboard for the host's authorized_keys.
    func createSSHKey() {
        if let key = RemoteSSH.shared.key {
            UIPasteboard.general.string = key.publicKeyLine + " tide"
            toast("Tide already has an \(key.typeName) key. Its public key is on the clipboard.")
            return
        }
        let key = SSHUserKey.generateEd25519()
        do {
            try RemoteSSH.shared.setKey(key)
        } catch {
            show(error: error, prefix: "Tide could not keep the key")
            return
        }
        UIPasteboard.general.string = key.publicKeyLine + " tide"
        toast("Created an \(key.typeName) key. Its public key is on the clipboard: add it to ~/.ssh/authorized_keys on your host.")
    }

    /// Remote-SSH: Copy Public Key
    func copySSHPublicKey() {
        guard let key = RemoteSSH.shared.key else {
            toast("Tide has no SSH key yet. Run Remote-SSH: Create SSH Key, or import one.", kind: .warning)
            return
        }
        UIPasteboard.general.string = key.publicKeyLine + " tide"
        toast("The public key is on the clipboard.")
    }

    /// Remote-SSH: Import SSH Key from Clipboard. An OpenSSH Ed25519 or ECDSA
    /// private key without a passphrase.
    func importSSHKey() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            toast("Copy an OpenSSH private key first, then import it.", kind: .warning)
            return
        }
        do {
            let key = try SSHUserKey(openSSHPrivateKey: text)
            try RemoteSSH.shared.setKey(key)
            toast("Imported an \(key.typeName) key. Tide logs in with it from now on.")
        } catch {
            show(error: error, prefix: "Tide could not import the key")
        }
    }
}
