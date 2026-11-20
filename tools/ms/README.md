# ms

Native Swift CLI and stdio MCP server for machine-spirit. macOS 14+, Swift 6.0+,
Apple frameworks only; no third-party packages or added runtime dependencies.
The package manifest defines build targets, with an empty dependency graph.
The repo's Brewfile remains the dependency inventory.

```sh
swift build -c release --package-path tools/ms
bin/ms screens
bin/ms windows --app Safari --json
bin/ms binds --tree --grep screenshot
bin/ms run s/s/c --dry-run --json
```

`bin/ms` resolves the repository relative to itself, including through a symlink,
builds on first run if the release executable is missing, then `exec`s it.
Build diagnostics go to stderr. Explicitly rebuild after source changes; the
wrapper intentionally does not run SwiftPM on every invocation.

## Commands

Every CLI command supports `--json`, including before the command. Errors exit 1
(window/audio/search misses and capture cancellation exit 11),
leave stdout empty, and print one line to stderr. Area-capture cancellation is quiet. `--` introduces literal positional
arguments, e.g. `ms run --dry-run -- -/-`. `ms --help` lists syntax.

| Command | Result / behavior |
| --- | --- |
| `screens` | Display ID, name, frame, visible frame, scale, refresh rate, main/built-in flags. Refresh rate is null when unavailable or variable. |
| `apps` | Regular running apps: name, bundle ID, PID, frontmost, hidden. |
| `windows [--app NAME] [--all-spaces] [--all-layers]` | Window ID, app, PID, title, frame, screen ID, layer, z-order, on-screen flag. App filter is a case-insensitive name substring or exact bundle ID. |
| `focus TARGET` | Activate an exact running app name/bundle ID, or raise a numeric window ID. Window focus may unminimize it. |
| `mouse` | Mouse position, screen ID and screen/usable frames, in **AppKit** coordinates. |
| `win place MODE [--app NAME]` | Place the focused window; modes and grow ladder below. |
| `win tile-all` | Unhide regular apps, unminimize windows, tile standard windows across all displays. |
| `win hide-all` | Hide every regular app, including Finder/frontmost, except Leader Key/MachineSpirit helpers. |
| `win cycle [--app NAME]` | Raise the next standard window in ascending window-ID order, wrapping. |
| `binds [--flat\|--tree] [--grep TEXT]` | Read the live config, including groups. Full keypath, label, type, value; case-insensitive search across all fields. Tree text is indented and search retains ancestors. JSON uses ordered rows with full paths in both modes. |
| `run KEYPATH [--dry-run]` | Resolve a unique live leaf, launch its action, then post the board notification. Dry-run only returns the launch plan. |
| `tmux [list]` | Installed `~/bin/sheol-core list --json`; JSON preserves its array/fields. Human output labels attached > 0 as living and 0 as wandering. |
| `tmux revive NAME` | Request revival into a new iTerm window through sheol-core. |
| `tmux detach NAME` | Request detachment of clients, leaving the session alive. |
| `capslock [on\|off\|toggle\|status]` | Real IOKit Caps Lock state; defaults to status. Changes verify the state and request the caps HUD. |
| `audio [list\|tile]` | CoreAudio active output apps/processes (14.4+); tile their standard windows on the mouse screen. |
| `translate-area [--to LANG]` | Interactive area capture, accurate Vision OCR, installed on-device translation, copy and text HUD. |
| `pulse [collect\|report [--hours N]]` | Append one local usage sample or summarize the last N hours (default 24). |
| `stats` | CPU busy % over 250ms, memory-pressure estimate %, kernel pressure level, swap used/total bytes, battery % or null, uptime seconds. |
| `screenshot [--screen ID\|--window ID\|--rect x,y,w,h] [--out PATH]` | Silent PNG; defaults to the main screen and a temporary file. Text prints its path; JSON adds pixel dimensions. |
| `clipboard [list [-n 20]\|get INDEX]` | Read-only history. Disabled unless `MS_ALLOW_CLIPBOARD=1`. Indices are zero-based, in persisted archive order. |
| `mcp` | Newline-delimited JSON-RPC 2.0 over stdin/stdout. `--json` is accepted but does not change the wire protocol. |

Except for `mouse`, frames use **global points, primary display top-left origin, y increasing
downward**. Secondary displays can have negative coordinates. Screens, windows,
AX matching, and capture rectangles use the same convention. Screen IDs are
Core Graphics IDs, not `screencapture -D` ordinals. A window's screen ID is the
display with the greatest frame overlap, or null when none overlaps. Z-order is
the original WindowServer list index, so filtering can leave gaps.

