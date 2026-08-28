class_name VoxelParticlePool
extends MultiMeshInstance3D
## Budgeted impact feedback inspired by Teardown's split between physical voxel volumes and
## cosmetic "plain"/smoke particles. Chips are pooled MultiMesh voxels; dust and sparks are
## manually emitted GPU particles. No deleted voxel becomes an individual RigidBody3D.

const CHIP_CAPACITY := 1536
const CHIP_LIFETIME := 2.4
const MAX_IMPACT_CHIPS := 96
const MAX_IMPACT_DUST := 224
const MAX_IMPACT_SPARKS := 32
## El voxel del mapa (`VoxelShape3D.voxel_size`). El humo se dibuja a esta misma medida: un cubo
## de humo más grande que uno del mundo rompe la escala y canta de inmediato.
const SMOKE_VOXEL_SIZE := 0.1
const DUST_CAPACITY := 3072
const SPARK_CAPACITY := 768
const MUZZLE_FLASH_TIME := 0.14
const FIRE_PUFF_CAPACITY := 512
const SMOKE_PUFF_CAPACITY := 1024

var last_impact_particles := 0
var total_emitted := 0

var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _angular_velocities := PackedVector3Array()
var _life := PackedFloat32Array()
var _colors := PackedColorArray()
var _bases: Array[Basis] = []
var _active_slots := PackedInt32Array()
var _slot_active := PackedByteArray()
var _instance_buffer := PackedFloat32Array()
var _buffer_dirty := false
var _cursor := 0
var _dust: GPUParticles3D
var _sparks: GPUParticles3D
var _fire: GPUParticles3D
var _smoke: GPUParticles3D
var _flash: OmniLight3D
var _flash_life := 0.0
var _flash_energy := 0.0
var _gpu_expiry_batches: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 0x54454152444f574e
	_setup_chip_multimesh()
	_dust = _create_dust_particles()
	_dust.name = "ImpactDust"
	add_child(_dust)
	_sparks = _create_spark_particles()
	_sparks.name = "ImpactSparks"
	add_child(_sparks)
	_fire = _create_puff_particles(FIRE_PUFF_CAPACITY, 0.5, 2.6, 0.7, _fire_ramp())
	_fire.name = "MuzzleFire"
	add_child(_fire)
	_smoke = _create_puff_particles(SMOKE_PUFF_CAPACITY, 1.15, 0.0, 2.1, _smoke_ramp())
	_smoke.name = "MuzzleSmoke"
	add_child(_smoke)
	_flash = _create_flash_light()
	_flash.name = "MuzzleFlash"
	add_child(_flash)
	set_process(false)


