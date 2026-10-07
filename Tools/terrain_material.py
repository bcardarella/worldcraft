#!/usr/bin/env python3
"""Generate the repeated block-atlas material. No textures are resampled.

UV0 counts blocks; UV1.y is a constant atlas tile. Gradients use the unwrapped
UV0, avoiding false coarse mip selection at each fract() boundary. The 4.5px
inset, 55px span, filtering and mip clamp match VoxelMesher/WorldRenderer.
"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def graph():
    path = '/WorldcraftTerrain/Repeated'
    lines = ['#usda 1.0', '( defaultPrim = "WorldcraftTerrain" )',
             'def Scope "WorldcraftTerrain" {', '    def Material "Repeated" {',
             '        asset inputs:Atlas = @BlockAtlas.png@',
             '        asset inputs:Normals = @BlockNormals.png@',
             '        asset inputs:Occlusion = @BlockOcclusion.png@',
             '        color3f inputs:HazeColor = (0.3, 0.5, 0.6)',
             '        float inputs:HazeAmount = 0',
             f'        token outputs:mtlx:surface.connect = <{path}/Surface.outputs:out>']

    def node(label, identifier, output, **inputs):
        lines.extend([f'        def Shader "{label}" {{', f'            uniform token info:id = "{identifier}"'])
        for key, (kind, value) in inputs.items():
            if isinstance(value, str) and value.startswith('$'):
                value = f'<{path}.inputs:{value[1:]}>'; key += '.connect'
            elif isinstance(value, str) and value.startswith('#'):
                value = f'<{path}/{value[1:]}.outputs:out>'; key += '.connect'
            elif isinstance(value, str) and not value.startswith('('):
                value = f'"{value}"'
            lines.append(f'            {kind} inputs:{key} = {value}')
        lines.extend([f'            {output} outputs:out', '        }'])
        return '#' + label

    f = lambda x: ('float', x)
    v2 = lambda x: ('float2', x)
    v3 = lambda x: ('float3', x)
    c = lambda x: ('color3f', x)
    uv = node('Repeats', 'ND_texcoord_vector2', 'float2', index=('int', 0))
    metadata = node('Metadata', 'ND_texcoord_vector2', 'float2', index=('int', 1))
    tile_raw = node('TileValue', 'ND_extract_vector2', 'float', **{'in': v2(metadata), 'index': ('int', 1)})
    tile_bias = node('TileRound', 'ND_add_float', 'float', in1=f(tile_raw), in2=f(.5))
    tile = node('Tile', 'ND_floor_float', 'float', **{'in': f(tile_bias)})
    row_fraction = node('RowFraction', 'ND_multiply_float', 'float', in1=f(tile), in2=f(1/16))
    row = node('Row', 'ND_floor_float', 'float', **{'in': f(row_fraction)})
    row_start = node('RowStart', 'ND_multiply_float', 'float', in1=f(row), in2=f(16))
    column = node('Column', 'ND_subtract_float', 'float', in1=f(tile), in2=f(row_start))
    tile_u = node('TileU', 'ND_multiply_float', 'float', in1=f(column), in2=f(1/16))
    tile_v = node('TileV', 'ND_multiply_float', 'float', in1=f(row), in2=f(1/8))
    u = node('OriginU', 'ND_add_float', 'float', in1=f(tile_u), in2=f(4.5/1024))
    v = node('OriginV', 'ND_subtract_float', 'float', in1=f(7/8+4.5/512), in2=f(tile_v))
    origin = node('Origin', 'ND_combine2_vector2', 'float2', in1=f(u), in2=f(v))
    integral = node('WholeBlocks', 'ND_floor_vector2', 'float2', **{'in': v2(uv)})
    fraction = node('Fraction', 'ND_subtract_vector2', 'float2', in1=v2(uv), in2=v2(integral))
    span = f'({55/1024}, {55/512})'
    scaled = node('WithinTile', 'ND_multiply_vector2', 'float2', in1=v2(fraction), in2=v2(span))
    coordinate = node('AtlasUV', 'ND_add_vector2', 'float2', in1=v2(origin), in2=v2(scaled))
    unwrapped = node('Unwrapped', 'ND_multiply_vector2', 'float2', in1=v2(uv), in2=v2(span))
    dx = node('GradientX', 'ND_MTL_dfdx_vector2', 'float2', p=v2(unwrapped))
    dy = node('GradientY', 'ND_MTL_dfdy_vector2', 'float2', p=v2(unwrapped))
    samples = {}
    for name in ['Atlas', 'Normals', 'Occlusion']:
        samples[name] = node(name+'Sample', 'ND_RealityKitTexture2DGradient_color3', 'color3f',
                            file=('asset', '$'+name), texcoord=v2(coordinate),
                            gradient_dPdx=v2(dx), gradient_dPdy=v2(dy),
                            mag_filter=('string', 'nearest'), min_filter=('string', 'nearest'),
                            mip_filter=('string', 'linear'), max_lod_clamp=f(3), max_anisotropy=('int', 4))
    raw_normal = node('RawNormal', 'ND_convert_color3_vector3', 'float3', **{'in': c(samples['Normals'])})
    doubled = node('DoubleNormal', 'ND_multiply_vector3', 'float3', in1=v3(raw_normal), in2=v3('(2, 2, 2)'))
    decoded = node('DecodeNormal', 'ND_subtract_vector3', 'float3', in1=v3(doubled), in2=v3('(1, 1, 1)'))
    normal = node('Normal', 'ND_normalize_vector3', 'float3', **{'in': v3(decoded)})
    ao = node('AO', 'ND_extract_color3', 'float', **{'in': c(samples['Occlusion']), 'index': ('int', 0)})
    visibility = node('Visibility', 'ND_subtract_float', 'float', in1=f(1), in2=f('$HazeAmount'))
    diffuse = node('Diffuse', 'ND_multiply_color3FA', 'color3f', in1=c(samples['Atlas']), in2=f(visibility))
    haze = node('Haze', 'ND_multiply_color3FA', 'color3f', in1=c('$HazeColor'), in2=f('$HazeAmount'))
    node('Surface', 'ND_realitykit_pbr_surfaceshader', 'token', baseColor=c(diffuse),
         normal=v3(normal), ambientOcclusion=f(ao), emissiveColor=c(haze), roughness=f(.82),
         metallic=f(0), specular=f(.5))
    lines.extend(['    }', '}', ''])
    return '\n'.join(lines)


def validate(text, compile_asset):
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    resources = developer.parent/'SystemFrameworks/ShaderGraph.framework/Versions/A/Resources/MaterialX'
    schemas = [resources/'MaterialX-1.38/MaterialX_NodeDefs/stdlib_defs.mtlx']
    schemas += [resources/'Apple/apple_nodedefs'/name for name in
                ['apple_defs.mtlx', 'apple_image_nodedefs.mtlx', 'apple_metal_nodedefs.mtlx']]
    definitions = {n.get('name'): n for schema in schemas for n in ET.parse(schema).getroot().findall('nodedef')}
    types = dict(float='float', integer='int', vector2='float2', vector3='float3', color3='color3f',
                 string='string', filename='asset', surfaceshader='token', boolean='bool', integer2='int2')
    prefix = '/WorldcraftTerrain/Repeated'
    outputs = {prefix+'.inputs:'+key: kind for kind, key in re.findall(r'^        (\w+) inputs:(\w+) =', text, re.M)}
    connections = []
    for label, shader in re.findall(r'def Shader "(\w+)" \{(.*?)\n        \}', text, re.S):
        identifier = re.search(r'info:id = "(\w+)"', shader)[1]
        definition = definitions[identifier]
        inputs = {n.get('name'): types[n.get('type')] for n in definition.findall('input')}
        for kind, param, connection, value in re.findall(r'(\w+) inputs:(\w+)(\.connect)? = ([^\n]+)', shader):
            assert inputs.get(param) == kind, (label, param, kind, inputs)
            if connection: connections.append((kind, value.strip('<>')))
        kind, output = re.search(r'(\w+) outputs:(\w+)', shader).groups()
        assert kind == types[definition.find('output').get('type')], label
        outputs[prefix+'/'+label+'.outputs:'+output] = kind
    for kind, target in connections:
        assert outputs.get(target) == kind, (kind, target)
    assert (ROOT/'Resources/WorldcraftTerrain.usda').read_text() == text, 'Regenerate stale graph'
    print(f'PASS: repeated-atlas graph, {len(connections)} typed connections and public node definitions')
    if compile_asset:
        scratch = ROOT/'tmp/scratch/terrain-material'
        assets = scratch/'TerrainValidation.rkassets'
        assets.mkdir(parents=True, exist_ok=True)
        for name in ['BlockAtlas.png', 'BlockNormals.png', 'BlockOcclusion.png']:
            shutil.copy2(ROOT/'Resources'/name, assets/name)
        scene = text.replace('def Scope "WorldcraftTerrain"', 'def Xform "WorldcraftTerrain"')
        mesh = '''    def Mesh "Preview" (prepend apiSchemas = ["MaterialBindingAPI"]) {
        rel material:binding = </WorldcraftTerrain/Repeated>
        point3f[] points = [(0,0,0),(0,4,0),(8,4,0),(8,0,0)]
        int[] faceVertexCounts = [3,3]
        int[] faceVertexIndices = [0,1,2,0,2,3]
        normal3f[] normals = [(0,0,-1),(0,0,-1),(0,0,-1),(0,0,-1)]
        texCoord2f[] primvars:st = [(0,0),(0,4),(8,4),(8,0)] (interpolation = "vertex")
        texCoord2f[] primvars:st1 = [(0,64),(0,64),(0,64),(0,64)] (interpolation = "vertex")
    }
'''
        end = scene.rfind('}')
        (assets/'Terrain.usda').write_text(scene[:end]+mesh+scene[end:])
        result = scratch/'TerrainValidation.reality'
        subprocess.run(['xcrun', 'realitytool', 'compile', '--platform', 'xros', '--deployment-target', '2.0',
                        '--use-metal', 'false', '--output-reality', str(result), str(assets)], check=True, timeout=60)
        assert result.stat().st_size > 1000
        print('PASS: Apple Reality asset compiler accepted bound repeated-atlas material for visionOS 2')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--compile', action='store_true')
    options = parser.parse_args()
    text = graph()
    if options.validate or options.compile: validate(text, options.compile)
    else: (ROOT/'Resources/WorldcraftTerrain.usda').write_text(text)
