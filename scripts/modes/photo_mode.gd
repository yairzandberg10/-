extends Node
## Photo / video mode: hidden UI, smooth camera, keyframed camera paths
## (Catmull-Rom), orbit shots, tilt-shift miniature look, cinematic bars,
## time-of-day control. Camera paths persist in user://camera_path.json.

const CameraRig = preload("res://scripts/camera/camera_rig.gd")
const PATH_FILE := "user://camera_path.json"

var active := false
var rig
var hud
var main

var keyframes: Array = []  # [{"xf": Transform3D, "fov": float}]
var seg_time := 4.0
var playing := false
var orbiting := false
var tilt_shift := false
var letterbox := false

var _play_t := 0.0
var _orbit_center := Vector3.ZERO
var _orbit_r := 30.0
var _orbit_h := 20.0
var _orbit_a := 0.0


func setup(camera_rig, h, main_node) -> void:
	rig = camera_rig
	hud = h
	main = main_node
	_load_path()


func toggle() -> void:
	active = not active
	if active:
		rig.set_mode(CameraRig.Mode.PHOTO)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.set_photo(true)
	else:
		_stop()
		tilt_shift = false
		letterbox = false
		rig.set_mode(CameraRig.Mode.FOLLOW)
		hud.set_photo(false)


func _unhandled_input(event: InputEvent) -> void:
	if not active or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var cam: Camera3D = rig.camera
	match (event as InputEventKey).physical_keycode:
		KEY_K:
			keyframes.append({"xf": cam.global_transform, "fov": cam.fov})
			_save_path()
			hud.toast("נקודת מסלול %d נוספה" % keyframes.size(), 1.5)
		KEY_ENTER, KEY_KP_ENTER:
			if playing:
				_stop()
			elif keyframes.size() >= 2:
				_stop()
				playing = true
				_play_t = 0.0
				rig.external = true
			else:
				hud.toast("צריך לפחות 2 נקודות מסלול (K)")
		KEY_BACKSPACE:
			_stop()
			keyframes.clear()
			_save_path()
			hud.toast("המסלול נמחק", 1.5)
		KEY_O:
			if orbiting:
				_stop()
			else:
				_start_orbit()
		KEY_T:
			tilt_shift = not tilt_shift
			hud.set_tilt_shift(tilt_shift)
		KEY_G:
			letterbox = not letterbox
			hud.set_letterbox(letterbox)
		KEY_BRACKETLEFT:
			main.set_time_of_day(main.time_of_day - 0.5)
			hud.toast("שעה %s" % _hour_text(main.time_of_day), 1.0)
		KEY_BRACKETRIGHT:
			main.set_time_of_day(main.time_of_day + 0.5)
			hud.toast("שעה %s" % _hour_text(main.time_of_day), 1.0)
		KEY_Z:
			cam.fov = clampf(cam.fov - 5.0, 15.0, 100.0)
		KEY_X:
			cam.fov = clampf(cam.fov + 5.0, 15.0, 100.0)
		KEY_N:
			rig.roll -= 0.04
		KEY_M:
			rig.roll += 0.04
		KEY_J:
			rig.roll = 0.0
		KEY_MINUS:
			seg_time = minf(seg_time + 1.0, 30.0)
			hud.toast("%.0f שניות בין נקודות" % seg_time, 1.0)
		KEY_EQUAL:
			seg_time = maxf(seg_time - 1.0, 1.0)
			hud.toast("%.0f שניות בין נקודות" % seg_time, 1.0)


func _process(delta: float) -> void:
	if not active:
		return
	if playing:
		_update_play(delta)
	elif orbiting:
		_orbit_a += delta * 0.12
		var cam: Camera3D = rig.camera
		cam.global_position = _orbit_center + Vector3(sin(_orbit_a) * _orbit_r, _orbit_h, cos(_orbit_a) * _orbit_r)
		cam.look_at(_orbit_center)


func _update_play(delta: float) -> void:
	var n := keyframes.size()
	_play_t += delta / seg_time
	if _play_t >= n - 1:
		_stop()
		hud.toast("סוף המסלול", 1.5)
		return
	var i := int(_play_t)
	var f := _play_t - i
	var k0: Dictionary = keyframes[maxi(i - 1, 0)]
	var k1: Dictionary = keyframes[i]
	var k2: Dictionary = keyframes[i + 1]
	var k3: Dictionary = keyframes[mini(i + 2, n - 1)]
	var x0: Transform3D = k0["xf"]
	var x1: Transform3D = k1["xf"]
	var x2: Transform3D = k2["xf"]
	var x3: Transform3D = k3["xf"]
	var p := x1.origin.cubic_interpolate(x2.origin, x0.origin, x3.origin, f)
	var q1 := x1.basis.get_rotation_quaternion()
	var q := q1.spherical_cubic_interpolate(x2.basis.get_rotation_quaternion(),
			x0.basis.get_rotation_quaternion(), x3.basis.get_rotation_quaternion(), f)
	var cam: Camera3D = rig.camera
	cam.global_transform = Transform3D(Basis(q), p)
	cam.fov = lerpf(float(k1["fov"]), float(k2["fov"]), f)


func _start_orbit() -> void:
	_stop()
	var cam: Camera3D = rig.camera
	var o := cam.global_position
	var fwd := -cam.global_transform.basis.z
	if fwd.y < -0.05:
		_orbit_center = o + fwd * (-o.y / fwd.y)
	else:
		_orbit_center = o + Vector3(fwd.x, 0, fwd.z).normalized() * 30.0
		_orbit_center.y = 0.0
	var off := o - _orbit_center
	_orbit_h = off.y
	_orbit_r = maxf(Vector2(off.x, off.z).length(), 5.0)
	_orbit_a = atan2(off.x, off.z)
	orbiting = true
	rig.external = true


func _stop() -> void:
	if playing or orbiting:
		rig.sync_from_camera()
	playing = false
	orbiting = false
	rig.external = false


func _hour_text(h: float) -> String:
	return "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]


func _save_path() -> void:
	var out := []
	for k in keyframes:
		var xf: Transform3D = k["xf"]
		var q := xf.basis.get_rotation_quaternion()
		out.append([xf.origin.x, xf.origin.y, xf.origin.z, q.x, q.y, q.z, q.w, k["fov"]])
	var f := FileAccess.open(PATH_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"seg_time": seg_time, "keyframes": out}))


func _load_path() -> void:
	if not FileAccess.file_exists(PATH_FILE):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH_FILE))
	if not (data is Dictionary):
		return
	seg_time = float(data.get("seg_time", seg_time))
	for a in data.get("keyframes", []):
		var q := Quaternion(a[3], a[4], a[5], a[6]).normalized()
		keyframes.append({"xf": Transform3D(Basis(q), Vector3(a[0], a[1], a[2])), "fov": float(a[7])})
