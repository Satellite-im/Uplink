#!/usr/bin/env python3
"""Packs the phone the landing page's hero shows into one file for the web: site/model/duo.bin, a gzipped GLB.

    python3 tool/hero3d-model.py "<folder of the prepared model>" [out.bin]

The model is NOT in this repository and must never be: it is a real phone's, its maker's own, and Uplink may show
it but not pass it on. So the folder it is read from lives outside the repository, what this writes is ignored by
git (site/model/), and tool/deploy-site.mjs lays it over the site from ~/.config/mattssoftware/uplink-site-private/
as it ships. Without the file the hero draws a plain foldable of our own (site-src/hero3d/phone.js), which is what
anyone building the site from the public source gets.

The folder holds, for each of two finishes (Star White, and Night Sky with `NightSky_` before each material's name),
the phone open and shut as two OBJ files of the same 66 parts and the same vertices, the materials' values
(*-material-settings.json) and their pictures. This writes:

  - R and L: the parts of the right half and of the left, each a rigid body turning 90 degrees about its own
    hinge line as the phone shuts, merged by material;
  - D_<part>: the few parts that bend instead (the inner display and its bezel, the hinge's cover and seal), each
    with where every vertex is when shut (_CLOSED), for site-src/hero3d/duo.js to carry it between the two;
  - the materials of both finishes (each mesh's `extras.night` is its Night Sky material), with the model's own
    roughness, metal, colour and normal pictures, as WebP;
  - in the scene's extras: the two hinge lines and the screens' rectangles.

The displays are written dark and bare: what is on them is the app's own pages, laid over by the page.

Kept small, since the server sends a file of this kind as it is: the rigid halves' positions, normals and picture
coordinates are whole numbers on a grid (KHR_mesh_quantization, exact to a few thousandths of a millimetre), the
pictures are WebP no larger than they are seen, and the whole file is gzipped, for the page to unpack itself.
"""
import gzip
import hashlib
import io
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SRC = Path(sys.argv[1]).expanduser()
OUT = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / 'site' / 'model' / 'duo.bin'

BENDS = {'Display_Inner_Flexible', 'Inner_Display_Bezel', 'Hinge_Titanium_Cover', 'Hinge_Flexible_Seal'}
SCREENS = {'Outer_OLED', 'Inner_OLED_Nano_Texture'}  # drawn dark, with no picture: the app is laid over them


def parse(path):
    v, vt, vn, objs, cur, mat = [], [], [], [], None, None
    with open(path) as f:
        for line in f:
            if line.startswith('v '): v.append(line.split()[1:4])
            elif line.startswith('vt '): vt.append(line.split()[1:3])
            elif line.startswith('vn '): vn.append(line.split()[1:4])
            elif line.startswith('o '): cur = {'name': line[2:].strip(), 'faces': []}; objs.append(cur); mat = None
            elif line.startswith('usemtl '): mat = line[7:].strip()
            elif line.startswith('f '): cur['faces'].append((mat, [tuple(int(x) if x else 0 for x in p.split('/')) for p in line.split()[1:]]))
    return np.array(v, np.float64), np.array(vt, np.float64), np.array(vn, np.float64), objs


def kabsch(p, q):
    pc, qc = p.mean(0), q.mean(0)
    with np.errstate(all='ignore'):
        u, _, vt = np.linalg.svd((p - pc).T @ (q - qc))
        d = np.sign(np.linalg.det(vt.T @ u.T))
        r = vt.T @ np.diag([1, 1, d]) @ u.T
        return r, qc - r @ pc


np.seterr(all='ignore')  # macOS's numpy warns of overflows in matmul that are not there


print('reading', SRC)
vo, vto, vno, open_objs = parse(SRC / 'iphone-duo-star-white-open.obj')
vc, _, _, shut_objs = parse(SRC / 'iphone-duo-star-white-closed.obj')
_, _, _, night_objs = parse(SRC / 'iphone-duo-night-sky-open.obj')
shut = {o['name']: o for o in shut_objs}
night = {o['name']: o for o in night_objs}
settings = {**json.load(open(SRC / 'iphone-duo-star-white-material-settings.json')), **json.load(open(SRC / 'iphone-duo-night-sky-material-settings.json'))}