`windows` defaults to on-screen, layer-zero windows. `--all-layers` includes menu
and overlay layers; desktop elements remain excluded. `--all-spaces` also includes
off-screen/minimized windows reported by WindowServer. macOS may omit windows on
other Spaces; this is not a private Spaces API. A single top-level `notes` entry
explains possibly missing titles when Screen Recording is unavailable.

Window focus uses public Accessibility APIs and matches PID + frame (within two
points) + title when available. It fails on ambiguous matches rather than raising
an arbitrary window. Refresh `windows` if the target moved or closed. App focus
activates an already-running app; use an application bind to launch a cold app.

## Window placement and mouse

```sh
bin/ms mouse --json
bin/ms win place smart
bin/ms win place step
bin/ms win place center --app Safari --json
bin/ms win cycle --app 'Unreal Editor'
bin/ms win tile-all --json
bin/ms win hide-all
```

All `win` commands require Accessibility on the calling process. Missing access
prints `ms: Accessibility not granted to the calling process`, without prompting.
`place` uses the frontmost app's focused window, falling back to its main window,
then first standard window. `--app` accepts an exact running app name or bundle ID
(case-insensitive). No target window is a miss (exit 11).

`smart` selects the display under the mouse, falling back to the main screen.
Within the usable frame the outer 25% on both axes selects a quarter. Elsewhere the outer 10% of an edge selects a half. The interior selects the centered 90% window. The board preview uses the same geometry. The launcher passes the pointer position from key release with `win place smart --point X,Y`, in global AppKit coordinates.
`win place next-display` and `prev-display` transfer the relative frame between usable screens. The `display-left`, `display-right`, `display-up`, and `display-down` modes first look for a monitor aligned with the source in that direction, then consider diagonals. They return `status: "unchanged"` when no neighbor exists. `win resize --delta -120` shrinks a window about its center. Frame changes post a visual cue to the running board before applying the final bounds.

| Mode | Requested frame within the screen's visibleFrame |
| --- | --- |
| `amm` | Centered 90% width × 90% height |
| `max` | Full usable frame, excluding menu bar and Dock |
| `left`, `right`, `top`, `bottom` | Corresponding half |
| `tl`, `tr`, `bl`, `br` | Corresponding quarter |
| `center` | Keep size, clamp to usable area, center |
| `fullscreen` | Request native fullscreen |

`step` classifies all four current edges with tolerance `max(12pt, 2% of the
screen's usable dimension)`. Quarters grow to the containing left/right half;
halves grow to `amm`, then `max`, then native fullscreen. A step from fullscreen
exits to `max`; the next step returns to `amm`. Unrecognized frames go to `amm`.
The bounce marker is persisted atomically in `$TMPDIR/ms-win-place.json` with
`windowKey`, `last`, `fromFullscreen`, and epoch `t`. It expires after ten minutes
or a different window key. Keys use PID + uniquely matched CGWindowID, falling
back to a stable AX-title hash (identical titles can collide). All other placements
clear the bounce marker; tile-all clears the file.

Exiting fullscreen waits only while the command is active: at most 1.2 seconds,
checking every 50 ms. When move feedback is enabled, the mover checks the same window after the write, every 35 ms for up to 550 ms (1.3 s for native fullscreen). A matching frame within two points triggers the landing fade. A refused or constrained frame clears the outline through its cancellation path. Frame writes are
position → size → position to accommodate apps that clamp against the old position.
JSON reports `status: "requested"` and the requested frame, not verified geometry:
apps may silently clamp sizes or reject AX writes. Explicit write errors fail.

`tile-all` reads each window's attributes in one AX batch, unminimizes it, and
includes standard, non-fullscreen windows whose current size is at least 120×80.
Windows start on the screen they mostly overlap; integer quotas proportional to
usable display area move the smallest windows from overloaded screens. Each grid
is ordered by current top-left position, with 6pt gaps and a widened final row.
JSON includes successful requests and individual failures. Unresponsive apps can
still affect total latency despite a 150ms AX messaging timeout; the 30-window
performance target needs a live benchmark. No idle polling or background timers.

