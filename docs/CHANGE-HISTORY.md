# Machine Spirit change history

**The first round of randomness was already in the classic build.** On November 19, `3f8c0bf` introduced the typing overlay’s Randomness slider, small arrival offsets, speed-reactive effects, and radial hover drift. The later Numogram proportions, thin gradient traces, usage circles and lightning came from a separate experiment. You can keep the first round independently of that experiment.

## The visual and window changes, in order

Times are local to Los Angeles. For November 19, the source times come from Git. Times marked *report* refer to the saved worktree report. An install row has separate evidence from the source revision.

| When | What changed | Where to find it |
| --- | --- | --- |
| Jul 4 | Repeated letters became a spatial window grid. Rectangle placed windows. The resize AppleScript animated grow/shrink. | `f361e40` |
| Jul 6 | The **board** gained growth, sway, taper and cascades. Later revisions made it still at rest, revisited curves and sway, then restored straight followable traces. These precede the typing overlay. | `130bc60` → `948cd3c` → `fb9f909` → `efee0ea` |
| Sep 25 | The board’s render clock learned to stop when idle. | `55e0e81` |
| Nov 19, 07:51 | The optional board and transparent **typing overlay** became separate surfaces. | `0db9318` |
| 09:23–09:39 | The overlay moved to Core Animation with a native-refresh panel, icons and layered traces. Real node labels and a local backdrop followed. | `6af954c`, `0483acd` |
| 12:53 | Smart placement classified the mouse region. The separate step action advanced the window through the resize ladder. | `61427ec` |
| 13:05–13:08 | The classic overlay gained the skull, letter pop, shockwave, hover route, clickable nodes and optional curved traces (off by default). Leader Key added hold/repeat, Back, and the Caps–Space–Space ladder. | `552ad58`, `2966bd8`, `d3555c2` |
| 17:27 | **First typing-overlay randomness.** A bounded offset/rotation on arrival, faster-typing shake and glyph slices, stronger shockwaves, and the ghost exit. The Graphics sliders defaulted to Randomness 0.35, Shake 0.4 and Glitch 0.5. The follow-up in this same commit added 6–14 pt radial movement around a hovered route, varying per hover change, plus the glass Caps pill. Space gained a mouse-driven green preview. The two worktree reports preserve the order within this one commit. | `3f8c0bf`, merged by `1030c2d`. [First FX report](../app/MachineSpirit/Tests/OverlayWave2Verification.md) · [Hover follow-up](../app/MachineSpirit/Tests/OverlayFXFollowupVerification.md) |
| 17:32–17:50 | Hold mode stopped grabbing focus every 50 ms. The Caps badge began following the pointer. The board app saved for rollback is the **17:40 classic build**. The subsequent merge into main added the launcher’s audio menu. | `044cf9a`, `f4dddd4` → `91f06ad`, `ebcbb15` → `2fb0c47`. Classic board executable SHA-256 begins `0892c10c8d2b8119`. |
| 17:57 *report* | **Pass 4, calm motion.** The fx4 worktree tried 3–8 pt deterministic hover travel, a 60 ms debounce, slow exits, and presentation-layer retargeting. It also changed ordinary navigation to 600 ms and restyled the Caps HUD/follower. This was an isolated build at the time of its report. | `f489c7e:app/MachineSpirit/Tests/OverlayCalmVerification.md` |
| 18:12 *report* | **Pass 5, Numogram.** Thin circles, default curved gradient traces, changed proportions, usage bubbles, skull pump, lightning, and red Caps styling were added on top of pass 4. The `1.2k` and `12` pictured in the verification came from a seeded stats fixture. | `f489c7e:app/MachineSpirit/Tests/OverlayNumogramVerification.md` |
| 18:21 *report* | **Pass 6, HUD.** The worktree changed Caps to bare red lettering with trails, added a persistent hardware-state indicator, and changed the placement preview to a thin square outline. | `f489c7e:app/MachineSpirit/Tests/OverlayBrandVerification.md` |
| 18:35 | **Installed for comparison.** The combined experimental board ran on the Mac. Its saved executable SHA begins `82a10cb0eb971543`. Alexander tried it and rejected the altered lines, proportions and lightning. | The installation log and saved replaced bundle agree. `f08c52d` preserves the full working source snapshot, including the three pass reports. |
| 18:36–18:47 | Pin work was recorded on its own branch. Lens, OCR and a separate after-landing outline were developed in the lens worktree. The classic board was restored around 18:42. The experimental tracked files were stashed at 18:47 with the untracked reports as a separate stash parent. | `5a71ef0` (pin), `wt/lens` (uncommitted), `126b7d4` and `126b7d4^3`. The lens and pin changes are outside the classic main tree. |
| 19:01–19:03 | **Second installed comparison.** The classic look was paired with the calm navigation timing, 25%-by-25% corner hit areas, hold-to-aim, arrow display transfers, and a green outline with AX arrival confirmation. Several established grid shortcuts switched from Rectangle to the CLI. | `2251f84`. This candidate included the hard-coded 600 ms navigation and put readback on the serial command path. Its notification could reach the screen after the actual window moved. |
| 19:07–19:09 | **Restored.** Both original signed apps, the CLI, resize AppleScript and complete live shortcut config were restored from the pre-pass copies. The revert matched the `2fb0c47` source tree. The next change added the audit. After this rollback Alexander said the interaction felt good again. | `2e0e909` → `d867da5`. [Opus review and rollback evidence](OPUS-WINDOW-MOTION-HANDOFF.md) |
| 19:14 | Removed the 6–14 pt hover displacement. Hover still highlights and scales the route. The original arrival randomness, tempo effects, and 140 ms forward / 90 ms Back timings are present. | `64cbc74`, installed with the board at 19:19. |
| 19:14–19:16 | Reintroduced two matching arrows after Caps for directional display movement. The only new live bindings are the four arrow routes. They preserve relative window bounds and stop at an outer edge. Existing grid commands still call Rectangle. | `35161ad`. Signed launcher installed at 19:16, executable SHA-256 begins `2cda08984cca8044`. |
| 19:19 | Installed the resident board’s pre-commit cue. A quarter or half previews on its penultimate letter. An arrow previews on the first tap. F/F and G/G identify the target monitor. Arrival observation is independent of the keyboard command queue. | `2ac5a6a`. Signed board SHA-256 begins `02a73b70db4de5a9`. Private IPC and a real disposable window verified cue-before-move ordering, arrival fade, cancellation and cross-display movement. Physical key-to-pixel timing remains unmeasured. |
| 20:10 | Alexander accepted the running build as definitive. Added Safari Gmail on Caps G M with hold-M tab collection and reloaded the live shortcut tree. Captured the existing Tripo / Translate branches in the source mirror. Both signed app executables are the same as at 19:19. | Annotated tag `v0.5-classic-driver`. [Checkpoint and recovery copy](../CHECKPOINTS.md#v05-classic-driver--definitive-daily-driver-2026-11-19) |

## Looking up one change

To inspect the first randomness implementation, run `git show 3f8c0bf -- app/MachineSpirit/Sources/TypingOverlay.swift`. To compare the whole rejected motion experiment with the agreed baseline, run `git diff 2fb0c47 2251f84`. To retrieve the complete staged Numogram source snapshot, including new resources, read `git show f08c52d:<path>`. Four T3 checkpoints between 18:37 and 18:43 captured that same tree. The intermediate reports record what was implemented within each pass. The inspected refs identify a combined tree. The exact intermediate trees for passes 4 and 5 remain unverified.

Future entries should record **when, what changed on screen or under the keys, which revision, whether it actually ran, and what was kept or reversed**. The exact installed app can differ from a nearby source checkout when parallel worktrees are active.

## Repository chronology through the pre-commit window preview

The index includes each development commit reachable from `2ac5a6a`, plus the one additional branch commit on `wt/pin`, ordered by local commit time. A merge row marks integration. Installation dates require separate evidence. The timeline above records known worktree and deployment events separately. Subject lines below come from the commit authors.


### 2026-07-03

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 03:50:01 | `1f50875` | Initial commit: aesthetic-mac-setup |
| 06:58:37 | `905fd3e` | sync live configs: Leader Key, Karabiner, shell + docs |

### 2026-07-04

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 10:41:18 | `3f014e0` | splash: hotkey-window boot splash (banners, logos, quotes, charms) |
| 10:41:35 | `b2b1a11` | rename to machine-spirit; splash showcase, deps, and agent handoff |
| 10:47:19 | `84dda03` | Update README.md |
| 10:52:00 | `f361e40` | window management: spatial grid, animated resize, Rectangle dep |
| 10:52:00 | `0043dad` | docs: window management section + full keybind reference |
| 11:01:51 | `2ee2ee5` | splash: charms blink and appear more often |
| 11:06:39 | `bdce60a` | splash: charms flicker in instead of blinking |
| 11:17:05 | `ed0c1ef` | web-jump: one universal focus-or-cycle-or-open script for all sites |
| 11:17:05 | `12f5c79` | bin: capture screenshot suite; recursive bin/ sync and install |
| 11:54:35 | `a8a1f1a` | splash: deeper Planescape: Torment quotes |
| 13:52:09 | `b1c2d31` | leader-key: digit thirds, almost-maximize, Grok, center-window, VMware helper |
| 13:52:09 | `b2f6315` | README: reconcile keybind reference with live config; add visual-customization roadmap |
| 15:04:44 | `f44bafe` | leader-key: swallow failing commands so none can throw a focus-stealing dialog |
| 15:14:04 | `bd0516b` | busy-pane shield (v0.1): escalating Halo-style close guard for iTerm panes |
| 15:36:45 | `2c9b803` | docs: design cache / handoff notes (roadmap items 1-13 + shield finalization) |
| 20:25:44 | `5951497` | leader-key: universal browser window-cycle (s a) + address-bar jump (l l) |
| 20:26:11 | `66a3ae0` | busy-pane shield: 4-beat redesign — terminal-native visuals, skull death, silent |
| 20:26:21 | `bcd2aec` | docs: add VISION.md — shareable project vision |
| 20:26:35 | `e35fc78` | docs: MANUAL-WIRING.md onboarding checklist + fix Cmd-W bind syntax |

### 2026-07-06

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 03:44:20 | `821cd60` | tmux protection + sheol (necromancer ledger); remove busy-pane shield |
| 05:10:02 | `6fb5e3f` | sheol: fix heat/pileup + context banish; restore shield as opt-in; i t all-windows |
| 05:15:24 | `ba37581` | sheol: fix instant-death — bash 3.2 read -t timeout returns 1 like EOF |
| 05:30:49 | `af8dcfd` | sheol: auto-update on external changes (command/detach/kill), ~1s refresh |
| 05:50:33 | `4b5ba2f` | docs: SESSION-LOG.md — the tmux/sheol session narrative + reptyr verdict |
| 06:24:13 | `6d77ef2` | harden tmux helpers + sheol (Codex review pass) |
| 12:02:12 | `29a20d9` | [P1.1] capture loved state (sigil assets) + checkpoint ledger |
| 12:02:44 | `22a3f1f` | Squashed 'forks/LeaderKey/' content from commit 16bcb30 |
| 12:02:44 | `fc82aa7` | Merge commit '22a3f1f65b0363692e0793782d32504255ee06e0' as 'forks/LeaderKey' |
| 12:02:52 | `1be9917` | Squashed 'forks/Rectangle/' content from commit 7d6b4c5 |
| 12:02:52 | `03f0cfc` | Merge commit '1be99176150e236490243154e3d1f8e6c2f8acf4' as 'forks/Rectangle' |
| 14:43:50 | `cadaf01` | [P1.2] forks: LeaderKey + Rectangle vendored, MIT recorded, both building |
| 14:52:16 | `65da427` | [P1.3] kit: model + lossless LK importer + round-trip gate green |
| 14:55:30 | `95ec547` | [P1.4] app: the witness stands — tree renders the imported config |
| 15:27:06 | `96bfdc7` | [P1.5] app: the altar stands — node-graph canvas over the same model |
| 15:40:27 | `31279a5` | [P1.6] app: tab-switch carries the selection across worlds |
| 15:44:24 | `6bd47f4` | [P1.7] summon: the sigil as app icon + F19 indicator (route A) |
| 15:47:15 | `2586e9f` | [P1.8] summon: the wordmark builds letter by letter |
| 15:52:42 | `55152b5` | [P1.9a] sheol-core extracted; TUI rewired; parity proven on a throwaway socket |
| 16:12:44 | `79b67e9` | [P1.9b] sheol lives in the graph |
| 16:24:26 | `86fbebb` | [P1.10] altar v2: radial 360, side-by-side views, walk by key |
| 16:41:21 | `0a3af17` | [P1.11] spirits leave the config graph (owner ruling) + drive polish |
| 16:55:12 | `1ef7848` | [P1.12] altar: circuit-board traces, path glow, cursor-anchored scroll, the sheol door |
| 17:20:38 | `130bc60` | [P1.13] the board lives: growth, sway, taper, typewriter, cascade |
| 18:12:14 | `60e4cbf` | [P1.14] identity colors, icons, legible labels, the leader-key parent |
| 18:35:44 | `948cd3c` | [P1.15] self-explaining labels, still-at-rest board, leaf shells |
| 19:12:46 | `331d41f` | [P1.16] directional flow, readable spread, gates, spelled words, MB4 exhibit |
| 19:35:11 | `e8f85f7` | [P1.17] interlocked stagger, drag-and-drop, favicons, the embedded ledger |
| 20:18:35 | `8df12b8` | [P1.18] nothing hides: full-info board, group drag, ledger fixed, honest stubs |
| 20:19:55 | `171056b` | docs: [P1.18] checkpoint entry + cache #34-36 (latch, learned auto-layout, fire-pings) |
| 20:47:33 | `fb9f909` | [P1.19] corrections: curves back, sway done right, sheol is a pane |
| 20:59:28 | `efee0ea` | [P1.20] wrap: straight followable traces, key chips above icons, session log |
| 21:17:45 | `b9d9e52` | [P1.21] the keystroke order rides whole: [c-s-s] chips, above icon faces |
| 21:23:00 | `317fa9a` | [P1.22] keystroke chips read the true path (l-s-n-m); Codex review prompt |
| 21:31:27 | `f14eac5` | [P1.23] the 7:09 board returns: circular with minor curves, everything new kept |
| 22:01:37 | `5286a4f` | docs: session close addendum; Phase 1 sealed |
| 22:30:55 | `3cb60e6` | [P2.1b] adopt Codex app lifecycle fixes |
| 22:34:03 | `f75ad61` | [P2.1c] losslessness boundary made true, then documented |
| 22:35:58 | `a26a02e` | [P2.1d] sheol change-signature joints ride the unit separator |
| 22:36:29 | `bfb592d` | docs: [P2.1] checkpoint — Codex hardening adopted, Phase-2 boundary doctrine recorded |
| 22:43:00 | `429e82a` | [P2.2] sort made non-destructive: named layouts, radial ⇄ hand |
| 22:43:13 | `6c10a30` | docs: [P2.2] checkpoint entry |
| 22:49:43 | `6343e37` | [P2.4] the fork hot-reloads its config (implementation; live demo pending) |
| 22:58:59 | `da861dc` | [P2.4x] incident: fork tests ate the live config; sandboxed + restored |
| 22:59:16 | `fa89f70` | [P2.6a] write-back: the machinery, proven against temp targets |
| 22:59:39 | `5dc4433` | docs: [P2.4]/[P2.4x]/[P2.6a] checkpoint entries; owner-window actions staged |
| 23:05:43 | `4052027` | [P2.5a] the fired ping, app side: scheme + wave, preview staged |
| 23:06:38 | `ac4cf0f` | docs: [P2.5a] checkpoint + THE OWNER WINDOW supervised runbook |

### 2026-07-09

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 21:32:08 | `221d597` | config: recover the two drifted binds from Leader Key's memory |
| 21:55:45 | `2a9798b` | [P2.5b] the pulse was firing in a ghost window; now it lands |
| 22:03:06 | `025684e` | browser-jump: one ladder for every browser (s a → Safari, c h r → Chrome) |
| 22:03:06 | `d95d9da` | [P2.2b] the true reset: wipe the hand layout, behind a confirm |
| 22:03:06 | `b25b4ee` | docs: the altar board joins the README |
| 22:32:39 | `917df0e` | [P2.5c] make the pulse unmissable + fix the reset deadlock |
| 22:37:56 | `f05679d` | [P2.5d] the fork fires the board ping on every executed bind (#36) |
| 22:39:04 | `cd00622` | docs: [P2.3] swap rollback documented before the live change |

### 2026-07-10

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 23:38:19 | `1ccb488` | browser-jump: fix — activate OUTSIDE the System Events tell |
| 23:38:44 | `bc9e59a` | [P2.5e] the loop closes: a real keystroke pulses the board (witnessed) |

### 2026-07-12

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 17:32:35 | `dd62735` | app-jump: generalize browser-jump to any app; f i cycles Finder |
| 17:39:16 | `4424374` | [P2.6] the fork gets its own identity: com.machinespirit.leader-key |
| 17:52:09 | `20cb940` | [P2.6] fork display name → "MachineSpirit Leader Key" |
| 18:06:24 | `08f6c34` | cache: #37 per-keystroke pulse (owner) — incremental light on nav, retract on backspace |
| 18:10:18 | `15b2083` | docs: Phase-2 session log — the wiring, through v0.4-sovereign-driver |
| 18:34:58 | `945b6bc` | [P2.6b] the pen: +/− write the live config through the gate |
| 18:35:07 | `bf577a8` | docs: [P2.6] + [P2.6b] checkpoints; session log — the pen awaits its witness |

### 2026-07-15

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 07:28:04 | `4c87ee1` | fix: [tt/sheol] bootstrap Homebrew PATH in custom-command iTerm windows |
| 19:53:29 | `52d8c32` | chore: [fork/leaderkey] ignore local Release build output |
| 19:53:29 | `895545c` | fix: [fork/leaderkey] summon crash (phantom NSScreen) + URL-launch nil guards |
| 19:53:29 | `55bb304` | feat: [fork/leaderkey] skull menu-bar icon (idle stare / summoned pupils) |
| 20:09:07 | `f99a29b` | feat: [fork/leaderkey] unified skull menu — Leader Key + Rectangle + Karabiner |
| 20:48:21 | `0d3c762` | fix: [fork/leaderkey] rename menu Quit to "Quit MachineSpirit" |
| 21:06:32 | `7a8671d` | chore: [fork/leaderkey] capture fork daily-driver + hidden-icon setup in repo |
| 21:27:34 | `beb61e9` | fix: [fork/leaderkey] route app->fork pings via a unique msleaderkey:// scheme (#37) |
| 21:30:48 | `63a5a17` | fix: [fork/leaderkey] disable Sparkle auto-update (its feed points at stock) |
| 21:34:47 | `177454a` | feat: [fork/leaderkey] summoned skull lights up machine-spirit green (#2) |
| 23:10:26 | `0f652f4` | fix: [fork/leaderkey] stable self-signed signing so TCC grants survive rebuilds |

### 2026-07-18

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 20:26:40 | `f646a26` | docs: [fork/leaderkey] handoff — build/sign/redeploy recipe + skull app-icon task (#38) |
| 23:14:38 | `135e8d0` | feat: [fork/leaderkey] skull AppIcon for Dock/⌘-Tab/Settings (#38) |

### 2026-07-20

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 21:11:47 | `1405606` | feat: [app] unify on the skull icon across launcher + node-graph app |
| 21:23:55 | `db5784b` | feat: [fork/leaderkey] tmux/sheol menu-bar item — two live counts (#15) |
| 21:33:15 | `3206d2e` | fix: [sheol] revive hands iTerm tmux's absolute path (window no longer vanishes) |
| 21:39:46 | `f46e5fc` | feat: [app] open the launcher from the app + live config auto-refresh |
| 22:04:01 | `ae7951c` | feat: [tmux] evocative session names (Halo-Monitor style) instead of ms-HHMMSS |
| 22:10:38 | `b749590` | feat: [fork/leaderkey] per-row detach + banish controls in the tmux menu |
| 22:49:36 | `881bcfc` | feat: [fork/leaderkey] triple-tap ◆◆◇ ward for banish + rows sized to fit names |

### 2026-07-21

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 02:00:25 | `4d9d2ba` | feat: [fork/leaderkey] terminal ledger — 3 counts + a Terminals menu section |
| 04:12:17 | `137e66e` | feat: [fork/leaderkey] terminals list = non-tmux only, hoverable tmux rows, all-apps scan |

### 2026-07-23

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 14:27:13 | `ab43ae0` | feat: [fork/leaderkey] menu-bar memory-pressure gauge (distinct from Stats RAM%) |

### 2026-07-25

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 16:44:24 | `a4b423c` | feat: [fork/leaderkey] t q q q q kills selected tmux pane; menu-bar banish keeps ledger open |
| 16:54:41 | `741a721` | fix: [fork/leaderkey] tmux-kill-pane no-op'd — Homebrew missing from launchd PATH |

### 2026-07-30

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 15:50:50 | `3a258e0` | feat: [leaderkey] ⇪ s i g opens Signal (app-jump: launch/focus/cycle) |
| 17:22:33 | `e9f0f78` | perf: [fork/terminals-core] one ps snapshot replaces ~20 forks/call |
| 17:22:44 | `0ede262` | perf: [fork/menu-bar] terminals poll 8s→45s; cache mem-pressure gauge image |
| 23:19:11 | `7c07b8e` | fix: [fork/terminals-core] single ps snapshot — close the snapshot-gap divergence |
| 23:19:11 | `5c24db8` | perf: [fork/sheol] one clock read per redraw; JSON-escape without a subshell |
| 23:19:11 | `24e529a` | fix: [fork/menu-bar] repaint open menu on fresh read; real gauge needle; no double-init |

### 2026-08-02

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 00:51:56 | `56cc135` | feat: [tmux/sheol] session survival — resurrect+continuum, save/restore/banish-all |
| 01:11:42 | `799d6df` | fix: [tmux/sheol] reliable launchd auto-save (continuum's status-right timer was broken) |
| 20:23:37 | `6f4a991` | feat: [fork/menu-bar] sheol save/restore + type-BANISH nuke; ✕ ward on terminal rows |
| 20:24:26 | `d261dce` | docs: [sheol] menu-bar type-BANISH panel + terminal ✕ ward |
| 21:30:38 | `8728da1` | feat: [fork/menu-bar] agent-aware glyphs, iTerm $\| marker, new-window items, snapshot→bottom |
| 21:31:14 | `f3acd3e` | docs: [sheol] menu-bar agent-awareness glyphs, $\| marker, new-window items |

### 2026-08-03

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 00:29:36 | `e011303` | feat: [fork/menu-bar] Claude spark mark, deep agent detection, aligned ✕, non-closing ＋New |
| 01:47:47 | `590b0fb` | feat: [fork/terminals] label the iTerm hotkey window + reveal it on click |

### 2026-08-07

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 20:16:13 | `fc8cdc6` | feat: [leaderkey] ⇪ v l c opens VLC (app-jump: launch/focus/cycle) |
| 20:20:49 | `84b3dba` | feat: [fork/menu-bar] drawn marks for Codex + Grok (stylized indicators) |

### 2026-08-08

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 16:42:21 | `233fe1a` | feat: [leaderkey] ⇪ s l e e p sleeps the display (pmset displaysleepnow) |

### 2026-09-25

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 18:00:22 | `55e0e81` | fix: [app/graph] render clock actually pauses when idle (was pinned ~100% CPU) |

### 2026-11-19

| Local time | Revision | Recorded change |
| --- | --- | --- |
| 07:51:44 | `0db9318` | feat: [app] optional board + transparent typing overlay; drop directory pane |
| 07:51:45 | `fce48b4` | feat: [fork/menu-bar] system menu — keep-awake + display brightness; broadcast typing state |
| 08:58:21 | `77577bb` | feat: [fork] synced brightness w/ software dimming, invisible panel under overlay, clipboard history |
| 09:23:39 | `6af954c` | perf: [app/overlay] Core Animation renderer — native refresh, whole tree w/ icons, above menu bar |
| 09:26:03 | `f11431d` | perf: [fork/menu-bar] one compact status item w/ Stats folded in; rename; no cheatsheet under overlay |
| 09:39:16 | `0483acd` | feat: [app/overlay] real node labels (shared w/ board) + radial legibility backdrop |
| 09:39:16 | `c023afe` | feat: [fork/menu-bar] compact merged menu — one-line stats, inline brightness, no scrolling |
| 09:54:07 | `617e429` | feat: [ms] CLI + stdio MCP server so agents can navigate the Mac precisely |
| 09:54:07 | `571aa17` | chore: [install] board installs to ~/Applications; build dirs *.noindex (Spotlight skips them) |
| 10:07:13 | `d542f09` | docs: [readme] portfolio overhaul — hero overlay, architecture diagram, engineering notes, audited visuals |
| 12:53:21 | `8a90a32` | feat: [tmux] hold-x spawn/spiral splits, full session names when wide, idle-terminal reaper, ccwatch watches CC scratch dirs |
| 12:53:33 | `61427ec` | feat: [ms] win place smart/step ladder, tile-all, hide-all, cycle, mouse (+MCP tools) |
| 12:53:33 | `c637187` | Merge branch 'wt/win' |
| 12:54:38 | `6e34735` | feat: [fork/menu-bar] Stats-style labeled cells + TEMP/NET, extreme-value colors, tweened numbers, sectioned terminals menu, unkillable hotkey row |
| 12:54:38 | `a9160f0` | Merge branch 'wt/menubar' |
| 13:03:36 | `0c0625a` | feat: [bin] hold scripts — Safari tab collect/cycle, Finder window→tab gather, hover-to-close app toggle (TextEdit asks), FaceTime-from-Messages, blur-field, Photoshop doc cycle |
| 13:03:36 | `c08a4fa` | Merge branch 'wt/scripts' |
| 13:05:21 | `552ad58` | feat: [app/overlay] skull root + cursor, letter pop, keypress shockwave, red miss / blue done / back retract, hold state, swaggy close, clickable nodes w/ hover route, menu-bar/Dock-safe layout, optional curves, 1x AA; transient board; opt-in local stats |
| 13:05:22 | `54bfe4b` | Merge branch 'wt/overlay' |
| 13:08:36 | `2966bd8` | feat: [fork] hold mode — keep ⇪ down after a bind to repeat its hold command, ␣ places/ladders any window; ⌫ steps back one level; ⇪ ⎋ blurs the text field; overlay feedback (miss/back/done/hold); fresh app launches placed by mouse |
| 13:08:36 | `e48ec91` | perf: [fork/menu-bar] only the machine-spirit counts tween; stats snap (bar idles ~1% CPU, was ~6%) |
| 13:08:36 | `6c75cc9` | fix: [app] restore AppDelegate init() — NSApplicationDelegateAdaptor crashed at launch |
| 13:08:36 | `be7c482` | fix: [install] ~/bin/ms is a symlink into the repo (a copied wrapper can't find tools/ms); sync skips it; app-jump places fresh launches by mouse |
| 13:08:36 | `d3555c2` | feat: [leaderkey] ⇪ ␣ ␣ placement ladder, g g g, hold-collect on every site, d r / s h o p / t r / t e {l,x,r} / t g / p b / f c 2 / u r, hover-close toggles, h i d e / s h o w, l k, m a c h i n e s p i r i t; README hold-mode + tables |
| 16:55:32 | `07e1bba` | fix: [bin/app-toggle] TextEdit actually quits — wait for async close; frontmost w/ no documents (Dock ghost / Open panel) quits |
| 17:16:52 | `6159530` | feat: [ms] capslock (IOKit + HUD), audio list/tile (CoreAudio process objects), translate-area (Vision OCR + on-device Translation), hourly pulse collect/report + LaunchAgent; Messages name-search helper |
| 17:17:42 | `ff209a5` | feat: [leaderkey] c a p s, e t translate, a u audio tile, m e → name search, c a l / c o n / m a i l / s e toggles, t 3, Codex → c o d; install hourly pulse agent |
| 17:27:24 | `3f8c0bf` | feat: [app/overlay] skull grow-in + ghost/glitch exit + no-flicker min show, speed-reactive shake/shockwave/glitch, Graphics settings (accent, curvature, randomness, shake, glitch), live ⇪ ␣ placement preview, glass caps pill + text HUD, DIN Condensed type, animated hover w/ spore drift |
| 17:27:24 | `1030c2d` | Merge branch 'wt/fx' |
| 17:32:06 | `044cf9a` | fix: [fork/hold] event tap owns the keyboard while ⇪ is held — no more 50 ms focus re-grab fighting the target app (visible glitching on ⇪ y y y) |
| 17:40:07 | `f4dddd4` | feat: [app/overlay] Caps Lock badge follows the pointer while caps is on (glass, ≤60 moves/s, zero work when off); Graphics toggle |
| 17:40:07 | `91f06ad` | Merge branch 'wt/fx' |
| 17:50:09 | `ebcbb15` | feat: [fork/menu-bar] NOW PLAYING section — apps producing audio with live level meters (CoreAudio process taps, only while the menu is open); tab-row extension point |
| 17:50:09 | `2fb0c47` | Merge branch 'wt/audio' |
| 18:36:22 | `5a71ef0` | Add focused-window pins and stage Lens and pin chords |
| 19:03:39 | `2251f84` | Aim window placement from Caps–Space and fade on confirmed arrival |
| 19:07:56 | `2e0e909` | Revert "Aim window placement from Caps–Space and fade on confirmed arrival" |
| 19:09:29 | `d867da5` | Record read-only Opus review of the reverted window motion pass |
| 19:14:31 | `64cbc74` | Keep hover highlights anchored to the classic node layout |
| 19:14:31 | `35161ad` | Move the focused window with a repeated directional arrow |
| 19:19:37 | `2ac5a6a` | Preview the destination before committing a window shortcut |
