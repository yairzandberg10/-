extends Control
## Shop window: the items a shop type sells (data/items.json "shops").

const T = preload("res://scripts/ui/ui_theme.gd")

signal closed

var shop_type := ""
var _win: PanelContainer
var _title: Label
var _coins: Label
var _list: VBoxContainer
var _msg: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_win = T.window(Vector2(660, 520))
	add_child(_win)
	var v := T.vbox(10)
	_win.add_child(v)
	var head := T.hbox(10)
	v.add_child(head)
	_title = T.label("", 30, T.TITLE, true)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var coin := T.dot(T.GOLD, 26, "₪", 14)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(coin)
	_coins = T.label("", 24, T.TEXT, true)
	head.add_child(_coins)
	v.add_child(T.sep_line())
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 340)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)
	_list = T.vbox(8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_list)
	var foot := T.hbox(10)
	v.add_child(foot)
	_msg = T.label("", 17, T.TEXT_SOFT, true)
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_msg)
	foot.add_child(T.button("סגירה (Esc)", func(): closed.emit(), 150))
	GameState.coins_changed.connect(func(_c): if visible: _refresh())


func open(type: String, shop_name: String) -> void:
	shop_type = type
	_title.text = shop_name if shop_name != "" else "חנות"
	_msg.text = "ברוכים הבאים! מה תרצו?"
	_refresh()


func item_ids() -> Array:
	var shops := GameState.shops
	return shops.get(shop_type, shops.get("default", []))


func _refresh() -> void:
	_coins.text = str(GameState.coins)
	for c in _list.get_children():
		c.queue_free()
	for id in item_ids():
		var it := GameState.get_item(str(id))
		if it.is_empty():
			continue
		_list.add_child(_row(str(id), it))


func _row(id: String, it: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", T.box(Color("fffaf0"), 16, T.CREAM_DARK, 2, 10.0))
	var h := T.hbox(12)
	card.add_child(h)
	var icon := T.dot(Color(str(it.get("color", "#cccccc"))), 46, _kind_letter(it), 20)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(icon)
	var col := T.vbox(0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)
	col.add_child(T.label(str(it.get("name", id)), 20, T.TEXT, true))
	var d := T.label(str(it.get("desc", "")), 15, T.TEXT_SOFT)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(330, 0)
	col.add_child(d)
	var price := int(it.get("price", 0))
	var pr := T.hbox(4)
	pr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var pc := T.dot(T.GOLD, 20, "₪", 11)
	pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pr.add_child(pc)
	pr.add_child(T.label(str(price), 20, T.TEXT, true))
	h.add_child(pr)
	var owned := str(it.get("kind", "")) == "hat" and GameState.has_item(id)
	var b := T.button("בבעלותך" if owned else "קנייה", buy.bind(id), 110)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.disabled = owned or GameState.coins < price
	h.add_child(b)
	return card


func _kind_letter(it: Dictionary) -> String:
	return str(it.get("name", "?")).substr(0, 1)


func buy(id: String) -> bool:
	var it := GameState.get_item(id)
	var price := int(it.get("price", 0))
	if not GameState.spend_coins(price):
		_msg.text = "אין מספיק מטבעות... עגבניות מפילות מטבעות!"
		return false
	GameState.add_item(id)
	GameState.emit_event("buy:" + id, {"price": price, "shop": shop_type})
	_msg.text = "קנית: %s. תתחדשו!" % str(it.get("name", id))
	if str(it.get("kind", "")) == "hat" and GameState.equipped_hat != id:
		GameState.equip_hat(id)
	_refresh()
	return true
