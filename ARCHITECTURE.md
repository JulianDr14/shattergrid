# Arquitectura voxel tipo Teardown

## Decisión de renderer

El producto usa **Vulkan 1.2 a través de Godot Forward+ y su `RenderingDevice` global**. No llama
a Vulkan directamente.

La prueba con cajas proxy y `spatial shader` quedó descartada: al entrar en un volumen, la pérdida
de early-Z elevó el pase a unos 54 ms. El backend seleccionado es un `CompositorEffect` en
`POST_OPAQUE`, con un triángulo de pantalla completa, BVH de Shapes y DDA Amanatides-Woo. Es el
único backend conectado a `main.tscn`; el prototipo spatial queda solo como evidencia reproducible.

El pase dedicado:

- lee color y profundidad resueltos de Forward+;
- recorre primero un BVH GPU y después el volumen denso de la Shape candidata;
- salta macroceldas 8x8x8 vacías antes de hacer DDA fino a 10 cm;
- escribe color y profundidad reverse-Z para convivir con suelo, jugador y meshes opacos;
- convierte el color RGBA de MagicaVoxel de sRGB a lineal antes de escribir el buffer HDR;
- lee roughness, metallic y emisión de una segunda mitad de la fila de paleta GPU;
- ejecuta una segunda pasada alpha-blended, sin escritura de profundidad, solo cuando `MATL`
  declara vidrio visual transparente;
- deja que las transparencias convencionales de Godot se dibujen después del pase voxel.

### Agua de mapa

`VoxelWaterSystem` importa los `<water type="polygon">` de Teardown como una única superficie
`ArrayMesh`. No voxeliza el mar ni vuelve a dibujar la escena con una cámara especular. Un material
posterior al pase opaco reutiliza screen color/depth para refracción, absorción, espuma somera y un
SSR propio de ocho pasos; una segunda malla batcheada crea espuma irregular en la orilla y eleva la
lámina 1,8 cm para evitar z-fighting contra la cara voxel. Dos muestras de una normal 128×128 con ocho ondas oblicuas domain-warped
aportan movimiento sin simetría de 90°. El cielo
y el sol de `<environment>` resuelven rayos que salen de pantalla.

Lee contiene tres polígonos, 20 triángulos y 266.246,88 m², agrupados en un draw de superficie más
uno de orilla. La medida A/B
en la Radeon Pro 5300M es +0,273 ms GPU mediano / +0,798 ms P95 y +0,037 ms CPU render. No hay
reconstrucción de malla: flotación consulta solo Bodies despiertos a 30 Hz, las salpicaduras usan
un único emisor GPU y 24 ondas comparten un MultiMesh. El jugador nada con histéresis cerca de la
superficie.

## Modelo de datos

```text
VoxelWorld3D
└── VoxelBody3D                 estado estático, dinámico o retirado
    ├── StaticBody3D/RigidBody3D (Jolt)
    ├── VoxelShape3D           transformación, anclajes y paleta
    │   └── VoxelShapeData     volumen denso recortado, 1 byte/voxel, 0 = aire
    └── VoxelShape3D ...
```

`VoxelShapeData` y los recursos de configuración viven en la GDExtension C++. La extensión se
compila localmente para la arquitectura macOS del host; los binarios generados no se versionan. El
volumen denso es canónico; la ocupación de macroceldas 8x8x8 es un dato derivado para DDA, dirty
regions y colisiones.

`VoxelPalette` admite 255 materiales y conserva color/opacidad, rugosidad, metalicidad, emisión,
dureza, densidad, fricción y restitución. El renderer usa el índice real del voxel y la fila de
paleta correspondiente a su Shape. El daño y la física leen las propiedades materiales desde la
misma paleta.

En los mapas de Teardown, material físico y apariencia se resuelven por separado, como exige su
formato de autoría:

- la banda del índice de paleta decide vidrio/vegetación/madera/mampostería/metal y, por tanto,
  dureza y densidad;
- `RGBA` conserva el color sRGB exacto;
- `MATL._type`, `_rough`, `_metal`, `_alpha`, `_emit` y `_flux` deciden apariencia visual;
- un voxel de la banda física de vidrio puede llevar `MATL _metal` y verse opaco; a la inversa, un
  índice reservado puede llevar `MATL _glass` y verse transparente;
- los `voxbox` leen color, material físico y su cuarteto `pbr` del XML.

Antes se derivaba la transparencia de la banda física. Eso convertía paredes y piezas metálicas
del mapa Lee en vidrio, mientras algunos vidrios reales quedaban opacos.

El importador acepta `SIZE`, `XYZI`, `RGBA`, `MATL`, `nTRN`, `nGRP` y `nSHP`, transforma MagicaVoxel
Z-up a Godot Y-up y admite el sidecar `<asset>.voxel.json`. No reduce los `.vox` en runtime. Los
planos heredados de 30 cm se adaptan una sola vez a bloques 3x3x3 de voxeles de 10 cm.

## Destrucción

`VoxelWorld3D.damage_sphere(center, radius, energy)` realiza este flujo:

1. consulta la rejilla inmutable de Shapes estáticas y la rejilla de Shapes dinámicas despiertas;
2. aplica dureza y atenuación material por voxel;
3. escribe aire y emite la caja sucia;
4. actualiza atlas, macroceldas, clipmaps y colisión solo en la región afectada;
5. comprueba en C++ la frontera local del cráter; solo si puede haber un corte ejecuta la
   clasificación global por conectividad de seis caras;
6. conserva en el cuerpo estático las componentes conectadas a anclajes;
7. convierte las demás en partículas o nuevos `VoxelBody3D` dinámicos.

