#!/usr/bin/env python3
"""Original, deterministic spatial rocket effects (no sampled game audio)."""
from array import array
from pathlib import Path
import math
import random
import sys
import wave

RATE = 22050
ROOT = Path(__file__).resolve().parents[1] / "Resources"
rng = random.Random(58137)


def write(name, values):
    samples = array("h", (round(max(-0.9, min(0.9, v)) * 32767) for v in values))
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(ROOT / f"{name}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(samples.tobytes())


# Periodic harmonic noise has a seamless two-second boundary, unlike a cut
# white-noise buffer. Mono lets RealityKit position the engine below the cabin.
harmonics = [(rng.randint(80, 900) / 2, rng.random() * math.tau) for _ in range(36)]
engine = []
for i in range(RATE * 2):
    t = i / RATE
    rumble = sum(math.sin(math.tau * hz * t + phase) for hz, phase in harmonics) / 70
    engine.append(rumble + .11 * math.sin(math.tau * 52 * t) + .04 * math.sin(math.tau * 104 * t))
write("rocket_engine", engine)

door = []
filtered = 0.0
for i in range(int(RATE * .85)):
    t = i / RATE
    envelope = math.sin(math.pi * t / .85) ** 2
    filtered = .7 * filtered + .3 * rng.uniform(-1, 1)
    door.append(envelope * (.16 * filtered + .09 * math.sin(math.tau * (210 * t - 35 * t * t))))
write("rocket_door", door)

# A short, soft arrival fanfare with a diffuse wordless crowd-like shimmer.
arrival = [0.0] * (RATE * 2)
for n, hz in enumerate([523.25, 659.25, 783.99, 1046.50]):
    start = int(n * .19 * RATE)
    for i in range(int(RATE * 1.3)):
        t = i / RATE
        voice = math.sin(math.tau * hz * t + .06 * math.sin(t * 27))
        arrival[start + i] += voice * math.exp(-t * 3) * min(1, t * 35) * .10
write("rocket_arrival", arrival)
