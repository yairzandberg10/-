extends "res://scripts/systems/city_system.gd"
## Named, talkable NPCs + police officers (and optional police cars).
##
## Ids (the story system writes quests around them):
##   mayor   ראש העיר פוטטו   inside the town_hall interior
##   chief   המפקדת צ'יפסי    inside the police_station interior (else outside town_hall)
##   baker   האופה בורקס      inside the bakery interior (else outside the first shop_small)
##   savta   סבתא פירה        on the bench closest to the potato statue
##   kid     קטשופי           next to the park fountain
##   lifeguard המציל גלי       next to a lifeguard tower
##   officer (several)        patrolling sidewalks
## Talking: GameState.get_story_dialogue(id) wins when it returns lines,
## otherwise random default lines from data/npcs.json. When the dialogue ends
## the system emits GameState event "talk:<id>".
##
## The interior system asks spawn_npc() for the characters inside a room.

const NpcCharacter = preload("res://scripts/npc/npc_character.gd")
const SidewalkGraph = preload("res://scripts/npc/sidewalk_graph.gd")
const RoadDriver = preload("res://scripts/npc/road_driver.gd")
const Places = preload("res://scripts/npc/npc_places.gd")

const DATA_PATH := "res://data/npcs.json"
const TALK_RANGE := 3.0
const NEAR := 100.0
## Named NPCs that live inside a building type.
const HOME_TYPES := {"mayor": "town_hall", "chief": "police_station", "baker": "bakery"}
const OFFICERS := {"low": 3, "medium": 4, "high": 5}
const POLICE_CARS := {"low": 1, "medium": 2, "high": 2}

var data: Dictionary = {}
var graph
var _npcs: Array = []      # every live NpcCharacter (outdoor + current interior)
var _homes := {}           # npc id -> object dict of the building it lives in
var _officers: Array = []
var _cars: Array = []      # [{"node": MeshInstance3D, "car": Dictionary}]
var _driver
var _interior: Node
var _rng := RandomNumberGenerator.new()


func setup(lib) -> void:
	super.setup(lib)
	add_to_group("npc_system")
	name = "NpcSystem"
	_rng.seed = 4242
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	var parsed: Variant = JSON.parse_string(txt)
	data = parsed if parsed is Dictionary else {}
	graph = SidewalkGraph.new(31)
	_find_homes()
	_spawn_outdoor()
	_spawn_officers()
	_spawn_police_cars()
	Interact.register_provider(self)


func _exit_tree() -> void:
	Interact.unregister_provider(self)


func on_settings_changed() -> void:
	for o in _officers:
		if is_instance_valid(o):
			_npcs.erase(o)
			o.queue_free()
	_officers.clear()
	for c in _cars:
		c["node"].queue_free()
	_cars.clear()
	_spawn_officers()
	_spawn_police_cars()


# ------------------------------------------------------------------ public

## World position for quest markers. Interior NPCs: the door of their building.
func get_npc_position(id: String) -> Vector3:
	if _homes.has(id):
		return Places.door_position(_homes[id])
	for n in _npcs:
		if is_instance_valid(n) and n.npc_id == id and not n.indoor:
			return n.global_position
	return Vector3.INF


## The live character node with this id (first one for "officer"), or null.
func find_npc(id: String) -> Node3D:
	for n in _npcs:
		if is_instance_valid(n) and n.npc_id == id:
			return n
	return null


## CityData object the NPC lives in ({} when it lives outside).
func get_home(id: String) -> Dictionary:
	return _homes.get(id, {})


## Named NPC ids whose home is object `object_id` (used by the interior system).
func npcs_living_in(object_id: String) -> Array:
	var out := []
	for id in _homes:
		if str(_homes[id]["id"]) == object_id:
			out.append(id)
	return out


func npc_def(id: String) -> Dictionary:
	return data.get("npcs", {}).get(id, {})


## Creates a character as a child of `parent` (interior rooms use this).
## opts: role (staff key in npcs.json), seed, name, look, shop_type, shop_name,
##       seated, indoor (default true), lines.
func spawn_npc(id: String, parent: Node3D, local_pos: Vector3, yaw: float, opts := {}) -> Node3D:
	var def := npc_def(id)
	var seed_v := int(opts.get("seed", hash(id)))
	var look: Dictionary = opts.get("look", def.get("look", {}))
	var nm := str(opts.get("name", def.get("name", "")))
	var lines: Array = opts.get("lines", def.get("lines", []))
	if def.is_empty() and opts.has("role"):
		var staff: Dictionary = data.get("staff", {}).get(str(opts["role"]), {})
		var names: Array = staff.get("names", ["שכן"])
		var ni := posmod(seed_v, names.size())
		if nm == "":
			nm = str(names[ni])
		if lines.is_empty():
			lines = staff.get("lines", [])
		if look.is_empty():
			look = _staff_look(seed_v, nm, str(opts["role"]))
	var n := NpcCharacter.new()
	n.name = "Npc_" + id
	parent.add_child(n)
	n.setup(id, nm, look, library.material, bool(opts.get("seated", false)))
	n.lines = lines
	n.shop_type = str(opts.get("shop_type", ""))
	n.shop_name = str(opts.get("shop_name", ""))
	n.indoor = bool(opts.get("indoor", true))
	n.bouncy = bool(opts.get("bouncy", false))
	n.position = local_pos
	n.set_facing(yaw)
	_npcs.append(n)
	n.tree_exiting.connect(func(): _npcs.erase(n))
	return n