No hay solver de tensión, compresión, carga, balance ni voladizos en el volumen voxel. El criterio
es deliberadamente binario y 6-conexo: si una componente conserva al menos una ruta de caras hacia
una raíz viva, permanece estática; si pierde la última ruta, cae. No hay porcentajes de cimentación,
grosor mínimo ni excepciones por tipo de edificio. Un cuello real de un voxel sigue siendo una ruta;
simular su rotura por carga exigiría un subsistema de tensiones distinto.

Las raíces pueden ser explícitas (`anchor_indices`), material interno indestructible
(`hardness >= FOUNDATION_HARDNESS`, como `rock`/`heavymetal`) o una ruta material a otra Shape
estática que alcance una raíz. `_reaches_foundation` no tiene un límite que responda "soportado" al
agotarse: una búsqueda larga termina exactamente. `RETIRED_STATIC` no participa como soporte.
Colisión, AABB o proximidad solo generan candidatos; `touches`/`component_touches` comprueban voxeles
vivos a ambos lados.

La caché de raíz no es un booleano eterno: guarda el número exacto de voxeles de cimiento vivos por
Shape. `VoxelShapeData` mantiene un histograma de 256 materiales y cada daño informa cuántas raíces
eliminó, por lo que quitar la última piedra invalida el soporte en O(1) sin volver a recorrer una
torre o un terreno completos. Los índices de raíz originales pueden permanecer cacheados porque la
clasificación ignora automáticamente los que ya son aire.

La destrucción conserva antes del cambio únicamente los contactos que atraviesan el cubo local del
cráter. Después clasifica en C++ una sola vez y comprueba soporte externo solo para componentes
cercanas al daño. En la Shape real de 1,6 M voxeles del banco, esto redujo la llamada estable de
82,5 ms a 6,4 ms: el flood-fill completo cuesta ~2,5 ms y ya no se extraen contactos de toda la
Shape. `_static_contacts` sigue cacheando las rutas entre Shapes; la caché se invalida en ambas
direcciones mediante `_contact_users`.

Una cadena entera sin apoyo se convierte en dinámica como **un solo** `RigidBody3D`
(`_merge_dropped_chain`), sin el antiguo corte por cantidad de Shapes que convertía una tubería de
40 tramos en 40 cuerpos durante el peor frame: lo que la destrucción no ha separado sigue siendo
una pieza, aunque el mapa lo haya autorado como varios `<vox>` distintos con un cuerpo cada uno. Si
el corte ocurre dentro de una Shape y el fragmento recién creado toca otras Shapes authored lejos
del cráter —por ejemplo la cabeza de una torre eléctrica— `_absorb_static_continuations` sigue esas
uniones intactas, descarta cualquier ruta que aún llegue a una raíz y transfiere la continuación al
mismo cuerpo dinámico. Así no queda una cabeza estática suspendida ni se fabrica una articulación
entre partes que visualmente siguen soldadas.

`damage_sphere` también separa Shapes de un mismo `<body dynamic>` que han dejado de tocarse
(`_split_loose_shapes` + `_contact_groups`), para las cadenas de tramos de tubería que Teardown
suelda en un único cuerpo rígido. La agrupación respeta una línea base de soldadura de autor
(`_capture_weld_baseline`, tomada al registrar el cuerpo): dos Shapes que **nunca** se tocaron están
unidas por quien hizo el mapa y ninguna destrucción las separa, solo lo que la destrucción de verdad
desconecta.

El golpe visual no crea un `RigidBody3D` por cada voxel borrado. La operación nativa conserva un
reservorio determinista de hasta 256 posiciones/materiales retirados y el pool compone el efecto:

- chips voxel reutilizables con gravedad, rotación, rebote y color del material;
- polvo billboard simulado en GPU, con expansión, arrastre y desvanecimiento;
- chispas o esquirlas para metal, vidrio y materiales especialmente duros;
- cámara con trauma/retroceso atenuado por distancia;
- componentes de 8+ voxeles como Bodies Jolt cuando afectan al gameplay.

Los límites por impacto son 96 chips, 128 partículas de polvo y 32 chispas. Esta separación sigue
el modelo observable de Teardown: la geometría/volúmenes conservan la destrucción permanente y los
`plain particles`/humo aportan feedback local de vida corta sin convertirse en cuerpos de física.

El índice de rejilla estático se termina de construir durante la importación: daño estático no lo invalida
porque editar celdas no cambia la caja exterior de la Shape. La reconstrucción de colisión tampoco
se ejecuta dentro de la llamada de daño. Los bloques sucios se deduplican y `VoxelWorld3D` entrega
como máximo uno por frame a Jolt; el atlas visual permanece inmediato.

La clasificación de componentes vive en C++ y recorre memoria contigua: toma un puntero de lectura
al volumen, usa una cola `std::vector` y materializa cada `PackedInt32Array` una sola vez. El
presupuesto global de física y el recuento de Bodies se ejecutan en el mantenimiento de 10 Hz, no
dentro del disparo; durante ese intervalo rige una ventana temporal de 192 Bodies.
Las Shapes dinámicas se consultan mediante una rejilla de 8 m; solo los Bodies despiertos actualizan
sus celdas a 10 Hz. El mapa Lee pasa así de recorrer todos los props importados (unos 5 ms por
disparo) a consultar únicamente las celdas solapadas (0,10-0,20 ms en la prueba final).

La clasificación global usa además un índice incremental exacto por macroceldas 8³. Cada bloque
conserva sus componentes locales y puertos de seis caras; daño reconstruye solo el bloque tocado y
sus aristas vecinas. El grafo compacto decide soporte y solo materializa los voxeles de una isla que
realmente se desprende. Un guard local negativo evita la consulta global; un positivo se confirma
contra las raíces globales para reconocer rutas que salen de la ventana y vuelven a entrar. Si el
índice no es válido se ejecuta el flood fill histórico. `verify_connectivity_in_debug` permite
compararlos por muestreo sin pagar ese coste en producción.

