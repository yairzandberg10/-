extends "res://scripts/systems/city_system.gd"
## Simple ambient traffic: cars follow the road graph from data/city.json,
## drive on the right, and take smooth (quadratic Bezier) turns at
## intersections. All cars of one colour are a single MultiMesh, so 40 cars
## cost a handful of draw calls. Car count comes from the quality preset.

const LANE := 1.9
const CAR_Y := 0.05

var _adj := {}  # Vector2i node -> Array[Vector2] neighbour positions
var _cars: Array = []
var _mms: Array = []
var _turn_r := 5.0
var _rng := RandomNumberGenerator.new()


func setup(lib) -> void:
	super.setup(lib)
	add_to_group("traffic_system")
	_rng.seed = 1234
	for r in CityData.roads:
		var a := Vector2(float(r["a"][0]), float(r["a"][1]))
		var b := Vector2(float(r["b"][0]), float(r["b"][1]))
		_link(a, b)
		_link(b, a)
		_turn_r = maxf(_turn_r, float(r.get("width", 8.0)) * 0.5 + 1.0)
	set_count(Settings.get_v("cars"))


func on_settings_changed() -> void:
	set_count(Settings.get_v("cars"))


func set_count(n: int) -> void:
	for c in get_children():
		c.queue_free()
	_cars.clear()
	_mms.clear()
	if _adj.is_empty() or not library.has_type("car") or n <= 0:
		return
	var nv: int = library.variant_count("car")
	var per := []
	per.resize(nv)
	per.fill(0)
	var nodes := _adj.keys()
	for i in n:
		var v := i % nv
		var a_key: Vector2i = nodes[_rng.randi() % nodes.size()]
		var a := Vector2(a_key)
		var nbrs: Array = _adj[a_key]
		var b: Vector2 = nbrs[_rng.randi() % nbrs.size()]
		var car := {
			"a": a, "b": b, "s": _rng.randf_range(_turn_r, maxf(a.distance_to(b) - _turn_r, _turn_r)),
			"phase": 0, "speed": _rng.randf_range(5.0, 9.0), "mm": v, "slot": per[v],
			"pos": a, "heading": Vector2(0, 1),
		}
		per[v] += 1
		_cars.append(car)
	var b := CityData.bounds.grow(50.0)
	for v in nv:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = library.get_mesh("car", v, false)
		mm.instance_count = per[v]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(b.position.x, -1, b.position.y), Vector3(b.size.x, 4, b.size.y))
		add_child(mmi)
		_mms.append(mm)
	for car in _cars:
		_step(car, 0.0)


func _process(delta: float) -> void:
	for car in _cars:
		_step(car, delta)
		var h: Vector2 = car["heading"]
		var p: Vector2 = car["pos"]
		_mms[car["mm"]].set_instance_transform(car["slot"],
				Transform3D(Basis(Vector3.UP, atan2(h.x, h.y)), Vector3(p.x, CAR_Y, p.y)))


## Distance from `pos` to the closest traffic car (used for bumping the player's car).
func nearest_car_distance(pos: Vector3) -> float:
	var best := INF
	var p2 := Vector2(pos.x, pos.z)
	for car in _cars:
		best = minf(best, p2.distance_to(car["pos"]))
	return best


func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x), roundi(p.y))


func _link(a: Vector2, b: Vector2) -> void:
	var k := _key(a)
	if not _adj.has(k):
		_adj[k] = []
	if not (_adj[k] as Array).has(b):
		_adj[k].append(b)


func _right(d: Vector2) -> Vector2:
	return Vector2(-d.y, d.x)


func _step(c: Dictionary, delta: float) -> void:
	var dist: float = c["speed"] * delta
	if c["phase"] == 0:
		c["s"] += dist
		var a: Vector2 = c["a"]
		var b: Vector2 = c["b"]
		var length := a.distance_to(b)
		var d := (b - a) / length
		if c["s"] >= length - _turn_r:
			_begin_turn(c, a, b, d, length)
		else:
			c["pos"] = a + d * c["s"] + _right(d) * LANE
			c["heading"] = d
			return
	c["t"] += dist / c["tlen"]
	if c["t"] >= 1.0:
		c["a"] = c["b"]
		c["b"] = c["next"]
		c["s"] = _turn_r
		c["phase"] = 0
		var d2: Vector2 = (c["b"] - c["a"]).normalized()
		c["pos"] = c["a"] + d2 * _turn_r + _right(d2) * LANE
		c["heading"] = d2
		return
	var u: float = c["t"]
	var p0: Vector2 = c["p0"]
	var p1: Vector2 = c["ctrl"]
	var p2: Vector2 = c["p2"]
	c["pos"] = p0 * (1.0 - u) * (1.0 - u) + p1 * 2.0 * u * (1.0 - u) + p2 * u * u
	var tan := (p1 - p0) * 2.0 * (1.0 - u) + (p2 - p1) * 2.0 * u
	if tan.length_squared() > 1e-6:
		c["heading"] = tan.normalized()


func _begin_turn(c: Dictionary, a: Vector2, b: Vector2, d1: Vector2, length: float) -> void:
	var options: Array = _adj.get(_key(b), [])
	var choices := options.filter(func(p): return _key(p) != _key(a))
	var nxt: Vector2 = a if choices.is_empty() else choices[_rng.randi() % choices.size()]
	var d2 := (nxt - b).normalized()
	var p0 := a + d1 * (length - _turn_r) + _right(d1) * LANE
	var p2 := b + d2 * _turn_r + _right(d2) * LANE
	var cr := d1.cross(d2)
	var ctrl: Vector2
	if absf(cr) < 0.01:
		ctrl = (p0 + p2) * 0.5 if d1.dot(d2) > 0.0 else b + d1 * _turn_r
	else:
		ctrl = p0 + d1 * ((p2 - p0).cross(d2) / cr)
	c["p0"] = p0
	c["p2"] = p2
	c["ctrl"] = ctrl
	c["next"] = nxt
	c["phase"] = 1
	c["t"] = 0.0
	c["tlen"] = maxf(p0.distance_to(ctrl) + ctrl.distance_to(p2), 0.5)
