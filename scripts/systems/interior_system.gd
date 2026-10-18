extends "res://scripts/systems/city_system.gd"
## Enterable buildings. Near a front door the player gets "[E] להיכנס ל...";
## entering builds a small furnished room on demand far away from the city
## (ROOM_ORIGIN, on the y = 0 world floor, no ceiling - a dollhouse), moves the
## player inside and frees everything again on exit. Only one room exists at
## a time. The furniture comes from data/furniture.json (same part format as
## building_types.json) and every static piece of a room is merged into ONE
## mesh, so a room costs one draw call plus its characters.
##
## Which buildings: a type's optional "interior" field ("house", "shop", ...,
## or "none") wins; otherwise TYPE_KIND by type id, then the category
## (residential -> house, apartments -> lobby, commercial -> shop, civic -> hall).
##
## Events: "enter:<type>" {"id": id}, "enter_id:<id>", "exit_interior".

const BuildingLibrary = preload("res://scripts/city/building_library.gd")
const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")
const Places = preload("res://scripts/npc/npc_places.gd")

const FURNITURE_PATH := "res://data/furniture.json"
const ROOM_ORIGIN := Vector3(6000, 0, 0)
const LAYER_WALLS := 2      # follow camera collides with these
const LAYER_FURNITURE := 1  # player only
const WALL_T := 0.3
const CUTAWAY := 0.7        # visible height of the wall facing the camera
const DOOR_RANGE := 4.0

const TYPE_KIND := {
	"town_hall": "town_hall", "police_station": "police", "library": "library", "school": "school",
	"bakery": "bakery", "cafe": "cafe", "ice_cream_shop": "ice_cream", "pharmacy": "pharmacy",
	"toy_shop": "toy_shop", "falafel_stand": "falafel", "kiosk": "kiosk", "shop_small": "shop",
	"friksa_workshop": "workshop",
}
const CATEGORY_KIND := {"residential": "house", "apartments": "lobby", "commercial": "shop", "civic": "hall"}
## Half sizes (x, z) and wall height per kind.
const ROOM := {
	"house": [5.0, 4.0, 3.2], "lobby": [4.5, 4.0, 3.4], "shop": [5.0, 4.0, 3.2], "kiosk": [3.0, 2.6, 3.0],
	"bakery": [5.0, 4.0, 3.2], "cafe": [6.0, 4.5, 3.2], "ice_cream": [4.5, 3.6, 3.2],
	"pharmacy": [5.0, 4.0, 3.2], "toy_shop": [5.0, 4.0, 3.2], "falafel": [4.5, 3.6, 3.2],
	"town_hall": [8.0, 6.0, 4.0], "police": [8.0, 6.0, 3.6], "library": [7.0, 5.5, 3.6],
	"school": [7.0, 5.0, 3.4], "hall": [6.0, 5.0, 3.4], "workshop": [12.0, 9.0, 5.0],
}
const WALL_COLORS := ["#f4e1c1", "#d8e8f0", "#f7d6d0", "#e4f0d8", "#fff3c4", "#e8dcf2", "#f6efe2"]
const LOWER_COLORS := ["#9fc3d6", "#c8553d", "#7fb8a4", "#e9c46a", "#b5a3d0", "#f2f2ee"]
const FLOOR_COLORS := ["#c99a66", "#b07f52", "#d8b48a", "#a8754a"]

var furniture  # BuildingLibrary built from data/furniture.json

var _room: Node3D
var _mb
var _walls: StaticBody3D
var _furn_body: StaticBody3D
var _rng := RandomNumberGenerator.new()
var _mirror := false
var _hx := 5.0
var _outside_cam: Array = []  # [distance, pitch] of the street camera
var _hz := 4.0
var _kind := ""
var _obj: Dictionary = {}
var _outside_pos := Vector3.ZERO
var _outside_yaw := 0.0
var _outside_model_yaw := 0.0
var _anchor: Node3D
var _paused: Array = []
var _arrays := {}
var _npc_spots: Array = []
var _no_resident := {}

var _doors: Array = []
var _door_key := Vector2i(1 << 30, 0)
var _doors_dirty := true


func setup(lib) -> void:
	super.setup(lib)
	name = "InteriorSystem"
	add_to_group("interior_system")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FURNITURE_PATH))
	furniture = BuildingLibrary.new(parsed if parsed is Dictionary else {})
	furniture.material = lib.material  # one shared material for everything
	Interact.register_provider(self)
	CityData.chunk_changed.connect(func(_k): _doors_dirty = true)
	# Connect after main.gd's own before_save handler so the saved player
	# position is the street, never the room far away.
	(func(): CityData.before_save.connect(_on_before_save)).call_deferred()
	if "--test-interiors" in OS.get_cmdline_user_args():
		_run_test.call_deferred()


func _exit_tree() -> void:
	Interact.unregister_provider(self)


# ------------------------------------------------------------------ public

func is_inside() -> bool:
	return _room != null


## CityData id of the building the player is inside ("" outside).
func current_object_id() -> String:
	return str(_obj.get("id", "")) if _room else ""


func current_type() -> String:
	return str(_obj.get("type", "")) if _room else ""


func current_kind() -> String:
	return _kind if _room else ""


