extends "res://scripts/systems/city_system.gd"
## Ambient residents: potato people walking the sidewalk rings of the blocks,
## crossing at corners, stopping to look around or chat in pairs, and a few
## sitting on benches. Not interactive.
##
## Performance: one MultiMesh per look (≈8 draw calls at most). Only agents
## within RANGE of the camera are animated and drawn (they are packed into the
## first slots and visible_instance_count is set), far agents are stepped
## every 8th frame. Agents that drift far away are recycled to sidewalks near
## the camera, so the player always sees a lively street.

const SidewalkGraph = preload("res://scripts/npc/sidewalk_graph.gd")
const PotatoKit = preload("res://scripts/npc/potato_kit.gd")
const Places = preload("res://scripts/npc/npc_places.gd")

const RANGE := 120.0
const COUNTS := {"low": 20, "medium": 40, "high": 70}
const ROAD_Y := 0.05
const SITTER_LOOKS := 2
enum { WALK, IDLE, CHAT, SIT }

var graph
var _looks: Array = []
var _agents: Array = []
var _mms: Array = []       # walking MultiMesh per look, then seated ones
var _mmis: Array = []
var _counts := PackedInt32Array()
var _frame := 0
var _recycle_left := 0.5
var _rng := RandomNumberGenerator.new()
var _interior: Node


func setup(lib) -> void:
	super.setup(lib)
	name = "PedestrianSystem"
	_rng.seed = 2024
	graph = SidewalkGraph.new(11)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/npcs.json"))
	if parsed is Dictionary:
		_looks = parsed.get("pedestrian_looks", [])
	if _looks.is_empty():
		_looks = [{}]
	_build()


func on_settings_changed() -> void:
	_build()


func agent_count() -> int:
	return _agents.size()


func _build() -> void:
	for c in get_children():
		c.queue_free()
	_agents.clear()
	_mms.clear()
	_mmis.clear()
	if graph.is_empty():
		return
	var n: int = COUNTS.get(Settings.quality, 20)
	var nl := _looks.size()
	var n_mm := nl + mini(SITTER_LOOKS, nl)
	for i in n_mm:
		var seated := i >= nl
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = PotatoKit.build(_looks[i - nl if seated else i], library.material, seated)
		mm.instance_count = n
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_mms.append(mm)
		_mmis.append(mmi)
	_counts.resize(n_mm)

	# A few residents sit on benches (never on savta's bench).
	var savta_bench := Places.savta_bench()
	var benches := Places.of_type("bench").filter(func(b): return savta_bench.is_empty() or b["id"] != savta_bench["id"])
	var n_sit := mini(benches.size(), n / 8)
	for i in n_sit:
		var b: Dictionary = benches[_rng.randi() % benches.size()]
		benches.erase(b)
		var xf := CityData.object_transform(b)
		var p: Vector3 = xf * Vector3(_rng.randf_range(-0.4, 0.4), 0, 0.12)
		_agents.append({"state": SIT, "mm": nl + i % mini(SITTER_LOOKS, nl), "p3": Vector3(p.x, Places.SEAT_Y, p.z),
				"yaw": deg_to_rad(float(b.get("rot", 0.0))), "phase": _rng.randf() * 10.0, "acc": 0.0})
	var spawn := CityData.get_player_spawn()
	for i in n - n_sit:
		var blk := -1
		if i % 2 == 0:
			blk = graph.block_near(Vector2(spawn.x, spawn.z), 90.0)
		var w: Dictionary = graph.make_walker(blk)
		w["state"] = WALK
		w["mm"] = i % nl
		w["phase"] = _rng.randf() * 10.0
		w["pause"] = _rng.randf_range(3.0, 15.0)
		w["timer"] = 0.0
		w["yaw"] = 0.0
		w["acc"] = 0.0
		w["partner"] = -1
		_agents.append(w)


