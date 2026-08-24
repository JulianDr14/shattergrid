class_name VoxelRopes
extends MeshInstance3D
## Los tendidos del mapa como cables de verdad: cadena de puntos con integracion de Verlet y
## restricciones de distancia, dibujada como cinta orientada a la camara.
##
## Es el modelo de Teardown. Su API expone `GetRopeNumberOfPoints` y `GetRopePointPosition`, o sea
## que un cable suyo es una cadena de puntos simulados, y el desmontaje grafico del juego describe
## los cables como "billboarded triangle lists" pintadas despues de la geometria solida. En Godot la
## alternativa -una cadena de `RigidBody3D` con juntas- es justo la que hunde los fps; Verlet es lo
## que usan las implementaciones que aguantan.
##
## El rendimiento sale de no simular nada parado. Los 79 tendidos de Lee vienen tensos (`slack` es
## -0,15 en todos), asi que se duermen en cuanto se asientan y a partir de ahi cuestan cero: ni
## simulacion ni reconstruccion de malla. Solo despiertan cuando una explosion les pasa cerca.

## Puntos por tramo. Ocho eran los que ya usaba la linea plana y sobran para un cable tenso.
const SEGMENTS := 8
## Iteraciones de restriccion por frame. Cada una propaga la tension un segmento, asi que con pocas
## el cable se porta como un muelle: con dos descolgaba 39 cm y con seis 12 cm, que ya es descuelgue
## de cable de verdad. Mas no bajan de ahi — con `slack` negativo el sistema es infactible a proposito
## (ocho segmentos de 0,73 m no cubren 6 m), asi que el reposo es un compromiso entre estirar y
## colgar, igual que un cable real bajo tension. Alternar el sentido del barrido se probo y no aporta.
const ITERATIONS := 6
const GRAVITY := 9.8
## Rozamiento exponencial por segundo. Un tendido sujeto por ambos extremos necesita bastante
## amortiguación para asentarse, pero aplicársela también a un extremo recién roto limitaba su
## caída a unos 2,7 m/s: parecía una cinta de papel. El cable suelto conserva casi toda su velocidad
## y acelera con gravedad; el que sigue formando un vano se amortigua como antes.
const PINNED_DRAG_PER_SECOND := 3.7
const LOOSE_DRAG_PER_SECOND := 0.28
## Por debajo de esto en un frame se considera quieto.
const SLEEP_EPSILON := 0.0015
## Frames quietos seguidos antes de dormirlo.
const SLEEP_FRAMES := 20
## Margen visual alrededor del radio destructivo. Antes se usaban 60 m y `blast_radius * 6`, por
## lo que volar la base de una torre despertaba tendidos de media Lee: cientos de raycasts por
## physics tick justo durante el colapso. Se mide contra el segmento real, no contra su centro.
const WAKE_PADDING := 1.5

## Tension. `<rope>` de Teardown lleva `slack`, `strength` y `maxstretch`: holgura, fuerza que aguanta
## y estiramiento maximo antes de reventar. Lee no los escribe, asi que estos son los de por defecto
## y son la perilla para afinarlos.
##
## La longitud de reposo NO sale de `slack`: los 79 tendidos vienen con -0,15, o sea ya pretensados,
## y usar eso dejaria a los props tirados por un cable que nunca afloja. Se toma la separacion que
## tenian los anclajes al importar, que es la postura de equilibrio del mapa.
const STIFFNESS := 20_000.0
## `strength` del XML es una escala, no decoración. Un cable authored normal aguanta 10 kN; los
## cuatro tirantes cortos de Lee que escriben `strength="5"` aguantan cinco veces eso y el cable
## industrial `strength="100"` conserva su intención. Antes todos recibían 80 kN y ocho líneas
## eléctricas podían dejar una torre suspendida indefinidamente.
const FORCE_PER_STRENGTH := 10_000.0
const DEFAULT_STRENGTH := 1.0
const TENSION_DAMPING := 2_000.0
## Zona muerta de la tension. Sin ella, un prop que se asienta dos milimetros estira el cable, el
## cable tira y lo despierta, y el prop no se duerme nunca: bucle de dos cuerpos por tendido.
const TENSION_SLACK := 0.02
## `maxstretch` es distancia adicional antes de romper. Lee no la escribe, así que el límite normal
## evita que un tendido de decenas de metros se convierta en una goma capaz de sostener una torre
## varios metros por debajo de sus anclajes.
const DEFAULT_MAX_STRETCH := 0.75
## Tope de aceleracion que un cable puede imprimir a un cuerpo. Un muelle de 20 kN/m sobre una caja
## de un kilo es inestable a 60 Hz y la manda al espacio; el tope lo acota sin tocar la rigidez, que
## es la que hace que una torre de 24 toneladas note el tiron.
const MAX_ACCELERATION := 400.0
## Radio en el que se busca material para dar un anclaje por destruido.
const ANCHOR_RADIUS := 0.6
## Separacion que se deja al apoyar un punto sobre una superficie, y cuanta velocidad tangencial
## conserva al rozar contra ella.
const COLLISION_SKIN := 0.05
const COLLISION_FRICTION := 0.5
## Donde se aparcan los vertices de un tramo que ya no existe.
const DEAD_POINT := Vector3(0.0, -10_000.0, 0.0)