## Emits the bounded samples returned by the native damage operation. The native reservoir has a
## hard ceiling of 256 samples, so a huge explosion cannot multiply scripting or particle work.
## `cause` viene de `VoxelWorld3D.damage_sphere`. Solo una explosión hace humo: un riel de hierro
## cayendo al suelo levantaba una bocanada como si ardiera, y eso es lo que rompía la lectura de la
## escena. Todo lo demás son cascotes -cubos de voxel con el color del material- y chispas.
func emit_damage(
	shape: VoxelShape3D, result: Dictionary, impulse_center: Vector3,
	energy: float, radius: float, cause := "impact"
) -> int:
	if multimesh == null or shape == null or shape.palette == null:
		return 0
	var indices: PackedInt32Array = result.get("removed_indices", PackedInt32Array())
	var materials: PackedByteArray = result.get("removed_materials", PackedByteArray())
	var removed := int(result.get("removed", 0))
	if indices.is_empty() or materials.size() != indices.size() or removed <= 0:
		return 0

	var intensity := clampf(sqrt(float(removed)), 1.0, 24.0)
	var is_explosion := cause == "explosion"
	# Sin humo que llene el hueco, un impacto necesita más cascote para leerse igual de bien.
	var chip_rate := 3.5 if is_explosion else 6.0
	var chip_count := mini(indices.size(), mini(MAX_IMPACT_CHIPS, ceili(intensity * chip_rate)))
	var dust_budget := 0
	if is_explosion:
		dust_budget = mini(MAX_IMPACT_DUST, maxi(14, ceili(intensity * 9.0)))
	var spark_budget := mini(MAX_IMPACT_SPARKS, maxi(2, ceili(intensity * 1.5)))
	var emitted := 0
	var dust_emitted := 0
	var sparks_emitted := 0
	# Pull the palette's packed SoA columns once. Building a material Dictionary for every one of
	# the 96 samples cost ~3 ms in a large-map impact even though only four scalar fields are used.
	var palette_colors := shape.palette.get_colors()
	var render_properties := shape.palette.get_render_properties()
	var hardnesses := shape.palette.get_hardnesses()

	for sample in chip_count:
		var source_index := _spread_index(sample, chip_count, indices.size())
		var material_index := int(materials[source_index])
		var world_position := shape.voxel_center_world(indices[source_index])
		var color: Color = palette_colors[material_index] \
			if material_index < palette_colors.size() else Color.GRAY
		var opacity := color.a
		color.a = 1.0
		var outward := _outward_direction(world_position, impulse_center)
		var speed := clampf(1.8 + energy * 0.16 + radius * 0.9, 2.2, 9.5)
		_spawn_chip(world_position, outward * speed * _rng.randf_range(0.55, 1.15)
			+ Vector3.UP * _rng.randf_range(0.7, 2.8), color,
			_rng.randf_range(0.55, 1.15))
		emitted += 1

		var metallic := render_properties[material_index].g \
			if material_index < render_properties.size() else 0.0
		var hardness := hardnesses[material_index] \
			if material_index < hardnesses.size() else 1.0
		var glass_like := opacity < 0.92
		var metal_like := metallic > 0.22
		if dust_emitted < dust_budget and not metal_like and not glass_like:
			var dust_per_sample := 2 if sample < chip_count / 3 else 1
			for _dust_index in mini(dust_per_sample, dust_budget - dust_emitted):
				_emit_dust(world_position, outward, color, intensity)
				dust_emitted += 1
		if sparks_emitted < spark_budget and (metal_like or glass_like or hardness >= 2.0):
			var spark_color := Color(1.0, 0.55, 0.16, 1.0) if metal_like \
				else Color(color.r, color.g, color.b, 0.9)
			_emit_spark(world_position, outward, spark_color, energy)
			sparks_emitted += 1

	# Sparse surfaces may provide fewer chip samples than the dust budget. Add a compact central
	# puff so every explosion reads immediately, even when it removes only a few voxels.
	while is_explosion and dust_emitted < mini(dust_budget, maxi(10, chip_count * 2)):
		var sample_index := dust_emitted % indices.size()
		var material_index := int(materials[sample_index])
		var color: Color = palette_colors[material_index] \
			if material_index < palette_colors.size() else Color.GRAY
		var world_position := shape.voxel_center_world(indices[sample_index])
		_emit_dust(
			world_position, _outward_direction(world_position, impulse_center), color, intensity
		)
		dust_emitted += 1

	emitted += dust_emitted + sparks_emitted
	last_impact_particles = emitted
	total_emitted += emitted
	_flush_chip_buffer()
	_track_gpu_batch(dust_emitted, sparks_emitted)
	set_process(true)
	return emitted


func emit_component(shape: VoxelShape3D, indices: PackedInt32Array, impulse_center: Vector3) -> void:
	if multimesh == null or shape.data == null:
		return
	var colors := shape.palette.get_colors()
	var dimensions := shape.data.get_dimensions()
	for voxel_index in indices:
		var material := shape.data.get_cell(
			voxel_index % dimensions.x,
			(voxel_index % (dimensions.x * dimensions.y)) / dimensions.x,
			voxel_index / (dimensions.x * dimensions.y)
		)
		var color: Color = colors[material] if material < colors.size() else Color.GRAY
		var world_position := shape.voxel_center_world(voxel_index)
		var outward := _outward_direction(world_position, impulse_center)
		_spawn_chip(world_position, outward * 2.8 + Vector3.UP * 2.2, color, 1.0)
		total_emitted += 1
	_flush_chip_buffer()
	set_process(true)


