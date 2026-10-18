extends Node
## F4 (or `-- --benchmark` on the command line): flies the camera over the
## city for a fixed time with vsync/FPS cap off and reports FPS numbers.
## Results are appended to user://benchmark.txt.

const DURATION := 24.0

var running := false
var rig
var hud

var _quit_after := false
var _t := 0.0
var _frames := PackedFloat32Array()
var _draw_sum := 0.0
var _prev_vsync := DisplayServer.VSYNC_ENABLED
var _prev_fps := 60


func setup(camera_rig, h) -> void:
	rig = camera_rig
	hud = h


func start(quit_after: bool) -> void:
	if running:
		return
	running = true
	_quit_after = quit_after
	_t = 0.0
	_frames.clear()
	_draw_sum = 0.0
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	_prev_fps = Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	rig.external = true
	hud.toast("בדיקת ביצועים רצה... (%d שניות)" % int(DURATION), 3.0)


func _process(delta: float) -> void:
	if not running:
		return
	_t += delta
	if _t > 1.0:  # skip the first second (chunk loading)
		_frames.append(delta)
		_draw_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var b: Rect2 = CityData.bounds
	var c := Vector3(b.get_center().x, 0.0, b.get_center().y)
	var cam: Camera3D = rig.camera
	var p := _t / DURATION
	if p < 0.5:
		# High orbit around the whole city.
		var a := p * 2.0 * TAU
		var r := maxf(b.size.x, b.size.y) * 0.55 + 20.0
		cam.global_position = c + Vector3(cos(a) * r, 35.0, sin(a) * r)
		cam.look_at(c)
	else:
		# Street-level drive along the road closest to the centre.
		var pitch := float(CityData.grid.get("pitch", 48.0))
		var z := roundf(c.z / pitch) * pitch
		var x := lerpf(b.position.x + 4.0, b.end.x - 4.0, (p - 0.5) * 2.0)
		cam.global_position = Vector3(x, 1.8, z + 1.5)
		cam.look_at(Vector3(x + 10.0, 1.6, z + 1.5))
	if _t >= DURATION:
		_finish()


func _finish() -> void:
	running = false
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	Engine.max_fps = _prev_fps
	rig.external = false
	rig.sync_from_camera()
	var n := _frames.size()
	if n == 0:
		return
	var total := 0.0
	for f in _frames:
		total += f
	var sorted := _frames.duplicate()
	sorted.sort()
	var p99: float = sorted[mini(int(n * 0.99), n - 1)]
	var text := "בדיקת ביצועים [%s]: ממוצע %.0f FPS · 1%% נמוך %.0f FPS · מינימום %.0f FPS · %.0f draw calls" % [
		Settings.quality, n / total, 1.0 / p99, 1.0 / sorted[n - 1], _draw_sum / n]
	print(text)
	var f := FileAccess.open("user://benchmark.txt", FileAccess.READ_WRITE if FileAccess.file_exists("user://benchmark.txt") else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line("%s  %s  GPU: %s" % [Time.get_datetime_string_from_system(), text, RenderingServer.get_video_adapter_name()])
	hud.toast(text, 10.0)
	if _quit_after:
		get_tree().quit()