def own(o):
    return np.array(sorted({p[0] - 1 for _, f in o['faces'] for p in f}))


# --- which half each part belongs to, and the two hinge lines ----------------------------------------------------
axes = {'L': [], 'R': []}
side = {}
for o in open_objs:
    name = o['name']
    io_, ic = own(o), own(shut[name])
    assert len(io_) == len(ic), name
    if name in BENDS:
        side[name] = 'D'
        continue
    p, q = vo[io_], vc[ic]
    r, t = kabsch(p, q)
    assert np.abs(p @ r.T + t - q).max() < 2e-5, f'{name} is not rigid between the two files'
    # A quarter turn about the upright: sin of it is r[0][2]. The left half turns one way, the right the other.
    s = 'L' if r[0, 2] > 0.5 else 'R' if r[0, 2] < -0.5 else None
    assert s, f'{name} does not turn a quarter'
    side[name] = s
    a = (np.eye(3) - r)[[0, 2]][:, [0, 2]]
    axes[s].append(np.linalg.solve(a, t[[0, 2]]))
axis = {s: np.mean(axes[s], 0) for s in axes}
print('hinge lines (x, z in mm): left', (axis['L'] * 1000).round(3), 'right', (axis['R'] * 1000).round(3))


# --- geometry -----------------------------------------------------------------------------------------------------
def build(objs_of_one_material):
    """One primitive from [(object, material)]: unique (position, uv, normal) corners, and triangles of them."""
    pos, nor, uv, shut_pos, tris, seen = [], [], [], [], [], {}
    for o, mat in objs_of_one_material:
        ranks = {v: i for i, v in enumerate(own(o))}
        closed = own(shut[o['name']])
        for m, f in o['faces']:
            if m != mat: continue
            corner = []
            for (v, t, n) in f:
                key = (o['name'], v, t, n)
                i = seen.get(key)
                if i is None:
                    i = seen[key] = len(pos)
                    pos.append(vo[v - 1]); nor.append(vno[n - 1] if n else (0, 0, 1)); uv.append((vto[t - 1][0], 1 - vto[t - 1][1]) if t else (0, 0))
                    shut_pos.append(vc[closed[ranks[v - 1]]])
                corner.append(i)
            for k in range(1, len(corner) - 1): tris.append((corner[0], corner[k], corner[k + 1]))
    return np.array(pos, np.float32), np.array(nor, np.float32), np.array(uv, np.float32), np.array(shut_pos, np.float32), np.array(tris, np.uint32)


mat_of = {}  # star white material -> night sky material, by the parts that wear them
for o in open_objs:
    for (m, _), (nm, _) in zip(o['faces'], night[o['name']]['faces']):
        assert mat_of.setdefault(m, nm) == nm
groups = {}  # node name -> {material: [(object, material)]}
for o in open_objs:
    node = side[o['name']] if side[o['name']] != 'D' else 'D_' + o['name']
    for m in dict.fromkeys(m for m, _ in o['faces']):
        groups.setdefault(node, {}).setdefault(m, []).append((o, m))

# --- the file -----------------------------------------------------------------------------------------------------
blob = bytearray()
views, accessors, images, textures, materials, meshes, nodes = [], [], [], [], [], [], []


def view(data, target=None):
    while len(blob) % 4: blob.append(0)
    views.append({'buffer': 0, 'byteOffset': len(blob), 'byteLength': len(data), **({'target': target} if target else {})})
    blob.extend(data)
    return len(views) - 1


def accessor(arr, kind, target, bounds=False, normalized=False):
    comp = {np.dtype(np.float32): 5126, np.dtype(np.uint32): 5125, np.dtype(np.uint16): 5123, np.dtype(np.int16): 5122}[arr.dtype]
    if arr.ndim > 1 and arr.dtype.itemsize * arr.shape[1] % 4:  # each vertex starts on a multiple of four bytes
        arr = np.concatenate([arr, np.zeros((arr.shape[0], 1), arr.dtype)], 1)
        views.append(None)
        data = arr.tobytes()
        while len(blob) % 4: blob.append(0)
        views[-1] = {'buffer': 0, 'byteOffset': len(blob), 'byteLength': len(data), 'byteStride': arr.dtype.itemsize * arr.shape[1], 'target': target}
        blob.extend(data)
        a = {'bufferView': len(views) - 1, 'componentType': comp, 'count': int(arr.shape[0]), 'type': kind}
        arr = arr[:, :-1]
    else:
        a = {'bufferView': view(arr.tobytes(), target), 'componentType': comp, 'count': int(arr.shape[0] if arr.ndim > 1 else arr.size), 'type': kind}
    if normalized: a['normalized'] = True
    if bounds: a['min'], a['max'] = arr.min(0).tolist(), arr.max(0).tolist()
    accessors.append(a)
    return len(accessors) - 1