func get_active_count() -> int:
	var gpu_active := 0
	for batch: Dictionary in _gpu_expiry_batches:
		gpu_active += int(batch.count)
	return _active_slots.size() + gpu_active


func _setup_chip_multimesh() -> void:
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * 0.075
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.88
	cube.material = material
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = cube
	multimesh.instance_count = CHIP_CAPACITY
	_positions.resize(CHIP_CAPACITY)
	_velocities.resize(CHIP_CAPACITY)
	_angular_velocities.resize(CHIP_CAPACITY)
	_life.resize(CHIP_CAPACITY)
	_colors.resize(CHIP_CAPACITY)
	_bases.resize(CHIP_CAPACITY)
	_slot_active.resize(CHIP_CAPACITY)
	_instance_buffer.resize(CHIP_CAPACITY * 16)
	for index in CHIP_CAPACITY:
		_hide_chip(index)
	_flush_chip_buffer()


func _spawn_chip(
	world_position: Vector3, velocity: Vector3, color: Color, scale_multiplier: float
) -> void:
	var slot := _cursor
	_cursor = (_cursor + 1) % CHIP_CAPACITY
	if _slot_active[slot] == 0:
		_slot_active[slot] = 1
		_active_slots.append(slot)
	_positions[slot] = world_position
	_velocities[slot] = velocity
	_angular_velocities[slot] = Vector3(
		_rng.randf_range(-8.0, 8.0), _rng.randf_range(-8.0, 8.0),
		_rng.randf_range(-8.0, 8.0)
	)
	_life[slot] = CHIP_LIFETIME * _rng.randf_range(0.72, 1.1)
	_colors[slot] = color
	_bases[slot] = Basis.IDENTITY.scaled(Vector3.ONE * scale_multiplier)
	_write_chip_buffer(slot, _bases[slot], world_position, color)


func _emit_dust(
	world_position: Vector3, outward: Vector3, color: Color, intensity: float
) -> void:
	var dust_color := color.lerp(Color(0.42, 0.40, 0.37, 1.0), 0.38)
	# Alfa alto a propósito: con el hash el desvanecido lo hace la rampa descartando píxeles, y
	# arrancar en 0,28 dejaba el cubo hecho un colador desde el primer frame.
	dust_color.a = _rng.randf_range(0.8, 1.0)
	var velocity := outward * _rng.randf_range(0.25, 1.2) \
		+ Vector3.UP * _rng.randf_range(0.6, 1.8 + intensity * 0.035) \
		+ _random_unit() * 0.35
	var spawn := world_position + Vector3(
		_rng.randfn(0.0, 0.17), _rng.randfn(0.0, 0.13), _rng.randfn(0.0, 0.17)
	)
	_emit_smoke(spawn, velocity, dust_color)


## Emisión cruda de un cubo de humo. Nace en la rejilla de 10 cm, como cualquier voxel del mapa.
## Después la turbulencia lo saca de ella, pero el primer frame de la bocanada es una nube alineada
## con lo que se acaba de romper.
func _emit_smoke(world_position: Vector3, velocity: Vector3, color: Color) -> void:
	_dust.emit_particle(
		Transform3D(Basis.IDENTITY, world_position.snapped(Vector3.ONE * SMOKE_VOXEL_SIZE)),
		velocity, color, Color(0, 0, 0, 0),
		GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_ROTATION_SCALE \
			| GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR
	)


func _emit_spark(
	world_position: Vector3, outward: Vector3, color: Color, energy: float
) -> void:
	var velocity := outward * _rng.randf_range(3.5, 7.0 + minf(energy * 0.12, 5.0)) \
		+ Vector3.UP * _rng.randf_range(1.5, 5.0) + _random_unit() * 1.2
	_sparks.emit_particle(
		Transform3D(Basis.IDENTITY, world_position), velocity, color, Color(0, 0, 0, 0),
		GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY \
			| GPUParticles3D.EMIT_FLAG_COLOR
	)


