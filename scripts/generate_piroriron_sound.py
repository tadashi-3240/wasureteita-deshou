#!/usr/bin/env python3
"""Generate the bundled notification chime (ピロリローン系).

Requires: python3, ffmpeg

Usage (from WasureteitaDeshou/):
  python3 scripts/generate_piroriron_sound.py
"""

from __future__ import annotations

import math
import os
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "WasureteitaDeshou" / "Resources" / "Sounds" / "piroriron.caf"


def synthesize(rate: int = 44100) -> list[float]:
    duration_notes = [0.12, 0.12, 0.12, 0.28]
    freqs = [784.0, 988.0, 1175.0, 1568.0]
    samples: list[float] = []
    for dur, f in zip(duration_notes, freqs):
        n = int(rate * dur)
        for i in range(n):
            t = i / rate
            env = min(1.0, i / (rate * 0.01)) * math.exp(-3.0 * t / dur)
            ff = f * (1.0 + 0.008 * math.sin(2 * math.pi * 6 * t)) if dur > 0.2 else f
            val = 0.45 * env * math.sin(2 * math.pi * ff * t)
            val += 0.12 * env * math.sin(2 * math.pi * ff * 2 * t)
            samples.append(max(-1.0, min(1.0, val)))
    samples.extend([0.0] * int(rate * 0.05))
    return samples


def main() -> None:
    rate = 44100
    samples = synthesize(rate)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    try:
        with wave.open(wav_path, "w") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
        subprocess.check_call(
            ["ffmpeg", "-y", "-i", wav_path, "-acodec", "pcm_s16le", str(OUT)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    finally:
        os.unlink(wav_path)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
