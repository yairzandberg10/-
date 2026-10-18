extends Control
## In-game HUD: hearts, coins, quest tracker with a direction arrow, on-screen
## quest marker, interaction prompt, timer, toasts and banners.

const T = preload("res://scripts/ui/ui_theme.gd")

var target := Vector3.INF
var target_label := ""

var _hearts_box: HBoxContainer
var _hearts: Array = []
var _coins: Label
var _coin_pill: PanelContainer
var _quest_panel: PanelContainer
var _q_chapter: Label
var _q_title: Label
var _q_obj: Label
var _q_dist: Label
var _arrow: Control
var _prompt: PanelContainer
var _prompt_label: Label
var _timer: PanelContainer
var _timer_label: Label
var _toasts: VBoxContainer
var _banner: VBoxContainer
var _banner_title: Label
var _banner_sub: Label
var _marker: Control
var _hurt: ColorRect
var _challenge_text := ""
var _last_hearts := -1


class Arrow extends Control:
	var angle := 0.0
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.45
		var pts := PackedVector2Array()
		for p in [Vector2(0, -1), Vector2(0.75, 0.8), Vector2(0, 0.4), Vector2(-0.75, 0.8)]:
			pts.append(c + (p * r).rotated(angle))
		draw_colored_polygon(pts, Color("f0803c"))
		var outline := pts.duplicate()
		outline.append(pts[0])
		draw_polyline(outline, Color.WHITE, 2.5, true)