## World-space centre of the free floor area of the current room
## (for the workshop: the middle of the ~10 m clear arena). INF outside.
func get_interior_center() -> Vector3:
	if _room == null:
		return Vector3.INF
	return ROOM_ORIGIN + (Vector3(0, 0, 1.0) if _kind == "workshop" else Vector3.ZERO)


## Half extents (x, z) of the current room floor; ZERO outside.
func get_interior_half_size() -> Vector2:
	return Vector2(_hx, _hz) if _room else Vector2.ZERO


## Turns the potato neighbour living in a house on/off (e.g. the player's own
## new home should be empty). Applies the next time the house is entered.
func set_house_resident(object_id: String, on: bool) -> void:
	if on:
		_no_resident.erase(object_id)
	else:
		_no_resident[object_id] = true


## Interior kind for a building type, "" when it cannot be entered.
func kind_for(type_id: String) -> String:
	if not library.has_type(type_id):
		return ""
	var def: Dictionary = library.get_def(type_id)
	if def.has("interior"):
		var k := str(def["interior"])
		return k if ROOM.has(k) else ""
	if not bool(def.get("enterable", true)) or str(def.get("detail", "")) == "prop":
		return ""
	if TYPE_KIND.has(type_id):
		return TYPE_KIND[type_id]
	return CATEGORY_KIND.get(str(def.get("category", "")), "")


func enter_building(o: Dictionary, kind := "") -> void:
	if _room != null or o.is_empty():
		return
	if kind == "":
		kind = kind_for(str(o["type"]))
	if kind == "":
		return
	var player := get_tree().get_first_node_in_group("player") as CharacterBody3D
	var rig := get_tree().get_first_node_in_group("camera_rig")
	if player == null or rig == null:
		return
	_obj = o
	_kind = kind
	_outside_pos = player.global_position
	_outside_yaw = rig.yaw
	var model = player.get("_model")
	if model:
		_outside_model_yaw = model.rotation.y
	_build_room(o, kind)
	player.global_position = ROOM_ORIGIN + Vector3(0, 0.05, _hz - 1.3)
	player.velocity = Vector3.ZERO
	rig.yaw = 0.0
	# Dollhouse view: from above the open-top walls, far enough to see the room.
	_outside_cam = [rig.distance, rig.pitch]
	rig.indoor = true
	rig.distance = clampf(maxf(_hx, _hz) * 1.2 + 2.5, 7.0, 15.0)
	rig.pitch = -0.95
	if model:
		model.rotation.y = PI
	_hold_city(true)
	_sfx("door")
	var t := str(o["type"])
	GameUI.toast("נכנסת ל" + _building_name(o))
	GameState.emit_event("enter:" + t, {"id": str(o["id"])})
	GameState.emit_event("enter_id:" + str(o["id"]))


func exit_interior() -> void:
	if _room == null:
		return
	var player := get_tree().get_first_node_in_group("player") as CharacterBody3D
	var rig := get_tree().get_first_node_in_group("camera_rig")
	_room.queue_free()
	_room = null
	_npc_spots.clear()
	if player:
		player.global_position = _outside_pos + Vector3(0, 0.05, 0)
		player.velocity = Vector3.ZERO
		var model = player.get("_model")
		if model:
			model.rotation.y = _outside_model_yaw
	if rig:
		rig.yaw = _outside_yaw
		rig.indoor = false
		if not _outside_cam.is_empty():
			rig.distance = _outside_cam[0]
			rig.pitch = _outside_cam[1]
	_hold_city(false)
	_sfx("door")
	_obj = {}
	GameState.emit_event("exit_interior")


# ---------------------------------------------------------------- interact

func get_interactions(player_pos: Vector3) -> Array:
	if _room != null:
		var door := ROOM_ORIGIN + Vector3(0, 0, _hz - 0.5)
		if player_pos.distance_to(door) < DOOR_RANGE:
			return [{"position": door, "prompt": "לצאת", "action": exit_interior}]
		return []
	var key := CityData.chunk_key(player_pos)
	if key != _door_key or _doors_dirty:
		_rebuild_doors(key)
	var out := []
	for d in _doors:
		var p: Vector3 = d["position"]
		if absf(p.x - player_pos.x) < DOOR_RANGE and absf(p.z - player_pos.z) < DOOR_RANGE:
			out.append(d)
	return out


func _rebuild_doors(key: Vector2i) -> void:
	_door_key = key
	_doors_dirty = false
	_doors.clear()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for o in CityData.get_chunk_objects(key + Vector2i(dx, dz)):
				if kind_for(str(o["type"])) == "":
					continue
				var p := Places.door_position(o)
				_doors.append({"position": p, "prompt": "להיכנס ל" + _building_name(o),
						"action": enter_building.bind(o)})


func _building_name(o: Dictionary) -> String:
	return library.display_name(str(o["type"]))


func _unhandled_input(event: InputEvent) -> void:
	if _room == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if (event as InputEventKey).physical_keycode == KEY_B:
		get_viewport().set_input_as_handled()
		GameUI.toast("אי אפשר לבנות בתוך בניין – צאו החוצה קודם")


func _on_before_save() -> void:
	if _room != null:
		var p := _outside_pos
		CityData.set_player_state({"pos": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
				"yaw": snappedf(_outside_yaw, 0.001)})


