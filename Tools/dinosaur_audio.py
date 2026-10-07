#!/usr/bin/env python3
"""Original, deterministic mono dinosaur calls for positional RealityKit audio."""
from array import array
import math
from pathlib import Path
import random
import sys
import wave

SAMPLE_RATE = 22050


def generate(destination):
    for index, (name, duration, fundamental) in enumerate([
        ("raptor_call", 1.05, 430), ("dinosaur_call", 1.4, 155), ("colossal_roar", 1.85, 42)
    ]):
        rng = random.Random(9200 + index)
        samples, phase, filtered = [], 0.0, 0.0
        for i in range(int(duration * SAMPLE_RATE)):
            t = i / SAMPLE_RATE
            progress = t / duration
            envelope = math.sin(math.pi * progress) ** 2
            frequency = fundamental * (1.22 - .45 * progress + .04 * math.sin(t * 19))
            phase += 2 * math.pi * frequency / SAMPLE_RATE
            filtered = .91 * filtered + .09 * rng.uniform(-1, 1)
            tone = math.sin(phase) + .35 * math.sin(phase * 2) + .14 * math.sin(phase * 3)
            if name == "raptor_call":
                envelope *= .45 + .55 * max(0, math.sin(t * 20))
            elif name == "colossal_roar":
                tone += .25 * math.sin(phase * .5)
                envelope *= .85 + .15 * math.sin(t * 36)
            samples.append(int((tone * .21 + filtered * .32) * envelope * 32767))
        pcm = array('h', samples)
        if sys.byteorder != 'little':
            pcm.byteswap()
        with wave.open(str(destination / f"{name}.wav"), 'wb') as sound:
            sound.setnchannels(1)
            sound.setsampwidth(2)
            sound.setframerate(SAMPLE_RATE)
            sound.writeframes(pcm.tobytes())


if __name__ == '__main__':
    generate(Path(__file__).resolve().parents[1] / 'Resources')
