class_name Blueprints
## Planos de los edificios destructibles y las primitivas para escribirlos.
##
## Se escriben en la **rejilla gruesa** (celda = `Vox.BLUEPRINT_CELL`). El importador heredado
## expande cada celda exactamente una vez a 3x3x3 voxeles de 10 cm.
##
## Convención heredada de la rejilla: **`y` nunca es negativa** y lo que deba quedarse en pie tiene
## que conservar un camino 6-conexo hasta los anclajes de `y == 0`.

const K := Vox.Kind


static func of(name: String) -> Dictionary:
	var coarse: Dictionary = {}
	match name:
		"casa": coarse = _casa()
		"torre": coarse = _torre()
		"fabrica": coarse = _fabrica()
		_: push_error("plano desconocido: %s" % name)
	return coarse


# MARK: - Primitivas


static func solid(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i, kind: int) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				v[Vector3i(xi, yi, zi)] = kind


## Las cuatro paredes de una caja, sin suelo ni techo.
static func shell(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i, kind: int) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				if xi == x.x or xi == x.y or zi == z.x or zi == z.y:
					v[Vector3i(xi, yi, zi)] = kind


## Una capa horizontal: forjados, cubiertas, calles.
static func slab(v: Dictionary, y: int, x: Vector2i, z: Vector2i, kind: int) -> void:
	solid(v, x, Vector2i(y, y), z, kind)


static func column(v: Dictionary, x: int, z: int, y: Vector2i, kind: int) -> void:
	solid(v, Vector2i(x, x), y, Vector2i(z, z), kind)


## Cilindro de sección circular. Con `inner > 0` sale un tubo hueco: torres, chimeneas. Los radios
## van en celdas y en coma flotante porque los bordes salen mucho mejor con medios: un radio de 2.4
## da una sección más redonda que uno de 2.
static func cylinder(
	v: Dictionary, cx: int, cz: int, outer: float, inner: float, y: Vector2i, kind: int
) -> void:
	var bound := ceili(outer)
	for dx in range(-bound, bound + 1):
		for dz in range(-bound, bound + 1):
			var distance := sqrt(float(dx * dx + dz * dz))
			if distance > outer or distance < inner:
				continue
			for yi in range(y.x, y.y + 1):
				v[Vector3i(cx + dx, yi, cz + dz)] = kind


## Vacía un volumen: puertas, portones, ventanales.
static func carve(v: Dictionary, x: Vector2i, y: Vector2i, z: Vector2i) -> void:
	for xi in range(x.x, x.y + 1):
		for yi in range(y.x, y.y + 1):
			for zi in range(z.x, z.y + 1):
				v.erase(Vector3i(xi, yi, zi))


# MARK: - Planos


## Casa de ladrillo con esquinas de madera, ventanales y tejado piramidal macizo.
static func _casa() -> Dictionary:
	var v := {}
	var x := Vector2i(-7, 7)
	var z := Vector2i(-5, 5)
	var wall_top := 7

	for yi in range(0, wall_top + 1):
		for xi in range(x.x, x.y + 1):
			for zi in range(z.x, z.y + 1):
				var on_x := xi == x.x or xi == x.y
				var on_z := zi == z.x or zi == z.y
				if not (on_x or on_z):
					continue
				# Puerta en la fachada frontal.
				if zi == z.y and absi(xi) <= 1 and yi <= 3:
					continue
				var kind := K.LADRILLO
				if (on_x and on_z) or yi == 0:
					kind = K.MADERA
				elif yi >= 3 and yi <= 4:
					if on_z and absi(xi) % 4 == 2:
						kind = K.VIDRIO
					if on_x and absi(zi) % 3 == 2:
						kind = K.VIDRIO
				v[Vector3i(xi, yi, zi)] = kind

	# Tejado a niveles, cada uno **macizo**. Con anillos retranqueados cada nivel queda metido un
	# voxel respecto al de abajo y no llega a tocarlo: el tejado entero flota sobre la casa y se
	# viene abajo con la primera explosión en cualquier parte.
	var level := 0
	while true:
		var lo := Vector2i(x.x - 1 + level, x.y + 1 - level)
		var lz := Vector2i(z.x - 1 + level, z.y + 1 - level)
		if lo.x > lo.y or lz.x > lz.y:
			break
		slab(v, wall_top + 1 + level, lo, lz, K.TECHO)
		if lz.y - lz.x <= 1 or lo.y - lo.x <= 1:
			break
		level += 1
	return v