## While inside: keep the city chunks around the street loaded (instant exit),
## pause and hide traffic. Pedestrians/NPCs check is_inside() themselves.
func _hold_city(on: bool) -> void:
	var main := get_tree().get_first_node_in_group("main")
	var world = main.get("world") if main else null
	if on:
		if _anchor == null:
			_anchor = Node3D.new()
			add_child(_anchor)
		_anchor.global_position = _outside_pos
		if world:
			world.focus = _anchor
		_paused.clear()
		for c in get_parent().get_children():
			var s: Script = c.get_script()
			if s and s.resource_path.ends_with("traffic_system.gd"):
				c.process_mode = Node.PROCESS_MODE_DISABLED
				c.visible = false
				_paused.append(c)
	else:
		var rig := get_tree().get_first_node_in_group("camera_rig")
		if world and rig:
			world.focus = rig.camera
		for c in _paused:
			if is_instance_valid(c):
				c.process_mode = Node.PROCESS_MODE_INHERIT
				c.visible = true
		_paused.clear()


func _sfx(n: String) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio and audio.has_method("play_sfx"):
		audio.play_sfx(n)


# --------------------------------------------------------------- room build

func _build_room(o: Dictionary, kind: String) -> void:
	var dims: Array = ROOM.get(kind, ROOM["house"])
	_hx = dims[0]
	_hz = dims[1]
	var h: float = dims[2]
	_rng.seed = hash(str(o["id"]))
	_mirror = _rng.randf() < 0.5 and kind != "workshop"
	_room = Node3D.new()
	_room.name = "Interior"
	add_child(_room)
	_room.global_position = ROOM_ORIGIN
	_mb = MeshBuilder.new()
	_walls = StaticBody3D.new()
	_walls.collision_layer = LAYER_WALLS
	_walls.collision_mask = 0
	_room.add_child(_walls)
	_furn_body = StaticBody3D.new()
	_furn_body.collision_layer = LAYER_FURNITURE
	_furn_body.collision_mask = 0
	_room.add_child(_furn_body)
	_npc_spots.clear()

	_shell(kind, h)
	match kind:
		"house": _layout_house(o)
		"lobby": _layout_lobby()
		"town_hall": _layout_town_hall(o)
		"police": _layout_police(o)
		"library": _layout_library()
		"school": _layout_school()
		"workshop": _layout_workshop()
		"hall": _layout_hall()
		"cafe": _layout_cafe(o)
		_: _layout_shop(o, kind)

	var mi := MeshInstance3D.new()
	mi.mesh = _mb.commit(library.material)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_room.add_child(mi)
	_spawn_npcs(o)


## Floor, four walls (outside the room rect), wainscot, trim, door, outer pad.
func _shell(kind: String, h: float) -> void:
	var wall := Color.html(WALL_COLORS[_rng.randi() % WALL_COLORS.size()])
	var lower := Color.html(LOWER_COLORS[_rng.randi() % LOWER_COLORS.size()])
	var floor_c := Color.html(FLOOR_COLORS[_rng.randi() % FLOOR_COLORS.size()])
	match kind:
		"workshop":
			wall = Color("c9a48a")
			lower = Color("7f8fa6")
			floor_c = Color("9aa0a8")
		"police":
			wall = Color("dfe8f2")
			lower = Color("2e5aa8")
			floor_c = Color("b9c0c8")
		"town_hall":
			wall = Color("efe6d6")
			lower = Color("8b6f5c")
			floor_c = Color("d8cbb4")
		"school":
			wall = Color("f4e7b8")
	var w := _hx * 2.0
	var d := _hz * 2.0
	# Dark "stage" around the room: from the dollhouse camera you only see the room.
	var pad := maxf(w, d) + 240.0
	_mb.add_box(Vector3(pad, 0.1, pad), Vector3(0, -0.06, 0), Color("2c2733"))
	_mb.add_box(Vector3(w + WALL_T * 2.0, 0.1, d + WALL_T * 2.0), Vector3(0, -0.04, 0), floor_c)
	# Floor boards / tiles.
	var line := floor_c.darkened(0.12)
	if kind in ["police", "workshop", "town_hall", "school"]:
		for i in range(1, int(w / 1.5)):
			_mb.add_box(Vector3(0.03, 0.02, d), Vector3(-_hx + i * 1.5, 0.012, 0), line)
		for i in range(1, int(d / 1.5)):
			_mb.add_box(Vector3(w, 0.02, 0.03), Vector3(0, 0.012, -_hz + i * 1.5), line)
	else:
		for i in range(1, int(w / 0.6)):
			_mb.add_box(Vector3(0.025, 0.02, d), Vector3(-_hx + i * 0.6, 0.012, 0), line)
	var walls := [
		[Vector3(w + WALL_T * 2.0, h, WALL_T), Vector3(0, h * 0.5, -_hz - WALL_T * 0.5), Vector3(w, 1.0, 0.02), Vector3(0, 0.5, -_hz + 0.01)],
		[Vector3(w + WALL_T * 2.0, h, WALL_T), Vector3(0, h * 0.5, _hz + WALL_T * 0.5), Vector3(w, 1.0, 0.02), Vector3(0, 0.5, _hz - 0.01)],
		[Vector3(WALL_T, h, d), Vector3(-_hx - WALL_T * 0.5, h * 0.5, 0), Vector3(0.02, 1.0, d), Vector3(-_hx + 0.01, 0.5, 0)],
		[Vector3(WALL_T, h, d), Vector3(_hx + WALL_T * 0.5, h * 0.5, 0), Vector3(0.02, 1.0, d), Vector3(_hx - 0.01, 0.5, 0)],
	]
	for wi in walls.size():
		var wl: Array = walls[wi]
		if wi == 1:
			# Front (door) wall faces the camera: drawn as a low cutaway so the
			# room reads like a dollhouse; its collision stays full height.
			var low: Vector3 = wl[0]
			low.y = CUTAWAY
			_mb.add_box(low, Vector3(wl[1].x, CUTAWAY * 0.5, wl[1].z), wall)
			_mb.add_box(Vector3(low.x + 0.06, 0.1, low.z + 0.06), Vector3(wl[1].x, CUTAWAY + 0.05, wl[1].z), Color("f7f3ea"))
			_add_wall_shape(wl)
			continue
		_mb.add_box(wl[0], wl[1], wall)
		_mb.add_box(wl[2], wl[3], lower)
		var trim_size: Vector3 = wl[0] + Vector3(0.06, 0.0, 0.06)
		trim_size.y = 0.12
		_mb.add_box(trim_size, Vector3(wl[1].x, h + 0.06, wl[1].z), Color("f7f3ea"))
		var skirt: Vector3 = wl[2] + Vector3(0, 0, 0)
		skirt.y = 0.12
		_mb.add_box(skirt * Vector3(1, 1, 1) + Vector3(0.02 if skirt.x < 0.1 else 0.0, 0, 0.02 if skirt.z < 0.1 else 0.0),
				Vector3(wl[3].x, 1.04, wl[3].z), Color("f7f3ea"))
		_add_wall_shape(wl)
	_put("rug", 0.0, _hz - 0.7, 0.0)


