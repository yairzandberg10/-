extends "res://scripts/systems/city_system.gd"
## Drivable cars. A handful of cars are parked along the streets; walk up and
## press E to drive. Arcade handling: W/S gas & brake/reverse, A/D steer,
## Space handbrake, Q horn, E get out. Only the car being driven runs physics.

const PARKED := 10
const MAX_SPEED := 19.0  # m/s (~70 km/h)
const REVERSE_SPEED := 6.0
const ACCEL := 9.0
const BRAKE := 22.0
const DRAG := 4.0
const STEER := 2.1
const CAR_TYPES := ["car_police", "car"]


## Each car is its own small body; it exposes the same fields the camera rig
## expects from the player (control_enabled, cam_yaw).
class Car:
	extends CharacterBody3D
	var control_enabled := true
	var cam_yaw := 0.0
	var speed := 0.0
	var body: Node3D
	var type_id := "car"


var _cars: Array = []
var _driving: Car = null
var _player: CharacterBody3D
var _rig: Node
var _saved_distance := 7.0
var _engine: AudioStreamPlayer
var _hud: CanvasLayer
var _speed_label: Label
var _puff_left := 0.0
var _bump_cool := 0.0
var _test_throttle := 0.0  # used by the self-test to drive without a keyboard


func setup(lib) -> void:
	super.setup(lib)
	add_to_group("vehicle_system")
	_player = get_tree().get_first_node_in_group("player")
	_rig = get_tree().get_first_node_in_group("camera_rig")
	_spawn_parked()
	Interact.register_provider(self)
	_engine = AudioStreamPlayer.new()
	if has_node("/root/Audio"):
		_engine.stream = Audio.get_stream("sfx_engine", true)
	add_child(_engine)
	_make_hud()


func is_driving() -> bool:
	return _driving != null


## Interact provider: "drive" prompt next to each parked car.
func get_interactions(pos: Vector3) -> Array:
	if _driving:
		return []
	var out := []
	for car in _cars:
		if car.global_position.distance_to(pos) < 4.5:
			out.append({"position": car.global_position, "prompt": "לנהוג ברכב", "action": _enter.bind(car)})
	return out


# ------------------------------------------------------------------ spawning

func _spawn_parked() -> void:
	if CityData.roads.is_empty() or not library.has_type("car"):
		return
	var spawn := CityData.get_player_spawn()
	var roads := CityData.roads.duplicate()
	roads.sort_custom(func(a, b): return _road_mid(a).distance_to(spawn) < _road_mid(b).distance_to(spawn))
	var count := 0
	for i in range(0, roads.size(), 2):
		if count >= PARKED:
			break
		var r: Dictionary = roads[i]
		var a := Vector3(float(r["a"][0]), 0, float(r["a"][1]))
		var b := Vector3(float(r["b"][0]), 0, float(r["b"][1]))
		var d := (b - a).normalized()
		var right := Vector3(-d.z, 0, d.x)
		var pos := a.lerp(b, 0.35 + 0.3 * float(i % 3) / 2.0) + right * 2.8
		var type_id := "car_police" if count == 0 and library.has_type("car_police") else "car"
		_cars.append(_make_car(type_id, count % library.variant_count(type_id), pos, atan2(d.x, d.z)))
		count += 1


func _road_mid(r: Dictionary) -> Vector3:
	return Vector3((float(r["a"][0]) + float(r["b"][0])) * 0.5, 0, (float(r["a"][1]) + float(r["b"][1])) * 0.5)


func _make_car(type_id: String, variant: int, pos: Vector3, yaw: float) -> Car:
	var car := Car.new()
	car.type_id = type_id
	car.collision_layer = 2
	car.collision_mask = 1 | 2
	car.floor_snap_length = 0.5
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 1.3, 4.1)
	cs.shape = box
	cs.position.y = 0.75
	car.add_child(cs)
	car.body = Node3D.new()
	car.add_child(car.body)
	var mi := MeshInstance3D.new()
	mi.mesh = library.get_mesh(type_id, variant, false)
	car.body.add_child(mi)
	add_child(car)
	car.global_position = pos + Vector3(0, 0.05, 0)
	car.rotation.y = yaw
	return car


# ------------------------------------------------------------------ enter / exit

func _enter(car: Car) -> void:
	if _driving or _player == null:
		return
	_driving = car
	car.speed = 0.0
	car.control_enabled = true
	_player.visible = false
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	_saved_distance = _rig.distance
	_rig.distance = 10.0
	_rig.target = car
	_rig.yaw = car.rotation.y + PI
	if _engine.stream:
		_engine.volume_db = linear_to_db(maxf(Settings.sfx_volume * 0.5, 0.0001))
		_engine.play()
	if has_node("/root/Audio"):
		Audio.play_sfx("door", -4.0)
	_hud.visible = true
	GameUI.toast("W/S נסיעה · A/D היגוי · רווח בלם יד · Q צופר · E לצאת")
	GameState.emit_event("drive:start", {"type": car.type_id})


