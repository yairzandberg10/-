extends Control
## Home screen (at launch) and pause menu (Esc). The city slowly turns behind
## it. Pages: main buttons, settings, how to play.

const T = preload("res://scripts/ui/ui_theme.gd")

signal closed

var paused_mode := false   # false = home screen at launch, true = Esc menu
var _win: PanelContainer
var _pages := {}
var _title: Label
var _sub: Label
var _continue: Button
var _resume: Button
var _confirm: Control
var _quality: Button
var _fps: CheckBox


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.12, 0.08, 0.05, 0.25)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var head := T.vbox(0)
	head.anchor_left = 0.5
	head.anchor_right = 0.5
	head.offset_top = 38
	head.grow_horizontal = Control.GROW_DIRECTION_BOTH
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(head)
	_title = T.hud_label("תל בטטה", 76, Color("ffd34a"))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_constant_override("outline_size", 18)
	head.add_child(_title)
	_sub = T.hud_label("הסוד של רמת פריקסה", 30)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.add_theme_constant_override("outline_size", 10)
	head.add_child(_sub)

	_win = T.window(Vector2(420, 0))
	_win.anchor_top = 0.58
	_win.anchor_bottom = 0.58
	add_child(_win)
	var stack := T.vbox(0)
	_win.add_child(stack)
	_pages["main"] = _main_page()
	_pages["settings"] = _settings_page()
	_pages["help"] = _help_page()
	_pages["confirm"] = _confirm_page()
	for k in _pages:
		stack.add_child(_pages[k])
	var ver := T.hud_label("Tel Batata · Godot 4", 13, Color(1, 1, 1, 0.7), false)
	ver.anchor_top = 1.0
	ver.anchor_bottom = 1.0
	ver.offset_top = -26
	ver.offset_left = 14
	add_child(ver)
	show_page("main")


func open(as_pause: bool) -> void:
	paused_mode = as_pause
	_title.visible = true
	_sub.text = "הפסקה" if as_pause else "הסוד של רמת פריקסה"
	var has_game := GameState.started
	_continue.visible = not as_pause and has_game
	_continue.text = "המשך לשחק  (פרק %d)" % mini(GameState.quest_index + 1, GameState.quests().size())
	_resume.visible = as_pause
	visible = true
	show_page("main")
	_win.pivot_offset = _win.size * 0.5
	_win.scale = Vector2(0.9, 0.9)
	create_tween().tween_property(_win, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK)


func show_page(name: String) -> void:
	for k in _pages:
		_pages[k].visible = k == name
	_refresh_settings()
	_win.reset_size()


func _main_page() -> Control:
	var v := T.vbox(12)
	_resume = T.button("חזרה למשחק", _close, 340)
	v.add_child(_resume)
	_continue = T.button("המשך לשחק", _close, 340)
	v.add_child(_continue)
	v.add_child(T.button("משחק חדש", _ask_new_game, 340))
	v.add_child(T.button("הגדרות", show_page.bind("settings"), 340))
	v.add_child(T.button("איך משחקים?", show_page.bind("help"), 340))
	v.add_child(T.button("יציאה", func(): get_tree().quit(), 340))
	return v


func _confirm_page() -> Control:
	var v := T.vbox(14)
	var l := T.label("להתחיל את הסיפור מההתחלה?\nההתקדמות הנוכחית תימחק (העיר והבניינים שלך נשארים).",
			19, T.TEXT, false, HORIZONTAL_ALIGNMENT_CENTER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(360, 0)
	v.add_child(l)
	var h := T.hbox(12)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(T.button("כן, מההתחלה", start_new_game, 170))
	h.add_child(T.button("ביטול", show_page.bind("main"), 140))
	v.add_child(h)
	return v


func _settings_page() -> Control:
	var v := T.vbox(12)
	v.add_child(T.title_row("הגדרות", 26))
	_quality = T.button("", func():
		Settings.cycle_quality()
		_refresh_settings(), 340)
	v.add_child(_quality)
	v.add_child(_slider("מוזיקה", Settings.music_volume, func(x):
		Settings.music_volume = x
		Settings.save()
		Settings.changed.emit()))
	v.add_child(_slider("צלילים", Settings.sfx_volume, func(x):
		Settings.sfx_volume = x
		Settings.save()
		Settings.changed.emit()))
	_fps = CheckBox.new()
	_fps.text = "הצגת FPS"
	_fps.focus_mode = Control.FOCUS_NONE
	_fps.toggled.connect(func(on):
		Settings.show_stats = on
		Settings.save()
		var hud := get_tree().get_first_node_in_group("hud")
		if hud:
			hud.show_stats(on))
	v.add_child(_fps)
	v.add_child(T.button("חזרה", show_page.bind("main"), 340))
	return v


func _slider(text: String, value: float, cb: Callable) -> Control:
	var h := T.hbox(12)
	var l := T.label(text, 19, T.TEXT, true)
	l.custom_minimum_size = Vector2(90, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(cb)
	h.add_child(s)
	return h


func _help_page() -> Control:
	var v := T.vbox(8)
	v.add_child(T.title_row("איך משחקים?", 26))
	for line in [
		"WASD – הליכה · Shift – ריצה · רווח – קפיצה",
		"עכבר – סיבוב המצלמה · גלגלת – זום",
		"E – לדבר, להיכנס לבניין, לנהוג ברכב",
		"F או קליק שמאלי – בגט ספוגי (אחרי שתקבלו אותו)",
		"I – התיק · Tab – יומן המשימות",
		"היהלום הצהוב מראה לאן ללכת",
		"ברכב: W/S נסיעה · A/D היגוי · Q צופר · E יציאה",
		"P – מצב צילום · B – בנייה · C – מצלמה חופשית",
		"Esc – התפריט הזה",
	]:
		var l := T.label(line, 17, T.TEXT, false, HORIZONTAL_ALIGNMENT_RIGHT)
		v.add_child(l)
	v.add_child(T.button("חזרה", show_page.bind("main"), 340))
	return v


func _refresh_settings() -> void:
	if _quality:
		_quality.text = "איכות גרפיקה: " + Settings.quality_label()
	if _fps:
		_fps.set_pressed_no_signal(Settings.show_stats)


func _ask_new_game() -> void:
	if GameState.started and (GameState.quest_index > 0 or GameState.step_index > 0):
		show_page("confirm")
	else:
		start_new_game()


func start_new_game() -> void:
	visible = false
	closed.emit()
	GameState.new_game()


func _close() -> void:
	visible = false
	closed.emit()