`hide-all` returns the count of successful hide requests and failure count. Finder
is hidden but its desktop remains. Bundle IDs beginning `com.machinespirit` and
the names `Leader Key`/`MachineSpirit` are excluded. `cycle` unminimizes and raises
the next standard window, then activates its app. At most one window exits 11;
other errors exit 1. Stable order uses CGWindowIDs matched by PID, frame and title
when available; ambiguous matches fail rather than picking an arbitrary window.
Non-Cocoa apps must expose standard AX windows; they need no keyboard shortcut.

`mouse` needs no Accessibility grant. It prints `x,y screen=ID`; JSON contains
`{x,y,screen,frame,visibleFrame}`. These coordinates are **AppKit bottom-left,
y increasing upward**, unlike `screens` and window output. Secondary display
origins can be negative in either convention. One shared rectangle reflection
converts using the primary screen's top edge, not the top of the desktop union.

MCP exposes `win_place` (required `mode`, optional `app`), `win_tile_all`,
`win_cycle` (optional `app`), and `mouse`, returning the same JSON as the CLI.
Window tools are marked as mutations; `mouse` is read-only. A CLI miss becomes
an MCP tool error without terminating the server.

`stats.memoryPressurePercent` is explicitly an estimate:
`100 * (1 - (free + inactive + speculative pages) / physical pages)`.
It is not Activity Monitor's memory pressure graph. `pressureLevel` separately
reports the kernel's normal/warning/critical signal, or unavailable. CPU percentage
is normalized across all processors, from 0 to 100, using `host_processor_info`.

## Caps Lock, audio, and area translation

`capslock` uses IOHIDSystem rather than synthesizing the Caps Lock key (which is
remapped to F19). Status reads only. Changes read back the state, print `on`/`off`
(JSON: `{"state":"off"}`), and request the MachineSpirit caps HUD. HUD failures do
not fail the command.

`audio list` reads CoreAudio process objects and active output streams. This is
**app-level only**: Safari/Chrome per-tab audio is not exposed by an API. Active
streams do not prove audible samples. Common helpers are attributed by their
containing app bundle, or WebKit's AppKit-provided host display name; JSON retains
`audioProcessPIDs` and the attribution method. Unresolved helpers stay separate.
Processes disappearing mid-query are skipped. `audio tile` reuses `win tile-all`
with only these app PIDs and only the screen under the mouse. It may unhide apps
and unminimize their standard non-fullscreen windows; individual failures are
reported in JSON. No active audio exits 11. It requires Accessibility.

`translate-area` uses `screencapture -i -x`; drag a rectangle or press Esc to
cancel quietly (exit 11). It recognizes text with Vision's accurate model,
language correction and automatic language detection. NaturalLanguage detects
the source; `--to` defaults to the first `Locale.preferredLanguages` entry.
On macOS 26+, Apple's [installed-language session initializer](https://developer.apple.com/documentation/translation/translationsession)
works without SwiftUI. Only an already-installed pair is attempted. Unsupported,
uninstalled or failed translation returns OCR text with an explicit note; it
never requests downloads or calls a network translation service. Same-language
text is copied unchanged. JSON separates `ocrText`, `text`, `source`, `target`,
`translated`, `copied` and `notes`.

This command **writes the live clipboard**, independently of the opt-in for
reading clipboard history. Captures use a private temporary directory and are
removed on completion/cancellation. No recognized text is stored by `ms`.
The text HUD includes source→target and at most 600 characters, encoded as URL
query items. A hidden `--image PATH` bypasses interactive capture for OCR tests;
it still copies the result and requests the HUD. No-text images exit 11.

## Pulse snapshots and reports

```sh
bin/ms pulse collect --json
bin/ms pulse report --hours 48
# Isolated verification, with no access to the default Library directory:
MS_PULSE_DIR="$TMPDIR/ms-pulse-test" bin/ms pulse collect
MS_PULSE_DIR="$TMPDIR/ms-pulse-test" bin/ms pulse report --json
```

`collect` appends exactly one JSON line to
`~/Library/Application Support/MachineSpirit/pulse/YYYY-MM.jsonl` and prints that
record. Timestamps and month partitions use UTC, rounded down to the minute.
Logs are mode 0600 in a newly created mode-0700 directory; append is locked, and
symlink log files are rejected. `MS_PULSE_DIR` overrides the directory for both
collect and report. Logs persist until the owner removes them; no retention or
background work is hidden in the CLI.

