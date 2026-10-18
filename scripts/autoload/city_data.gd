extends Node
## The city's data store.
##
## Two layers are merged at load time:
##   * base    - res://data/city.json, the authored city (edited by tools/city_tool.py)
##   * overlay - user://city_overlay.json, everything the player changed in-game
##               (added objects, removed base ids, player position)
## Keeping the player's edits separate means the base city can be extended
## (new neighbourhoods etc.) without ever overwriting what was built in-game.
## Objects are indexed by 64m chunks so the world can stream them by area.

signal chunk_changed(key: Vector2i)
signal before_save
signal saved(path: String)

const BASE_PATH := "res://data/city.json"
const TYPES_PATH := "res://data/building_types.json"
const AUTOSAVE_SECONDS := 30.0

var overlay_path := "user://city_overlay.json"
var type_data: Dictionary = {}
var city_name := "תל בטטה"
var chunk_size := 64.0
var grid: Dictionary = {}
var environment: Dictionary = {}
var districts: Dictionary = {}
var blocks: Array = []
var roads: Array = []
var objects: Dictionary = {}  # id -> object dict
var overlay: Dictionary = {}
var bounds := Rect2()

var _chunk_objects: Dictionary = {}  # Vector2i -> Array[String] (ids)
var _chunk_blocks: Dictionary = {}  # Vector2i -> Array[Dictionary]
var _chunk_roads: Dictionary = {}  # Vector2i -> Array[Dictionary]
var _dirty := false
var _autosave_left := AUTOSAVE_SECONDS
var _uid_counter := 0


func _ready() -> void:
	if "--smoke" in OS.get_cmdline_user_args():
		overlay_path = "user://smoke_overlay.json"
		DirAccess.remove_absolute(overlay_path)
	load_city()


func _process(delta: float) -> void:
	if not _dirty:
		return
	_autosave_left -= delta
	if _autosave_left <= 0.0:
		save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()


# --------------------------------------------------------------------- loading

func load_city() -> void:
	type_data = _read_json(TYPES_PATH)
	var base := _read_json(BASE_PATH)
	city_name = str(base.get("name", city_name))
	chunk_size = float(base.get("chunk_size", 64.0))
	grid = base.get("grid", {})
	environment = base.get("environment", {})
	districts.clear()
	for d in base.get("districts", []):
		districts[str(d["id"])] = d
	blocks = base.get("blocks", [])
	roads = base.get("roads", [])

	overlay = {"version": 1, "added": [], "removed": [], "player": {}}
	if FileAccess.file_exists(overlay_path):
		var ov := _read_json(overlay_path)
		for k in ov:
			overlay[k] = ov[k]

	objects.clear()
	_chunk_objects.clear()
	_chunk_blocks.clear()
	_chunk_roads.clear()
	var removed := {}
	for id in overlay["removed"]:
		removed[str(id)] = true
	for kind in ["buildings", "props"]:
		for o in base.get(kind, []):
			if not removed.has(str(o["id"])):
				_index_object(o)
	for o in overlay["added"]:
		_index_object(o)

	bounds = Rect2()
	var first := true
	for blk in blocks:
		var r := block_rect(blk)
		_append(_chunk_blocks, chunk_key_2d(r.get_center()), blk)
		bounds = r if first else bounds.merge(r)
		first = false
	for road in roads:
		var rr := road_rect(road)
		_append(_chunk_roads, chunk_key_2d(rr.get_center()), road)
		bounds = rr if first else bounds.merge(rr)
		first = false


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("CityData: missing file " + path)
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		return data
	push_error("CityData: could not parse " + path)
	return {}


func _index_object(o: Dictionary) -> void:
	var id := str(o["id"])
	objects[id] = o
	_append(_chunk_objects, chunk_key(object_position(o)), id)


func _append(dict: Dictionary, key: Vector2i, value: Variant) -> void:
	if not dict.has(key):
		dict[key] = []
	dict[key].append(value)


# ------------------------------------------------------------------- geometry

func chunk_key(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / chunk_size), floori(p.z / chunk_size))


func chunk_key_2d(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / chunk_size), floori(p.y / chunk_size))


func object_position(o: Dictionary) -> Vector3:
	var p: Array = o["pos"]
	return Vector3(float(p[0]), float(o.get("y", 0.0)), float(p[1]))


func object_transform(o: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(float(o.get("rot", 0.0)))), object_position(o))


func type_footprint(type_id: String) -> Vector2:
	var def: Dictionary = type_data.get("types", {}).get(type_id, {})
	var fp: Array = def.get("footprint", [2, 2])
	return Vector2(float(fp[0]), float(fp[1]))


func footprint_rect(center: Vector2, fp: Vector2, rot_deg: float) -> Rect2:
	var a := deg_to_rad(rot_deg)
	var c := absf(cos(a))
	var s := absf(sin(a))
	var ext := Vector2(fp.x * c + fp.y * s, fp.x * s + fp.y * c)
	return Rect2(center - ext * 0.5, ext)


func object_rect(o: Dictionary) -> Rect2:
	var p := object_position(o)
	return footprint_rect(Vector2(p.x, p.z), type_footprint(str(o["type"])), float(o.get("rot", 0.0)))


func block_rect(blk: Dictionary) -> Rect2:
	var r: Array = blk["rect"]
	return Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))


