class_name VoxelSelfTest
extends SceneTree
## Base de los selftests: contador de fallos, montaje del mundo y cajas estáticas. Lo que había
## copiado en 28 archivos palabra por palabra.
##
## Un test hereda de aquí y define `_run()`; el `_init` de esta clase ya lo difiere. No redefinas
## `_init` en el hijo: GDScript llama igualmente al del padre y `_run` correría dos veces.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	push_error("el selftest no define _run()")
	quit(1)


func _check(condition: bool, message := "") -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


## El mundo que monta casi todo el mundo: sin diagnósticos y con presupuesto de física.
func make_world(with_budget := true) -> VoxelWorld3D:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	if with_budget:
		world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	return world


## Suelo, muro o repisa. Coloca el cuerpo entero en vez de desplazar la Shape dentro de él: para un
## StaticBody es la misma pose y ahorra el ajuste a mano en cada llamada.
static func make_box_body(parent: Node, size: Vector3, position := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	parent.add_child(body)
	body.position = position
	return body
