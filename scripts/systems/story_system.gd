extends "res://scripts/systems/city_system.gd"
## The world side of the story in data/story.json (GameState owns the quest
## logic). Per step it can: point the HUD marker at the target, drop pickups,
## keep enemies alive (via combat_system), bring an NPC to a place ("meet"),
## add neighbours' doors to knock on, workshop levers and Friksa's machine,
## and fire "reach:<place>" when the player arrives somewhere.
## Also runs the side challenges: golden chips, the delivery race and the
## tomato arena.

const Places = preload("res://scripts/npc/npc_places.gd")
const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")

const PICK_RANGE := 1.7
const STORY_TAG := "story"
const HUNT_ALIVE := 4

var _player: Node3D
var _npcs: Node
var _combat: Node
var _interior: Node
var _place_cache := {}
var _step_key := ""
var _drops: Array = []          # [{"node": Node3D, "item": String}]
var _chips: Array = []          # [{"node": Node3D, "index": int}]
var _spawn: Dictionary = {}
var _spawn_left := 0.0
var _meet_npcs := {}            # npc id -> Node3D (outdoor copy for the story)
var _rescue_doors: Array = []   # [{"id": String, "pos": Vector3}]
var _levers: Array = []         # [{"n": int, "node": Node3D, "pos": Vector3}]
var _machine: Node3D
var _reached := {}
var _rings := {}                # challenge id -> Node3D start ring
var _hunt := {}                 # active tomato arena: {"left": s, "score": n}
var _delivery := {}             # active delivery race: {"left": s, "done": []}
var _mesh_cache := {}
var _spin := 0.0


func setup(lib) -> void:
	super.setup(lib)
	add_to_group("story_system")
	_player = get_tree().get_first_node_in_group("player")
	_npcs = get_tree().get_first_node_in_group("npc_system")
	_combat = get_tree().get_first_node_in_group("combat_system")
	_interior = get_tree().get_first_node_in_group("interior_system")
	Interact.register_provider(self)
	GameState.quest_changed.connect(_sync_step)
	GameState.progress_reset.connect(_on_new_game)
	GameState.game_event.connect(_on_event)
	GameState.challenges_changed.connect(_build_chips)
	(func():
		# A new story starts from the home screen (GameUI menu).
		if GameState.started:
			GameState.broadcast_all()
		_build_chips()
		_build_rings()
		_sync_step()
		if "--test-story" in OS.get_cmdline_user_args():
			_test_story()).call_deferred()


func _exit_tree() -> void:
	Interact.unregister_provider(self)


# ------------------------------------------------------------------ places

## World position of a story place (data/story.json "places"), resolved
## against the real city so new layouts keep working.
func place_pos(name: String) -> Vector3:
	if _place_cache.has(name):
		return _place_cache[name]
	var pl: Dictionary = GameState.story.get("places", {}).get(name, {})
	var p := _v(pl.get("pos", [0, 0]))
	if pl.get("home", false):
		var home := home_object()
		if not home.is_empty():
			p = Places.door_position(home, 1.5)
	elif pl.has("building"):
		var o := {}
		if pl.has("near"):
			o = Places.nearest_of_type(str(pl["building"]), _v(pl["near"]))
		else:
			o = Places.first_of_type(str(pl["building"]))
		if o.is_empty() and pl.has("fallback_building"):
			o = Places.first_of_type(str(pl["fallback_building"]))
		if not o.is_empty():
			p = Places.door_position(o, 1.2)
			if pl.has("offset"):
				p = CityData.object_position(o) + _v(pl["offset"])
	elif pl.has("district"):
		p = _district_pos(str(pl["district"]), str(pl.get("block_type", "")), p)
	_place_cache[name] = p
	return p


func place_radius(name: String) -> float:
	return float(GameState.story.get("places", {}).get(name, {}).get("r", 6.0))


