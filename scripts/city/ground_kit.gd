extends RefCounted
## Geometry for city blocks (raised sidewalk + lot surface) and roads
## (asphalt, centre dashes, zebra crossings). Everything is written into a
## MeshBuilder so a whole chunk of ground becomes a single draw call.

const COLORS := {
	"sidewalk": "d3ccbc", "asphalt": "5b5f66", "marking": "f4f1e6",
	"residential": "8fc46b", "apartments": "9fcd7a", "park": "7dbb5f",
	"plaza": "dccfb2", "commercial": "d6d0c4", "civic": "b5d68c",
	"grass": "9ccc74", "sand": "ecd9a8", "default": "a8cf86",
}
const CURB_H := 0.12
const INNER_H := 0.15
const ROAD_H := 0.05
const MARK_Y := 0.065


static func color(key: String) -> Color:
	return Color.html(str(COLORS.get(key, COLORS["default"])))


static func add_block(mb, blk: Dictionary) -> void:
	var r: Array = blk["rect"]
	var x0 := float(r[0])
	var z0 := float(r[1])
	var x1 := float(r[2])
	var z1 := float(r[3])
	var w := x1 - x0
	var d := z1 - z0
	var c := Vector3((x0 + x1) * 0.5, 0.0, (z0 + z1) * 0.5)
	mb.add_box(Vector3(w, CURB_H, d), c + Vector3(0, CURB_H * 0.5, 0), color("sidewalk"))
	var s := float(blk.get("sidewalk", 3.0))
	if w > 2.0 * s and d > 2.0 * s:
		var h := INNER_H - CURB_H + 0.01
		mb.add_box(Vector3(w - 2.0 * s, h, d - 2.0 * s), c + Vector3(0, CURB_H - 0.01 + h * 0.5, 0),
				color(str(blk.get("type", "default"))))


static func add_road(mb, road: Dictionary) -> void:
	var a := Vector3(float(road["a"][0]), 0.0, float(road["a"][1]))
	var b := Vector3(float(road["b"][0]), 0.0, float(road["b"][1]))
	var w := float(road.get("width", 8.0))
	var v := b - a
	var length := v.length()
	if length < 0.01:
		return
	var dir := v / length
	var yaw := atan2(dir.x, dir.z)
	var side := Vector3(dir.z, 0.0, -dir.x)
	# Asphalt is extended by w/2 at both ends so intersections are covered.
	mb.add_box(Vector3(w, ROAD_H, length + w), (a + b) * 0.5 + Vector3(0, ROAD_H * 0.5, 0), color("asphalt"), yaw)
	var mark := color("marking")
	var lift := Vector3(0, MARK_Y, 0)
	var s := w * 0.5 + 4.0
	while s + 2.0 <= length - w * 0.5 - 4.0:
		mb.add_box(Vector3(0.15, 0.02, 2.0), a + dir * (s + 1.0) + lift, mark, yaw)
		s += 4.0
	var along := w * 0.5 + 1.6
	var stripes := 6
	for p in [a + dir * along, b - dir * along]:
		for k in stripes:
			var off := -w * 0.5 + 0.9 + k * (w - 1.8) / (stripes - 1)
			mb.add_box(Vector3(0.45, 0.02, 2.2), p + side * off + lift, mark, yaw)
