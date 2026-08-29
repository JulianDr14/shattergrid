extends "res://tests/selftest/selftest.gd"
## Proyectil del cañón: cae como debe, no atraviesa nada por ir rápido, y detona DETRÁS del
## blindaje en vez de en su cara.

class Gunner:
	extends Node3D
	var camera: Camera3D
	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


func _run() -> void:
	print("proyectil del cañón")
	await _test_ballistics()
	await _test_penetration()
	await _test_tank_fires()
	quit(1 if failures > 0 else 0)


## Caída libre: sin nada que golpear, el proyectil describe una parábola. Se compara contra
## ½·g·t², que es la referencia analítica; el rozamiento solo puede restar, nunca sumar.
func _test_ballistics() -> void:
	var world := make_world()
	var start := Vector3(0.0, 50.0, 0.0)
	var muzzle := Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), start)
	var shell := Projectile.spawn(world, muzzle)
	_check(shell != null, "la ficha 'ap' existe y se instancia")
	if shell == null:
		world.queue_free()
		return
	_check_is_voxel_dart(shell)
	var elapsed := 0.0
	var step := 1.0 / Engine.physics_ticks_per_second
	for _frame in 30:
		await physics_frame
		elapsed += step
	_check(is_instance_valid(shell), "no detona en el aire")
	if not is_instance_valid(shell):
		world.queue_free()
		return
	var drop := start.y - shell.global_position.y
	var free_fall := 0.5 * Projectile.GRAVITY * elapsed * elapsed
	var travel := shell.global_position.x - start.x
	print("  t=%.3f s  avance=%.1f m  caída=%.3f m (libre %.3f m)" % [
		elapsed, travel, drop, free_fall
	])
	_check(drop > free_fall * 0.85 and drop <= free_fall * 1.01, "la caída es la de una parábola")
	# Con el rozamiento cuadrático la velocidad va como v0/(1+k·v0·t): siempre por debajo de la
	# balística en vacío, nunca por encima ni frenada hasta pararse.
	var vacuum: float = float(Projectile.AMMO.ap.speed) * elapsed
	_check(travel < vacuum and travel > vacuum * 0.9, "el rozamiento frena, pero no lo detiene")
	world.queue_free()
	await process_frame


## La bala es el modelo `.vox` de verdad, no una caja ni una tabla en el código: se comprueba que
## el asset carga, que sale entero en MultiMesh y que está orientado como un dardo -punta de un
## voxel a proa, aletas anchas a popa-. En headless el driver de vídeo es el mudo y no devuelve los
## transforms del MultiMesh, así que la silueta se mide en el modelo y el dibujado en las instancias.
func _check_is_voxel_dart(shell: Projectile) -> void:
	var asset := Projectile.model()
	_check(not asset.is_empty(), "el modelo .vox del proyectil carga")
	if asset.is_empty():
		return
	var data: VoxelShapeData = asset.shapes[0].data
	var dimensions := data.get_dimensions()
	var occupied := data.get_live_indices().size()
	var drawn := 0
	for child in shell.get_children():
		if child is MultiMeshInstance3D:
			drawn += (child as MultiMeshInstance3D).multimesh.instance_count
	var unit := float(Projectile.AMMO.ap.caliber) / float(Projectile.MODEL_BODY_VOXELS)
	print("  dardo: %s voxeles de %.3f m, %d ocupados, %d dibujados" % [
		dimensions, unit, occupied, drawn
	])
	_check(occupied > 100, "el dardo está hecho de voxeles, no de una caja suelta")
	_check(drawn == occupied, "se dibuja el modelo entero, acero y trazador")
	# El eje largo es el de la marcha: un dardo es mucho más largo que ancho.
	_check(dimensions.z > dimensions.x * 3, "el modelo es un dardo, no un ladrillo")
	_check(_slice_count(data, 0) == 1, "la punta afilada va a proa (-Z), que es hacia donde vuela")
	_check(
		_slice_count(data, dimensions.z - 1) > 1,
		"el culote es más ancho que la punta: ahí van aletas y trazador"
	)
	# La barra mide el calibre de la ficha: cinco voxeles de 24 mm son los 120 mm reales.
	_check(
		is_equal_approx(unit * Projectile.MODEL_BODY_VOXELS, float(Projectile.AMMO.ap.caliber)),
		"el grueso de la barra es el calibre"
	)


## Voxeles ocupados en la rodaja z del modelo.
func _slice_count(data: VoxelShapeData, z: int) -> int:
	var dimensions := data.get_dimensions()
	var count := 0
	for y in dimensions.y:
		for x in dimensions.x:
			if data.get_cell(x, y, z) != 0:
				count += 1
	return count


## Perforación: un muro de 40 cm a 30 m. A 420 m/s el proyectil recorre 7 m por paso de física, así
## que si el trazado no fuese por barrido lo atravesaría sin enterarse.
func _test_penetration() -> void:
	var world := make_world()
	var wall_x := 30.0
	var thickness := 0.4
	make_box_body(world, Vector3(thickness, 8.0, 8.0), Vector3(wall_x, 50.0, 0.0))
	var blasts: Array[Dictionary] = []
	world.explosion_started.connect(
		func(center: Vector3, radius: float, _energy: float) -> void:
			blasts.append({"center": center, "radius": radius})
	)
	var face := wall_x - thickness * 0.5
	var muzzle := Transform3D(
		Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(0.0, 50.0, 0.0)
	)
	var shell := Projectile.spawn(world, muzzle)
	for _frame in 20:
		await physics_frame
		if not blasts.is_empty():
			break
	_check(not blasts.is_empty(), "el muro para el proyectil: no lo atraviesa sin detonar")
	_check(not is_instance_valid(shell), "el proyectil se retira al detonar")
	if blasts.is_empty():
		world.queue_free()
		return
	var center: Vector3 = blasts[0].center
	var depth := center.x - face
	print("  cara del muro x=%.2f  carga en x=%.2f  (%.2f m dentro)" % [face, center.x, depth])
	# Lo que separa un AP de una granada: la carga revienta pasada la chapa, no contra ella.
	_check(depth > 0.5, "la carga detona detrás del blindaje, no en su cara")
	_check(depth <= float(Projectile.AMMO.ap.penetration) + 0.01, "no penetra más de su ficha")
	# La caída de la parábola no puede desviar el impacto del muro: a 30 m son centímetros.
	_check(absf(center.z) < 0.5 and absf(center.y - 50.0) < 1.0, "impacta donde apunta")
	world.queue_free()
	await process_frame


## Integración: el cañón del tanque suelta proyectil de verdad, y no se dispara a sí mismo pese a
## que el bocacho nace dentro de la envolvente de la torreta.
func _test_tank_fires() -> void:
	var world := make_world()
	make_box_body(world, Vector3(80, 1, 80), Vector3(0, -0.5, 0))
	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null, "el tanque se importa")
	if tank == null:
		world.queue_free()
		return
	for _frame in 90:
		await physics_frame
	var blasts := 0
	world.explosion_started.connect(
		func(_center: Vector3, _radius: float, _energy: float) -> void: blasts += 1
	)
	_check(tank.fire(), "el cañón dispara")
	await physics_frame
	var shells := 0
	for child in world.get_children():
		if child is Projectile:
			shells += 1
	_check(shells == 1, "el disparo pone un proyectil en el mundo")
	# Dos frames a 420 m/s son 14 m: si el rayo mordiese el propio carro, ya habría detonado.
	await physics_frame
	_check(blasts == 0, "el proyectil no detona sobre el tanque que lo dispara")
	world.queue_free()
	gunner.queue_free()
	await process_frame