## Boca de fuego de un cañón. Las cuatro etapas que se distinguen en cualquier vídeo a cámara lenta:
## el destello incandescente en el ánima, la bola de fuego secundaria (el propelente que sale sin
## quemar y se reenciende al encontrar el oxígeno del aire), el humo -que es esa bola ya fría- y la
## cortina que la onda de boca levanta del suelo.
##
## Todo son puffs, no cubos: pocos, grandes y solapados. Cubos pequeños y separados no se leen como
## una masa de gas, se leen como bichos volando, porque el ojo cuenta las siluetas duras una a una.
##
## `power` escala calibre: 1.0 es un cañón de carro de combate.
func emit_muzzle_blast(
	origin: Vector3, direction: Vector3, power := 1.0, ground_y := -INF
) -> void:
	if _fire == null:
		return
	var forward := direction.normalized() if direction.length_squared() > 0.0001 else Vector3.FORWARD
	var side := forward.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = forward.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(forward).normalized()
	var scale := clampf(power, 0.2, 3.0)

	_flash.global_position = origin + forward * 1.6 * scale
	_flash_energy = 70.0 * scale
	_flash.light_energy = _flash_energy
	_flash.omni_range = 34.0 * scale
	_flash.visible = true
	_flash_life = MUZZLE_FLASH_TIME

	# Bola de fuego: cónica y sesgada hacia adelante, y frenando con la distancia al bocacho para que
	# el frente se abra en hongo en vez de viajar como un bloque. Los puffs del núcleo son los
	# gordos; hacia el borde adelgazan.
	var fire_count := ceili(96.0 * scale)
	for index in fire_count:
		var along := _rng.randf() * _rng.randf()
		var spread := (side * _rng.randfn(0.0, 1.0) + up * _rng.randfn(0.0, 1.0)) \
			* (0.35 + along * 1.5) * scale
		var heat := _rng.randf()
		var color := Color(1.0, 0.96, 0.80).lerp(Color(1.0, 0.45, 0.07), heat)
		color.a = _rng.randf_range(0.85, 1.0)
		_emit_puff(
			_fire, origin + forward * (along * 5.0 * scale) + spread,
			forward * lerpf(34.0, 7.0, along) * scale + spread * 2.4,
			color, lerpf(3.4, 1.3, along) * scale
		)

	# Anillo de choque, perpendicular al ánima: es la firma de un calibre grande frente a un fusil,
	# que no lo tiene.
	var ring_count := ceili(26.0 * scale)
	for index in ring_count:
		var angle := TAU * float(index) / float(ring_count) + _rng.randf_range(-0.14, 0.14)
		var radial := (side * cos(angle) + up * sin(angle)).normalized()
		_emit_puff(
			_fire, origin + forward * (0.4 * scale) + radial * (0.8 * scale),
			radial * _rng.randf_range(10.0, 17.0) * scale
				+ forward * _rng.randf_range(2.0, 6.0) * scale,
			Color(1.0, 0.72, 0.30, 0.9), 1.6 * scale
		)

	# Humo. No es un chorro que frena: el gas se enrolla en el labio del bocacho y forma un anillo de
	# vórtice que se lleva el momento del disparo y se va girando hacia adelante mientras se abre.
	# Eso se emite directamente en las velocidades -un toro girando sobre su propio tubo- porque
	# `ParticleProcessMaterial` no tiene campo de vórtice.
	var ring_radius := 1.1 * scale
	var tube_radius := 0.8 * scale
	var smoke_count := ceili(96.0 * scale)
	for index in smoke_count:
		var angle := TAU * _rng.randf()
		var radial := (side * cos(angle) + up * sin(angle)).normalized()
		var phase := TAU * _rng.randf()
		var depth := _rng.randf() * tube_radius
		# Punto dentro del tubo del anillo y velocidad de giro alrededor de su núcleo. El sentido es
		# el de un anillo de humo: por fuera va hacia atrás y por dentro hacia adelante.
		var offset := radial * cos(phase) * depth + forward * sin(phase) * depth
		var roll := (radial * sin(phase) - forward * cos(phase)) * (depth * 7.0)
		_emit_puff(
			_smoke,
			origin + forward * (1.2 * scale) + radial * ring_radius + offset,
			roll + forward * _rng.randf_range(7.0, 12.0) * scale
				+ radial * _rng.randf_range(1.5, 3.5) * scale
				+ Vector3.UP * _rng.randf_range(0.0, 1.0),
			_smoke_color(_rng.randf_range(0.24, 0.42)), lerpf(2.0, 4.0, _rng.randf()) * scale
		)

	# Cola: el gas que sale detrás del anillo y se queda colgando del ánima. Va mucho más lento, así
	# que se deshace donde nació en vez de acompañar al anillo.
	var trail_count := ceili(64.0 * scale)
	for index in trail_count:
		var along := _rng.randf()
		var spread := (side * _rng.randfn(0.0, 1.0) + up * _rng.randfn(0.0, 1.0)) \
			* (0.4 + along * 1.2) * scale
		_emit_puff(
			_smoke, origin + forward * (along * 3.5 * scale) + spread,
			forward * lerpf(6.0, 0.8, along) * scale + spread * 0.9
				+ Vector3.UP * _rng.randf_range(0.3, 1.4),
			_smoke_color(_rng.randf_range(0.18, 0.34)), lerpf(1.8, 3.4, along) * scale
		)
	smoke_count += trail_count

	var kicked := _kick_ground_dust(origin, forward, side, scale, ground_y)
	_track_gpu_batch(smoke_count + kicked, 0)
	_gpu_expiry_batches.append({
		"count": fire_count + ring_count, "expires": Time.get_ticks_msec() + 700,
	})
	set_process(true)


