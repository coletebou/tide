# SSH on Apple's swift-nio-ssh, Not Citadel

Tide's research picked Citadel, a pure-Swift SSH client on SwiftNIO SSH, and planned to vendor it and fix four gaps before 1.0 ([prior-art report](<iOS VS Code clone prior art.md>)). A closer look on October 21, 2026, before writing any SSH code, changed that: Tide's SSH client, `Packages/TideSSH`, sits directly on Apple's [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) 0.15.0, and Tide writes the thin client layer Citadel would have provided. This note records why, what Tide gains and gives up, and how the result is checked.

## Citadel's SSH core has an unpatched memory-safety bug

Citadel 0.12.1 (April 4, 2026, the same commit as `main`) does not use Apple's swift-nio-ssh. It depends on a fork, `github.com/Wellz26/swift-nio-ssh`, with the requirement `"0.3.4" ..< "0.4.0"`, so a fresh resolve today fetches that fork's 0.3.7. The fork branched from Apple's 0.4.0 in April 2022 and is 93 commits behind Apple's `main`.

Among the missing commits is the fix for **CVE-2026-43798** ([GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc)), a critical unauthenticated out-of-bounds stack write triggered by an oversized ECDSA signature, fixed in swift-nio-ssh 0.14.1 and published July 17, 2026. The fork still has the vulnerable code (`NIOSSHSignature.swift`, lines 338 to 360), and a client reaches it while parsing the server's key-exchange reply. That happens before any host-key check, so a malicious server or anyone in the network path can trigger it, and known-hosts pinning does not help.

## The dependency changed hands quietly, and upstream has stalled

- **A quiet swap.** Citadel's switch to the Wellz26 fork came in pull request #127, whose description mentions only adding swift-nio. The fork was created the same day, has no stars and issues turned off, and added tags 0.3.6 and 0.3.7, which do not exist in the maintainer's own fork. Tide's two reviewed commits from the new owner look benign, but an SSH client's supply chain should not depend on a personal fork that appeared without notice.
- **A stalled upstream.** Citadel has had no commits in 180 days, and its last four CI runs on `main` failed. The maintainer's own pull request to move back to his fork and issue #122 ("migrate back to official swift-nio-ssh") are still open.
- **No escape through pinning.** An `exactVersion` pin on Citadel still resolves the fork by version range, and it cannot patch the vulnerability. Vendoring both would make Tide the owner of about 30,000 lines of security-critical code, four years diverged from Apple's.

## Citadel's API would also have fought a terminal

Read from Citadel 0.12.1's sources, not run:

- **A hardcoded login timeout.** A 10-second login timeout covers the host-key check, so a "trust this host?" dialog fails the connection if someone takes longer to answer.
- **One login method per connection.** A connection offers exactly one authentication method, so trying a key and then asking for a password needs a second connection.
- **A lost exit status.** `withPTY` throws `ChannelError.alreadyClosed` when the remote shell exits, and that error replaces the exit status.
- **SHA-1 RSA only.** RSA keys sign only as SHA-1 `ssh-rsa`, which OpenSSH 8.8 and later reject by default.

## What Tide gets, and gives up

swift-nio-ssh supports exactly the keys Tide's plan defaults to:
- **Key types:** Ed25519, ECDSA P-256, P-384 and P-521, and Secure Enclave P-256.
- **Sendable types:** its keys, offers and channel events are Sendable, which suits Tide's Swift 6 code.
- **Asynchronous answers:** its authentication delegate is asked again after each failure and may answer later, so one connection tries the key, then asks for a password, and a host-key dialog can wait for the user.

TideSSH adds about 800 lines on top:
- **Sessions:** `SSHShellSession` covers connecting, the pty and shell requests, window-change resizes and the exit status.
- **Known hosts:** `KnownHosts` covers OpenSSH's known_hosts format, including hashed names, wildcards, negations, `@revoked`, and changed-key detection.
- **Keys:** `SSHUserKey` imports OpenSSH Ed25519 and ECDSA private keys.

That import closes one of Citadel's four gaps, the missing ECDSA support.

The costs:

| Lost or not yet built | Why, and the way back |
|---|---|
| RSA user keys | swift-nio-ssh has no RSA and no hook for custom key types. Tide makes Ed25519 keys and imports ECDSA ones. If RSA-only hosts turn out to be common, libssh2 (BSD-3) behind the same `TerminalConnection` seam remains the fallback the prior-art report named. |
| Keyboard-interactive login (2FA, PAM prompts) | Missing from swift-nio-ssh and from Citadel alike; it needs an upstream contribution. |
| Encrypted private keys | Not read yet. Tide says how to remove the passphrase from a copy, or makes its own key. Reading them needs bcrypt-pbkdf and AES-CTR. |
| SFTP | Next on the remote roadmap. Citadel's MIT SFTP client can be ported onto upstream channels, or written fresh (SFTP v3). |
| Agent forwarding, port forwarding, jump hosts | Later items. swift-nio-ssh supports direct-tcpip channels for forwarding. |

## How it is checked

The TideSSH tests run against a real OpenSSH server on GitHub's macOS runners. `scripts/ssh-test-server.sh` starts sshd as the runner user on 127.0.0.1, with throwaway host and client keys. The tests cover:

- logging in with Ed25519 and ECDSA keys
- a shell on a pty, with `stty size` before and after a resize
- the exit status of `exit 3`
- the host-key question for an unknown key, with the fingerprint OpenSSH reports
- refusing a changed key without asking
- a refused login
- an unreachable host
- keys made by `ssh-keygen` at test time, read back, with the expected refusals for encrypted and RSA keys

A UI test connects the app in the iPad simulator to the same server, answers the host-key question, runs a command and reads its output back from the terminal.
