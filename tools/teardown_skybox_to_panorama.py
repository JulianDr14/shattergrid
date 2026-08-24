"""Cubemap DDS de Teardown -> panorama equirectangular PNG para PanoramaSkyMaterial.

El .dds es RGBA32F, 6 caras de 256x256 con 9 mips cada una, en orden +X -X +Y -Y +Z -Z.
Se lee solo el mip 0 de cada cara y se remuestrea a equirectangular con vecino mas cercano:
la fuente son 256 px por cara, cualquier filtrado mas fino no aporta nada visible en un cielo.
"""
import struct
import sys

import numpy as np
from PIL import Image

FACES = ("+X", "-X", "+Y", "-Y", "+Z", "-Z")


def read_faces(path):
    raw = open(path, "rb").read()
    assert raw[:4] == b"DDS ", "no es un DDS"
    height, width, _pitch, _depth, mips = struct.unpack_from("<5I", raw, 12)
    fourcc = struct.unpack_from("<I", raw, 0x54)[0]
    assert fourcc == 116, f"se esperaba A32B32G32R32F (116), no {fourcc}"
    assert height == width, "cara no cuadrada"
    # Cada cara lleva su cadena de mips completa y contigua.
    face_bytes = sum((width >> level) ** 2 for level in range(mips)) * 16
    faces = []
    for index in range(6):
        start = 128 + index * face_bytes
        pixels = np.frombuffer(raw, "<f4", count=width * width * 4, offset=start)
        faces.append(pixels.reshape(width, width, 4)[:, :, :3])
    assert 128 + 6 * face_bytes == len(raw), "sobran o faltan bytes"
    return np.stack(faces), width


def equirectangular(faces, size):
    """size = ancho; el alto es la mitad. Devuelve float32 lineal."""
    height = size // 2
    # v hacia abajo en la imagen = de +Y a -Y, u de 0 a 2pi.
    theta = (np.arange(height, dtype=np.float32) + 0.5) / height * np.pi
    phi = (np.arange(size, dtype=np.float32) + 0.5) / size * 2.0 * np.pi
    sin_theta = np.sin(theta)[:, None]
    direction = np.stack([
        sin_theta * np.sin(phi)[None, :],
        np.repeat(np.cos(theta)[:, None], size, axis=1),
        sin_theta * -np.cos(phi)[None, :],
    ], axis=-1)

    absolute = np.abs(direction)
    major = np.argmax(absolute, axis=-1)
    positive = np.take_along_axis(direction, major[..., None], -1)[..., 0] > 0
    face = major * 2 + (~positive)
    magnitude = np.take_along_axis(absolute, major[..., None], -1)[..., 0]
    magnitude = np.maximum(magnitude, 1e-9)
    x, y, z = direction[..., 0], direction[..., 1], direction[..., 2]

    # Convenio de cubemap de D3D/OpenGL: por cada cara, que ejes son s y t y con que signo.
    sc = np.select(
        [face == 0, face == 1, face == 2, face == 3, face == 4, face == 5],
        [-z, z, x, x, x, -x],
    )
    tc = np.select(
        [face == 0, face == 1, face == 2, face == 3, face == 4, face == 5],
        [-y, -y, z, -z, -y, -y],
    )
    resolution = faces.shape[1]
    s = np.clip(((sc / magnitude + 1.0) * 0.5 * resolution).astype(np.int32), 0, resolution - 1)
    t = np.clip(((tc / magnitude + 1.0) * 0.5 * resolution).astype(np.int32), 0, resolution - 1)
    return faces[face, t, s]


def sun_direction(panorama):
    """Teardown saca la direccion del sol del pixel mas brillante del HDRI. Aqui igual."""
    height, width = panorama.shape[:2]
    row, column = np.unravel_index(np.argmax(panorama.sum(-1)), (height, width))
    theta = (row + 0.5) / height * np.pi
    phi = (column + 0.5) / width * 2.0 * np.pi
    return np.array([
        np.sin(theta) * np.sin(phi), np.cos(theta), np.sin(theta) * -np.cos(phi)
    ])


def main(source, destination, size=2048, tint=(1.0, 1.0, 1.0)):
    faces, resolution = read_faces(source)
    print(f"caras 6x{resolution}x{resolution} RGBA32F  max={faces.max():.2f}")
    panorama = equirectangular(faces, size)
    direction = sun_direction(panorama)
    print("SOL dir=%.4f %.4f %.4f  elevacion=%.1f  azimut=%.1f" % (
        *direction, np.degrees(np.arcsin(direction[1])),
        np.degrees(np.arctan2(direction[0], -direction[2])),
    ))
    # El tinte se hornea en el PNG porque PanoramaSkyMaterial solo tiene un multiplicador
    # escalar. Si algun dia hace falta compartir un cielo entre mapas con tintes distintos, toca
    # shader de cielo propio.
    panorama = panorama * np.array(tint, dtype=np.float32)
    # El sol de un HDRI pasa de 100; se comprime con Reinhard y se pasa a sRGB. El brillo real del
    # sol lo pone el DirectionalLight, aqui solo hace falta que el cielo tenga el color correcto.
    tonemapped = panorama / (1.0 + panorama)
    srgb = np.where(
        tonemapped <= 0.0031308,
        tonemapped * 12.92,
        1.055 * np.power(np.maximum(tonemapped, 1e-9), 1 / 2.4) - 0.055,
    )
    Image.fromarray((np.clip(srgb, 0, 1) * 255).astype(np.uint8)).save(destination)
    print(f"escrito {destination}  {size}x{size // 2}")


if __name__ == "__main__":
    # uso: <origen.dds> <destino.png> [tinte "r g b"]
    rgb = tuple(float(v) for v in sys.argv[3].split()) if len(sys.argv) > 3 else (1.0, 1.0, 1.0)
    main(sys.argv[1], sys.argv[2], tint=rgb)