A sample includes uptime, load averages (1/5/15 minutes), kernel memory pressure,
swap used, free disk on `/`, battery percentage/cycles/health when available,
thermal state, frontmost app, regular app count and per-app window estimates.
**CGWindowList does not expose AX standard-window subroles or minimized state.**
`standardWindowsEstimate` counts layer-zero windows at least 120×80;
`offScreenWindows` also includes hidden and other-Space windows.
`minimizedWindows` is explicitly null, never mislabeled as an exact count.
Battery health can be an explicitly labeled raw/design-capacity estimate.

Running Safari and Chrome are queried in bulk through one `osascript`, with a
three-second Apple-event timeout and a shared three-second subprocess deadline.
A browser absent from the running-app snapshot is skipped; each script checks
again before addressing it. No browser is deliberately launched. Failed,
closed, timed-out or denied Automation queries have a status and unknown counts,
not zero. Only total tabs, ten leading HTTP(S) hostnames and duplicate counts are
stored: full URLs, titles and URL query strings are discarded. Duplicates are
extra copies of identical nonempty URLs within each browser, not across browsers.
`tmux list-sessions` counts sessions if tmux is on PATH; a missing server counts
as zero, while other failures remain unknown. Helpers are drained, killed on
timeout and reaped; no collector survives in the background.

`report` accepts integer hours 1–8760, reads relevant UTC month files and ignores
future/out-of-range samples. It reports averages/peaks, frontmost observations,
window peaks per app, tab change and duplicates, latest top domains, swap growth,
minimum free disk and notable pressure/thermal signals. Malformed lines are
skipped with a count. Missing browser samples are excluded from averages/trends.
One sample cannot establish a trend. These are hourly observations, **not time
spent in applications**; repeated manual collection changes sampling weight.

The target is <400 ms wall and <100 ms combined CPU, including subprocesses.
The three-second timeout is a failure ceiling, not that performance target.
On the development Mac, five final end-to-end samples with both browsers
running took 680/604/351/375/333 ms wall and 105/123/95/87/89 ms CPU. Three warm
runs met both budgets; the budget is not guaranteed under load/cold startup.
The first separate-process implementation consumed 140 ms CPU and was replaced
with the shared interpreter. Re-measure after deployment, especially under a
LaunchAgent's Automation identity.

`config/pulse/com.machinespirit.pulse.plist` is an **uninstalled template**:
StartInterval 3600, Background, Nice 10 and LowPriorityIO. The installer owner
must expand `__HOME__`, ensure `~/bin/ms` points to the prebuilt repo wrapper,
and handle Automation consent before loading it. No LaunchAgent is installed by
this change. Pulse contains private usage metadata: keep logs outside the repo.

| MCP tool | Arguments | Behavior |
| --- | --- | --- |
| `audio_list` | none | Read-only audio app/process JSON. |
| `pulse_report` | optional integer `hours` (1–8760, default 24) | Read-only summary from the selected pulse directory. |

Collect, Caps Lock, translation and audio tiling are not exposed through MCP.

## Messages conversation search helper

`bin/messages-find.sh` activates `com.apple.MobileSMS` and delegates to the
private native `ms messages-find` entry point. It waits up to two seconds for a
window, then searches the live AX tree (with a separate two-second search budget).
If search is absent it tries Show Sidebar/Show Conversation List or a sidebar
button, then the Find menu used by Tahoe's narrow Catalyst layout. It does not
resize the window or type text. Native AX directly verifies the focused subrole; it selects a standard window
instead of mistaking a transient Catalyst tooltip for the conversation window.

Catalyst can report successful `AXFocused` writes while leaving compose focused.
The fallback clicks only a visible `AXSearchField` whose screen hit-test matches
the same element, then verifies focused subrole. It never sends Return or a
fallback key into compose. Existing search text is preserved, with best-effort AX selection for replacement. Success exits 0;
a miss, obscured field or missing Accessibility exits 11.
`blur-field.sh`'s Messages branch calls this same helper. The `⇪ m e` keybind and
installation belong to the integration owner; this change does not edit either.
Live restoration/focus acceptance still needs a quiet Messages session: concurrent
window changes and typing were observed during verification, so no typing test
or claim of end-to-end script acceptance is made.

## Actions and privacy

Live config: `~/Library/Application Support/Leader Key/config.json`. `binds` never
falls back to the repo snapshot or changes config. Keyless actions cannot be
addressed individually and are omitted; group execution is deliberately rejected.

`run` executes only a leaf found in that config:

- Application: `/usr/bin/open -- PATH`, or `open -a NAME` for a bare app name.
- URL: `open -- URL`; non-HTTP(S) schemes use `-g`, matching the fork's background
  custom-URL behavior.