class Marker extends Control:
	var hud
	func _draw() -> void:
		if hud == null or hud.target == Vector3.INF:
			return
		var cam := get_viewport().get_camera_3d()
		var player := get_tree().get_first_node_in_group("player") as Node3D
		if cam == null or player == null:
			return
		var p: Vector3 = hud.target + Vector3(0, 2.6, 0)
		var vp := get_viewport_rect().size
		var sp: Vector2
		var behind := cam.is_position_behind(p)
		sp = cam.unproject_position(p)
		if behind:
			sp = Vector2(vp.x - sp.x, vp.y - 40.0)
		var m := 46.0
		var clamped := Vector2(clampf(sp.x, m, vp.x - m), clampf(sp.y, m + 60.0, vp.y - m))
		var d := player.global_position.distance_to(hud.target)
		if d < 4.0:
			return
		var t := Time.get_ticks_msec() / 1000.0
		var bob := sin(t * 4.0) * 4.0
		var c := clamped + Vector2(0, bob)
		var s := 13.0
		var pts := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s * 0.8, 0), c + Vector2(0, s), c + Vector2(-s * 0.8, 0)])
		draw_colored_polygon(pts, Color("ffcf3a"))
		var o := pts.duplicate()
		o.append(pts[0])
		draw_polyline(o, Color("c8562a"), 3.0, true)
		var f := T.font(true)
		var txt := "%d מ'" % int(d)
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		draw_string_outline(f, c + Vector2(-w * 0.5, s + 20), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 5, Color(0.25, 0.13, 0.05, 0.85))
		draw_string(f, c + Vector2(-w * 0.5, s + 20), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout_direction = Control.LAYOUT_DIRECTION_RTL

	_hurt = ColorRect.new()
	_hurt.color = Color(1.0, 0.25, 0.25, 0.0)
	_hurt.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hurt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hurt)

	_marker = Marker.new()
	_marker.hud = self
	_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_marker)

	# Top-right column: hearts + coins, then the quest tracker.
	var col := T.vbox(8)
	col.anchor_left = 1.0
	col.anchor_right = 1.0
	col.offset_left = -12
	col.offset_right = -12
	col.offset_top = 12
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	var row := T.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	var hp := _pill()
	row.add_child(hp)
	_hearts_box = T.hbox(2)
	hp.add_child(_hearts_box)
	_coin_pill = _pill()
	row.add_child(_coin_pill)
	var ch := T.hbox(6)
	_coin_pill.add_child(ch)
	var coin := T.dot(T.GOLD, 24, "₪", 13)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ch.add_child(coin)
	_coins = T.label("0", 22, T.TEXT, true)
	ch.add_child(_coins)

	_quest_panel = PanelContainer.new()
	var qsb := T.box(Color(1.0, 0.97, 0.9, 0.9), 18, T.BORDER, 3, 12.0)
	_quest_panel.add_theme_stylebox_override("panel", qsb)
	_quest_panel.custom_minimum_size = Vector2(330, 0)
	_quest_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_quest_panel)
	var qv := T.vbox(2)
	_quest_panel.add_child(qv)
	_q_chapter = T.label("", 14, T.TEXT_SOFT, true)
	qv.add_child(_q_chapter)
	_q_title = T.label("", 20, T.TITLE, true)
	qv.add_child(_q_title)
	_q_obj = T.label("", 16, T.TEXT)
	_q_obj.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_q_obj.custom_minimum_size = Vector2(300, 0)
	qv.add_child(_q_obj)
	var dr := T.hbox(6)
	qv.add_child(dr)
	_arrow = Arrow.new()
	_arrow.custom_minimum_size = Vector2(26, 26)
	dr.add_child(_arrow)
	_q_dist = T.label("", 15, T.TEXT_SOFT, true)
	_q_dist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dr.add_child(_q_dist)
	var hint := T.label("Tab – יומן משימות", 13, T.TEXT_SOFT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	dr.add_child(hint)

	_timer = _pill(Color("fff0d0"))
	_timer.anchor_left = 0.5
	_timer.anchor_right = 0.5
	_timer.offset_top = 46
	_timer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_timer_label = T.label("", 22, T.TITLE, true, HORIZONTAL_ALIGNMENT_CENTER)
	_timer.add_child(_timer_label)
	_timer.visible = false
	add_child(_timer)

	_toasts = T.vbox(6)
	_toasts.anchor_left = 0.5
	_toasts.anchor_right = 0.5
	_toasts.anchor_top = 0.62
	_toasts.anchor_bottom = 0.62
	_toasts.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toasts.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toasts.alignment = BoxContainer.ALIGNMENT_END
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toasts)

	_prompt = _pill(Color(1.0, 0.97, 0.9, 0.95))
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 0.8
	_prompt.anchor_bottom = 0.8
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt_label = T.label("", 20, T.TEXT, true, HORIZONTAL_ALIGNMENT_CENTER)
	_prompt.add_child(_prompt_label)
	_prompt.visible = false
	add_child(_prompt)

	_banner = T.vbox(0)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.anchor_top = 0.24
	_banner.anchor_bottom = 0.24
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_title = T.hud_label("", 44, Color("ffd34a"))
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_title.add_theme_constant_override("outline_size", 12)
	_banner.add_child(_banner_title)
	_banner_sub = T.hud_label("", 24)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_sub)
	_banner.modulate.a = 0.0
	add_child(_banner)

	GameState.hearts_changed.connect(_on_hearts)
	GameState.coins_changed.connect(_on_coins)
	GameState.quest_changed.connect(refresh_quest)
	_on_hearts(GameState.hearts, GameState.max_hearts)
	_on_coins(GameState.coins)
	refresh_quest()


func _pill(bg := Color(1.0, 0.97, 0.9, 0.9)) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := T.box(bg, 20, T.BORDER, 3, 0.0)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	_marker.queue_redraw()
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var cam := get_viewport().get_camera_3d()
	if target != Vector3.INF and player and cam:
		var d3 := target - player.global_position
		var d := Vector2(d3.x, d3.z)
		var f3 := -cam.global_transform.basis.z
		var f := Vector2(f3.x, f3.z)
		if f.length_squared() > 1e-4 and d.length_squared() > 1e-4:
			_arrow.angle = f.angle_to(d)
		_arrow.visible = true
		_arrow.queue_redraw()
		var dist := int(d.length())
		_q_dist.text = ("%s · %d מ'" % [target_label, dist]) if target_label != "" else ("%d מ'" % dist)
		if dist < 4:
			_q_dist.text = "הגעתם!"
	else:
		_arrow.visible = false
		_q_dist.text = target_label
	var tt := ""
	if GameState.timer_left > 0.0:
		tt = "%s  %s" % [GameState.timer_label, T.fmt_time(GameState.timer_left)]
	if _challenge_text != "":
		tt = _challenge_text if tt == "" else tt + "   ·   " + _challenge_text
	_timer.visible = tt != ""
	_timer_label.text = tt
	var low := GameState.timer_left > 0.0 and GameState.timer_left < 20.0
	_timer_label.add_theme_color_override("font_color", T.HEART if low else T.TITLE)