func _add_wall_shape(wl: Array) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = wl[0]
	cs.shape = bs
	cs.position = wl[1]
	_walls.add_child(cs)


# ---------------------------------------------------------------- placing

## Places a furniture piece at room coordinates (x, z), rotation in degrees.
## The whole layout is mirrored left/right for half of the buildings.
func _put(type_id: String, x: float, z: float, rot := 0.0, variant := -1, y := 0.0) -> void:
	if not furniture.has_type(type_id):
		push_warning("Interior: unknown furniture " + type_id)
		return
	if _mirror:
		x = -x
		rot = -rot
	if variant < 0:
		variant = _rng.randi() % furniture.variant_count(type_id)
	var key := "%s|%d" % [type_id, furniture.clamp_variant(type_id, variant)]
	if not _arrays.has(key):
		var m: ArrayMesh = furniture.get_mesh(type_id, variant, false)
		_arrays[key] = m.surface_get_arrays(0) if m.get_surface_count() > 0 else []
	var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(rot)), Vector3(x, y, z))
	if not (_arrays[key] as Array).is_empty():
		_mb.add_colored_arrays(_arrays[key], xf)
	if furniture.collides(type_id):
		var fp: Vector2 = furniture.footprint(type_id)
		var hgt: float = furniture.get_height(type_id)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(fp.x * 0.95, hgt, fp.y * 0.95)
		cs.shape = bs
		cs.transform = xf * Transform3D(Basis(), Vector3(0, hgt * 0.5, 0))
		_furn_body.add_child(cs)


## Item hung on / standing against a wall: "n", "s", "w", "e"; `along` is the
## offset along the wall, `out` how far the item centre stands from it.
func _wall_item(type_id: String, wall: String, along: float, out := 0.0, variant := -1) -> void:
	if wall == "s":
		return  # the front wall is a low cutaway; nothing hangs on it
	match wall:
		"n": _put(type_id, along, -_hz + out, 0.0, variant)
		"s": _put(type_id, along, _hz - out, 180.0, variant)
		"w": _put(type_id, -_hx + out, along, 90.0, variant)
		"e": _put(type_id, _hx - out, along, 270.0, variant)


func _chance(p: float) -> bool:
	return _rng.randf() < p


func _pick(list: Array) -> Variant:
	return list[_rng.randi() % list.size()]


## Character spot (room coordinates, mirrored like furniture). yaw 0 = facing the door.
func _spot(id: String, x: float, z: float, yaw := 0.0, opts := {}) -> void:
	if _mirror:
		x = -x
		yaw = -yaw
	_npc_spots.append({"id": id, "pos": Vector3(x, 0, z), "yaw": yaw, "opts": opts})


func _spawn_npcs(o: Dictionary) -> void:
	var npcs := get_tree().get_first_node_in_group("npc_system")
	if npcs == null:
		return
	var i := 0
	for s in _npc_spots:
		var opts: Dictionary = s["opts"].duplicate()
		opts["seed"] = hash(str(o["id"])) + i * 7919
		npcs.spawn_npc(s["id"], _room, s["pos"], s["yaw"], opts)
		i += 1


