extends Node
## Player progress shared by every gameplay system (OWNER: agent C – story/combat/UI).
## Other systems only use the public API below; keep these signatures stable.
##
## Event names (emit_event) – the contract between systems:
##   "talk:<npc_id>"          dialogue with a named NPC finished        (NPC system)
##   "enter:<building_type>"  player entered a building interior        (interior system)
##   "enter_id:<object_id>"   same, by CityData object id               (interior system)
##   "exit_interior"          player left an interior                   (interior system)
##   "buy:<item_id>"          item bought in a shop                      (shop UI)
##   "pickup:<item_id>"       collectible picked up                      (story system)
##   "defeat:<enemy_type>"    enemy defeated ("tomato" / "boss")         (combat system)
##   "reach:<place>"          player reached a story place               (story system)
##   "rescue:<object_id>"     knocked on a neighbour's door              (story system)
##   "lever:<n>"              pulled a workshop lever                    (story system)
##   "machine:start"          started Friksa's machine                   (story system)
##   "use:<effect>"           used a fun item (confetti, whistle, ...)   (inventory UI)
##
## The story itself (quests, steps, dialogue) is data: res://data/story.json.
## Progress is saved to user://progress.json (autosave a moment after every change and on quit).

signal coins_changed(coins: int)
signal hearts_changed(hearts: int, max_hearts: int)
signal inventory_changed
signal game_event(name: String, data: Dictionary)
## Story progress moved (new step, new quest, counter changed, new game, load).
signal quest_changed
## A quest was completed (for banners / rewards).
signal quest_completed(quest: Dictionary)
## The story wants to say something that is not an NPC conversation (intro, narration).
signal story_message(speaker: String, lines: Array)
signal hat_changed(hat_id: String)
signal challenges_changed
signal progress_reset

const STORY_PATH := "res://data/story.json"
const ITEMS_PATH := "res://data/items.json"
const NAV_PREFIXES := ["enter:", "enter_id:", "reach:"]

var coins := 0
var hearts := 5
var max_hearts := 5
var inventory: Dictionary = {}  # item_id -> count
var flags: Dictionary = {}      # free-form story flags
## True while a menu/dialogue is open: player movement and attacks are ignored.
var input_locked := false

var story: Dictionary = {}
var item_db: Dictionary = {}
var shops: Dictionary = {}
var started := false
var quest_index := 0
var step_index := 0
var step_count := 0
var step_done: Array = []
var completed: Array = []
var challenges: Dictionary = {}
var equipped_hat := ""
var play_time := 0.0
## Quest timer (e.g. the hot burekas delivery). 0 = no timer.
var timer_left := 0.0
var timer_label := ""
var last_defeat_pos := Vector3.INF

var save_path := "user://progress.json"
var autosave_enabled := true

var _locks: Dictionary = {}
var _dirty := false
var _save_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	story = _read_json(STORY_PATH)
	var it := _read_json(ITEMS_PATH)
	item_db = it.get("items", {})
	shops = it.get("shops", {})
	var args := OS.get_cmdline_user_args()
	if "--smoke" in args or "--shots" in args or "--benchmark" in args or "--test-story" in args:
		# Unattended runs never touch the player's real progress.
		save_path = "user://test_progress.json"
		DirAccess.remove_absolute(save_path)
		_reset_values()
		started = true
	elif not load_progress():
		_reset_values()


func _process(delta: float) -> void:
	if started and not get_tree().paused:
		play_time += delta
	if timer_left > 0.0 and not _ui_busy():
		timer_left -= delta
		if timer_left <= 0.0:
			timer_left = 0.0
			_timer_failed()
	if _dirty:
		_save_left -= delta
		if _save_left <= 0.0:
			save_progress()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_progress()


# ------------------------------------------------------------------ basics

func add_coins(n: int) -> void:
	coins = maxi(coins + n, 0)
	coins_changed.emit(coins)
	_mark_dirty()


func spend_coins(n: int) -> bool:
	if coins < n:
		return false
	add_coins(-n)
	return true


func add_item(item_id: String, n := 1) -> void:
	inventory[item_id] = int(inventory.get(item_id, 0)) + n
	inventory_changed.emit()
	_mark_dirty()


func remove_item(item_id: String, n := 1) -> void:
	var left := int(inventory.get(item_id, 0)) - n
	if left > 0:
		inventory[item_id] = left
	else:
		inventory.erase(item_id)
	if item_id == equipped_hat and left <= 0:
		equip_hat("")
	inventory_changed.emit()
	_mark_dirty()


func has_item(item_id: String, n := 1) -> bool:
	return int(inventory.get(item_id, 0)) >= n


