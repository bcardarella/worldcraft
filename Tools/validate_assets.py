#!/usr/bin/env python3
"""Check the generated PNG atlas contract and recognizable block/plant skins."""
from pathlib import Path
import json
import struct
import zlib
import wave

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "Resources"

def read_png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    offset, payload = 8, b''
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        name, body = data[offset+4:offset+8], data[offset+8:offset+8+length]
        crc = struct.unpack('>I', data[offset+8+length:offset+12+length])[0]
        assert zlib.crc32(name+body) == crc, path
        if name == b'IHDR': width,height,bits,kind,_,_,_ = struct.unpack('>IIBBBBB',body)
        if name == b'IDAT': payload += body
        offset += length+12
    assert bits == 8 and kind == 2, path
    raw = zlib.decompress(payload); row = width*3
    assert len(raw) == (row+1)*height and all(raw[y*(row+1)] == 0 for y in range(height)), path
    pixels = b''.join(raw[y*(row+1)+1:(y+1)*(row+1)] for y in range(height))
    return width,height,pixels

manifest = json.loads((RES / 'BlockAtlasManifest.json').read_text())
assert manifest['grass'] == {'top':0,'side':1,'bottom':2}
assert manifest['dirt'] == 2 and manifest['wood']['side'] != manifest['wood']['end']
for name in ['BlockAtlas.png','BlockAtlas-dune.png','BlockAtlas-frost.png','BlockAtlas-ember.png','BlockAtlas-aurora.png','BlockAtlas-solar.png','BlockNormals.png','BlockOcclusion.png','BlockOpacity.png']:
    w,h,pixels=read_png(RES / name)
    assert (w,h) == (manifest['width'],manifest['height']), name
    # Every atlas cell has a duplicated 4px rim, so small mips retain its skin.
    if name.startswith('BlockAtlas'):
        for tile in range(128):
            x,y=(tile%16)*64,(tile//16)*64
            for yy in [4,16,32,48,59]:
                pixel=lambda xx: pixels[((y+yy)*w+x+xx)*3:((y+yy)*w+x+xx)*3+3]
                assert pixel(0)==pixel(4) and pixel(63)==pixel(59), (name,tile,yy)
    print(f'{name}: dimensions, CRC and atlas contract OK')
w,h,pixels=read_png(RES / 'BlockAtlas.png')
def pixel(tile,x,y):
    i=(((tile//16)*64+y)*w+(tile%16)*64+x)*3
    return tuple(pixels[i:i+3])
assert pixel(0,32,32)[1] > pixel(0,32,32)[0]  # grass top green
assert pixel(1,32,7)[1] > pixel(1,32,7)[0]    # grass fringe at top
assert pixel(1,32,48)[0] > pixel(1,32,48)[1]  # side earth underneath
assert pixel(2,32,32)[0] > pixel(2,32,32)[1]  # dirt stays warm brown
_,_,opacity=read_png(RES / 'BlockOpacity.png')
for tile in manifest['solidPlants']:
    x,y=(tile%16)*64,(tile//16)*64
    for yy in range(64):
        row=opacity[((y+yy)*w+x)*3:((y+yy)*w+x+64)*3]
        assert set(row)=={255}, tile
for name in ['WaterNormals.png','LavaSurface.png','LavaEmission.png','LavaNormals.png','LavaRoughness.png']:
    read_png(RES / name)
for name in ['rex_chomp.wav','rex_roar.wav']:
    assert (RES / name).stat().st_size > 1000
print('Grass top/fringe/earth, dirt, log ends, solid plant skins, water normals and T-rex audio: PASS')

# Cooling crust is dark and rough; narrow hot fissures emit independently.
_,_,emission = read_png(RES / 'LavaEmission.png')
_,_,roughness = read_png(RES / 'LavaRoughness.png')
hot = [i for i in range(0,len(emission),3) if emission[i] > 160]
cold = [i for i in range(0,len(emission),3) if emission[i] < 8]
assert len(hot) > 1000 and len(cold) > 20000
assert sum(roughness[i] for i in hot)/len(hot) < 175
assert sum(roughness[i] for i in cold)/len(cold) > 225
from lava_material import field
for u,v in [(0.,0.),(.31,.53),(.98,.06)]:
    assert max(abs(a-b) for a,b in zip(field(u,v,2),field(u+1,v-1,2))) < 1e-6
assert sum(field(x/16,y/16,0) != field(x/16,y/16,12) for y in range(16) for x in range(16)) > 40
assert {manifest['basalt'],manifest['coral'],manifest['limestone']} == {12,13,15}
print('Lava crust/emission separation, roughness, animation, tile continuity and habitat skins: PASS')

for name, duration in [('rocket_engine', 2), ('rocket_door', .85), ('rocket_arrival', 2)]:
    with wave.open(str(RES / f'{name}.wav'), 'rb') as sound:
        assert sound.getnchannels() == 1 and sound.getsampwidth() == 2, name
        assert sound.getframerate() == 22050, name
        assert abs(sound.getnframes() / sound.getframerate() - duration) < .001, name
        pcm = sound.readframes(sound.getnframes())
        samples = struct.unpack('<' + 'h' * (len(pcm) // 2), pcm)
        assert 100 < max(map(abs, samples)) < 32760, name
        if name == 'rocket_engine':
            assert abs(samples[0] - samples[-1]) < 2000, 'Engine loop boundary clicks'
print('Rocket engine loop, door and arrival audio: mono PCM, duration, level and loop boundary PASS')

for name, duration in [('raptor_call', 1.05), ('dinosaur_call', 1.4), ('colossal_roar', 1.85), ('dog_bark', .68)]:
    with wave.open(str(RES / f'{name}.wav'), 'rb') as sound:
        assert sound.getnchannels() == 1 and sound.getsampwidth() == 2
        assert sound.getframerate() == 22050
        assert abs(sound.getnframes() / sound.getframerate() - duration) < .001
        pcm = sound.readframes(sound.getnframes())
        samples = struct.unpack('<' + 'h' * (len(pcm) // 2), pcm)
        assert 1000 < max(map(abs, samples)) < 32760
        assert abs(samples[0]) < 5 and abs(samples[-1]) < 5
print('Dinosaur calls and dog bark: spatial mono PCM, bounded duration, no clipping or boundary clicks PASS')
