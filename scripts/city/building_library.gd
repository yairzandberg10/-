extends RefCounted
## Turns building type definitions (data/building_types.json) into meshes.
## Each (type, colour variant, LOD) is built once and cached, then reused by
## every instance in the city through MultiMesh.
##
## A type is a list of primitive "parts":
##   {"shape": "box"|"gable"|"cylinder"|"cone"|"sphere", "size"/"radius"/...,
##    "pos": [x,y,z], "rot": [deg,deg,deg], "scale": [x,y,z],
##    "color": "#hex" | colour-slot name | palette name,
##    "lod": true      -> part is kept in the far low-detail mesh
##    "array": {"x": [count, step], "y": [...], "z": [...]}  -> repeated, centred on pos
##    "around": N      -> repeated N times around the Y axis (windows on all sides)}

const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")

var types: Dictionary
var palette: Dictionary
var material := StandardMaterial3D.new()

var _meshes := {}
var _lod_arrays := {}
var _shapes := {}
var _heights := {}


func _init(type_data: Dictionary) -> void:
	types = type_data.get("types", {})
	palette = type_data.get("palette", {})
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	material.metallic_specular = 0.05


func set_per_vertex(on: bool) -> void:
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX if on else BaseMaterial3D.SHADING_MODE_PER_PIXEL


func has_type(id: String) -> bool:
	return types.has(id)


func get_def(id: String) -> Dictionary:
	return types.get(id, {})


func display_name(id: String) -> String:
	return str(get_def(id).get("name", id))


func is_prop(id: String) -> bool:
	return str(get_def(id).get("detail", "building")) == "prop"


## Props marked "far" (trees...) get a low-detail copy baked into far chunks.
func has_far(id: String) -> bool:
	return bool(get_def(id).get("far", false))


func collides(id: String) -> bool:
	return bool(get_def(id).get("collide", not is_prop(id)))


func footprint(id: String) -> Vector2:
	var fp: Array = get_def(id).get("footprint", [2, 2])
	return Vector2(float(fp[0]), float(fp[1]))


func variant_count(id: String) -> int:
	var n := 1
	var slots: Dictionary = get_def(id).get("colors", {})
	for k in slots:
		n = maxi(n, (slots[k] as Array).size())
	return n


func clamp_variant(id: String, v: int) -> int:
	return posmod(v, variant_count(id))


func placeable_types() -> Array:
	var out := []
	for id in types:
		if bool(types[id].get("placeable", true)):
			out.append(id)
	return out


func get_mesh(id: String, variant: int, lod := false) -> ArrayMesh:
	var key := "%s|%d|%d" % [id, clamp_variant(id, variant), int(lod)]
	if not _meshes.has(key):
		_meshes[key] = _build(id, clamp_variant(id, variant), lod)
	return _meshes[key]


## Raw arrays of the low-detail mesh, used to bake far chunks into one mesh.
func get_lod_arrays(id: String, variant: int) -> Array:
	var key := "%s|%d" % [id, clamp_variant(id, variant)]
	if not _lod_arrays.has(key):
		var m := get_mesh(id, variant, true)
		_lod_arrays[key] = m.surface_get_arrays(0) if m.get_surface_count() > 0 else []
	return _lod_arrays[key]


func get_height(id: String) -> float:
	if not _heights.has(id):
		var m := get_mesh(id, 0, false)
		_heights[id] = maxf(m.get_aabb().end.y, 0.5) if m.get_surface_count() > 0 else 1.0
	return _heights[id]


func get_shape(id: String) -> BoxShape3D:
	if not _shapes.has(id):
		var fp := footprint(id)
		var s := BoxShape3D.new()
		s.size = Vector3(fp.x * 0.9, get_height(id), fp.y * 0.9)
		_shapes[id] = s
	return _shapes[id]


# ------------------------------------------------------------------- building

func _build(id: String, variant: int, lod: bool) -> ArrayMesh:
	var def := get_def(id)
	var mb := MeshBuilder.new()
	for part in def.get("parts", []):
		if lod and not bool(part.get("lod", false)):
			continue
		_add_part(mb, part, def, variant)
	if lod and mb.is_empty():
		var fp := footprint(id)
		var h := get_height(id)
		mb.add_box(Vector3(fp.x * 0.8, h, fp.y * 0.8), Vector3(0, h * 0.5, 0),
				_color(def, str(def.get("lod_color", "wall")), variant))
	return mb.commit(material)


func _add_part(mb, part: Dictionary, def: Dictionary, variant: int) -> void:
	var prim := _make_primitive(part)
	if prim == null:
		push_warning("BuildingLibrary: unknown shape in " + str(part))
		return
	var color := _color(def, str(part.get("color", "#ff00ff")), variant)
	var pos := _vec3(part.get("pos", [0, 0, 0]))
	var basis := Basis.from_euler(_vec3(part.get("rot", [0, 0, 0])) * (PI / 180.0))
	if part.has("scale"):
		basis = basis * Basis.from_scale(_vec3(part["scale"]))
	var offsets := _array_offsets(part.get("array", {}))
	var around := maxi(int(part.get("around", 1)), 1)
	var start := deg_to_rad(float(part.get("around_start", 0.0)))
	var arrays := prim.get_mesh_arrays()
	for k in around:
		var ry := Basis(Vector3.UP, start + TAU * k / around)
		for off in offsets:
			mb.add_arrays(arrays, Transform3D(ry * basis, ry * (pos + off)), color)


func _make_primitive(part: Dictionary) -> PrimitiveMesh:
	match str(part.get("shape", "box")):
		"box":
			var m := BoxMesh.new()
			m.size = _vec3(part.get("size", [1, 1, 1]))
			return m
		"gable":
			var m := PrismMesh.new()
			m.size = _vec3(part.get("size", [1, 1, 1]))
			return m
		"cylinder", "cone":
			var m := CylinderMesh.new()
			var r := float(part.get("radius", 0.5))
			m.bottom_radius = float(part.get("bottom", r))
			m.top_radius = 0.0 if str(part.get("shape")) == "cone" else float(part.get("top", r))
			m.height = float(part.get("height", 1.0))
			m.radial_segments = int(part.get("segments", 8))
			m.rings = 0
			return m
		"sphere":
			var m := SphereMesh.new()
			var r := float(part.get("radius", 0.5))
			m.radius = r
			m.height = r * 2.0
			m.radial_segments = int(part.get("segments", 8))
			m.rings = int(part.get("rings", 4))
			return m
	return null


func _array_offsets(spec: Dictionary) -> Array:
	var out := []
	for x in _axis(spec.get("x")):
		for y in _axis(spec.get("y")):
			for z in _axis(spec.get("z")):
				out.append(Vector3(x, y, z))
	return out


func _axis(a: Variant) -> Array:
	if a == null:
		return [0.0]
	var n := int(a[0])
	var step := float(a[1])
	var out := []
	for i in n:
		out.append((i - (n - 1) * 0.5) * step)
	return out


## Colour lookup: "#hex", a per-type slot (list indexed by variant), or a palette name.
func _color(def: Dictionary, key: String, variant: int) -> Color:
	var slots: Dictionary = def.get("colors", {})
	if slots.has(key):
		var list: Array = slots[key]
		return _literal(str(list[variant % list.size()]))
	return _literal(key)


func _literal(key: String) -> Color:
	if key.begins_with("#"):
		return Color.html(key)
	if palette.has(key):
		return Color.html(str(palette[key]))
	return Color.MAGENTA


func _vec3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
