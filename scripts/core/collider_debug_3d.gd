class_name ColliderDebug3D
extends MeshInstance3D
## Dibuja en verde la malla de colision que hay delante de la mira. Si una mancha del suelo sale
## enrejada, ahi hay geometria con colision y lo que falla es el dibujado; si sale limpia, al reves.
##
## `debug_collisions_hint` no sirve para esto: el escenario estatico lleva una CollisionShape3D por
## macrocelda, casi un millon en el mapa entero, y pedirle a Godot el wireframe de todas cuelga el
## arranque. Se dibujan solo las que rodean al jugador, preguntandole a Jolt cuales son.

## Alcance del visor: es a la vez la distancia a la que se planta el cubo delante de la camara y su
## medio lado, asi que cubre desde los pies hasta el doble de esa distancia hacia donde se mira. Se
## dibuja la malla de triangulos real, cientos de vertices por forma, asi que va corto.
const REACH := 4.0

## Tope de vertices, para que un sitio muy poblado no congele el frame.
const MAX_VERTICES := 300_000

var _camera: Camera3D
var _exclude: Array[RID] = []
var _origin := Vector3.INF


func setup(camera: Camera3D, exclude: Array[RID]) -> void:
	_camera = camera
	_exclude = exclude


func _process(_delta: float) -> void:
	if _camera == null:
		return
	# El volumen va delante de la camara y no centrado en el jugador: lo que queda a la espalda no se
	# ve, y gastarlo ahi obliga a recortar el alcance justo donde si se esta mirando.
	var center := _camera.global_position - _camera.global_basis.z * REACH
	# Se rehace al moverse o al girar, que mueven el centro igual: reconstruir la malla en cada frame
	# cuesta bastante mas que la consulta.
	if _origin.distance_to(center) < 1.0:
		return
	_origin = center
	var query := PhysicsShapeQueryParameters3D.new()
	var region := BoxShape3D.new()
	region.size = Vector3.ONE * REACH * 2.0
	query.shape = region
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.exclude = _exclude
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 1.0, 0.35)
	var vertices := PackedVector3Array()
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 4096):
		var collider := hit.collider as CollisionObject3D
		if collider == null:
			continue
		var node := collider.shape_owner_get_owner(collider.shape_find_owner(int(hit.shape)))
		var collision := node as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		# El escenario estatico no son cajas sino una malla de triangulos por macrocelda, asi que
		# filtrar por BoxShape3D dejaba el visor vacio. Se dibuja el contorno real y no su caja
		# envolvente: la caja de una malla irregular no dice donde esta la superficie, que es
		# justamente lo que hay que comparar contra lo que se ve.
		var outline: ArrayMesh = collision.shape.get_debug_mesh()
		if outline.get_surface_count() == 0:
			continue
		var transform := collision.global_transform
		for point: Vector3 in outline.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			vertices.append(transform * point)
		if vertices.size() >= MAX_VERTICES:
			break
	if vertices.is_empty():
		mesh = null
		return
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for point in vertices:
		immediate.surface_add_vertex(point)
	immediate.surface_end()
	mesh = immediate