func _exit() -> void:
	var car := _driving
	if car == null:
		return
	_driving = null
	car.speed = 0.0
	car.velocity = Vector3.ZERO
	var side := -car.global_transform.basis.x
	var spot := car.global_position + side * 2.3
	_player.process_mode = Node.PROCESS_MODE_INHERIT
	_player.visible = true
	_player.global_position = spot + Vector3(0, 0.3, 0)
	_player.velocity = Vector3.ZERO
	_rig.target = _player
	_rig.distance = _saved_distance
	_engine.stop()
	_hud.visible = false
	if has_node("/root/Audio"):
		Audio.play_sfx("door", -4.0)
	GameState.emit_event("drive:stop")


func _unhandled_input(event: InputEvent) -> void:
	if _driving == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if not _driving.control_enabled or GameState.input_locked:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_E:
			get_viewport().set_input_as_handled()
			_exit()
		KEY_Q:
			if has_node("/root/Audio"):
				Audio.play_sfx("horn", 0.0, 0.0)


# ------------------------------------------------------------------ driving

func _physics_process(delta: float) -> void:
	var car := _driving
	if car == null:
		return
	var can := car.control_enabled and not GameState.input_locked
	var throttle := 0.0
	var steer := 0.0
	var handbrake := false
	if can:
		throttle = Input.get_axis("move_back", "move_forward")
		steer = Input.get_axis("move_right", "move_left")
		handbrake = Input.is_physical_key_pressed(KEY_SPACE)
	if _test_throttle != 0.0:
		throttle = _test_throttle
		steer = 0.4

	if throttle > 0.0:
		car.speed += (BRAKE if car.speed < 0.0 else ACCEL) * throttle * delta
	elif throttle < 0.0:
		car.speed += (BRAKE if car.speed > 0.5 else ACCEL * 0.6) * throttle * delta
	else:
		car.speed = move_toward(car.speed, 0.0, DRAG * delta)
	if handbrake:
		car.speed = move_toward(car.speed, 0.0, BRAKE * 1.4 * delta)
	car.speed = clampf(car.speed, -REVERSE_SPEED, MAX_SPEED)

	var grip := clampf(absf(car.speed) / 6.0, 0.0, 1.0) * signf(car.speed)
	car.rotation.y += steer * STEER * grip * delta * (1.4 if handbrake else 1.0)
	var fwd := car.global_transform.basis.z
	var vy := car.velocity.y - 20.0 * delta if not car.is_on_floor() else -0.5
	car.velocity = fwd * car.speed + Vector3(0, vy, 0)
	car.move_and_slide()

	_bump_cool -= delta
	var hit := car.get_slide_collision_count() > 0 and absf(car.speed) > 3.0
	if not hit:
		var traffic := get_tree().get_first_node_in_group("traffic_system")
		hit = traffic != null and absf(car.speed) > 3.0 and traffic.nearest_car_distance(car.global_position) < 2.4
	if hit and _bump_cool <= 0.0:
		_bump_cool = 0.5
		car.speed *= -0.35
		Effects.puff(car.global_position + fwd * 2.2 + Vector3(0, 0.6, 0), "dust", 6)
		if has_node("/root/Audio"):
			Audio.play_sfx("bump")

	# Juice: body leans into turns and squats under acceleration.
	car.body.rotation.z = lerpf(car.body.rotation.z, -steer * grip * 0.07, 8.0 * delta)
	car.body.rotation.x = lerpf(car.body.rotation.x, -throttle * 0.03, 6.0 * delta)
	_puff_left -= delta
	if _puff_left <= 0.0:
		_puff_left = 0.12
		if throttle > 0.0:
			Effects.puff(car.global_position - fwd * 2.1 + Vector3(0, 0.35, 0), "smoke", 1)
		if handbrake and absf(car.speed) > 4.0:
			Effects.puff(car.global_position - fwd * 1.3, "dust", 2)
			if has_node("/root/Audio"):
				Audio.play_sfx("skid", -6.0)

	_player.global_position = car.global_position  # saves/quests see the player where the car is
	if absf(car.speed) > 1.0:
		_rig.yaw = lerp_angle(_rig.yaw, car.rotation.y + (PI if car.speed > 0.0 else 0.0), 2.0 * delta)
	_engine.pitch_scale = 0.7 + absf(car.speed) / MAX_SPEED * 1.4
	_speed_label.text = "%d קמ\"ש" % int(absf(car.speed) * 3.6)


# ------------------------------------------------------------------ hud

func _make_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 9
	_hud.visible = false
	add_child(_hud)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.6)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -80
	panel.offset_bottom = -20
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud.add_child(panel)
	_speed_label = Label.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "Arial", "Noto Sans Hebrew", "DejaVu Sans"])
	_speed_label.add_theme_font_override("font", font)
	_speed_label.add_theme_font_size_override("font_size", 28)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_label.text = "0 קמ\"ש"
	panel.add_child(_speed_label)


## Self-test: get into the nearest car, drive for a moment, get out.
func debug_drive(seconds := 1.5) -> bool:
	if _cars.is_empty():
		return false
	var car: Car = _cars[0]
	var start := car.global_position
	_enter(car)
	_test_throttle = 1.0
	await get_tree().create_timer(seconds).timeout
	_test_throttle = 0.0
	var moved := car.global_position.distance_to(start)
	_exit()
	return moved > 1.0