func damage(n := 1) -> void:
	hearts = maxi(hearts - n, 0)
	hearts_changed.emit(hearts, max_hearts)
	_mark_dirty()


func heal(n := 1) -> void:
	hearts = mini(hearts + n, max_hearts)
	hearts_changed.emit(hearts, max_hearts)
	_mark_dirty()


func set_flag(key: String, value: Variant = true) -> void:
	flags[key] = value
	_mark_dirty()


func get_item(item_id: String) -> Dictionary:
	return item_db.get(item_id, {})


func item_name(item_id: String) -> String:
	return str(get_item(item_id).get("name", item_id))


func equip_hat(hat_id: String) -> void:
	if equipped_hat == hat_id:
		hat_id = ""  # toggling the same hat takes it off
	equipped_hat = hat_id
	hat_changed.emit(hat_id)
	_mark_dirty()


## Inventory "use" button. Returns a short message for the UI.
func use_item(item_id: String) -> String:
	if not has_item(item_id):
		return ""
	var it := get_item(item_id)
	match str(it.get("kind", "")):
		"food":
			if hearts >= max_hearts:
				return "הבטן מלאה! כל הלבבות כבר מלאים"
			heal(int(it.get("heal", 1)))
			remove_item(item_id)
			emit_event("use:eat", {"item": item_id})
			return "יאמי! %s" % item_name(item_id)
		"hat":
			equip_hat(item_id)
			return ("חבשת: " + item_name(item_id)) if equipped_hat == item_id else "הורדת את הכובע"
		"fun":
			if not bool(it.get("keep", false)):
				remove_item(item_id)
			emit_event("use:" + str(it.get("use", item_id)), {"item": item_id})
			return ""
	return str(it.get("desc", ""))


## Locks player input for a named reason (menus, dizzy...). Input stays locked
## while any reason is active.
func set_lock(reason: String, on: bool) -> void:
	if on:
		_locks[reason] = true
	else:
		_locks.erase(reason)
	input_locked = not _locks.is_empty()


func emit_event(name: String, data := {}) -> void:
	if name.begins_with("defeat:") and data.has("pos"):
		last_defeat_pos = data["pos"]
	game_event.emit(name, data)
	if started:
		_story_event(name, data)


## Story hook for NPCs: returns {"lines": [...], "speaker": "..."} when the story
## wants to override what `npc_id` says right now, otherwise {}.
## Lines are Strings, or {"text": ..., "choices": [{"text": ..., "reply": ...}]}.
func get_story_dialogue(npc_id: String) -> Dictionary:
	if not started:
		return {}
	var q := current_quest()
	if not q.is_empty():
		var steps: Array = q.get("steps", [])
		for k in range(step_index, steps.size()):
			var st: Dictionary = steps[k]
			var ev := "talk:" + npc_id
			if _step_accepts(st, ev, k == step_index):
				var say: Dictionary = st.get("say", {}).get(npc_id, {})
				if not say.is_empty():
					return {"speaker": str(say.get("speaker", npc_name(npc_id))), "lines": say.get("lines", [])}
			if not _is_nav(st):
				break
	var ch: Dictionary = story.get("chatter", {}).get(npc_id, {})
	if is_story_done() and ch.has("done"):
		return {"speaker": npc_name(npc_id), "lines": ch["done"]}
	if not q.is_empty() and ch.has(str(q.get("id", ""))):
		return {"speaker": npc_name(npc_id), "lines": ch[str(q["id"])]}
	if ch.has("default") and not is_story_done():
		return {"speaker": npc_name(npc_id), "lines": ch["default"]}
	return {}


func npc_name(npc_id: String) -> String:
	return str(story.get("npc_names", {}).get(npc_id, npc_id))


# ------------------------------------------------------------------ story

func quests() -> Array:
	return story.get("quests", [])


func current_quest() -> Dictionary:
	var qs := quests()
	if not started or quest_index >= qs.size():
		return {}
	return qs[quest_index]


func current_step() -> Dictionary:
	var q := current_quest()
	var steps: Array = q.get("steps", [])
	if step_index >= steps.size():
		return {}
	return steps[step_index]


func is_story_done() -> bool:
	return started and quest_index >= quests().size()


func is_quest_done(quest_id: String) -> bool:
	return completed.has(quest_id)


## "גרשו את העגבניות (2/3)"
func objective_text() -> String:
	var st := current_step()
	if st.is_empty():
		return ""
	var t := str(st.get("text", ""))
	var need := step_need(st)
	if need > 1:
		t += "  (%d/%d)" % [step_count, need]
	return t