## The building's named NPC (mayor/chief/baker) or "" if none lives here.
func _named_here(o: Dictionary) -> String:
	var npcs := get_tree().get_first_node_in_group("npc_system")
	if npcs == null:
		return ""
	var l: Array = npcs.npcs_living_in(str(o["id"]))
	return str(l[0]) if not l.is_empty() else ""


func _shop_opts(o: Dictionary) -> Dictionary:
	return {"role": "shopkeeper", "shop_type": str(o["type"]), "shop_name": _building_name(o)}


# ---------------------------------------------------------------- layouts

func _layout_house(o: Dictionary) -> void:
	var hx := _hx
	var hz := _hz
	# Living room (west half).
	_put("rug", -2.6, 0.6, 90.0)
	_put("tv_stand", -hx + 0.3, 0.6, 90.0)
	_put("sofa", -1.0, 0.6, 270.0)
	_put("coffee_table", -2.6, 0.6, 90.0)
	_put("floor_lamp", -0.8, -0.9)
	if _chance(0.6):
		_put("armchair", -3.9, 2.7, 135.0)
	else:
		_put("plant_big", -hx + 0.45, hz - 0.45)
	# Bedroom corner.
	_put("bed", -hx + 0.75, -hz + 1.08, 0.0)
	_put("plant_small", -hx + 1.8, -hz + 0.3)
	_wall_item("picture", "n", -hx + 0.75)
	_wall_item("bookshelf", "n", -1.9, 0.22)
	_wall_item("window", "n", 0.15)
	# Kitchen + dining (east half).
	_wall_item("kitchen_counter", "n", 2.2, 0.35)
	_wall_item("fridge", "n", hx - 0.5, 0.4)
	_put("dining_table", 2.6, 0.5, 0.0)
	_put("chair", 2.2, -0.25, 0.0)
	_put("chair", 3.0, -0.25, 0.0)
	_put("chair", 2.2, 1.25, 180.0)
	if _chance(0.6):
		_put("chair", 3.0, 1.25, 180.0)
	_put("plant_big", hx - 0.45, hz - 0.45)
	_wall_item("window", "e", -0.8)
	_wall_item("window", "e", 2.0)
	_wall_item("window", "w", -1.6)
	_wall_item("picture", "w", 2.6)
	_wall_item("clock", "s", -2.4)
	_wall_item("picture", "s", 2.6)
	# Toys and the cat in random cosy spots.
	var spots := [Vector2(-2.0, 1.4), Vector2(-3.3, -0.4), Vector2(0.3, 2.6), Vector2(-3.0, 2.2), Vector2(1.0, -2.6)]
	for t in ["toy_blocks", "ball", "teddy"]:
		if _chance(0.7):
			var sp: Vector2 = spots.pop_at(_rng.randi() % spots.size())
			_put(t, sp.x, sp.y, _rng.randf() * 360.0)
	var cat_spot: Vector2 = spots[_rng.randi() % spots.size()]
	_put("cat", cat_spot.x, cat_spot.y, _rng.randf() * 360.0)
	if not _no_resident.has(str(o["id"])):
		var at: Vector2 = _pick([Vector2(1.6, 1.8), Vector2(0.4, -1.4), Vector2(3.6, 2.4)])
		_spot("resident_" + str(o["id"]), at.x, at.y, 0.0, {"role": "resident"})


func _layout_lobby() -> void:
	_put("stairs", -_hx + 0.75, -_hz + 1.5, 0.0)
	_wall_item("elevator", "n", 1.4)
	_wall_item("mailboxes", "w", 1.2)
	_put("rug", 0.8, 0.6, 0.0)
	_put("sofa", _hx - 0.5, 0.6, 270.0)
	_put("plant_big", _hx - 0.45, -_hz + 0.45)
	_put("plant_big", -_hx + 0.45, _hz - 0.45)
	_wall_item("picture", "e", -1.8)
	_wall_item("window", "e", 2.6)
	_wall_item("clock", "s", 2.2)
	if _chance(0.5):
		_put("cat", 0.5, 1.2, _rng.randf() * 360.0)
	_spot("doorman", 2.4, -1.6, 0.0, {"role": "doorman"})


