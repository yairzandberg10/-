extends Node3D
## Streams the city in 64m chunks around the camera.
##
## Per chunk:
##   * ground  - blocks + roads merged into one mesh (1 draw call)
##   * near    - one MultiMesh per (type, colour) with full detail, shown up to lod_distance
##   * far     - every building's low-detail mesh baked into one mesh (1 draw call),
##               shown from lod_distance to far_distance
##   * props   - trees/lamps/benches as MultiMesh, hidden beyond prop_distance;
##               trees/umbrellas ("far" types) switch to a baked low-detail mesh
##   * physics - one StaticBody with a box per building
## Chunks are built a few per frame (no stutter) and freed when far away.

const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")
const GroundKit = preload("res://scripts/city/ground_kit.gd")
const SEA_SHADER = preload("res://shaders/sea.gdshader")

const LAYER_BUILDINGS := 2

var library  # BuildingLibrary
var focus: Node3D

var _loaded := {}  # Vector2i -> Node3D
var _queue: Array = []
var _scan_left := 0.0


func setup(lib) -> void:
	library = lib
	_build_static_ground()
	CityData.chunk_changed.connect(_on_chunk_changed)


func _process(delta: float) -> void:
	if focus == null:
		return
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = 0.25
		_update_wanted()
	var budget: int = Settings.get_v("chunks_per_frame")
	while budget > 0 and not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if not _loaded.has(key):
			_loaded[key] = _build_chunk(key)
			budget -= 1


func loaded_count() -> int:
	return _loaded.size()


func load_around_now(pos: Vector3, radius: int) -> void:
	var c := CityData.chunk_key(pos)
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var key := c + Vector2i(dx, dz)
			if CityData.has_chunk(key) and not _loaded.has(key):
				_loaded[key] = _build_chunk(key)


func load_all_now() -> void:
	for key in CityData.all_chunk_keys():
		if not _loaded.has(key):
			_loaded[key] = _build_chunk(key)


## Rebuild everything (after a quality change).
func reload_all() -> void:
	for key in _loaded:
		_loaded[key].queue_free()
	_loaded.clear()
	_queue.clear()
	if focus:
		load_around_now(focus.global_position, 1)
	_scan_left = 0.0


func stats() -> Dictionary:
	var s := {"chunks": _loaded.size(), "multimeshes": 0, "instances": 0, "meshes": 0, "shapes": 0}
	for key in _loaded:
		for n in _loaded[key].get_children():
			if n is MultiMeshInstance3D:
				s["multimeshes"] += 1
				s["instances"] += n.multimesh.instance_count
			elif n is MeshInstance3D:
				s["meshes"] += 1
			elif n is StaticBody3D:
				s["shapes"] += n.get_child_count()
	return s


func _update_wanted() -> void:
	var c := CityData.chunk_key(focus.global_position)
	var r: int = Settings.get_v("view_chunks")
	for key in _loaded.keys():
		if maxi(absi(key.x - c.x), absi(key.y - c.y)) > r + 1:
			_loaded[key].queue_free()
			_loaded.erase(key)
	var wanted := []
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var key := c + Vector2i(dx, dz)
			if not _loaded.has(key) and CityData.has_chunk(key):
				wanted.append(key)
	wanted.sort_custom(func(a, b): return (a - c).length_squared() < (b - c).length_squared())
	_queue = wanted


func _on_chunk_changed(key: Vector2i) -> void:
	if _loaded.has(key):
		_loaded[key].free()
		_loaded[key] = _build_chunk(key)
	elif focus and CityData.chunk_key(focus.global_position).distance_to(key) <= 2.0:
		_loaded[key] = _build_chunk(key)


# --------------------------------------------------------------- chunk build