func step_need(st: Dictionary) -> int:
	if st.has("all"):
		return (st["all"] as Array).size()
	return int(st.get("count", 1))


## The targets the marker should point at: [{"npc": ...} / {"building": ...} / {"place": ...}].
func current_targets() -> Array:
	var st := current_step()
	if st.is_empty():
		return []
	if st.has("all"):
		var out := []
		for ev in st["all"]:
			if not step_done.has(ev):
				out.append(st.get("targets", {}).get(ev, {}))
		return out
	return [st.get("target", {})]


## Resolves "$home" etc. in event names.
func resolve_event(ev: String) -> String:
	return ev.replace("$home", str(flags.get("home_id", "")))


func _is_nav(st: Dictionary) -> bool:
	var evs: Array = st.get("any", [st.get("event", "")])
	for ev in evs:
		for p in NAV_PREFIXES:
			if str(ev).begins_with(p):
				return true
	return false


## True when `ev` advances step `st`.
func _step_accepts(st: Dictionary, ev: String, is_current: bool) -> bool:
	if st.has("all"):
		if not is_current or step_done.has(ev) or not (st["all"] as Array).has(ev):
			return false
		return not st.has("requires") or has_item(str(st["requires"]))
	if st.has("any"):
		for a in st["any"]:
			if resolve_event(str(a)) == ev:
				return true
		return false
	var want := resolve_event(str(st.get("event", "")))
	if want.contains(":"):
		return want == ev
	# Prefix steps ("rescue", "lever") count each distinct target once.
	return ev.begins_with(want + ":") and not (is_current and step_done.has(ev))


func _story_event(ev: String, _data: Dictionary) -> void:
	var q := current_quest()
	if q.is_empty():
		return
	var steps: Array = q.get("steps", [])
	for k in range(step_index, steps.size()):
		var st: Dictionary = steps[k]
		if _step_accepts(st, ev, k == step_index):
			# Skip navigation steps the player bypassed (e.g. already inside).
			while step_index < k:
				_complete_step(false)
			_advance_counter(st, ev)
			return
		if not _is_nav(st):
			return


func _advance_counter(st: Dictionary, ev: String) -> void:
	if st.has("all") or not str(st.get("event", ":")).contains(":"):
		step_done.append(ev)
	if st.has("requires"):
		remove_item(str(st["requires"]))
	step_count += 1
	if step_count >= step_need(st):
		_complete_step(true)
	else:
		quest_changed.emit()
		_mark_dirty()


func _complete_step(with_after: bool) -> void:
	var q := current_quest()
	var st := current_step()
	for id in st.get("take", {}):
		remove_item(str(id), int(st["take"][id]))
	for id in st.get("give", {}):
		add_item(str(id), int(st["give"][id]))
		var it := get_item(str(id))
		if not it.is_empty():
			_toast("קיבלת: %s" % item_name(str(id)))
	if st.has("flag"):
		flags[str(st["flag"])] = true
	if st.get("clear_timer", false):
		timer_left = 0.0
	if st.has("timer"):
		timer_left = float(st["timer"].get("seconds", 120))
		timer_label = str(st["timer"].get("label", ""))
	if st.has("night"):
		flags["time_of_day"] = float(st["night"])
		_apply_time(float(st["night"]))
	step_index += 1
	step_count = 0
	step_done.clear()
	if with_after and st.has("after"):
		story_message.emit(str(st["after"].get("speaker", "")), st["after"].get("lines", []))
	if step_index >= (q.get("steps", []) as Array).size():
		_complete_quest(q)
	quest_changed.emit()
	_mark_dirty()


func _complete_quest(q: Dictionary) -> void:
	completed.append(str(q.get("id", "")))
	flags[str(q.get("id", ""))] = true
	add_coins(int(q.get("coins", 0)))
	quest_index += 1
	step_index = 0
	step_count = 0
	step_done.clear()
	quest_completed.emit(q)
	game_event.emit("quest_complete:" + str(q.get("id", "")), {})
	var nq := current_quest()
	if nq.is_empty():
		flags["story_done"] = true
		return
	game_event.emit("chapter:%d" % (quest_index + 1), {"quest": str(nq.get("id", ""))})
	flags.erase("time_of_day")
	_apply_quest_time()
	if nq.has("intro"):
		story_message.emit(str(nq["intro"].get("speaker", "")), nq["intro"].get("lines", []))


