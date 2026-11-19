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

- **LeaderKey — own bundle id** (`[P2.6]`): `PRODUCT_BUNDLE_IDENTIFIER` for the
  app target is `com.machinespirit.leader-key` (was `com.brnbw.Leader-Key`;
  Tests target unchanged). This is what makes the fork a distinct app to
  macOS — its own TCC/Accessibility grant, its own LaunchServices entry (so
  `open` never bounces to the cask), and its own UserDefaults domain. Display name is
  **"MachineSpirit Leader Key"** (CFBundleDisplayName) so it's
  distinguishable from the cask's "Leader Key" in the TCC panes; the
  binary/CFBundleName stay "Leader Key". Consequence: the new domain starts EMPTY, so the
  install seeds it from the cask's domain (F19 activation lives under
  `KeyboardShortcuts_navigate` = carbonKeyCode 80).
- **LeaderKey — summon sigil indicator** (`[P1.7]`): `Themes/Mini.swift` renders
  `SummonSigil` (new imageset from `assets/icon_transparent.png`, 256px) when
  idle instead of the plain `●`; typed keys still take over mid-sequence.
- **LeaderKey — test sandbox for the config home** (`[P2.4x]`, incident fix):
  `UserConfig.defaultDirectory()` returns a temp-dir sandbox whenever XCTest
  is loaded. Upstream's `testCreatesDefaultConfigDirIfNotExists` DELETES the
  real `~/Library/Application Support/Leader Key/` — running the full test
  plan once destroyed the owner's live config (SESSION-LOG war story,
  2026-07-06). Never remove this guard; re-check it survives any upstream
  merge.
- **LeaderKey — board IPC and background launch**: bind execution posts
  `com.machinespirit.leader.fired` with a string `path`; panel show/navigation/
  clear/hide posts `com.machinespirit.leader.nav` with string `state`, `path`, and
  global AppKit `screen` frame. Both use DistributedNotificationCenter with
  immediate delivery. `msGraphOverlayEnabled` gates shown events; hidden always
  posts. `UserState.navigationPath.didSet` covers keyboard, reset, and URL paths.
  No board URL open or running-app lookup remains on the bind path. An installed
  board (`com.machinespirit.MachineSpirit`) starts in the background at fork
  launch unless `msLaunchBoardAtLogin` is false. Explicit board opening still
  uses `machinespirit://board`, activating.
- **LeaderKey — system menu**: exactly one additional status item combines
  keep-awake and brightness, independently of the skull visibility preference.
  `KeepAwake.swift` owns one IOPM assertion and one optional expiry timer;
  `SystemStatusItem.swift` owns the menu; `BrightnessController.swift` owns
  cached display state, the media-key tap, and one reusable nonactivating HUD;
  `DisplayHardware.swift` resolves private APIs dynamically. All display I/O
  uses one serial queue, and each display retains only its latest pending write.
  The existing memory gauge also skips unchanged image/title assignments to
  avoid redundant AppKit status-item replica redraws.
  Topology changes invalidate callbacks; unchanged screen notifications keep
  the cache. Wake and menu opening refresh readings. Ambiguous registry matches
  and unsupported hardware fail closed, with no brightness slider enabled.
- **MonitorControl attribution (MIT)**: registry matching and DDC protocol are
  adapted/reimplemented from [Arm64DDC.swift](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift).
  Its copyright/MIT notice is retained in `DisplayHardware.swift`; no dependency
  on the MonitorControl app or package is added. DisplayServices, IOAVService,
  and optional CoreDisplay identity lookup are private API compatibility risks.
- **LeaderKey — config hot-reload** (`[P2.4]`): `ConfigFileMonitor` (in
  `UserConfig.swift` — no new compile unit for the app target) watches the
  live config via a DispatchSource file-system object source, 300ms debounce,
  re-arms on the path after every event burst so replace-by-rename (the
  atomic-swap write ritual) can't kill the watch. Wired in
  `AppDelegate.applicationDidFinishLaunching`; re-watches when the config
  directory preference changes. Unit tests in
  `Leader KeyTests/ConfigFileMonitorTests.swift` (pbxproj hand-patched with
  `FADE0001…`/`FADE0002…` ids). `reload-leaderkey.sh` becomes legacy once the
  fork drives.

## Signing