# ---------------------------------------------------------------- interact

func get_interactions(player_pos: Vector3) -> Array:
	var out := []
	for n in _npcs:
		if not is_instance_valid(n):
			continue
		var p: Vector3 = n.global_position
		if absf(p.x - player_pos.x) > TALK_RANGE or absf(p.z - player_pos.z) > TALK_RANGE:
			continue
		var prompt: String = "לדבר עם " + n.display_name
		if n.shop_type != "":
			prompt += " (חנות)"
		out.append({"position": p, "prompt": prompt, "action": talk.bind(n), "priority": 1.0})
	return out


func talk(n: Node3D) -> void:
	if not is_instance_valid(n):
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player:
		n.face(player.global_position)
	var id: String = n.npc_id
	var speaker: String = n.display_name
	var lines: Array = []
	var story: Dictionary = GameState.get_story_dialogue(id)
	var is_story := false
	if story.has("lines") and not (story["lines"] as Array).is_empty():
		lines = story["lines"]
		speaker = str(story.get("speaker", speaker))
		is_story = true
	else:
		lines = _pick_lines(n.lines)
	var shop_type: String = "" if is_story else n.shop_type
	var shop_name: String = n.shop_name
	GameUI.show_dialogue(speaker, lines, func():
		GameState.emit_event("talk:" + id, {"name": speaker})
		if shop_type != "":
			GameUI.open_shop(shop_type, shop_name))


func _pick_lines(pool: Array) -> Array:
	if pool.is_empty():
		return ["שלום!"]
	var idx := range(pool.size())
	var out := []
	for k in mini(2, pool.size()):
		var j: int = idx[_rng.randi() % idx.size()]
		idx.erase(j)
		out.append(pool[j])
	return out


# ------------------------------------------------------------------ update

func _process(delta: float) -> void:
	if _interior == null:
		_interior = get_tree().get_first_node_in_group("interior_system")
	var inside: bool = _interior != null and _interior.is_inside()
	var rig := get_tree().get_first_node_in_group("camera_rig")
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if rig == null or player == null:
		return
	var cam: Vector3 = rig.camera.global_position
	var pp := player.global_position
	for i in range(_npcs.size() - 1, -1, -1):
		var n = _npcs[i]
		if not is_instance_valid(n):
			_npcs.remove_at(i)
			continue
		if n.indoor != inside:
			continue
		var near: bool = cam.distance_squared_to(n.global_position) < NEAR * NEAR
		if near or not n.walker.is_empty():
			n.tick(delta, pp, near)
	if inside:
		return
	for c in _cars:
		var car: Dictionary = c["car"]
		_driver.step(car, delta)
		var h: Vector2 = car["heading"]
		var p: Vector2 = car["pos"]
		c["node"].transform = Transform3D(Basis(Vector3.UP, atan2(h.x, h.y)), Vector3(p.x, 0.05, p.y))


# ------------------------------------------------------------------- spawn

func _find_homes() -> void:
	_homes.clear()
	for id in HOME_TYPES:
		var o := Places.first_of_type(HOME_TYPES[id])
		if not o.is_empty() and library.has_type(str(o["type"])):
			_homes[id] = o


