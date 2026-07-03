# iTerm2

## Color scheme
Drop your exported `.itermcolors` file in this folder (e.g. `hacker.itermcolors`)
and commit it. To apply on a new machine:

`iTerm2 → Settings → Profiles → Colors → Color Presets ▾ → Import` → pick the file,
then select it from the same menu.

## Keybinds (defaults — no config needed)
- `⌘D` — split vertically
- `⌘⇧D` — split horizontally
- `⌘⌥ + arrows` — navigate between panes (use THESE; `⌘[`/`⌘]` are unreliable here)
- `⌘⇧⏎` — toggle full-screen focus on the active pane
- `⌘W` — close the focused pane (kills its process — never on a live run)
- `⌘Z` — undo an accidental pane/session close (~5s window)

## Two-profile color setup (green ambient, plain for long-runs)
Colors live on the *profile/session*, not the window — a running session can
change colors with zero process restart.

Profiles:
- **Hacker** — green preset, set as DEFAULT (new panes are green).
- **Regular** — normal/dark colors.
- (optional) **CC** and **Baking** — plain colors + distinct tab colors/badges.

Manual color toggle — bind in `Settings → Keys → Key Bindings`. Use **Change
Profile** (NOT Load Color Preset — that depends on a preset being saved with the
right name and silently no-ops otherwise). AVOID `⌘⌥+number` combos — they
collide with iTerm's built-in select-pane/tab bindings.
- `⌃⌥1` → Change Profile → Regular   (snap current pane back to normal)
- `⌃⌥2` → Change Profile → Hacker

## Automatic Profile Switching (auto-plain for Claude Code / long bakes)
`Settings → Profiles → <plain profile> → Advanced → Automatic Profile Switching`.
APS matches the pane's foreground JOB name (prefix with `&`). Long CC runs are
usually wrapped in `caffeinate` to keep the Mac awake, so `caffeinate` — not
`claude` — is the foreground job. Match BOTH:

    &claude*
    &caffeinate*

Never add `&node*` — it would strip styling from the dialer panes too.

Different look per run type: point each rule at its own plain profile.
- `&claude*`     → profile "CC"      (tab color cyan,  badge "CLAUDE")
- `&caffeinate*` → profile "Baking"  (tab color amber, badge "☕ BAKING")
Limit: APS can't tell apart two things that both report `caffeinate`.

## Badges
Big faint label painted behind a pane's text. `Profiles → General → Badge`.
Supports emoji. Use to mark scratch/long-run panes unmistakably (e.g. `SCRATCH`,
`☕ BAKING`).

## Tab color
`Profiles → Colors → Use tab color`. Applied via a profile, so APS makes CC/bake
panes auto-wear their color while running and drop it when the job exits.

## Dimming (two independent toggles)
`Settings → Appearance → Dimming`:
- **Dim inactive split panes** — fades non-focused panes within one window.
- **Dim background windows** — fades whole windows that aren't focused.
- **Dimming affects only text, not background** — keep backgrounds full, fade
  only text (subtle, not washed out). Lower the amount slider to taste.
If some panes dim and others don't, the two toggles are set asymmetrically.

## Dedicated hotkey window (Guake-style dropdown)
`Settings → Keys → Hotkey → Create a Dedicated Hotkey Window`; trigger = double-tap
Control (or right-Option — calmer, never collides with Ctrl+C/R/A).
- Requires iTerm RUNNING in the background to listen globally → set launch-at-login
  and don't quit it. A reboot may be needed once so macOS Accessibility fully
  registers the global listener.
- Bind it to its OWN dedicated profile (loud badge like `SCRATCH`) so the dropdown
  never opens one of your working layouts.
- Keep this profile OUT of APS rules.
- Pin it to stay open when focus leaves; enable show-on-all-Spaces / float-on-top
  to drop over full-screen apps.

## Persistent sessions (survive iTerm quitting/crashing)
Start long runs inside tmux control mode so the process outlives the UI:

    tmux -CC new -A -s main     # attach if exists, else create; renders as native iTerm windows
    tmux -CC attach -t main     # reattach after a quit/crash

Can't retro-adopt an already-running process — make this the FIRST thing typed
for the next long run.

## Optional: full-prefs-in-repo
For total reproducibility have iTerm read all settings from this folder:
`Settings → General → Settings → "Load preferences from a custom folder or URL"`,
point it here, enable "Save changes automatically." iTerm writes
`com.googlecode.iterm2.plist` here — review before committing (may contain window
titles / paths).
