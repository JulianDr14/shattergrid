extends "res://tests/selftest/selftest.gd"
## Los cables tienen que comportarse como cables: colgar por su peso, mantener su longitud, y sobre
## todo dormirse. Lo caro de simular 79 tendidos es hacerlo cuando no se mueve ninguno.


func _run() -> void:
	print("cables")
	var ropes := VoxelRopes.new()
	root.add_child(ropes)
	# Tenso, como los de Lee, y otro con dos metros de holgura para ver la catenaria.
	ropes.add_span(Vector3(0, 5, 0), Vector3(6, 5, 0), -0.15)
	ropes.add_span(Vector3(0, 5, 40), Vector3(6, 5, 40), 2.0)
	# Cable largo cuya esfera de bounds alcanza la explosión, aunque el segmento real está 20 m
	# arriba. Protege contra el radio viejo que despertaba tendidos lejanos de la torre.
	ropes.add_span(Vector3(-20, 25, 0), Vector3(20, 25, 0), -0.15)
	ropes.settle()
	_check(ropes.span_count() == 3, "entran los tres tramos")

	var middle := VoxelRopes.SEGMENTS / 2
	var taut_sag := 5.0 - ropes.point(0, middle).y
	var slack_sag := 5.0 - ropes.point(1, middle).y
	print("  descuelgue en el centro  tenso %.3f m   con holgura %.3f m" % [taut_sag, slack_sag])
	# Un cable tenso descuelga poco, no cero: con `slack` negativo la cadena no da de si para cubrir
	# el hueco, asi que queda estirada y bajo tension, que es lo que le pasa a un cable real.
	_check(taut_sag < 0.2 and taut_sag < slack_sag * 0.1, "el tenso queda casi recto")
	_check(slack_sag > 1.0, "el cable con holgura cuelga por su peso")

	# Los extremos son anclajes: no se mueven nunca.
	_check(ropes.point(0, 0).is_equal_approx(Vector3(0, 5, 0))
		and ropes.point(0, VoxelRopes.SEGMENTS).is_equal_approx(Vector3(6, 5, 0)),
		"los anclajes siguen clavados")

	# La restriccion de distancia tiene que sostener la longitud: sin ella el cable se estira sin fin.
	var longest := 0.0
	for step in VoxelRopes.SEGMENTS:
		longest = maxf(longest, ropes.point(1, step).distance_to(ropes.point(1, step + 1)))
	var rest := (6.0 + 2.0) / float(VoxelRopes.SEGMENTS)
	print("  tramo mas largo %.3f m  (reposo %.3f m)" % [longest, rest])
	_check(longest < rest * 1.25, "los segmentos no se estiran")

	for _frame in 40:
		await physics_frame
	_check(ropes.awake_count() == 0, "los cables quietos se duermen y dejan de costar")

	# Una explosion al lado despierta el tramo cercano y no toca el que esta a 40 m.
	ropes.on_impact(Vector3(3, 5, 0), 2.0)
	_check(ropes.awake_count() == 1, "una explosion cercana despierta solo el cable de al lado")
	var before := ropes.point(0, middle)
	for _frame in 6:
		await physics_frame
	_check(not ropes.point(0, middle).is_equal_approx(before), "y el cable se mueve de verdad")

	for _frame in 240:
		await physics_frame
	_check(ropes.awake_count() == 0, "y vuelve a dormirse cuando se calma")
	_check(VoxelRopes.elastic_tension_for_extension(VoxelRopes.TENSION_SLACK) == 0.0 \
			and VoxelRopes.elastic_tension_for_extension(
				VoxelRopes.TENSION_SLACK + 0.001
			) < 25.0,
		"la tensión entra de forma continua y no hace castañetear el anclaje")

	# Al romperse un extremo deja de usar el damping fuerte del vano sujeto. En un segundo debe
	# acelerar casi con gravedad, no alcanzar la velocidad terminal de una hoja de papel.
	ropes.add_span(Vector3(0, 12, 80), Vector3(4, 12, 80), 0.4)
	ropes.release_anchor(ropes._spans[3], "b")
	var loose_before := ropes.point(3, VoxelRopes.SEGMENTS).y
	for _frame in 60:
		await physics_frame
	var loose_drop := loose_before - ropes.point(3, VoxelRopes.SEGMENTS).y
	print("  extremo suelto cayó %.2f m en un segundo" % loose_drop)
	_check(loose_drop > 3.0, "un cable roto cae con gravedad, no como papel")

	var surfaces := (ropes.mesh as ArrayMesh).get_surface_count()
	var vertices := 0
	if surfaces > 0:
		vertices = ((ropes.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as
			PackedVector3Array).size()
	print("  malla: %d superficie(s), %d vertices" % [surfaces, vertices])
	_check(vertices == 4 * 2 * (VoxelRopes.SEGMENTS + 1),
		"la cinta lleva dos vertices por punto y el ancho lo pone el shader")

	if failures == 0:
		print("VOXEL_ROPE_SELFTEST_OK")
	else:
		printerr("VOXEL_ROPE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