func road_rect(road: Dictionary) -> Rect2:
	var a := Vector2(float(road["a"][0]), float(road["a"][1]))
	var b := Vector2(float(road["b"][0]), float(road["b"][1]))
	var h := float(road.get("width", 8.0)) * 0.5
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(h, h)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(h, h)
	return Rect2(lo, hi - lo)


func _keys_for_rect(r: Rect2) -> Array:
	var keys := []
	for x in range(floori(r.position.x / chunk_size), floori(r.end.x / chunk_size) + 1):
		for z in range(floori(r.position.y / chunk_size), floori(r.end.y / chunk_size) + 1):
			keys.append(Vector2i(x, z))
	return keys


# --------------------------------------------------------------------- queries

func has_chunk(key: Vector2i) -> bool:
	return _chunk_objects.has(key) or _chunk_blocks.has(key) or _chunk_roads.has(key)


func all_chunk_keys() -> Array:
	var keys := {}
	for d in [_chunk_objects, _chunk_blocks, _chunk_roads]:
		for k in d:
			keys[k] = true
	return keys.keys()


func get_chunk_objects(key: Vector2i) -> Array:
	var out := []
	for id in _chunk_objects.get(key, []):
		out.append(objects[id])
	return out


func get_chunk_blocks(key: Vector2i) -> Array:
	return _chunk_blocks.get(key, [])


func get_chunk_roads(key: Vector2i) -> Array:
	return _chunk_roads.get(key, [])


## True when a footprint at `center` overlaps no object and no road.
func is_area_free(center: Vector3, fp: Vector2, rot_deg: float, ignore_id := "") -> bool:
	var r := footprint_rect(Vector2(center.x, center.z), fp, rot_deg).grow(-0.25)
	for key in _keys_for_rect(r.grow(chunk_size * 0.5)):
		for id in _chunk_objects.get(key, []):
			if id != ignore_id and r.intersects(object_rect(objects[id])):
				return false
		for road in _chunk_roads.get(key, []):
			if r.intersects(road_rect(road)):
				return false
	return true


# --------------------------------------------------------------------- editing

## Adds a player-built object (stored in the overlay). Returns its unique id.
func add_object(type_id: String, pos: Vector3, rot_deg: float, variant: int, district := "") -> String:
	_uid_counter += 1
	var id := "u_%d_%d" % [int(Time.get_unix_time_from_system()), _uid_counter]
	while objects.has(id):
		_uid_counter += 1
		id = "u_%d_%d" % [int(Time.get_unix_time_from_system()), _uid_counter]
	var o := {
		"id": id, "type": type_id,
		"pos": [snappedf(pos.x, 0.01), snappedf(pos.z, 0.01)],
		"rot": fposmod(rot_deg, 360.0), "variant": variant, "district": district,
	}
	overlay["added"].append(o)
	_index_object(o)
	_mark_dirty()
	chunk_changed.emit(chunk_key(pos))
	return id


## Removes any object. Base objects are remembered in overlay["removed"].
## Returns the removed object (for undo) or an empty dict.
func remove_object(id: String) -> Dictionary:
	if not objects.has(id):
		return {}
	var o: Dictionary = objects[id]
	objects.erase(id)
	var key := chunk_key(object_position(o))
	_chunk_objects[key].erase(id)
	var added: Array = overlay["added"]
	var i := _find_by_id(added, id)
	if i >= 0:
		added.remove_at(i)
	else:
		overlay["removed"].append(id)
	_mark_dirty()
	chunk_changed.emit(key)
	return o


## Puts back an object returned by remove_object (undo).
func restore_object(o: Dictionary) -> void:
	var id := str(o["id"])
	if objects.has(id):
		return
	var removed: Array = overlay["removed"]
	if removed.has(id):
		removed.erase(id)
	else:
		overlay["added"].append(o)
	_index_object(o)
	_mark_dirty()
	chunk_changed.emit(chunk_key(object_position(o)))


func _find_by_id(list: Array, id: String) -> int:
	for i in list.size():
		if str(list[i]["id"]) == id:
			return i
	return -1


func get_player_state() -> Dictionary:
	return overlay.get("player", {})


func set_player_state(state: Dictionary) -> void:
	overlay["player"] = state


func get_player_spawn() -> Vector3:
	var st := get_player_state()
	if st.has("pos"):
		var p: Array = st["pos"]
		return Vector3(float(p[0]), float(p[1]) + 0.5, float(p[2]))
	if environment.has("spawn"):
		var s: Array = environment["spawn"]
		return Vector3(float(s[0]), 1.0, float(s[1]))
	var c := bounds.get_center()
	return Vector3(c.x, 1.0, c.y)


# ---------------------------------------------------------------------- saving

func mark_dirty() -> void:
	_mark_dirty()


func _mark_dirty() -> void:
	if not _dirty:
		_autosave_left = AUTOSAVE_SECONDS
	_dirty = true


## Atomic save: write .tmp, keep the previous file as .bak, then rename.
func save() -> bool:
	before_save.emit()
	overlay["saved_at"] = Time.get_datetime_string_from_system()
	var tmp := overlay_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("CityData: cannot write " + tmp)
		return false
	f.store_string(JSON.stringify(overlay, "\t"))
	f.close()
	if FileAccess.file_exists(overlay_path):
		DirAccess.copy_absolute(overlay_path, overlay_path + ".bak")
		DirAccess.remove_absolute(overlay_path)
	DirAccess.rename_absolute(tmp, overlay_path)
	_dirty = false
	saved.emit(overlay_path)
	return true