func _layout_shop(o: Dictionary, kind: String) -> void:
	var hx := _hx
	var hz := _hz
	var shelf_v := _rng.randi() % 5
	if kind == "pharmacy":
		shelf_v = 2
	elif kind == "toy_shop":
		shelf_v = 4
	var named := _named_here(o)
	var keeper_id := named if named != "" else "shopkeeper"
	var keeper_opts := _shop_opts(o)
	match kind:
		"bakery":
			_wall_item("bread_shelf", "n", -2.4, 0.3)
			_wall_item("bread_shelf", "n", 2.4, 0.3)
			_wall_item("bread_shelf", "w", -1.0, 0.3)
			_wall_item("bread_shelf", "e", -1.0, 0.3)
			_put("bakery_case", -0.9, -1.5, 0.0)
			_put("shop_counter", 1.4, -1.5, 0.0, 3)
			_put("cafe_table", -3.0, 2.2, 0.0)
			_put("chair", -3.0, 2.85, 180.0)
			_put("chair", -3.0, 1.55, 0.0)
			_put("plant_big", hx - 0.45, hz - 0.45)
			_wall_item("menu_board", "w", 2.0)
		"ice_cream", "falafel":
			_wall_item("menu_board", "n", 0.0)
			if kind == "ice_cream":
				_put("freezer_case", 0.0, -_hz + 1.6, 0.0)
				_wall_item("drinks_fridge", "n", hx - 0.6, 0.4)
			else:
				_put("falafel_counter", 0.0, -_hz + 1.6, 0.0)
				_wall_item("shelf_goods", "n", -hx + 1.2, 0.3, 1)
			for x in [-2.6, 2.6]:
				_put("cafe_table", x, 1.4, 0.0)
				_put("chair", x - 0.65, 1.4, 90.0)
				_put("chair", x + 0.65, 1.4, 270.0)
			_put("plant_big", -hx + 0.45, hz - 0.45)
		"kiosk":
			_wall_item("shelf_goods", "n", -1.0, 0.3, shelf_v)
			_wall_item("drinks_fridge", "w", -0.6, 0.4)
			_put("shop_counter", 0.9, -0.6, 0.0)
			_put("newspaper_rack", 2.3, 1.6, 270.0)
		_:
			for z in [-1.8, 0.4]:
				_wall_item("shelf_goods", "w", z, 0.3, shelf_v)
				_wall_item("shelf_goods", "e", z, 0.3, shelf_v)
			_wall_item("shelf_goods", "n", -2.7, 0.3, shelf_v)
			_wall_item("shelf_goods", "n", 2.7, 0.3, shelf_v)
			_put("shop_counter", 0.0, -1.6, 0.0)
			match kind:
				"toy_shop":
					_put("rug", 0.0, 1.5, 0.0)
					_put("teddy", -0.6, 1.4, 20.0, 0)
					_put("teddy", 0.2, 1.8, -30.0, 2)
					_put("ball", 0.8, 1.2, 0.0)
					_put("toy_blocks", -1.2, 1.9, 10.0)
				"pharmacy":
					_put("plant_big", -1.8, 2.6)
					_wall_item("notice_board", "s", 2.6)
				_:
					_put("produce_stand", -1.8, 1.4, 0.0)
					_put("produce_stand", 1.8, 1.4, 0.0)
			_wall_item("clock", "s", -2.6)
	var kz := -_hz + 0.95 if kind in ["ice_cream", "falafel"] else (-0.15 if kind == "kiosk" else -2.5)
	var kx := 0.9 if kind == "kiosk" else (0.0 if kind != "bakery" else 0.2)
	_spot(keeper_id, kx, kz, 0.0, keeper_opts)


func _layout_cafe(o: Dictionary) -> void:
	var hx := _hx
	var hz := _hz
	_put("shop_counter", -1.0, -hz + 1.6, 0.0, 0)
	_wall_item("coffee_machine", "n", 1.6, 0.3)
	_wall_item("bread_shelf", "n", -3.6, 0.3)
	_wall_item("menu_board", "n", -1.0)
	for p in [Vector2(-3.6, 0.6), Vector2(0.0, 1.2), Vector2(3.6, 0.6), Vector2(-2.0, 3.0), Vector2(2.4, 3.0)]:
		_put("cafe_table", p.x, p.y, 0.0)
		_put("chair", p.x - 0.65, p.y, 90.0)
		_put("chair", p.x + 0.65, p.y, 270.0)
	_put("plant_big", hx - 0.45, -hz + 0.45)
	_put("plant_big", -hx + 0.45, hz - 0.45)
	_wall_item("window", "w", 0.5)
	_wall_item("window", "e", 1.5)
	_wall_item("picture", "e", -1.6)
	if _chance(0.5):
		_put("cat", 4.6, 2.4, 200.0)
	_spot("shopkeeper", -1.0, -hz + 0.8, 0.0, _shop_opts(o))


func _layout_town_hall(o: Dictionary) -> void:
	var hx := _hx
	var hz := _hz
	_put("runner", 0.0, 1.6, 0.0)
	_put("mayor_desk", 0.0, -3.4, 0.0)
	_put("throne_chair", 0.0, -5.0, 0.0)
	_put("flag", -2.2, -5.4, 0.0, 0)
	_put("flag", 2.2, -5.4, 0.0, 1)
	_wall_item("portrait", "n", 0.0)
	_wall_item("bookshelf", "n", -5.0, 0.22)
	_wall_item("bookshelf", "n", 5.0, 0.22)
	for z in [-0.4, 1.2, 2.8]:
		_put("chair", -1.6, z, 90.0, 0)
		_put("chair", 1.6, z, 270.0, 0)
	_put("mini_statue", 5.6, 2.6)
	_put("plant_big", -hx + 0.5, hz - 0.5)
	_put("plant_big", hx - 0.5, hz - 0.5)
	_put("plant_big", -hx + 0.5, -hz + 0.5)
	_put("desk", -5.6, 0.4, 90.0)
	_put("office_chair", -6.5, 0.4, 90.0)
	_wall_item("notice_board", "w", 3.2)
	for z in [-3.0, 0.4]:
		_wall_item("window", "e", z)
	_wall_item("window", "w", -3.0)
	_wall_item("clock", "s", -4.0)
	var named := _named_here(o)
	if named != "":
		_spot(named, 0.0, -4.35, 0.0)
		_spot("clerk", -6.5, 1.3, PI * 0.5, {"role": "clerk"})
	else:
		_spot("clerk", 0.0, -4.35, 0.0, {"role": "clerk"})


