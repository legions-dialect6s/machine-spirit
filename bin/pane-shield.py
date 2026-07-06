#!/usr/bin/env python3
"""pane-shield.py — an escalating, Halo-Reach-style barrier to closing a BUSY iTerm2 pane.

Runs as an iTerm2 Python-API AutoLaunch daemon. It registers the RPC
`pane_shield`; you bind ⌘W to it (see README). On each ⌘W it reads the session's
foreground job and decides:

  * pane NOT busy (job is just the shell)   -> close immediately.
  * SHIELD DISABLED (kill-switch flag)       -> close immediately.
  * pane busy (claude / node / python / …)   -> raise the shield and escalate:
      hit 1  soft energy "vwip" + cyan  bg pulse  + badge  ◆ SHIELD ▓▓░ ◆
      hit 2  louder vwip        + amber bg pulse  + badge  ◆ SHIELD ▓░░ ◆
      hit 3  glassy BURST       + white bg flash  + badge  ⚡ SHIELD DOWN ⚡
             (the shield breaks — but the pane does NOT close yet)
      hit 4  DEATH: an ASCII skull + crossbones is drawn INTO the pane, the
             whole pane fades to black (a reversed summon), THEN it closes.
  * stop pressing for REGEN_SECS and the shield REGENERATES to full — a soft
    rising shimmer, badge clears (classic Reach shield recharge).

All visuals for hits 1–3 are non-destructive (badge + background-color pulse),
so a live session's on-screen output is never corrupted. Text is injected into
the pane ONLY on the death frame, when the pane is closing anyway.

WHY NO CGEventTap (kill-switch safety): all interception lives in ONE iTerm key
binding routed to this RPC. There is no system-wide event tap, so this can NEVER
eat keystrokes outside iTerm. Worst case if the daemon dies: ⌘W does nothing in
iTerm until you restart it or remove the binding — contained, never global.

KILL SWITCH (instant, no restart): create the flag file and ⌘W is 100% normal:
      ~/bin/shield-off.sh     # touch ~/.config/machine-spirit/shield-disabled
      ~/bin/shield-on.sh      # remove it
Full teardown: delete the AutoLaunch symlink + remove the ⌘W key binding.

── PARAMETER SURFACE (handoff #13) ───────────────────────────────────────────
Everything tunable lives in CONFIG below: hit thresholds, per-hit SFX + volumes
+ colors + pulse counts, the busy-process list, regen timing, and the death
sequence. These constants are the seed of the eventual node's parameter surface,
so keep behavior expressed HERE as data, not scattered as magic numbers.
"""
import asyncio
import os
import time

import iterm2

# ---------------------------------------------------------------- parameters
CONFIG = {
    # what counts as "not busy" (idle) — closing these closes instantly.
    "idle_jobs": {
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "login",
        "fish", "-fish", "tmux", "screen", "",
    },
    "burst_hit": 3,        # the hit that BREAKS the shield (no close yet)
    "death_hit": 4,        # the hit that kills the pane
    "regen_secs": 5.0,     # idle this long -> shield recharges to full
    # Per-hit look + sound. Each visual is a smooth EASED background wash: blend
    # the pane toward `bg` by `depth`, easing up over `up` steps then down over
    # `down` (smoothstep) — a breath, not a strobe. Tuned so the three hits RAMP:
    #   1 gentle hold  ->  2 deeper/lingering strain  ->  3 snappy bright break.
    "hits": {
        1: {"sfx": "shield-dmg1.wav", "vol": 0.50, "bg": (90, 175, 195),
            "depth": 0.30, "up": 3, "down": 4, "step_ms": 30, "hold_ms": 45,
            "bar": "▓▓░", "badge": "◆ SHIELD {bar} ◆\n{job} is running"},
        2: {"sfx": "shield-dmg2.wav", "vol": 0.60, "bg": (205, 135, 40),
            "depth": 0.52, "up": 3, "down": 5, "step_ms": 30, "hold_ms": 65,
            "bar": "▓░░", "badge": "◆ SHIELD {bar} ◆\n{job} is running"},
        3: {"sfx": "shield-burst.wav", "vol": 0.70, "bg": (236, 238, 246),
            "depth": 0.85, "up": 1, "down": 6, "step_ms": 26, "hold_ms": 30,
            "bar": "░░░", "badge": "⚡ SHIELD DOWN ⚡\none more ⌘W ends it"},
    },
    "regen_sfx": ("shield-recharge.wav", 0.35),
    "regen_pulse": {"bg": (70, 165, 160), "depth": 0.26, "up": 5, "down": 6,
                    "step_ms": 34, "hold_ms": 40},
    "death_sfx": ("pane-death.wav", 0.55),
    "death_settle_secs": 0.28,   # skull fades UP from dim to lit
    "death_hold_secs": 0.42,     # holds, lit, so the kill registers
    "death_fade_secs": 0.72,     # then eases skull + pane to black together
    "death_fade_steps": 12,
    "death_black_secs": 0.16,    # a black beat before the pane closes
}