func _timer_failed() -> void:
	var st := current_step()
	if st.is_empty():
		return
	if st.has("fail_to"):
		if st.has("requires"):
			remove_item(str(st["requires"]), int(inventory.get(str(st["requires"]), 0)))
		step_index = int(st["fail_to"])
		step_count = 0
		step_done.clear()
		_toast(str(st.get("fail_text", "נגמר הזמן!")))
		quest_changed.emit()
		_mark_dirty()


## Moves the sun to the hour the current chapter happens at.
func _apply_quest_time() -> void:
	if flags.has("time_of_day"):
		_apply_time(float(flags["time_of_day"]))
		return
	var q := current_quest()
	if q.has("time"):
		_apply_time(float(q["time"]))


func _apply_time(h: float) -> void:
	var main := get_tree().get_first_node_in_group("main")
	if main and main.has_method("set_time_of_day"):
		main.set_time_of_day(h)


func apply_world_state() -> void:
	_apply_quest_time()


func _toast(text: String) -> void:
	var ui := get_node_or_null("/root/GameUI")
	if ui:
		ui.toast(text)


func _ui_busy() -> bool:
	var ui := get_node_or_null("/root/GameUI")
	return ui != null and ui.is_modal_open()


# ------------------------------------------------------------------ challenges

func challenge(id: String) -> Dictionary:
	if not challenges.has(id):
		challenges[id] = {}
	return challenges[id]


func set_record(id: String, key: String, value: Variant) -> void:
	challenge(id)[key] = value
	challenges_changed.emit()
	_mark_dirty()


# ------------------------------------------------------------------ save / load

func has_save() -> bool:
	return FileAccess.file_exists(save_path)


func new_game() -> void:
	_reset_values()
	started = true
	progress_reset.emit()
	coins_changed.emit(coins)
	hearts_changed.emit(hearts, max_hearts)
	inventory_changed.emit()
	hat_changed.emit(equipped_hat)
	challenges_changed.emit()
	quest_changed.emit()
	_apply_quest_time()
	var intro: Dictionary = story.get("intro", {})
	if not intro.is_empty():
		story_message.emit(str(intro.get("speaker", "")), intro.get("lines", []))
	save_progress()


func _reset_values() -> void:
	coins = int(story.get("start_coins", 15))
	max_hearts = 5
	hearts = max_hearts
	inventory = {}
	flags = {}
	started = false
	quest_index = 0
	step_index = 0
	step_count = 0
	step_done = []
	completed = []
	challenges = {}
	equipped_hat = ""
	play_time = 0.0
	timer_left = 0.0
	timer_label = ""


func save_progress() -> bool:
	_dirty = false
	if not autosave_enabled or not started:
		return false
	var data := {
		"version": 1, "saved_at": Time.get_datetime_string_from_system(),
		"coins": coins, "hearts": hearts, "max_hearts": max_hearts,
		"inventory": inventory, "flags": flags, "quest_index": quest_index,
		"step_index": step_index, "step_count": step_count, "step_done": step_done,
		"completed": completed, "challenges": challenges, "hat": equipped_hat,
		"play_time": snappedf(play_time, 0.1), "timer_left": snappedf(timer_left, 0.1),
		"timer_label": timer_label,
	}
	var tmp := save_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("GameState: cannot write " + tmp)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	DirAccess.rename_absolute(tmp, save_path)
	return true


func load_progress() -> bool:
	if not FileAccess.file_exists(save_path):
		return false
	var d := _read_json(save_path)
	if d.is_empty():
		return false
	_reset_values()
	started = true
	coins = int(d.get("coins", coins))
	max_hearts = int(d.get("max_hearts", 5))
	hearts = clampi(int(d.get("hearts", max_hearts)), 1, max_hearts)
	for k in d.get("inventory", {}):
		inventory[str(k)] = int(d["inventory"][k])
	flags = d.get("flags", {})
	quest_index = int(d.get("quest_index", 0))
	step_index = int(d.get("step_index", 0))
	step_count = int(d.get("step_count", 0))
	step_done = d.get("step_done", [])
	completed = d.get("completed", [])
	challenges = d.get("challenges", {})
	equipped_hat = str(d.get("hat", ""))
	play_time = float(d.get("play_time", 0.0))
	timer_left = float(d.get("timer_left", 0.0))
	timer_label = str(d.get("timer_label", ""))
	return true


## Tells every listener to refresh after a load (called once the world exists).
func broadcast_all() -> void:
	coins_changed.emit(coins)
	hearts_changed.emit(hearts, max_hearts)
	inventory_changed.emit()
	hat_changed.emit(equipped_hat)
	challenges_changed.emit()
	quest_changed.emit()
	_apply_quest_time()


func _mark_dirty() -> void:
	if not _dirty:
		_save_left = 1.5
	_dirty = true


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else {}
