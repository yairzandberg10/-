extends Node
## In-game building: place any placeable type on free ground, delete objects,
## undo. Every change goes through CityData (overlay + autosave).

const CameraRig = preload("res://scripts/camera/camera_rig.gd")
const LAYER_BUILDINGS := 2

var active := false
var library
var rig
var hud

var _types: Array = []
var _type_index := 0
var _variant := 0
var _rot := 0.0
var _ghost: MeshInstance3D
var _mat_ok: StandardMaterial3D
var _mat_bad: StandardMaterial3D
var _highlight: MeshInstance3D
var _hover_id := ""
var _pos := Vector3.ZERO
var _has_pos := false
var _valid := false
var _undo: Array = []  # [["add", id] | ["remove", object_dict]]


func setup(lib, camera_rig, h) -> void:
	library = lib
	rig = camera_rig
	hud = h
	_types = library.placeable_types()
	_mat_ok = _ghost_material(Color(0.35, 1.0, 0.45, 0.45))
	_mat_bad = _ghost_material(Color(1.0, 0.3, 0.3, 0.45))
	_ghost = MeshInstance3D.new()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.visible = false
	add_child(_ghost)
	_highlight = MeshInstance3D.new()
	_highlight.mesh = BoxMesh.new()
	_highlight.material_override = _ghost_material(Color(1.0, 0.15, 0.1, 0.35))
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_highlight.visible = false
	add_child(_highlight)


func toggle() -> void:
	active = not active
	if active:
		rig.set_mode(CameraRig.Mode.FREE)
		rig.capture_on_click = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_refresh_ghost()
	else:
		rig.set_mode(CameraRig.Mode.FOLLOW)
		rig.capture_on_click = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_ghost.visible = false
		_highlight.visible = false


func _current_type() -> String:
	return _types[_type_index] if not _types.is_empty() else ""


func _process(_delta: float) -> void:
	if not active or _types.is_empty():
		return
	var cam: Camera3D = rig.camera
	var mp := get_viewport().get_mouse_position()
	var o := cam.project_ray_origin(mp)
	var dir := cam.project_ray_normal(mp)

	_hover_id = ""
	var q := PhysicsRayQueryParameters3D.create(o, o + dir * 400.0, LAYER_BUILDINGS)
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and hit["collider"] is StaticBody3D:
		var body: StaticBody3D = hit["collider"]
		var owner_node := body.shape_owner_get_owner(body.shape_find_owner(hit["shape"]))
		if owner_node is CollisionShape3D and owner_node.has_meta("id"):
			_hover_id = str(owner_node.get_meta("id"))
			var shape: BoxShape3D = owner_node.shape
			_highlight.global_transform = owner_node.global_transform.scaled_local(shape.size * 1.04)
	_highlight.visible = _hover_id != ""

	_has_pos = false
	if dir.y < -0.001:
		var t := -o.y / dir.y
		if t < 600.0:
			_pos = (o + dir * t).snapped(Vector3(1, 0, 1))
			_pos.y = 0.0
			_has_pos = true
	var type_id := _current_type()
	_valid = _has_pos and CityData.is_area_free(_pos, library.footprint(type_id), _rot)
	_ghost.visible = _has_pos
	_ghost.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(_rot)), _pos + Vector3(0, 0.03, 0))
	_ghost.material_override = _mat_ok if _valid else _mat_bad


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_place()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.physical_keycode:
			KEY_Z:
				if k.ctrl_pressed:
					_undo_last()
				else:
					_cycle(-1)
			KEY_X:
				_cycle(1)
			KEY_V:
				_variant = (_variant + 1) % library.variant_count(_current_type())
				_refresh_ghost()
			KEY_R:
				_rot = fposmod(_rot + 90.0, 360.0)
			KEY_DELETE, KEY_BACKSPACE:
				_delete_hovered()


func _place() -> void:
	if not _has_pos:
		return
	if not _valid:
		hud.toast("אי אפשר לבנות כאן – המקום תפוס")
		return
	var t := _current_type()
	var id: String = CityData.add_object(t, _pos, _rot, _variant)
	_undo.append(["add", id])
	hud.toast("נבנה: %s  (%s)" % [library.display_name(t), id], 2.0)


func _delete_hovered() -> void:
	if _hover_id == "":
		return
	var o: Dictionary = CityData.remove_object(_hover_id)
	if not o.is_empty():
		_undo.append(["remove", o])
		hud.toast("נמחק: %s" % library.display_name(str(o["type"])), 2.0)
	_hover_id = ""


func _undo_last() -> void:
	if _undo.is_empty():
		return
	var step: Array = _undo.pop_back()
	if step[0] == "add":
		CityData.remove_object(step[1])
	else:
		CityData.restore_object(step[1])
	hud.toast("בוטל", 1.5)


func _cycle(d: int) -> void:
	_type_index = posmod(_type_index + d, _types.size())
	_variant = 0
	_refresh_ghost()


func _refresh_ghost() -> void:
	var t := _current_type()
	if t == "":
		return
	_ghost.mesh = library.get_mesh(t, _variant, false)
	hud.set_build_text("%s\nצבע %d/%d  ·  סוג %d/%d" % [library.display_name(t), _variant + 1,
			library.variant_count(t), _type_index + 1, _types.size()])


func _ghost_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m
