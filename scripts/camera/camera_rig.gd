extends Node3D
## One camera, three behaviours:
##   FOLLOW - third-person orbit around the player (mouse look, wheel zoom)
##   FREE   - free flying camera (WASD + E/Q, wheel = speed)
##   PHOTO  - like FREE but with smoothed movement/rotation and roll, for video
## Photo paths / benchmark set `external = true` and drive the camera directly.

enum Mode { FOLLOW, FREE, PHOTO }

const LAYER_BUILDINGS := 2

var mode := Mode.FOLLOW
var camera: Camera3D
var target: CharacterBody3D
var external := false
## Inside a building: steep dollhouse view over the open-top walls (no wall
## collision, pitch kept steep so the backdrop, not the sky, is behind).
var indoor := false
var capture_on_click := true

var yaw := 0.0
var pitch := -0.35
var distance := 7.0

var fly_pos := Vector3.ZERO
var fly_yaw := 0.0
var fly_pitch := -0.3
var fly_speed := 14.0
var roll := 0.0

var mouse_sensitivity := 0.0025

var _vel := Vector3.ZERO
var _cur_yaw := 0.0
var _cur_pitch := 0.0
var _cur_roll := 0.0
var _rmb := false


func setup(player: CharacterBody3D) -> void:
	target = player
	camera = Camera3D.new()
	camera.near = 0.15
	camera.far = 400.0
	camera.fov = 70.0
	camera.top_level = true
	add_child(camera)
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_mode(m: Mode) -> void:
	if m != Mode.FOLLOW and mode == Mode.FOLLOW:
		fly_pos = camera.global_position
		fly_yaw = yaw
		fly_pitch = pitch
	if m == Mode.FOLLOW and mode != Mode.FOLLOW:
		yaw = fly_yaw
		roll = 0.0
		camera.fov = 70.0
	_cur_yaw = fly_yaw
	_cur_pitch = fly_pitch
	_cur_roll = roll
	_vel = Vector3.ZERO
	mode = m
	target.control_enabled = m == Mode.FOLLOW


func toggle_free() -> void:
	set_mode(Mode.FOLLOW if mode != Mode.FOLLOW else Mode.FREE)


## Called after an external controller (photo path, orbit) let go.
func sync_from_camera() -> void:
	var e := camera.global_transform.basis.get_euler()
	fly_pos = camera.global_position
	fly_pitch = e.x
	fly_yaw = e.y
	roll = e.z
	_cur_yaw = fly_yaw
	_cur_pitch = fly_pitch
	_cur_roll = roll
	_vel = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and capture_on_click \
				and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var dir := -1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			if mode == Mode.FOLLOW:
				distance = clampf(distance + dir * 0.8, 2.5, 25.0)
			else:
				fly_speed = clampf(fly_speed * (1.0 - dir * 0.15), 1.0, 120.0)
	elif event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _rmb):
		var d: Vector2 = (event as InputEventMouseMotion).relative * mouse_sensitivity
		if mode == Mode.FOLLOW:
			yaw -= d.x
			if indoor:
				yaw = clampf(yaw, -0.7, 0.7)  # stay on the cutaway side of the room
			pitch = clampf(pitch - d.y, -1.35, -0.7 if indoor else 0.3)
		else:
			fly_yaw -= d.x
			fly_pitch = clampf(fly_pitch - d.y, -1.55, 1.55)


func _process(delta: float) -> void:
	if external:
		return
	if mode == Mode.FOLLOW:
		_follow()
	else:
		_fly(delta)


func _follow() -> void:
	var pivot := target.global_position + Vector3(0, 1.3, 0)
	var want := pivot + Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3(0, 0, distance)
	var q := PhysicsRayQueryParameters3D.create(pivot, want, LAYER_BUILDINGS)
	var hit := {} if indoor else get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = hit["position"] + (pivot - want).normalized() * 0.3
	want.y = maxf(want.y, 0.3)
	camera.global_position = want
	camera.look_at(pivot)
	target.cam_yaw = yaw


func _fly(delta: float) -> void:
	var smooth := mode == Mode.PHOTO
	if smooth:
		var k := 1.0 - exp(-6.0 * delta)
		_cur_yaw = lerp_angle(_cur_yaw, fly_yaw, k)
		_cur_pitch = lerpf(_cur_pitch, fly_pitch, k)
		_cur_roll = lerpf(_cur_roll, roll, k)
	else:
		_cur_yaw = fly_yaw
		_cur_pitch = fly_pitch
		_cur_roll = 0.0
	var basis := Basis.from_euler(Vector3(_cur_pitch, _cur_yaw, _cur_roll))
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var up := Input.get_action_strength("fly_up") - Input.get_action_strength("fly_down")
	var dir := basis * Vector3(input.x, 0, input.y) + Vector3.UP * up
	var speed := fly_speed * (3.0 if Input.is_action_pressed("run") else 1.0)
	if smooth:
		_vel = _vel.lerp(dir * speed, 1.0 - exp(-2.5 * delta))
	else:
		_vel = dir * speed
	fly_pos += _vel * delta
	fly_pos.y = maxf(fly_pos.y, 0.4)
	camera.global_transform = Transform3D(basis, fly_pos)
