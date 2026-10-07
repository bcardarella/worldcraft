#!/usr/bin/env python3
"""An original, soft two-note dog woof for positional audio. No sampled assets."""
from array import array
import math
from pathlib import Path
import random
import sys
import wave


def generate(destination):
    rate, duration = 22050, .68
    rng, phase, filtered = random.Random(7319), 0.0, 0.0
    samples = []
    for i in range(int(rate * duration)):
        t = i / rate
        envelope = 0.0
        for onset, length, level in [(0.025, .23, 1.0), (.34, .25, .75)]:
            u = (t - onset) / length
            if 0 < u < 1:
                envelope += math.sin(math.pi * u) ** 1.4 * level
        phase += 2 * math.pi * (180 + 75 * math.exp(-t * 12)) / rate
        filtered = .82 * filtered + .18 * rng.uniform(-1, 1)
        tone = math.sin(phase) + .5 * math.sin(phase * 2) + .3 * math.sin(phase * 3)
        samples.append(int((tone * .22 + filtered * .4) * envelope * 32767))
    pcm = array('h', samples)
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(destination / 'dog_bark.wav'), 'wb') as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(rate)
        sound.writeframes(pcm.tobytes())


if __name__ == '__main__':
    generate(Path(__file__).resolve().parents[1] / 'Resources')