DISABLE_FLAG = os.path.expanduser("~/.config/machine-spirit/shield-disabled")

# session_id -> (count, last_monotonic)
_state = {}


# ---------------------------------------------------------------- kill switch
def _disabled():
    return os.path.exists(DISABLE_FLAG)


# ---------------------------------------------------------------- assets / sfx
def _assets_dir():
    here = os.path.dirname(os.path.realpath(__file__))
    for c in (
        os.environ.get("PANE_SHIELD_ASSETS"),
        os.path.expanduser("~/projects/machine-spirit/assets"),
        os.path.join(here, "assets"),
        os.path.join(here, "..", "assets"),
    ):
        if c and os.path.isdir(c):
            return c
    return None


_ASSETS = _assets_dir()


async def _play(name, volume=1.0):
    # SOUND IS INTENTIONALLY SILENT BY DEFAULT. The synth SFX were dropped as
    # placeholder cruft (they read corny); the shield ships as a purely visual
    # safety feature for now. Sound is a pure DROP-IN: the filenames in
    # CONFIG (shield-dmg1/dmg2/burst/recharge, pane-death .wav) are the contract
    # — drop real audio at assets/<name> and it plays again with no code change.
    # Real "cybergoth" audio is deferred to real samples / node params later.
    if not _ASSETS or not name:
        return
    path = os.path.join(_ASSETS, name)
    if not os.path.exists(path):        # no file -> silent, by design
        return
    try:
        await asyncio.create_subprocess_exec(
            "/usr/bin/afplay", "-v", str(volume), path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception:
        pass


# ------------------------------------------------------------- per-pane visuals
def _color(rgb):
    return iterm2.Color(rgb[0], rgb[1], rgb[2])


async def _set_bg(session, color):
    p = iterm2.LocalWriteOnlyProfile()
    p.set_background_color(color)
    await session.async_set_profile_properties(p)


async def _set_badge(session, text):
    p = iterm2.LocalWriteOnlyProfile()
    p.set_badge_text(text)
    await session.async_set_profile_properties(p)


async def _orig_bg(session):
    try:
        prof = await session.async_get_profile()
        return prof.background_color
    except Exception:
        return iterm2.Color(0, 0, 0)


def _smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)                    # smoothstep easing


def _lerp_rgb(a, b, t):
    return (int(a[0] + (b[0] - a[0]) * t),
            int(a[1] + (b[1] - a[1]) * t),
            int(a[2] + (b[2] - a[2]) * t))


async def _pulse(session, rgb, depth, up, down, step_ms, hold_ms):
    """A smooth, eased background WASH: blend the pane toward `rgb` by `depth`,
    easing up (smoothstep) then holding then easing back down. Non-destructive —
    always restores the original bg. Reads as a breath, not a strobe."""
    orig = await _orig_bg(session)
    o = (orig.red, orig.green, orig.blue)
    target = _lerp_rgb(o, rgb, depth)
    try:
        for k in range(1, up + 1):
            await _set_bg(session, _color(_lerp_rgb(o, target, _smooth(k / up))))
            await asyncio.sleep(step_ms / 1000)
        await asyncio.sleep(hold_ms / 1000)
        for k in range(1, down + 1):
            await _set_bg(session, _color(_lerp_rgb(o, target, _smooth(1 - k / down))))
            await asyncio.sleep(step_ms / 1000)
        await _set_bg(session, orig)
    except Exception:
        try:
            await _set_bg(session, orig)
        except Exception:
            pass


async def _do_hit(session, session_id, cnt, job):
    """Absorb one ⌘W: badge + sound + eased wash, then arm the regen timer."""
    h = CONFIG["hits"][cnt]
    await _set_badge(session, h["badge"].format(bar=h["bar"], job=job))
    await _play(h["sfx"], h["vol"])
    await _pulse(session, h["bg"], h["depth"], h["up"], h["down"],
                 h["step_ms"], h["hold_ms"])
    asyncio.create_task(_regen_after(session, session_id))


async def _inject(session, text):
    try:
        await session.async_inject(text.encode("utf-8"))
    except Exception:
        pass


# --------------------------------------------------------------- death sequence
# Skull + crossbones. Kept compact so it fits a modest pane; falls back to a
# single line if the pane is too small.
_SKULL = r"""      .-~~~~~~~-.
     /  _     _  \
    :  (o)   (o)  :
    |     ^^^     |
    :   \_____/   :
     \___________/
    __/         \__
   /  \  '.^.'  /  \
  (    \   |   /    )
   \    '. | .'    /
    '.____\|/____.'
         'X-X'"""
_SKULL_CAPTION = "S E S S I O N   T E R M I N A T E D"


