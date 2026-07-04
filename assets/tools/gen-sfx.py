#!/usr/bin/env python3
"""gen-sfx.py — render the busy-pane-shield sound effects, offline and original.

Build-time only. Produces two short, royalty-free WAVs (we synthesize them from
scratch, so there is zero third-party / game audio — nothing from Halo or an
else), committed next to this tool:

    assets/shield-hit.wav     bright energy "zap" as the shield absorbs   (hits 1 & 2)
    assets/shield-break.wav   overload burst + sub-boom shatter           (hit 3 -> close)

Pure Python stdlib (wave/struct/math/random with a fixed seed) so the render is
deterministic and needs no dependencies. Regenerate with:

    python3 assets/tools/gen-sfx.py
"""
import math
import os
import random
import struct
import wave

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def _write(name, samples):
    path = os.path.join(OUT_DIR, name)
    peak = max(1e-9, max(abs(s) for s in samples))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for s in samples:
            v = int(max(-1.0, min(1.0, s / peak * 0.92)) * 32767)
            frames += struct.pack("<h", v)
        w.writeframes(bytes(frames))
    print(f"  wrote {name}  ({len(samples)/RATE:.2f}s, {len(samples)*2} bytes)")


def shield_hit(dur=0.24):
    """A bright energy zap: fast up-chirp + ring-modulated metallic shimmer,
    snappy attack, quick exponential decay. Reads as 'shield absorbed a hit'."""
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        p = i / n
        # quick pitch snap upward then settle (the 'vwip')
        f = 520 + 460 * math.exp(-14 * t)
        carrier = math.sin(2 * math.pi * f * t)
        # ring modulation -> metallic/energised timbre
        ring = math.sin(2 * math.pi * f * 1.5 * t)
        shimmer = 0.25 * math.sin(2 * math.pi * (f * 2.01) * t)
        s = carrier * (0.6 + 0.4 * ring) + shimmer
        atk = min(1.0, t / 0.003)             # 3ms attack
        env = atk * math.exp(-9 * t)          # fast decay
        out.append(s * env)
    return out


def shield_break(dur=0.62):
    """Overload shatter: a bright crack transient, a downward sweep under a
    decaying noise burst, and a short sub-bass boom for weight."""
    rng = random.Random(0x5E1D)               # fixed seed -> reproducible
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        p = i / n
        # descending energy sweep
        f = 900 * (110 / 900) ** p
        tone = math.sin(2 * math.pi * f * t)
        # gritty shatter noise, front-loaded
        noise = rng.uniform(-1, 1) * (1 - p) ** 1.4
        # sub-bass boom for body (60 -> 42 Hz)
        sub = 0.7 * math.sin(2 * math.pi * (60 - 18 * p) * t) * math.exp(-4 * t)
        # sharp opening crack
        crack = 1.6 * math.exp(-90 * t) * rng.uniform(-1, 1)
        env = math.exp(-3.0 * t)
        out.append((0.5 * tone + 0.75 * noise) * env + sub + crack)
    return out


if __name__ == "__main__":
    print("rendering shield SFX ->", os.path.normpath(OUT_DIR))
    _write("shield-hit.wav", shield_hit())
    _write("shield-break.wav", shield_break())
    print("done.")
