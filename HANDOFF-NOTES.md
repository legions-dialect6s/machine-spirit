# machine-spirit — design cache & handoff notes

Forward-looking design decisions for the machine-spirit **app** (the node-graph
tool that will eventually replace the current Leader Key + Rectangle config
layer). This is a *cache of intent*, not yet-built work — it exists so an
upcoming full handoff starts from the accumulated thinking instead of a blank
page. For how the repo works *today*, see [`CLAUDE.md`](CLAUDE.md) and
[`README.md`](README.md).

Status legend: 🧭 north-star direction · 🔒 firm decision · 🌱 shapes work in flight.

---

## Design cache (items 1–13)

**1. Letter-by-letter logo build on summon.** 🧭
Typing `f19 → m-a-c-h-i-n-e-s-p-i-r-i-t` builds the machine-spirit logo letter by
letter, with per-letter sounds/animations, culminating in entry to
settings/node-graph. Doubles as a teaching moment for how nodes chain.

**2. Editable summon indicator.** 🧭
Replace Leader Key's plain dot with an animated green ASCII skull; shipped as
default and user-editable in the menu.

**3. Shield as a node in the graph.** 🌱
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

**13. Shield must be parameterized/modular.** 🌱
Expose the shield's behavior as node parameters (hit count, per-hit sounds,
per-hit visuals/brightness, which processes count as "busy," flash vs.
pane-tracked overlay, enable/disable) so machine-spirit can present it as a
configurable node, not a hardcoded feature.

---

## Load-bearing for the shield (finalize with these in mind)

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