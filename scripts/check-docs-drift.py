#!/usr/bin/env python3
"""Evaluate whether repository text and screenshots match the current code and push.

Usage:
  scripts/check-docs-drift.py                       # check working repo integrity + keybind parity
  scripts/check-docs-drift.py --range BASE..HEAD    # also evaluate UI/feature drift in git range
  scripts/check-docs-drift.py --range BASE..HEAD --gate
      Fail if a mapped UI/feature surface changed without updating its docs/visuals
      (unless a commit in the range carries 'Visuals-Reviewed: current' / 'Docs-Reviewed: current').
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = REPO_ROOT / "config/leader-key/config.json"
README_PATH = REPO_ROOT / "README.md"
REFERENCE_PATH = REPO_ROOT / "docs/REFERENCE.md"
VISUAL_AUDIT_PATH = REPO_ROOT / "docs/VISUAL-AUDIT.md"
IMG_DIR = REPO_ROOT / "docs/img"

# Map changed source paths (prefixes or regexes) to the docs and visuals that represent them.
SURFACE_RULES = [
    {
        "name": "Menu bar compact cells & drive labels",
        "patterns": [
            r"^forks/LeaderKey/Leader Key/CompactBar\.swift$",
            r"^forks/LeaderKey/Leader Key/SystemStats\.swift$",
        ],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": ["docs/img/menubar.png"],
    },
    {
        "name": "Compact system menu & Now Playing",
        "patterns": [
            r"^forks/LeaderKey/Leader Key/NowPlayingMenu\.swift$",
            r"^forks/LeaderKey/Leader Key/StatusItem\.swift$",
            r"^forks/LeaderKey/Leader Key/BrightnessController\.swift$",
        ],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": ["docs/img/menu.png"],
    },
    {
        "name": "Native clipboard panel",
        "patterns": [
            r"^forks/LeaderKey/Leader Key/Clipboard.*\.swift$",
        ],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": ["docs/img/clipboard.png"],
    },
    {
        "name": "Typing overlay & Core Animation node graph",
        "patterns": [
            r"^app/MachineSpirit/Sources/TypingOverlay\.swift$",
            r"^app/MachineSpirit/Sources/OverlayScene\.swift$",
            r"^app/MachineSpirit/Sources/OverlayFX\.swift$",
            r"^app/MachineSpirit/Sources/OverlaySurfaces\.swift$",
        ],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": ["docs/img/overlay-walk.gif", "docs/img/hero.png", "docs/img/overlay-corner.png"],
    },
    {
        "name": "MachineSpirit board & Apps pane",
        "patterns": [
            r"^app/MachineSpirit/Sources/GraphView\.swift$",
            r"^app/MachineSpirit/Sources/ContentView\.swift$",
            r"^app/MachineSpirit/Sources/AppsPane\.swift$",
            r"^app/MachineSpirit/Sources/PenForm\.swift$",
            r"^app/MachineSpirit/Sources/GraphicsSettings\.swift$",
        ],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": ["docs/img/board.png"],
    },
    {
        "name": "Captured Leader Key bindings",
        "patterns": [r"^config/leader-key/config\.json$"],
        "docs": ["docs/REFERENCE.md"],
        "visuals": [],
    },
    {
        "name": "ms CLI & MCP server",
        "patterns": [r"^tools/ms/Sources/.*\.swift$"],
        "docs": ["README.md", "docs/REFERENCE.md", "tools/ms/README.md"],
        "visuals": [],
    },
    {
        "name": "Hotkey terminal splash",
        "patterns": [r"^shell/splash/"],
        "docs": ["README.md", "docs/REFERENCE.md"],
        "visuals": [],
    },
]

PNG_FORBIDDEN_CHUNKS = {b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"tIME"}
MAX_IMAGE_BYTES = 4 * 1024 * 1024


def normalize_token(key: str) -> str:
    if key in (" ", "space", "␣"):
        return "space"
    return key.lower()


def extract_config_binds() -> list[tuple[str, str]]:
    data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    binds: list[tuple[str, str]] = []

    def walk(node: dict, prefix: list[str]) -> None:
        for action in node.get("actions", []):
            key = action.get("key", "")
            path = prefix + [normalize_token(key)]
            if action.get("type") == "group":
                walk(action, path)
            else:
                label = action.get("label") or action.get("value") or ""
                binds.append((" ".join(path), label))

    walk(data, [])
    return binds


def extract_documented_binds(markdown_text: str) -> set[str]:
    found: set[str] = set()
    # Match inline code spans starting with ⇪ (Caps Lock leader sigil), e.g. `⇪ s s s c` or `⇪ ␣ M`
    for match in re.finditer(r"`⇪\s+([^`]+)`", markdown_text):
        raw = match.group(1).strip()
        # Strip trailing ellipsis or parenthetical notes
        if "…" in raw or "(" in raw:
            continue
        tokens = [normalize_token(tok) for tok in raw.split()]
        if tokens:
            found.add(" ".join(tokens))
    return found


def check_keybind_parity() -> list[str]:
    errors: list[str] = []
    if not CONFIG_PATH.is_file():
        return [f"Missing config: {CONFIG_PATH}"]
    doc_text = ""
    if REFERENCE_PATH.is_file():
        doc_text += REFERENCE_PATH.read_text(encoding="utf-8") + "\n"
    if README_PATH.is_file():
        doc_text += README_PATH.read_text(encoding="utf-8") + "\n"
    documented = extract_documented_binds(doc_text)
    configured = extract_config_binds()
    missing = [seq for seq, _ in configured if seq not in documented]
    if missing:
        errors.append(
            "Undocumented keybinds in config/leader-key/config.json (missing from docs/REFERENCE.md / README.md): "
            + ", ".join(f"`⇪ {m}`" for m in missing)
        )
    return errors


def check_markdown_links(md_path: Path) -> list[str]:
    errors: list[str] = []
    if not md_path.is_file():
        return [f"Missing expected documentation file: {md_path.relative_to(REPO_ROOT)}"]
    text = md_path.read_text(encoding="utf-8")
    # Strip fenced code blocks before scanning links
    stripped = re.sub(r"```.*?```", "", text, flags=re.S)
    for match in re.finditer(r"!?\[[^\]]*\]\(([^)]+)\)", stripped):
        raw_target = match.group(1).strip()
        if raw_target.startswith("<") and raw_target.endswith(">"):
            raw_target = raw_target[1:-1]
        # Remove optional markdown title
        target = raw_target.split(' "', 1)[0].strip()
        if not target or target.startswith(("http://", "https://", "mailto:", "#", "msleaderkey://", "machinespirit://")):
            continue
        path_part = target.split("#", 1)[0]
        if not path_part:
            continue
        resolved = (md_path.parent / path_part).resolve()
        if not resolved.exists():
            errors.append(f"Broken link in {md_path.relative_to(REPO_ROOT)}: {target}")
    return errors


def inspect_png_chunks(path: Path) -> list[str]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return [f"{path.relative_to(REPO_ROOT)} is not a valid PNG"]
    bad: list[str] = []
    pos = 8
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
        if ctype in PNG_FORBIDDEN_CHUNKS:
            bad.append(ctype.decode("ascii", errors="replace"))
        pos += 12 + length
    if bad:
        return [
            f"{path.relative_to(REPO_ROOT)} contains stripped-required metadata chunks: {', '.join(sorted(set(bad)))}"
        ]
    return []


def check_visual_assets() -> list[str]:
    errors: list[str] = []
    if not IMG_DIR.is_dir():
        return ["Missing docs/img directory"]
    audit_text = VISUAL_AUDIT_PATH.read_text(encoding="utf-8") if VISUAL_AUDIT_PATH.is_file() else ""
    for asset in sorted(IMG_DIR.iterdir()):
        if asset.name.startswith(".") or not asset.is_file():
            continue
        size = asset.stat().st_size
        if size > MAX_IMAGE_BYTES:
            errors.append(
                f"{asset.relative_to(REPO_ROOT)} is {size / (1024 * 1024):.2f} MiB (limit {MAX_IMAGE_BYTES // (1024 * 1024)} MiB)"
            )
        if asset.name not in audit_text:
            errors.append(
                f"{asset.relative_to(REPO_ROOT)} is not recorded in docs/VISUAL-AUDIT.md"
            )
        if asset.suffix.lower() == ".png":
            errors.extend(inspect_png_chunks(asset))
    return errors


def git_changed_files(git_range: str | None) -> tuple[list[str], str]:
    if git_range:
        files = subprocess.check_output(
            ["git", "diff", "--name-only", git_range], cwd=REPO_ROOT, text=True
        ).splitlines()
        log_text = subprocess.check_output(
            ["git", "log", "--format=%B", git_range], cwd=REPO_ROOT, text=True
        )
        return [f.strip() for f in files if f.strip()], log_text
    files = subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=REPO_ROOT, text=True
    ).splitlines()
    parsed = [line[3:].strip().strip('"') for line in files if len(line) > 3]
    return parsed, ""


def evaluate_surface_drift(changed_files: list[str], commit_log: str) -> tuple[list[str], list[str]]:
    changed_set = set(changed_files)
    docs_attested = bool(re.search(r"^Docs-Reviewed:\s*current\b", commit_log, re.M | re.I))
    visuals_attested = bool(re.search(r"^Visuals-Reviewed:\s*current\b", commit_log, re.M | re.I))

    doc_warnings: list[str] = []
    visual_warnings: list[str] = []

    for rule in SURFACE_RULES:
        matched = [
            f for f in changed_files if any(re.search(pat, f) for pat in rule["patterns"])
        ]
        if not matched:
            continue
        docs_touched = any(d in changed_set for d in rule["docs"])
        visuals_touched = any(v in changed_set for v in rule["visuals"])
        if rule["docs"] and not docs_touched and not docs_attested:
            doc_warnings.append(
                f"[{rule['name']}] changed ({', '.join(matched)}) without updating "
                f"{' or '.join(rule['docs'])} (or adding trailer 'Docs-Reviewed: current')."
            )
        if rule["visuals"] and not visuals_touched and not visuals_attested:
            visual_warnings.append(
                f"[{rule['name']}] changed ({', '.join(matched)}) without refreshing "
                f"{', '.join(rule['visuals'])} (or adding trailer 'Visuals-Reviewed: current')."
            )
    return doc_warnings, visual_warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate repo docs and visuals freshness.")
    parser.add_argument("--range", dest="git_range", help="Git revision range, e.g. BASE..HEAD")
    parser.add_argument(
        "--gate",
        action="store_true",
        help="Exit non-zero if changed UI surfaces lack updated docs/visuals or explicit review trailers.",
    )
    args = parser.parse_args()

    hard_errors: list[str] = []
    hard_errors.extend(check_keybind_parity())
    hard_errors.extend(check_markdown_links(README_PATH))
    hard_errors.extend(check_markdown_links(REFERENCE_PATH))
    hard_errors.extend(check_visual_assets())

    changed_files, commit_log = git_changed_files(args.git_range)
    doc_warnings, visual_warnings = evaluate_surface_drift(changed_files, commit_log)

    if hard_errors:
        print("Docs/Visuals integrity errors:", file=sys.stderr)
        for err in hard_errors:
            print(f"  - {err}", file=sys.stderr)

    if doc_warnings or visual_warnings:
        stream = sys.stderr if args.gate else sys.stdout
        label = "Docs/Visuals drift gate blocked push:" if args.gate else "Docs/Visuals freshness advisory:"
        print(label, file=stream)
        for w in doc_warnings + visual_warnings:
            print(f"  - {w}", file=stream)

    if hard_errors:
        return 1
    if args.gate and (doc_warnings or visual_warnings):
        return 1

    print("Docs & visuals check passed (keybinds, links, metadata, visual audit, and surface freshness).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
