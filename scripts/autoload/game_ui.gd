extends CanvasLayer
## Game interface. Other systems call only these methods; the widgets live in
## scripts/ui/ (game_hud, dialogue_box, shop_window, inventory_window, quest_log).
##   I = inventory, Tab = quest log, Esc = close, E / Space / click = next line.

signal dialogue_finished(speaker: String)

const HUD := preload("res://scripts/ui/game_hud.gd")
const DIALOGUE := preload("res://scripts/ui/dialogue_box.gd")
const SHOP := preload("res://scripts/ui/shop_window.gd")
const INVENTORY := preload("res://scripts/ui/inventory_window.gd")
const QUEST_LOG := preload("res://scripts/ui/quest_log.gd")

var hud: Control
var _dialogue: Control
var _shop: Control
var _inventory: Control
var _quest_log: Control
var _queue: Array = []  # [speaker, lines, on_done]
var _on_done := Callable()
var _mouse_was_captured := false
var _quiet := false  # unattended test runs: no HUD in screenshots


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	_quiet = ("--shots" in args or "--benchmark" in args or "--test-story" in args) and not "--with-ui" in args
	hud = HUD.new()
	add_child(hud)
	_fill(hud)
	_dialogue = _add_hidden(DIALOGUE.new())
	_dialogue.finished.connect(_dialogue_done)
	_shop = _add_hidden(SHOP.new())
	_shop.closed.connect(_close.bind(_shop))
	_inventory = _add_hidden(INVENTORY.new())
	_inventory.closed.connect(_close.bind(_inventory))
	_quest_log = _add_hidden(QUEST_LOG.new())
	_quest_log.closed.connect(_close.bind(_quest_log))
	visible = not _quiet
	GameState.story_message.connect(show_dialogue)
	GameState.quest_completed.connect(_on_quest_completed)
	GameState.hearts_changed.connect(_on_hearts)
	GameState.game_event.connect(_on_event)


func _add_hidden(c: Control) -> Control:
	c.visible = false
	add_child(c)
	_fill(c)
	return c


## Full-screen root. Set explicitly: a preset applied in the widget's own
## _ready under RTL layout leaves it zero-sized in the corner.
func _fill(c: Control) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0


## Shows a dialogue box. lines: Array of Strings (or {"text", "choices"}).
## Locks input until closed, then calls on_done and emits dialogue_finished.
## Dialogues requested while one is open are queued.
func show_dialogue(speaker: String, lines: Array, on_done := Callable()) -> void:
	if lines.is_empty():
		if on_done.is_valid():
			on_done.call()
		return
	if _quiet:
		dialogue_finished.emit(speaker)
		if on_done.is_valid():
			on_done.call()
		return
	if _dialogue.visible:
		_queue.append([speaker, lines, on_done])
		return
	_on_done = on_done
	_dialogue.visible = true
	_dialogue.start(speaker, lines)
	_refresh_modal()


func _dialogue_done() -> void:
	var spk: String = _dialogue.speaker
	var cb := _on_done
	_on_done = Callable()
	_dialogue.visible = false
	_refresh_modal()
	dialogue_finished.emit(spk)
	if cb.is_valid():
		cb.call()
	if not _queue.is_empty() and not _dialogue.visible:
		var next: Array = _queue.pop_front()
		show_dialogue(next[0], next[1], next[2])


## Opens the shop window for a building type (items come from data/items.json).
func open_shop(shop_type: String, shop_name: String) -> void:
	if not GameState.shops.has(shop_type):
		toast("החנות סגורה כרגע")
		return
	_close_windows()
	_shop.visible = true
	_shop.open(shop_type, shop_name)
	_refresh_modal()


func toast(text: String) -> void:
	if hud:
		hud.toast(text)


func banner(title: String, sub := "", seconds := 3.0) -> void:
	if hud:
		hud.banner(title, sub, seconds)


## Interaction prompt near the player ("" hides it).
func set_prompt(text: String) -> void:
	if hud:
		hud.set_prompt(text)


## True while any modal window (dialogue, shop, menu) is open.
func is_modal_open() -> bool:
	return _dialogue.visible or _shop.visible or _inventory.visible or _quest_log.visible


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).physical_keycode
	if _dialogue.visible:
		match k:
			KEY_E, KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
				_dialogue.advance()
			KEY_ESCAPE:
				_dialogue.skip_all()
			KEY_1, KEY_2, KEY_3:
				_dialogue.choose_index(k - KEY_1)
		get_viewport().set_input_as_handled()
		return
	match k:
		KEY_ESCAPE:
			if _shop.visible or _inventory.visible or _quest_log.visible:
				_close_windows()
				get_viewport().set_input_as_handled()
		KEY_I:
			_toggle(_inventory)
			get_viewport().set_input_as_handled()
		KEY_TAB:
			_toggle(_quest_log)
			get_viewport().set_input_as_handled()


func _toggle(w: Control) -> void:
	var open := not w.visible
	_close_windows()
	if open:
		w.visible = true
		if w.has_method("refresh"):
			w.refresh()
	_refresh_modal()


func _close(w: Control) -> void:
	w.visible = false
	_refresh_modal()


func _close_windows() -> void:
	for w in [_shop, _inventory, _quest_log]:
		w.visible = false
	_refresh_modal()


func _refresh_modal() -> void:
	var modal := is_modal_open()
	GameState.set_lock("ui", modal)
	hud.visible = not _dialogue.visible
	if modal and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_was_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not modal and _mouse_was_captured:
		_mouse_was_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_quest_completed(q: Dictionary) -> void:
	var coins := int(q.get("coins", 0))
	banner("✓ " + str(q.get("title", "")), ("+%d מטבעות" % coins) if coins > 0 else "", 3.0)
	if GameState.is_story_done():
		var credits := str(GameState.story.get("credits", ""))
		if credits != "":
			show_dialogue("קריין", [credits])


func _on_hearts(h: int, _mh: int) -> void:
	if h > 0 or not GameState.started:
		return
	# Out of hearts: a soft, funny "faint" – back on your feet at full hearts.
	toast("אוי! טוטו התעלף לרגע… והתאושש עם כל הלבבות")
	GameState.heal(GameState.max_hearts)
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and has_node("/root/Effects"):
		Effects.puff(player.global_position + Vector3(0, 1.0, 0), "sparkle", 10)


func _on_event(name: String, _data: Dictionary) -> void:
	if name.begins_with("chapter:"):
		var q := GameState.current_quest()
		banner(str(q.get("chapter", "")), str(q.get("title", "")), 3.0)