func _spawn_outdoor() -> void:
	var spawn := CityData.get_player_spawn()
	spawn.y = 0.0
	# Savta on her bench by the potato statue.
	var bench := Places.savta_bench()
	if not bench.is_empty():
		var xf := CityData.object_transform(bench)
		var p: Vector3 = xf * Vector3(0, 0, 0.12)
		p.y = Places.SEAT_Y
		_outdoor("savta", p, deg_to_rad(float(bench.get("rot", 0.0))), {"seated": true})
	else:
		_outdoor("savta", _ground(spawn + Vector3(-3, 0, 2)), 0.0)
	# The kid playing by the park fountain.
	var fountain := Places.first_of_type("fountain")
	if not fountain.is_empty():
		var fp := CityData.type_footprint("fountain")
		_outdoor("kid", _ground(CityData.object_position(fountain) + Vector3(0, 0, fp.y * 0.5 + 1.3)), PI, {"bouncy": true})
	else:
		_outdoor("kid", _ground(spawn + Vector3(3, 0, 3)), PI, {"bouncy": true})
	# Lifeguard next to the lifeguard tower closest to the city centre.
	var c := CityData.bounds.get_center()
	var tower := Places.nearest_of_type("lifeguard_tower", Vector3(c.x, 0, c.y))
	if not tower.is_empty():
		var p2: Vector3 = CityData.object_transform(tower) * Vector3(2.3, 0, 1.4)
		_outdoor("lifeguard", Vector3(p2.x, 0.0, p2.z), deg_to_rad(float(tower.get("rot", 0.0))))
	else:
		var bx := float(CityData.environment.get("beach_x", -4.0)) - 15.0
		_outdoor("lifeguard", Vector3(bx, 0, c.y), -PI * 0.5)
	# Fallbacks when the building types they live in do not exist.
	if not _homes.has("chief"):
		var th := Places.first_of_type("town_hall")
		if not th.is_empty():
			var fp2 := CityData.type_footprint("town_hall")
			_outdoor("chief", _ground(CityData.object_transform(th) * Vector3(4.5, 0, fp2.y * 0.5 + 1.6)),
					deg_to_rad(float(th.get("rot", 0.0))))
		else:
			_outdoor("chief", _ground(spawn + Vector3(5, 0, 0)), 0.0)
	if not _homes.has("baker"):
		var shop := Places.first_of_type("shop_small")
		var opts := {"shop_type": "bakery", "shop_name": "המאפייה של בורקס"}
		if not shop.is_empty():
			var fp3 := CityData.type_footprint("shop_small")
			_outdoor("baker", _ground(CityData.object_transform(shop) * Vector3(1.6, 0, fp3.y * 0.5 + 1.2)),
					deg_to_rad(float(shop.get("rot", 0.0))), opts)
		else:
			_outdoor("baker", _ground(spawn + Vector3(-5, 0, 0)), 0.0, opts)


func _outdoor(id: String, pos: Vector3, yaw: float, opts := {}) -> Node3D:
	opts["indoor"] = false
	return spawn_npc(id, self, pos, yaw, opts)


func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x, Places.ground_y(Vector2(p.x, p.z)), p.z)


func _spawn_officers() -> void:
	if graph.is_empty():
		return
	var n: int = OFFICERS.get(Settings.quality, 3)
	var def := npc_def("officer")
	var names: Array = def.get("names", [def.get("name", "השוטר")])
	# Patrol around the police station when there is one, else around the centre.
	var st := Places.first_of_type("police_station")
	var center := CityData.bounds.get_center()
	if not st.is_empty():
		var sp := CityData.object_position(st)
		center = Vector2(sp.x, sp.z)
	for i in n:
		var blk: int = graph.block_near(center, 60.0 + i * 25.0)
		var w: Dictionary = graph.make_walker(blk)
		w["speed"] = 1.2
		w["side"] = 0.0
		var look: Dictionary = def.get("look", {}).duplicate(true)
		if i % 2 == 1:
			look["hair"] = "bun"
			look["hair_color"] = ["#3a2618", "#7a4b2a", "#2b1d14"][i % 3]
		look["skin"] = ["#c49a5a", "#d4aa6a", "#b8874a", "#e0b77a", "#a87a45"][i % 5]
		var p: Vector2 = w["pos"]
		var o := _outdoor("officer", Vector3(p.x, graph.CURB_Y, p.y), 0.0,
				{"name": str(names[i % names.size()]), "look": look})
		o.walker = w
		o.graph = graph
		_officers.append(o)


func _spawn_police_cars() -> void:
	if not library.has_type("car_police") or CityData.roads.is_empty():
		return
	if _driver == null:
		_driver = RoadDriver.new(77)
	for i in POLICE_CARS.get(Settings.quality, 1):
		var mi := MeshInstance3D.new()
		mi.mesh = library.get_mesh("car_police", 0, false)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = 220.0
		add_child(mi)
		_cars.append({"node": mi, "car": _driver.make_car(6.5)})


## Look for generic staff, varied by seed. Names ending with a feminine title
## get hair instead of a hat now and then.
func _staff_look(seed_v: int, nm: String, role: String) -> Dictionary:
	var looks: Array = data.get("pedestrian_looks", [{}])
	var look: Dictionary = (looks[posmod(seed_v, looks.size())] as Dictionary).duplicate(true)
	look.erase("scale")
	var first := nm.split(" ")[0]
	if first.ends_with("ת") and not look.has("hair"):
		look["hair"] = "bun"
		look["hair_color"] = ["#3a2618", "#7a4b2a", "#2b1d14", "#c98b3a"][posmod(seed_v, 4)]
		if str(look.get("hat", "")) in ["cap", "beanie", "sprout"]:
			look.erase("hat")
	var extras: Array = look.get("extras", []).duplicate()
	extras.erase("bag")
	extras.erase("book")
	match role:
		"shopkeeper":
			extras.append("apron")
		"mechanic":
			look["clothes"] = "#e9a23b"
			look["hat"] = "cap"
			look["hat_color"] = "#3b3f45"
		"clerk", "librarian", "teacher":
			look["glasses"] = "round"
	look["extras"] = extras
	return look