def _draw_frame(rows, cols, top, left, art_lines, cap_row, cap_col, cap, fg):
    """Build a single inject string that (re)paints the art + caption at `fg`."""
    fgseq = f"\x1b[38;2;{fg[0]};{fg[1]};{fg[2]}m"
    out = ["\x1b[?25l"]                       # hide cursor
    for i, ln in enumerate(art_lines):
        out.append(f"\x1b[{top + i};{left}H{fgseq}{ln}")
    out.append(f"\x1b[{cap_row};{cap_col}H{fgseq}{cap}")
    out.append("\x1b[0m")
    return "".join(out)


async def _death(session):
    try:
        rows = int(await session.async_get_variable("rows") or 24)
        cols = int(await session.async_get_variable("columns") or 80)
    except Exception:
        rows, cols = 24, 80
    orig = await _orig_bg(session)
    orig_rgb = (orig.red, orig.green, orig.blue)
    black = (0, 0, 0)
    bone = (232, 234, 240)
    dim = (58, 76, 88)                       # skull starts dim, then powers up

    art = _SKULL.split("\n")
    art_w = max(len(l) for l in art)
    art_h = len(art)

    # clear the screen so the dying pane reads clean under the skull
    await _inject(session, "\x1b[2J\x1b[H\x1b[?25l")

    if rows >= art_h + 2 and cols >= art_w + 2:
        top = max(1, (rows - art_h) // 2)
        left = max(1, (cols - art_w) // 2 + 1)
        cap_row = min(rows, top + art_h + 1)
        cap_col = max(1, (cols - len(_SKULL_CAPTION)) // 2 + 1)
        art_lines, cap = art, _SKULL_CAPTION
    else:
        # too small: a single centered glyph line
        line = "☠  SESSION TERMINATED  ☠"
        top = max(1, rows // 2)
        left = max(1, (cols - len(line)) // 2 + 1)
        cap_row, cap_col, cap = top, left, ""
        art_lines = [line]

    def paint(fg):
        return _draw_frame(rows, cols, top, left, art_lines, cap_row, cap_col, cap, fg)

    # 1) settle — the skull fades UP from dim to lit as the power-down tone hits
    await _play(*CONFIG["death_sfx"])
    ss = 5
    sdt = CONFIG["death_settle_secs"] / ss
    for k in range(ss + 1):
        await _inject(session, paint(_lerp_rgb(dim, bone, _smooth(k / ss))))
        await asyncio.sleep(sdt)
    # 2) hold, lit, so the kill registers
    await asyncio.sleep(CONFIG["death_hold_secs"])
    # 3) dissolve — skull fg AND pane bg ease to black together (smoothstep)
    fs = CONFIG["death_fade_steps"]
    fdt = CONFIG["death_fade_secs"] / fs
    for k in range(fs + 1):
        t = _smooth(k / fs)
        await _inject(session, paint(_lerp_rgb(bone, black, t)))
        await _set_bg(session, _color(_lerp_rgb(orig_rgb, black, t)))
        await asyncio.sleep(fdt)

    await asyncio.sleep(CONFIG["death_black_secs"])
    await session.async_close()


# ------------------------------------------------------------------ regen timer
async def _regen_after(session, session_id):
    await asyncio.sleep(CONFIG["regen_secs"])
    cnt_ts = _state.get(session_id)
    if not cnt_ts or (time.monotonic() - cnt_ts[1]) < CONFIG["regen_secs"]:
        return                                  # a newer hit landed; not idle
    _state.pop(session_id, None)
    await _play(*CONFIG["regen_sfx"])
    rp = CONFIG["regen_pulse"]                            # gentle recharge swell
    await _pulse(session, rp["bg"], rp["depth"], rp["up"], rp["down"],
                 rp["step_ms"], rp["hold_ms"])
    try:
        await _set_badge(session, "")
    except Exception:
        pass


# ------------------------------------------------------------------- the RPC
async def _handle(connection, session_id):
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(session_id)
    if session is None:
        return

    # kill switch: shield off -> behave as stock ⌘W.
    if _disabled():
        await session.async_close()
        return

    job = (await session.async_get_variable("jobName") or "").strip()
    if job in CONFIG["idle_jobs"]:              # idle shell -> close instantly
        _state.pop(session_id, None)
        await session.async_close()
        return

    now = time.monotonic()
    cnt, last = _state.get(session_id, (0, 0.0))
    if now - last > CONFIG["regen_secs"]:
        cnt = 0                                  # shield had regenerated
    cnt += 1
    _state[session_id] = (cnt, now)

    if cnt >= CONFIG["death_hit"]:
        _state.pop(session_id, None)
        await _set_badge(session, "☠")
        await _death(session)
        return

    # hits 1 & 2 (absorb, strain) and 3 (burst) — all eased washes, ramped
    # by their per-hit CONFIG params.
    await _do_hit(session, session_id, cnt, job)


async def main(connection):
    @iterm2.RPC
    async def pane_shield(session_id):
        await _handle(connection, session_id)

    await pane_shield.async_register(connection)
    await asyncio.Future()   # keep the daemon (and registration) alive


if __name__ == "__main__":
    iterm2.run_forever(main)
