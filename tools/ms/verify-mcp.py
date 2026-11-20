#!/usr/bin/env python3
"""Local stdio smoke test; Python stdlib only, no client registration or bind execution.

Run from any directory. --screenshot additionally captures and deletes one PNG.
--json-flag verifies `ms mcp --json` also preserves the wire protocol.
Never reads clipboard history, even if the invoking shell opted in.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import select
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--screenshot", action="store_true")
parser.add_argument("--json-flag", action="store_true")
options = parser.parse_args()
root = Path(__file__).resolve().parents[2]
env = os.environ.copy()
env.pop("MS_ALLOW_CLIPBOARD", None)
process = subprocess.Popen(
    [str(root / "bin/ms"), "mcp", *(["--json"] if options.json_flag else [])],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, env=env,
)


def send(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def call(identifier, method, params=None):
    message = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        message["params"] = params
    send(message)
    assert select.select([process.stdout], [], [], 20)[0], f"timeout: {method}"
    result = json.loads(process.stdout.readline())
    assert result["jsonrpc"] == "2.0" and result["id"] == identifier, result
    assert "error" not in result, result
    return result["result"]


try:
    result = call(1, "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "ms-smoke-test", "version": "1"},
    })
    assert result["protocolVersion"] == "2025-06-18"
    assert result["serverInfo"]["name"] == "machine-spirit"
    print("initialize ->", json.dumps(result, separators=(",", ":")))
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    result = call(2, "tools/list")
    names = [tool["name"] for tool in result["tools"]]
    assert set(names) == {"screens", "apps", "windows", "focus", "binds", "run", "tmux", "stats", "screenshot",
                          "mouse", "win_place", "win_tile_all", "win_cycle", "audio_list", "pulse_report"}
    for tool in result["tools"]:
        assert tool["inputSchema"]["type"] == "object"
        assert tool["inputSchema"]["additionalProperties"] is False
    print("tools/list ->", json.dumps(names))
    for identifier, name in [(3, "screens"), (4, "windows")]:
        result = call(identifier, "tools/call", {"name": name, "arguments": {}})
        assert result["isError"] is False, result
        assert result["content"][0]["type"] == "text"
        payload = json.loads(result["content"][0]["text"])
        assert isinstance(payload[name], list)
        # Keep private window titles out of test logs.
        print(f"tools/call {name} -> isError=false, {len(payload[name])} records; JSON parsed")
    assert call(5, "ping") == {}
    print("ping -> {}")
    result = call(6, "tools/call", {"name": "clipboard", "arguments": {}})
    assert result["isError"] is True
    print("disabled clipboard -> isError=true")
    result = call(8, "tools/call", {"name": "mouse", "arguments": {}})
    assert result["isError"] is False, result
    payload = json.loads(result["content"][0]["text"])
    assert {"x", "y", "screen", "frame", "visibleFrame"} <= payload.keys()
    print("tools/call mouse -> isError=false; JSON parsed")
    # Exercise mutation routing without moving any real window.
    for identifier, name, arguments in [
        (9, "win_place", {"mode": "center", "app": "ms-smoke-nonexistent-00000000"}),
        (10, "win_cycle", {"app": "ms-smoke-nonexistent-00000000"}),
    ]:
        result = call(identifier, "tools/call", {"name": name, "arguments": arguments})
        assert result["isError"] is True, result
        error = json.loads(result["content"][0]["text"])["error"]
        assert "no running app" in error or "Accessibility not granted" in error, error
    print("window tools -> routed; nonexistent app rejected without mutation")
    for identifier, name in [(18, "audio_list"), (19, "pulse_report")]:
        if name == "pulse_report" and "MS_PULSE_DIR" not in os.environ:
            continue
        result = call(identifier, "tools/call", {"name": name, "arguments": {}})
        assert result["isError"] is False, result
        json.loads(result["content"][0]["text"])
        print(f"tools/call {name} -> isError=false; JSON parsed")
    if options.screenshot:
        result = call(7, "tools/call", {"name": "screenshot", "arguments": {}})
        assert result["isError"] is False, result
        payload = json.loads(result["content"][0]["text"])
        file = Path(payload["path"])
        try:
            assert file.stat().st_mode & 0o777 == 0o600
            image = result["content"][1]
            assert image["type"] == "image" and image["mimeType"] == "image/png"
            png = base64.b64decode(image["data"], validate=True)
            assert png[:8] == b"\x89PNG\r\n\x1a\n"
            width, height = struct.unpack(">II", png[16:24])
            assert 0 < max(width, height) <= 1568
            print(f"screenshot -> private PNG {payload['width']}x{payload['height']}; MCP PNG {width}x{height}")
        finally:
            file.unlink(missing_ok=True)
    process.stdin.close()
    process.wait(timeout=5)
    assert process.returncode == 0
    assert process.stdout.read() == "", "unexpected protocol output"
    stderr = process.stderr.read()
    assert not stderr, stderr
    print("PASS: parsed responses, no notification reply/stdout noise, clean EOF shutdown")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
