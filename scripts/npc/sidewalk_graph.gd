extends RefCounted
## Walkable sidewalk loops built from CityData.blocks. Each block's sidewalk
## ring (outer `sidewalk` metres of its rect) becomes a closed loop through 4
## corners at the ring's centre line. Corners that face a neighbouring block
## straight across a road are linked so walkers can cross at the corners.
##
## A walker is a Dictionary moved by step():
##   blk, edge (0..3), t (metres along edge), dir (+1/-1), speed,
##   side (lateral offset), pos (Vector2), heading (Vector2),
##   cross (bool) + cross_from / cross_to / cross_t while crossing.

const CURB_Y := 0.12

var loops: Array = []  # Array of {"c": [Vector2 x4], "len": [float x4]}
var links: Array = []  # loops index -> Array (per corner) of [blk, corner]
var rng := RandomNumberGenerator.new()


func _init(seed_value := 7) -> void:
	rng.seed = seed_value
	for blk in CityData.blocks:
		var r: Rect2 = CityData.block_rect(blk)
		var inset := float(blk.get("sidewalk", 3.0)) * 0.5
		r = r.grow(-inset)
		if r.size.x < 2.0 or r.size.y < 2.0:
			continue
		# Clockwise seen from above (x east, z south): NW, NE, SE, SW.
		var c := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
		var lens := []
		for i in 4:
			lens.append((c[(i + 1) % 4] as Vector2).distance_to(c[i]))
		loops.append({"c": c, "len": lens, "rect": r})
	for i in loops.size():
		var per := []
		for k in 4:
			per.append([])
		links.append(per)
	for i in loops.size():
		for k in 4:
			var p: Vector2 = loops[i]["c"][k]
			for j in loops.size():
				if j == i:
					continue
				for m in 4:
					var q: Vector2 = loops[j]["c"][m]
					var d := q - p
					if d.length() < 16.0 and d.length() > 3.0 and (absf(d.x) < 0.8 or absf(d.y) < 0.8):
						links[i][k].append([j, m])


func is_empty() -> bool:
	return loops.is_empty()


func corner(blk: int, k: int) -> Vector2:
	return loops[blk]["c"][posmod(k, 4)]


## Places a new walker at a random spot of block `blk` (random block if -1).
func make_walker(blk := -1) -> Dictionary:
	if blk < 0:
		blk = rng.randi() % loops.size()
	var edge := rng.randi() % 4
	var w := {
		"blk": blk, "edge": edge, "t": rng.randf() * float(loops[blk]["len"][edge]),
		"dir": 1 if rng.randf() < 0.5 else -1, "speed": rng.randf_range(1.0, 1.5),
		"side": rng.randf_range(-0.5, 0.5), "pos": Vector2.ZERO, "heading": Vector2(0, 1),
		"cross": false,
	}
	_update_pos(w)
	return w


## Moves a walker `delta` seconds forward; `cross_chance` at each corner.
func step(w: Dictionary, delta: float, cross_chance := 0.3) -> void:
	var dist: float = w["speed"] * delta
	if w["cross"]:
		var a: Vector2 = w["cross_from"]
		var b: Vector2 = w["cross_to"]
		w["cross_t"] += dist
		var L := a.distance_to(b)
		if w["cross_t"] >= L:
			w["cross"] = false
			w["pos"] = b
			_start_from_corner(w, int(w["to_blk"]), int(w["to_corner"]))
		else:
			w["heading"] = (b - a) / L
			w["pos"] = a + w["heading"] * w["cross_t"]
		return
	var guard := 0
	while dist > 0.0 and guard < 4:
		guard += 1
		var blk: int = w["blk"]
		var e: int = w["edge"]
		var L: float = loops[blk]["len"][e]
		if w["dir"] > 0:
			var room: float = L - w["t"]
			if dist < room:
				w["t"] += dist
				dist = 0.0
			else:
				dist -= room
				if _arrive_corner(w, (e + 1) % 4, cross_chance):
					return
		else:
			var room2: float = w["t"]
			if dist < room2:
				w["t"] -= dist
				dist = 0.0
			else:
				dist -= room2
				if _arrive_corner(w, e, cross_chance):
					return
	_update_pos(w)


## At corner `k` of the current block: maybe cross, else continue around.
func _arrive_corner(w: Dictionary, k: int, cross_chance: float) -> bool:
	var blk: int = w["blk"]
	var opts: Array = links[blk][k]
	if not opts.is_empty() and rng.randf() < cross_chance:
		var o: Array = opts[rng.randi() % opts.size()]
		w["cross"] = true
		w["cross_from"] = corner(blk, k)
		w["cross_to"] = corner(o[0], o[1])
		w["cross_t"] = 0.0
		w["to_blk"] = o[0]
		w["to_corner"] = o[1]
		w["pos"] = w["cross_from"]
		return true
	_start_from_corner(w, blk, k)
	return false


func _start_from_corner(w: Dictionary, blk: int, k: int) -> void:
	w["blk"] = blk
	if rng.randf() < 0.15:
		w["dir"] = -int(w["dir"])
	if w["dir"] > 0:
		w["edge"] = k
		w["t"] = 0.0
	else:
		w["edge"] = posmod(k - 1, 4)
		w["t"] = float(loops[blk]["len"][w["edge"]])
	_update_pos(w)


func _update_pos(w: Dictionary) -> void:
	var blk: int = w["blk"]
	var e: int = w["edge"]
	var a := corner(blk, e)
	var b := corner(blk, e + 1)
	var d := (b - a).normalized()
	var side := Vector2(-d.y, d.x) * float(w["side"])
	w["pos"] = a + d * float(w["t"]) + side
	w["heading"] = d * float(w["dir"])


## Index of a random loop whose rect is within `max_d` of `center` (-1: none).
func block_near(center: Vector2, max_d: float) -> int:
	var cands := []
	for i in loops.size():
		var r: Rect2 = loops[i]["rect"]
		var cx := clampf(center.x, r.position.x, r.end.x)
		var cz := clampf(center.y, r.position.y, r.end.y)
		if Vector2(cx, cz).distance_to(center) < max_d:
			cands.append(i)
	if cands.is_empty():
		return -1
	return cands[rng.randi() % cands.size()]
