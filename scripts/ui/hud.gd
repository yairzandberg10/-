extends CanvasLayer
## On-screen text: performance stats, current mode, help, toasts, build info.
## Also owns the photo-mode overlays (tilt-shift blur, cinematic bars).

const TILT_SHADER = preload("res://shaders/tilt_shift.gdshader")

const HELP := {
	"follow": [
		"מצב הליכה",
		"WASD – תזוזה  |  Shift – ריצה  |  רווח – קפיצה",
		"E – לדבר / להיכנס / לנהוג  |  F או קליק – בגט ספוגי",
		"I – תיק  |  Tab – יומן משימות  |  עכבר – סיבוב מצלמה",
		"C – מצלמה חופשית  |  B – מצב בנייה  |  P – מצב צילום",
		"F2 – איכות גרפיקה  |  F3 – נתוני ביצועים  |  F4 – בדיקת ביצועים",
		"F5 – שמירה  |  F11 – מסך מלא  |  F12 – צילום מסך",
		"Esc – שחרור העכבר  |  H – הסתרת העזרה",
	],
	"free": [
		"מצלמה חופשית",
		"WASD – תעופה  |  E / Q – למעלה / למטה  |  Shift – מהר",
		"עכבר – הסתכלות  |  גלגלת – מהירות",
		"C – חזרה לדמות  |  B – בנייה  |  P – צילום  |  H – הסתרה",
	],
	"build": [
		"מצב בנייה",
		"לחיצה שמאלית – בנייה  |  Z / X – סוג בניין  |  V – צבע  |  R – סיבוב",
		"Delete – מחיקת הבניין המסומן באדום  |  Ctrl+Z – ביטול",
		"WASD / E / Q – תזוזה  |  קליק ימני וגרירה – סיבוב מצלמה",
		"B – יציאה ממצב בנייה  |  H – הסתרה",
	],
	"photo": [
		"מצב צילום",
		"WASD / E / Q – תנועה חלקה  |  גלגלת – מהירות",
		"K – הוספת נקודת מסלול  |  Enter – הפעלת מסלול  |  Backspace – מחיקה",
		"O – סיבוב סביב נקודה  |  T – אפקט מיניאטורה  |  G – פסים קולנועיים",
		"[ ] – שעה ביום  |  Z / X – זום  |  N / M – הטיה  |  J – איפוס",
		"- / = – מהירות המסלול  |  F12 – צילום מסך  |  H – הסתרה  |  P – יציאה",
	],
}

var help_visible := true

var _root: Control
var _stats: Label
var _mode: Label
var _help_panel: PanelContainer
var _help: Label
var _toast: Label
var _build_panel: PanelContainer
var _build: Label
var _tilt: ColorRect
var _bars: Array = []
var _toast_left := 0.0
var _mode_key := "follow"
var _photo := false


func _ready() -> void:
	layer = 10
	var fx := CanvasLayer.new()
	fx.layer = 5
	add_child(fx)
	_tilt = ColorRect.new()
	_tilt.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tilt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	sm.shader = TILT_SHADER
	_tilt.material = sm
	_tilt.visible = false
	fx.add_child(_tilt)
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_right = 1.0
		bar.anchor_top = 0.0 if top else 0.88
		bar.anchor_bottom = 0.12 if top else 1.0
		bar.visible = false
		fx.add_child(bar)
		_bars.append(bar)

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "Arial", "Noto Sans Hebrew", "DejaVu Sans", "Sans-Serif"])
	theme.default_font = font
	theme.default_font_size = 15
	_root.theme = theme
	add_child(_root)

	_stats = _label()
	_stats.anchor_top = 1.0
	_stats.anchor_bottom = 1.0
	_stats.offset_left = 12
	_stats.offset_top = -34
	_stats.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(_stats)

	_mode = _label()
	_mode.add_theme_font_size_override("font_size", 20)
	_mode.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode.anchor_left = 0.5
	_mode.anchor_right = 0.5
	_mode.offset_top = 10
	_mode.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_mode)

	_help_panel = _panel(1.0, 0.0)
	_help = _label()
	_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_help_panel.add_child(_help)

	_build_panel = _panel(1.0, 1.0)
	_build = _label()
	_build.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_build.add_theme_font_size_override("font_size", 18)
	_build_panel.add_child(_build)
	_build_panel.visible = false

	_toast = _label()
	_toast.add_theme_font_size_override("font_size", 18)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.anchor_top = 0.78
	_toast.anchor_bottom = 0.78
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.modulate.a = 0.0
	_root.add_child(_toast)

	_stats.visible = Settings.show_stats
	set_mode("follow")


func _process(delta: float) -> void:
	if _toast_left > 0.0:
		_toast_left -= delta
		_toast.modulate.a = clampf(_toast_left / 0.6, 0.0, 1.0)


func toast(text: String, seconds := 3.0) -> void:
	if not _photo and GameUI.hud and GameUI.visible:
		GameUI.hud.toast(text, seconds)
		return
	_toast.text = text
	_toast_left = seconds
	_toast.modulate.a = 1.0


func set_mode(key: String) -> void:
	_mode_key = key
	_help.text = "\n".join(HELP.get(key, []))
	_mode.text = HELP.get(key, [""])[0]
	_build_panel.visible = key == "build"
	_refresh()


func set_build_text(text: String) -> void:
	_build.text = text


func update_stats(text: String) -> void:
	_stats.text = text


func show_stats(on: bool) -> void:
	_stats.visible = on and not _photo


func toggle_help() -> void:
	help_visible = not help_visible
	_refresh()


## Photo mode hides all UI except what the photographer asks for.
func set_photo(on: bool) -> void:
	_photo = on
	GameUI.visible = not on
	help_visible = not on
	_stats.visible = Settings.show_stats and not on
	set_mode("photo" if on else "follow")
	if not on:
		set_tilt_shift(false)
		set_letterbox(false)
	else:
		toast("מצב צילום – H להצגת המקשים", 3.0)


func set_tilt_shift(on: bool) -> void:
	_tilt.visible = on


func set_letterbox(on: bool) -> void:
	for b in _bars:
		b.visible = on


func _refresh() -> void:
	_help_panel.visible = help_visible
	_mode.visible = not _photo


func _label() -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	return l


## Panel anchored to a screen corner (ax/ay = 0 or 1) that grows inwards.
func _panel(ax: float, ay: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.55)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.anchor_left = ax
	p.anchor_right = ax
	p.anchor_top = ay
	p.anchor_bottom = ay
	var m := 12.0
	p.offset_left = m if ax == 0.0 else -m
	p.offset_right = p.offset_left
	p.offset_top = (m + 36.0) if ay == 0.0 else -m
	p.offset_bottom = p.offset_top
	p.grow_horizontal = Control.GROW_DIRECTION_END if ax == 0.0 else Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_END if ay == 0.0 else Control.GROW_DIRECTION_BEGIN
	_root.add_child(p)
	return p
