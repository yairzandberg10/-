extends Node3D
## Cheap pooled visual effects. Each kind is ONE MultiMesh of tiny spheres
## (a single draw call), puffs grow, rise and shrink away.
##   Effects.puff(pos, "dust" | "smoke" | "splash" | "sparkle", count := 4)
## Also flies a few birds/seagulls around the camera for life in the sky.

const KINDS := {
	"dust": {"color": Color("d9c9a3"), "size": 0.35, "life": 0.6, "rise": 0.6, "spread": 0.8},
	"smoke": {"color": Color("b9bcc2"), "size": 0.3, "life": 0.9, "rise": 1.2, "spread": 0.3},
	"splash": {"color": Color("e8f6ff"), "size": 0.22, "life": 0.5, "rise": 2.5, "spread": 1.2},
	"sparkle": {"color": Color("ffe27a"), "size": 0.15, "life": 0.7, "rise": 1.5, "spread": 1.0},
}
const PER_KIND := 48
const BIRDS := 7

var _pools := {}  # kind -> {"mm": MultiMesh, "parts": Array, "next": int}
var _birds: MultiMesh
var _bird_state: Array = []
var _time := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 6
	sphere.rings = 3
	for kind in KINDS:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = KINDS[kind]["color"]
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if kind == "sparkle" else BaseMaterial3D.SHADING_MODE_PER_VERTEX
		var m := sphere.duplicate()
		m.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m
		mm.instance_count = PER_KIND
		for i in PER_KIND:
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-5000, -50, -5000), Vector3(10000, 300, 10000))
		add_child(mmi)
		var parts := []
		for i in PER_KIND:
			parts.append({"age": 9.0, "life": 1.0, "pos": Vector3.ZERO, "vel": Vector3.ZERO, "size": 0.0})
		_pools[kind] = {"mm": mm, "parts": parts, "next": 0}
	_make_birds()


func puff(pos: Vector3, kind := "dust", count := 4) -> void:
	if not _pools.has(kind):
		return
	var cfg: Dictionary = KINDS[kind]
	var pool: Dictionary = _pools[kind]
	for i in count:
		var p: Dictionary = pool["parts"][pool["next"]]
		pool["next"] = (int(pool["next"]) + 1) % PER_KIND
		var spread: float = cfg["spread"]
		p["age"] = 0.0
		p["life"] = float(cfg["life"]) * randf_range(0.7, 1.2)
		p["pos"] = pos + Vector3(randf_range(-0.2, 0.2), 0.0, randf_range(-0.2, 0.2))
		p["vel"] = Vector3(randf_range(-spread, spread), float(cfg["rise"]) * randf_range(0.6, 1.2), randf_range(-spread, spread))
		p["size"] = float(cfg["size"]) * randf_range(0.7, 1.3)


func _process(delta: float) -> void:
	_time += delta
	for kind in _pools:
		var pool: Dictionary = _pools[kind]
		var mm: MultiMesh = pool["mm"]
		var parts: Array = pool["parts"]
		var grav := 6.0 if kind == "splash" else 0.0
		for i in PER_KIND:
			var p: Dictionary = parts[i]
			if p["age"] >= p["life"]:
				continue
			p["age"] += delta
			p["vel"] = (p["vel"] as Vector3) * (1.0 - 2.0 * delta) + Vector3(0, -grav * delta, 0)
			p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
			var k: float = clampf(p["age"] / p["life"], 0.0, 1.0)
			var s: float = p["size"] * sin(k * PI) * (1.0 + k)
			if p["age"] >= p["life"]:
				s = 0.0
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * maxf(s, 0.0)), p["pos"]))
	_update_birds(delta)


# ----------------------------------------------------------------------- birds

func _make_birds() -> void:
	# A bird is two thin wings (V shape) built from boxes; flapping = scaling wings in Y via basis.
	var mb := preload("res://scripts/core/mesh_builder.gd").new()
	mb.add_box(Vector3(0.9, 0.05, 0.3), Vector3(-0.42, 0.12, 0), Color.WHITE, 0.0)
	mb.add_box(Vector3(0.9, 0.05, 0.3), Vector3(0.42, 0.12, 0), Color.WHITE, 0.0)
	mb.add_box(Vector3(0.18, 0.15, 0.5), Vector3(0, 0, 0), Color.WHITE, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("f4f4f0")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	_birds = MultiMesh.new()
	_birds.transform_format = MultiMesh.TRANSFORM_3D
	_birds.mesh = mb.commit(mat)
	_birds.instance_count = BIRDS
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _birds
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-5000, -50, -5000), Vector3(10000, 300, 10000))
	add_child(mmi)
	for i in BIRDS:
		_bird_state.append({"a": randf() * TAU, "r": randf_range(25, 70), "h": randf_range(18, 34),
				"speed": randf_range(0.12, 0.22) * (1 if i % 2 else -1), "phase": randf() * TAU,
				"center": Vector3.ZERO})


func _update_birds(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _birds == null:
		return
	var c := cam.global_position
	for i in BIRDS:
		var b: Dictionary = _bird_state[i]
		var center: Vector3 = b["center"]
		if center == Vector3.ZERO or center.distance_to(Vector3(c.x, 0, c.z)) > 160.0:
			center = Vector3(c.x + randf_range(-40, 40), 0, c.z + randf_range(-40, 40))
			b["center"] = center
		b["a"] = float(b["a"]) + float(b["speed"]) * delta
		var a: float = b["a"]
		var r: float = b["r"]
		var pos := center + Vector3(cos(a) * r, b["h"], sin(a) * r)
		var dir := Vector3(-sin(a), 0, cos(a)) * signf(b["speed"])
		# Flapping = wingspan pulsing; from 20m+ away it reads as wing beats.
		var flap := 0.35 + 0.65 * absf(sin(_time * 7.0 + float(b["phase"])))
		var basis := Basis.looking_at(dir, Vector3.UP) * Basis.from_scale(Vector3(flap, 1.0, 1.0))
		_birds.set_instance_transform(i, Transform3D(basis, pos))
