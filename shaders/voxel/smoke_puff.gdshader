shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_disabled,
	shadows_disabled;

// Bocanada de humo al estilo Teardown, que es el referente del juego y no dibuja el humo con cubos.
// Allí cada partícula es una pirámide hueca encarada a la cámara con las normales interpoladas: no
// se ve la geometría, se ve una bola sombreada. Aquí se hace igual con un solo quad: la normal
// esférica se calcula en el fragment, más barato y con el mismo resultado.
//
// La textura es fBm con dominio deformado -f(p + f(p)), que es lo que convierte un ruido plano en
// algo veteado y arremolinado- usada para tres cosas a la vez: romper la silueta, variar la densidad
// por dentro (un puff de densidad uniforme parece una pegatina) y abollar la normal, que es lo que
// le da el aspecto de coliflor que tiene el humo de verdad.
//
// Además se erosiona con la edad: en vez de bajar la opacidad entera, sube el umbral y solo aguantan
// los núcleos más densos. Así la bocanada se deshila en jirones en lugar de desaparecer entera.

uniform float emissive = 0.0;
// Cuánto se afila el borde. Alto = el humo se apaga mucho antes de llegar a la silueta, que es lo
// que lo hace blando. El fuego lo quiere bajo: una llama sí tiene borde.
uniform float edge_softness = 1.8;
uniform float noise_scale = 2.2;
uniform float erosion = 0.75;
uniform float bump_strength = 1.6;
// Distancia en la que el puff se apaga al clavarse en la geometría. Sin esto, la cortina de polvo
// corta el suelo con una línea recta y canta más que ninguna otra cosa.
uniform float soft_distance = 1.2;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying float seed;
varying float age;


float hash13(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}


float value_noise(vec2 x, float z) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash13(vec3(i, z)), hash13(vec3(i + vec2(1.0, 0.0), z)), f.x),
		mix(hash13(vec3(i + vec2(0.0, 1.0), z)), hash13(vec3(i + vec2(1.0, 1.0), z)), f.x),
		f.y
	);
}


float fbm(vec2 x, float z) {
	return value_noise(x, z) * 0.53 + value_noise(x * 2.1, z) * 0.29
		+ value_noise(x * 4.4, z) * 0.18;
}


void vertex() {
	// Billboard conservando la escala por eje: el tamaño de cada puff viene en la MODEL_MATRIX,
	// que es como `emit_particle` transporta la escala por partícula.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		normalize(INV_VIEW_MATRIX[0]) * length(MODEL_MATRIX[0].xyz),
		normalize(INV_VIEW_MATRIX[1]) * length(MODEL_MATRIX[1].xyz),
		normalize(INV_VIEW_MATRIX[2]) * length(MODEL_MATRIX[2].xyz),
		MODEL_MATRIX[3]
	);
	// Semilla por partícula: su posición de nacimiento. Sin ella todos los puffs comparten silueta y
	// la nube se ve estampada.
	seed = hash13(floor(MODEL_MATRIX[3].xyz * 7.0)) * 40.0;
	// `CUSTOM.y` es la fracción de vida que escribe el material de proceso.
	age = INSTANCE_CUSTOM.y;
}


void fragment() {
	vec2 disc = UV * 2.0 - 1.0;
	// Cada puff mira su ruido con su propio giro: sin esto se repite el mismo dibujo por toda la nube.
	float turn = seed * 1.7;
	vec2 sample_uv = mat2(vec2(cos(turn), -sin(turn)), vec2(sin(turn), cos(turn))) * disc;

	// Dominio deformado: el ruido se muestrea en coordenadas que el propio ruido desplaza.
	vec2 warp = vec2(
		value_noise(sample_uv * 1.6 + 11.0, seed), value_noise(sample_uv * 1.6 - 7.0, seed)
	) - 0.5;
	float billow = fbm(sample_uv * noise_scale + warp * 1.3, seed);

	float radius = length(disc) / (0.68 + billow * 0.62);
	if (radius > 1.0) {
		discard;
	}
	// Grosor de la esfera en este píxel: en un gas la opacidad es literalmente cuánta materia
	// atraviesa el rayo.
	float thickness = pow(1.0 - radius * radius, 0.5 * edge_softness);
	// Erosión: el umbral sube con la edad y solo sobreviven los grumos densos.
	float density = thickness * (0.45 + billow * 0.95);
	density *= smoothstep(age * erosion, age * erosion + 0.35, density + 0.15);

	// Abolladura de la normal con el gradiente del ruido. Una octava basta: el relieve del humo es
	// grueso, y de paso son tres muestras y no nueve.
	float step_uv = 0.06;
	vec2 gradient = vec2(
		value_noise((sample_uv + vec2(step_uv, 0.0)) * noise_scale, seed) - billow,
		value_noise((sample_uv + vec2(0.0, step_uv)) * noise_scale, seed) - billow
	) / step_uv;
	vec3 normal = normalize(vec3(disc.x, -disc.y, sqrt(max(1.0 - radius * radius, 0.0)))
		+ vec3(gradient.x, -gradient.y, 0.0) * bump_strength);
	// El truco de Teardown: uno de cada dos píxeles se sombrea por la cara de atrás de la esfera.
	// Con eso la luz parece atravesar la bocanada en vez de rebotar en una cáscara opaca.
	if (mod(FRAGCOORD.x + FRAGCOORD.y, 2.0) < 1.0) {
		normal.z = -normal.z;
	}
	NORMAL = normal;

	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emissive;
	float alpha = COLOR.a * density;

	// Soft particles: se desvanece contra lo que tenga detrás en vez de cortarlo.
	float scene_depth = texture(depth_texture, SCREEN_UV).x;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	float scene_distance = -scene_view.z / scene_view.w;
	alpha *= clamp((scene_distance + VERTEX.z) / soft_distance, 0.0, 1.0);

	ALPHA = alpha;
}
