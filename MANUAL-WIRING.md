# machine-spirit — manual wiring checklist

The **click-through-the-UI steps that currently must be done by hand** to bring a
fresh machine up to a working machine-spirit. This is deliberately narrow: it
lists *only* the human-in-the-loop GUI actions — the highest-friction onboarding
surface — not the parts `install.sh` already scripts.

It is the concrete spec for what the eventual machine-spirit app must **automate**
(where safe) or **guide** (where a security consent gate makes silent automation
impossible or wrong). See [`HANDOFF-NOTES.md`](HANDOFF-NOTES.md) #12 — *the manual
wiring being done at dev-time is the spec for what the app will later do itself.*

> **Scope boundary.** `install.sh` already restores the Leader Key + Karabiner
> configs, lays down `~/bin`, compiles `shield-fx`, and applies the optional
> `macos-defaults.sh`. Those are *not* here. This file is what's left over that a
> human still has to click. A broader, forward-looking automation inventory (the
> `AUTOMATION-MANIFEST`) is a separate, not-yet-written doc; this checklist is its
> highest-priority subset.

## Legend

**Today** — current state in this repo:
✅ installer/app already handles · ⚠️ partly handled (config restored, wiring manual) · ✋ fully manual

**Strategy** — how the app will eventually take it over:
- `plist-while-quit` — write `com.googlecode.iterm2.plist` **while iTerm is quit** (`defaults write` / PlistBuddy). iTerm **rewrites its plist on quit**, so a live poke is discarded — this is the load-bearing reason most iTerm setup can't be scripted naively.
- `iterm-api` — set it at runtime through iTerm's Python API (works while iTerm runs; needs the API already enabled — see step 1).
- `detect-and-guide` — a **security consent gate**. Detect the current state programmatically, then walk the user to the exact pane. **Never auto-flip a consent** (no app can or should).
- `defaults-write` — a plain, scriptable `defaults write` to a normal (non-iTerm) domain.
- `own-when-forked` — becomes automatable only once the tool is hard-forked into machine-spirit (Leader Key / Rectangle per handoff #8).

---

## Summary — what's manual right now

| # | Step | Today | Strategy |
|---|---|---|---|
| 1 | iTerm: enable Python API | 🗑 RETIRED | shield removed — no longer needed |
| 2 | iTerm: restart after enabling API | 🗑 RETIRED | shield removed |
| 3 | iTerm: ⌘W → shield keybinding | 🗑 RETIRED | shield removed; use built-in close-confirm |
| 4 | iTerm: profiles, APS, semantic history, dimming, hotkey window, colors, greeting | ✋ | plist-while-quit / iterm-api |
| 5 | Leader Key: F19 activation + Launch at Login | ⚠️ | own-when-forked / detect-and-guide |
| 6 | Leader Key: reload after a config edit | ✅ | `reload-leaderkey.sh` |
| 7 | Karabiner: Input Monitoring + driver ext; caps→f19 | ⚠️ | detect-and-guide (config restored) |
| 8 | Accessibility permissions | ✋ | detect-and-guide |
| 9 | Screen Recording permission | ✋ | detect-and-guide |
| 10 | Rectangle: Accessibility + launch | ⚠️ | detect-and-guide |
| 11 | Stats: menu-bar allow; disable Sensors/Bluetooth | ✋ | plist + detect-and-guide |
| 12 | iPhone Mirroring → Ask Every Time | ✋ | user-choice / guide |
| 13 | Lock Screen password-after-display-off delay | ✋ | user-choice / guide |
| 14 | Per-monitor display color matching | ✋ | guide (hardware OSD) |

---

## iTerm2

### 1–3. 🗑 RETIRED — busy-pane shield (Python API + ⌘W keybinding)

**These three steps are gone.** They existed only to wire the busy-pane shield
(iTerm Python API → AutoLaunch daemon → ⌘W keybinding). The shield was removed —
its *safety* is now iTerm's own built-in setting (step 7 below / see HANDOFF), and
nothing else in the repo needs the Python API. If you set them up before, see the
handoff's **"undo the shield"** checklist to unwire them cleanly. This deletes the
largest consent-gated + plist-resident chunk of the onboarding surface.

### 4. Profiles, APS, semantic history, dimming, hotkey window, colors, greeting
The bulk of iTerm setup. All of it lives in the plist (not captured by sync — see CLAUDE.md), so it's **manual in the Settings UI today**.
- **Profiles:** create **Hacker / Regular / Baking / CC / Hotkey Window** (Settings → Profiles → `+`), each with its color/behavior.
- **Automatic Profile Switching (APS):** per-profile → Advanced → *Automatic Profile Switching* rules — e.g. **`&claude*`** and **`&caffeinate*`** (job-name globs) to swap profile when those foreground jobs run.
- **Semantic History:** per profile → Profiles → Advanced → *Semantic History* = **“Open with default app.”**
- **Dimming:** Settings → Appearance → *Dimming* (dim inactive split panes / windows) to taste.
- **Hotkey window:** a dedicated **Hotkey Window** profile, positioned **Left of Screen**, bound to the summon hotkey (Profiles → Keys → *Hotkey Window* / “Configure Hotkey Window”). See README → Terminal splash → Wiring; the window only re-reads Rows/Columns when fully recreated.
- **Color scheme:** Settings → Profiles → Colors → **Color Presets → Import** → `config/iterm2/*.itermcolors`, then select it per profile.
- **Greeting / env var:** the hotkey pane's greeting runs from the shell (`shell/splash/`); hotkey-only behavior gates on **`ITERM_PROFILE == "Hotkey Window"`** (set by iTerm at launch). ⚠️ *“Send text at start” runs too late to export env vars* (per CLAUDE.md) — use the profile-name gate, not send-text, for anything env-dependent.
- **Why not scriptable (today):** the iTerm profile plist is intentionally **not** captured by sync (`config/iterm2/` holds only the color scheme + tooling); everything else is hand-set in Settings.
- **Strategy:** `plist-while-quit` for static profile/APS/dimming/semantic-history keys; `iterm-api` for anything settable at runtime. Long-term: machine-spirit generates the profile plist from repo-managed profile definitions and writes it with iTerm quit.

---

## Leader Key

### 5. Set F19 activation + Launch at Login
- **Click-path:** Leader Key → Settings (`⇪ l k`, or ⌘, once focused) → **activation shortcut field → press Caps Lock** (Karabiner has already remapped it to **F19**, so the field records F19). Enable **Launch at Login**.
- **Set:** activation = F19; Launch at Login = on.
- **Why not scriptable:** the shortcut must be *captured from a keypress* in Leader Key's own field; Launch-at-Login is a Leader Key preference (and a `SMAppService` login item, itself approval-adjacent).
- **Strategy:** `own-when-forked` — once Leader Key is hard-forked into machine-spirit (#8), machine-spirit owns activation + login-item registration directly. Until then, `detect-and-guide`.

### 6. Reload Leader Key after a config edit — ✅ already automated
- **How:** run [`bin/reload-leaderkey.sh`](bin/reload-leaderkey.sh) (Leader Key does **not** hot-reload; an edited bind stays stale until restart).
- **Why it was a trap:** silent staleness — you change a bind, nothing happens, no error.
- **Strategy:** done. Any tool/automation that edits the config must call this after; the node-graph app makes it implicit (see [`CLAUDE.md`](CLAUDE.md) → *Editing a keybind / config*).

---

## Karabiner

### 7. Grant Input Monitoring + approve the driver; caps_lock → f19
- **Click-path:** launch **Karabiner-Elements** → approve **Input Monitoring** and the **driver / system extension** when prompted (**may require a reboot**). Then Simple Modifications → **`caps_lock` → `f19`** (this is already in the restored `karabiner.json`, but the driver must be live for it to take effect).
- **Set:** Input Monitoring = allowed; driver ext = approved; caps→f19 modification present.
- **Why not scriptable:** the karabiner **config** is restored by `install.sh`, but the **driver/system-extension approval** and **Input Monitoring** grant are TCC/`systemextensionsctl` consent gates that only the user can approve, sometimes across a reboot.
- **Strategy:** `detect-and-guide` (managed dependency per handoff #4 — never rebuild Karabiner). Detect the extension's activation state; guide the approval; prompt for the reboot if needed.

---

## System permissions — all consent-gated (`detect-and-guide`)

macOS TCC permissions cannot be granted by a script without disabling SIP; the
app's job is to **detect** the state (functional probe or TCC read) and **deep-link**
the user to the exact pane (`x-apple.systempreferences:…`), never to auto-grant.

### 8. Accessibility
- **Click-path:** System Settings → **Privacy & Security → Accessibility** → enable: **Leader Key, iTerm, Karabiner, MachineSpirit.app, Rectangle**.
- **Why:** these drive keystrokes / window control (⌘L, ⌘\` cycling, window moves, the shield).
- **Strategy:** `detect-and-guide`; probe each app's AX trust (`AXIsProcessTrusted`-style) and guide the toggles.

### 9. Screen Recording
- **Click-path:** System Settings → **Privacy & Security → Screen Recording** → enable the screenshot toolchain's host (iTerm / the capturing binary).
- **Why:** the `⇪ s s …` screenshot/record scripts capture the screen.
- **Strategy:** `detect-and-guide`.

### 10. Rectangle — Accessibility + launch
- **Click-path:** launch **Rectangle**, approve its **Accessibility** prompt on first run; enable **Launch on login**.
- **Why:** window management is driven through Rectangle's URL scheme; it needs AX to move windows.
- **Strategy:** `detect-and-guide` now; `own-when-forked` later (Rectangle is a hard-fork target, #8).

### 11. Stats (menu-bar system monitor)
- **Click-path:** on **macOS 26**, allow **Stats** under **Menu Bar** (the new menu-bar-item consent), and in Stats' own settings **disable the Sensors and Bluetooth modules**.
- **Why:** the menu-bar-item allow is a macOS 26 consent gate; the module toggles are Stats prefs (avoid noisy/irrelevant readouts).
- **Strategy:** module toggles are `defaults-write` to Stats' domain; the menu-bar allow is `detect-and-guide`.

---

## Optional / user-choice

Personal-preference or hardware steps — the app should **offer**, never impose.

### 12. iPhone Mirroring → “Ask Every Time”
- **Click-path:** System Settings → **Desktop & Dock → iPhone Mirroring** (or the app's own setting) → **Ask Every Time**.
- **Why it matters:** selecting *Ask Every Time* is what unlocks the Lock-Screen password-delay option in step 13.
- **Strategy:** user-choice / guide.

### 13. Lock Screen — require password after display off (delay)
- **Click-path:** System Settings → **Lock Screen** → *Require password after screen saver begins or display is turned off* → pick the **delay**.
- **Why not scriptable:** security-sensitive; gated (and coupled to step 12).
- **Strategy:** user-choice / guide.

### 14. Per-monitor display color matching
- **Click-path:** each monitor's **hardware OSD** *and* System Settings → **Displays** → set to a matched target: **6500K**, **HDR off**, **True Tone off**, **sRGB profile** (ColorSync).
- **Why not scriptable:** the monitor **OSD is hardware** — outside macOS entirely; the macOS-side ColorSync/HDR/True-Tone toggles are partly `defaults`/profile-selectable but the match only works paired with the OSD.
- **Strategy:** guide (document the target values); the OSD half can never be automated.

---

## Cross-reference — already handled vs still manual

- **Already scripted (`install.sh`):** Homebrew + `brew bundle`, `~/bin` scripts, Leader Key config restore (with `__HOME__` re-expansion), Karabiner config restore, `shield-fx` compile, optional `macos-defaults.sh`.
- **Already scripted (this repo):** Leader Key reload (`reload-leaderkey.sh`, step 6); the shield's own kill switch (`shield-on/off.sh`).
- **Still manual:** everything in the summary table with ✋ or ⚠️ — every consent gate (steps 1, 7–11) and every iTerm plist-resident setting (steps 3–4), which are the two hardest classes and the app's top automation targets.
- **Doc drift fixed alongside this:** `install.sh`'s printed manual checklist carried the wrong shield invocation (`\(id)`); corrected to `pane_shield(session_id: id)` to match step 3.