## Un tramo: puntos consecutivos en los buffers planos, con los dos extremos clavados.
var _spans: Array[Dictionary] = []
var _points := PackedVector3Array()
var _previous := PackedVector3Array()
var _mesh := ArrayMesh.new()
## Lo que no cambia nunca se construye una vez: los indices y el lado de la cinta. Solo se reescriben
## posicion y tangente, y en sitio, sin volver a hacer crecer los arrays cada frame.
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _arrays := []
var _dirty := false
var _awake := 0
## Diagnostico: tramos que estan tirando de algun cuerpo ahora mismo.
var pulling := 0


func _ready() -> void:
	mesh = _mesh
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load("res://shaders/rope.gdshader")
	material_override = shader_material
	# La malla va en coordenadas de mundo: el shader cuenta con ello para orientar la cinta sin
	# invertir la matriz del modelo en cada vertice.
	global_transform = Transform3D.IDENTITY
	set_physics_process(false)


## Añade un tramo entre dos anclajes. `slack` es la longitud sobrante en metros, como en el XML de
## Teardown: negativa quiere decir que el cable es mas corto que el hueco, o sea tenso.
func add_span(
	from: Vector3, to: Vector3, slack: float,
	body_a: VoxelBody3D = null, body_b: VoxelBody3D = null,
	strength := DEFAULT_STRENGTH, max_stretch := DEFAULT_MAX_STRETCH
) -> void:
	var start := _points.size()
	for step in SEGMENTS + 1:
		var point := from.lerp(to, float(step) / float(SEGMENTS))
		_points.append(point)
		_previous.append(point)
	var separation := from.distance_to(to)
	var length := maxf(separation + slack, 0.01)
	var hold_key := "rope:%d:%d" % [get_instance_id(), start]
	_spans.append({
		"start": start,
		"count": SEGMENTS + 1,
		"rest": length / float(SEGMENTS),
		"center": (from + to) * 0.5,
		"reach": separation * 0.5 + 1.0,
		"still": 0,
		"awake": true,
		# Los extremos: a que cuerpo estan clavados y en que sitio de ese cuerpo. Un extremo sin
		# cuerpo se queda clavado al mundo, como antes.
		"body_a": body_a,
		"body_b": body_b,
		"local_a": _to_local(body_a, from),
		"local_b": _to_local(body_b, to),
		"pin_a": true,
		"pin_b": true,
		"span_rest": maxf(separation, 0.01),
		"strength": maxf(float(strength), 0.01),
		"max_stretch": maxf(float(max_stretch), 0.01),
		"dead": false,
		"physics_hold_key_a": hold_key + ":a",
		"physics_hold_key_b": hold_key + ":b",
	})
	for side in ["a", "b"]:
		var body := body_a if side == "a" else body_b
		if body != null:
			body.acquire_physics_hold(hold_key + ":" + side)
	# Durante importación el nodo aún no está en el árbol y `settle()` inicializa el contador de una
	# vez. Un cable creado en gameplay, en cambio, tiene que empezar a simular inmediatamente.
	if is_inside_tree():
		_awake += 1
		set_physics_process(true)
	_dirty = true


