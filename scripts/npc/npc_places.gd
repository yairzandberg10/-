extends RefCounted
## Shared lookups for where characters live, so the NPC, pedestrian and
## interior systems agree (e.g. pedestrians never sit on savta's bench).

const SEAT_Y := 0.27       # node height of a seated potato on a bench
const BLOCK_Y := 0.15      # top of a block's inner lot (park, plaza...)
const CURB_Y := 0.12       # sidewalk top


## Objects of `type` sorted by id (stable "first" building of a kind).
static func of_type(type_id: String) -> Array:
	var out := []
	for id in CityData.objects:
		var o: Dictionary = CityData.objects[id]
		if str(o["type"]) == type_id:
			out.append(o)
	out.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	return out


static func first_of_type(type_id: String) -> Dictionary:
	var l := of_type(type_id)
	return l[0] if not l.is_empty() else {}


static func nearest_of_type(type_id: String, p: Vector3) -> Dictionary:
	var best := {}
	var bd := INF
	for o in of_type(type_id):
		var d := CityData.object_position(o).distance_to(p)
		if d < bd:
			bd = d
			best = o
	return best


## The bench savta sits on: the one closest to the potato statue.
static func savta_bench() -> Dictionary:
	var statue := first_of_type("potato_statue")
	if statue.is_empty():
		return {}
	return nearest_of_type("bench", CityData.object_position(statue))


## Point outside the front door of a building (world space, y = 0).
static func door_position(o: Dictionary, extra := 0.6) -> Vector3:
	var fp := CityData.type_footprint(str(o["type"]))
	var p: Vector3 = CityData.object_transform(o) * Vector3(0, 0, fp.y * 0.5 + extra)
	p.y = 0.0
	return p


## Ground height under a point: block lot, sidewalk ring or road/beach.
static func ground_y(p: Vector2) -> float:
	for blk in CityData.blocks:
		var r: Rect2 = CityData.block_rect(blk)
		if r.has_point(p):
			var s := float(blk.get("sidewalk", 3.0))
			return BLOCK_Y if r.grow(-s).has_point(p) else CURB_Y
	return 0.0
