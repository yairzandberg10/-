extends Node3D
## One talkable potato person (named NPC, police officer, shopkeeper...).
## Owned and driven by npc_system.gd: it idles, turns to face the player when
## close, and can patrol a sidewalk loop (police officers).
## The mesh is one MeshInstance3D (one draw call), hidden beyond 90 m.

const PotatoKit = preload("res://scripts/npc/potato_kit.gd")

var npc_id := ""
var display_name := ""
var lines: Array = []
var shop_type := ""   # non-empty: talking opens this shop afterwards
var shop_name := ""
var seated := false
var bouncy := false    # kids hop around
var turn_to_player := true
var walker: Dictionary = {}  # sidewalk walker (patrolling officers)
var graph                    # SidewalkGraph for walker
var indoor := false   # lives inside the current interior room

var _model: Node3D
var _t := 0.0
var _home_yaw := 0.0
var _pause := 0.0


func setup(id: String, name_: String, look: Dictionary, material: Material, sit := false) -> void:
	npc_id = id
	display_name = name_
	seated = sit
	_model = Node3D.new()
	add_child(_model)
	var mi := MeshInstance3D.new()
	mi.mesh = PotatoKit.build(look, material, sit)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 90.0
	_model.add_child(mi)
	_t = randf() * 10.0


func set_facing(yaw: float) -> void:
	_home_yaw = yaw
	_model.rotation.y = yaw


func facing() -> float:
	return _model.rotation.y


## Turns the whole body towards `p` right away (used when a dialogue starts).
func face(p: Vector3) -> void:
	var d := p - global_position
	if d.length_squared() > 0.01 and not seated:
		_model.rotation.y = atan2(d.x, d.z)


func tick(delta: float, player_pos: Vector3, near: bool) -> void:
	_t += delta
	var to_p := player_pos - global_position
	to_p.y = 0.0
	var close := to_p.length() < 4.0
	if not walker.is_empty():
		_patrol(delta, close)
	if not near:
		return
	var want := _home_yaw
	if close and turn_to_player and not seated:
		want = atan2(to_p.x, to_p.z)
	elif not walker.is_empty():
		var h: Vector2 = walker["heading"]
		want = atan2(h.x, h.y)
	_model.rotation.y = lerp_angle(_model.rotation.y, want, minf(6.0 * delta, 1.0))
	var moving := not walker.is_empty() and not close and _pause <= 0.0
	if moving:
		_model.position.y = absf(sin(_t * 9.0)) * 0.08
		_model.rotation.z = sin(_t * 9.0) * 0.07
	elif bouncy:
		_model.position.y = maxf(sin(_t * 5.0), 0.0) * 0.35
		_model.rotation.z = 0.0
	else:
		# Breathing.
		_model.position.y = 0.0
		_model.scale = Vector3(1.0, 1.0 + sin(_t * 2.2) * 0.015, 1.0)
		_model.rotation.z = lerpf(_model.rotation.z, 0.0, 0.2)


func _patrol(delta: float, close: bool) -> void:
	if close:
		return
	if _pause > 0.0:
		_pause -= delta
		return
	graph.step(walker, delta, 0.25)
	var p: Vector2 = walker["pos"]
	global_position = Vector3(p.x, graph.CURB_Y, p.y)
	if randf() < delta * 0.05:
		_pause = randf_range(2.0, 5.0)
