class_name Explosion
## Reparte una onda expansiva entre todo lo que puede notarla.
##
## La explosión no pertenece al edificio que se tiene delante: en el pueblo del original, una bomba
## entre dos casas tenía que morder a las dos. Aquí es un barrido por el grupo, que con unos pocos
## edificios sale más barato que montar un `Area3D`.

static func at(node: Node, center: Vector3, radius: float, energy: float) -> void:
	var tree := node.get_tree()
	var worlds := tree.get_nodes_in_group(VoxelWorld3D.GROUP)
	for world: VoxelWorld3D in worlds:
		world.damage_sphere(center, radius, energy)