func set_challenge_text(t: String) -> void:
	_challenge_text = t


func refresh_quest() -> void:
	var q := GameState.current_quest()
	if q.is_empty():
		if GameState.is_story_done():
			_q_chapter.text = "הסיפור הושלם"
			_q_title.text = "גיבור רמת פריקסה!"
			_q_obj.text = "אתגרים: צ'יפס זהוב, מרוץ משלוחים, זירת העגבניות וכובעים"
			_quest_panel.visible = true
		else:
			_quest_panel.visible = false
		return
	_quest_panel.visible = true
	_q_chapter.text = "%s · %s" % [str(q.get("act", "")), str(q.get("chapter", ""))]
	_q_title.text = str(q.get("title", ""))
	_q_obj.text = "◆ " + GameState.objective_text()
	var tw := create_tween()
	_quest_panel.pivot_offset = _quest_panel.size * Vector2(1.0, 0.0)
	tw.tween_property(_quest_panel, "scale", Vector2(1.04, 1.04), 0.08)
	tw.tween_property(_quest_panel, "scale", Vector2.ONE, 0.15)


func _on_hearts(h: int, mh: int) -> void:
	while _hearts.size() < mh:
		var l := T.hud_label("♥", 26, T.HEART)
		l.add_theme_constant_override("outline_size", 5)
		_hearts_box.add_child(l)
		_hearts.append(l)
	for i in _hearts.size():
		var l: Label = _hearts[i]
		l.visible = i < mh
		l.add_theme_color_override("font_color", T.HEART if i < h else Color(0.75, 0.68, 0.62, 0.7))
	if _last_hearts >= 0 and h != _last_hearts:
		var idx := clampi(mini(h, _last_hearts), 0, _hearts.size() - 1)
		var l: Label = _hearts[idx]
		l.pivot_offset = l.size * 0.5
		var tw := create_tween()
		tw.tween_property(l, "scale", Vector2(1.6, 1.6), 0.08)
		tw.tween_property(l, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK)
		if h < _last_hearts:
			flash_hurt()
	_last_hearts = h


func _on_coins(c: int) -> void:
	_coins.text = str(c)
	_coin_pill.pivot_offset = _coin_pill.size * 0.5
	var tw := create_tween()
	tw.tween_property(_coin_pill, "scale", Vector2(1.12, 1.12), 0.07)
	tw.tween_property(_coin_pill, "scale", Vector2.ONE, 0.15)


func flash_hurt() -> void:
	var tw := create_tween()
	_hurt.color.a = 0.35
	tw.tween_property(_hurt, "color:a", 0.0, 0.45)


func set_prompt(text: String) -> void:
	_prompt.visible = text != ""
	_prompt_label.text = text


func toast(text: String, seconds := 3.0) -> void:
	if text == "":
		return
	while _toasts.get_child_count() >= 3:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	var p := _pill(Color(0.29, 0.2, 0.13, 0.82))
	var l := T.label(text, 19, Color("fff3dc"), true, HORIZONTAL_ALIGNMENT_CENTER)
	p.add_child(l)
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_toasts.add_child(p)
	p.modulate.a = 0.0
	var tw := p.create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.15)
	tw.tween_interval(seconds)
	tw.tween_property(p, "modulate:a", 0.0, 0.5)
	tw.tween_callback(p.queue_free)


func banner(title: String, sub := "", seconds := 3.0) -> void:
	_banner_title.text = title
	_banner_sub.text = sub
	_banner.pivot_offset = _banner.size * 0.5
	var tw := create_tween()
	_banner.modulate.a = 0.0
	_banner.scale = Vector2(0.6, 0.6)
	tw.set_parallel(true)
	tw.tween_property(_banner, "modulate:a", 1.0, 0.25)
	tw.tween_property(_banner, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.set_parallel(false)
	tw.tween_interval(seconds)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.6)