## La onda de boca barre el suelo delante del carro y levanta una cortina de polvo más ancha que la
## propia llamarada. Sin ella el disparo pasa por encima del mundo sin tocarlo.
## ponytail: `ground_y` lo da quien dispara (el fondo de su casco, que está apoyado). Vale mientras
## se dispare desde suelo llano; si hace falta polvo en pendiente, aquí va un raycast.
func _kick_ground_dust(
	origin: Vector3, forward: Vector3, side: Vector3, scale: float, ground_y: float
) -> int:
	if ground_y == -INF or origin.y - ground_y > 6.0 * scale:
		return 0
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length_squared() < 0.0001:
		return 0
	flat = flat.normalized()
	var count := ceili(80.0 * scale)
	for index in count:
		var along := _rng.randf()
		var spawn := origin + flat * (1.5 + along * 9.0) * scale \
			+ side * _rng.randfn(0.0, 1.6) * scale
		spawn.y = ground_y + _rng.randf_range(0.2, 0.8) * scale
		var color := Color(0.56, 0.48, 0.36).lerp(Color(0.33, 0.27, 0.20), _rng.randf())
		color.a = _rng.randf_range(0.18, 0.34)
		_emit_puff(
			_smoke, spawn,
			flat * lerpf(9.0, 1.0, along) * scale + side * _rng.randfn(0.0, 1.8)
				+ Vector3.UP * _rng.randf_range(0.8, 3.0),
			color, lerpf(2.5, 6.0, along) * scale
		)
	return count


func _smoke_color(alpha: float) -> Color:
	var color := Color(0.62, 0.59, 0.55).lerp(Color(0.24, 0.21, 0.19), _rng.randf())
	color.a = alpha
	return color


func _emit_puff(
	emitter: GPUParticles3D, world_position: Vector3, velocity: Vector3, color: Color, size: float
) -> void:
	emitter.emit_particle(
		Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * maxf(size, 0.2)), world_position),
		velocity, color, Color(0, 0, 0, 0),
		GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_ROTATION_SCALE \
			| GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR
	)