## Carga compilada del mapa inmutable

El XML y los VOX siguen siendo la fuente de verdad. En la primera carga completa con colisión,
`TeardownMapCache` guarda en `user://compiled_teardown_maps` las caras estáticas ya fusionadas por
greedy meshing. No se usa un `PackedScene`: los datos voxel vivos, las relaciones `Body`/`Shape`,
joints y cables todavía tienen que construirse, y serializar nodos no evita por sí mismo insertar
las Shapes físicas en Jolt. El artefacto derivado permite reutilizar exactamente la fase cara sin
crear un segundo importador ni sacrificar la destrucción posterior.

La clave incluye versión de formato y Godot, tamaño/fecha del XML, todos los VOX y los archivos que
implementan importación, colisión y física. Cambiar el mapa o ese código produce otra clave y, por
tanto, una recompilación automática. El caché nunca se distribuye con el proyecto y no modifica los
archivos originales. `--rebuild-teardown-cache` fuerza una medida en frío,
`--no-teardown-cache` desactiva el camino y `--eager-teardown-cache` instala toda la colisión al
cargar para comparar.

En una carga caliente se instala sincrónicamente la colisión a 45 m del punto de aparición. El resto
queda ordenado por distancia a la cámara y entra a Jolt solo a 80 m, con 1,5 ms de presupuesto por
frame. Si una Shape recibe daño o su Body pasa a dinámico, se eliminan primero sus bloques todavía
pendientes: una cara compilada antigua nunca puede reaparecer encima de geometría destruida.

## Física Jolt y presupuestos

Los cuerpos anclados usan `StaticBody3D` y superficies cóncavas invisibles reconstruidas por
macrocelda sucia. Los fragmentos usan `RigidBody3D` y compuestos de cajas. La descomposición greedy
nativa prueba paso exacto de 10 cm. Si excede el límite, cada macrocelda reducida recibe el AABB
ajustado de sus voxeles reales: ya no se rellena todo el cubo de 20/40/80 cm ni se fusionan celdas
reducidas atravesando aire. Ese relleno era capaz de crear una repisa invisible bajo una torre.
Masa, centro de masa e inercia se calculan desde densidades y voxeles ocupados. En Bodies con varias
Shapes, la inercia se rota a los ejes del Body y se suma con el teorema de ejes paralelos; sumar solo
la inercia intrínseca hacía que un poste largo girara como un objeto compacto. Los Bodies dinámicos
usan `VoxelImpactRigidBody3D` con ocho contactos monitorizados: `_integrate_forces` solo agrega el
contacto dominante y difiere la destrucción al World, fuera del paso de Jolt.

El `VoxelBody3D` sigue siendo la unidad estructural y de autor, pero su colisión estática se reparte
en `StaticBody3D` espaciales de 2×2×2 macroceldas (ocho superficies cóncavas como máximo). Antes,
decenas de miles de bloques eran hijos de un único `StaticBody3D`: su AABB cubría todo el mapa y un
compound dinámico grande obligaba al narrow phase a probar todos sus hijos. El sharding conserva la
misma geometría y la actualización por macrocelda, pero deja que el broad phase descarte regiones
lejanas. En la torre real de la presa, un colapso de 266 cajas pasó de 66,36 ms a 8,69 ms de física
P95 sin reducir el compound ni alterar la destrucción.

El daño de un Body dinámico encola una sola reconstrucción de compound por frame. Transferir varias
Shapes al mismo fragmento usa inserción por lotes y reconstruye al final, evitando el patrón O(n²)
de rehacer el compound después de cada `add_voxel_shape`.

### Ownership, revisiones y handoff

Durante gameplay, `VoxelWorld3D._finalize_detached_bodies` es el único commit de desprendimiento.
Los fragmentos inmediatos y los que exceden el límite de tres por frame conservan el mismo Body de
origen, revisión, componente, bounds, estado, explosión y transaction ID. Ambos absorben
continuaciones estáticas sin fundación antes de emitir `body_split`; las reevaluaciones globales de
soporte esperan a que esa cola termine. Esto corrige el techo de Lee que podía convertirse por una
ruta distinta y quedar suspendido.

Si varios Bodies estructurales del mismo batch pertenecían antes a una misma familia rígida y aún
conservan contacto material, se coalescen una sola vez después del handoff. El linaje de cada Shape
impide volver a soldar dos mitades del mismo volumen separadas por el cráter; la familia impide unir
dos cascotes o edificios que simplemente chocaron durante la explosión.

Separar estática de dinámica usa un handoff explícito. El fragmento nace congelado y con filtros de
colisión a cero mientras la colisión estática vieja se reconstruye prioritariamente. Cuando todos
los bloques alcanzan la revisión objetivo, los Bodies absorbidos salieron de Jolt y pasó un physics
tick de seguridad, se restauran filtros, se descongela y se aplica el impulso almacenado. Así no hay
ni agujero temporal para jugador/vehículos/raycasts ni colisión doble contra la geometría anterior.
La misma regla cubre una torre o poste completo que cambia de `StaticBody3D` a `RigidBody3D`, aunque
no exista una Shape fuente parcialmente recortada. El CCD permanece activo para postes, piezas
pequeñas y cuerpos rápidos; una torre grande por debajo de 14 m/s lo desactiva para no barrer cada
una de sus cajas contra mallas cóncavas en todos los ticks. Los props authored dormidos no lo pagan.