func _layout_police(o: Dictionary) -> void:
	var hx := _hx
	var hz := _hz
	_put("jail_cell", hx - 1.5, -hz + 1.2, 0.0)
	_put("desk", 0.0, -3.2, 0.0, 2)
	_put("office_chair", 0.0, -4.1, 180.0, 0)
	_put("flag", 1.6, -5.4, 0.0, 0)
	_wall_item("notice_board", "n", -1.8)
	_wall_item("lockers", "w", -3.2, 0.25)
	_wall_item("coffee_machine", "n", -5.6, 0.3)
	_put("water_cooler", -4.4, -hz + 0.3)
	for p in [Vector2(-4.0, 1.0), Vector2(3.2, 2.0)]:
		_put("desk", p.x, p.y, 0.0, 1)
		_put("office_chair", p.x, p.y - 0.85, 180.0, 1)
	_put("plant_big", -hx + 0.5, hz - 0.5)
	_put("plant_big", hx - 0.5, hz - 0.5)
	_put("chair", -1.0, 3.6, 180.0, 3)
	_put("chair", 0.0, 3.6, 180.0, 3)
	_wall_item("notice_board", "w", 1.6)
	_wall_item("window", "e", 1.2)
	_wall_item("window", "w", 4.0)
	_wall_item("clock", "s", 3.0)
	var named := _named_here(o)
	_spot(named if named != "" else "officer", 0.0, -4.1, 0.0)
	_spot("officer", 3.2, 1.15, 0.0)


func _layout_library() -> void:
	var hx := _hx
	var hz := _hz
	for x in [-4.8, -2.9, 2.9, 4.8]:
		_wall_item("bookshelf", "n", x, 0.22)
	for z in [-2.6, -0.8, 1.0]:
		_wall_item("bookshelf", "w", z, 0.22)
		_wall_item("bookshelf", "e", z, 0.22)
	_wall_item("window", "n", 0.0)
	_put("rug", 0.0, -0.6, 0.0)
	for z in [-1.8, 0.8]:
		_put("dining_table", 0.0, z, 0.0, 1)
		for x in [-0.4, 0.4]:
			_put("chair", x, z - 0.75, 0.0, 0)
			_put("chair", x, z + 0.75, 180.0, 0)
	_put("desk", -3.6, 3.2, 180.0, 0)
	_put("globe", 3.8, 3.4)
	_put("plant_big", hx - 0.5, hz - 0.5)
	_put("plant_big", -hx + 0.5, hz - 0.5)
	_wall_item("clock", "s", 2.0)
	_spot("librarian", -3.6, 2.45, 0.0, {"role": "librarian"})


func _layout_school() -> void:
	var hx := _hx
	var hz := _hz
	_wall_item("blackboard", "n", 0.0)
	_put("desk", 2.6, -3.2, 0.0, 2)
	_put("globe", 4.2, -3.6)
	for x in [-4.2, -1.4, 1.4, 4.2]:
		for z in [-0.8, 1.4]:
			_put("school_desk", x, z, 0.0)
	_wall_item("bookshelf", "e", 2.0, 0.22)
	_wall_item("notice_board", "s", -3.0)
	for z in [-2.0, 1.2]:
		_wall_item("window", "w", z)
	_wall_item("window", "e", -1.6)
	_wall_item("clock", "n", -4.6)
	_put("plant_big", -hx + 0.5, -hz + 0.5)
	_put("plant_big", hx - 0.5, hz - 0.5)
	_spot("teacher", 1.0, -3.5, 0.0, {"role": "teacher"})


func _layout_hall() -> void:
	var hx := _hx
	var hz := _hz
	_put("rug", 0.0, 0.0, 0.0)
	_put("desk", 0.0, -2.6, 0.0, 0)
	_put("office_chair", 0.0, -3.5, 180.0)
	for x in [-1.0, 1.0]:
		_put("chair", x, -1.4, 180.0)
	_wall_item("bookshelf", "n", -3.6, 0.22)
	_wall_item("bookshelf", "n", 3.6, 0.22)
	_wall_item("notice_board", "w", 0.0)
	_wall_item("window", "e", 0.0)
	_put("plant_big", -hx + 0.5, hz - 0.5)
	_put("plant_big", hx - 0.5, hz - 0.5)
	_put("water_cooler", hx - 0.4, -hz + 0.4)
	_spot("clerk", 0.0, -3.5, 0.0, {"role": "clerk"})


