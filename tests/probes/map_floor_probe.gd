extends SceneTree
## Que superficies pisables no llegan a Jolt.
##
## Busca voxeles con aire justo encima — o sea, sitios donde se puede poner un pie — y tira un rayo
## corto de arriba abajo sobre cada uno. Si el rayo no encuentra nada, esa superficie se dibuja pero
## no se pisa. El fallo se agrupa por material para saber a quien culpar.

var MAP := VoxelProjectPaths.teardown_map_path()
const MUESTRAS_POR_SHAPE := 6


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	for _frame in 4:
		await physics_frame

	var space := root.world_3d.direct_space_state
	var fallos := {}
	var totales := {}
	var ejemplos := {}
	var perdidos := {}
	var desfases := {}
	var sin_bloque := {}
	var bloques := {}
	var grosores := {}
	var bloques_ok := {}
	var grosores_ok := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for body in world.get_children():
		# Los Bodies con `collide="false"` no deben colisionar: mezclarlos aqui solo ensucia.
		if not (body is VoxelBody3D) or body.get_physics_body() is RigidBody3D \
				or not (body as VoxelBody3D).collision_enabled:
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			if shape.data == null:
				continue
			var cells := shape.data.get_dimensions()
			var origin := -Vector3(cells) * shape.voxel_size * 0.5
			var to_world := (body as Node3D).global_transform * shape.transform
			var encontrados := 0
			for _try in 220:
				if encontrados >= MUESTRAS_POR_SHAPE:
					break
				var x := rng.randi_range(0, cells.x - 1)
				var z := rng.randi_range(0, cells.z - 1)
				var y := rng.randi_range(0, cells.y - 2)
				var index := shape.data.get_cell(x, y, z)
				if index == 0 or shape.data.get_cell(x, y + 1, z) != 0:
					continue
				encontrados += 1
				var top := to_world * (origin + Vector3(
					float(x) + 0.5, float(y) + 1.0, float(z) + 0.5
				) * shape.voxel_size)
				var material := TeardownPalette.material_name(index)
				totales[material] = int(totales.get(material, 0)) + 1
				var block_ok := VoxelBody3D.collision_block_for(shape)
				bloques_ok[block_ok] = int(bloques_ok.get(block_ok, 0)) + 1
				var grosor_ok := mini(cells.x, mini(cells.y, cells.z))
				var clase_ok := "lamina<=2" if grosor_ok <= 2 \
					else ("fina<=8" if grosor_ok <= 8 else "gorda")
				grosores_ok[clase_ok] = int(grosores_ok.get(clase_ok, 0)) + 1
				var query := PhysicsRayQueryParameters3D.create(
					top + Vector3.UP * 0.4, top - Vector3.UP * 0.25
				)
				if space.intersect_ray(query).is_empty():
					fallos[material] = int(fallos.get(material, 0)) + 1
					# Si el rayo largo si acierta, la colision existe pero esta desplazada; el
					# desfase dice cuanto y hacia donde.
					var largo := PhysicsRayQueryParameters3D.create(
						top + Vector3.UP * 3.0, top - Vector3.UP * 3.0
					)
					var hit := space.intersect_ray(largo)
					if hit.is_empty():
						perdidos[material] = int(perdidos.get(material, 0)) + 1
					else:
						var desfase: float = hit.position.y - top.y
						desfases[material] = float(desfases.get(material, 0.0)) + desfase
					# Existe siquiera el bloque de colision que deberia cubrir este voxel?
					var block := VoxelBody3D.collision_block_for(shape)
					var macro_dim := shape.data.get_macro_dimensions()
					var key := "%d:%d:%d:%d" % [shape.get_instance_id(),
						(x / 8) / block, (y / 8) / block, (z / 8) / block]
					if not (body as VoxelBody3D)._macro_collisions.has(key):
						sin_bloque[material] = int(sin_bloque.get(material, 0)) + 1
					bloques[block] = int(bloques.get(block, 0)) + 1
					var grosor := mini(cells.x, mini(cells.y, cells.z))
					var clase := "lamina<=2" if grosor <= 2 else ("fina<=8" if grosor <= 8 else "gorda")
					grosores[clase] = int(grosores.get(clase, 0)) + 1
					if not ejemplos.has(material):
						ejemplos[material] = "%s  %s  hit=%s" % [body.name, top,
							"nada" if hit.is_empty() else str(hit.position)]

	print("\nsuperficies pisables que NO colisionan, por material")
	for material in totales:
		var fallo: int = fallos.get(material, 0)
		var total: int = totales[material]
		var perdido: int = perdidos.get(material, 0)
		var desplazado := fallo - perdido
		var desfase_medio := 0.0 if desplazado == 0 \
			else float(desfases.get(material, 0.0)) / float(desplazado)
		print("  %-12s %5d/%-5d fallan (%4.1f %%)  sin nada=%d  desplazados=%d (media %+0.2f m)"
			% [material, fallo, total, 100.0 * float(fallo) / float(total),
			perdido, desplazado, desfase_medio])
		print("      sin bloque de colision: %d   ej: %s"
			% [int(sin_bloque.get(material, 0)), ejemplos.get(material, "")])
	print("\nfallos por tamano de bloque: ", bloques, "  de un total de ", bloques_ok)
	print("fallos por grosor de la Shape: ", grosores, "  de un total de ", grosores_ok)
	quit()