- Folder: `open -- PATH`, expanding `~`.
- Command: `/bin/zsh -lc VALUE`, detached with stdin/stdout/stderr at `/dev/null`.
  Returns after spawning, without waiting for completion or tracking exit status.
  The login-shell behavior is intentional per the `ms` interface; the fork's
  current runner uses `$SHELL -c`, so login startup files can affect the environment.

After a successful launch request, it posts distributed notification
`com.machinespirit.leader.fired`, `userInfo: ["path": keypath]`. Dry-run neither
launches nor notifies. Commands in the owner's config may be destructive; this is
an execution tool, not a command sandbox. Its MCP metadata marks that explicitly.

Only `list`, `revive`, and `detach` are exposed from sheol-core. Mutation checks that
the session exists and reports **requested**, because sheol-core suppresses some
underlying failures. It cannot promise a verified attachment. No kill/save/restore
verb is reachable through `ms tmux`.

Clipboard history is read from
`~/Library/Application Support/MachineSpirit/clipboard/index.json` (archive version
1, Foundation reference-date timestamps). `list` gives 160-character previews;
`get` gives full text, file URLs, or an image path. Image names must match the
entry UUID and `.png`; symlinks are rejected. It never reads the live pasteboard,
copies entries, changes pins, deletes entries, or writes the archive. History can
shift between calls; compare IDs, not just indices. Without explicit opt-in, the
CLI fails with `clipboard access disabled` and MCP neither lists nor accepts it.

Screenshot outputs are mode 0600, never overwrite an existing file, and require
an existing parent directory for `--out`. Temporary screenshots remain available
for the caller to consume and delete. MCP returns the same JSON text as the CLI
and a separate PNG image with long edge at most 1568 pixels; the on-disk original
keeps full resolution. Captures/config/clipboard content can be private: do not
check outputs into this public repo. Pulse explicitly persists usage metadata outside the package; captures and other live content are not checked into it.

## Install/registration

For the installer owner to merge: build the release target and expose the wrapper
on PATH. If installing at `~/bin/ms`, **symlink the repo wrapper**, rather than
copying it away from its package. Prebuild before registration to avoid a client's
startup timeout on the first compile. The core CLI/MCP needs no LaunchAgent, app registration or daemon. Hourly pulse
collection has the optional uninstalled template described above.

Replace `<repo>` with the absolute checkout path, keeping quotes if it contains
spaces. Exact Claude Code registration:

```sh
claude mcp add --scope user machine-spirit -- "<repo>/bin/ms" mcp
```

Equivalent command from the repository root:

```sh
claude mcp add --scope user machine-spirit -- "$PWD/bin/ms" mcp
```

Codex `~/.codex/config.toml`:

```toml
[mcp_servers.machine-spirit]
command = "<repo>/bin/ms"
args = ["mcp"]
startup_timeout_sec = 60
```

Clipboard is intentionally absent by default. For deliberate opt-in, add
`env = { MS_ALLOW_CLIPBOARD = "1" }` within that Codex table, or add
`--env MS_ALLOW_CLIPBOARD=1` to the Claude registration command before the server
name. Restart the client/server after changing the environment.

