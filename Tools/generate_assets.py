#!/usr/bin/env python3
"""Reproducible, original pixel textures and audio. No third-party game assets."""
from array import array
from pathlib import Path
import json
import math
import random
import struct
import wave
import zlib


class Raster:
    """Small PNG writer for reproducible asset generation with the standard library."""
    def __init__(self, mode, size, color=None):
        self.mode, self.size = mode, size
        self.channels = len(mode)
        self.data = bytearray(bytes(color or (0,)*self.channels) * (size[0]*size[1]))

    @classmethod
    def new(cls, mode, size, color=None):
        return cls(mode, size, color)

    def resize(self, size):
        result = Raster(self.mode, size)
        for y in range(size[1]):
            for x in range(size[0]):
                source = ((y*self.size[1]//size[1])*self.size[0]+x*self.size[0]//size[0])*self.channels
                target = (y*size[0]+x)*self.channels
                result.data[target:target+self.channels] = self.data[source:source+self.channels]
        return result

    def point(self, function):
        result = Raster(self.mode, self.size)
        result.data = self.data.translate(bytes(function(i) for i in range(256)))
        return result

    def paste(self, source, position):
        for y in range(source.size[1]):
            start = ((y+position[1])*self.size[0]+position[0])*self.channels
            row = source.size[0]*self.channels
            result = y*row
            self.data[start:start+row] = source.data[result:result+row]

    def save(self, path):
        def chunk(name, payload):
            return struct.pack('>I',len(payload))+name+payload+struct.pack('>I',zlib.crc32(name+payload))
        width,height = self.size
        row = width*self.channels
        pixels = b''.join(b'\0'+self.data[y*row:(y+1)*row] for y in range(height))
        header = struct.pack('>IIBBBBB',width,height,8,6 if self.channels==4 else 2,0,0,0)
        Path(path).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',header)+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b''))


class Draw:
    def __init__(self, image): self.image = image
    def point(self, position, fill):
        x,y = position
        if 0 <= x < self.image.size[0] and 0 <= y < self.image.size[1]:
            start = (y*self.image.size[0]+x)*self.image.channels
            self.image.data[start:start+self.image.channels] = bytes(fill if len(fill)==self.image.channels else (*fill,255))
    def rectangle(self, bounds, fill):
        x0,y0,x1,y1 = map(int,bounds)
        color = bytes(fill if len(fill)==self.image.channels else (*fill,255))
        x0,x1 = max(0,x0),min(self.image.size[0]-1,x1)
        for y in range(max(0,y0),min(self.image.size[1]-1,y1)+1):
            start = (y*self.image.size[0]+x0)*self.image.channels
            self.image.data[start:start+(x1-x0+1)*self.image.channels] = color*(x1-x0+1)
    def polygon(self, points, fill):
        for y in range(int(min(p[1] for p in points)),int(max(p[1] for p in points))+1):
            intersections=[]
            for i,(x0,y0) in enumerate(points):
                x1,y1=points[(i+1)%len(points)]
                if min(y0,y1)<=y<max(y0,y1): intersections.append(x0+(y-y0)*(x1-x0)/(y1-y0))
            intersections.sort()
            for i in range(0,len(intersections)-1,2): self.rectangle((math.ceil(intersections[i]),y,math.floor(intersections[i+1]),y),fill)


Image = Raster

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
RESOURCES.mkdir(exist_ok=True)
rng = random.Random(8192)

COLORS = [(93,177,46), (121,77,40), (115,69,38), (143,148,140),
          (239,220,165), (114,69,36), (183,137,73), (72,158,43),
          (34,151,181), (195,94,61), (174,220,230), (241,250,253),
          (44,39,43), (210,98,132), (245,193,79), (211,205,177),
          (231,225,206), (205,186,137), (81,57,38), (131,94,54),
          (246,158,192), (234,133,39), (43,116,58), (123,185,56),
          (141,216,59), (255,219,57), (248,252,232), (181,118,244),
          (247,102,16), (161,213,63), (76,151,42), (64,124,37)]
tiles = []
opacity_tiles = []
for index, base in enumerate(COLORS):
    tile = Image.new("RGB", (32,32))
    draw = Draw(tile)
    opacity = Image.new("RGB", (32,32), (255,255,255))
    mask = Draw(opacity)
    for y in range(32):
        for x in range(32):
            # Coherent broad pixels, rather than independent noisy texels.
            cluster = ((x//3)*17 + (y//3)*31 + index*7) % 11 - 5
            variation = cluster*3 + rng.choice([-2,0,0,0,2])
            color = tuple(max(0, min(255, c+variation)) for c in base)
            if index == 0:
                clump = (x//4 * 13 + y//3 * 7) % 7
                color = tuple(max(0,min(255,c+clump*5-16+variation//3)) for c in base)
                if x%8 in (2,3) and y%9 in (1,2): color = (124,197,58)
            if index == 2:
                if (x//2*7+y//3*11)%17 == 0: color = (155,105,61)
                elif (x//3*13+y//2*5)%19 == 0: color = (80,48,29)
            if index in (7,20,21,22,23):
                # Overlapping pixel leaves: bright edges, dark clustered gaps.
                leaf = (x//4*13 + y//4*7) % 11
                edge = 27 if (x%4 == 1 and y%4 == 0) or (x%4 == 0 and y%4 < 3) else 0
                tone = (leaf%4)*12 - 24 + edge
                if x%4 == 3 and y%4 == 3: tone -= 18
                color = tuple(max(0,min(255,c+variation//3+tone)) for c in base)
                if leaf in (0,7) and (x%4+y%4)<4:
                    mask.point((x,y),fill=(0,0,0))
            if index == 1 and y < 6 + (x*7 % 5):
                color = tuple(max(0,min(255,c+variation)) for c in COLORS[0])
            if index in (5,18):
                variation += -20 if (x + y//11) % 8 in (0,1) else 9
                color = tuple(max(0,min(255,c+variation)) for c in base)
            if index in (6,17,19):
                radius = math.sqrt((x-15.5)**2+(y-15.5)**2)
                if int(radius) % 5 == 0: color = (120,82,42)
            if index == 3:
                seam = (x + y//6*3) % 19 == 0 and y%13 < 8
                if seam: color = (111,119,115)
                elif (x//4*7+y//3*19)%17 == 0: color = (166,169,157)
            if index == 4:
                ripple = int(5*math.sin((y + math.sin(x*.2)*2)*.7))
                color = tuple(max(0,min(255,c+variation//2+ripple)) for c in base)
            if index == 9 and (y % 8 == 0 or (x+(8 if (y//8)%2 else 0)) % 16 == 0):
                color = (232,192,143)
            if index == 10:
                color = (216,245,248) if x in (0,31) or y in (0,31) or x+y in (19,20) else (146,199,211)
            if index == 8:
                color = tuple(max(0,min(255,c+variation+(8 if y % 4 == 0 else 0))) for c in base)
            if index == 16:
                color = (58,52,47) if y%9 in (0,1) and (x+y//9*7)%21 < 9 else tuple(max(0,min(255,c+variation//3)) for c in base)
            if index == 14:
                color = (255,220,118) if (x//4+y//4)%2 else (233,151,43)
            if index == 12:
                if (x + y//7*5) % 13 == 0: color = (23,20,24)
            if index == 13:
                if (x//2*13+y//2*7)%11 < 3: color = (130,65,98)
                elif (x+y)%7 == 0: color = (247,146,160)
            if index == 15:
                if y%9 == 0 or (x+y//9*6)%17 == 0: color = (157,165,151)
            if index == 28:
                fissure = abs(math.sin(x*math.pi/8 + math.sin(y*math.pi/16)*1.3))
                heat = math.sin(y*math.pi/8 + math.cos(x*math.pi/16))
                color = (255,215,73) if fissure < .20 else ((99,25,14) if heat > .72 else (246,88+int(fissure*53),10))
            draw.point((x,y), fill=color)
    if index == 24:
        # Original cutout sprites, rendered on crossed cards in the world mesh.
        # Color under transparent texels stays green to avoid filtering fringes.
        draw.rectangle((0,0,31,31),fill=(98,183,43))
        mask.rectangle((0,0,31,31),fill=(0,0,0))
        if index == 24:
            for blade in range(11):
                x = 1 + blade*3
                top = 3 + rng.randrange(15)
                lean = rng.choice([-4,-2,0,2,4])
                points = [(x,31),(x+2,31),(x+lean+1,top),(x+lean,top)]
                color = [(116,207,45),(162,230,67),(89,178,38),(137,216,54)][blade%4]
                draw.polygon(points,fill=color)
                mask.polygon(points,fill=(255,255,255))
        else:
            draw.rectangle((15,12,16,31),fill=(60,146,39))
            mask.rectangle((15,12,16,31),fill=(255,255,255))
            for points in [[(15,23),(9,18),(7,19),(15,27)],[(16,27),(22,22),(24,23),(16,30)]]:
                draw.polygon(points,fill=(121,202,53)); mask.polygon(points,fill=(255,255,255))
            for box in [(11,4,20,15),(7,8,24,12)]:
                draw.rectangle(box,fill=base); mask.rectangle(box,fill=(255,255,255))
            draw.rectangle((13,8,18,12),fill=(246,167,36) if index != 27 else (255,220,92))
    def padded(source):
        interior = source.resize((56,56))
        result = Image.new("RGB", (64,64))
        for py in range(64):
            for px in range(64):
                sx,sy = max(0,min(55,px-4)),max(0,min(55,py-4))
                src = (sy*56+sx)*3; dst = (py*64+px)*3
                result.data[dst:dst+3] = interior.data[src:src+3]
        return result
    tiles.append(padded(tile))
    opacity_tiles.append(padded(opacity))

# Subtle directional ambient shading supplements real sun/moon lighting.
atlas = Image.new("RGB", (1024,512))
normal_atlas = Image.new("RGB", (1024,512))
opacity_atlas = Image.new("RGB", (1024,512))
occlusion_atlas = Image.new("RGB", (1024,512))
for shade, brightness in enumerate([1.0,0.97,0.92,0.84]):
    for i, tile in enumerate(tiles):
        toned = tile.point(lambda c: int(c * brightness))
        cell = shade*32+i
        atlas.paste(toned, ((cell%16)*64, (cell//16)*64))
        opacity_atlas.paste(opacity_tiles[i], ((cell%16)*64, (cell//16)*64))
        normal = Image.new("RGB", (64,64), (128,128,255))
        nd = Draw(normal)
        def luminance(x,y):
            offset = ((y%64)*64+x%64)*3
            return sum(tile.data[offset:offset+3])/765
        for y in range(64):
            for x in range(64):
                nx = (luminance(x-2,y)-luminance(x+2,y))*.9
                ny = (luminance(x,y-2)-luminance(x,y+2))*.9
                length = math.sqrt(nx*nx+ny*ny+1)
                nd.point((x,y),fill=(int((nx/length*.5+.5)*255),int((ny/length*.5+.5)*255),int((1/length*.5+.5)*255)))
        normal_atlas.paste(normal, ((cell%16)*64,(cell//16)*64))
        occlusion = Image.new("RGB", (64,64))
        od = Draw(occlusion)
        for y in range(64):
            for x in range(64):
                # Gentle pixel crevice shading, not a dark border around every cube.
                light = luminance(x,y)
                value = int(225 + min(30,max(0,light*38)))
                od.point((x,y),fill=(value,value,value))
        occlusion_atlas.paste(occlusion,((cell%16)*64,(cell//16)*64))
atlas.save(RESOURCES / "BlockAtlas.png")
normal_atlas.save(RESOURCES / "BlockNormals.png")
opacity_atlas.save(RESOURCES / "BlockOpacity.png")
occlusion_atlas.save(RESOURCES / "BlockOcclusion.png")
from water_material import generate as generate_water
generate_water(RESOURCES)
(RESOURCES / "BlockAtlasManifest.json").write_text(json.dumps({
    "width":1024,"height":512,"tileSize":64,"padding":4,"columns":16,"shades":4,
    "uvOrigin":"bottom-left","imageOrigin":"top-left",
    "grass":{"top":0,"side":1,"bottom":2},"dirt":2,"stone":3,
    "wood":{"side":5,"end":6},"birch":{"side":16,"end":17},
    "basalt":12,"coral":13,"limestone":15,"lava":28,
    "solidPlants":list(range(25,28))+list(range(29,32))},indent=2))
from lava_material import images as lava_images
for name, pixels in lava_images().items():
    lava_image = Image.new("RGB", (256,256))
    lava_image.data = pixels
    lava_image.save(RESOURCES / name)
for suffix, grass, leaves, stone, sand in [
    ("-dune",(143,162,59),(99,145,73),(186,133,91),(239,183,103)),
    ("-frost",(144,182,183),(69,124,140),(149,179,198),(180,153,111)),
    ("-ember",(112,77,47),(125,79,51),(76,66,64),(161,114,80)),
    ("-aurora",(140,78,185),(159,81,171),(132,128,184),(210,178,206)),
    ("-solar",(113,61,30),(124,65,27),(58,40,38),(139,72,39))]:
    variant = Image.new("RGB", (1024,512))
    for shade, brightness in enumerate([1.0,0.97,0.92,0.84]):
        for i,tile in enumerate(tiles):
            target = {0:grass,24:grass,29:grass,30:leaves,31:leaves,7:leaves,3:stone,4:sand}.get(i)
            adjusted=Image.new("RGB", (64,64))
            for pixel in range(64*64):
                for c in range(3):
                    v=tile.data[pixel*3+c]
                    if target: v=max(0,min(255,target[c]+v-COLORS[i][c]))
                    if i == 1 and tile.data[pixel*3+1] > tile.data[pixel*3]:
                        v=max(0,min(255,grass[c]+v-COLORS[0][c]))
                    adjusted.data[pixel*3+c]=int(v*brightness)
            cell=shade*32+i
            variant.paste(adjusted,((cell%16)*64,(cell//16)*64))
            if shade == 0:
                block = {0:1,3:3,4:4,5:5,7:6,9:8,10:9}.get(i)
                if block is not None:
                    folder=RESOURCES / "Assets.xcassets" / f"Block{block}{suffix}.imageset"
                    folder.mkdir(parents=True,exist_ok=True)
                    adjusted.save(folder / "block.png")
                    (folder / "Contents.json").write_text(json.dumps({"images":[{"filename":"block.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}))
    variant.save(RESOURCES / f"BlockAtlas{suffix}.png")

# Authored equirectangular skies also drive image-based lighting/reflections.
sky_rng = random.Random(98173)
for name, zenith, horizon, ground in [
    ("SkyDay", (25,100,240), (139,242,248), (110,169,191)),
    ("SkyDusk", (204,117,45), (255,214,100), (115,103,89)),
    ("SkyNight", (2,5,20), (19,31,60), (6,12,23)),
    ("SpaceSky", (1,2,10), (2,3,12), (1,2,10))]:
    sky = Image.new("RGB", (1024,512)); sd = Draw(sky)
    for y in range(512):
        altitude = abs(y-256)/256
        target = zenith if y < 256 else ground
        blend = altitude**.52
        color = tuple(int(horizon[c]*(1-blend)+target[c]*blend) for c in range(3))
        sd.rectangle((0,y,1023,y), fill=color)
    if name in ("SkyNight","SpaceSky"):
        # A faint galactic band and individually colored, stable stars.
        for _ in range(5500):
            x = sky_rng.randrange(1024); y = int(110 + x*.11 + sky_rng.gauss(0,21))
            if 0 <= y < 256:
                offset = (y*1024+x)*3
                sd.point((x,y), fill=tuple(min(255,v+sky_rng.randrange(2,9)) for v in sky.data[offset:offset+3]))
        for _ in range(2400 if name == "SpaceSky" else 1400):
            x,y = sky_rng.randrange(1024),sky_rng.randrange(512 if name == "SpaceSky" else 245)
            brightness = sky_rng.randrange(65,230)
            sd.point((x,y),fill=(brightness,brightness,min(255,brightness+20)))
            if brightness > 215: sd.point((x+1,y),fill=(brightness//3,brightness//3,brightness//2))
    sky.save(RESOURCES / f"{name}.png")
    if name not in ("SkyNight","SpaceSky"):
        for suffix,tint in [("-dune",(1,.80,.65)),("-frost",(.78,.88,1)),("-ember",(1,.53,.38)),("-aurora",(.77,.66,1)),("-solar",(1,.44,.14))]:
            tinted=Image.new("RGB",(1024,512))
            tinted.data=bytearray(int(v*tint[i%3]) for i,v in enumerate(sky.data))
            tinted.save(RESOURCES / f"{name}{suffix}.png")

assets = RESOURCES / "Assets.xcassets"
assets.mkdir(exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info":{"author":"xcode","version":1}}))
for block, tile in [(1,0),(3,3),(4,4),(5,5),(6,7),(8,9),(9,10)]:
    folder = assets / f"Block{block}.imageset"
    folder.mkdir(exist_ok=True)
    tiles[tile].save(folder / "block.png")
    (folder / "Contents.json").write_text(json.dumps({"images":[{"filename":"block.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}))

# visionOS layered icon: illustrated floating voxel island.
icon = assets / "AppIcon.solidimagestack"
icon.mkdir(exist_ok=True)
(icon / "Contents.json").write_text(json.dumps({"layers":[{"filename":f"{name}.solidimagestacklayer"} for name in ["Front","Middle","Back"]],"info":{"author":"xcode","version":1}}))
for name in ["Front","Middle","Back"]:
    layer = icon / f"{name}.solidimagestacklayer"
    layer.mkdir(exist_ok=True)
    (layer / "Contents.json").write_text(json.dumps({"info":{"author":"xcode","version":1}}))
    image_set = layer / "Content.imageset"
    image_set.mkdir(exist_ok=True)
    image = Image.new("RGBA", (1024,1024), (0,0,0,0))
    d = Draw(image)
    if name == "Back":
        d.rectangle([0,0,1024,1024], fill=(27,62,50))
        d.rectangle([710,185,830,305], fill=(239,210,136))
    if name == "Middle":
        d.polygon([(210,430),(512,580),(512,855),(210,690)], fill=(88,69,44))
        d.polygon([(512,580),(814,430),(814,690),(512,855)], fill=(64,55,39))
        d.polygon([(210,430),(512,278),(814,430),(512,580)], fill=(142,166,84))
        d.polygon([(210,430),(512,580),(512,625),(210,475)], fill=(91,122,58))
        d.polygon([(512,580),(814,430),(814,475),(512,625)], fill=(70,101,47))
        for x,y in [(320,562),(405,685),(645,652),(690,529)]:
            d.rectangle([x,y,x+32,y+28], fill=(121,93,56))
    if name == "Front":
        d.rectangle([471,308,514,463], fill=(113,80,44))
        d.rectangle([388,234,596,342], fill=(59,106,58))
        d.rectangle([416,180,568,256], fill=(92,136,64))
        d.rectangle([440,156,544,195], fill=(120,157,72))
    image.resize((512,512)).save(image_set / "icon.png")
    (image_set / "Contents.json").write_text(json.dumps({"images":[{"filename":"icon.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}))

SAMPLE_RATE = 22050
def save_audio(name, samples, channels=1):
    pcm = array('h', (int(max(-1,min(1,s))*32767) for s in samples))
    import sys
    if sys.byteorder != 'little': pcm.byteswap()
    with wave.open(str(RESOURCES / f"{name}.wav"), 'wb') as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm.tobytes())

for name, duration, tone, decay in [("step_grass",.23,100,23),("step_stone",.20,180,27),("break",.38,130,15),("place",.24,90,24),("splash",.65,63,7)]:
    samples = []
    filtered = 0
    for i in range(int(duration*SAMPLE_RATE)):
        t = i/SAMPLE_RATE
        noise = rng.uniform(-1,1)
        filtered = .68*filtered + .32*noise
        crunch = noise*.22 if name in ("break","step_grass") else filtered*.12
        samples.append((math.sin(2*math.pi*tone*t)*.28 + crunch)*math.exp(-decay*t)*min(1,t*600))
    save_audio(name,samples)

birds = [0.]*(SAMPLE_RATE*12)
for onset in [.6,1.2,3.8,5.0,8.1,8.5,10.4]:
    for i in range(int(.26*SAMPLE_RATE)):
        t = i/SAMPLE_RATE
        phase = 2*math.pi*(1850*t + 280*t*t/.26)
        envelope = math.sin(math.pi*t/.26)**2
        birds[int(onset*SAMPLE_RATE)+i] += .15*math.sin(phase)*envelope
save_audio("birds", birds)

water = []
filtered = 0
for i in range(SAMPLE_RATE*8):
    t = i/SAMPLE_RATE
    filtered = filtered*.93 + rng.uniform(-1,1)*.07
    edge = min(1,t/.3,(8-t)/.3)
    water.append((filtered*.50 + math.sin(2*math.pi*82*t)*.01)*(0.8+.2*math.sin(2*math.pi*t/4))*edge)
save_audio("water",water)

lava=[]
filtered=0
for i in range(SAMPLE_RATE*8):
    t=i/SAMPLE_RATE
    filtered = filtered*.985 + rng.uniform(-1,1)*.015
    edge=min(1,t/.3,(8-t)/.3)
    lava.append((filtered*.55+math.sin(t*2*math.pi*47)*.035)*(0.8+.2*math.sin(t*2*math.pi/4))*edge)
save_audio("lava",lava)

for name, frequency in [("sheep",240),("fox",570),("deer",115),("rabbit",830)]:
    samples = []
    for i in range(int(SAMPLE_RATE*.7)):
        t = i/SAMPLE_RATE
        envelope = math.sin(math.pi*t/.7)**2
        flutter = 1 + .13*math.sin(t*2*math.pi*17)
        tone = math.sin(2*math.pi*frequency*t*flutter)
        samples.append((tone*.09 + math.sin(2*math.pi*frequency*2*t)*.035)*envelope)
    save_audio(name,samples)

for name,duration in [("rex_roar",1.4),("rex_chomp",.32)]:
    samples=[]; filtered=0
    for i in range(int(SAMPLE_RATE*duration)):
        t=i/SAMPLE_RATE
        filtered=filtered*.88+rng.uniform(-1,1)*.12
        envelope=math.sin(math.pi*t/duration)**2
        pitch=74-22*t/duration if name == "rex_roar" else 96+80*t
        growl=math.sin(t*2*math.pi*pitch)+.35*math.sin(t*2*math.pi*pitch*2.1)
        samples.append((growl*.16+filtered*(.2 if name == "rex_roar" else .6))*envelope)
    save_audio(name,samples)

from dinosaur_audio import generate as generate_dinosaur_audio
generate_dinosaur_audio(RESOURCES)
from dog_audio import generate as generate_dog_audio
generate_dog_audio(RESOURCES)

crickets=[]
for i in range(SAMPLE_RATE*8):
    t=i/SAMPLE_RATE
    pulse=max(0,math.sin(t*2*math.pi*2.5))**12
    crickets.append(math.sin(t*2*math.pi*4100)*pulse*.045)
save_audio("crickets",crickets)

import sys
if "--visuals-only" in sys.argv:
    print("Generated vibrant textures, normal atlas, planet skies, full-sphere stars and wildlife sounds.")
    raise SystemExit(0)

# Original 80-second composition: sparse bell/piano tones and soft sustained
# chords. This melody is created here, not transcribed from another game.
duration = 80
left, right = array('f',[0])*(SAMPLE_RATE*duration), array('f',[0])*(SAMPLE_RATE*duration)
def note(midi, onset, length, gain, pan, pad=False):
    frequency = 440*2**((midi-69)/12)
    first = int(onset*SAMPLE_RATE)
    for i in range(min(int(length*SAMPLE_RATE), len(left)-first)):
        t = i/SAMPLE_RATE
        if pad:
            envelope = min(1,t/1.3)*min(1,(length-t)/1.8)*.55
            sample = math.sin(2*math.pi*frequency*t)+.12*math.sin(2*math.pi*frequency*2*t)
        else:
            envelope = min(1,t/.012)*math.exp(-t*.9)*min(1,(length-t)/.3)
            sample = math.sin(2*math.pi*frequency*t)+.28*math.sin(2*math.pi*frequency*2.002*t)+.08*math.sin(2*math.pi*frequency*3*t)
        sample *= gain*envelope
        left[first+i] += sample*(1-pan)*.8
        right[first+i] += sample*pan*.8
        # Two gentle, cross-channel echoes.
        for delay, level in [(.29,.14),(.61,.08)]:
            index = first+i+int(delay*SAMPLE_RATE)
            if index < len(left):
                left[index] += sample*pan*level
                right[index] += sample*(1-pan)*level

chords = [[48,55,60,64],[45,52,57,60],[41,48,53,57],[43,50,55,59]]
for bar in range(8):
    for pitch in chords[bar%4]: note(pitch,bar*9.0,10,.035,.5,pad=True)
melodies = [[72,76,79,74,72],[69,72,76,71,69],[65,69,72,76,72],[67,71,74,79,74]]
for bar in range(8):
    for j,pitch in enumerate(melodies[bar%4]):
        note(pitch,bar*9+1.1+j*1.35,4,.13,.35 if j%2==0 else .65)
interleaved = array('f')
for i in range(len(left)):
    fade = min(1,i/(SAMPLE_RATE*2),(len(left)-i)/(SAMPLE_RATE*5))
    interleaved.extend([left[i]*fade,right[i]*fade])
save_audio("QuietFields",interleaved,channels=2)
print("Generated original voxel textures, planet skies, sound effects and Quiet Fields music.")

# Keep the high-resolution space sky reproducible when rebuilding all assets.
import subprocess
space_tools = ROOT / "tmp" / "asset-tools"
space_tools.mkdir(parents=True, exist_ok=True)
subprocess.run(["swiftc", "-O", "-module-cache-path", str(ROOT / "tmp" / "swift-module-cache"),
                str(ROOT / "Tools" / "GenerateSpaceSky.swift"), "-o", str(space_tools / "generate-space")], check=True)
subprocess.run([str(space_tools / "generate-space"), str(RESOURCES / "SpaceSky.png")], check=True)
