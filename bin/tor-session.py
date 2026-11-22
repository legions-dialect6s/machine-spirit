#!/usr/bin/python3
"""Launch the disposable, single-app ARM64 Tor Browser Linux VM.

Networking and killswitch live entirely INSIDE the isolated Linux VM:
- tor-only mode: nftables blocks IPv6, incoming traffic, clearnet DNS (port 53),
  and non-Tor processes; Tor Browser connects directly over Tor.
- wireguard mode: streams the user's WireGuard .conf (e.g. Proton VPN Free)
  into guest RAM over a private virtio serial pipe, locks nftables to ONLY the
  WireGuard endpoint on eth0, verifies handshake, and routes Tor over wg0.

The Mac host's network settings are NEVER modified.
"""
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode

SUPPORT_DIR = Path.home() / "Library/Application Support/MachineSpirit"
MODE_PREF = SUPPORT_DIR / "tor-mode"
WG_CONF = SUPPORT_DIR / "tor-wireguard.conf"
DESK = Path.home() / "projects/machine-spirit-lab/desk"
APPLIANCE_MANIFEST = Path.home() / "projects/machine-spirit-lab/.local/tor-appliance/manifest.json"


def parse_wireguard_endpoint(text: str) -> str:
    section = None
    iface = {}
    peer = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if "=" not in line:
            continue
        k, v = [p.strip() for p in line.split("=", 1)]
        if section == "interface":
            iface[k.lower()] = v
        elif section == "peer":
            peer[k.lower()] = v
    if "privatekey" not in iface or "address" not in iface:
        raise ValueError("Invalid WireGuard .conf: missing [Interface] PrivateKey or Address.")
    if "publickey" not in peer or "endpoint" not in peer:
        raise ValueError("Invalid WireGuard .conf: missing [Peer] PublicKey or Endpoint.")
    ep = peer["endpoint"]
    if ":" not in ep or ep.startswith("["):
        raise ValueError("Invalid WireGuard .conf: expected IPv4 host:port Endpoint.")
    # Verify at least one IPv4 interface address exists
    has_v4 = False
    for entry in iface["address"].split(","):
        try:
            ipaddress.IPv4Interface(entry.strip())
            has_v4 = True
            break
        except ValueError:
            pass
    if not has_v4:
        raise ValueError("Invalid WireGuard .conf: no IPv4 Address in [Interface].")
    return ep


def current_mode() -> str:
    try:
        val = MODE_PREF.read_text().strip()
        if val in ("tor-only", "wireguard"):
            return val
    except FileNotFoundError:
        pass
    return "wireguard" if WG_CONF.is_file() else "tor-only"


def save_mode(mode: str):
    if mode not in ("tor-only", "wireguard"):
        raise ValueError("Mode must be 'tor-only' or 'wireguard'.")
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    MODE_PREF.write_text(mode + "\n")


def status_dict() -> dict:
    endpoint = None
    has_wg = False
    if WG_CONF.is_file():
        try:
            endpoint = parse_wireguard_endpoint(WG_CONF.read_text())
            has_wg = True
        except (OSError, ValueError):
            has_wg = False
    mode = current_mode()
    if mode == "wireguard" and not has_wg:
        mode = "tor-only"
    return {
        "mode": mode,
        "hasWireguard": has_wg,
        "endpoint": endpoint,
        "applianceReady": APPLIANCE_MANIFEST.is_file(),
    }


def import_wireguard(src_path: str):
    text = Path(src_path).read_text(encoding="utf-8")
    endpoint = parse_wireguard_endpoint(text)
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = WG_CONF.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, WG_CONF)
    save_mode("wireguard")
    print(json.dumps({"ok": True, "endpoint": endpoint}))


def remove_wireguard():
    try:
        WG_CONF.unlink()
    except FileNotFoundError:
        pass
    save_mode("tor-only")
    print(json.dumps({"ok": True}))


def feedback(message: str):
    query = urlencode({"style": "text", "title": "Tor Browser", "text": message})
    subprocess.run(["/usr/bin/open", "-g", "machinespirit://hud?" + query])


def focus_existing() -> bool:
    matches = subprocess.run(["/usr/bin/pgrep", "-x", "tor-room"], capture_output=True, text=True)
    expected = str(DESK.parent / ".build/tor-room")
    for pid in matches.stdout.split():
        command = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        if command.stdout.strip() != expected:
            continue
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                """
on run argv
    set vmPID to (item 1 of argv) as integer
    tell application "System Events"
        set vm to first application process whose unix id is vmPID
        tell vm
            set w to first window
            if value of attribute "AXMinimized" of w then set value of attribute "AXMinimized" of w to false
            set frontmost to true
            perform action "AXRaise" of w
        end tell
    end tell
end run""",
                pid,
            ],
            check=True,
            timeout=6,
        )
        return True
    return False


def launch():
    if not os.access(DESK, os.X_OK):
        raise ValueError("Install Machine Spirit Lab in ~/projects/machine-spirit-lab first.")
    if focus_existing():
        return
    st = status_dict()
    cmd = [str(DESK), "tor"]
    if st["mode"] == "wireguard":
        if not st["hasWireguard"]:
            raise ValueError("WireGuard mode is selected, but no .conf is imported. Import one in Machine Spirit → Apps.")
        feedback("Starting isolated Tor Browser + WireGuard killswitch…")
        cmd.extend(["--wireguard", str(WG_CONF)])
    else:
        if not st["applianceReady"]:
            feedback("Building isolated Tor Browser appliance (one-time)…")
        else:
            feedback("Starting isolated Tor Browser…")
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    try:
        args = sys.argv[1:]
        if args == ["--status"]:
            print(json.dumps(status_dict()))
        elif len(args) == 2 and args[0] == "--import-wg":
            import_wireguard(args[1])
        elif args == ["--remove-wg"]:
            remove_wireguard()
        elif len(args) == 2 and args[0] == "--set-mode":
            save_mode(args[1])
            print(json.dumps(status_dict()))
        elif args == ["--session"]:
            launch()
        elif not args:
            # Leader Key serializes commands. Detach cleanly so its queue never blocks.
            subprocess.Popen(
                [sys.executable, __file__, "--session"],
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            sys.exit(2)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        if sys.argv[1:] not in (["--status"], ["--remove-wg"]) and not (
            len(sys.argv) == 3 and sys.argv[1] in ("--import-wg", "--set-mode")
        ):
            feedback(str(exc))
            subprocess.run(
                [
                    "/usr/bin/osascript",
                    "-e",
                    'on run argv\nactivate\ndisplay alert "Tor Browser" message (item 1 of argv)\nend run',
                    str(exc),
                ]
            )
        sys.exit(str(exc))
