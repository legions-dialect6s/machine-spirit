# machine-spirit — design cache & handoff notes

Forward-looking design decisions for the machine-spirit **app** (the node-graph
tool that will eventually replace the current Leader Key + Rectangle config
layer). This is a *cache of intent*, not yet-built work — it exists so an
upcoming full handoff starts from the accumulated thinking instead of a blank
page. For how the repo works *today*, see [`CLAUDE.md`](CLAUDE.md) and
[`README.md`](README.md). A detailed narrative of the
tmux/sheol working session (decisions, reversals, bugs, the reptyr verdict) is in
[`SESSION-LOG.md`](SESSION-LOG.md).

Status legend: 🧭 north-star direction · 🔒 firm decision · 🌱 shapes work in flight.

---

## Design cache (items 1–15, plus loose notes 16–21)

**1. Letter-by-letter logo build on summon.** 🧭
Typing `f19 → m-a-c-h-i-n-e-s-p-i-r-i-t` builds the machine-spirit logo letter by
letter, with per-letter sounds/animations, culminating in entry to
settings/node-graph. Doubles as a teaching moment for how nodes chain.

**2. Editable summon indicator.** 🧭
Replace Leader Key's plain dot with an animated green ASCII skull; shipped as
default and user-editable in the menu.

**3. Shield as a node in the graph.** 🌱 DEPRIORITIZED (shield is now opt-in / off-by-default; still a valid node example if it earns its place)
The busy-pane shield ships as a default node (greyed if no iTerm2), doubling as a
teaching example of what a node can do. *(Load-bearing for shield finalization —
see below.)*

**4. Karabiner = managed dependency, NOT rebuilt.** 🔒
Install the official signed build, own its config in-repo, reflect its status in
machine-spirit's menu bar, smoke-test config changes. Never rebuild (root
daemons + code-signing = keyboard-brick risk).

**5. iTerm2 = integrate via Python API, greyed-if-absent nodes.** 🔒
Never fork (huge, GPL).

**6. Smoke-test-before-update gate for all managed/forked dependencies.** 🔒
Scan incoming updates, block/flag ones that break machine-spirit's hooks.

**7. Launch model.** 🧭
`machinespirit` terminal command pre-F19; F19 summon-sequence entry post-setup.

**8. Hard-fork Leader Key + Rectangle only.** 🔒
MIT, small, owned as a learning goal. Karabiner + iTerm2 stay external/managed.

**9. Node model.** 🔒
A node acts as both group AND action, extensibly — current bindings map in
without restructuring.

**10. Graceful degradation.** 🔒
Absent-dependency nodes import as present-but-inert/greyed (nudge to install);
empty configs → empty graph, never crash.

**11. Migration architecture.** 🧭
Reimplement natively + import configs; forks are the starting substrate, the node
graph is the destination.

**12. Self-integrating onboarding (detect / auto-configure / guide).** 🌱
machine-spirit minimizes manual setup by detecting dependency state and
auto-configuring everything safe to automate, while guiding users through steps
that can't be automated for security reasons. Shield example: on install/launch
with iTerm2 present, auto-write the `⌘W → pane_shield()` binding [automatable],
handle the iTerm restart [automatable], and detect whether iTerm's Python API is
on — if not, guide the user through enabling it (it's a deliberate consent gate
no app can or should silently bypass). Generalize to all integrations:
detect → auto-apply safe config → guide consent-gated steps → grey-out/nudge if
absent. **Never silently flip a security consent.** The manual wiring being done
at dev-time is the spec for what the app will later automate.
*The concrete, enumerated form of that spec lives in
[`MANUAL-WIRING.md`](MANUAL-WIRING.md)* — every click-through step, why it can't
be scripted today, and the per-step automation strategy. Treat it as the
priority backlog for this item.

**13. Shield must be parameterized/modular.** 🌱 DEPRIORITIZED (opt-in shield; params still apply if it becomes a node)
Expose the shield's behavior as node parameters (hit count, per-hit sounds,
per-hit visuals/brightness, which processes count as "busy," flash vs.
pane-tracked overlay, enable/disable) so machine-spirit can present it as a
configurable node, not a hardcoded feature.

