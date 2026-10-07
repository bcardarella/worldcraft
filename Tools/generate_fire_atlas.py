#!/usr/bin/env python3
"""Original, reproducible soft fire/smoke/ember atlas. No third-party assets.

32 lifetime frames, four 64px rows: two flames, smoke, embers. Each cell has
four transparent border pixels; the renderer samples only the interior.
"""
from pathlib import Path
import math
import struct
import zlib

FRAMES, ROWS, CELL = 32, 4, 64


def smooth(a, b, x):
    t = max(0.0, min(1.0, (x-a)/(b-a)))
    return t*t*(3-2*t)


def sample(row, age, x, y):
    fade = smooth(0, .13, age) * (1-smooth(.55, 1, age))
    if row < 2:
        # Tapered, curling tongues with a white-yellow core and warm edges.
        bend = .22*math.sin(y*8+row*2+age*4)*y
        bend += .1*math.sin(y*17-age*9)*y*y
        width = .66*max(0, 1-y)**.62 + .016
        d = abs(x-bend)/width
        shape = (1-smooth(.4, 1.1, d)) * smooth(0, .12, y) * (1-smooth(.84, 1, y))
        core = (1-smooth(.08, .6, d)) * (1-smooth(.15, .7, y))
        heat = max(0, 1-age*.7)
        color = (255, 75+120*heat+60*core, 8+38*heat+150*core)
        return (*color, 230*shape*fade)
    if row == 2:
        r = math.sqrt(x*x+(y*2-1)**2)
        noise = .8+.1*math.sin(x*11+y*16)+.1*math.cos(x*19-y*12)
        shape = (1-smooth(.2, .91, r*noise))
        shade = 77+noise*23
        return (shade, shade*.99, shade*.96, 38*shape*fade)
    r = math.sqrt((x*1.8)**2+((y-.5)*2)**2)
    glow = math.exp(-r*r*8)*(1-smooth(.7, 1, r))
    return (255, 226-age*153, 85*(1-age), 255*glow*fade)


def generate():
    width, height = FRAMES*CELL, ROWS*CELL
    data = bytearray(width*height*4)
    for row in range(ROWS):
        for frame in range(FRAMES):
            age = frame/(FRAMES-1)
            for py in range(4, CELL-4):
                for px in range(4, CELL-4):
                    x, y = (px-4)/55*2-1, 1-(py-4)/55
                    rgba = sample(row, age, x, y)
                    start = ((row*CELL+py)*width + frame*CELL+px)*4
                    data[start:start+4] = bytes(round(max(0, min(255, c))) for c in rgba)
    def chunk(name, payload):
        return struct.pack('>I', len(payload))+name+payload+struct.pack('>I', zlib.crc32(name+payload))
    scanlines = b''.join(b'\0'+data[y*width*4:(y+1)*width*4] for y in range(height))
    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', header)+chunk(b'IDAT', zlib.compress(scanlines, 9))+chunk(b'IEND', b'')
    path = Path(__file__).resolve().parents[1]/'Resources/FireParticles.png'
    path.write_bytes(png)
    print(f'{path.name}: {width}x{height}, {len(png):,} bytes')


if __name__ == '__main__':
    generate()