Los choques físicos se convierten en daño bidireccional con una cola deduplicada de 16 y máximo dos
trabajos o 4 ms por frame. Radio y penetración salen de impulso×velocidad; atacante y receptor se agregan
explícitamente aunque el índice dinámico todavía no haya actualizado su transform. Árboles y otro
material no sólido conservan su ausencia de caras Jolt, pero una pasada exacta a 30 Hz (ocho pruebas
nativas como máximo) permite que una torre metálica los atraviese dañándolos.

`VoxelShapeData.content_revision` cambia con toda mutación real. `VoxelShape3D` registra la última
revisión notificada, `VoxelBody3D` la última revisión de colisión y una `physics_generation` por
reemplazo del Body Jolt. La caché de contactos valida revisión, generación y pose de ambos extremos.
El snapshot del World informa `COHERENT`, `PENDING` o `DESYNC`; una mutación nativa que evitó el
wrapper se diagnostica y programa un rebuild completo seguro. El mismo snapshot identifica la
revisión canónica, la revisión de colisión y el primer consumidor atrasado.

Joints, ropes y puertas ya no escriben un booleano compartido de persistencia. Cada constraint o
endpoint adquiere una retención identificada; romper una no desprotege las demás. `body_split`
transfiere ownership antes de desregistrar el dueño viejo y `body_unregistered` elimina cualquier
referencia sin heredero. Esto incluye el índice inverso de joints, endpoints de ropes y el metadato
de interacción de puertas.

Las superficies cóncavas también se fusionan con greedy meshing coplanar: un paño sólido de 64x64
voxeles entrega dos triángulos a Jolt, no 8.192, sin cambiar ni elevar la superficie. Los bloques
estáticos llegan como máximo a 3,2 m; frente al techo antiguo de 6,4 m esto añade solo 4,1 % de
Shapes en Lee y acota la reconstrucción de una región dañada.

Valores iniciales de `VoxelPhysicsBudget`:

| Límite | Valor |
|---|---:|
| Bodies despiertos recomendado | 128 |
| Bodies durante explosión | 192 |
| Cajas por Body | 128 |
| Cajas activas globales | 8192 |
| Componente convertida en partículas | 1-31 voxeles |
| Fragmento estructural | 64+ voxeles |
| Retiro estático reversible | 1,5 s dormido |

Las componentes aisladas de hasta 31 voxeles nacen directamente como chips del pool; desde 32 siguen
siendo escombros rígidos y agarrables. Un conector pequeño que todavía toca una continuación estática
siempre nace como Body para poder absorberla. Cuando una ráfaga supera esos techos, únicamente los fragmentos cosméticos por debajo de 64 voxeles
se convierten de inmediato al pool visual. Las componentes estructurales no se congelan ni se
eliminan para forzar el presupuesto.

El overlay publica `awake_bodies`, cajas **activas** contra el presupuesto, cajas totales de
diagnóstico, `collision_rebuild_ms`, bloques pendientes y `retired_bodies`.
Los fragmentos retirados vuelven a `RigidBody3D` al recibir daño.

`_box_allowance_for_new_body()` reparte el techo de cajas activas contra `awake_compound_boxes`, no
contra el total de cajas de todos los cuerpos dinámicos. Un mapa Teardown importa cientos de props
dormidos que no le cuestan nada a Jolt pero sí cuentan como "cajas existentes"; restarlas del techo
global dejaba la reserva en 1 caja para cualquier cuerpo recién vuelto dinámico, sin importar su
tamaño. Una torre de 24 m con 9600 voxeles se convertía en un único bloque macizo con la forma
equivocada: no caía porque el bloque seguía apoyado, y no se podía tocar bien porque su única caja
no coincidía con los voxeles visibles.

## Mapas Teardown: cuerpos vivos, joints y cables

`teardown_map_importer.gd` convierte un `.xml` de Teardown en el modelo `Body`/`Shape` del proyecto.
`<body dynamic="true">` es la marca de un cuerpo vivo desde el inicio, no algo que se activa solo
con una explosión: en el mapa de referencia (Lee, 632 de 635 `<body>`) son cables, tuberías, cajas
sueltas y postes que Teardown simula en reposo igual que cualquier otro objeto.

Cuatro de esas marcas viven dentro de `<script>`. El importador recorre sus hijos aunque ignore la
lógica Lua; retornar en ese nodo era la razón por la que antes solo aparecían 628. El reporte separa
`authored_dynamic_bodies` de `imported_dynamic_bodies` y el censo completo exige 632/632. Los 38
atributos `density` de Lee multiplican masa e inercia de su Shape y sobreviven a un detach.

La masa importada separa dos conceptos que el volumen voxel por sí solo no puede distinguir:
`density_scale` conserva literalmente el multiplicador `density` del XML y
`physical_fill_scale` representa cuánto del volumen delimitado por voxeles es material real. Los
props authored dentro de `<body dynamic="true">` usan `physical_fill_scale = 0.025`. Una estructura
soportada conserva `1.0` como verdad volumétrica; al convertirse en fragmento dinámico adopta
`0.10`, que representa vigas, mampostería rota y entramados huecos sin tratarlos como un bloque
macizo. Esta calibración lleva las
tres carrocerías de referencia de Lee a 847, 1533 y 1820 kg, una caja de madera de 1 m³ a 17,5 kg y
un tanque metálico de 0,25 m³ a 48,75 kg; una pieza estructural que calculaba 600 kg pasa a unos
60 kg al caer. Las regresiones están cubiertas por `tests/prop_mass_policy_selftest.gd` y
`tests/composite_mass_selftest.gd`.