The early build examples above use ad-hoc signing. The daily-driver Leader Key
Release install must be re-signed with **MachineSpirit Local Codesign** at
`~/Applications/MachineSpirit Leader Key.app`, as in `install.sh`, to preserve
TCC identity across rebuilds. The existing LaunchAgent remains the only login
mechanism. `reload-leaderkey.sh` uses a name-based `open -a "Leader Key"` and can
resolve to a DerivedData build; verify the running executable afterward and
restart the existing LaunchAgent if necessary.

## The fork as permanent daily driver (`[P2.6]`, owner machine)

The live setup that makes the fork the standing driver (not committed — these
are live-system steps; the eventual `install.sh`/onboarding automates them,
tracked in MANUAL-WIRING):

1. **Bundle id** → `com.machinespirit.leader-key` (in-tree, above).
2. **Stable install path:** build, then `cp -R` the product to
   `~/Applications/Leader Key.app` and `codesign --force --deep --sign -` it
   (ad-hoc re-sign at the new path). DerivedData is ephemeral; the login item
   must point somewhere stable.
3. **Seed prefs:** `defaults export com.brnbw.Leader-Key - | defaults import
   com.machinespirit.leader-key -` — carries F19 activation + theme into the
   new (empty) domain.
4. **Launch at login:** `~/Library/LaunchAgents/com.machinespirit.leader-key.plist`
   (RunAtLoad, ProgramArguments → the ~/Applications binary), loaded with
   `launchctl bootstrap gui/$(id -u) <plist>`.
5. **Retire the cask's autostart:** remove its legacy login item
   (`System Events → delete login item "Leader Key"`, path
   `/Applications/Leader Key.app`). The cask **stays installed** for rollback.
6. **Accessibility (owner, consent gate):** the new bundle id is a new TCC
   identity — grant Accessibility to `~/Applications/Leader Key.app` for the
   System-Events binds (app-jump, screenshots) to work.

**Rollback to the cask:** `launchctl bootout gui/$(id -u)/com.machinespirit.leader-key`;
`pkill -f 'Applications/Leader Key.app'`; re-enable the cask's Launch-at-Login
(open `/Applications/Leader Key.app`, toggle it on); it drives again. The new
domain, LaunchAgent, and ~/Applications copy can all be deleted with no trace.

## System menu verification (2026-11-19)

- Release built with install.sh's flags into `DerivedData-Release`; deployed with
  `ditto` and the existing local signing identity. No commit/staging/push.
- `tools/SystemMenuSmoke.swift` compiles with `KeepAwake.swift` and
  `DisplayHardware.swift`. `--awake` verified display/system assertion types,
  Off release, and real 60-second expiry using the production assertion owner.
  The shipping menu retains 15 minutes as its shortest duration. The installed
  signed app also passed a launch-preference test: `pmset` showed a Leader Key
  `PreventUserIdleDisplaySleep` assertion named `machine-spirit keep-awake`;
  clean quit/restoring the original launch preference left no assertion.
- Hardware smoke run: Built-in Retina Display read successfully; M28U DDC read
  `current=0 max=100`, wrote the same value, and read back `0`. Samsung LC32G5xT
  matched the registry but mostly did not answer, with one transient successful
  app read. Its support is not considered verified; failed reads disable control.
  Brightness was not intentionally changed from the values read.
- `tools/ObserveLeaderIPC.swift` observed real shown/root, group (`s`, `f`),
  hidden, and fired (`h`) events from the installed app. Payload values were
  checked as Strings; observed screen was `0,1117,1920,1080`. These were triggered
  through the fork's existing URL routes, not a physical F19 key.
- Final installed runtime logged `status item created, visible=1` and
  `brightness key event tap installed`; `codesign --verify --deep --strict` passed.
- Final five-second `top` intervals measured 1.1% and 0.4% CPU (initial
  cumulative sample 0.0%); this is a bounded observation, not a whole-session
  performance guarantee. Earlier verification intervals reached 4.5%. A sample
  showed mostly waiting plus AppKit status-item replica redraw work.
- UI automation reached the launcher panel but could not expose menu-bar extras.
  Visual icon/menu acceptance, slider dragging, physical media-key routing/HUD,
  hot-plug, Intel fallback, and cold board launch remain manual checks. The board
  worker's app files were not modified.