## Emisor de bocanadas. La malla es un quad de 1 m: el shader lo encara a la cámara y le pone normal
## esférica, así que la escala que se emite es el diámetro del puff en metros.
##
## Lo que impide que la nube parezca un enjambre no es el shader sino el frenado: `damping` alto para
## que los puffs se paren juntos donde los dejó la onda, y turbulencia floja, porque turbulencia
## fuerte es exactamente lo que hace que cada partícula se vaya por su lado revoloteando.
func _create_puff_particles(
	capacity: int, life: float, emissive: float, edge_softness: float, ramp: Gradient
) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = capacity
	particles.lifetime = life
	particles.local_coords = false
	particles.emitting = false
	particles.fixed_fps = 30
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	particles.visibility_aabb = AABB(Vector3.ONE * -140.0, Vector3.ONE * 280.0)
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3(0.0, 1.4 if emissive > 0.0 else 0.9, 0.0)
	# `damping` en Godot es lineal: resta velocidad hasta el cero exacto. Con un valor alto e igual
	# para todos, la nube avanzaba y se paraba en seco toda a la vez, como contra una pared. Ahora es
	# flojo y muy repartido: cada puff afloja a su ritmo y se deshace antes de llegar a pararse.
	process.damping_min = 0.4
	process.damping_max = 2.6
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 1.1
	process.turbulence_noise_scale = 1.2
	process.turbulence_influence_min = 0.04
	process.turbulence_influence_max = 0.18
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	process.color_ramp = ramp_texture
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/voxel/smoke_puff.gdshader")
	material.set_shader_parameter("emissive", emissive)
	material.set_shader_parameter("edge_softness", edge_softness)
	# El fuego no se deshila: se apaga. La erosión es cosa del humo.
	material.set_shader_parameter("erosion", 0.2 if emissive > 0.0 else 0.85)
	material.set_shader_parameter("bump_strength", 0.5 if emissive > 0.0 else 1.8)
	quad.material = material
	particles.draw_pass_1 = quad
	return particles


func _fire_ramp() -> Gradient:
	# Curva de enfriamiento del gas: blanco, amarillo, naranja, rojo sucio y ya humo.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.14, 0.38, 0.66, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 0.95, 1.0), Color(1.0, 0.85, 0.40, 1.0),
		Color(1.0, 0.45, 0.09, 0.9), Color(0.55, 0.20, 0.06, 0.45),
		Color(0.22, 0.19, 0.17, 0.0),
	])
	return ramp


func _smoke_ramp() -> Gradient:
	# Sube de golpe -la bocanada aparece, no crece- y se va deshaciendo desde el primer tercio. Antes
	# aguantaba media opacidad hasta el final y el humo se quedaba colgado delante del carro.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.06, 0.3, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 1.0),
		Color(0.95, 0.95, 0.95, 0.42), Color(0.88, 0.88, 0.88, 0.0),
	])
	return ramp


## Un fogonazo emisivo sin luz solo se pinta a sí mismo: el casco y el suelo de delante se quedan
## igual de oscuros y el disparo no pesa. Es una sola luz, encendida menos de una décima.
func _create_flash_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.36)
	light.light_energy = 0.0
	light.omni_range = 16.0
	light.shadow_enabled = false
	light.visible = false
	return light