**Sleep, no freeze.** Los props dinámicos importados llaman a `VoxelBody3D.sleep()`, que pone
`RigidBody3D.sleeping = true` sin sacar el cuerpo de la simulación. Es lo contrario de
`freeze_mode = FREEZE_MODE_STATIC`: un cuerpo congelado no lo mueve nada, ni el jugador empujando ni
una explosión al lado; uno dormido despierta solo en cuanto algo lo toca, tira de un joint o le
aplica una fuerza, y hasta entonces no le cuesta nada a Jolt. Jolt ignora `sleeping` mientras el
cuerpo no haya dado un paso por el espacio, así que dormir en el mismo frame en que se crea no hace
nada; `sleep()` espera dos `physics_frame` y vuelve a verificar que el Body siga vivo. Los props
reciben `linear_damp = 0.2` / `angular_damp = 1.0`; las puertas usan `0.12/0.28` para no frenar su
eje como una cadena industrial. En Lee esto cambió el estado estable de ~102
cuerpos despiertos a cero y redujo la física P95 de 17–23 ms a ~6,6 ms.

**`VoxelJoints`** reconstruye los `<joint>` del XML (`hinge`, `prismatic`, ball) como
`Joint3D` de Godot y los rompe solo cuando la destrucción se los lleva de verdad:

- el otro cuerpo se elige por material vivo dentro del radio del joint, no por contener el punto en
  una AABB; el censo real queda en 465 joints, cero extremos sin material y cero duplicados a 1 cm;
- los ball joints usan `Generic6DOFJoint3D`: traslación bloqueada, rotación libre y resortes
  angulares derivados de `rotstrength`/`rotspring` y de la inercia efectiva de ambos Bodies;
- no se usa `PinJoint3D` para los ball authored: Jolt ignora sus parámetros de bias/damping/impulse
  clamp y, además, un pin no puede representar la resistencia angular del XML;

- se **reata** al `PhysicsBody3D` nuevo cuando su cuerpo cambia de estado (`make_dynamic()` o
  `retire_to_static()` reemplazan el `PhysicsBody3D` entero, lo que invalidaba en silencio cualquier
  joint que apuntara al nodo muerto por `NodePath`);
