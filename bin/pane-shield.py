#!/usr/bin/env python3
"""pane-shield.py — an escalating, Halo-style barrier to closing a BUSY iTerm2 pane.

Runs as an iTerm2 Python-API AutoLaunch daemon. It registers the RPC
`pane_shield`; you bind ⌘W to it (see README). On each ⌘W it reads the session's
foreground job and decides:

  * pane NOT busy (job is just the shell)          -> close immediately.
  * SHIELD DISABLED (kill-switch flag present)      -> close immediately.
  * pane busy (claude / node / python / ngrok / …)  -> raise the shield:
      hit 1  shield-hit SFX + cyan flare + dim flash + badge "SHIELD 1/3"
      hit 2  louder hit + amber "overload" flare + brighter flash + "2/3"
      hit 3  shield-break SFX + full-screen SHATTER, THEN the pane closes.
  * stop pressing for RESET_SECS and the shield disarms (badge clears).

WHY NO CGEventTap (kill-switch safety): all interception lives in ONE iTerm key
binding routed to this RPC. There is no system-wide event tap, so this can NEVER
eat keystrokes outside iTerm. Worst case if the daemon dies: ⌘W does nothing in
iTerm until you restart it or remove the binding — contained, never global.

KILL SWITCH (instant, no restart): create the flag file and ⌘W is 100% normal:
      ~/bin/shield-off.sh     # touch ~/.config/machine-spirit/shield-disabled
      ~/bin/shield-on.sh      # remove it
Full teardown: delete the AutoLaunch symlink + remove the ⌘W key binding.
"""
import asyncio
import os
import time

import iterm2

SHELLS = {
    "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "login",
    "fish", "-fish", "tmux", "screen", "",
}
RESET_SECS = 6.0
FLASH_MS = 90
DISABLE_FLAG = os.path.expanduser("~/.config/machine-spirit/shield-disabled")

_state = {}   # session_id -> (count, last_monotonic)


# ---------------------------------------------------------------- kill switch
def _disabled():
    return os.path.exists(DISABLE_FLAG)


# ---------------------------------------------------------------- assets / fx
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
_FX = os.path.expanduser("~/bin/shield-fx")   # compiled Swift overlay (optional)


async def _play(name, volume=1.0):
    if not _ASSETS:
        return
    path = os.path.join(_ASSETS, name)
    if not os.path.exists(path):
        return
    try:
        await asyncio.create_subprocess_exec(
            "/usr/bin/afplay", "-v", str(volume), path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception:
        pass


async def _overlay(level):
    """Fire the fullscreen flare/shatter overlay, fire-and-forget. Optional."""
    if not os.path.exists(_FX):
        return
    try:
        await asyncio.create_subprocess_exec(
            _FX, str(level),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception:
        pass


# ------------------------------------------------------------- per-pane visuals
async def _set_bg(session, color):
    p = iterm2.LocalWriteOnlyProfile()
    p.set_background_color(color)
    await session.async_set_profile_properties(p)


async def _set_badge(session, text):
    p = iterm2.LocalWriteOnlyProfile()
    p.set_badge_text(text)
    await session.async_set_profile_properties(p)


async def _flash(session, color, pulses):
    try:
        prof = await session.async_get_profile()
        orig = prof.background_color
    except Exception:
        return
    try:
        for _ in range(pulses):
            await _set_bg(session, color)
            await asyncio.sleep(FLASH_MS / 1000)
            await _set_bg(session, orig)
            await asyncio.sleep(FLASH_MS / 1000 * 0.6)
    except Exception:
        try:
            await _set_bg(session, orig)
        except Exception:
            pass


async def _disarm_after(session, session_id):
    await asyncio.sleep(RESET_SECS)
    cnt_ts = _state.get(session_id)
    if cnt_ts and (time.monotonic() - cnt_ts[1]) >= RESET_SECS:
        _state.pop(session_id, None)
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

    # Kill switch: shield off -> behave as stock ⌘W (close, no friction).
    if _disabled():
        await session.async_close()
        return

    job = (await session.async_get_variable("jobName") or "").strip()
    if job in SHELLS:                       # idle shell -> close instantly
        _state.pop(session_id, None)
        await session.async_close()
        return

    now = time.monotonic()
    cnt, last = _state.get(session_id, (0, 0.0))
    if now - last > RESET_SECS:
        cnt = 0
    cnt += 1
    _state[session_id] = (cnt, now)

    if cnt >= 3:
        await _set_badge(session, "⛒ SHIELD BREAK ⛒")
        await _play("shield-break.wav", 1.0)
        await _overlay(3)                   # fullscreen shatter
        await _flash(session, iterm2.Color(235, 60, 25), pulses=3)
        _state.pop(session_id, None)
        await session.async_close()
        return

    # hits 1 & 2 — flare, warn, hold the line
    color = iterm2.Color(110, 25, 25) if cnt == 1 else iterm2.Color(210, 45, 20)
    await _set_badge(session, f"◆ SHIELD {cnt}/3 ◆\n{job} is running")
    await _play("shield-hit.wav", 1.0 if cnt == 1 else 2.0)
    await _overlay(cnt)                      # escalating flare (level 1 / 2)
    await _flash(session, color, pulses=cnt)
    asyncio.create_task(_disarm_after(session, session_id))


async def main(connection):
    @iterm2.RPC
    async def pane_shield(session_id):
        await _handle(connection, session_id)

    await pane_shield.async_register(connection)
    await asyncio.Future()   # keep the daemon (and registration) alive


if __name__ == "__main__":
    iterm2.run_forever(main)