func _district_pos(dname: String, block_type: String, fallback: Vector3) -> Vector3:
	var did := ""
	for id in CityData.districts:
		if str(CityData.districts[id].get("name", "")) == dname:
			did = id
	if did == "":
		return fallback
	var sum := Vector2.ZERO
	var n := 0
	for blk in CityData.blocks:
		if str(blk.get("district", "")) != did:
			continue
		var c := CityData.block_rect(blk).get_center()
		if block_type != "" and str(blk.get("type", "")) == block_type:
			return Vector3(c.x, 0, c.y)
		sum += c
		n += 1
	if n == 0 or block_type != "":
		return fallback if n == 0 else Vector3(sum.x / n, 0, sum.y / n)
	return Vector3(sum.x / n, 0, sum.y / n)


## The player's new house in Ramat Friksa (picked once, saved in flags).
func home_object() -> Dictionary:
	var hid := str(GameState.flags.get("home_id", ""))
	if CityData.objects.has(hid):
		return CityData.objects[hid]
	var center := _district_pos("רמת פריקסה", "", Vector3(72, 0, 280))
	var best := {}
	var bd := INF
	for id in CityData.objects:
		var o: Dictionary = CityData.objects[id]
		if not str(o["type"]) in ["house_small", "house_tall", "house_villa"]:
			continue
		var d := CityData.object_position(o).distance_to(center)
		if d < bd:
			bd = d
			best = o
	if not best.is_empty():
		GameState.set_flag("home_id", str(best["id"]))
	return best


func _v(a: Variant) -> Vector3:
	if a is Array and (a as Array).size() >= 2:
		return Vector3(float(a[0]), 0, float(a[1]))
	return Vector3.ZERO


func _ground(p: Vector3) -> Vector3:
	p.y = Places.ground_y(Vector2(p.x, p.z))
	return p


# ------------------------------------------------------------------ steps

func _on_new_game() -> void:
	_step_key = ""
	_reached.clear()
	var home := home_object()
	if _player and not home.is_empty():
		# Start on the pavement in front of the new house, looking at it.
		var door := Places.door_position(home, 0.0)
		var out := (Places.door_position(home, 1.0) - door).normalized()
		var p := door + out * 9.0
		var main := get_tree().get_first_node_in_group("main")
		if main and main.get("world"):
			main.world.load_around_now(p, 1)
		_player.global_position = _ground(p) + Vector3(0, 0.4, 0)
		_player.velocity = Vector3.ZERO
		var rig := get_tree().get_first_node_in_group("camera_rig")
		if rig:
			rig.yaw = atan2(out.x, out.z)
			rig.pitch = -0.3
	(func(): _build_chips(); _sync_step()).call_deferred()


func _sync_step() -> void:
	var key := "%d:%d" % [GameState.quest_index, GameState.step_index]
	if not GameState.started or key == _step_key:
		return
	_step_key = key
	_leave_step()
	var st := GameState.current_step()
	if not st.is_empty():
		_enter_step(st)


func _leave_step() -> void:
	for d in _drops:
		if is_instance_valid(d["node"]):
			d["node"].queue_free()
	_drops.clear()
	_spawn = {}
	if _combat:
		_combat.clear(STORY_TAG)
	for n in _levers:
		if is_instance_valid(n["node"]):
			n["node"].queue_free()
	_levers.clear()
	if _machine:
		_machine.queue_free()
		_machine = null
	_rescue_doors.clear()


func _enter_step(st: Dictionary) -> void:
	if st.has("meet"):
		_meet(str(st["meet"].get("npc", "")), str(st["meet"].get("place", "")))
	if st.has("drop"):
		_drop_items(st["drop"], maxi(int(st["drop"].get("count", 1)) - GameState.step_count, 0))
	for d in st.get("drops", []):
		_drop_items(d, 1)
	if st.has("spawn"):
		if st.has("boss_intro") and GameState.step_count == 0:
			GameUI.show_dialogue(str(st["boss_intro"].get("speaker", "")), st["boss_intro"].get("lines", []),
					func(): _spawn = st["spawn"])
		else:
			_spawn = st["spawn"]
		_spawn_left = 0.0
	match str(st.get("event", "")):
		"rescue":
			_make_rescue_doors()
		"lever":
			_make_levers()
	if st.get("machine", false):
		_make_machine()
	if st.get("celebrate", false):
		_celebrate(place_pos("ramat_friksa"))


