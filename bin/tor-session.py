#!/usr/bin/python3
"""Launch the disposable, single-app ARM64 Tor Browser Linux VM.

Networking and killswitch live entirely INSIDE the isolated Linux VM:
- tor-only mode: nftables blocks IPv6, incoming traffic, clearnet DNS (port 53),
  and outbound traffic from users other than the browser account.
- wireguard mode: streams the user's WireGuard .conf (e.g. Proton VPN Free)
  into guest RAM over a private virtio serial pipe, locks nftables to ONLY the
  WireGuard endpoint on eth0, verifies handshake, and routes Tor over wg0.

Networking is configured inside the Linux guest.
"""
import base64
import tempfile
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
SETUP_PREF = SUPPORT_DIR / "tor-setup-version"
SESSION_STATUS = SUPPORT_DIR / "tor-session.json"
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
            name = line[1:-1].strip().lower()
            if name not in ("interface", "peer") or (name == "interface" and iface) or (name == "peer" and peer):
                raise ValueError("Import one WireGuard interface with one peer.")
            section = name
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
    for key in (iface["privatekey"], peer["publickey"], peer.get("presharedkey")):
        if key is not None and len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("WireGuard keys must be 32 bytes.")
    ep = peer["endpoint"]
    if ":" not in ep or ep.startswith("["):
        raise ValueError("Invalid WireGuard .conf: expected IPv4 host:port Endpoint.")
    host, port = ep.rsplit(":", 1)
    ipaddress.IPv4Address(host)
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("Invalid WireGuard endpoint port.")
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
        if val not in ("tor-only", "wireguard"):
            raise ValueError("Saved Tor network mode is invalid. Select a mode in Apps.")
        return val
    except FileNotFoundError:
        pass
    return "wireguard"


def save_mode(mode: str):
    if mode not in ("tor-only", "wireguard"):
        raise ValueError("Mode must be 'tor-only' or 'wireguard'.")
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".tor-mode-", dir=SUPPORT_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(mode + "\n")
        os.replace(name, MODE_PREF)
        SETUP_PREF.write_text("1\n")
    finally:
        Path(name).unlink(missing_ok=True)


def is_session_executable(command):
    return command.strip() in {
        str(DESK.parent / ".build/tor-room"),
        str(DESK.parent / ".build/TorRoom.app/Contents/MacOS/tor-room"),
    }


def running_session():
    try:
        state = json.loads(SESSION_STATUS.read_text())
        pid = int(state["pid"])
        if pid <= 0:
            return None
        command = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True,
        )
        if is_session_executable(command.stdout):
            return state
    except (OSError, ValueError, KeyError, TypeError):
        pass
    # Older running builds may predate the status file. Treat their mode as unknown.
    matches = subprocess.run(["/usr/bin/pgrep", "-x", "tor-room"], capture_output=True, text=True)
    for pid in matches.stdout.split():
        command = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        if is_session_executable(command.stdout):
            return {"pid": int(pid), "mode": "unknown", "phase": "unknown"}
    return None


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
    return {
        "mode": mode,
        "hasWireguard": has_wg,
        "endpoint": endpoint,
        "applianceReady": APPLIANCE_MANIFEST.is_file(),
        "setupRequired": not SETUP_PREF.is_file() and not has_wg,
        "session": running_session(),
    }


def import_wireguard(src_path: str):
    with Path(src_path).open("r", encoding="utf-8") as source:
        text = source.read(65537)
    if len(text) > 65536:
        raise ValueError("WireGuard configuration exceeds 64 KiB.")
    endpoint = parse_wireguard_endpoint(text)
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".wireguard-", dir=SUPPORT_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(name, WG_CONF)
    finally:
        Path(name).unlink(missing_ok=True)
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
    for pid in matches.stdout.split():
        command = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        if not is_session_executable(command.stdout):
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


def open_setup():
    subprocess.run(["/usr/bin/open", "machinespirit://apps"], check=True)


def confirm_tor_only():
    result = subprocess.run([
        "/usr/bin/osascript", "-e", """
activate
set choice to button returned of (display dialog "Tor Browser supports use without a VPN. Your internet provider may see that you use Tor. Adding a VPN changes who you trust and requires its own configuration." with title "Open Tor without a VPN?" buttons {"Configure VPN", "Cancel", "Open without VPN"} default button "Configure VPN" cancel button "Cancel" with icon caution)
return choice
""",
    ], capture_output=True, text=True)
    if result.returncode != 0:
        # Cancel and dialog failures both leave the session unopened.
        return False
    if result.stdout.strip() == "Configure VPN":
        open_setup()
        return False
    return result.stdout.strip() == "Open without VPN"


def launch():
    if not os.access(DESK, os.X_OK):
        raise ValueError("Install Machine Spirit Lab in ~/projects/machine-spirit-lab first.")
    st = status_dict()
    if st["setupRequired"]:
        open_setup()
        return
    active = st["session"]
    if active:
        if active.get("mode") != "wireguard" and not confirm_tor_only():
            return
        if focus_existing():
            return
    if st["mode"] == "tor-only" and not confirm_tor_only():
        return
    cmd = [str(DESK), "tor"]
    if st["mode"] == "wireguard":
        if WG_CONF.is_file() and WG_CONF.stat().st_mode & 0o077:
            raise ValueError("The saved WireGuard key must have owner-only file permissions.")
        if not st["hasWireguard"]:
            open_setup()
            feedback("Import a VPN configuration to continue.")
            return
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