## The big "machine hall": the Friksa machine fills the north wall, benches
## and storage line the walls, the middle (~10 m around get_interior_center)
## is left empty for the boss fight.
func _layout_workshop() -> void:
	var hx := _hx
	var hz := _hz
	_put("friksa_machine", 0.0, -hz + 2.0, 0.0)
	_put("lever_panel", -6.2, -hz + 0.8, 0.0)
	_wall_item("wall_pipes", "n", -8.8)
	_wall_item("wall_pipes", "n", 8.8)
	_wall_item("blueprint", "n", -9.2)
	_wall_item("blueprint", "n", 7.0)
	for z in [-4.5, -0.5, 3.5]:
		_wall_item("workbench", "w", z, 0.45)
		_wall_item("workbench", "e", z, 0.45)
	for z in [-2.5, 1.5, 5.5]:
		_wall_item("blueprint", "w", z)
		_wall_item("blueprint", "e", z)
	for p in [Vector2(-hx + 0.6, hz - 0.6), Vector2(-hx + 1.7, hz - 0.6), Vector2(-hx + 0.6, hz - 1.7),
			Vector2(hx - 0.6, hz - 0.6), Vector2(hx - 0.6, hz - 1.7)]:
		_put("crate", p.x, p.y, _rng.randf_range(-10, 10))
	for p in [Vector2(-hx + 0.5, -hz + 0.5), Vector2(-hx + 1.3, -hz + 0.5), Vector2(hx - 0.5, -hz + 0.5),
			Vector2(hx - 1.6, hz - 0.6), Vector2(-hx + 2.0, -hz + 0.6)]:
		_put("barrel", p.x, p.y, 0.0)
	_wall_item("clock", "s", -4.0)
	_wall_item("notice_board", "s", 4.0)


# -------------------------------------------------------------------- test

## `-- --test-interiors`: enters one building of every interior kind, takes
## screenshots (user://shots_B/), talks to the characters, then photographs
## the outdoor NPCs and pedestrians and quits.
func _run_test() -> void:
	for i in 10:
		await get_tree().process_frame
	var main := get_tree().get_first_node_in_group("main")
	var rig := get_tree().get_first_node_in_group("camera_rig")
	var npcs := get_tree().get_first_node_in_group("npc_system")
	if main and main.get("hud"):
		main.hud.visible = false
	var dir := "user://shots_B"
	DirAccess.make_dir_recursive_absolute(dir)
	var events := []
	GameState.game_event.connect(func(n, _d): events.append(n))
	var kinds := ["house", "lobby", "shop", "kiosk", "bakery", "cafe", "ice_cream", "pharmacy", "toy_shop",
			"falafel", "town_hall", "police", "library", "school", "hall", "workshop"]
	var ok := true
	for kind in kinds:
		var o := {}
		for id in CityData.objects:
			if kind_for(str(CityData.objects[id]["type"])) == kind:
				o = CityData.objects[id]
				break
		if o.is_empty():
			o = {"id": "test_" + kind, "type": "shop_small", "pos": [72, 84], "rot": 0}
		enter_building(o, kind)
		if not is_inside():
			push_error("TEST: could not enter " + kind)
			ok = false
			continue
		for i in 8:
			await get_tree().process_frame
		rig.external = true
		var c := ROOM_ORIGIN
		rig.camera.global_position = c + Vector3(_hx * 0.55, maxf(_hx, _hz) * 1.25 + 3.0, _hz * 1.5 + 2.0)
		rig.camera.look_at(c + Vector3(0, 0.5, -0.5))
		await _shot("%s/interior_%s.png" % [dir, kind])
		rig.external = false
		for i in 4:
			await get_tree().process_frame
		await _shot("%s/interior_%s_walk.png" % [dir, kind])
		var n_inside := 0
		for ch in _room.get_children():
			if ch.has_method("tick"):
				n_inside += 1
				npcs.talk(ch)
		print("TEST interior %s (%s): npcs=%d draw calls=%d" % [kind, str(o["id"]), n_inside,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
		exit_interior()
		await get_tree().process_frame
	rig.external = true
	for id in ["savta", "kid", "lifeguard", "chief", "baker", "officer"]:
		var p: Vector3 = npcs.get_npc_position(id)
		var node = npcs.find_npc(id)
		if node:
			p = node.global_position
		if p == Vector3.INF:
			print("TEST npc %s: no position" % id)
			continue
		var f := Vector3(sin(node.facing()), 0, cos(node.facing())) if node else Vector3(0, 0, 1)
		rig.camera.global_position = p + f * 3.2 + Vector3(f.z, 0, -f.x) * 1.2 + Vector3(0, 1.6, 0)
		rig.camera.look_at(p + Vector3(0, 0.7, 0))
		main.world.load_all_now()
		for i in 6:
			await get_tree().process_frame
		await _shot("%s/npc_%s.png" % [dir, id])
		print("TEST npc %s at %s" % [id, str(p)])
	var sp := CityData.get_player_spawn()
	rig.camera.global_position = Vector3(sp.x - 14, 3.0, sp.z + 22)
	rig.camera.look_at(Vector3(sp.x + 6, 0.5, sp.z + 6))
	for i in 30:
		await get_tree().process_frame
	await _shot("%s/pedestrians.png" % dir)
	var ped := get_parent().get_node_or_null("PedestrianSystem")
	print("TEST pedestrians: %d" % (ped.agent_count() if ped else -1))
	var need := ["enter:shop_small", "exit_interior", "talk:shopkeeper"]
	for e in need:
		if not events.has(e):
			push_error("TEST: missing event " + e)
			ok = false
	print("TEST events: ", ", ".join(PackedStringArray(events.slice(0, 40))))
	print("TEST INTERIORS %s" % ("OK" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