func _meet(npc_id: String, place: String) -> void:
	if _npcs == null or npc_id == "":
		return
	if _meet_npcs.has(npc_id) and is_instance_valid(_meet_npcs[npc_id]):
		_meet_npcs[npc_id].queue_free()
	var p := _meet_spot(place)
	var n: Node3D = _npcs.spawn_npc(npc_id, self, p, 0.0, {"indoor": false})
	_meet_npcs[npc_id] = n
	if _player:
		n.face(_player.global_position)


## Where a story NPC waits: in front of the home (not on the doorstep, or E
## would open the door instead of talking), else next to the place centre.
func _meet_spot(place: String) -> Vector3:
	if GameState.story.get("places", {}).get(place, {}).get("home", false):
		var home := home_object()
		if not home.is_empty():
			var door := Places.door_position(home, 0.0)
			var out := (Places.door_position(home, 1.0) - door).normalized()
			return _ground(door + out * 4.5 + Vector3(out.z, 0, -out.x) * 1.5)
	return _ground(place_pos(place) + Vector3(1.5, 0, 1.5))


func _drop_items(d: Dictionary, count: int) -> void:
	var item := str(d.get("item", ""))
	var center: Vector3
	if str(d.get("at", "")) == "last_defeat" and GameState.last_defeat_pos != Vector3.INF:
		center = GameState.last_defeat_pos
	else:
		center = place_pos(str(d.get("place", "")))
	var spread := float(d.get("spread", 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(item + _step_key)
	for i in count:
		var p := center
		if spread > 0.0:
			var a := rng.randf() * TAU
			p += Vector3(cos(a), 0, sin(a)) * rng.randf_range(spread * 0.3, spread)
		var node := _pickup_node(_item_color(item), false)
		add_child(node)
		node.global_position = _ground(p)
		_drops.append({"node": node, "item": item})


func _item_color(item: String) -> Color:
	return Color.html(str(GameState.get_item(item).get("color", "#ffd34d")))


## A floating, spinning pickup with a sparkle ring under it.
func _pickup_node(color: Color, chip: bool) -> Node3D:
	var key := color.to_html() + str(chip)
	if not _mesh_cache.has(key):
		var mb := MeshBuilder.new()
		if chip:
			mb.add_box(Vector3(0.18, 0.18, 0.75), Vector3(0, 0, 0), color, 0.0)
			mb.add_box(Vector3(0.18, 0.18, 0.6), Vector3(0.22, -0.05, 0.05), color.darkened(0.1), 0.3)
		else:
			mb.add_box(Vector3(0.5, 0.5, 0.5), Vector3.ZERO, color)
			mb.add_box(Vector3(0.54, 0.1, 0.54), Vector3.ZERO, color.lightened(0.4))
		var ring := TorusMesh.new()
		ring.inner_radius = 0.45
		ring.outer_radius = 0.55
		ring.rings = 12
		ring.ring_segments = 4
		mb.add_primitive(ring, Transform3D(Basis(), Vector3(0, -0.75, 0)), Color("fff3a0"))
		_mesh_cache[key] = mb.commit(library.material)
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh_cache[key]
	mi.position.y = 0.8
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return root


func _make_rescue_doors() -> void:
	var home := home_object()
	var center := place_pos("ramat_friksa")
	var houses := []
	for id in CityData.objects:
		var o: Dictionary = CityData.objects[id]
		if str(o["type"]).begins_with("house") and str(o["id"]) != str(home.get("id", "")):
			houses.append(o)
	houses.sort_custom(func(a, b): return CityData.object_position(a).distance_to(center) \
			< CityData.object_position(b).distance_to(center))
	for o in houses.slice(0, 6):
		_rescue_doors.append({"id": str(o["id"]), "pos": Places.door_position(o, 0.8)})


func _make_levers() -> void:
	var c := place_pos("workshop")
	var mb := MeshBuilder.new()
	mb.add_box(Vector3(0.6, 0.5, 0.4), Vector3(0, 0.25, 0), Color("6b5a4a"))
	mb.add_box(Vector3(0.1, 1.0, 0.1), Vector3(0, 0.9, 0), Color("c8c8c8"))
	mb.add_box(Vector3(0.25, 0.25, 0.25), Vector3(0, 1.45, 0), Color("e8473a"))
	var mesh := mb.commit(library.material)
	for i in 3:
		var p := _ground(c + Vector3((i - 1) * 6.0, 0, 4.0 + absf(i - 1) * 1.5))
		var root := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		root.add_child(mi)
		add_child(root)
		root.global_position = p
		var pulled := GameState.step_done.has("lever:%d" % (i + 1))
		mi.rotation.x = 0.7 if pulled else -0.5
		_levers.append({"n": i + 1, "node": root, "pos": p, "mesh": mi})


func _make_machine() -> void:
	var mb := MeshBuilder.new()
	mb.add_box(Vector3(2.4, 1.6, 1.6), Vector3(0, 0.8, 0), Color("7a8fa6"))
	mb.add_box(Vector3(0.9, 0.9, 0.2), Vector3(0, 1.0, 0.85), Color("f2c230"))
	mb.add_box(Vector3(0.3, 1.2, 0.3), Vector3(-0.8, 2.2, 0), Color("b04a3a"))
	mb.add_box(Vector3(0.5, 0.25, 0.5), Vector3(-0.8, 2.9, 0), Color("dddddd"))
	mb.add_box(Vector3(0.2, 0.2, 0.2), Vector3(0.7, 1.75, 0.6), Color("4fd16b"))
	_machine = Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mb.commit(library.material)
	_machine.add_child(mi)
	add_child(_machine)
	_machine.global_position = _ground(place_pos("workshop") + Vector3(4.0, 0, 3.0))


func _celebrate(p: Vector3) -> void:
	if has_node("/root/Audio"):
		Audio.play_music("victory")
	for i in 8:
		var a := i * TAU / 8.0
		Effects.puff(p + Vector3(cos(a) * 4.0, 1.5, sin(a) * 4.0), "sparkle", 8)


# ------------------------------------------------------------------ interact

func get_interactions(pos: Vector3) -> Array:
	var out := []
	for d in _rescue_doors:
		if not GameState.step_done.has("rescue:" + d["id"]) and d["pos"].distance_to(pos) < 3.0:
			out.append({"position": d["pos"], "prompt": "לדפוק בדלת", "action": _knock.bind(d["id"])})
	for l in _levers:
		if not GameState.step_done.has("lever:%d" % l["n"]) and l["pos"].distance_to(pos) < 3.0:
			out.append({"position": l["pos"], "prompt": "למשוך בידית", "action": _pull.bind(l)})
	if _machine and _machine.global_position.distance_to(pos) < 3.5:
		out.append({"position": _machine.global_position, "prompt": "להפעיל את מכונת הפריך",
				"action": _start_machine})
	for id in _rings:
		var r: Node3D = _rings[id]
		if r.visible and r.global_position.distance_to(pos) < 3.0 and _hunt.is_empty() and _delivery.is_empty():
			var ch: Dictionary = GameState.story["challenges"][id]
			out.append({"position": r.global_position, "prompt": "להתחיל: " + str(ch.get("title", id)),
					"action": _start_challenge.bind(id)})
	return out


func _knock(id: String) -> void:
	Audio.play_sfx("door", -2.0)
	var lines := ["תודה טוטו! כבר יצאתי לחלון – העגבניות נעלמו!", "שמעתי שגירשת אותן עם בגט! איזה גיבור."]
	GameUI.show_dialogue("שכנה", [lines[hash(id) % lines.size()]],
			func(): GameState.emit_event("rescue:" + id))


func _pull(l: Dictionary) -> void:
	Audio.play_sfx("click", 0.0)
	var mi: Node3D = l["mesh"]
	create_tween().tween_property(mi, "rotation:x", 0.7, 0.25).set_trans(Tween.TRANS_BACK)
	Effects.puff(l["pos"] + Vector3(0, 1.4, 0), "sparkle", 4)
	GameState.emit_event("lever:%d" % l["n"])


func _start_machine() -> void:
	Audio.play_sfx("quest", 0.0)
	var p := _machine.global_position
	for i in 5:
		Effects.puff(p + Vector3(randf_range(-1, 1), 2.5 + i * 0.4, randf_range(-1, 1)), "smoke", 4)
		Effects.puff(p + Vector3(0, 1.5, 1.0), "sparkle", 6)
	GameState.emit_event("machine:start")


# ------------------------------------------------------------------ update

func _process(delta: float) -> void:
	if _player == null or not GameState.started:
		return
	_spin += delta
	var pp := _player.global_position
	_update_pickups(pp)
	_update_reach(pp)
	_update_marker(pp)
	_update_spawns(delta)
	_update_challenges(delta)


func _update_pickups(pp: Vector3) -> void:
	for i in range(_drops.size() - 1, -1, -1):
		var d: Dictionary = _drops[i]
		var n: Node3D = d["node"]
		n.rotation.y = _spin * 2.0
		n.get_child(0).position.y = 0.8 + sin(_spin * 3.0 + i) * 0.15
		if n.global_position.distance_to(pp) < PICK_RANGE:
			_drops.remove_at(i)
			Effects.puff(n.global_position + Vector3(0, 0.8, 0), "sparkle", 6)
			n.queue_free()
			GameState.add_item(str(d["item"]))
			GameUI.toast("מצאת: " + GameState.item_name(str(d["item"])))
			GameState.emit_event("pickup:" + str(d["item"]))
	for i in range(_chips.size() - 1, -1, -1):
		var c: Dictionary = _chips[i]
		var n: Node3D = c["node"]
		n.rotation.y = _spin * 2.5
		if n.global_position.distance_to(pp) < PICK_RANGE:
			_chips.remove_at(i)
			n.queue_free()
			_found_chip(int(c["index"]), n.global_position)


func _update_reach(pp: Vector3) -> void:
	var st := GameState.current_step()
	var evs: Array = st.get("any", [st.get("event", "")])
	for ev in evs:
		var e := str(ev)
		if not e.begins_with("reach:"):
			continue
		var place := e.trim_prefix("reach:")
		var inside := Vector2(pp.x, pp.z).distance_to(Vector2(place_pos(place).x, place_pos(place).z)) \
				< place_radius(place)
		if inside and not _reached.get(e, false):
			_reached[e] = true
			GameState.emit_event(e)
		elif not inside:
			_reached[e] = false


func _update_marker(pp: Vector3) -> void:
	var hud: Control = GameUI.hud
	if hud == null:
		return
	var best := Vector3.INF
	var label := ""
	var bd := INF
	if _interior and _interior.is_inside():
		# The marker points at the street; inside, the room is the whole world.
		hud.target = Vector3.INF
		hud.target_label = ""
		return
	var targets := GameState.current_targets()
	var meet: Dictionary = GameState.current_step().get("meet", {})
	if not meet.is_empty():
		targets = [{"npc": str(meet.get("npc", ""))}]
	for t in targets:
		var p := _target_pos(t)
		if p == Vector3.INF:
			continue
		var d := p.distance_to(pp)
		if d < bd:
			bd = d
			best = p
			label = _target_label(t)
	hud.target = best
	hud.target_label = label


func _target_pos(t: Dictionary) -> Vector3:
	if t.get("item_drop", "") != "":
		var best := Vector3.INF
		for d in _drops:
			if d["item"] == t["item_drop"] and (best == Vector3.INF \
					or d["node"].global_position.distance_to(_player.global_position) \
					< best.distance_to(_player.global_position)):
				best = d["node"].global_position
		return best
	if t.get("rescue", false):
		for d in _rescue_doors:
			if not GameState.step_done.has("rescue:" + d["id"]):
				return d["pos"]
		return Vector3.INF
	if t.get("levers", false):
		for l in _levers:
			if not GameState.step_done.has("lever:%d" % l["n"]):
				return l["pos"]
		return Vector3.INF
	if t.has("npc"):
		var id := str(t["npc"])
		if _meet_npcs.has(id) and is_instance_valid(_meet_npcs[id]):
			return _meet_npcs[id].global_position
		if t.has("building"):
			var o := Places.first_of_type(str(t["building"]))
			if not o.is_empty():
				return Places.door_position(o)
		if _npcs:
			var p: Vector3 = _npcs.get_npc_position(id)
			if p != Vector3.INF:
				return p
		if t.has("place"):
			return place_pos(str(t["place"]))
		return Vector3.INF
	if t.has("building"):
		var o := Places.first_of_type(str(t["building"]))
		return Places.door_position(o) if not o.is_empty() else Vector3.INF
	if t.has("place"):
		return place_pos(str(t["place"]))
	return Vector3.INF


func _target_label(t: Dictionary) -> String:
	if t.has("npc"):
		return GameState.npc_name(str(t["npc"]))
	if t.get("item_drop", "") != "":
		return GameState.item_name(str(t["item_drop"]))
	return ""


func _update_spawns(delta: float) -> void:
	if _spawn.is_empty() or _combat == null:
		return
	_spawn_left -= delta
	if _spawn_left > 0.0:
		return
	_spawn_left = 1.2
	var st := GameState.current_step()
	var remaining := GameState.step_need(st) - GameState.step_count
	var want := mini(int(_spawn.get("alive", 3)), remaining)
	var place := str(_spawn.get("place", ""))
	if _combat.alive(STORY_TAG) < want:
		var kind := str(_spawn.get("kind", "tomato"))
		_combat.spawn(kind, _ground(place_pos(place)), place_radius(place) * 0.6, STORY_TAG)


# ------------------------------------------------------------------ challenges

func _on_event(name: String, data: Dictionary) -> void:
	if name.begins_with("defeat:") and str(data.get("tag", "")) == "hunt" and not _hunt.is_empty():
		_hunt["score"] = int(_hunt["score"]) + 1
		GameState.add_coins(int(GameState.story["challenges"]["hunt"].get("coins_per_hit", 2)))
	elif name.begins_with("talk:") and not _delivery.is_empty():
		var who := name.trim_prefix("talk:")
		if who in ["savta", "kid", "lifeguard"] and not (_delivery["done"] as Array).has(who):
			_delivery["done"].append(who)
			GameUI.toast("בורקס נמסר! (%d/3)" % (_delivery["done"] as Array).size())
			if (_delivery["done"] as Array).size() >= 3:
				_finish_delivery(true)
	elif name.begins_with("quest_complete:"):
		_build_rings()


## 12 golden chips at fixed, seeded spots on sidewalks around town.
func _build_chips() -> void:
	for c in _chips:
		if is_instance_valid(c["node"]):
			c["node"].queue_free()
	_chips.clear()
	if not GameState.started or CityData.blocks.is_empty():
		return
	var cfg: Dictionary = GameState.story.get("challenges", {}).get("chips", {})
	var found: Array = GameState.challenge("chips").get("found", [])
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for i in int(cfg.get("count", 12)):
		var blk: Dictionary = CityData.blocks[rng.randi() % CityData.blocks.size()]
		var r := CityData.block_rect(blk)
		var side := rng.randi() % 4
		var t := rng.randf_range(0.15, 0.85)
		var s := float(blk.get("sidewalk", 3.0)) * 0.5
		var p2: Vector2
		match side:
			0: p2 = Vector2(r.position.x + r.size.x * t, r.position.y + s)
			1: p2 = Vector2(r.position.x + r.size.x * t, r.end.y - s)
			2: p2 = Vector2(r.position.x + s, r.position.y + r.size.y * t)
			_: p2 = Vector2(r.end.x - s, r.position.y + r.size.y * t)
		if found.has(i) or found.has(float(i)):
			continue
		var n := _pickup_node(Color("f2c230"), true)
		add_child(n)
		n.global_position = _ground(Vector3(p2.x, 0, p2.y))
		_chips.append({"node": n, "index": i})


func _found_chip(i: int, pos: Vector3) -> void:
	var cfg: Dictionary = GameState.story["challenges"]["chips"]
	var found: Array = GameState.challenge("chips").get("found", []).duplicate()
	found.append(i)
	Effects.puff(pos + Vector3(0, 0.8, 0), "sparkle", 10)
	Audio.play_sfx("coin", 0.0)
	GameState.add_coins(int(cfg.get("coins_each", 3)))
	var total := int(cfg.get("count", 12))
	GameUI.toast("צ'יפס זהוב! %d/%d" % [found.size(), total])
	var hat := str(cfg.get("milestones", {}).get(str(found.size()), ""))
	if hat != "":
		GameState.add_item(hat)
		GameUI.banner("כובע חדש!", GameState.item_name(hat))
	if found.size() >= total:
		GameState.add_coins(int(cfg.get("coins_done", 30)))
		GameUI.banner("כל הצ'יפסים הזהובים!", "+%d מטבעות" % int(cfg.get("coins_done", 30)))
	GameState.challenges_changed.disconnect(_build_chips)
	GameState.set_record("chips", "found", found)
	GameState.challenges_changed.connect(_build_chips)


## Start rings for the delivery race (by the bakery) and the tomato arena
## (Ramat Friksa playground); they appear once their quest is done.
func _build_rings() -> void:
	var chs: Dictionary = GameState.story.get("challenges", {})
	var spots := {"delivery": _bakery_spot(), "hunt": place_pos("playground")}
	for id in spots:
		if not chs.has(id):
			continue
		if not _rings.has(id):
			var ring := TorusMesh.new()
			ring.inner_radius = 1.2
			ring.outer_radius = 1.5
			ring.rings = 16
			ring.ring_segments = 4
			var mb := MeshBuilder.new()
			mb.add_primitive(ring, Transform3D(Basis(), Vector3(0, 0.1, 0)), Color("ffcf3a"))
			mb.add_box(Vector3(0.15, 2.2, 0.15), Vector3(0, 1.1, 0), Color("ffffff"))
			mb.add_box(Vector3(0.9, 0.55, 0.08), Vector3(0, 2.0, 0), Color("f0803c") if id == "hunt" else Color("e0b060"))
			var root := Node3D.new()
			var mi := MeshInstance3D.new()
			mi.mesh = mb.commit(library.material)
			root.add_child(mi)
			add_child(root)
			root.global_position = _ground(spots[id])
			_rings[id] = root
		var req := str(chs[id].get("requires", ""))
		_rings[id].visible = req == "" or GameState.is_quest_done(req)


func _bakery_spot() -> Vector3:
	var o := Places.first_of_type("bakery")
	return Places.door_position(o, 3.0) + Vector3(2.5, 0, 0) if not o.is_empty() else place_pos("plaza")


func _start_challenge(id: String) -> void:
	var cfg: Dictionary = GameState.story["challenges"][id]
	GameUI.show_dialogue(str(cfg.get("title", "")), [str(cfg.get("desc", "")), "מוכנים? 3… 2… 1… צאו!"], func():
		match id:
			"hunt":
				_hunt = {"left": float(cfg.get("seconds", 60)), "score": 0}
			"delivery":
				_delivery = {"left": float(cfg.get("seconds", 210)), "done": []}
				GameState.add_item("burekas", 3)
		Audio.play_sfx("quest"))


func _update_challenges(delta: float) -> void:
	var hud: Control = GameUI.hud
	if not _hunt.is_empty():
		_hunt["left"] = float(_hunt["left"]) - delta
		if _combat and _combat.alive("hunt") < HUNT_ALIVE:
			_combat.spawn("tomato", _ground(place_pos("playground")), 9.0, "hunt")
		hud.set_challenge_text("זירת העגבניות: %d · %d שנ'" % [int(_hunt["score"]), ceili(float(_hunt["left"]))])
		if float(_hunt["left"]) <= 0.0:
			_finish_hunt()
	elif not _delivery.is_empty():
		_delivery["left"] = float(_delivery["left"]) - delta
		hud.set_challenge_text("משלוחים %d/3 · %d שנ'" % [(_delivery["done"] as Array).size(), ceili(float(_delivery["left"]))])
		if float(_delivery["left"]) <= 0.0:
			_finish_delivery(false)


func _finish_hunt() -> void:
	var cfg: Dictionary = GameState.story["challenges"]["hunt"]
	var score := int(_hunt["score"])
	_hunt = {}
	_combat.clear("hunt")
	GameUI.hud.set_challenge_text("")
	var best := int(GameState.challenge("hunt").get("best", 0))
	if score > best:
		GameState.set_record("hunt", "best", score)
	var msg := "%d עגבניות הפכו לקונפטי!" % score
	if score >= int(cfg.get("reward_score", 10)) and not GameState.challenge("hunt").get("rewarded", false):
		GameState.set_record("hunt", "rewarded", true)
		GameState.add_item(str(cfg.get("reward_item", "")))
		msg += "  קיבלת: " + GameState.item_name(str(cfg.get("reward_item", "")))
	GameUI.banner("נגמר הזמן!", msg + ("  (שיא חדש!)" if score > best else ""), 4.0)


func _finish_delivery(ok: bool) -> void:
	var cfg: Dictionary = GameState.story["challenges"]["delivery"]
	var used := float(cfg.get("seconds", 210)) - float(_delivery["left"])
	_delivery = {}
	GameUI.hud.set_challenge_text("")
	GameState.remove_item("burekas", int(GameState.inventory.get("burekas", 0)))
	if not ok:
		GameUI.banner("הבורקס התקרר…", "נסו שוב בטבעת ליד המאפייה", 3.5)
		return
	GameState.add_coins(int(cfg.get("coins", 20)))
	var best := float(GameState.challenge("delivery").get("best", 0.0))
	if best <= 0.0 or used < best:
		GameState.set_record("delivery", "best", snappedf(used, 0.1))
	if not GameState.challenge("delivery").get("rewarded", false):
		GameState.set_record("delivery", "rewarded", true)
		GameState.add_item(str(cfg.get("reward_item", "")))
	GameUI.banner("כל המשלוחים הגיעו!", "%d שניות" % int(used), 3.5)


# ------------------------------------------------------------------ self-test

## Plays the start of the story without a keyboard (used by --smoke).
func debug_run() -> Dictionary:
	var out := {}
	out["home"] = str(GameState.flags.get("home_id", ""))
	out["quest0"] = str(GameState.current_quest().get("id", ""))
	out["target"] = GameUI.hud.target
	GameState.emit_event("talk:chief")
	await get_tree().process_frame
	out["drops"] = _drops.size()
	for d in _drops.duplicate():
		_player.global_position = d["node"].global_position
		await get_tree().process_frame
		await get_tree().process_frame
	out["boxes"] = int(GameState.inventory.get("box", 0))
	out["step"] = GameState.step_index
	out["chips"] = _chips.size()
	if _combat:
		GameState.add_item("foam_baguette")
		var e: Node3D = _combat.spawn("tomato", _player.global_position + _player.global_transform.basis.z * 1.5, 0.0, "test")
		e.global_position = _player.global_position + _player.global_transform.basis.z * 1.5
		var hits := 0
		for i in 3:
			hits += _combat.swing()
			await get_tree().create_timer(0.4).timeout
		out["hits"] = hits
		out["tomato_left"] = _combat.alive("test")
		GameState.remove_item("foam_baguette")
	return out


## --test-story: plays every quest by firing the events each step waits for,
## so a broken story.json (a step nothing can complete) fails loudly.
func _test_story() -> void:
	var guard := 0
	while not GameState.is_story_done() and guard < 400:
		guard += 1
		await get_tree().process_frame
		var st := GameState.current_step()
		var q := GameState.current_quest()
		print("TEST story %s step %d: %s" % [q.get("id", ""), GameState.step_index, GameState.objective_text()])
		if st.has("requires"):
			GameState.add_item(str(st["requires"]), 3)
		for id in st.get("take", {}):
			GameState.add_item(str(id), int(st["take"][id]))
		var evs: Array = []
		if st.has("all"):
			evs = st["all"]
		elif st.has("any"):
			evs = [st["any"][0]]
		else:
			var ev := GameState.resolve_event(str(st.get("event", "")))
			for i in GameState.step_need(st) - GameState.step_count:
				evs.append(ev if ev.contains(":") else "%s:t%d" % [ev, i])
		for ev in evs:
			GameState.emit_event(GameState.resolve_event(str(ev)), {"pos": Vector3.ZERO})
			await get_tree().process_frame
	var ok := GameState.is_story_done()
	print("TEST story chapters done %d/%d coins %d items %s" % [GameState.completed.size(),
			GameState.quests().size(), GameState.coins, GameState.inventory.keys()])
	print("TEST STORY %s" % ("OK" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)
