# FORK-NOTES — vendored upstreams

Hard-fork decision per HANDOFF-NOTES #8 🔒: Leader Key and Rectangle are owned
in-tree (MIT, small, a learning goal). Karabiner and iTerm2 stay external and
managed — never forked. "Coordinator, not parent" still governs process
lifecycle: the app coordinates running tools; it never owns their lifecycles.

Local build commands use `.noindex` derived-data folders to exclude build products
from Spotlight. Daily-driver apps live in `~/Applications`.

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
    -configuration Debug -derivedDataPath forks/LeaderKey/DerivedData.noindex \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    -skipPackagePluginValidation -skipMacroValidation build
  ```
  Product: `forks/LeaderKey/DerivedData.noindex/Build/Products/Debug/Leader Key.app`.
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
    -configuration Debug -derivedDataPath forks/Rectangle/DerivedData.noindex \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build
  ```
  Product: `forks/Rectangle/DerivedData.noindex/Build/Products/Debug/Rectangle.app`,
  ad-hoc signed (`codesign -dv` → `flags=0x2(adhoc)`).

## Local patches (the fork diverges here)

- **LeaderKey — own bundle id** (`[P2.6]`): `PRODUCT_BUNDLE_IDENTIFIER` for the
  app target is `com.machinespirit.leader-key` (was `com.brnbw.Leader-Key`;
  Tests target unchanged). This is what makes the fork a distinct app to
  macOS — its own TCC/Accessibility grant, its own LaunchServices entry (so
  `open` never bounces to the cask), and its own UserDefaults domain. Display name is
  **"MachineSpirit Leader Key"** (CFBundleDisplayName and CFBundleName) so it's
  distinguishable from the cask's "Leader Key" in the TCC panes; the
  binary stays "Leader Key" (v3). Consequence: a new domain starts EMPTY, so the
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
- **LeaderKey — compact menu (v3)**: `StatusItem.swift` is the sole NSStatusItem
  owner. `CompactBar.swift` renders one scale-aware image, comparing visible
  content before assigning it. `SystemStatusItem.swift` is now a section builder;
  `MemoryPressureStatusItem.swift` is a pure kernel reader. Sheol controls remain
  in a section builder with their original targets/wards. All five `msBar*`
  segment preferences default on. The former show-icon preference controls only
  the skull; the single system menu remains reachable.
  `KeepAwake.swift` retains one IOPM assertion; its deadline and the clipboard
  change counter now use the bar's two-second heartbeat. Clipboard capture can
  take roughly two seconds (previously half a second).
  Brightness keeps its existing per-display serial queues and latest-write
  coalescing. No hardware write is triggered by a stats refresh.
- **LeaderKey — Stats readers (v3)**: `SystemStats.swift` samples total CPU with
  host_processor_info deltas every 2s (0.5s tolerance). GPU/VM details, top five
  processes, primary-interface network rates, physical-disk rates, battery and
  temperatures run only during menu tracking, at 1s with in-flight coalescing and
  generation checks. `ps` is used once per open-menu sample because unprivileged
  proc_pidinfo omits some system processes. Counter resets/interface changes and
  fresh menu openings re-prime deltas. IOHID sensors fail soft; `SMC.swift` adds
  read-only known-M4 CPU/GPU fallback, never fan control or privileged helpers.
