#!/usr/bin/env python3
"""Validate water graph types against Apple's public MaterialX node definitions.

--compile also exercises Apple's Reality asset compiler with both materials
bound to real meshes. It needs Xcode, but not a GPU or a running simulator.
This does not substitute for headset visual or frame-time validation.
"""
from pathlib import Path
import argparse
import math
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from water_material import ROOT, generate, normal_field, foam_field


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compile', action='store_true')
    args = parser.parse_args()
    scratch = ROOT/'tmp/scratch/water-quality'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        generate(Path(directory))
        for name in ['WaterNormals.png', 'WaterFoam.png', 'WorldcraftWater.usda']:
            assert (Path(directory)/name).read_bytes() == (ROOT/'Resources'/name).read_bytes(), f'Stale asset: {name}'
    for u, v in [(0., 0.), (.137, .283), (.997, .09), (-.03, 2.81)]:
        normal = normal_field(u, v)
        assert abs(sum((2*c-1)**2 for c in normal)-1) < 1e-6
        assert max(abs(a-b) for a, b in zip(normal, normal_field(u+1, v-1))) < 1e-6
        assert abs(foam_field(u, v)-foam_field(u+1, v-1)) < 1e-6
    print('PASS: deterministic water assets, unit normals and periodic normal/foam fields')

    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    resource = developer.parent/'SystemFrameworks/ShaderGraph.framework/Versions/A/Resources/MaterialX'
    schemas = [resource/'MaterialX-1.38/MaterialX_NodeDefs/stdlib_defs.mtlx',
               resource/'Apple/apple_nodedefs/apple_defs.mtlx']
    definitions = {}
    for schema in schemas:
        for node in ET.parse(schema).getroot().findall('nodedef'):
            definitions[node.get('name')] = node
    types = dict(float='float', integer='int', vector2='float2', vector3='float3', color3='color3f',
                 color4='color4f', string='string', filename='asset', surfaceshader='token', boolean='bool')
    text = (ROOT/'Resources/WorldcraftWater.usda').read_text()
    outputs = {}; connections = []; node_count = 0
    for name, contents in re.findall(r'def Material "(\w+)" \{(.*?)(?=    def Material|\n\}$)', text, re.S):
        prefix = '/WorldcraftWater/'+name
        for kind, param in re.findall(r'^        (\w+) inputs:(\w+) =', contents, re.M):
            outputs[prefix+'.inputs:'+param] = kind
        for label, shader in re.findall(r'def Shader "(\w+)" \{(.*?)\n        \}', contents, re.S):
            identifier = re.search(r'info:id = "(\w+)"', shader)[1]
            assert identifier in definitions, f'Unsupported shader node: {identifier}'
            definition = definitions[identifier]
            inputs = {n.get('name'): types[n.get('type')] for n in definition.findall('input')}
            for kind, param, connection, value in re.findall(r'(\w+) inputs:(\w+)(\.connect)? = ([^\n]+)', shader):
                assert inputs.get(param) == kind, (label, param, kind, inputs)
                if connection: connections.append((kind, value.strip('<>')))
            kind, output = re.search(r'(\w+) outputs:(\w+)', shader).groups()
            assert kind == types[definition.find('output').get('type')], label
            outputs[prefix+'/'+label+'.outputs:'+output] = kind
            node_count += 1
    assert node_count > 50
    for kind, target in connections:
        assert outputs.get(target) == kind, f'Broken or mistyped connection: {kind} {target}'
    horizon = text.split('def Material "Horizon"')[1]
    assert 'inputs:opacity' not in horizon, 'Distant water must remain an opaque draw'
    print(f'PASS: {node_count} shader nodes and {len(connections)} typed connections match Apple definitions; opaque horizon retained')

    if args.compile:
        assets = scratch/'WaterValidation.rkassets'
        assets.mkdir(exist_ok=True)
        for name in ['WaterNormals.png', 'WaterFoam.png']:
            shutil.copy2(ROOT/'Resources'/name, assets/name)
        scene = text.replace('def Scope "WorldcraftWater"', 'def Xform "WorldcraftWater"')
        meshes = ''
        for name in ['Surface', 'Horizon']:
            meshes += f'''    def Mesh "{name}Preview" (prepend apiSchemas = ["MaterialBindingAPI"]) {{
        rel material:binding = </WorldcraftWater/{name}>
        point3f[] points = [(-1,0,-1),(-1,0,1),(1,0,-1),(1,0,1)]
        int[] faceVertexCounts = [3,3]
        int[] faceVertexIndices = [0,1,2,2,1,3]
        normal3f[] normals = [(0,1,0),(0,1,0),(0,1,0),(0,1,0)]
        texCoord2f[] primvars:st = [(0,0),(0,1),(1,0),(1,1)] (interpolation = "vertex")
        texCoord2f[] primvars:st1 = [(0,0),(0,1),(1,0),(1,1)] (interpolation = "vertex")
        color3f[] primvars:displayColor = [(0.5,0.4,0.7)] (interpolation = "constant")
        float[] primvars:displayOpacity = [0.7] (interpolation = "constant")
    }}
'''
        index = scene.rfind('}')
        (assets/'Water.usda').write_text(scene[:index]+meshes+scene[index:])
        result = scratch/'WaterValidation.reality'
        subprocess.run(['xcrun', 'realitytool', 'compile', '--platform', 'xros', '--deployment-target', '2.0',
                        '--use-metal', 'false', '--output-reality', str(result), str(assets)], check=True, timeout=60)
        assert result.stat().st_size > 1000
        print('PASS: Apple Reality asset compiler accepted both bound water materials for visionOS 2')


if __name__ == '__main__':
    main()