pictures = {}


def texture(img, quality):
    out = io.BytesIO()
    img.save(out, 'WEBP', quality=quality, method=6)
    data = out.getvalue()
    key = hashlib.sha1(data).hexdigest()
    if key not in pictures:
        images.append({'bufferView': view(data), 'mimeType': 'image/webp'})
        textures.append({'sampler': 0, 'extensions': {'EXT_texture_webp': {'source': len(images) - 1}}})
        pictures[key] = len(textures) - 1
    return pictures[key]


def load(name, limit):
    img = Image.open(SRC / name)
    if img.mode in ('I;16', 'I', 'I;16B'): img = Image.fromarray((np.asarray(img, np.float64) / 257).clip(0, 255).astype(np.uint8))
    if max(img.size) > limit: img = img.resize((limit * img.size[0] // max(img.size), limit * img.size[1] // max(img.size)), Image.LANCZOS)
    return img


materials_index = {}


def material(name):
    if name in materials_index: return materials_index[name]
    s = settings[name]
    p, maps = s['principled_linear_values'], s['maps']
    real = lambda ch: ch in maps and maps[ch]['source'] != 'shader constant'
    plain = name.replace('NightSky_', '')
    pbr = {'baseColorFactor': [round(x, 5) for x in p['Base Color']], 'metallicFactor': round(p['Metallic'], 4), 'roughnessFactor': round(max(p['Roughness'], 0.02), 4)}
    m = {'name': name, 'pbrMetallicRoughness': pbr, 'extensions': {}}
    if plain not in SCREENS:
        if real('Base Color'):
            pbr['baseColorTexture'] = {'index': texture(load(maps['Base Color']['file'], 512).convert('RGB'), 86)}
            pbr['baseColorFactor'] = [1, 1, 1, 1]
        if real('Roughness') or real('Metallic'):
            rough = load(maps['Roughness']['file'], 512).convert('L') if real('Roughness') else None
            metal = load(maps['Metallic']['file'], 512).convert('L') if real('Metallic') else None
            size = (rough or metal).size
            flat = lambda value: Image.new('L', size, round(value * 255))
            rough = rough or flat(pbr['roughnessFactor'])
            metal = (metal.resize(size) if metal else None) or flat(pbr['metallicFactor'])
            pbr['metallicRoughnessTexture'] = {'index': texture(Image.merge('RGB', (Image.new('L', size, 255), rough.resize(size), metal)), 80)}
            pbr['roughnessFactor'] = pbr['metallicFactor'] = 1
        if real('Normal'):
            m['normalTexture'] = {'index': texture(load(maps['Normal']['file'], 256).convert('RGB'), 90), 'scale': round(s.get('normal_strength', 1), 3)}
    if p['Coat Weight'] > 0: m['extensions']['KHR_materials_clearcoat'] = {'clearcoatFactor': round(p['Coat Weight'], 3), 'clearcoatRoughnessFactor': round(p['Coat Roughness'], 3)}
    if abs(p['IOR'] - 1.5) > 0.01: m['extensions']['KHR_materials_ior'] = {'ior': round(p['IOR'], 3)}
    if p['Transmission Weight'] > 0:
        # Clear covers (a lens's sapphire, the glass over the mark): seen through, as plain blending, which costs a
        # phone's browser nothing; three's true transmission would draw the whole phone twice.
        pbr['baseColorFactor'] = pbr['baseColorFactor'][:3] + [round(1 - 0.86 * p['Transmission Weight'], 3)]
        m['alphaMode'] = 'BLEND'
    if not m['extensions']: del m['extensions']
    materials.append(m)
    materials_index[name] = len(materials) - 1
    return materials_index[name]


total = 0
for node, by_material in groups.items():
    built = {mat: build(objs) for mat, objs in by_material.items()}
    entry = {'name': node, 'mesh': len(meshes)}
    rigid = not node.startswith('D_')
    if rigid:
        # A half's own grid: 65535 steps along its longest side, from its least corner (the node's place and scale).
        every = np.concatenate([b[0] for b in built.values()])
        low, step = every.min(0), float((every.max(0) - every.min(0)).max()) / 65535
        entry['translation'], entry['scale'] = low.astype(float).round(9).tolist(), [step] * 3
    prims = []
    for mat, (pos, nor, uv, shut_pos, tris) in built.items():
        total += len(tris)
        if rigid:
            unit = nor / np.maximum(np.linalg.norm(nor, axis=1, keepdims=True), 1e-9)
            attrs = {'POSITION': accessor(np.round((pos - low) / step).astype(np.uint16), 'VEC3', 34962, True), 'NORMAL': accessor(np.round(unit * 32767).astype(np.int16), 'VEC3', 34962, normalized=True)}
            inside = uv.min() >= 0 and uv.max() <= 1
            attrs['TEXCOORD_0'] = accessor(np.round(uv * 65535).astype(np.uint16), 'VEC2', 34962, normalized=True) if inside else accessor(uv, 'VEC2', 34962)
        else:
            attrs = {'POSITION': accessor(pos, 'VEC3', 34962, True), 'NORMAL': accessor(nor, 'VEC3', 34962), 'TEXCOORD_0': accessor(uv, 'VEC2', 34962), '_CLOSED': accessor(shut_pos, 'VEC3', 34962)}
        idx = tris.astype(np.uint16 if len(pos) < 65536 else np.uint32).reshape(-1)
        prims.append({'attributes': attrs, 'indices': accessor(idx, 'SCALAR', 34963), 'material': material(mat), 'extras': {'night': material(mat_of[mat])}})
    meshes.append({'name': node, 'primitives': prims})
    nodes.append(entry)


def rect(name):
    p = vo[own(next(o for o in open_objs if o['name'] == name))]
    return {'min': p.min(0).round(6).tolist(), 'max': p.max(0).round(6).tolist()}


gltf = {
    'asset': {'version': '2.0', 'generator': 'Uplink tool/hero3d-model.py'},
    'extensionsUsed': ['EXT_texture_webp', 'KHR_materials_clearcoat', 'KHR_materials_ior', 'KHR_mesh_quantization'],
    'extensionsRequired': ['EXT_texture_webp', 'KHR_mesh_quantization'],
    'scene': 0,
    'scenes': [{'nodes': list(range(len(nodes))), 'extras': {
        'unit': 'metre', 'hingeLeft': axis['L'].round(6).tolist(), 'hingeRight': axis['R'].round(6).tolist(),
        'cover': rect('Display_Outer'), 'inner': rect('Display_Inner_Flexible'), 'camera': rect('Front_Camera_Mask'),
        'body': {'min': vo.min(0).round(6).tolist(), 'max': vo.max(0).round(6).tolist()},
    }}],
    'nodes': nodes, 'meshes': meshes, 'materials': materials, 'textures': textures, 'images': images,
    'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}],
    'accessors': accessors, 'bufferViews': views, 'buffers': [{'byteLength': len(blob)}],
}
while len(blob) % 4: blob.append(0)
gltf['buffers'][0]['byteLength'] = len(blob)
text = json.dumps(gltf, separators=(',', ':')).encode()
text += b' ' * (-len(text) % 4)
OUT.parent.mkdir(parents=True, exist_ok=True)
glb = struct.pack('<4sII', b'glTF', 2, 12 + 8 + len(text) + 8 + len(blob)) + struct.pack('<I4s', len(text), b'JSON') + text + struct.pack('<I4s', len(blob), b'BIN\0') + bytes(blob)
OUT.write_bytes(gzip.compress(glb, 9, mtime=0))
print(f'{OUT}: {OUT.stat().st_size / 1024:.0f} KB ({len(glb) / 1024:.0f} KB unpacked), {total} triangles, {len(nodes)} nodes, {len(materials)} materials, {len(images)} pictures')