- **Stats attribution (MIT)**: native readers/SMC ABI and sensor-key mappings
  reference/adapt [exelban/Stats](https://github.com/exelban/stats), shallow clone
  `8bf536fe1752cf6d126426ef504a7a94b2489974` (2026-11-19). Copyright (c) 2019
  Serhiy Mytrovtsiy; full notice retained in `LeaderKey/Stats-LICENSE.txt`.
  No dependency on the Stats app is added, and it is never quit automatically.
- **LeaderKey — native sheol reads (v3)**: `SheolReader.swift` uses the read-only
  tmux v8 local-socket protocol and native Apple Events, avoiding helper launches
  while closed. UTF-8 client flags preserve the list field separators. It never
  creates a server or attaches to a session. Native non-iTerm discovery mirrors
  terminals-core's login-shell/owning-app scan. Actions and open-menu enrichment
  still use the established helpers. Protocol incompatibility retains cached
  counts. tmux 3.7b protocol references and Nicholas Marriott's ISC notice are
  retained in `SheolReader.swift`.
- **LeaderKey — overlay cheatsheet exclusion (v3)**: both scheduling and the
  shared show method check `msGraphOverlayEnabled`; enabling the overlay also
  hides an already-open cheatsheet. The false path preserves the previous rules.
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
2. **Stable install path:** Release build, then `ditto` the product to
   `~/Applications/MachineSpirit Leader Key.app` and sign with
   **MachineSpirit Local Codesign** (see Signing above). Never run the
   DerivedData product as the daily driver.
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
   identity — grant Accessibility to `~/Applications/MachineSpirit Leader Key.app` for the
   System-Events binds (app-jump, screenshots) to work.

**Rollback to the cask:** `launchctl bootout gui/$(id -u)/com.machinespirit.leader-key`;
`pkill -f 'Applications/MachineSpirit Leader Key.app'`; re-enable the cask's Launch-at-Login
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

## Leader Key v2 (2026-11-19)

- **DDC fix:** the Samsung LC32G5xT returned repeated valid DDC null packets
  (`6E 80 BE`) to the old GET checksum. Standard GET includes source address
  `0x51`; this immediately made Samsung answer. Standard-first reads retain a
  legacy-checksum retry for bridges that require it. Reads/writes use two paced
  10 ms write cycles, a 50 ms read delay, and bounded retries. Matching retains
  unique IORegistry location/EDID identity, adds product-name scoring, and logs
  each matched DCPAVServiceProxy registry ID and framebuffer plus read results.
- **Reference/license:** inspected MonitorControl at
  `7cfe64500d19cbbcbf82121a91c826f658a403bd`, including
  `MonitorControl/Support/Arm64DDC.swift` and `DisplayManager.swift`.
  The existing full MIT notice in `DisplayHardware.swift` covers the adapted
  registry/DDC implementation. Standard-checksum fallback and per-display queue
  ownership are local changes; no MonitorControl dependency is linked.
- **Brightness:** `msBrightnessSync` defaults true; one All displays slider,
  per-display rows only when sync is off, shared 6.25% media-key steps, one lazy
  HUD per screen. Hardware occupies levels 25–100; levels 0–25 use 15–100% gamma
  at minimum hardware (1% backlight floor on built-in to prevent switching off).
  Unsupported hardware has full-range software fallback. Display UUID levels
  and the master level persist. ColorSync restoration is global, so restoring
  one display immediately reapplies all other dimmed screens. Wake/topology
  events rebuild/reapply. MonitorControl conflict warning/action is opt-in.
- **Invisible launcher:** only MainWindow's content alpha/shadow change when
  graph overlay is on. The key window stays alive; IPC payloads are unchanged;
  the separate cheatsheet is unaffected. Theme shadow state restores when off.
- **Commands/screenshots:** commands now run on a serial background queue with
  continuous output draining and a 64 KiB diagnostic limit, preserving group
  ordering without blocking AppKit. The screenshot failure on this machine is
  a denied Screen Capture TCC grant, not a missing executable or PATH. Both
  copy/save probes through the installed app returned exit 1 and `could not
  create image from rect`; identical shell probes returned exit 0 and PNG/TIFF
  clipboard data. The quiet wrapper intentionally converts failures to exit 0.
  Owner action: System Settings → Privacy & Security → Screen & System Audio
  Recording → MachineSpirit Leader Key; enable/re-tick the installed app and
  restart the LaunchAgent. No TCC database modifications were made.
- **Native clipboard:** `ClipboardHistory.swift` and `ClipboardPanel.swift`,
  default ⌘⇧V (`msClipboardHistory`, configurable), both clipboard URL schemes,
  System menu entries, and live-config `⇪ k` (`v` was occupied). Live config was
  backed up to `/private/tmp/leader-key-before-clipboard-20261119-083850.json`
  before the surgical insertion; `scripts/sync.sh` captured exactly that change.
  Native AppKit
  search/list, keyboard selection, pins, copy-only and guarded previous-app
  paste. Maccy's [README behavior](https://github.com/p0deje/Maccy#usage) and
  ignored-type policy informed the design; no Maccy source was copied/vendored.
  Its project is MIT licensed. Our default Return/Option-Return actions follow
  the owner's requested mapping. Local index/images use owner-only permissions,
  background processing/persistence, 300-entry/50-image caps with pin exceptions.
  Clear preserves pins; explicit deletion can remove a pin.

### v2 verification

- Each part was Release-built, installed with `ditto`, signed using the existing
  MachineSpirit Local Codesign identity, verified with `codesign --verify
  --deep --strict`, and restarted through `launchctl kickstart -k`. No staging,
  commits or pushes; no edits to the concurrent worker's `app/` files.
- Real DDC roundtrip: **LC32G5xT 0 → 1 → 0**, **M28U 63 → 64 → 63**.
  Both original values were restored before enabling the new sync behavior.
  The installed sync-default launch then set all displays to shared level 100.
- Production-controller smoke: combined level 12.5 read gamma maximum **0.575**
  on Built-in Retina Display, LC32G5xT and M28U. At combined level 50, hardware
  read **33.3333 / 33 / 33** respectively. Original hardware and ColorSync were
  restored after the smoke.
- Installed transparent panel reported `key=1 contentAlpha=0.0 shadow=0`.
  Actual keyboard input advanced IPC path to `s/s/s`; Escape posted hidden.
  IPC values remained Strings with the existing state/path/screen contract.
- Command smoke wrote 200 KB, captured the bounded 65,536-byte diagnostic buffer,
  exited 0, and allowed **9 main-run-loop timer ticks** while executing.
- Clipboard smoke uses an isolated named pasteboard/temp directory. Passed all
  ignored markers, dedup preserving a pin, RTF retention/own-copy exclusion,
  multiple file URLs, image priority over secondary plain URL text, 300-entry eviction preserving the oldest pin, 3000-pixel
  source resized to **2048×16**, PNG+TIFF replay, 50-image cap, full persistence
  equality after restart, clearing unpinned entries and orphan PNG removal,
  and fuzzy matching. The installed app passed fuzzy search, pin and copy-only.
- Reproduction tools live in `forks/LeaderKey/tools/`: `SystemMenuSmoke.swift`,
  `BrightnessSmoke.swift`, `CommandRunnerSmoke.swift`, `ClipboardSmoke.swift`.
  `deploy-release.sh` follows the stable-path/certificate/LaunchAgent recipe.
  Smoke binaries are standalone fixtures; no DerivedData app was run live.

- Final layout fixture rendered the production view offscreen (no user windows
  activated): table/cell width **504 px**, preview width **364 px**; image reviewed
  at `forks/LeaderKey/docs/clipboard-panel.png`. `ClipboardPanelSmoke.swift` explains
  its test-only same-file extension compilation. Initial preview clipping was
  corrected by explicitly sizing the table/column to the scroll view.
- Idle CPU with the installed clipboard poller: `top -l 3 -s 2 … -stats cpu,mem`
  returned **0.0%, 0.0%, 0.0%**, about **47 MB** in the initial sample. This is a
  short bounded observation, not a whole-session performance guarantee. The final
  sample after all changes was **0.0%, 0.3%, 0.6%**, about **24 MB**.
- Still manual/unverified: successful screenshots after the owner restores the
  Screen Recording grant; physical brightness/hotkey routing; MonitorControl
  conflict-menu click; wake/hot-plug and Intel fallback; interactive all-screen
  HUD acceptance; final Return-to-previous-app paste. Live paste verification
  was interrupted by repeated launcher activations/current-app changes; it is
  not counted as a pass. Storage copy/replay and installed Option-Return copy
  were verified separately. No TCC permissions were silently granted/reset.

## Fork v3 verification (2026-11-19)

- Clean Release builds used the documented flags, stable install path and
  **MachineSpirit Local Codesign**. `codesign --verify --deep --strict` passed;
  signature authority was `MachineSpirit Local Codesign`. The LaunchAgent's
  running executable remained `~/Applications/MachineSpirit Leader Key.app/Contents/MacOS/Leader Key`.
  `defaults read …/Contents/Info CFBundleName` and CFBundleDisplayName both returned
  `MachineSpirit Leader Key`; CFBundleExecutable returned `Leader Key`, and
  CFBundleIdentifier remained `com.machinespirit.leader-key`. Generated Info.plist
  was disabled for the app target because Xcode otherwise overwrote CFBundleName
  from PRODUCT_NAME; required app keys are explicit in the source Info.plist.
- Accessibility reported exactly **1** menu-bar item. The combined item measured
  **128 × 24 points**; disabling CPU reduced width to **98**, and enabling it
  restored **128**. The CPU preference was restored on. Summoning visibly turned
  the skull green. Keep-awake Indefinitely created a real Leader Key
  `PreventUserIdleDisplaySleep` assertion and showed the dot; Off released it.
- Installed URL routes emitted shown/root, group `s`, and hidden notifications.
  With overlay enabled, delayed activation plus `?` showed only the 200 × 200
  input panel; no cheatsheet window. With overlay disabled, `?` showed the
  **580 × 812** cheatsheet again. Overlay was restored on.
- `tools/SheolSmoke.swift`: native socket/Apple Event counts matched the existing
  helpers at **1·8·0**, with no double-counted tmux terminals. Original row targets,
  moon/revive actions, triple-tap wards and the Banish All confirmation remain in
  the section builder. No live session was killed/detached for verification.
- `tools/StatsSmoke.swift`: rate baselines, counter resets, interface changes and
  open/close/reopen passed; **6** updates were delivered, none while closed.
  Installed menu exposed all seven rows with working detail submenus and live
  refresh. Example readings: GPU 28%, memory 27.27 GB / 48 GB with 17% pressure,
  battery 80%, 53 cycles and 92% design health. CPU/GPU temperature averages and
  hottest sensor worked through the M4 SMC fallback. SoC average was unavailable;
  AC power had no meaningful time-to-empty estimate.
- `tools/SystemMenuSmoke.swift --awake`: display/system assertion types, Off,
  and a real 60-second expiry passed using the production deadline checker.
  `tools/ClipboardSmoke.swift` passed sensitive-type filters, dedup/pins, RTF,
  file URLs, size/count caps, image replay, persistence, cleanup and fuzzy search
  on its isolated pasteboard and temporary storage.
- Screenshots were captured and **viewed**: `/private/tmp/ms-bar-right.png`
  shows the tight skull/counts/CPU/pressure item; `/private/tmp/ms-bar-summoned.png`
  shows the green skull; `/private/tmp/ms-bar-awake.png` shows the active dot;
  `/private/tmp/ms-menu.png` shows seven Stats rows above the existing terminal
  controls and brightness slider. The full menu scrolls on the tested screen;
  its lower Leader Key/Quit section was checked through accessibility.
  `/private/tmp/ms-bar.png` is the requested origin-based bar capture; the active
  item moved between displays, so the right-side crop uses its actual AX bounds.
  Screenshots remain outside the public repo.

CPU observations: `top -l 6 -s 2 -stats pid,command,cpu -pid …` before (four items)
and after (one item, menu closed). These are means/ranges over the five interval
samples, discarding top's initial cumulative sample. The machine remained busy
with unrelated work and Stats.app running, so this is **not a controlled system
idle benchmark or a causal performance claim**.

| Process | Before mean (range) | After mean (range) |
|---|---:|---:|
| Leader Key | 0.46% (0.0–0.8) | 1.26% (0.5–3.0) |
| SystemUIServer | 52.80% (35.9–76.6) | 1.56% (0.0–5.2) |
| WindowServer | 63.32% (56.3–69.9) | 41.98% (30.5–52.2) |
| ControlCenter | 1.16% (0.3–2.4) | 9.36% (0.5–17.5) |

Raw logs: `/private/tmp/ms-cpu-before.txt`, `/private/tmp/ms-cpu-after.txt`.
Final build log: `/private/tmp/ms-v3-final-build.log`. No staging, commit or push.
The concurrent worker's `app/` tree was not edited. Stats.app remained running.

Not exercised: physical F19 routing, destructive sheol controls, actual
brightness changes/media-key routing, hot-plug/wake, Intel/other Apple Silicon
sensor fallbacks, or final clipboard paste into another app. The full Xcode test
suite was not run; the existing config-directory XCTest sandbox remains intact.
