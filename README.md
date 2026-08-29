<div align="center">
  <img src="icon.svg" width="96" alt="Shattergrid">
  <h1>Shattergrid</h1>
  <p>Sandbox voxel destructible para Godot 4, con renderer DDA dedicado y física Jolt.</p>

  <p>
    <img src="https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&amp;logoColor=white" alt="Godot 4.7">
    <img src="https://img.shields.io/badge/C++-17-00599C?logo=cplusplus&amp;logoColor=white" alt="C++ 17">
    <img src="https://img.shields.io/badge/renderer-Vulkan%20DDA-6D5DFB" alt="Vulkan DDA">
    <img src="https://img.shields.io/badge/license-Apache--2.0-D22128" alt="Apache License 2.0">
  </p>
</div>

> Prototipo técnico de investigación centrado en destrucción, coherencia física y rendimiento a
> gran escala. No es un port ni una redistribución de Teardown.

## Características

- Render voxel por `CompositorEffect`, BVH en GPU y DDA con salto de macroceldas 8³.
- Destrucción por material y conectividad exacta de seis vecinos.
- Colisión Jolt fragmentada espacialmente, handoff seguro estático → dinámico y CCD adaptativo.
- Revisiones de contenido, generaciones físicas y diagnóstico `COHERENT / PENDING / DESYNC`.
- Props agarrables, puertas destructibles, joints, cables Verlet y daño por impacto bidireccional.
- Agua batcheada con refracción, SSR, espuma, ondas, salpicaduras, flotación y nado.
- Vehículos importados con suspensión, cámara exterior/cabina y luces funcionales.
- Importador opcional de escenas XML/VOX para pruebas locales sobre datos aportados por el usuario.

La descripción de subsistemas, ownership, invariantes y mediciones está en
[ARCHITECTURE.md](ARCHITECTURE.md).

## Requisitos

- macOS o Windows x86_64 (el descriptor GDExtension publica el target nativo de ambas).
- Godot 4.7 con Forward+ y Jolt Physics.
- CMake 3.22+, compilador C++17 y Ninja recomendado (en Windows, MSVC 2019+ o MinGW-w64).

`godot-cpp` se descarga en la revisión fijada por CMake; no se versionan dependencias, binarios ni
cachés de compilación.

## Puesta en marcha

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
godot --editor --path .
```

Después de importar el proyecto, ejecuta `main.tscn`. Si no hay ningún mapa externo configurado,
se carga automáticamente el pequeño escenario incluido en `assets/models/`.

## Mapas externos opcionales

Los mapas, modelos y texturas de Teardown no forman parte de este repositorio. El importador espera
un `main.xml` convertido junto a su carpeta `vox/`. Puedes pasar una ruta de tres formas:

```bash
# Argumento de ejecución
godot --path . -- --teardown-map=/ruta/al/mapa/main.xml

# Variable de entorno
SHATTERGRID_MAP=/ruta/al/mapa/main.xml godot --path .

# Ruta local convencional para el editor y las sondas de integración
mkdir -p external/teardown_maps
ln -s /ruta/a/la/carpeta/del/mapa external/teardown_maps/lee
```

`external/`, los mapas compilados y los assets de referencia locales están cubiertos por
`.gitignore` para evitar publicaciones accidentales.

## Controles

| Entrada | Acción |
|---|---|
| `WASD` | Caminar o conducir |
| `Shift` | Correr |
| `Espacio` | Saltar / freno de mano |
| Clic izquierdo | Disparo destructivo |
| Clic derecho | Agarrar puerta, prop o fragmento |
| `G` / clic medio | Lanzar bomba |
| `E` | Entrar o salir de un vehículo |
| Rueda del ratón | Zoom de cámara del vehículo |
| `R` | Reiniciar escena |
| `Esc` | Liberar el cursor |

## Pruebas

Las regresiones autocontenidas no necesitan datos externos:

```bash
godot --headless --path . --script res://tests/native/core_selftest.gd
godot --headless --path . --script res://tests/selftest/teardown_architecture_selftest.gd
godot --headless --path . --script res://tests/selftest/physics_budget_selftest.gd
godot --headless --path . --script res://tests/selftest/water_system_selftest.gd
```

Cada test hereda de `tests/selftest/selftest.gd`, que aporta el contador `failures`, `_check()`,
`make_world()` y `make_box_body()`. Solo hay que definir `_run()` y cerrar con
`quit(1 if failures > 0 else 0)`; no redefinas `_init`, el de la base ya difiere `_run`.

Las sondas cuyos nombres empiezan por `map_`, además de los censos de Lee y las pruebas completas
de vehículos, requieren `SHATTERGRID_MAP` o el mapa local en
`external/teardown_maps/lee`.

## Estructura

| Ruta | Contenido |
|---|---|
| `native/` | GDExtension C++: datos voxel, bricks, paletas y operaciones intensivas |
| `scripts/` | Mundo, física, importación, renderer y sistemas jugables |
| `shaders/` | DDA, uploads regionales, agua y cables |
| `tests/` | Autotests, sondas físicas y benchmarks reproducibles |
| `prototype/` | Bancos aislados del renderer |
| `assets/models/` | Escenario voxel incluido y modelos con atribución documentada |

## Licencia

Salvo donde se indique lo contrario, el código y el material original del proyecto se distribuyen
bajo la [Apache License 2.0](LICENSE). Copyright © 2026
[JulianDr14](https://github.com/JulianDr14).

Apache 2.0 permite usar, modificar y distribuir el proyecto, incluso comercialmente, sin regalías.
Las redistribuciones deben conservar la licencia, los avisos aplicables y la atribución incluida en
[NOTICE](NOTICE). Los assets de terceros enumerados allí conservan sus licencias respectivas y no
quedan relicenciados por la licencia principal del proyecto.

## Datos externos y créditos

Este proyecto implementa ideas públicas de representación `Body / Shape / Joint`; no incluye
código ni contenido propietario de Teardown. Teardown es propiedad de Tuxedo Labs y solo se usa
como referencia técnica con archivos que aporta localmente cada usuario.

`casa_barrio.vox`, `casa_dos_plantas.vox` y `casa_garaje.vox` proceden de
[Mini Mike's Metro Minis](https://github.com/mikelovesrobots/mmmm), de Mike Judge, bajo
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Los archivos fuente no fueron
modificados; la conversión de ejes y escala se realiza durante la carga.

`icon.svg` adapta el logotipo de Godot Engine, Copyright © 2017 Andrea Calabró, bajo
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Se adaptó como icono cuadrado redondeado
para este proyecto. Los detalles y enlaces de origen se conservan en [NOTICE](NOTICE).