## El humo eran quads billboard con una textura gaussiana y `SHADING_MODE_UNSHADED`: manchas de
## aerógrafo, planas, encima de un mundo de cubos, y parpadeando al reordenarse entre ellas.
## Teardown resuelve su humo dibujándolo opaco y descartando píxeles contra ruido azul en vez de
## mezclar alfa, y sombreándolo para que el sol lo toque. Aquí la partícula directamente ES un
## cubo, alineado a los ejes y en múltiplos del voxel (0,1 m), con normales reales -así que el
## hemisferio falso de Teardown sobra- y `TRANSPARENCY_ALPHA_HASH`, el mismo screen-door, que el
## FSR2 del proyecto ya resuelve temporalmente.
func _create_dust_particles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = DUST_CAPACITY
	particles.lifetime = 1.9
	particles.local_coords = false
	particles.emitting = false
	particles.fixed_fps = 30
	particles.visibility_aabb = AABB(Vector3.ONE * -120.0, Vector3.ONE * 240.0)
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3(0.0, 1.4, 0.0)
	# El drag de antes (1,6-3,2) frenaba la bocanada en medio segundo y los cubos se quedaban
	# aparcados en el aire el resto de la vida. Ahora siguen subiendo, y la turbulencia -ruido nativo
	# del ParticleProcessMaterial- les da la deriva que hace que un humo parezca humo y no una rejilla.
	process.damping_min = 0.35
	process.damping_max = 0.9
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 1.4
	process.turbulence_noise_scale = 2.6
	process.turbulence_noise_speed = Vector3(0.35, 0.2, 0.35)
	process.turbulence_influence_min = 0.15
	process.turbulence_influence_max = 0.55
	# Sin variación ni curva de escala: un voxel de humo mide lo que mide un voxel del mapa y punto.
	# Una bocanada crece porque hay más cubos y se separan, no porque cada cubo se infle.
	var ramp := Gradient.new()
	# El color va a saltos -el humo cambia de tono como cambia un voxel al de al lado- pero el alfa
	# tiene que bajar continuo: en escalones el hash descartaba un pedazo del cubo de golpe en cada
	# peldaño y la partícula se iba a trompicones en vez de disolverse.
	ramp.offsets = PackedFloat32Array([0.0, 0.16, 0.42, 0.68, 0.88, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 0.98, 0.94, 1.0), Color(0.84, 0.82, 0.78, 0.9),
		Color(0.68, 0.66, 0.62, 0.72), Color(0.55, 0.53, 0.5, 0.46),
		Color(0.46, 0.44, 0.42, 0.2), Color(0.42, 0.4, 0.38, 0.0),
	])
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	process.color_ramp = ramp_texture
	particles.process_material = process
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * SMOKE_VOXEL_SIZE
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	cube.material = material
	particles.draw_pass_1 = cube
	return particles


func _create_spark_particles() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = SPARK_CAPACITY
	particles.lifetime = 0.62
	particles.local_coords = false
	particles.emitting = false
	particles.fixed_fps = 60
	particles.visibility_aabb = AABB(Vector3.ONE * -120.0, Vector3.ONE * 240.0)
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3.DOWN * 9.81
	process.damping_min = 0.2
	process.damping_max = 0.7
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	ramp.colors = PackedColorArray([
		Color.WHITE, Color(1.0, 0.52, 0.12, 0.85), Color(1.0, 0.2, 0.03, 0.0),
	])
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	process.color_ramp = ramp_texture
	particles.process_material = process
	# La chispa era una tira billboard con alfa: en un mundo de cubos se leía como una raya de
	# Photoshop. Ahora es una brasa -un cubo alineado a los ejes, en la misma rejilla que todo lo
	# demás pero a media escala de voxel, que es lo que la distingue de un cascote.
	var ember := BoxMesh.new()
	ember.size = Vector3.ONE * (SMOKE_VOXEL_SIZE * 0.5)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.08)
	material.emission_energy_multiplier = 2.5
	ember.material = material
	particles.draw_pass_1 = ember
	return particles