static func _to_local(body: VoxelBody3D, world_point: Vector3) -> Vector3:
	if body == null:
		return world_point
	var physics := body.get_physics_body()
	return world_point if physics == null \
		else physics.global_transform.affine_inverse() * world_point


static func _anchor_world(body: VoxelBody3D, local: Vector3) -> Vector3:
	if body == null or not is_instance_valid(body):
		return local
	var physics := body.get_physics_body()
	return local if physics == null else physics.global_transform * local


## Se llama una vez al terminar de importar. Deja los cables asentados en su forma de reposo antes
## del primer frame para que nadie vea la caida inicial.
func settle() -> void:
	if _spans.is_empty():
		return
	set_physics_process(true)
	_awake = _spans.size()
	# Dos segundos y medio de simulacion: lo que tarda un cable con holgura en dejar de caer. Se paga
	# una vez, al importar, y evita que el jugador vea los tendidos desplomandose al entrar.
	for _step in 150:
		_simulate(1.0 / 60.0)
	# `settle` define explícitamente la postura inicial. Algunos vanos pretensados conservan una
	# corrección submilimétrica imposible de llevar por debajo del epsilon y dejaban 12 de los 79
	# cables de Lee simulándose para siempre. Se estacionan aquí; mover un anclaje o un impacto los
	# despierta por las rutas normales.
	_awake = 0
	for span in _spans:
		if bool(span.dead):
			continue
		span.awake = false
		span.still = SLEEP_FRAMES
		for index in range(int(span.start), int(span.start) + int(span.count)):
			_previous[index] = _points[index]
	_rebuild()


func setup(world: VoxelWorld3D) -> void:
	world.body_split.connect(_on_body_split)
	world.body_unregistered.connect(_on_body_unregistered)
	world.voxel_impact.connect(
		func(center: Vector3, _removed: int, blast_radius: float) -> void:
			on_impact(center, blast_radius)
	)


func _physics_process(delta: float) -> void:
	_follow_anchors()
	if _awake > 0:
		_simulate(delta)
		_collide()
		_apply_tension()
	if _dirty:
		_rebuild()


