"""Check: cada primitiva tiene NORMAL unitaria + TEXCOORD_0, y AABB conservado."""
import sys, importlib.util
spec = importlib.util.spec_from_file_location('f', __file__.replace('check_glb','fix_glb'))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)

for p in sys.argv[1:]:
    js, b = f.read_glb(p); jo, bo = f.read_glb(p + '.orig')
    for m in js['meshes']:
        for pr in m['primitives']:
            a = pr['attributes']
            assert {'POSITION','NORMAL','TEXCOORD_0'} <= a.keys(), m['name']
            N = f.acc_read(js, b, a['NORMAL'])
            for n in N:
                assert abs(sum(c*c for c in n) - 1) < 1e-4, (m['name'], n)
            assert len(f.acc_read(js, b, a['TEXCOORD_0'])) == len(N)
    # AABB igual al original
    for m, mo in zip(js['meshes'], jo['meshes']):
        n = js['accessors'][m['primitives'][0]['attributes']['POSITION']]
        o = jo['accessors'][mo['primitives'][0]['attributes']['POSITION']]
        assert max(abs(x-y) for x,y in zip(n['min']+n['max'], o['min']+o['max'])) < 1e-5, m['name']
    print(p, 'OK', sum(len(m['primitives']) for m in js['meshes']), 'prims')
