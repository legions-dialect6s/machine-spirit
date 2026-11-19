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

Every CLI command supports `--json`, including before the command. Errors exit 1,
leave stdout empty, and print one line to stderr. `--` introduces literal positional
arguments, e.g. `ms run --dry-run -- -/-`. `ms --help` lists syntax.

| Command | Result / behavior |
| --- | --- |
| `screens` | Display ID, name, frame, visible frame, scale, refresh rate, main/built-in flags. Refresh rate is null when unavailable or variable. |
| `apps` | Regular running apps: name, bundle ID, PID, frontmost, hidden. |
| `windows [--app NAME] [--all-spaces] [--all-layers]` | Window ID, app, PID, title, frame, screen ID, layer, z-order, on-screen flag. App filter is a case-insensitive name substring or exact bundle ID. |
| `focus TARGET` | Activate an exact running app name/bundle ID, or raise a numeric window ID. Window focus may unminimize it. |
| `binds [--flat\|--tree] [--grep TEXT]` | Read the live config, including groups. Full keypath, label, type, value; case-insensitive search across all fields. Tree text is indented and search retains ancestors. JSON uses ordered rows with full paths in both modes. |
| `run KEYPATH [--dry-run]` | Resolve a unique live leaf, launch its action, then post the board notification. Dry-run only returns the launch plan. |
| `tmux [list]` | Installed `~/bin/sheol-core list --json`; JSON preserves its array/fields. Human output labels attached > 0 as living and 0 as wandering. |
| `tmux revive NAME` | Request revival into a new iTerm window through sheol-core. |
| `tmux detach NAME` | Request detachment of clients, leaving the session alive. |
| `stats` | CPU busy % over 250ms, memory-pressure estimate %, kernel pressure level, swap used/total bytes, battery % or null, uptime seconds. |
| `screenshot [--screen ID\|--window ID\|--rect x,y,w,h] [--out PATH]` | Silent PNG; defaults to the main screen and a temporary file. Text prints its path; JSON adds pixel dimensions. |
| `clipboard [list [-n 20]\|get INDEX]` | Read-only history. Disabled unless `MS_ALLOW_CLIPBOARD=1`. Indices are zero-based, in persisted archive order. |
| `mcp` | Newline-delimited JSON-RPC 2.0 over stdin/stdout. `--json` is accepted but does not change the wire protocol. |

Frames use **global points, primary display top-left origin, y increasing
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

`stats.memoryPressurePercent` is explicitly an estimate:
`100 * (1 - (free + inactive + speculative pages) / physical pages)`.
It is not Activity Monitor's memory pressure graph. `pressureLevel` separately
reports the kernel's normal/warning/critical signal, or unavailable. CPU percentage
is normalized across all processors, from 0 to 100, using `host_processor_info`.

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
check outputs into this public repo. No live content is persisted in this package.

## Install/registration

For the installer owner to merge: build the release target and expose the wrapper
on PATH. If installing at `~/bin/ms`, **symlink the repo wrapper**, rather than
copying it away from its package. Prebuild before registration to avoid a client's
startup timeout on the first compile. No LaunchAgent, app registration, or daemon
is needed. No other installer/app files are changed by this package.

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
- **Accessibility** on that host: raise/unminimize individual windows. Checked
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

Observed on the development Mac, 2026-11-19:

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