func _process(delta: float) -> void:
	if _agents.is_empty():
		return
	if _interior == null:
		_interior = get_tree().get_first_node_in_group("interior_system")
	if _interior != null and _interior.is_inside():
		if visible:
			visible = false
		return
	if not visible:
		visible = true
	var rig := get_tree().get_first_node_in_group("camera_rig")
	if rig == null:
		return
	var cam: Camera3D = rig.camera
	var cp := cam.global_position
	_frame += 1
	_counts.fill(0)
	var r2 := RANGE * RANGE
	for i in _agents.size():
		var a: Dictionary = _agents[i]
		var p := _pos3(a)
		if Vector2(p.x - cp.x, p.z - cp.z).length_squared() < r2:
			_update(i, a, delta + a["acc"])
			a["acc"] = 0.0
			var mmi: int = a["mm"]
			_mms[mmi].set_instance_transform(_counts[mmi], _xform(a))
			_counts[mmi] += 1
		else:
			a["acc"] += delta
			if (_frame + i) % 8 == 0:
				_update(i, a, a["acc"])
				a["acc"] = 0.0
	var box := AABB(Vector3(cp.x - RANGE, -1.0, cp.z - RANGE), Vector3(RANGE * 2.0, 4.0, RANGE * 2.0))
	for k in _mms.size():
		_mms[k].visible_instance_count = _counts[k]
		_mmis[k].custom_aabb = AABB(box.position - _mmis[k].global_position, box.size)
	_recycle_left -= delta
	if _recycle_left <= 0.0:
		_recycle_left = 0.5
		_recycle(cam)


func _pos3(a: Dictionary) -> Vector3:
	if a["state"] == SIT:
		return a["p3"]
	var p: Vector2 = a["pos"]
	return Vector3(p.x, ROAD_Y if a["cross"] else graph.CURB_Y, p.y)


func _xform(a: Dictionary) -> Transform3D:
	var p := _pos3(a)
	var yaw: float = a["yaw"]
	var roll := 0.0
	var ph: float = a["phase"]
	if a["state"] == WALK:
		p.y += absf(sin(ph)) * 0.07
		roll = sin(ph) * 0.07
	elif a["state"] == CHAT:
		p.y += maxf(sin(ph * 0.6), 0.0) * 0.03
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, roll)
	if a["state"] == SIT:
		b = b * Basis.from_scale(Vector3(1.0, 1.0 + sin(ph * 0.4) * 0.015, 1.0))
	return Transform3D(b, p)


func _update(i: int, a: Dictionary, dt: float) -> void:
	a["phase"] += dt * (8.0 if a["state"] == WALK else 2.0)
	match a["state"]:
		WALK:
			graph.step(a, dt)
			var h: Vector2 = a["heading"]
			a["yaw"] = lerp_angle(a["yaw"], atan2(h.x, h.y), minf(dt * 10.0, 1.0))
			if a["cross"]:
				return
			a["pause"] -= dt
			if a["pause"] <= 0.0:
				_start_pause(i, a)
		IDLE, CHAT:
			a["timer"] -= dt
			if a["timer"] <= 0.0:
				a["state"] = WALK
				a["partner"] = -1
				a["pause"] = _rng.randf_range(8.0, 22.0)


func _start_pause(i: int, a: Dictionary) -> void:
	var p: Vector2 = a["pos"]
	for j in _agents.size():
		var b: Dictionary = _agents[j]
		if j == i or b["state"] != WALK or b["cross"]:
			continue
		var q: Vector2 = b["pos"]
		var d := q - p
		if d.length_squared() < 9.0 and d.length_squared() > 0.25:
			var t := _rng.randf_range(4.0, 9.0)
			for pair in [[a, d], [b, -d]]:
				var ag: Dictionary = pair[0]
				var dd: Vector2 = pair[1]
				ag["state"] = CHAT
				ag["timer"] = t
				ag["yaw"] = atan2(dd.x, dd.y)
			a["partner"] = j
			b["partner"] = i
			return
	a["state"] = IDLE
	a["timer"] = _rng.randf_range(1.5, 4.0)
	a["yaw"] += _rng.randf_range(-1.2, 1.2)


## Moves walkers that are far from the camera onto sidewalks closer to it,
## preferably behind the camera so nobody pops into view.
func _recycle(cam: Camera3D) -> void:
	var cp := cam.global_position
	var c2 := Vector2(cp.x, cp.z)
	var fwd := -cam.global_transform.basis.z
	var f2 := Vector2(fwd.x, fwd.z).normalized()
	var moved := 0
	for a in _agents:
		if moved >= 3:
			break
		if a["state"] == SIT or a["cross"]:
			continue
		var p: Vector2 = a["pos"]
		if p.distance_to(c2) < RANGE + 15.0:
			continue
		for attempt in 6:
			var blk: int = graph.block_near(c2, 100.0)
			if blk < 0:
				break
			var w: Dictionary = graph.make_walker(blk)
			var q: Vector2 = w["pos"]
			var d := q.distance_to(c2)
			var behind := (q - c2).dot(f2) < 0.0
			if d > 35.0 and d < RANGE - 10.0 and (behind or d > 80.0 or cp.y > 30.0):
				for k in ["blk", "edge", "t", "dir", "pos", "heading"]:
					a[k] = w[k]
				a["state"] = WALK
				a["partner"] = -1
				moved += 1
				break
