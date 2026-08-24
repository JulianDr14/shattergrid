"""Reescribe GLB voxel con triángulos separados, normales planas y UV box-projected.

No requiere dependencias y genera glTF mínimo (POSITION/NORMAL/TEXCOORD_0, sin índices).
"""
import json, struct, sys, shutil, os

UV_SCALE = 1.0  # 1 tile de textura por unidad de mundo

def read_glb(p):
    d = open(p, 'rb').read()
    off, js, bin_ = 12, None, b''
    while off < len(d):
        ln, ty = struct.unpack('<II', d[off:off+8])
        chunk = d[off+8:off+8+ln]
        if ty == 0x4E4F534A: js = json.loads(chunk)
        else: bin_ = chunk
        off += 8 + ln + (-ln % 4)
    return js, bin_

def acc_read(js, bin_, i):
    a = js['accessors'][i]
    bv = js['bufferViews'][a['bufferView']]
    base = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
    fmt = {5125: 'I', 5123: 'H', 5121: 'B', 5126: 'f'}[a['componentType']]
    sz = struct.calcsize('<' + fmt)
    stride = bv.get('byteStride') or n * sz
    out = []
    for k in range(a['count']):
        o = base + k * stride
        v = struct.unpack_from('<' + fmt * n, bin_, o)
        out.append(v[0] if n == 1 else v)
    return out

def build(path):
    js, bin_ = read_glb(path)
    src = {'accessors': js['accessors'], 'bufferViews': js['bufferViews']}
    out_bin = bytearray()
    js['bufferViews'], js['accessors'] = [], []

    def push(data, count, typ, comp=5126, mn=None, mx=None):
        while len(out_bin) % 4: out_bin.append(0)
        js['bufferViews'].append({'buffer': 0, 'byteOffset': len(out_bin), 'byteLength': len(data)})
        out_bin.extend(data)
        a = {'bufferView': len(js['bufferViews']) - 1, 'componentType': comp,
             'count': count, 'type': typ}
        if mn: a['min'], a['max'] = mn, mx
        js['accessors'].append(a)
        return len(js['accessors']) - 1

    for mesh in js['meshes']:
        for prim in mesh['primitives']:
            pos = acc_read(src, bin_, prim['attributes']['POSITION'])
            idx = acc_read(src, bin_, prim['indices']) if 'indices' in prim else range(len(pos))
            P, N, T = [], [], []
            for t in range(0, len(idx), 3):
                tri = [pos[idx[t + k]] for k in range(3)]
                u = [tri[1][k] - tri[0][k] for k in range(3)]
                v = [tri[2][k] - tri[0][k] for k in range(3)]
                nx = u[1]*v[2] - u[2]*v[1]
                ny = u[2]*v[0] - u[0]*v[2]
                nz = u[0]*v[1] - u[1]*v[0]
                L = (nx*nx + ny*ny + nz*nz) ** 0.5 or 1.0
                nrm = (nx/L, ny/L, nz/L)
                ax = max(range(3), key=lambda k: abs(nrm[k]))  # box projection
                uv_ax = {0: (2, 1), 1: (0, 2), 2: (0, 1)}[ax]
                for p in tri:
                    P.append(p); N.append(nrm)
                    T.append((p[uv_ax[0]] * UV_SCALE, p[uv_ax[1]] * UV_SCALE))
            n = len(P)
            mn = [min(p[k] for p in P) for k in range(3)]
            mx = [max(p[k] for p in P) for k in range(3)]
            prim.pop('indices', None)
            prim['attributes'] = {
                'POSITION': push(b''.join(struct.pack('<3f', *p) for p in P), n, 'VEC3', mn=mn, mx=mx),
                'NORMAL':   push(b''.join(struct.pack('<3f', *v) for v in N), n, 'VEC3'),
                'TEXCOORD_0': push(b''.join(struct.pack('<2f', *v) for v in T), n, 'VEC2'),
            }

    for m in js.get('materials', []):
        m['pbrMetallicRoughness']['roughnessFactor'] = 0.65
        m['doubleSided'] = False

    js['buffers'] = [{'byteLength': len(out_bin)}]
    jb = json.dumps(js, separators=(',', ':')).encode()
    jb += b' ' * (-len(jb) % 4)
    out_bin.extend(b'\0' * (-len(out_bin) % 4))
    body = struct.pack('<II', len(jb), 0x4E4F534A) + jb + \
           struct.pack('<II', len(out_bin), 0x004E4942) + bytes(out_bin)
    open(path, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
    print(f'{os.path.basename(path)}: {sum(len(m["primitives"]) for m in js["meshes"])} prims, '
          f'{len(out_bin)//1024} KB')

if __name__ == '__main__':
    for p in sys.argv[1:]:
        if not os.path.exists(p + '.orig'): shutil.copy(p, p + '.orig')
        build(p)
