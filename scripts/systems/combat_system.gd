extends "res://scripts/systems/city_system.gd"
## Soft, silly fights: the player bonks hopping tomatoes with a foam baguette
## (F or left click) and they pop into confetti. Tomatoes squirt the player for
## one heart; running out of hearts just makes Toto dizzy for a moment.
##   spawn(kind, center, radius, tag) -> Node3D   kind: "tomato" | "boss"
##   alive(tag) -> int, clear(tag)
## Emits "defeat:tomato" / "defeat:boss" with {"pos": Vector3, "tag": tag}.

const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")

const REACH := 2.4
const SWING_COOLDOWN := 0.35
const KINDS := {
	"tomato": {"hp": 2, "speed": 3.2, "radius": 0.45, "sight": 16.0, "hit_cd": 1.2},
	"boss": {"hp": 10, "speed": 4.2, "radius": 1.1, "sight": 30.0, "hit_cd": 1.0},
}


class Enemy:
	extends Node3D
	var kind := "tomato"
	var tag := ""
	var hp := 2
	var home := Vector3.ZERO
	var hop := 0.0
	var hit_cd := 0.0
	var stun := 0.0
	var dash := 0.0
	var dash_dir := Vector3.ZERO
	var dash_cd := 3.0
	var model: Node3D


var _player: CharacterBody3D
var _meshes := {}
var _baguette: MeshInstance3D
var _swing_cd := 0.0
var _rng := RandomNumberGenerator.new()


func setup(lib) -> void:
	super.setup(lib)
	add_to_group("combat_system")
	_player = get_tree().get_first_node_in_group("player")
	_rng.randomize()
	for k in KINDS:
		_meshes[k] = _build_enemy_mesh(k)
	_baguette = MeshInstance3D.new()
	var mb := MeshBuilder.new()
	mb.add_box(Vector3(0.16, 0.16, 1.1), Vector3(0, 0, 0.55), Color("e0b060"))
	for i in 4:
		mb.add_box(Vector3(0.17, 0.03, 0.06), Vector3(0, 0.07, 0.2 + i * 0.22), Color("b9873e"))
	_baguette.mesh = mb.commit(library.material)
	_baguette.visible = false
	if _player:
		_player.add_child(_baguette)
		_baguette.position = Vector3(0.38, 0.85, 0.1)


func spawn(kind: String, center: Vector3, radius := 6.0, tag := "") -> Node3D:
	var cfg: Dictionary = KINDS.get(kind, KINDS["tomato"])
	var e := Enemy.new()
	e.kind = kind
	e.tag = tag
	e.hp = cfg["hp"]
	var a := _rng.randf() * TAU
	var r := _rng.randf_range(0.3, 1.0) * radius
	e.home = center + Vector3(cos(a) * r, 0, sin(a) * r)
	e.model = Node3D.new()
	e.add_child(e.model)
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes[kind]
	e.model.add_child(mi)
	e.add_to_group("enemy")
	add_child(e)
	e.global_position = e.home
	e.model.scale = Vector3(0.1, 0.1, 0.1)
	create_tween().tween_property(e.model, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK)
	Effects.puff(e.home + Vector3(0, 0.4, 0), "dust", 5)
	return e


func alive(tag := "") -> int:
	var n := 0
	for e in get_children():
		if e is Enemy and not e.is_queued_for_deletion() and (tag == "" or e.tag == tag):
			n += 1
	return n


func clear(tag := "") -> void:
	for e in get_children():
		if e is Enemy and (tag == "" or e.tag == tag):
			Effects.puff(e.global_position + Vector3(0, 0.5, 0), "dust", 4)
			e.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	var pressed := false
	if event is InputEventKey and event.pressed and not event.echo:
		pressed = (event as InputEventKey).physical_keycode == KEY_F
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if pressed and _can_fight():
		swing()


func _can_fight() -> bool:
	if _player == null or not _player.visible or GameState.input_locked:
		return false
	if not bool(_player.get("control_enabled")):
		return false
	var veh := get_tree().get_first_node_in_group("vehicle_system")
	return veh == null or not veh.is_driving()


## One baguette swing; returns how many enemies it hit.
func swing() -> int:
	if _swing_cd > 0.0:
		return 0
	if not GameState.has_item("foam_baguette"):
		if alive() > 0:
			GameUI.toast("צריך נשק רך… אולי לבורקס יש רעיון?")
		return 0
	_swing_cd = SWING_COOLDOWN
	Audio.play_sfx("swing", -2.0)
	_baguette.visible = true
	_baguette.rotation = Vector3(0, -1.2, 0)
	var tw := create_tween()
	tw.tween_property(_baguette, "rotation:y", 1.1, 0.16).set_trans(Tween.TRANS_QUAD)
	tw.tween_interval(0.08)
	tw.tween_callback(func(): _baguette.visible = false)
	var fwd := _player.global_transform.basis.z
	var p := _player.global_position
	var hits := 0
	for e in get_children():
		if not (e is Enemy) or e.is_queued_for_deletion():
			continue
		var to: Vector3 = e.global_position - p
		to.y = 0.0
		var reach: float = REACH + float(KINDS[e.kind]["radius"])
		if to.length() < reach and (to.length() < 1.0 or fwd.dot(to.normalized()) > 0.2):
			_hit(e, to.normalized())
			hits += 1
	return hits


