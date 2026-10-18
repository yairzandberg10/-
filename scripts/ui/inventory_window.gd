extends Control
## Inventory (I): food heals, hats are worn, fun items do silly things,
## story items are just carried.

const T = preload("res://scripts/ui/ui_theme.gd")
const ORDER := ["food", "hat", "fun", "story"]

signal closed

var _grid: GridContainer
var _msg: Label
var _hearts: Label
var _coins: Label
var _empty: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var win := T.window(Vector2(760, 540))
	add_child(win)
	var v := T.vbox(10)
	win.add_child(v)
	var head := T.hbox(12)
	v.add_child(head)
	var t := T.label("התיק של טוטו", 30, T.TITLE, true)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	_hearts = T.label("", 22, T.HEART, true)
	head.add_child(_hearts)
	var coin := T.dot(T.GOLD, 26, "₪", 14)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(coin)
	_coins = T.label("", 22, T.TEXT, true)
	head.add_child(_coins)
	v.add_child(T.sep_line())
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 360)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	var inner := T.vbox(6)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)
	_empty = T.label("התיק ריק. אפשר לקנות דברים בחנויות!", 18, T.TEXT_SOFT, false, HORIZONTAL_ALIGNMENT_CENTER)
	inner.add_child(_empty)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_grid)
	var foot := T.hbox(10)
	v.add_child(foot)
	_msg = T.label("", 17, T.TEXT_SOFT, true)
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_msg)
	foot.add_child(T.button("סגירה (I)", func(): closed.emit(), 150))
	GameState.inventory_changed.connect(func(): if visible: refresh())
	GameState.hat_changed.connect(func(_h): if visible: refresh())


func refresh() -> void:
	_hearts.text = "♥ %d/%d" % [GameState.hearts, GameState.max_hearts]
	_coins.text = str(GameState.coins)
	for c in _grid.get_children():
		c.queue_free()
	var ids := GameState.inventory.keys()
	ids.sort_custom(func(a, b):
		var ka := ORDER.find(str(GameState.get_item(a).get("kind", "story")))
		var kb := ORDER.find(str(GameState.get_item(b).get("kind", "story")))
		return ka < kb if ka != kb else str(a) < str(b))
	for id in ids:
		_grid.add_child(_card(str(id)))
	_empty.visible = ids.is_empty()


func _card(id: String) -> Control:
	var it := GameState.get_item(id)
	var kind := str(it.get("kind", "story"))
	var card := PanelContainer.new()
	var worn := id == GameState.equipped_hat
	card.add_theme_stylebox_override("panel", T.box(Color("fff3d6") if worn else Color("fffaf0"), 16, T.ACCENT if worn else T.CREAM_DARK, 3 if worn else 2, 10.0))
	card.custom_minimum_size = Vector2(225, 150)
	var v := T.vbox(4)
	card.add_child(v)
	var h := T.hbox(8)
	v.add_child(h)
	h.add_child(T.dot(Color(str(it.get("color", "#cccccc"))), 38, str(it.get("name", id)).substr(0, 1), 17))
	var n := T.label(str(it.get("name", id)), 17, T.TEXT, true)
	n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.custom_minimum_size = Vector2(120, 0)
	h.add_child(n)
	var cnt := int(GameState.inventory.get(id, 0))
	if cnt > 1:
		h.add_child(T.label("×%d" % cnt, 18, T.ACCENT, true))
	var tag := str(GameState.item_db.get(id, {}).get("kind", ""))
	var kinds := {"food": "אוכל", "hat": "כובע", "fun": "כיף", "story": "חפץ סיפור"}
	var d := T.label("%s · %s" % [kinds.get(tag, ""), str(it.get("desc", ""))], 13, T.TEXT_SOFT)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(200, 0)
	d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(d)
	var label := ""
	match kind:
		"food": label = "לאכול"
		"hat": label = "להוריד" if worn else "לחבוש"
		"fun": label = "להשתמש"
	if label != "":
		var b := T.button(label, use.bind(id))
		b.custom_minimum_size = Vector2(0, 38)
		b.add_theme_font_size_override("font_size", 16)
		v.add_child(b)
	return card


func use(id: String) -> void:
	var m := GameState.use_item(id)
	if m != "":
		_msg.text = m
	refresh()
	# Fun items happen in the world: close so the player can see them.
	if str(GameState.get_item(id).get("kind", "")) == "fun":
		closed.emit()