func _process(delta: float) -> void:
	var active_index := _active_slots.size() - 1
	while active_index >= 0:
		var slot := _active_slots[active_index]
		_life[slot] -= delta
		if _life[slot] <= 0.0:
			_hide_chip(slot)
			_active_slots.remove_at(active_index)
			active_index -= 1
			continue
		_velocities[slot] += Vector3.DOWN * 9.81 * delta
		_positions[slot] += _velocities[slot] * delta
		# Cheap world collision for cosmetic chips. Gameplay collision remains on Jolt Bodies.
		if _positions[slot].y < 0.04:
			_positions[slot].y = 0.04
			if _velocities[slot].y < 0.0:
				_velocities[slot].y *= -0.27
				_velocities[slot].x *= 0.72
				_velocities[slot].z *= 0.72
				if absf(_velocities[slot].y) < 0.32:
					_velocities[slot].y = 0.0
		var angular := _angular_velocities[slot]
		if angular.length_squared() > 0.001 and _velocities[slot].length_squared() > 0.03:
			_bases[slot] = _bases[slot].rotated(angular.normalized(), angular.length() * delta)
		var color := _colors[slot]
		if _life[slot] < 0.45:
			color.a = clampf(_life[slot] / 0.45, 0.0, 1.0)
		_write_chip_buffer(slot, _bases[slot], _positions[slot], color)
		active_index -= 1

	if _flash_life > 0.0:
		_flash_life -= delta
		# Cae al cuadrado: un fogonazo no se atenúa, se corta.
		var remaining := clampf(_flash_life / MUZZLE_FLASH_TIME, 0.0, 1.0)
		_flash.light_energy = _flash_energy * remaining * remaining
		_flash.visible = _flash_life > 0.0

	var now := Time.get_ticks_msec()
	for index in range(_gpu_expiry_batches.size() - 1, -1, -1):
		if now >= int(_gpu_expiry_batches[index].expires):
			_gpu_expiry_batches.remove_at(index)
	_flush_chip_buffer()
	set_process(not _active_slots.is_empty() or not _gpu_expiry_batches.is_empty()
		or _flash_life > 0.0)


func _hide_chip(slot: int) -> void:
	_slot_active[slot] = 0
	_life[slot] = 0.0
	_write_chip_buffer(
		slot, Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO,
		Color(0.0, 0.0, 0.0, 0.0)
	)


func _write_chip_buffer(slot: int, basis: Basis, position: Vector3, color: Color) -> void:
	# MultiMesh TRANSFORM_3D: tres filas vec4 seguidas por el color. Esto reemplaza cientos de
	# llamadas individuales a RenderingServer por una sola subida compacta al final del frame.
	var offset := slot * 16
	_instance_buffer[offset + 0] = basis.x.x
	_instance_buffer[offset + 1] = basis.y.x
	_instance_buffer[offset + 2] = basis.z.x
	_instance_buffer[offset + 3] = position.x
	_instance_buffer[offset + 4] = basis.x.y
	_instance_buffer[offset + 5] = basis.y.y
	_instance_buffer[offset + 6] = basis.z.y
	_instance_buffer[offset + 7] = position.y
	_instance_buffer[offset + 8] = basis.x.z
	_instance_buffer[offset + 9] = basis.y.z
	_instance_buffer[offset + 10] = basis.z.z
	_instance_buffer[offset + 11] = position.z
	_instance_buffer[offset + 12] = color.r
	_instance_buffer[offset + 13] = color.g
	_instance_buffer[offset + 14] = color.b
	_instance_buffer[offset + 15] = color.a
	_buffer_dirty = true


func _flush_chip_buffer() -> void:
	if _buffer_dirty and multimesh != null:
		multimesh.set_buffer(_instance_buffer)
		_buffer_dirty = false


func _track_gpu_batch(dust_count: int, spark_count: int) -> void:
	if dust_count > 0:
		_gpu_expiry_batches.append({
			"count": dust_count, "expires": Time.get_ticks_msec() + 1950,
		})
	if spark_count > 0:
		_gpu_expiry_batches.append({
			"count": spark_count, "expires": Time.get_ticks_msec() + 650,
		})


func _outward_direction(world_position: Vector3, center: Vector3) -> Vector3:
	var outward := world_position - center
	if outward.length_squared() < 0.0001:
		outward = _random_unit()
	return outward.normalized()


func _random_unit() -> Vector3:
	var vector := Vector3(
		_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.15, 1.0),
		_rng.randf_range(-1.0, 1.0)
	)
	return vector.normalized() if vector.length_squared() > 0.0001 else Vector3.UP


static func _spread_index(index: int, count: int, source_count: int) -> int:
	if count <= 1:
		return 0
	return mini(source_count - 1, (index * source_count) / count)
