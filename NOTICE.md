# Notices

Tide is an independent project. It is not affiliated with or endorsed by
Microsoft. Visual Studio Code and VS Code are trademarks of Microsoft
Corporation; Tide uses the names only to describe what it is modeled on.

Portions of Tide are adapted from **Visual Studio Code (Code - OSS)**,
Copyright (c) Microsoft Corporation, released under the MIT License
(https://github.com/microsoft/vscode/blob/main/LICENSE.txt):

- Quick Open and Command Palette matching
  (`Packages/TideCore/Sources/TideCore/Fuzzy/FuzzyMatching.swift`), ported
  from `src/vs/base/common/fuzzyScorer.ts` and `src/vs/base/common/filters.ts`.
- Default theme colors (`Packages/TideCore/Sources/TideCore/Theme/BuiltinThemes.swift`),
  taken from `extensions/theme-defaults/themes`.
- Setting names, command ids and default keybindings, so VS Code users feel at home.

Third-party packages:

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza, MIT License.
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh), [SwiftNIO](https://github.com/apple/swift-nio),
  [Swift Crypto](https://github.com/apple/swift-crypto), [Swift ASN.1](https://github.com/apple/swift-asn1),
  [Swift Atomics](https://github.com/apple/swift-atomics), [Swift Collections](https://github.com/apple/swift-collections)
  and [Swift System](https://github.com/apple/swift-system), by Apple Inc. and their project authors,
  Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0). TideSSH uses them for SSH.

Notices from the Apache-licensed packages' NOTICE files:

- **The SwiftNIO Project**, Copyright 2017, 2018 The SwiftNIO Project. It is heavily influenced
  by Netty (Apache License 2.0), and contains NodeJS's llhttp (MIT), "cpp_magic.h" from Thomas
  Nixon and Jonathan Heathcote's uSHET (MIT), "sha1.c" and "sha1.h" from FreeBSD (Copyright (C)
  1995, 1996, 1997, and 1998 WIDE Project; BSD-3-Clause), and derivations of Fabian Fett's
  Base64.swift and of code from AsyncHTTPClient, SwiftCertificates, Swift System and Swift
  Package Manager (Apache License 2.0).
- **The SwiftCrypto Project**, Copyright 2019 The SwiftCrypto Project. It contains test vectors
  from Google's Wycheproof project and a derivation of files from SwiftNIO (Apache License 2.0).
- **The SwiftASN1 Project**, Copyright 2022 The SwiftASN1 Project. It contains derivations of
  scripts from SwiftNIO and Swift OpenAPI Generator (Apache License 2.0).