**14. tmux start-time protection.** 🌱  *(v1 shipped: `t t` bind, one-window plain tmux)*
Opt-in pane protection: launch a pane running inside tmux so the work outlives
the window. **Hard constraint that shapes the whole design:** you CANNOT adopt an
already-running process into tmux — tmux must be the parent from launch. So
protection is a *launch-time* choice, not a retrofit; the busy-pane shield
(#3/#13) is the complementary guard for the accidental-close case on an
unprotected pane. Ships as **plain tmux (one window + status bar)**, NOT control
mode `-CC` — `-CC` spawns separate native iTerm windows + a confusing gateway
window (tested, rejected as too confusing). Visible markers: the tmux status bar
+ an iTerm TMUX badge. A clickable pane-title button (gold when available,
Iron-Warriors-yellow when tmux'd) is a future item — iTerm's API doesn't expose
custom pane-title buttons, so it waits for the app. In the node graph this is a
"protected launch" action node with the session name as a parameter.

**15. Sheol — the necromancer's ledger of tmux spirits.** 🌱  *(v1 shipped: `t m u x` TUI)*
Theme is load-bearing, used in earnest across the code + docs: living sessions
walk **the land of the living**; detached ones are **restless spirits** wandering
**sheol**, the underworld, awaiting **revival** or **banishment**. v1 TUI
(`bin/tmux-sheol.sh`): two auto-refreshed rosters (LIVING vs SHEOL), arrow/jk nav,
**r** revive (reattach in a NEW window), **c** commune (attach in place to tend a
spirit without fully reviving; status bar shows `Ctrl-b d → back to sheol`), and
**d·d·d** banish (triple-tap with a decaying ◆ ward — the shield motif, since it's
irreversible). No Enter-to-attach (was an accidental-dump footgun).
**Deferred / future (all fit the theme):**
- The **nag** — a Dock/menu-bar presence that shows ONLY while spirits wander,
  hard to forget, auto-clears when empty. Needs a GUI agent, not a terminal
  script → the app's job, with a first-class GUI ledger tab.
  **v1 SHIPPED 2026-07-19 (in the FORK, not the app — owner's call, since the
  fork is the always-on menu-bar agent):** a second menu-bar item beside the
  skull (`SheolStatusItem` in the fork's `StatusItem.swift`) whose title is two
  live counts — **`active, invisible`** (attached sessions, then
  detached-but-running). Per owner's revised spec it's ALWAYS shown (`0, 0`
  when empty), not the auto-clearing version. Menu lists sessions grouped
  living/wandering; click a row → `sheol-core revive` (open/attach a window);
  "Open sheol ledger…" launches the full TUI (irreversible **banish** stays
  there, behind its ◆◆◇ ward). Polls `~/bin/sheol-core list --json` every 5s.
  **Load-bearing fix:** `sheol-core` now self-heals PATH + UTF-8 locale, since
  launchd-spawned GUI callers inherit neither — without it every GUI caller
  (this item AND the app's `SheolService`) silently read `0`. A first-class GUI
  ledger tab in the app is still the richer future.
- **Non-tmux "fragile" panes in the ledger** — list EVERY terminal + its state
  (fragile/basic · tmux-hardened · living · dead spirit). Needs iTerm's API to
  enumerate panes and cross-check tmux membership.
**Honest constraints baked in:** tmux has no "detached-at" timestamp (quiet-for =
`#{session_activity}` proxy; a true death-time means recording detach events
ourselves); and you CANNOT retrofit tmux onto a live process — necromancy only
revives the tmux-born (see #14).

---

## Load-bearing for the shield (context; shield now opt-in, off by default)

The busy-pane shield ([`bin/pane-shield.py`](bin/pane-shield.py), commit
`bd0516b`) is the first real integration and a live test of the app's whole
philosophy. Three cache items directly govern how it should be finalized:

- **#3 — it becomes a node.** Don't let the shield ossify as a hardcoded script.
  It is the reference example of a node that is both group + action, greyed when
  iTerm2 is absent (see #10).

- **#12 — the manual wiring is the automation spec.** The three steps a human is
  doing by hand right now to activate the shield are *exactly* what machine-spirit
  must later do itself:
  1. **Auto-write** the `⌘W → pane_shield(session_id: id)` iTerm key binding. *(automatable)*
  2. **Handle** the iTerm restart so the daemon auto-launches. *(automatable)*
  3. **Detect** iTerm's Python-API consent state; if off, **guide** the user to
     enable it — never bypass it. *(consent-gated → guide, don't automate)*
  Goal: **nobody ever wires this by hand.** The current README setup steps are a
  temporary stand-in for this onboarding flow.

- **#13 — keep the knobs exposed.** As the shield is hardened, keep its behavior
  as parameters, not constants: `hit count`, per-hit `SFX`, per-hit
  `visual/brightness`, the **busy-process list**, `flash` vs `pane-tracked
  overlay`, and `on/off`. Today these live as module constants + a disable flag
  in `pane-shield.py`; they are the seed of the node's parameter surface.
- #16 — Mini keybind changes (DONE): s a = Safari-specific open/focus/cycle; chr = same for Chrome; l l = ⌘L to address bar (universal). Per-browser keys each cycle their own windows.
#17 — Config staleness: Leader Key doesn't hot-reload; any config edit needs a Leader Key reload (reload-leaderkey.sh). machine-spirit must auto-reload after any config write so users never hit stale config.
#18 — Automate settings-open: f19 l k only opens Leader Key settings if already open; fix when Leader Key is forked (own the settings-open behavior).
#19 — Universal browser gestures: window-cycle + address-bar gestures should work across Safari/Chrome/Arc/Brave.
#20 — Page-field cycling (l l extended, HARD/future): Research concluded the robust path is a browser extension (Safari + Chrome content scripts via native messaging, à la Vimium's gi), NOT keybind/AppleScript/accessibility. Simulated-Tab too crude; Accessibility API browser-brittle (Chrome needs --force-renderer-accessibility, Firefox unsupported); AppleScript-JS needs a fragile per-browser toggle. So field-cycling = a machine-spirit companion browser-extension feature (Phase 3+) with a native-messaging bridge. l l ships now as address-bar-only. Reuse Vimium/SurfingKeys content-script approach as reference.
#21 — Shield sound (deferred): stdlib synth can't do the target "minor-key cybergoth" vibe (3 passes bounced — needs real samples or proper synth). Shield ships silent-by-design; CONFIG filenames are a drop-in contract — add real cybergoth .wavs at those asset paths (or wire as node params) later, zero code change. Also #13 (parameterize) applies: sounds become node params.
Also: CC asked whether to commit the ~4 staged commits (Safari/browser cycle, shield redesign, VISION.md, onboarding docs). Yes — commit them per-subsystem as it proposed, but hold the push until I confirm.

#22 — Free-form graph (owner, 2026-07-06, on first sight of the altar): nodes draggable in 360°, a sprawling canvas that "can go on for a while and be complex" — not only left→right tidy-tree. `GraphViewState` (positions per node id) was built to hold user-dragged positions; needs drag UX + sidecar persistence + a layout-vs-freeform mode. Owner follow-up: scroll-wheel zoom too (needs an NSView wrapper or scrollWheel event monitor with cursor-anchored zoom). Slider + ⌘=/⌘- + wide zoom clamp shipped in Phase 1; the rest is Phase 2.
#23 — Keystroke-path search in BOTH views: type the actual key sequence (`q q q`) to walk/jump to that node; Esc or click-away blurs (note: Esc is not a bindable leader key in the config, so it's safe as blur). Mirrors Leader Key's own grammar — search by muscle memory. Phase 2.
#24 — Value affordances: click a CMD/APP/DIR node's value to reveal the script/app/folder in Finder (read-only-safe, cheap — could land as post-Phase-1 polish); later, execute actions straight from the app like Leader Key does (needs the execution engine, Phase 2+).
#25 — Side-by-side witness+altar (owner suggestion) as an alternative/addition to Tab-toggle — "node graph / directory with the open one selected". Evaluate after Tab-switch (one selection, two projections) lands. SHIPPED 2026-07-06 ([P1.10]: side-by-side panes, focused pane marked, Tab switches); owner approved on sight. #23 largely shipped too (letter-walk in both views; full text search still open).
#26 — 🔒 Owner ruling (2026-07-06): live tmux sessions do NOT belong inside the config graph — that surface is for binds/commands only. The in-graph living sheol node ([P1.9b]) was reverted in [P1.11]. Spirits get their OWN surface in the app: the GUI ledger + nag of #15 (a strip/pane that exists only while spirits wander; revive/banish with the ◆◆◇ ward live there). sheol-core + SheolService + the footer count survive as its plumbing; the reverted graft/strike code lives in git history at [P1.9b]–[P1.10] for reuse.
#27 — Altar polish backlog from the owner's first drive (2026-07-06): organic idle micro-drift ("creepy alive" — TimelineView, taste required); the m-a-c-h-i-n-e-s-p-i-r-i-t live bind opening MachineSpirit.app (design cache #1 flourish — needs a live-config write, owner must explicitly confirm before it happens); refresh as a graph-wave animation (breathe shipped; wave later); full text search.
#28 — Per-key animation as a node parameter (owner, 2026-07-06): every key/node will carry "a lil animation" — part of why group+action duality stays in the model even before execution exists. Belongs to the node editor era: animation type/params on ActionPayload-adjacent metadata, rendered by the indicator and the graph. Keep the model extensible for it (extras already carries unknown fields losslessly).
#29 — 🔒 Aesthetics are parameters (owner, 2026-07-06): every motion/animation shipped in the app (trace growth on boot/refresh, line sway + agitation, directory cascade, header typewriter, glide durations, glow intensity) must eventually be exposed in settings — off-switchable and tunable. Build new effects with a single knob-struct in mind so wiring a future settings pane is mechanical.
#30 — Drag-and-drop nodes (owner-confirmed direction): drag starting ON a node moves it (no modifier), drag on space pans; moved positions persist via GraphViewState sidecar (app-support JSON); an "auto-sort" action clears overrides back to the radial layout; traces re-route around moves. Plus #24's open-script affordance (double-click a CMD node → reveal/open the referenced script). Next slice after the living-lines pass.
#31 — Label-aware dynamic trace rerouting (owner, 2026-07-06): when zoomed out, traces should bend around label text so density never costs legibility ("information dense but visually pleasing"). Radial outward label placement + backing pills shipped as the 80% ([P1.14]); true label-collision routing (compute label rects, route curves around them) is the 20% — real work, graph-drawing territory. Pair with #22's freeform mode.
#32 — Embedded sheol terminal pane (owner asked "whatchu think"): recommendation given — a REAL terminal emulator inside the app needs SwiftTerm (MIT, mature, the only sane embed on macOS); doable as a right-side ledger pane that is closable in-app, with "open in iTerm instead" as the escape hatch. Cheaper interim: AppleScript-position an iTerm window snapped beside ours. Decide when the ledger surface (#26) gets built — SwiftTerm adds a dependency but delivers exactly the owner's ask. Owner blessed vendoring ("harness-fork it"). Capability answers (2026-07-06): the whole sheol TUI works in SwiftTerm unchanged (it's just a pty — commune/attach, single-instance pkill, ward, all of it); "pop out to iTerm" works BECAUSE of tmux (you can't move a pty between apps, but detach-embedded-client + iterm-new-window attach = the same session moves bodies); "snap a spirit's pane into another tmux window" = tmux join-pane/move-pane, a natural future ledger verb; "spawn a new living terminal from sheol" = tmux-launch.sh behind a new TUI key (n?) — small, do it when the ledger pane lands.
#33 — Multiple leader graphs in one workspace (owner, 2026-07-06): a second radial graph beside the first, e.g. mouse-button-4 with q→Spotlight, e→wallpaper settings. Shipped as an HONESTLY-UNBOUND exhibit in [P1.16] (renders beside the main board, labeled unbound; MB4 triggers nothing). Making it real needs the input layer to listen to extra devices (leader keys, plural — README north star) + config schema for multiple roots. Configurable leaders are the editor era's job.
#34 — Gate/group LATCH (owner, 2026-07-06): drag a child close to its parent and it latches on as a smaller attached node — compression for hand-organizing. Pairs with a future auto-compact. Editor-era interaction; design when drag UX matures.
#35 — 🔒 Learn the owner's hand layout as the auto-organize objective (owner asked "could we eventually learn to do this automatically?" — yes): their manual arrangement (2026-07-06 screenshots + persisted sidecar) = long even spokes, per-cluster breathing room, labels clear of lines. Fit an automatic layout to that: force-directed relaxation with label-rect collision constraints, seeded by the radial layout, tuned against the saved sidecar as ground truth. A deep-research pass on graph-drawing literature (force-atlas, label placement) is warranted WHEN this gets built — not needed for day-to-day slices.
#36 — Fire-animation when a bind actually runs (owner): when a leader-key command executes while the app is open, its trace should pulse. Needs a signal: the LeaderKey FORK can ping the app on action fire (URL scheme machinespirit://fired?path=... — we own the fork precisely for this). Wire when the fork becomes the daily driver.
#37 — Per-keystroke pulse (owner, 2026-07-12, on first seeing #36 land live): instead of firing the whole route on action EXECUTE, pulse each node AS the key is pressed during navigation — the route lights up incrementally as you type `s`→`s`→`w`→`s`, and RETRACTS on backspace (leader-key nav pops a level). Truer to the muscle-memory feel and turns the board into a live typing mirror, not a completed-prompt replay. Shape: the fork fires a lighter ping on each navigate (machinespirit://nav?path=... on group-descend, and a retract on ⌫), the board holds an incremental lit-path state that grows/shrinks, and the EXECUTE ping ([P2.5d]) becomes the final flourish. Bigger than #36 (per-keystroke fork hooks + board nav-state machine) — cache, build post-Phase-2. Owner verified the execute-pulse (#36) works and does NOT steal focus (activates=false holds). **Inbound-ping plumbing ready (2026-07-15):** the app→fork direction must use the fork's OWN scheme **`msleaderkey://`** (e.g. `msleaderkey://navigate?keys=s,s,w`), NOT bare `leaderkey://` — LaunchServices resolves `leaderkey://` to *stock* Leader Key in `/Applications` (which then launches + crashes), never reaching the fork. The fork now claims `msleaderkey` and sets `LSMultipleInstancesProhibited`, so those pings route to the running daily driver (verified: single instance, zero spawns/crashes). URLSchemeHandler already parses `navigate`/`show`/`hide`/`activate`.
#38 — Distinct skull app icon (owner, 2026-07-16): the menu-bar icon is a skull, but the Dock / ⌘-Tab / Settings-window `AppIcon` is still stock Leader Key's. Make an `AppIcon.appiconset` skull (the skull-0 angled-eye silhouette matching the menu-bar mark) so the fork reads as the fork everywhere. Needs the full iconset sizes (16–1024), a `clean build`, and a re-sign with the stable cert — recipe in [`forks/LeaderKey/AGENTS.md`](forks/LeaderKey/AGENTS.md) → "build, sign, redeploy". Small; safe now that rebuilds keep TCC grants (no more grant→re-prompt loop). **SHIPPED 2026-07-18:** the AppIcon is now the *summoned* skull — the same silhouette as the menu-bar `StatusItem`, painted machine-spirit green (`#36DE6A`, matching `StatusItem-filled`) on a dark squircle with a soft summon-glow halo. Reproducible from the mark via [`forks/LeaderKey/tools/make-appicon.sh`](forks/LeaderKey/tools/make-appicon.sh) (renders the vector skull → all catalog sizes; PNGs ship pre-rendered per philosophy #4). Clean-built, re-signed with the stable cert (TCC grants intact), redeployed; verified via `NSWorkspace.icon(forFile:)` resolving to the green skull.

---

## Busy-pane shield: kept as opt-in (off by default) + learnings

The busy-pane shield (escalating Halo-style guard on closing a busy iTerm pane)
was briefly removed, then **kept as an opt-in toy, OFF by default**. It works
mechanically end-to-end; the *point* was aesthetic game-feel, which only partly
landed, so it's not worth being on by default — but it's fun, so it stays behind
a flag.

**Why it went:**
- The **safety** it provided is a one-checkbox iTerm built-in: *Settings →
  Profiles → Session → "Prompt before closing → If there are jobs besides the
  login shell running."* The shield reinvented that the hard way.
- The **swag** (per-pane flares, a skull death, "cybergoth" SFX) is where all the
  effort went, and terminals aren't game engines: per-pane visuals are limited to
  background-color + badge + injected text, and procedural stdlib audio can't do
  "cool" (3 sound passes bounced; real samples/synth needed). Not a model/effort
  miss — a wrong-medium-for-aesthetics miss.
- Lesson kept: put game-feel where the medium supports it (the **splash**, and
  **sheol's** theme). The shield's escalation/ward motif survived — reused as
  sheol's `d·d·d` banish.

**Toggle (no re-wiring needed):** the ⌘W keybinding + daemon are wired ONCE
(already done). On/off is just a flag file the daemon checks:
- `~/bin/shield-on.sh` — arm (busy panes escalate on ⌘W)
- `~/bin/shield-off.sh` — disarm (⌘W closes normally) — **the default**
The daemon is symlinked into iTerm AutoLaunch (auto-starts on iTerm launch) and
started now; `install.sh` re-creates the symlink on a fresh machine (default off).

**If you ever want it fully gone:** delete `~/bin/{pane-shield.py,shield-*.sh}`,
the AutoLaunch symlink(s), and the ⌘W keybinding (iTerm → Keys → Key Bindings →
select the ⌘W row → `−`); then use iTerm's built-in *Prompt before closing → if
jobs besides the login shell running* for plain safety.

**Heat/pileup lesson (real bug found + fixed):** an earlier sheol trap caught
SIGTERM without exiting, so `pkill` couldn't end it → instances piled up, each
redrawing every 2s → WindowServer/iTerm pegged, keyboard lag, hot Mac. Fixes:
INT/TERM trap now exits; sheol only redraws when the roster/selection changes
(idle ≈ free); a lost stdin breaks instead of busy-looping; the opener force-kills
stragglers. Lesson for any long-running TUI here: **traps must exit, redraw only
on change, and guard the read loop against EOF.**

---

## Next-phase handoff (→ machine-spirit app)

**Where the repo is now (all live + committed after this):** Leader Key launcher,
Rectangle window grid, Karabiner remaps, the terminal splash, browser gestures
(`s a` window-cycle, `l l` address bar), and **tmux protection + sheol** (`t t`
launch, `t d` split, `t m u x` ledger). Shield removed. This is a solid, coherent
"environment as code" base.

**Next:** move to building the machine-spirit **app** (the node-graph tool). The
spec is this whole file — design cache **1–15** (2, 3, 13 aside: 3/13 retired) +
loose notes **16–21**. Sheol (#15) and its necromancer theme are the richest
seed; the shield's removal is itself a design lesson (know which medium carries
which idea).

**Open threads carried forward (not blocking):**
- **sheol nag + GUI ledger** (#15) — Dock/menu-bar haunt while spirits wander;
  needs a GUI agent → app.
- **Non-tmux "fragile" panes in the ledger** (#15) — needs iTerm API pane
  enumeration → app or a companion helper.
- **`c` commune status-bar hint** currently persists on the session after detach;
  could scope/reset it. Minor.
- **Page-field cycling** (#20) — browser extension, Phase 3+.
- **"bring all iTerm/tmux windows to front" bind** — user reported a focus gap;
  needs clarification on which bind + exact failure before changing anything.
- **`s a` browser-window-cycle skips minimized windows** (owner, 2026-07-06:
  1 open + 1 minimized Safari window; the minimized one never rose). Root
  cause: the script rides ⌘` ("move focus to next window"), which ignores
  minimized windows by design. Desired: first press restores/raises ALL of the
  frontmost browser's windows, further presses cycle. Fix shape: in
  `bin/browser-window-cycle.applescript`, unminiaturize via System Events
  (`set value of attribute "AXMinimized" to false` per window) before cycling —
  keep it browser-agnostic, dialog-safe (try-wrapped). Deferred past Phase 1
  (live `~/bin` is behind the live-system boundary this phase).
- **Pane-title button** (#14) — not in iTerm's API; app-era.