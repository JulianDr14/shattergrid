# Changelog

All notable changes to Shattergrid. Dates are ISO 8601.

## [0.2.0-alpha] — 2026-08-29

### Added

- **AP projectile.** New `Projectile` class handling ballistics, penetration and collision, with a
  per-material JSON configuration and its own voxel model. Tank firing now goes through it.
- **Cannon feedback.** Muzzle flash, smoke and reload logic for the tank cannon.
- **Three-part tank.** Hull, turret and barrel as independent pieces, with barrel pitch aiming and
  carriage limits.
- **Surface animation for vehicles.** `VoxelSurfaceAnimation` drives visual offsets and material
  indices without touching bounds or transforms; used for tank road wheels. BVH shape records grew
  from 192 to 240 bytes to carry the data.
- **Shaders.** Voxel DDA shader, a dedicated GLSL DDA pass, a compute shader for voxel region
  uploads, and water shaders for reflection/refraction, foam and ripples.
- **`GameHud`.** World-state metrics — voxel counts, performance statistics — with per-metric
  refresh rates.
- **`ColliderDebug3D`.** Renders collision meshes in front of the camera to debug collision vs.
  visual mismatches.
- **`ScenarioLoader`.** Loads the Teardown map and neighbourhood assets behind a loading screen.
- **`TeardownEnvironment`.** Lighting and environment settings for the scene.

### Changed

- **Vehicle camera isolated from the chassis.** Camera movement no longer inherits vehicle roll and
  pitch, so aiming stays stable while the hull tilts.
- **Voxel importer standardised** to 1 voxel = 10 cm.
- **Assets moved** to the `assets/` directory; shader and player script paths updated to match.
- **Selftests share a base.** `tests/selftest/selftest.gd` provides the `failures` counter,
  `_check()`, `make_world()` and `make_box_body()`; 26 tests inherit from it. Net -949/+335 lines.
  Four redundant tests were merged into the ones already covering them.

### Fixed

- **A ramming vehicle no longer destroys its own hull.** The vehicle-impact guard was applied only
  at dispatch; if destruction freed the target body while the impact waited in the deferred queue,
  the unconstrained sphere ate the attacker's own hull — 27 voxels per ram.
- **Collisions restored on vehicle exit**, without the unwanted push that followed it.
- **Five latent test defects**, all found while merging the selftests: a use-after-free reading a
  freed tank (which aborted `_run()` before `quit()` and left headless processes hanging), two
  rotten-green checks that could never fail, a same-tick read of a value restored two physics frames
  later, and three tests that only used `assert()` — stripped in release builds, so they always
  passed there.
- **Dead code removed** from `voxel_project_paths.gd`, `voxel_ropes.gd`, `voxel_tank_3d.gd`,
  `voxel_vehicle_3d.gd` and `voxel_water_system.gd`.

### Known limitations

- The Windows target is declared in CMake and in the export presets, but it has still not been
  compiled or run on Windows. Only macOS is verified — hence `alpha`.
- Builds ship no Teardown maps; they start from the scene in `models/`.

## [0.1.0-alpha] — 2026-08-26

First tagged version. Technical prototype of voxel destruction for Godot 4.7 with a dedicated DDA
renderer, Jolt physics and a C++ core as a GDExtension.

[0.2.0-alpha]: https://github.com/JulianDr14/shattergrid/compare/v0.1.0-alpha...v0.2.0-alpha
[0.1.0-alpha]: https://github.com/JulianDr14/shattergrid/releases/tag/v0.1.0-alpha
