# FORK-NOTES — vendored upstreams

Hard-fork decision per HANDOFF-NOTES #8 🔒: Leader Key and Rectangle are owned
in-tree (MIT, small, a learning goal). Karabiner and iTerm2 stay external and
managed — never forked. "Coordinator, not parent" still governs process
lifecycle: the app coordinates running tools; it never owns their lifecycles.

Both trees vendored as **squashed git subtrees** — upstream history is not
carried; the SHAs below are the exact upstream commits captured.

## LeaderKey

- **Upstream:** https://github.com/mikker/LeaderKey.app (branch `main`)
- **SHA at vendor:** `16bcb307dcc5309fbc3a00fe398d913e1f7ddc51`
- **Vendored:** 2026-07-06, via `git subtree add --prefix=forks/LeaderKey … main --squash`
- **License:** MIT (SPDX: `MIT`) — Copyright (c) 2024 Mikkel Malmberg.
  `forks/LeaderKey/LICENSE` kept intact (MIT requires the notice).
- **Build (works, 2026-07-06, Xcode 26.6):**
  ```
  xcodebuild -project "forks/LeaderKey/Leader Key.xcodeproj" -scheme "Leader Key" \
    -configuration Debug -derivedDataPath forks/LeaderKey/DerivedData \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    -skipPackagePluginValidation -skipMacroValidation build
  ```
  Product: `forks/LeaderKey/DerivedData/Build/Products/Debug/Leader Key.app`.
  The two skip flags are required: LeaderKey uses a SwiftFormat build plugin
  (`SwiftFormatPlugins`), and headless xcodebuild can't answer the interactive
  plugin-trust prompt — without them the build fails at
  "Validate plug-in Lint". Ad-hoc signing disables hardened runtime (fine for
  local Phase 1 use).

## Rectangle

- **Upstream:** https://github.com/rxhanson/Rectangle (branch `main`)
- **SHA at vendor:** `7d6b4c5a48b72b1fa9d2a5fe5d127c5f12264bf1`
- **Vendored:** 2026-07-06, via `git subtree add --prefix=forks/Rectangle … main --squash`
- **License:** MIT (SPDX: `MIT`) — Copyright (c) 2019-2026 Ryan Hanson; based on
  Spectacle, Copyright (c) 2017 Eric Czarny.
  `forks/Rectangle/LICENSE` kept intact (MIT requires the notice).
- **Build (works, 2026-07-06, Xcode 26.6):**
  ```
  xcodebuild -project forks/Rectangle/Rectangle.xcodeproj -scheme Rectangle \
    -configuration Debug -derivedDataPath forks/Rectangle/DerivedData \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build
  ```
  Product: `forks/Rectangle/DerivedData/Build/Products/Debug/Rectangle.app`,
  ad-hoc signed (`codesign -dv` → `flags=0x2(adhoc)`).

## Local patches (the fork diverges here)

- **LeaderKey — summon sigil indicator** (`[P1.7]`): `Themes/Mini.swift` renders
  `SummonSigil` (new imageset from `assets/icon_transparent.png`, 256px) when
  idle instead of the plain `●`; typed keys still take over mid-sequence.

## Signing

Ad-hoc / free personal team is the Phase 1 posture. The exact incantation that
worked gets recorded per fork above.
