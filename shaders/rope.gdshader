shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_opaque;

// Cinta de cables orientada a la camara, que es como los dibuja Teardown: no son voxeles ni SDF,
// son tiras de triangulos billboard pintadas despues de la geometria solida.
//
// El ensanchado va aqui y no en la CPU a proposito. La malla lleva dos vertices por punto, siempre
// los mismos, y solo cambia cuando un cable se mueve de verdad; si el billboard se calculara en la
// CPU habria que reconstruirla en cuanto el jugador gira la cabeza, con 79 tendidos parados.
//
// Se asume que la malla esta en coordenadas de mundo (el nodo cuelga del origen sin transformar),
// que es como la construye el importador: asi `VERTEX` ya es la posicion de mundo y la camara entra
// directa, sin invertir la matriz del modelo por vertice.

uniform float radius = 0.025;
uniform vec4 albedo : source_color = vec4(0.045, 0.045, 0.055, 1.0);
/// Un cable redondo no se ve plano: se oscurece hacia los bordes de la cinta para fingir el cilindro.
uniform float rim = 0.55;

varying float side_offset;

void vertex() {
	// NORMAL trae la tangente del cable en este punto y UV.x el lado de la cinta (0 o 1).
	side_offset = UV.x * 2.0 - 1.0;
	vec3 to_camera = CAMERA_POSITION_WORLD - VERTEX;
	vec3 across = cross(NORMAL, to_camera);
	float span = length(across);
	// Mirando el cable de punta la cruz degenera; se deja el vertice donde esta en vez de reventar.
	if (span > 0.00001) {
		VERTEX += (across / span) * radius * side_offset;
	}
}

void fragment() {
	float edge = 1.0 - abs(side_offset);
	ALBEDO = albedo.rgb * mix(1.0 - rim, 1.0, sqrt(clamp(edge, 0.0, 1.0)));
}