- se **transfiere** al trozo que se queda el material del anclaje cuando un cuerpo se parte
  (`body_split`), igual que documenta la API de Teardown ("joints may be transferred to new shapes,
  detached or completely disabled");
- se **rompe por destrucción** cuando ya no queda material a un lado u otro del anclaje
  (`on_impact`, mismo chequeo que usa `VoxelDoor3D` para bisagras y chapas);
- se **rompe por fuerza** cuando los dos anclajes se separan más de `BREAK_SEPARATION` (0,5 m):
  Godot no expone la fuerza de una restricción, pero sí cuánto la viola, que es la señal disponible
  más cercana al `strength` de Teardown.

**`VoxelRopes`** simula los `<rope>` como cadenas de puntos con integración de Verlet y
restricciones de distancia (el modelo de la API de Teardown: `GetRopeNumberOfPoints`/
`GetRopePointPosition`), no como `RigidBody3D` encadenados, que es lo que hunde los FPS. Cada
extremo se resuelve por geometría al importar (`_body_near`, radio `ANCHOR_SEARCH`: el XML de Lee no
dice a qué se engancha un cable) y queda clavado a un `VoxelBody3D`:

- el extremo **sigue** al cuerpo mientras esté clavado (`_follow_anchors`);
- el cable **tira**: muelle + amortiguador (`STIFFNESS`, `TENSION_DAMPING`) aplicado como fuerza en
  el punto de anclaje, no en el centro de masas, así que también genera par;
- **rompe** al superar el `maxstretch` authored o 0,75 m por defecto, o cuando la carga elástica
  alcanza `strength × 10 kN`; el amortiguador no puede provocar una rotura falsa al despertar;
- **colisiona**: cada punto libre lanza un rayo contra el mundo, con fricción tangencial
  (`COLLISION_FRICTION`) y una piel de separación (`COLLISION_SKIN`); solo los tramos despiertos, así
  que en reposo cuesta cero;
- una `TENSION_SLACK` de 2 cm evita que el asentamiento de un prop mantenga el cable en tensión
  perpetua y con él despierto un par de cuerpos para siempre.
- una explosión se compara con el segmento real más cercano más 1,5 m, no con un radio global de
  60 m. Los cables clavados a una torre se despiertan igualmente al moverse su endpoint, sin activar
  cientos de raycasts de tendidos ajenos durante el colapso;
- un extremo suelto usa drag de 0,28/s y cae 4,29 m el primer segundo, mientras un vano sujeto usa
  3,7/s para asentarse. Antes ambos multiplicaban su velocidad por 0,94 cada frame y el roto parecía
  papel;
- si un split/coalesce deja los dos extremos en el mismo `RigidBody`, los puntos se guardan en
  coordenadas locales y siguen su transform. Resolverlo como resorte interno aplicaba fuerzas
  opuestas en puntos distintos, inyectaba torque y era la causa del “baile” de la torre.

La longitud de reposo del cable **no** sale de `slack` del XML: los tendidos de Teardown se
autoran pretensados (`slack` negativo) y usar eso literalmente dejaría los cuerpos tirados por un
cable que nunca afloja. Se toma la separación real entre anclajes al importar, que es la postura de
equilibrio del mapa.

### Vehículos importados

El importador usa cada `<vehicle>` del XML como única fuente de verdad. Posición, ruedas, tracción,
dirección, recorrido, resorte, amortiguación, fricción, velocidad máxima y asiento se traducen a un
`VoxelVehicle3D` con un solo `VehicleBody3D` y cuatro `VehicleWheel3D`. La carrocería destructible y
el vehículo comparten el mismo Body Jolt; las ruedas voxel visuales no agregan colisión ni masa.

El jugador entra o sale con `E`, conduce con `WASD` y usa `Espacio` como freno de mano. La cámara
orbita con el ratón, evita geometría con raycast y pasa a cabina al acercar completamente el zoom.
Los faros se encienden únicamente en el vehículo ocupado; freno y reversa controlan luces traseras
reales. Todas se envían también al renderer DDA, sin shadow maps ni volúmenes de sombra móviles.
Los barcos, orugas y entradas `nodrive` permanecen como Bodies dinámicos normales.

## Jugador, escaleras y puertas

El jugador sigue siendo un `CharacterBody3D`, pero ya no depende solo de `move_and_slide()`. Usa
`floor_snap_length = 0,32 m`, margen seguro de 3,5 cm, ocho deslizamientos, 120 ms de coyote/buffer
de salto y un barrido de tres tramos para subir peldaños de hasta 46 cm: arriba, dentro del escalón
y de nuevo hacia el suelo. El barrido elevado impide trepar paredes completas y el snap mantiene
contacto al bajar escaleras. Esto acompaña la colisión acotada de Shapes grandes
sin introducir rampas visibles ni recalcular colisión a 10 cm para todo el mapa.

La prolongación horizontal de 30 cm pertenece solo al **sondeo** que encuentra el peldaño; nunca se
aplica al movimiento confirmado. La subida traslada exactamente el desplazamiento horizontal que
habría ocurrido en suelo plano y solo añade la corrección vertical. Antes se confirmaba también esa
prolongación y cada escalón regalaba distancia, produciendo la aceleración no lineal. El autotest
mide ahora un máximo de 9,2 cm por frame frente a un límite de 11 cm.

El clic derecho ya no es una ruta exclusiva de puertas. Selecciona cualquier `VoxelBody3D`
`DYNAMIC` o `RETIRED_STATIC` bajo la mira: cajas authored, props y fragmentos de destrucción. Nunca
promueve escenario `STATIC`. El punto pertenece a la Shape, por lo que sigue al heredero tras un
split; una retención impide retiro por budget y una línea HUD une la mira con el punto agarrado. El
resorte PD tiene fuerza absoluta máxima de 2200 N y aceleración máxima de 38 m/s²: los objetos
pesados se arrastran más lentamente y pueden superar la capacidad de levantamiento del jugador.

Las puertas importadas conservan la topología de juntas del XML original:

- dos `ball joints` alineados verticalmente forman el eje de bisagra; también se aceptan los
  `hinge joints` explícitos;
- una tercera junta en el borde opuesto se interpreta como chapa cerrada;
- clic derecho hace un raycast de 3,25 m y aplica un resorte amortiguado al punto exacto de la hoja;
- agarrar una puerta **no** abre una chapa intacta: hay que destruir sus voxeles;
- los dos puntos del eje usan `PinJoint3D`, de rotación libre, y siguen rompiéndose por separado;
- al romper la chapa se excluyen temporalmente todos los shards del marco que solapan la hoja;
  a 12° se restaura esa colisión para que la pared vuelva a detenerla;
- la hoja hereda el 2,5 % de volumen efectivo de los props authored (59,3 kg en la regresión); el
  límite de 28 kg/m², 28–160 kg, solo evita que un override excepcional vuelva a hacerla maciza;
- el daño comprueba material vivo en ambos lados de cada conexión; al perder una bisagra se rompe
  solo esa junta y, al perderlas todas, la hoja queda completamente desprendida;
- los Bodies con joints son persistentes: pueden dormir, pero el presupuesto nunca los reemplaza
  por otro `StaticBody3D`, porque eso invalidaría los RID de Jolt.

`VoxelJoints` es el único dueño de `live → broken`; la puerta ya no libera nodos o holds por fuera.
Al desaparecer la última bisagra y la chapa, espera a que `queue_free` retire la constraint, usa un
handoff de colisión de dos ticks para salir del marco y deja el movimiento posterior a Jolt.

Es el mismo reparto conceptual público de Teardown (`Body`/`Shape`/`Joint`, selección bajo la mira
y punto de agarre), implementado sobre `RigidBody3D`, `Generic6DOFJoint3D`, `HingeJoint3D` y
`SliderJoint3D`; no replica código propietario. La bomba pasó a `G`/clic medio para reservar clic
derecho a interacción.

## Atlas y actualizaciones parciales

`VoxelRenderSystem` empaqueta las Shapes en atlas 3D persistentes `R8UI`: uno para materiales y
otro para ocupación de macroceldas. Reserva profundidad para fragmentos nuevos; un split actualiza
metadatos/BVH y ocupa el espacio reservado. El daño sube el cubo sucio a un storage buffer compacto
y un kernel compute `r8ui` escribe únicamente esos texels después del pase DDA. Esto evita tanto
la transferencia completa como la transición global que `texture_copy` provocaba en la Radeon Pro
5300M. Las transferencias y metadatos se drenan desde el callback del hilo de render, sin bloquear
el movimiento ni el tick de destrucción.

El BVH mantiene índices padre/hoja y 256 hojas de reserva para fragmentos. Mover un Body actualiza
solo su registro de 192 bytes y la ruta hoja-raíz (48 bytes por nodo); crear un fragmento activa una
hoja reservada que comparte la fila de paleta de su Shape de origen. Antes, cada Body despierto
reconstruía y reempaquetaba las 2.247 entradas y unos 4.493 nodos del mapa en cada frame, que era el
"cooldown" de 3-11 FPS observado después de un impacto.

`VoxelRenderSystem.movable_shapes()` decide qué Shapes sondear cada frame preguntando a
`world.get_dynamic_bodies()` en el momento, no manteniendo una caché poblada al registrar. La caché
poblada al registrar dejaba fuera a cualquier Shape cuyo cuerpo se volviera dinámico **después** —
una torre que pierde su apoyo, un tramo suelto que estrena cuerpo — porque en ese momento su estado
todavía era estático. El cuerpo caía de verdad en Jolt, pero su transformada nunca volvía a subirse
a la GPU: quedaba un fantasma dibujado en el sitio de antes, atravesable e indestructible porque los
voxeles reales ya estaban en otro lado. Igual que la caché de la clipmap de sombras, se filtra a
cuerpos despiertos (con un frame de gracia al que acaba de dormirse).

## Sombras voxel

El sol consulta cuatro clipmaps toroidales centrados en cámara. Cada byte empaqueta 2x2x2 celdas y
las capas estática y dinámica son independientes:

| Nivel | Resolución lógica | Celda | Cobertura |
|---|---:|---:|---:|
| L0 | 512³ | 10 cm | 51,2 m |
| L1 | 512³ | 20 cm | 102,4 m |
| L2 | 512³ | 40 cm | 204,8 m |
| L3 | 512³ | 80 cm | 409,6 m |

La reserva total es 128 MiB. El origen avanza en saltos de ocho celdas y solo reconstruye las
franjas nuevas. Si tanto la franja entrante como la saliente están vacías, el scroll se elimina por
completo. Los niveles gruesos son conservadores: basta un hijo ocupado. El daño actualiza L0 de
inmediato y distribuye L1-L3 en los tres frames siguientes. Movimiento dinámico invalida únicamente
las regiones tocadas. Los rayos primarios conservan 10 cm; solo la sombra secundaria del sol cambia
progresivamente de clipmap y usa un máximo de 20 muestras.

Las luces `OmniLight3D` y `SpotLight3D` del grupo `voxel_shadow_lights` compiten por un pool de ocho
volúmenes lógicos 256³, empaquetados físicamente como 128³. Se ordenan por prioridad explícita,
influencia y distancia a cámara. El shader DDA consume posición, dirección, color, energía y el
volumen seleccionado; las demás luces pueden seguir iluminando mediante Godot sin sombra voxel.

## API pública

| Interfaz | Responsabilidad |
|---|---|
| `VoxelWorld3D.damage_sphere(...)` | daño material, separación y resultado por Shape |
| `VoxelBody3D` | agrupación de Shapes y estado Jolt |
| `VoxelDoor3D` | bisagras, chapa destructible y estado de interacción |
| `VoxelJoints` | joints de Teardown: reata, transfiere y rompe por destrucción o fuerza |
| `VoxelRopes` | cables como cadena de puntos Verlet: tensión, colisión y rotura |
| `VoxelWaterSystem` | polígonos, refracción/SSR, espuma, consultas, splash y flotación |
| `VoxelImpactRigidBody3D` | captura acotada de contactos Jolt; el World ejecuta el daño diferido |
| `VoxelShape3D` | transformación, datos, paleta y anclaje |
| `VoxelPalette` | propiedades visuales y físicas |
| `VoxelPhysicsBudget` | límites, retiro y reactivación |
| `VoxelRendererSettings` | escala y objetivos del renderer |
| `voxels_changed` | AABB mundial y cubo voxel modificado |
| `body_split` | nuevos Bodies desprendidos o fundidos (transfiere joints/cables) |
| `body_unregistered` | barrera final para liberar constraints y referencias sin heredero |
| `Explosion.at(...)` | adaptador de armas a `damage_sphere()` |

El backend DDA es interno y no existe selector de renderer en runtime.

## Validación reproducible

Comandos principales:

```bash
godot --headless --path . --script res://tests/native/core_selftest.gd
godot --headless --path . --script res://tests/teardown_palette_selftest.gd
godot --headless --path . --script res://tests/teardown_architecture_selftest.gd
godot --headless --path . --script res://tests/physics_budget_selftest.gd
godot --headless --path . --script res://tests/composite_mass_selftest.gd
godot --headless --path . --script res://tests/player_movement_selftest.gd
godot --headless --path . --script res://tests/door_system_selftest.gd
godot --headless --path . --script res://tests/grab_system_selftest.gd
godot --headless --path . --script res://tests/joint_break_selftest.gd
godot --headless --path . --script res://tests/rope_selftest.gd
godot --headless --path . --script res://tests/cable_link_selftest.gd
godot --headless --path . --script res://tests/water_system_selftest.gd
godot --headless --path . --script res://tests/water_interaction_selftest.gd
godot --headless --path . --script res://tests/voxel_impact_damage_selftest.gd
godot --headless --path . --script res://tests/loose_shapes_selftest.gd
godot --headless --path . --script res://tests/moving_shapes_selftest.gd
godot --headless --path . --script res://tests/live_props_selftest.gd
godot --headless --path . --script res://tests/unsupported_drop_selftest.gd
godot --headless --path . --script res://tests/deferred_continuation_selftest.gd
godot --headless --path . --script res://tests/collision_handoff_selftest.gd
godot --headless --path . --script res://tests/tower_parts_probe.gd
godot --headless --path . --script res://tests/large_collapse_probe.gd
godot --headless --path . --script res://tests/support_search_probe.gd
godot --headless --path . --script res://tests/compiled_map_cache_probe.gd -- --rebuild-teardown-cache
godot --headless --path . --script res://tests/compiled_map_cache_probe.gd
godot --headless --path . --script res://tests/map_destruction_cpu_probe.gd
godot --headless --path . --script res://tests/joint_census_probe.gd
godot --path . res://tests/physics_burst_benchmark.tscn
godot --path . res://prototype/dedicated_dda_prototype.tscn -- --benchmark
godot --path . res://main.tscn -- --benchmark-main
godot --path . res://main.tscn -- --benchmark-walk
godot --path . res://main.tscn -- --benchmark-destruction
godot --path . res://main.tscn -- --damage-capture
godot --path . res://main.tscn -- --water-capture
godot --path . res://main.tscn -- --clipmap-test
godot --path . res://main.tscn -- --local-shadow-test
```

Los benchmarks del mapa están limitados a 60 FPS por defecto para no monopolizar la GPU del equipo
de desarrollo. `--benchmark-uncapped` existe únicamente para una sesión dedicada de profiling.

Resultado medido el 2026-08-23 con la GDExtension `Release`, Godot 4.7.2 oficial, Radeon Pro 5300M y
1600x900 al 40 % de escala interna:

- Lee completo: 79.348.954 voxeles, 2.252 Shapes, 2.288 Bodies y 465 joints; compilación en frío en
  47,44 s y carga caliente en 13,01 s (3,65× más rápida). El archivo Zstd mide 82,4 MB; la carga
  reutiliza 25.757 bloques de caras, genera cero caras y baja la fase síncrona de colisión a 42 ms;
- la zona inicial instala 8.302 bloques en 1,81 s y deja 17.453 para streaming local; en seis frames
  de prueba el contador baja a 17.374 sin congelar la carga;
- mapa quieto con sombras voxel: frame mediano/P95 16,67 ms, GPU P95 9,35 ms, física P95 6,61 ms y
  cero Bodies despiertos;
- sin sombras voxel, para aislar CPU/Jolt: frame P95 16,67 ms, GPU P95 8,59 ms y física P95 6,13 ms;
- destrucción (12 impactos, 3.970 voxeles, pico de 1.878 partículas): frame P95 18,06 ms, máximo
  24,53 ms, ventana de impacto P95 20,57 ms y llamada de daño P95 19,87 ms; pasa el presupuesto
  gráfico completo;
- en esa prueba, el flush de colisión queda en 0,89 ms P95 / 5,96 ms máximo, el sync de transforms
  en 0,16 ms P95 y no ocurre ningún rebuild global de metadatos/BVH;
- Shape real de 1,6 M voxeles, sin renderer ni colisión: llamada estable 6,42 ms, flood-fill 2,52 ms,
  soporte externo local 0,47 ms; el diseño anterior tardaba 82,5 ms y gastaba ~59 ms recorriendo
  contactos ajenos al cráter;
- la misma Shape después del contador material incremental: cráter denso 2,58 ms y llamada estable
  6,22 ms, sin volver a escanear la cimentación completa;
- colapso aislado de la torre eléctrica real con daño de contacto apagado: 84 cajas, 10.521,9 kg,
  descenso de 2,58 m y física P95 de 6,73 ms. La representación maciza anterior calculaba
  105.219 kg y el mapa ejecutable permitía hasta 512 cajas por Body;
- burst gráfico de 256 fragmentos solicitados: frame P95 16,67 ms, recuperación en 0,21 s y 128
  compounds activos después de convertir el exceso cosmético al pool visual;
- censo de joints: 465 vivos (395 ball, 68 hinge, 2 prismatic), cero extremos sin material y cero
  duplicados a 1 cm.
- regresión fija de la torre de Lee: cabeza y mástil terminan en un único Body dinámico, CCD
  adaptativo apagado a baja velocidad, 29 cajas activas, ~9,4 t, cero Bodies
  vacíos/handoffs/fragmentos críticos y descenso de 3,17 m; ningún cable interno aplica tensión y
  la física de recuperación queda en 7,07 ms P95. En el probe de 12 impactos la peor
  conectividad queda en 8,71 ms y la peor llamada total en 19,35 ms, con cero fallbacks.

La integración se basa en la API pública Body/Shape de Teardown y en los puntos de extensión de
render de Godot; no usa código propietario de Teardown.

Referencias: [breakdown público del renderer de Teardown](https://juandiegomontoya.github.io/teardown_breakdown.html)
(solo representación/consultas, no se trata como descripción de destrucción estructural),
[API pública de Teardown](https://teardowngame.com/experimental/api.html),
[presentación técnica de Dennis Gustafsson](https://www.gamedeveloper.com/game-platforms/video-breaking-down-the-making-of-i-teardown-i-),
[`Cracking destruction`](https://blog.voxagon.se/2014/05/13/cracking-destruction.html),
[arquitectura oficial de Jolt](https://github.com/jrouwe/JoltPhysics/blob/master/Docs/Architecture.md),
[limitaciones de Jolt en Godot](https://docs.godotengine.org/en/4.7/tutorials/physics/using_jolt_physics.html),
[collision shapes 3D de Godot](https://docs.godotengine.org/en/4.7/tutorials/physics/collision_shapes_3d.html),
[archivos comprimidos y serialización de Godot](https://docs.godotengine.org/en/latest/classes/class_fileaccess.html),
[caché de geometría procedural en Godot](https://docs.godotengine.org/en/4.7/tutorials/3d/procedural_geometry/arraymesh.html),
[optimización CPU de Godot](https://docs.godotengine.org/en/latest/tutorials/performance/cpu_optimization.html),
[rendimiento de Voxel Tools](https://voxel-tools.readthedocs.io/en/latest/performance/),
[`CompositorEffect`](https://docs.godotengine.org/en/stable/classes/class_compositoreffect.html) y
[`RenderSceneBuffersRD`](https://docs.godotengine.org/en/stable/classes/class_renderscenebuffersrd.html).
