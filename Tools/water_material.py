#!/usr/bin/env python3
"""Original periodic water maps and a visionOS 2-compatible RealityKit shader graph.

Run independently to regenerate only water assets. Normals are raw linear data;
all graph nodes use public MaterialX/RealityKit node definitions shipped by Apple.
"""
from pathlib import Path
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def normal_field(u, v):
    dx = dz = 0.0
    for amplitude, kx, kz, phase in [(.28, 3, 2, 0), (.19, -2, 4, 1.7),
                                    (.11, 7, -3, .3), (.065, 12, 9, 2.4),
                                    (.035, -19, 13, .8), (.02, 29, 17, 2.1)]:
        c = amplitude * math.cos(math.tau * (u*kx + v*kz) + phase)
        length = math.hypot(kx, kz)
        dx += c*kx/length
        dz += c*kz/length
    length = math.sqrt(1 + dx*dx + dz*dz)
    return (.5 + .5*dx/length, .5 + .5*dz/length, .5 + .5/length)


def foam_field(u, v):
    # Periodic cellular filaments, with small bubbles inside each cell.
    u, v = u % 1, v % 1
    x = (u + .025*math.sin(math.tau*(3*u+2*v)) + .011*math.sin(math.tau*(7*u-4*v)))*9
    y = (v + .024*math.sin(math.tau*(2*u-3*v)) + .010*math.sin(math.tau*(5*u+6*v)))*9
    distances = []
    for iy in range(math.floor(y)-1, math.floor(y)+2):
        for ix in range(math.floor(x)-1, math.floor(x)+2):
            h = ((ix % 9)*73856093 ^ (iy % 9)*19349663 ^ 0xa511e9b3) & 0xffffffff
            h = ((h ^ (h >> 16))*0x7feb352d) & 0xffffffff
            h = ((h ^ (h >> 15))*0x846ca68b) & 0xffffffff
            h ^= h >> 16
            jx = .2 + .6*((h >> 3) & 1023)/1023
            jy = .2 + .6*((h >> 13) & 1023)/1023
            distances.append(math.hypot(ix+jx-x, iy+jy-y))
    distances.sort()
    edge = math.exp(-((distances[1]-distances[0])*11)**2)
    bubbles = (max(0, math.sin(u*math.tau*27 + math.cos(v*math.tau*18)))
               * max(0, math.sin(v*math.tau*31 + math.sin(u*math.tau*13))))**8
    coverage = .65 + .35*math.sin(math.tau*(2*u+3*v))*math.sin(math.tau*(5*u-2*v))
    return min(1, .05 + edge*coverage + bubbles*.20)


