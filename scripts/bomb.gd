class_name Bomb
extends RigidBody3D
## Carga que se lanza y revienta al primer contacto, o sola pasado el fusible.

var radius := 2.3
var energy := 12.0

## Segundos antes de reventar si no toca nada. Sin él, una bomba lanzada al vacío se queda cayendo
## para siempre y sigue costando broadphase.
const FUSE := 4.0

var _spent := false


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 1
	mass = 8.0

	var view := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.18
	ball.height = 0.36
	view.mesh = ball
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.1, 0.1, 0.12)
	paint.emission_enabled = true
	paint.emission = Color(0.9, 0.25, 0.1)
	paint.emission_energy_multiplier = 1.5
	view.material_override = paint
	add_child(view)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.18
	shape.shape = sphere
	add_child(shape)

	body_entered.connect(_on_touch)
	get_tree().create_timer(FUSE).timeout.connect(_detonate)


func _on_touch(_body: Node) -> void:
	# `body_entered` llega dentro del paso de física, y ahí no se puede sacar un cuerpo del árbol:
	# Jolt está recorriendo su propia lista. Se marca gastada ya —para que dos contactos del mismo
	# paso no la detonen dos veces— y el resto se hace al salir.
	if _spent:
		return
	_spent = true
	_detonate.call_deferred()


func _detonate() -> void:
	if not is_inside_tree():
		return
	_spent = true
	var center := global_position
	var parent := get_parent()
	# Se retira antes de repartir la onda: si no, el barrido de escombros se empuja a sí misma y el
	# `queue_free` posterior deja un cuerpo tocado a medias.
	get_parent().remove_child(self)
	queue_free()
	Explosion.at(parent, center, radius, energy)
