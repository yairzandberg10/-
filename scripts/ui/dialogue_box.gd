extends Control
## Dialogue box: round portrait with the speaker's initial, name, typewriter
## text, "continue" hint and optional choices. Driven by game_ui.gd.

const T = preload("res://scripts/ui/ui_theme.gd")
const CPS := 55.0

signal finished

var speaker := ""
var lines: Array = []
var index := 0

var _panel: PanelContainer
var _portrait_holder: Control
var _name: Label
var _text: Label
var _hint: Label
var _choices: VBoxContainer
var _typing := 0.0
var _choosing := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	layout_direction = Control.LAYOUT_DIRECTION_RTL
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_bottom = -26
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.custom_minimum_size = Vector2(820, 170)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var row := T.hbox(18)
	_panel.add_child(row)
	_portrait_holder = CenterContainer.new()
	_portrait_holder.custom_minimum_size = Vector2(104, 104)
	_portrait_holder.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(_portrait_holder)
	var col := T.vbox(6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	_name = T.label("", 22, T.TITLE, true)
	col.add_child(_name)
	_text = T.label("", 21, T.TEXT)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(640, 64)
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_text)
	_choices = T.vbox(6)
	col.add_child(_choices)
	_hint = T.label("E / רווח / קליק – המשך  ◂", 14, T.TEXT_SOFT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(_hint)


func start(spk: String, ls: Array) -> void:
	speaker = spk
	lines = ls.duplicate()
	index = 0
	for c in _portrait_holder.get_children():
		c.queue_free()
	var col := T.speaker_color(spk)
	var initial := spk.substr(0, 1) if spk != "" else "?"
	# "ראש העיר פוטטו" -> פ, "המפקדת צ'יפסי" -> צ: use the last word's initial for titles.
	var words := spk.split(" ", false)
	if words.size() > 1 and words[0] in ["ראש", "המפקדת", "האופה", "המציל", "סבתא", "מר"]:
		initial = words[words.size() - 1].substr(0, 1)
	_portrait_holder.add_child(T.dot(col, 96, initial, 46))
	_name.text = spk
	_name.add_theme_color_override("font_color", col.darkened(0.25))
	_show_line()
	_panel.pivot_offset = Vector2(_panel.size.x * 0.5, _panel.size.y)
	_panel.scale = Vector2(0.92, 0.92)
	_panel.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_panel, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.12)


func _line_text(l: Variant) -> String:
	return str(l.get("text", "")) if l is Dictionary else str(l)


func _show_line() -> void:
	for c in _choices.get_children():
		c.queue_free()
	_choosing = false
	_text.text = _line_text(lines[index])
	_typing = 0.0
	_text.visible_characters = 0
	_hint.visible = false
	T.sfx("blip")


func _process(delta: float) -> void:
	if _text.visible_characters < 0:
		return
	_typing += delta * CPS
	var n := int(_typing)
	if n >= _text.get_total_character_count():
		_finish_typing()
	else:
		_text.visible_characters = n


func _finish_typing() -> void:
	_text.visible_characters = -1
	var l: Variant = lines[index]
	if l is Dictionary and l.has("choices") and not _choosing:
		_choosing = true
		var i := 0
		for ch in l["choices"]:
			i += 1
			var b := T.button("%d. %s" % [i, str(ch.get("text", ""))], _choose.bind(ch))
			b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			b.focus_mode = Control.FOCUS_NONE
			_choices.add_child(b)
		_hint.text = "בחרו תשובה (1/2/3)"
	else:
		_hint.text = "E / רווח / קליק – המשך  ◂" if index < lines.size() - 1 else "E / רווח / קליק – סיום  ✓"
	_hint.visible = true


func _choose(ch: Dictionary) -> void:
	if ch.has("event"):
		GameState.emit_event(str(ch["event"]))
	if ch.has("flag"):
		GameState.set_flag(str(ch["flag"]))
	var reply := str(ch.get("reply", ""))
	if reply != "":
		lines.insert(index + 1, reply)
	_choosing = false
	next()


func choose_index(i: int) -> bool:
	if not _choosing:
		return false
	var l: Dictionary = lines[index]
	var chs: Array = l.get("choices", [])
	if i < 0 or i >= chs.size():
		return false
	_choose(chs[i])
	return true


## Click / E / Space: finish the typewriter, or go to the next line.
func advance() -> void:
	if _text.visible_characters >= 0:
		_finish_typing()
		return
	if _choosing:
		return
	next()


func next() -> void:
	index += 1
	if index >= lines.size():
		finished.emit()
		return
	_show_line()


## Esc: jump to the end (choices default to the first answer).
func skip_all() -> void:
	finished.emit()


func is_choosing() -> bool:
	return _choosing


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance()
		accept_event()