## Torre de piedra hueca con pisos de madera y almenas alternadas.
static func _torre() -> Dictionary:
	var v := {}
	var height := 17
	for yi in range(0, height + 1):
		for xi in range(-5, 6):
			for zi in range(-5, 6):
				var distance := sqrt(float(xi * xi + zi * zi))
				var is_wall := distance <= 5.3 and distance >= 3.9
				var is_inside := distance < 3.9
				if yi == height:
					if is_wall and (xi + zi) % 2 == 0:
						v[Vector3i(xi, yi, zi)] = K.PIEDRA
					continue
				if is_wall:
					var kind := K.PIEDRA
					if yi > 1 and yi % 5 == 3 and (absi(xi) <= 1 or absi(zi) <= 1):
						kind = K.VIDRIO
					v[Vector3i(xi, yi, zi)] = kind
				elif is_inside and yi > 0 and yi % 6 == 0:
					v[Vector3i(xi, yi, zi)] = K.MADERA
	return v


## Nave industrial con chimenea. Tumba la chimenea sobre la nave: es el escenario que luce la
## colisión de un trozo desprendido contra lo que sigue en pie.
static func _fabrica() -> Dictionary:
	var v := {}
	var x := Vector2i(-11, 11)
	var z := Vector2i(-5, 5)
	var eaves := 9

	shell(v, x, Vector2i(0, eaves), z, K.LADRILLO)
	# Lucernario corrido bajo el alero. Va **antes** que los pórticos para que los pilares lo
	# atraviesen: al revés, el vidrio sobrescribe el acero en esas dos hiladas y secciona los tres
	# pilares de cada pórtico, con lo que la cubierta nace sin camino al suelo.
	solid(v, x, Vector2i(eaves - 2, eaves - 1), Vector2i(z.x, z.x), K.VIDRIO)
	solid(v, x, Vector2i(eaves - 2, eaves - 1), Vector2i(z.y, z.y), K.VIDRIO)

	# Pórticos de acero cada tres celdas, con pilar central. El de x = 1 se salta para abrir el
	# hueco por donde entra el portón de carga.
	for cx in range(x.x, x.y + 1, 3):
		if cx == 1:
			continue
		column(v, cx, z.x, Vector2i(0, eaves), K.METAL)
		column(v, cx, 0, Vector2i(0, eaves), K.METAL)
		column(v, cx, z.y, Vector2i(0, eaves), K.METAL)
		slab(v, eaves, Vector2i(cx, cx), z, K.METAL)
		# Correas de madera sobre los pórticos: el combustible.
		slab(v, eaves + 1, Vector2i(cx, cx), z, K.MADERA)
	slab(v, eaves + 1, x, Vector2i(z.x, z.x), K.MADERA)
	slab(v, eaves + 1, x, Vector2i(z.y, z.y), K.MADERA)
	# Cubierta de teja sobre las correas.
	slab(v, eaves + 2, x, z, K.TECHO)

	# Portón de carga: el vano llega hasta el alero, sin muro encima.
	carve(v, Vector2i(-1, 3), Vector2i(0, eaves), Vector2i(z.y, z.y))
	slab(v, eaves, Vector2i(-2, 4), Vector2i(z.y, z.y), K.METAL)

	# Chimenea: tubo de ladrillo, macizo en la base para que se apoye de verdad.
	cylinder(v, 17, 0, 2.4, 0.0, Vector2i(0, 1), K.LADRILLO)
	cylinder(v, 17, 0, 2.4, 1.4, Vector2i(2, 30), K.LADRILLO)
	return v