func _build_chunk(key: Vector2i) -> Node3D:
	var cs := CityData.chunk_size
	var center := Vector3((key.x + 0.5) * cs, 0.0, (key.y + 0.5) * cs)
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [key.x, key.y]
	root.position = center
	add_child(root)

	var far: float = Settings.get_v("far_distance")
	var lod_d: float = Settings.get_v("lod_distance")
	var prop_d: float = Settings.get_v("prop_distance")
	var shadows: bool = Settings.get_v("shadows")
	var prop_shadows: bool = shadows and Settings.get_v("prop_shadows")

	var ground := MeshBuilder.new()
	ground.origin = center
	for blk in CityData.get_chunk_blocks(key):
		GroundKit.add_block(ground, blk)
	for road in CityData.get_chunk_roads(key):
		GroundKit.add_road(ground, road)
	if not ground.is_empty():
		_add_mesh(root, ground.commit(library.material), 0.0, far + cs, false)

	var groups := {}
	var far_mb := MeshBuilder.new()
	var far_props := MeshBuilder.new()
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_BUILDINGS
	body.collision_mask = 0
	for o in CityData.get_chunk_objects(key):
		var t := str(o["type"])
		if not library.has_type(t):
			continue
		var v: int = library.clamp_variant(t, int(o.get("variant", 0)))
		var xf := CityData.object_transform(o)
		xf.origin -= center
		var gk := "%s|%d" % [t, v]
		if not groups.has(gk):
			groups[gk] = []
		groups[gk].append(xf)
		if not library.is_prop(t) or library.has_far(t):
			var arr: Array = library.get_lod_arrays(t, v)
			if not arr.is_empty():
				(far_props if library.is_prop(t) else far_mb).add_colored_arrays(arr, xf)
		if library.collides(t):
			var col := CollisionShape3D.new()
			col.shape = library.get_shape(t)
			col.transform = xf * Transform3D(Basis(), Vector3(0, library.get_height(t) * 0.5, 0))
			col.set_meta("id", str(o["id"]))
			body.add_child(col)

	for gk in groups:
		var parts: PackedStringArray = gk.split("|")
		var t := parts[0]
		var mesh: ArrayMesh = library.get_mesh(t, int(parts[1]), false)
		if library.is_prop(t):
			_add_multimesh(root, mesh, groups[gk], 0.0, prop_d, prop_shadows)
		else:
			_add_multimesh(root, mesh, groups[gk], 0.0, lod_d, shadows)
	if not far_mb.is_empty():
		_add_mesh(root, far_mb.commit(library.material), lod_d, far, false)
	if not far_props.is_empty():
		_add_mesh(root, far_props.commit(library.material), prop_d, far, false)

	if body.get_child_count() > 0:
		root.add_child(body)
	else:
		body.free()
	return root


func _add_multimesh(root: Node3D, mesh: Mesh, xfs: Array, begin: float, end: float, shadows: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	_set_range(mmi, begin, end, shadows)
	root.add_child(mmi)


func _add_mesh(root: Node3D, mesh: Mesh, begin: float, end: float, shadows: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_set_range(mi, begin, end, shadows)
	root.add_child(mi)


func _set_range(gi: GeometryInstance3D, begin: float, end: float, shadows: bool) -> void:
	gi.visibility_range_begin = begin
	gi.visibility_range_end = end
	gi.visibility_range_begin_margin = 4.0 if begin > 0.0 else 0.0
	gi.visibility_range_end_margin = 4.0
	gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# ------------------------------------------------------------ static ground

## Grass around the city, beach and sea (from data/city.json "environment").
func _build_static_ground() -> void:
	var env := CityData.environment
	var b := CityData.bounds.grow(1500.0)
	var mb := MeshBuilder.new()
	var has_sea := env.has("sea_x")
	var beach_x := float(env.get("beach_x", b.position.x)) if has_sea else b.position.x
	var sea_x := float(env.get("sea_x", beach_x - 40.0))
	var gw := b.end.x - beach_x
	mb.add_box(Vector3(gw, 0.2, b.size.y), Vector3(beach_x + gw * 0.5, -0.1, b.get_center().y), GroundKit.color("grass"))
	if has_sea:
		mb.add_box(Vector3(beach_x - sea_x, 0.2, b.size.y), Vector3((sea_x + beach_x) * 0.5, -0.1, b.get_center().y), GroundKit.color("sand"))
	var gi := MeshInstance3D.new()
	gi.name = "Ground"
	gi.mesh = mb.commit(library.material)
	gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gi)

	if has_sea:
		var sea := MeshInstance3D.new()
		sea.name = "Sea"
		var pm := PlaneMesh.new()
		pm.size = Vector2(3000.0, b.size.y)
		sea.mesh = pm
		var mat := ShaderMaterial.new()
		mat.shader = SEA_SHADER
		mat.set_shader_parameter("shore_x", sea_x)
		sea.material_override = mat
		sea.position = Vector3(sea_x - 1500.0 + 2.0, -0.25, b.get_center().y)
		sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(sea)

	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	floor_body.add_child(shape)
	add_child(floor_body)