## Cuando un cuerpo se parte, o se absorbe en otro al caer, el extremo del cable se va con el trozo
## que se quedo el material del anclaje. Sin esto, unir dos cuerpos en uno dejaba el cable clavado a
## un cuerpo que ya no existe y el tendido se quedaba en el aire.
func _on_body_split(source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	if source == null:
		return
	for span in _spans:
		for side in ["a", "b"]:
			if span["body_" + side] != source or not bool(span["pin_" + side]):
				continue
			var index := int(span.start) + (0 if side == "a" else int(span.count) - 1)
			var at := _points[index]
			if VoxelDoor3D._body_has_material_near(source, at, ANCHOR_RADIUS):
				continue
			for candidate in created:
				if not VoxelDoor3D._body_has_material_near(candidate, at, ANCHOR_RADIUS):
					continue
				var hold_key := String(span.get("physics_hold_key_" + side, ""))
				source.release_physics_hold(hold_key)
				candidate.acquire_physics_hold(hold_key)
				span["body_" + side] = candidate
				span["local_" + side] = _to_local(candidate, at)
				break


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body == null:
		return
	for span in _spans:
		for side in ["a", "b"]:
			if span["body_" + side] == body:
				release_anchor(span, side)


## Los puntos libres chocan con el mundo. Solo los tramos despiertos: uno quieto ya esta donde tiene
## que estar, asi que en reposo esto cuesta cero. Se excluyen los cuerpos de los que cuelga el propio
## cable, que si no se aparta el mismo de su poste.
func _collide() -> void:
	var world_3d := get_world_3d()
	if world_3d == null:
		return
	var space := world_3d.direct_space_state
	if space == null:
		return
	for span in _spans:
		if not bool(span.awake) or bool(span.dead):
			continue
		var start := int(span.start)
		var last := start + int(span.count) - 1
		var exclude: Array[RID] = []
		for side in ["a", "b"]:
			var anchor_body := span["body_" + side] as VoxelBody3D
			if anchor_body != null and is_instance_valid(anchor_body):
				exclude.append_array(anchor_body.get_collision_rids())
		for index in range(start, last + 1):
			if (index == start and bool(span.pin_a)) or (index == last and bool(span.pin_b)):
				continue
			var from: Vector3 = _previous[index]
			var to: Vector3 = _points[index]
			if from.distance_squared_to(to) < 0.000001:
				continue
			var query := PhysicsRayQueryParameters3D.create(from, to)
			query.exclude = exclude
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				continue
			var normal: Vector3 = hit.normal
			var landed: Vector3 = (hit.position as Vector3) + normal * COLLISION_SKIN
			var velocity := landed - from
			_points[index] = landed
			# Se queda la velocidad que va a lo largo de la superficie, no la que la atraviesa.
			_previous[index] = landed - (velocity - normal * velocity.dot(normal)) \
				* COLLISION_FRICTION


## Los extremos clavados a un cuerpo van donde vaya el cuerpo. Es lo que convierte el tendido en una
## conexion y no en decorado: si el poste cae, el cable baja con el.
func _follow_anchors() -> void:
	for span in _spans:
		if bool(span.dead):
			continue
		# El mapa quieto no necesita transformar 711 puntos por tick. Un tramo dormido solo puede
		# cambiar si alguno de sus endpoints es un RigidBody despierto; los impactos y splits lo
		# despiertan explícitamente antes de llegar aquí.
		if not bool(span.awake) and not _body_can_move_now(span.body_a) \
				and not _body_can_move_now(span.body_b):
			continue
		if bool(span.pin_a) and bool(span.pin_b) and span.body_a != null \
				and span.body_a == span.body_b:
			_follow_same_body_span(span)
			continue
		span.erase("same_body_locals")
		span.erase("same_body_generation")
		var start := int(span.start)
		var last := start + int(span.count) - 1
		var moved := false
		if bool(span.pin_a) and span.body_a != null:
			moved = _move_anchor(start, _anchor_world(span.body_a, span.local_a)) or moved
		if bool(span.pin_b) and span.body_b != null:
			moved = _move_anchor(last, _anchor_world(span.body_b, span.local_b)) or moved
		if not moved:
			continue
		span.center = (_points[start] + _points[last]) * 0.5
		if not bool(span.awake):
			span.awake = true
			span.still = 0
			_awake += 1


## Si los dos extremos acabaron en la misma pieza rígida, todos los puntos viajan con su
## transformada. No hay cuerda que resolver ni raycasts que hacer: simularla como resorte interno
## era precisamente la fuente de la oscilación de la torre.
func _follow_same_body_span(span: Dictionary) -> void:
	var body := span.body_a as VoxelBody3D
	if body == null or not is_instance_valid(body):
		return
	var physics := body.get_physics_body()
	if physics == null:
		return
	var start := int(span.start)
	var count := int(span.count)
	var locals: PackedVector3Array = span.get("same_body_locals", PackedVector3Array())
	if locals.size() != count \
			or int(span.get("same_body_generation", -1)) != body.physics_generation:
		locals = PackedVector3Array()
		var inverse := physics.global_transform.affine_inverse()
		for index in range(start, start + count):
			locals.append(inverse * _points[index])
		span.same_body_locals = locals
		span.same_body_generation = body.physics_generation
	var moved := false
	for step in count:
		var index := start + step
		var target := physics.global_transform * locals[step]
		moved = moved or _points[index].distance_squared_to(target) > 0.000001
		_points[index] = target
		_previous[index] = target
	span.center = (_points[start] + _points[start + count - 1]) * 0.5
	if bool(span.awake):
		span.awake = false
		_awake = maxi(0, _awake - 1)
	if moved:
		_dirty = true


func _move_anchor(index: int, target: Vector3) -> bool:
	if _points[index].distance_squared_to(target) < 0.000001:
		return false
	_points[index] = target
	_previous[index] = target
	return true


static func _body_can_move_now(candidate: Variant) -> bool:
	var body := candidate as VoxelBody3D
	return body != null and is_instance_valid(body) and body.state == VoxelBody3D.State.DYNAMIC \
		and body.is_awake()


## El cable tira de los dos cuerpos a los que esta clavado, y revienta si le piden mas estiramiento
## del que aguanta. Sin esto la torre caia y el tendido ni se enteraba.
func _apply_tension() -> void:
	pulling = 0
	for span in _spans:
		if bool(span.dead) or not bool(span.awake):
			continue
		var start := int(span.start)
		var last := start + int(span.count) - 1
		# Después de un split/coalesce los dos anclajes pueden terminar en el mismo RigidBody. La
		# cuerda pasa a ser detalle interno de una pieza rígida: aplicarle dos fuerzas opuestas no
		# puede deformarla, solo inyecta torque y mantiene la torre oscilando para siempre.
		if bool(span.pin_a) and bool(span.pin_b) \
				and span.body_a != null and span.body_a == span.body_b:
			continue
		var a := _points[start]
		var b := _points[last]
		var separation := a.distance_to(b)
		var rest := float(span.span_rest)
		if separation <= rest + TENSION_SLACK:
			continue
		var extension := separation - rest
		if extension > float(span.max_stretch):
			_break_span(span)
			continue
		var direction := (b - a) / separation
		# Amortiguacion sobre la velocidad con la que se separan: un cable de acero no rebota, y sin
		# esto la torre colgada se pone a oscilar y no para.
		var separating := (_velocity(span.body_b) - _velocity(span.body_a)).dot(direction)
		var elastic_tension := extension * STIFFNESS
		var breaking_force := float(span.strength) * FORCE_PER_STRENGTH
		# El amortiguador estabiliza la cuerda, pero no representa carga estructural:
		# un pico de velocidad al despertar un Body no debe romper un cable flojo.
		if elastic_tension >= breaking_force:
			_break_span(span)
			continue
		var magnitude := clampf(
			elastic_tension + separating * TENSION_DAMPING,
			0.0,
			breaking_force
		)
		pulling += 1
		_pull(span.body_a as VoxelBody3D, bool(span.pin_a), a, direction * magnitude)
		_pull(span.body_b as VoxelBody3D, bool(span.pin_b), b, -direction * magnitude)


## Se suelta el extremo que estaba tirando, no los dos: el cable queda colgando del anclaje que
## aguanta, que es lo que se ve cuando una linea revienta. Si tampoco queda ese, el tramo desaparece.
func _break_span(span: Dictionary) -> void:
	var pulling_a := _is_dynamic(span.body_a) and bool(span.pin_a)
	release_anchor(span, "a" if pulling_a else "b")


func release_anchor(span: Dictionary, side: String) -> void:
	var pin := "pin_" + side
	if not bool(span[pin]):
		return
	var body_key := "body_" + side
	var anchor_body := span.get(body_key) as VoxelBody3D
	if anchor_body != null and is_instance_valid(anchor_body):
		anchor_body.release_physics_hold(span.get("physics_hold_key_" + side, ""))
	span[body_key] = null
	span[pin] = false
	span.still = 0
	if not bool(span.awake):
		span.awake = true
		_awake += 1
	if bool(span.pin_a) or bool(span.pin_b):
		return
	# Sin ningun anclaje no hay de que colgar: caeria para siempre porque un cable no colisiona con
	# nada. Se retira del tendido.
	span.dead = true
	span.awake = false
	_awake -= 1
	_dirty = true


static func _is_dynamic(body: Variant) -> bool:
	var voxel_body := body as VoxelBody3D
	return voxel_body != null and is_instance_valid(voxel_body) \
		and voxel_body.state == VoxelBody3D.State.DYNAMIC


static func _velocity(body: Variant) -> Vector3:
	var voxel_body := body as VoxelBody3D
	if voxel_body == null or not is_instance_valid(voxel_body):
		return Vector3.ZERO
	var rigid := voxel_body.get_physics_body() as RigidBody3D
	return Vector3.ZERO if rigid == null else rigid.linear_velocity


static func _pull(body: VoxelBody3D, pinned: bool, at: Vector3, force: Vector3) -> void:
	if not pinned or body == null or not is_instance_valid(body):
		return
	var rigid := body.get_physics_body() as RigidBody3D
	if rigid == null:
		return
	var limit := rigid.mass * MAX_ACCELERATION
	if force.length_squared() > limit * limit:
		force = force.normalized() * limit
	rigid.apply_force(force, at - rigid.global_position)
	# `apply_force` despierta el RigidBody por sí solo. Llamar `wake_for_interaction` en cada tick
	# renovaba eternamente el timestamp del presupuesto aunque la cuerda apenas tirase.


func on_impact(center: Vector3, blast_radius: float) -> void:
	for span in _spans:
		if bool(span.dead):
			continue
		var start := int(span.start)
		var last := start + int(span.count) - 1
		if _distance_to_segment(center, _points[start], _points[last]) \
				> blast_radius + WAKE_PADDING:
			continue
		# Un anclaje sin voxeles alrededor ya no sujeta nada. Es la misma regla que rompe los joints:
		# solo se suelta lo que la destruccion se ha llevado de verdad.
		if bool(span.pin_a) and span.body_a != null \
				and not VoxelDoor3D._body_has_material_near(
					span.body_a, _points[int(span.start)], ANCHOR_RADIUS):
			release_anchor(span, "a")
		if bool(span.pin_b) and span.body_b != null \
				and not VoxelDoor3D._body_has_material_near(
					span.body_b, _points[int(span.start) + int(span.count) - 1], ANCHOR_RADIUS):
			release_anchor(span, "b")
		if bool(span.awake) or bool(span.dead):
			continue
		span.awake = true
		span.still = 0
		_awake += 1
		# Un empujon en la direccion de la onda, para que se note el latigazo y no solo la caida.
		var push: Vector3 = ((span.center as Vector3) - center).normalized() * blast_radius * 0.35
		for index in range(int(span.start) + 1, int(span.start) + int(span.count) - 1):
			_previous[index] -= push


static func _distance_to_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(a)
	var fraction := clampf((point - a).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(a + segment * fraction)


func _simulate(delta: float) -> void:
	var fall := GRAVITY * delta * delta
	for span in _spans:
		if not bool(span.awake) or bool(span.dead):
			continue
		var start := int(span.start)
		var last := start + int(span.count) - 1
		var pin_low := bool(span.pin_a)
		var pin_high := bool(span.pin_b)
		var drag_per_second := PINNED_DRAG_PER_SECOND if pin_low and pin_high \
			else LOOSE_DRAG_PER_SECOND
		var damping := exp(-drag_per_second * delta)
		var moved := 0.0
		for index in range(start, last + 1):
			if (index == start and pin_low) or (index == last and pin_high):
				continue
			var current := _points[index]
			var step := (current - _previous[index]) * damping
			_previous[index] = current
			_points[index] = current + step - Vector3(0.0, fall, 0.0)
			moved = maxf(moved, step.length())
		var rest := float(span.rest)
		for _iteration in ITERATIONS:
			for index in range(start, last):
				var delta_vector := _points[index + 1] - _points[index]
				var distance := delta_vector.length()
				if distance < 0.000001:
					continue
				# Un extremo clavado no se mueve: toda la correccion se la come el punto libre.
				var free_low := index > start or not pin_low
				var free_high := index + 1 < last or not pin_high
				if not free_low and not free_high:
					continue
				var correction := delta_vector * ((distance - rest) / distance)
				if free_low and free_high:
					_points[index] += correction * 0.5
					_points[index + 1] -= correction * 0.5
				elif free_low:
					_points[index] += correction
				else:
					_points[index + 1] -= correction
		if moved < SLEEP_EPSILON:
			span.still = int(span.still) + 1
			if int(span.still) >= SLEEP_FRAMES:
				span.awake = false
				_awake -= 1
		else:
			span.still = 0
	_dirty = true


## Dos vertices por punto. `NORMAL` lleva la tangente y `UV.x` el lado de la cinta; el ensanchado lo
## hace el shader, asi que girar la camara no cuesta nada.
func _rebuild() -> void:
	_dirty = false
	if _points.is_empty():
		return
	if _vertices.size() != _points.size() * 2:
		_prepare_arrays()
	for span in _spans:
		var start := int(span.start)
		var count := int(span.count)
		if bool(span.dead):
			# Triangulos degenerados y bien lejos: el tramo deja de verse sin tocar los indices.
			for step in count:
				_vertices[(start + step) * 2] = DEAD_POINT
				_vertices[(start + step) * 2 + 1] = DEAD_POINT
			continue
		for step in count:
			var index := start + step
			var ahead: Vector3 = _points[mini(index + 1, start + count - 1)]
			var behind: Vector3 = _points[maxi(index - 1, start)]
			var tangent := ahead - behind
			tangent = tangent.normalized() if tangent.length_squared() > 0.000001 else Vector3.UP
			var vertex := index * 2
			var position := _points[index]
			_vertices[vertex] = position
			_vertices[vertex + 1] = position
			_normals[vertex] = tangent
			_normals[vertex + 1] = tangent
	_arrays[Mesh.ARRAY_VERTEX] = _vertices
	_arrays[Mesh.ARRAY_NORMAL] = _normals
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)


## Dos vertices por punto, uno por lado de la cinta. El ancho lo pone el shader, asi que girar la
## camara no toca la malla.
func _prepare_arrays() -> void:
	_vertices.resize(_points.size() * 2)
	_normals.resize(_points.size() * 2)
	_uvs.resize(_points.size() * 2)
	_indices.clear()
	for span in _spans:
		var start := int(span.start)
		var count := int(span.count)
		for step in count:
			var vertex := (start + step) * 2
			var ratio := float(step) / float(count - 1)
			_uvs[vertex] = Vector2(0.0, ratio)
			_uvs[vertex + 1] = Vector2(1.0, ratio)
		for step in count - 1:
			var quad := (start + step) * 2
			_indices.append_array([quad, quad + 1, quad + 2, quad + 1, quad + 3, quad + 2])
	_arrays = []
	_arrays.resize(Mesh.ARRAY_MAX)
	_arrays[Mesh.ARRAY_TEX_UV] = _uvs
	_arrays[Mesh.ARRAY_INDEX] = _indices


func span_count() -> int:
	return _spans.size()


func awake_count() -> int:
	return _awake


## Resumen barato para probes/overlay. Distingue un cable externo que todavía está cayendo de un
## vano cuyos dos extremos pertenecen al mismo sólido; solo el segundo sería una incoherencia si
## siguiera entrando al solver.
func get_diagnostics() -> Dictionary:
	var same_body_awake := 0
	var loose_awake := 0
	var external_awake := 0
	for span in _spans:
		if bool(span.dead) or not bool(span.awake):
			continue
		if not bool(span.pin_a) or not bool(span.pin_b):
			loose_awake += 1
		elif span.body_a != null and span.body_a == span.body_b:
			same_body_awake += 1
		else:
			external_awake += 1
	return {
		"awake": _awake,
		"same_body_awake": same_body_awake,
		"loose_awake": loose_awake,
		"external_awake": external_awake,
		"pulling": pulling,
	}


## Extremos que salieron enganchados a un cuerpo. Los que no, se quedan clavados al mundo.
func bound_ends() -> int:
	var bound := 0
	for span in _spans:
		bound += 1 if span.body_a != null else 0
		bound += 1 if span.body_b != null else 0
	return bound


## Si ese extremo salio enganchado a un cuerpo.
func has_body(span_index: int, side: String) -> bool:
	return _spans[span_index]["body_" + side] != null


## Extremos clavados a un cuerpo que ya no existe. Deberia ser siempre cero: si sube, algo esta
## liberando cuerpos sin avisar al tendido.
func orphan_ends(span_index: int) -> int:
	var span := _spans[span_index]
	var orphans := 0
	for side in ["a", "b"]:
		var body = span["body_" + side]
		if bool(span["pin_" + side]) and body != null and not is_instance_valid(body):
			orphans += 1
	return orphans


## Si ese extremo del tramo sigue clavado a su anclaje. Para las sondas y los tests.
func anchor_pinned(span_index: int, side: String) -> bool:
	return bool(_spans[span_index]["pin_" + side])


## Tramos con al menos un extremo clavado a un cuerpo, o sea cables que son conexion y no decorado.
func attached_count() -> int:
	var attached := 0
	for span in _spans:
		if span.body_a != null or span.body_b != null:
			attached += 1
	return attached


## La posicion de un punto de un tramo, para las sondas y los tests.
func point(span_index: int, step: int) -> Vector3:
	var span: Dictionary = _spans[span_index]
	return _points[int(span.start) + clampi(step, 0, int(span.count) - 1)]


func maximum_separation(span_index: int) -> float:
	var span: Dictionary = _spans[span_index]
	return float(span.span_rest) + float(span.max_stretch)
