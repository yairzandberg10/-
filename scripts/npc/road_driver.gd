extends RefCounted
## Minimal road-graph driver (same rules as traffic_system.gd: drive on the
## right, Bezier turns at intersections). Used for the police patrol cars.

const LANE := 1.9

var adj := {}  # Vector2i -> Array[Vector2]
var turn_r := 5.0
var rng := RandomNumberGenerator.new()


func _init(seed_value := 99) -> void:
	rng.seed = seed_value
	for r in CityData.roads:
		var a := Vector2(float(r["a"][0]), float(r["a"][1]))
		var b := Vector2(float(r["b"][0]), float(r["b"][1]))
		_link(a, b)
		_link(b, a)
		turn_r = maxf(turn_r, float(r.get("width", 8.0)) * 0.5 + 1.0)


func is_empty() -> bool:
	return adj.is_empty()


func make_car(speed := 7.0) -> Dictionary:
	var nodes := adj.keys()
	var a := Vector2(nodes[rng.randi() % nodes.size()])
	var nb: Array = adj[_key(a)]
	var b: Vector2 = nb[rng.randi() % nb.size()]
	var c := {"a": a, "b": b, "s": turn_r, "phase": 0, "speed": speed, "pos": a, "heading": Vector2(0, 1)}
	step(c, 0.0)
	return c


func step(c: Dictionary, delta: float) -> void:
	var dist: float = c["speed"] * delta
	if c["phase"] == 0:
		c["s"] += dist
		var a: Vector2 = c["a"]
		var b: Vector2 = c["b"]
		var length := a.distance_to(b)
		var d := (b - a) / length
		if c["s"] >= length - turn_r:
			_begin_turn(c, a, b, d, length)
		else:
			c["pos"] = a + d * c["s"] + _right(d) * LANE
			c["heading"] = d
			return
	c["t"] += dist / c["tlen"]
	if c["t"] >= 1.0:
		c["a"] = c["b"]
		c["b"] = c["next"]
		c["s"] = turn_r
		c["phase"] = 0
		var d2: Vector2 = (c["b"] - c["a"]).normalized()
		c["pos"] = c["a"] + d2 * turn_r + _right(d2) * LANE
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
	var options: Array = adj.get(_key(b), [])
	var choices := options.filter(func(p): return _key(p) != _key(a))
	var nxt: Vector2 = a if choices.is_empty() else choices[rng.randi() % choices.size()]
	var d2 := (nxt - b).normalized()
	var p0 := a + d1 * (length - turn_r) + _right(d1) * LANE
	var p2 := b + d2 * turn_r + _right(d2) * LANE
	var cr := d1.cross(d2)
	var ctrl: Vector2
	if absf(cr) < 0.01:
		ctrl = (p0 + p2) * 0.5 if d1.dot(d2) > 0.0 else b + d1 * turn_r
	else:
		ctrl = p0 + d1 * ((p2 - p0).cross(d2) / cr)
	c["p0"] = p0
	c["p2"] = p2
	c["ctrl"] = ctrl
	c["next"] = nxt
	c["phase"] = 1
	c["t"] = 0.0
	c["tlen"] = maxf(p0.distance_to(ctrl) + ctrl.distance_to(p2), 0.5)


func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x), roundi(p.y))


func _link(a: Vector2, b: Vector2) -> void:
	var k := _key(a)
	if not adj.has(k):
		adj[k] = []
	if not (adj[k] as Array).has(b):
		adj[k].append(b)


func _right(d: Vector2) -> Vector2:
	return Vector2(-d.y, d.x)