These registration instructions are provided for the owner; verification does
not execute them or edit `~/.codex` / `~/.claude` configuration. Syntax is checked
against installed client help and the [official Codex MCP documentation](https://developers.openai.com/codex/mcp).
The wire format follows [MCP 2025-06-18 tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
and [lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).

## Permissions and process lifetime

- **Screen Recording** on the invoking terminal or agent host: complete window
  titles and screenshots. Capture fails clearly when permission is missing;
  window enumeration can still return metadata. `ms` does not prompt for consent.
- **Accessibility** on that host: raise/unminimize individual windows and all `win` commands. Checked
  with `AXIsProcessTrusted`; app-only activation does not require it.
- **Automation** may be required by sheol's iTerm integration or by individual
  user-authored binds. Those actions inherit the owner's existing setup.
- **Clipboard** additionally requires `MS_ALLOW_CLIPBOARD=1`; it is never enabled
  implicitly by registration or by a tool argument.

Grant host permissions in System Settings → Privacy & Security, then restart that
host if needed. A terminal's existing grant does not guarantee a different agent
host is granted. TCC identifies the responsible process; macOS may show the host
or executable name.

Ordinary CLI invocations exit: **no idle process, timer, or polling cost**. `mcp`
exists only while its client keeps stdio open, blocking on input with no polling.
It holds process memory while connected, and exits on EOF. Tools are dispatched
serially; it advertises no background tasks, subscriptions, or cancellation support.

## Verification

```sh
swift build -c release --package-path tools/ms
swift test --package-path tools/ms
python3 tools/ms/verify-mcp.py
python3 tools/ms/verify-mcp.py --screenshot
python3 tools/ms/verify-mcp.py --json-flag
```

The optional smoke-test driver uses only Python's standard library (not a runtime
dependency). It performs the initialize → initialized → tools/list → screens →
windows sequence, parses all JSON responses, checks ping and disabled-clipboard
errors, rejects stray stdout/notification replies, and checks clean EOF shutdown.
`--screenshot` checks PNG dimensions/base64 and private file mode, then deletes the
capture. It does not print private window titles, run binds, or read clipboard data.

Window-command wave verification, 2026-11-19:

- Release build and all 16 Swift tests passed. Ten new tests cover coordinate
  reflection, all nine mouse zones/boundaries, named frames, classification edge
  tolerances, ladder transitions, state expiry/isolation, screen overlap,
  proportional rebalancing, grids through 30 windows, and MCP schemas/arguments.
- `bin/ms mouse --json` and `bin/ms screens --json` succeeded across three
  displays, including negative origins. `win place center` and `win place amm`
  succeeded on Finder with the existing Accessibility grant. Finder's resulting
  almost-maximize frame matched within whole-point rounding. Both commands also
  succeeded on T3 Code (Beta) after the final build.
- Timed `amm` runs took **0.20s wall time** on Finder and **0.12s** on T3 Code.
  These are individual observations, not a latency bound; the 150ms hold-command
  aim was not met consistently across these two runs.
- The updated MCP smoke test passed: 13 tools, parsed screen/window/mouse JSON,
  window routing with nonexistent targets, error handling and clean EOF shutdown.
- Live fullscreen transitions, non-Cocoa cycling, hide-all, and tile-all were not
  exercised. The 30-window / 1.5s tiling target and missing-TCC behavior remain
  unverified live. No permissions were changed or apps restarted/redeployed.

Earlier baseline verification (before window commands), 2026-11-19:

- Release build passed; six Swift tests passed (parsing, bind paths/argv, schema
  validation, geometry, MCP lifecycle/errors, clipboard archive decoding).
- First-run wrapper rebuilt a deliberately missing executable with build output
  confined to stderr; a symlink invocation from an unrelated working directory
  succeeded. Release executable is about 374 KiB on arm64.
- Every top-level command ran with and without `--json`; clipboard returned the
  intended disabled error. `mcp --json` preserved the protocol.
- Three displays: Built-in Retina Display 1728×1117 at 2×/120Hz; LC32G5xT
  2560×1440 at 1×/144Hz; M28U 1920×1080 at 2×/144Hz. Negative display origins worked.
- Sample stats: CPU 31.0%, memory estimate 56.8% / kernel normal, swap
  4,083,744,768 / 5,368,709,120 bytes, battery 80%. These are snapshots, not baselines.
- App focus and AX window focus both succeeded for the already-frontmost Safari.
  Screen, window and negative-origin rectangle capture succeeded; existing output
  paths were refused. Default PNG: 3456×2234; MCP PNG: 1568×1014. Test captures deleted.
- `run a/c`, `run k`, and `run 1/1/1` were checked **only with `--dry-run`**, in
  both formats (application, URL, command). No bind actually ran.
- Eight living tmux sessions were listed. Revive/detach were exercised only with
  a nonexistent name to verify rejection; no owner's session was changed. Actual
  iTerm revival/detachment remains unverified. Live clipboard contents stayed unread.

Trimmed MCP smoke transcript:

```text
initialize -> {"capabilities":{"tools":{"listChanged":false}},"protocolVersion":"2025-06-18","serverInfo":{"name":"machine-spirit","version":"0.1.0"}}
tools/list -> ["screens","apps","windows","focus","binds","run","tmux","stats","screenshot"]
tools/call screens -> isError=false, 3 records; JSON parsed
tools/call windows -> isError=false, 27 records; JSON parsed
ping -> {}
disabled clipboard -> isError=true
screenshot -> private PNG 3456x2234; MCP PNG 1568x1014
PASS: parsed responses, no notification reply/stdout noise, clean EOF shutdown
```
