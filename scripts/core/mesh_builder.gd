extends RefCounted
## Merges many primitive shapes into one vertex-coloured ArrayMesh.
## Everything in the city shares a single material, so a merged mesh is
## exactly one draw call no matter how many boxes it contains.

static var _unit_box: Array = []

## Subtracted from every vertex: lets chunk meshes be built relative to the
## chunk centre (keeps visibility ranges and float precision sane).
var origin := Vector3.ZERO

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()


func is_empty() -> bool:
	return _idx.is_empty()


func vertex_count() -> int:
	return _verts.size()


## Appends mesh arrays (vertex/normal/index) transformed by `xf`, all in `color`.
func add_arrays(arrays: Array, xf: Transform3D, color: Color) -> void:
	_append(arrays, xf, color, false)


## Same, but keeps the vertex colours already stored in `arrays`.
func add_colored_arrays(arrays: Array, xf: Transform3D) -> void:
	_append(arrays, xf, Color.WHITE, true)


func add_primitive(prim: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
	_append(prim.get_mesh_arrays(), xf, color, false)


func add_box(size: Vector3, center: Vector3, color: Color, rot_y := 0.0) -> void:
	if _unit_box.is_empty():
		_unit_box = BoxMesh.new().get_mesh_arrays()
	var basis := Basis(Vector3.UP, rot_y) * Basis.from_scale(size)
	_append(_unit_box, Transform3D(basis, center), color, false)


func commit(material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if _idx.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_INDEX] = _idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _append(arrays: Array, xf: Transform3D, color: Color, keep_colors: bool) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var ii: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var src_cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if keep_colors else PackedColorArray()
	var t := xf
	t.origin -= origin
	var nb := t.basis.inverse().transposed()
	var base := _verts.size()
	for k in v.size():
		_verts.append(t * v[k])
		_norms.append((nb * n[k]).normalized())
		_cols.append(src_cols[k] if keep_colors else color)
	for k in ii.size():
		_idx.append(base + ii[k])
