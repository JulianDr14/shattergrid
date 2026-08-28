class_name LoadingScreen
extends CanvasLayer
## Pantalla de carga del mapa. La construye el propio script: son ocho nodos y así no hay que
## mantenerlos también en `main.tscn`.
##
## El importador es una sola llamada bloqueante, así que esta pantalla solo se ve si alguien le
## cede frames al motor. Eso lo hace [TeardownMapImporter] con `await` entre etapas, y el coste de
## esos frames se mide y sale en el informe como `progress_ms`: si algún día se vuelve un lastre,
## se nota ahí.

var _title: Label
var _detail: Label
var _source: Label
var _bar: ProgressBar
var _started := Time.get_ticks_msec()
var _low := 0.0
var _high := 1.0


func _init() -> void:
	layer = 200
	# El árbol se pausa mientras se importa; esta capa tiene que seguir viva para repintarse.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.035, 0.055, 1.0)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var layout := CenterContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layout)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.055, 0.085, 0.96)
	style.set_content_margin_all(34.0)
	style.set_border_width_all(1)
	style.border_color = Color(0.28, 0.72, 0.92, 0.32)
	style.set_corner_radius_all(18)
	card.add_theme_stylebox_override("panel", style)
	layout.add_child(card)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	card.add_child(content)

	content.add_child(_label("SHATTERGRID  /  CARGANDO MAPA", 14, Color(0.38, 0.86, 1, 1)))
	_title = _label("Preparando…", 30, Color(0.94, 0.98, 1, 1))
	content.add_child(_title)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 10)
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.show_percentage = false
	content.add_child(_bar)

	_detail = _label("", 15, Color(0.65, 0.72, 0.8, 1))
	content.add_child(_detail)
	_source = _label("", 15, Color(0.55, 0.85, 0.6, 1))
	content.add_child(_source)


## Cada etapa informa de su propio 0..1; el tramo dice dónde cae eso en la barra global.
func set_range(low: float, high: float) -> void:
	_low = low
	_high = high


## Se pasa como `Callable` a cada etapa. `source` solo se manda cuando cambia: es la línea que dice
## si el mapa sale del caché compilado o hay que construirlo desde cero.
func report(fraction: float, label: String, source := "") -> void:
	var overall := _low + (_high - _low) * clampf(fraction, 0.0, 1.0)
	_title.text = label
	_bar.value = overall
	_detail.text = "%d %%  ·  %.1f s" % [
		roundi(overall * 100.0), (Time.get_ticks_msec() - _started) / 1000.0,
	]
	if not source.is_empty():
		_source.text = source


static func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
