extends Control
## Quest log (Tab): the current chapter, the story so far, and challenge records.

const T = preload("res://scripts/ui/ui_theme.gd")

signal closed

var _body: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var win := T.window(Vector2(820, 560))
	add_child(win)
	var v := T.vbox(10)
	win.add_child(v)
	v.add_child(T.title_row("יומן המשימות"))
	v.add_child(T.sep_line())
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 410)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var row := T.hbox(16)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(row)
	_body = T.vbox(8)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_body)
	var foot := T.hbox(10)
	foot.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(foot)
	foot.add_child(T.button("סגירה (Tab)", func(): closed.emit(), 150))


func refresh() -> void:
	for c in _body.get_children():
		c.queue_free()
	var q := GameState.current_quest()
	var cols := T.hbox(16)
	_body.add_child(cols)
	# Right column: current quest + story list.
	var left := T.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.4
	cols.add_child(left)
	var cur := PanelContainer.new()
	cur.add_theme_stylebox_override("panel", T.box(Color("fff0d2"), 18, T.ACCENT, 3, 14.0))
	left.add_child(cur)
	var cv := T.vbox(4)
	cur.add_child(cv)
	if q.is_empty():
		cv.add_child(T.label("הסיפור הושלם!", 24, T.TITLE, true))
		var won := T.label("טוטו הוא גיבור רמת פריקסה. אפשר להמשיך באתגרים ולאסוף כובעים.", 17)
		won.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cv.add_child(won)
	else:
		cv.add_child(T.label("%s · %s" % [q.get("act", ""), q.get("chapter", "")], 15, T.TEXT_SOFT, true))
		cv.add_child(T.label(str(q.get("title", "")), 26, T.TITLE, true))
		var s := T.label(str(q.get("summary", "")), 16)
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.custom_minimum_size = Vector2(400, 0)
		cv.add_child(s)
		var o := T.label("◆ " + GameState.objective_text(), 18, T.TEXT, true)
		o.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		o.custom_minimum_size = Vector2(400, 0)
		cv.add_child(o)
	left.add_child(T.label("הסיפור עד עכשיו", 20, T.TITLE, true))
	var qs := GameState.quests()
	var shown := 0
	for i in qs.size():
		var qq: Dictionary = qs[i]
		var txt := ""
		var col := T.TEXT
		if i < GameState.quest_index:
			txt = "✓  %s – %s" % [qq.get("chapter", ""), qq.get("title", "")]
			col = Color("4f9a3e")
		elif i == GameState.quest_index:
			txt = "◆  %s – %s" % [qq.get("chapter", ""), qq.get("title", "")]
			col = T.ACCENT
		else:
			txt = "?  %s – ???" % qq.get("chapter", "")
			col = Color("b5a58f")
		left.add_child(T.label(txt, 16, col, i == GameState.quest_index))
		shown += 1
	# Left column: challenges.
	var right := T.vbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(T.label("אתגרים ושיאים", 20, T.TITLE, true))
	var chs: Dictionary = GameState.story.get("challenges", {})
	for id in ["chips", "delivery", "hunt", "hats"]:
		var c: Dictionary = chs.get(id, {})
		if c.is_empty():
			continue
		right.add_child(_challenge_card(id, c))


func _challenge_card(id: String, c: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", T.box(Color("fffaf0"), 16, T.CREAM_DARK, 2, 10.0))
	var v := T.vbox(2)
	card.add_child(v)
	var rec := GameState.challenge(id)
	var status := ""
	match id:
		"chips":
			status = "נמצאו %d/%d" % [(rec.get("found", []) as Array).size(), int(c.get("count", 12))]
		"delivery":
			var best := float(rec.get("best", 0.0))
			status = ("שיא: " + T.fmt_time(best)) if best > 0.0 else "עוד אין שיא"
			if not GameState.flags.has(str(c.get("requires", ""))):
				status = "ייפתח בהמשך הסיפור"
		"hunt":
			var b := int(rec.get("best", 0))
			status = ("שיא: %d עגבניות" % b) if b > 0 else "עוד אין שיא"
			if not GameState.flags.has(str(c.get("requires", ""))):
				status = "ייפתח אחרי שתקבלו את הבגט"
		"hats":
			var total := 0
			var have := 0
			for iid in GameState.item_db:
				if str(GameState.item_db[iid].get("kind", "")) == "hat":
					total += 1
					if GameState.has_item(iid):
						have += 1
			status = "%d/%d כובעים" % [have, total]
	var h := T.hbox(6)
	v.add_child(h)
	var n := T.label(str(c.get("title", id)), 17, T.TEXT, true)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(n)
	h.add_child(T.label(status, 15, T.ACCENT, true))
	var d := T.label(str(c.get("desc", "")), 13, T.TEXT_SOFT)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(280, 0)
	v.add_child(d)
	return card
