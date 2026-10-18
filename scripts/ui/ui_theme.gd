extends RefCounted
## Shared look for the whole game interface: warm, rounded, cute. Everything is
## StyleBoxFlat + system fonts (no textures), so it costs nothing to load.

const FONTS := ["Segoe UI", "Arial", "Noto Sans Hebrew", "DejaVu Sans", "Sans-Serif"]

const CREAM := Color("fff6e6")
const CREAM_DARK := Color("f6e2c0")
const BORDER := Color("e8a85a")
const TEXT := Color("4a3222")
const TEXT_SOFT := Color("8a6a50")
const ACCENT := Color("f0803c")
const TITLE := Color("c8562a")
const BTN := Color("ffd27a")
const BTN_HOVER := Color("ffe2a6")
const BTN_PRESS := Color("f2b552")
const BTN_EDGE := Color("d9973f")
const GOOD := Color("7cc46a")
const HEART := Color("ee4b55")
const GOLD := Color("f5c330")

static var _theme: Theme
static var _font: SystemFont
static var _bold: SystemFont


static func font(bold := false) -> SystemFont:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(FONTS)
		_bold = SystemFont.new()
		_bold.font_names = PackedStringArray(FONTS)
		_bold.font_weight = 700
	return _bold if bold else _font


static func box(bg: Color, radius := 18, border := Color.TRANSPARENT, bw := 0, margin := 12.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	sb.set_content_margin_all(margin)
	sb.anti_aliasing = true
	return sb


static func panel_box() -> StyleBoxFlat:
	var sb := box(CREAM, 24, BORDER, 4, 20.0)
	sb.shadow_color = Color(0.25, 0.12, 0.0, 0.28)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 5)
	return sb


static func _button_box(bg: Color, edge: Color, pressed := false) -> StyleBoxFlat:
	var sb := box(bg, 16, edge, 0, 0.0)
	sb.border_color = edge
	sb.border_width_bottom = 2 if pressed else 5
	sb.border_width_top = 3 if pressed else 0
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


static func get_theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 18
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("panel", "PanelContainer", panel_box())
	t.set_stylebox("panel", "Panel", panel_box())
	t.set_stylebox("normal", "Button", _button_box(BTN, BTN_EDGE))
	t.set_stylebox("hover", "Button", _button_box(BTN_HOVER, BTN_EDGE))
	t.set_stylebox("pressed", "Button", _button_box(BTN_PRESS, BTN_EDGE, true))
	t.set_stylebox("hover_pressed", "Button", _button_box(BTN_PRESS, BTN_EDGE, true))
	t.set_stylebox("disabled", "Button", _button_box(Color("eee3d2"), Color("d8c8b0")))
	var focus := box(Color.TRANSPARENT, 16, ACCENT, 3, 0.0)
	focus.draw_center = false
	t.set_stylebox("focus", "Button", focus)
	t.set_font("font", "Button", font(true))
	t.set_font_size("font_size", "Button", 19)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(k, "Button", TEXT)
	t.set_color("font_disabled_color", "Button", Color("b5a58f"))
	t.set_constant("h_separation", "Button", 8)
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", TEXT)
	t.set_color("font_pressed_color", "CheckBox", TEXT)
	t.set_color("font_hover_pressed_color", "CheckBox", TEXT)
	t.set_color("font_focus_color", "CheckBox", TEXT)
	t.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover_pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckBox", StyleBoxEmpty.new())
	var track := box(CREAM_DARK, 8, BTN_EDGE, 0, 0.0)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", track)
	var fill := box(ACCENT, 8, ACCENT, 0, 0.0)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var sb_bg := box(Color(0.9, 0.82, 0.7, 0.6), 6, BORDER, 0, 0.0)
	var sb_grab := box(BTN_EDGE, 6, BORDER, 0, 0.0)
	t.set_stylebox("scroll", "VScrollBar", sb_bg)
	t.set_stylebox("grabber", "VScrollBar", sb_grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", box(ACCENT, 6))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(ACCENT, 6))
	_theme = t
	return t


static func label(text: String, size := 18, color := TEXT, bold := false, align := HORIZONTAL_ALIGNMENT_RIGHT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", font(true))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Label for the HUD over the 3D world: white with a soft dark outline.
static func hud_label(text: String, size := 18, color := Color.WHITE, bold := true) -> Label:
	var l := label(text, size, color, bold)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0.25, 0.13, 0.05, 0.8))
	return l


static func button(text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 46)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func():
		sfx("click")
		cb.call())
	return b


## A coloured circle (portraits, item icons, coin) with an optional centred letter.
static func dot(color: Color, d := 40.0, letter := "", letter_size := 0) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(d, d)
	var sb := box(color, int(d * 0.5), color.lightened(0.55), maxi(int(d / 14.0), 2), 0.0)
	sb.shadow_color = Color(0, 0, 0, 0.18)
	sb.shadow_size = 3
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if letter != "":
		var l := label(letter, letter_size if letter_size > 0 else int(d * 0.5), Color.WHITE, true, HORIZONTAL_ALIGNMENT_CENTER)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.add_theme_constant_override("outline_size", 4)
		l.add_theme_color_override("font_outline_color", color.darkened(0.45))
		p.add_child(l)
	return p


## Centred window panel of a minimum size, RTL.
static func window(min_size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = min_size
	p.anchor_left = 0.5
	p.anchor_right = 0.5
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.layout_direction = Control.LAYOUT_DIRECTION_RTL
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	return p


static func vbox(sep := 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep := 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func title_row(text: String, size := 30) -> Label:
	var l := label(text, size, TITLE, true, HORIZONTAL_ALIGNMENT_CENTER)
	return l


static func sep_line() -> ColorRect:
	var c := ColorRect.new()
	c.color = Color(BORDER, 0.45)
	c.custom_minimum_size = Vector2(0, 3)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func speaker_color(name: String) -> Color:
	var sp: Dictionary = GameState.story.get("speakers", {})
	if sp.has(name):
		return Color(str(sp[name]))
	var h := float(abs(name.hash()) % 360) / 360.0
	return Color.from_hsv(h, 0.55, 0.85)


static func sfx(n: String) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop and loop.root.has_node("Audio"):
		loop.root.get_node("Audio").play_sfx(n)


static func fmt_time(sec: float) -> String:
	var s := maxi(int(ceil(sec)), 0)
	return "%d:%02d" % [s / 60, s % 60]
