# Guide for coding agents

Tide is a native Swift (SwiftUI + UIKit/TextKit) clone of VS Code's workbench and editor for
iPad and iPhone — no web view. Humans start at [README.md](README.md); `CLAUDE.md` only imports
this file. Edit this one.

## Read before changing behaviour

- [README.md](README.md) "Architecture" table: the three layers (`TideCore`, Editor, Workbench)
  and what each owns.
- [docs/reports/iOS VS Code clone prior art.md](<docs/reports/iOS VS Code clone prior art.md>):
  the research the design decisions come from. Read it before changing direction on workbench,
  editor or remote-dev architecture.
- [docs/reports/libghostty terminal fit for Tide.md](<docs/reports/libghostty terminal fit for Tide.md>):
  why the terminal uses SwiftTerm, for anything touching `Terminal` or `SwiftTerm`.

## Hard rules

- **`Packages/TideCore` depends only on Foundation.** No UIKit, SwiftUI, or app-target imports —
  that is what lets `swift test --package-path Packages/TideCore` run on a Mac host in seconds,
  with no simulator. If a change needs a UIKit/SwiftUI type in `TideCore`, it belongs in
  `App/Sources` instead.
- **`project.yml` is the source of truth for `Tide.xcodeproj`.** Never hand-edit the generated
  `.xcodeproj`; change `project.yml` and run `xcodegen generate`.
- **Attribution stays accurate.** Code or theme colors ported from VS Code (Code - OSS, MIT) get
  an entry in [NOTICE.md](NOTICE.md) naming the source file and license, matching the existing
  entries. Don't port VS Code code without adding one.
- **Public, MIT-licensed repo.** No secrets, private hostnames, or machine-specific paths in
  commits or docs. Work on a branch and open a PR — CI (below) gates every push already.
- Never skip, weaken, or delete a test to get a build green; change one only when the intended
  behavior changed.

## Where things are, and what a change can break

| Path | Holds | Breaks |
|---|---|---|
| `Packages/TideCore/Sources/TideCore` | line index, tokenizers/language catalog, fuzzy matching (`Fuzzy/`), themes incl. VS Code theme import (`Theme/`), text editing ops, Myers diff, workspace file system + search, symbols, diagnostics, settings, the built-in shell, the `.git` reader | TideCore's own tests, and every app feature built on it (editor, Quick Open, Explorer, Search, Settings, terminal, Source Control) |
| `App/Sources/Editor` | `UITextView`-on-TextKit editor, layout manager/decorations, gutter, minimap, keyboard bar | the editor and split-view behavior |
| `App/Sources/Model`, `App/Sources/Views` | observable workbench state, VS Code-id commands, Quick Input, SwiftUI views | the workbench UI, menus, Quick Open/Palette |
| `UITests/` | XCUITest end-to-end suite (Command Palette, Quick Open, terminal, Search, Settings, themes, split editor) | nothing downstream, but is the regression gate for all of the above |
| `project.yml` | XcodeGen spec for `Tide.xcodeproj` and `TideUITests` targets | the whole build if it drifts from the checked-in `.xcodeproj` |

## Checks: run the light one locally, the rest in CI

```sh
swift test --package-path Packages/TideCore          # whole package, seconds, no simulator
swift test --package-path Packages/TideCore --filter <TestName>   # one test/suite
```

- The iOS app build and the `UITests/` simulator suite are heavy (Xcode + an iPad simulator boot)
  — push a branch and let CI (`.github/workflows/ci.yml`) run them rather than running Xcode
  builds or booting a simulator locally. Watch with `gh run watch <id> --exit-status`; read only
  the failures with `gh run view <id> --log-failed`. `workflow_dispatch` is enabled, so you can
  also trigger a run directly: `gh workflow run ci.yml --ref <branch>`.
- CI has three jobs: `core` (TideCore tests), `app` (build for the iOS Simulator), `ui` (XCUITest
  suite on a booted iPad simulator, screenshots uploaded as an artifact on every run, the
  `.xcresult` bundle on failure). A push to any branch cancels that branch's older runs; `master`
  runs always finish.
- Trivial local checks are fine: `xcodegen generate` (keep it in sync with `project.yml`),
  `swift build --package-path Packages/TideCore`, `git diff`.

## Running it

```sh
brew install xcodegen
xcodegen generate
xcodebuild -downloadComponent MetalToolchain   # once, for SwiftTerm's renderer
open Tide.xcodeproj
```

Requirements: Xcode 26+. Deployment target iOS/iPadOS 17+. Swift tools version 6.0, with
`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` as the app-wide default (see "Known traps" for the one
exception).

## Known traps

- `xcodebuild` needs `-skipPackagePluginValidation -skipMacroValidation` — SwiftTerm's build
  plugin fails strict validation without them (see `README.md`'s build command and `ci.yml`).
- `TideUITests` sets `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` in `project.yml`, unlike every
  other target: `XCTestCase`'s inherited initializers are `nonisolated`, so the test target can't
  compile under the app-wide `MainActor` default. UI test code marks itself `@MainActor`
  explicitly instead.
- The UI-test simulator boots without a hardware keyboard attached (`xcrun simctl bootstatus`
  detaches it once a UI-test session starts) — UI tests drive menu shortcuts and the on-screen
  keyboard, not physical key events.
- `-uiTesting` launches from a fresh copy of the sample workspace and default settings (optionally
  overridden by `TIDE_UI_TEST_SETTINGS` JSON) — a UI test that depends on prior app state will be
  flaky by design.
- Booting more than one simulator, or an iOS build running alongside it, can exhaust a
  memory-constrained Mac's RAM; prefer letting CI's dedicated runner do this instead of running
  simulators and compiles in parallel on a laptop/desktop.