func _hit(e: Enemy, dir: Vector3) -> void:
	e.hp -= 1
	e.stun = 0.45
	e.dash = 0.0
	e.global_position += dir * (0.6 if e.kind == "boss" else 1.4)
	Audio.play_sfx("bump", -3.0)
	Effects.puff(e.global_position + Vector3(0, 0.6, 0), "sparkle", 4)
	if e.hp <= 0:
		_defeat(e)
		return
	var tw := e.create_tween()
	tw.tween_property(e.model, "scale", Vector3(1.35, 0.6, 1.35), 0.06)
	tw.tween_property(e.model, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK)


func _defeat(e: Enemy) -> void:
	var pos := e.global_position
	for i in 3:
		Effects.puff(pos + Vector3(0, 0.5 + i * 0.3, 0), "sparkle", 8)
	Effects.puff(pos + Vector3(0, 0.3, 0), "splash", 6)
	e.remove_from_group("enemy")
	e.queue_free()
	GameState.emit_event("defeat:" + e.kind, {"pos": pos, "tag": e.tag})


func _process(delta: float) -> void:
	_swing_cd -= delta
	if _player == null:
		return
	var pp := _player.global_position
	var frozen := GameState.input_locked or not _player.visible
	for e in get_children():
		if not (e is Enemy) or e.is_queued_for_deletion():
			continue
		_think(e, pp, delta, frozen)


func _think(e: Enemy, pp: Vector3, delta: float, frozen: bool) -> void:
	var cfg: Dictionary = KINDS[e.kind]
	e.hop += delta * (9.0 if e.kind == "tomato" else 5.0)
	e.model.position.y = absf(sin(e.hop)) * (0.35 if e.kind == "tomato" else 0.25)
	e.hit_cd -= delta
	if e.stun > 0.0 or frozen:
		e.stun -= delta
		return
	var to := pp - e.global_position
	to.y = 0.0
	var d := to.length()
	var goal := e.home
	if d < float(cfg["sight"]):
		goal = pp
	var dir := goal - e.global_position
	dir.y = 0.0
	var speed: float = cfg["speed"]
	if e.kind == "boss":
		e.dash_cd -= delta
		if e.dash > 0.0:
			e.dash -= delta
			dir = e.dash_dir
			speed *= 2.6
			if _rng.randf() < 0.3:
				Effects.puff(e.global_position + Vector3(0, 0.1, 0), "splash", 1)
		elif e.dash_cd <= 0.0 and d < 14.0:
			e.dash_cd = 3.5
			e.dash = 0.7
			e.dash_dir = to.normalized()
			GameUI.toast("מר ריקבון מחליק על קטשופ!")
	if dir.length() > 0.6:
		var step := dir.normalized() * speed * delta
		e.global_position += step
		e.rotation.y = lerp_angle(e.rotation.y, atan2(dir.x, dir.z), 8.0 * delta)
	var touch: float = float(cfg["radius"]) + 0.55
	if d < touch and e.hit_cd <= 0.0:
		e.hit_cd = cfg["hit_cd"]
		_squirt_player(to.normalized())


func _squirt_player(dir: Vector3) -> void:
	GameState.damage(1)
	Audio.play_sfx("hurt", -2.0)
	Effects.puff(_player.global_position + Vector3(0, 1.0, 0), "splash", 6)
	_player.velocity += dir * 7.0 + Vector3(0, 3.0, 0)


func _build_enemy_mesh(kind: String) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var s := 1.0 if kind == "tomato" else 2.3
	var red := Color("e8473a")
	_sphere(mb, 0.45 * s, Vector3(0, 0.45 * s, 0), Vector3(1.0, 0.85, 1.0), red, 10)
	for a in 5:
		var ang := a * TAU / 5.0
		mb.add_box(Vector3(0.08, 0.04, 0.32) * s, Vector3(cos(ang) * 0.12, 0.84, sin(ang) * 0.12) * s,
				Color("3f9a3a"), ang)
	mb.add_box(Vector3(0.06, 0.16, 0.06) * s, Vector3(0, 0.9, 0) * s, Color("2f7a2a"))
	for x in [-0.14, 0.14]:
		_sphere(mb, 0.1 * s, Vector3(x * s, 0.55 * s, 0.36 * s), Vector3(1, 1, 0.6), Color.WHITE, 6)
		_sphere(mb, 0.05 * s, Vector3(x * s, 0.55 * s, 0.42 * s), Vector3(1, 1, 0.6), Color("2b2b2b"), 6)
		# angry-but-cute eyebrows
		mb.add_box(Vector3(0.14, 0.03, 0.03) * s, Vector3(x * s, 0.68 * s, 0.4 * s), Color("2b2b2b"), 0.0)
	if kind == "boss":
		mb.add_box(Vector3(0.7, 0.12, 0.08), Vector3(0, 0.85, 0.98), Color("3a2618"))  # mustache
		var crown := CylinderMesh.new()
		crown.top_radius = 0.42
		crown.bottom_radius = 0.36
		crown.height = 0.3
		crown.radial_segments = 8
		mb.add_primitive(crown, Transform3D(Basis(), Vector3(0, 2.05, 0)), Color("f2c230"))
	else:
		_sphere(mb, 0.07, Vector3(0, 0.36, 0.42), Vector3(1.4, 0.6, 0.6), Color("8a1f1a"), 6)
	return mb.commit(library.material)


func _sphere(mb, r: float, pos: Vector3, scale: Vector3, color: Color, seg: int) -> void:
	var sp := SphereMesh.new()
	sp.radius = r
	sp.height = r * 2.0
	sp.radial_segments = seg
	sp.rings = maxi(seg / 2, 3)
	mb.add_primitive(sp, Transform3D(Basis.from_scale(scale), pos), color)