def write_png(path, field, size=256):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            values = field(x/size, y/size)
            if isinstance(values, (float, int)):
                values = (values,)*3
            raw.extend(round(max(0, min(1, c))*255) for c in values)
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag+data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def graph(name, opaque):
    """Two programs: near water blends; horizon water remains an opaque draw.

    No scene-colour/depth copy, reflection render pass, time-driven material
    mutation or procedural fragment noise is required. Three texture samples.
    """
    path = f'/WorldcraftWater/{name}'
    lines = [f'    def Material "{name}" {{',
             '        asset inputs:Normals = @WaterNormals.png@',
             '        asset inputs:Foam = @WaterFoam.png@',
             '        color3f inputs:HazeColor = (0.3, 0.5, 0.6)',
             '        float inputs:HazeAmount = 0',
             f'        token outputs:mtlx:surface.connect = <{path}/Surface.outputs:out>']
    def node(label, identifier, output, **inputs):
        lines.extend([f'        def Shader "{label}" {{', f'            uniform token info:id = "{identifier}"'])
        for key, (kind, value) in inputs.items():
            if isinstance(value, str) and value.startswith('$'):
                link = f'{path}.inputs:{value[1:]}'
                lines.append(f'            {kind} inputs:{key}.connect = <{link}>')
            elif isinstance(value, str) and value.startswith('#'):
                lines.append(f'            {kind} inputs:{key}.connect = <{path}/{value[1:]}.outputs:out>')
            else:
                if isinstance(value, str) and not value.startswith('('): value = f'"{value}"'
                lines.append(f'            {kind} inputs:{key} = {value}')
        lines.extend([f'            {output} outputs:out', '        }'])
        return '#'+label
    f = lambda value: ('float', value)
    c = lambda value: ('color3f', value)
    v = lambda value: ('float3', value)
    uv = node('UV', 'ND_texcoord_vector2', 'float2', index=('int', 0))
    detail = node('DetailUV', 'ND_texcoord_vector2', 'float2', index=('int', 1))
    data = node('Optics', 'ND_geomcolor_color4', 'color4f', index=('int', 0))
    channels = [node(label, 'ND_extract_color4', 'float', **{'in': ('color4f', data), 'index': ('int', i)})
                for i, label in enumerate(['Depth', 'FoamAmount', 'RippleStrength', 'Transmission'])]
    normal_a = node('SwellNormals', 'ND_image_vector3', 'float3', file=('asset', '$Normals'), texcoord=('float2', uv))
    normal_b = node('CapillaryNormals', 'ND_image_vector3', 'float3', file=('asset', '$Normals'), texcoord=('float2', detail))
    normal_sum = node('NormalSum', 'ND_add_vector3', 'float3', in1=v(normal_a), in2=v(normal_b))
    decoded = node('DecodedNormals', 'ND_subtract_vector3', 'float3', in1=v(normal_sum), in2=v('(1, 1, 1)'))
    strength = node('NormalStrength', 'ND_combine3_vector3', 'float3', in1=f(channels[2]), in2=f(channels[2]), in3=f(1))
    scaled = node('ScaledNormals', 'ND_multiply_vector3', 'float3', in1=v(decoded), in2=v(strength))
    normal = node('WaterNormal', 'ND_normalize_vector3', 'float3', **{'in': v(scaled)})
    foam_tex = node('FoamFilaments', 'ND_image_color3', 'color3f', file=('asset', '$Foam'), texcoord=('float2', detail))
    mask = node('FoamMask', 'ND_extract_color3', 'float', **{'in': c(foam_tex), 'index': ('int', 0)})
    foam = node('FoamCoverage', 'ND_multiply_float', 'float', in1=f(mask), in2=f(channels[1]))
    water = node('DepthColor', 'ND_mix_color3', 'color3f', fg=c('(0.006, 0.035, 0.09)'), bg=c('(0.035, 0.37, 0.31)'), mix=f(channels[0]))
    color = node('FoamedWater', 'ND_mix_color3', 'color3f', fg=c('(0.80, 0.94, 0.91)'), bg=c(water), mix=f(foam))
    rough = node('FoamRoughness', 'ND_mix_float', 'float', fg=f(.58), bg=f(.075), mix=f(foam))
    coat = node('Coat', 'ND_mix_float', 'float', fg=f(0), bg=f(.65), mix=f(foam))
    visibility = node('Visibility', 'ND_subtract_float', 'float', in1=f(1), in2=f('$HazeAmount'))
    diffuse = node('HazedDiffuse', 'ND_multiply_color3FA', 'color3f', in1=c(color), in2=f(visibility))
    haze = node('HazeEmission', 'ND_multiply_color3FA', 'color3f', in1=c('$HazeColor'), in2=f('$HazeAmount'))
    surface = dict(baseColor=c(diffuse), emissiveColor=c(haze), normal=v(normal),
                   roughness=f(rough), metallic=f(0), specular=f(.32), clearcoat=f(coat),
                   clearcoatRoughness=f(.06), clearcoatNormal=v(normal))
    if not opaque:
        n = node('WorldNormal', 'ND_normal_vector3', 'float3', space=('string', 'world'))
        view = node('View', 'ND_realitykit_viewdirection_vector3', 'float3', space=('string', 'world'))
        dot = node('Facing', 'ND_dotproduct_vector3', 'float', in1=v(n), in2=v(view))
        absolute = node('TwoSidedFacing', 'ND_absval_float', 'float', **{'in': f(dot)})
        facing = node('FacingClamped', 'ND_clamp_float', 'float', **{'in': f(absolute)})
        grazing = node('Grazing', 'ND_subtract_float', 'float', in1=f(1), in2=f(facing))
        fresnel = node('Fresnel', 'ND_power_float', 'float', in1=f(grazing), in2=f(5))
        transmission = node('ViewOpacity', 'ND_mix_float', 'float', fg=f(.98), bg=f(channels[3]), mix=f(fresnel))
        opacity = node('FoamOpacity', 'ND_mix_float', 'float', fg=f(.98), bg=f(transmission), mix=f(foam))
        surface['opacity'] = f(opacity)
    # Pin the public, original surface node rather than the visionOS 27-only v2.
    node('Surface', 'ND_realitykit_pbr_surfaceshader', 'token', **surface)
    lines.append('    }')
    return '\n'.join(lines)


def generate(destination=ROOT/'Resources'):
    destination.mkdir(parents=True, exist_ok=True)
    write_png(destination/'WaterNormals.png', normal_field)
    write_png(destination/'WaterFoam.png', foam_field)
    text = '#usda 1.0\n( defaultPrim = "WorldcraftWater" )\ndef Scope "WorldcraftWater" {\n'
    text += graph('Surface', False) + '\n' + graph('Horizon', True) + '\n}\n'
    (destination/'WorldcraftWater.usda').write_text(text)


if __name__ == '__main__':
    generate()
