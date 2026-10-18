extends Node3D
## Entry point: builds the world, player, camera, UI, game modes and systems.
## Command line (after `--`):  --benchmark  run the FPS test and quit
##                              --smoke      headless self-test and quit

const BuildingLibrary = preload("res://scripts/city/building_library.gd")
const CityWorld = preload("res://scripts/city/city_world.gd")
const Player = preload("res://scripts/player/player.gd")
const CameraRig = preload("res://scripts/camera/camera_rig.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const BuildMode = preload("res://scripts/modes/build_mode.gd")
const PhotoMode = preload("res://scripts/modes/photo_mode.gd")
const Benchmark = preload("res://scripts/modes/benchmark.gd")

## Pluggable systems (see scripts/systems/city_system.gd). Add residents etc. here.
const SYSTEMS := [
	"res://scripts/systems/traffic_system.gd",
	"res://scripts/systems/pedestrian_system.gd",
	"res://scripts/systems/npc_system.gd",
	"res://scripts/systems/interior_system.gd",
	"res://scripts/systems/story_system.gd",
	"res://scripts/systems/combat_system.gd",
	"res://scripts/systems/vehicle_system.gd",
]

var library
var world
var player
var rig
var hud
var build_mode
var photo_mode
var benchmark
var systems: Array = []
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var env: Environment
var time_of_day := 15.5

var _sky: ProceduralSkyMaterial
var _stats_left := 0.0
var _uptime := 0.0
var _fps_window := 0.0
var _fps_frames := 0
var _last_auto_drop := -100.0
var _last_saved_pos := Vector3.INF


func _ready() -> void:
	library = BuildingLibrary.new(CityData.type_data)
	_setup_environment()

	world = CityWorld.new()
	world.name = "City"
	add_child(world)
	world.setup(library)

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.setup(library.material)
	player.add_to_group("player")
	player.global_position = CityData.get_player_spawn()

	rig = CameraRig.new()
	rig.name = "CameraRig"
	add_child(rig)
	rig.setup(player)
	rig.add_to_group("camera_rig")
	add_to_group("main")
	rig.yaw = float(CityData.get_player_state().get("yaw", PI))
	world.focus = rig.camera
	world.load_around_now(player.global_position, 1)

	hud = Hud.new()
	hud.add_to_group("hud")
	add_child(hud)
	build_mode = BuildMode.new()
	add_child(build_mode)
	build_mode.setup(library, rig, hud)
	photo_mode = PhotoMode.new()
	add_child(photo_mode)
	photo_mode.setup(rig, hud, self)
	benchmark = Benchmark.new()
	add_child(benchmark)
	benchmark.setup(rig, hud)

	for path in SYSTEMS:
		var sys: Node = load(path).new()
		add_child(sys)
		sys.setup(library)
		systems.append(sys)

	CityData.before_save.connect(_store_player_state)
	Settings.changed.connect(_on_settings_changed)
	_apply_settings()
	set_time_of_day(time_of_day)

	var args := OS.get_cmdline_user_args()
	if "--smoke" in args:
		_run_smoke_test.call_deferred()
	elif "--shots" in args:
		_run_shots.call_deferred()
	elif "--benchmark" in args:
		benchmark.start(true)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_C:
			if not photo_mode.active and not build_mode.active:
				rig.toggle_free()
				_refresh_mode()
		KEY_B:
			if not photo_mode.active and not _driving():
				build_mode.toggle()
				_refresh_mode()
		KEY_P:
			if _driving():
				return
			if build_mode.active:
				build_mode.toggle()
			photo_mode.toggle()
			_refresh_mode()
		KEY_H:
			hud.toggle_help()
		KEY_F2:
			Settings.cycle_quality()
			hud.toast("איכות גרפיקה: " + Settings.quality_label())
		KEY_F3:
			Settings.show_stats = not Settings.show_stats
			Settings.save()
			hud.show_stats(Settings.show_stats)
		KEY_F4:
			benchmark.start(false)
		KEY_F5:
			if CityData.save():
				hud.toast("העיר נשמרה")
		KEY_F11:
			var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)
		KEY_F12:
			take_screenshot()
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_uptime += delta
	_stats_left -= delta
	if _stats_left <= 0.0:
		_stats_left = 0.5
		hud.update_stats("FPS %d  ·  draw calls %d  ·  אובייקטים %d  ·  צ'אנקים %d  ·  איכות %s" % [
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			CityData.objects.size(), world.loaded_count(), Settings.quality_label()])
	_auto_quality(delta)
	if _last_saved_pos.distance_to(player.global_position) > 3.0:
		_last_saved_pos = player.global_position
		CityData.mark_dirty()


## Drops one preset if the game runs below 24 FPS for 5 seconds.
func _auto_quality(delta: float) -> void:
	if not Settings.auto_quality or benchmark.running or _uptime < 8.0:
		return
	_fps_window += delta
	_fps_frames += 1
	if _fps_window < 5.0:
		return
	var fps := _fps_frames / _fps_window
	_fps_window = 0.0
	_fps_frames = 0
	if fps < 24.0 and _uptime - _last_auto_drop > 20.0 and Settings.lower_quality():
		_last_auto_drop = _uptime
		hud.toast("ה־FPS נמוך – האיכות הורדה ל%s (F2 לשינוי)" % Settings.quality_label(), 4.0)


func _driving() -> bool:
	var v := get_tree().get_first_node_in_group("vehicle_system")
	return v != null and v.is_driving()


func _refresh_mode() -> void:
	if photo_mode.active:
		return
	if build_mode.active:
		hud.set_mode("build")
	elif rig.mode == CameraRig.Mode.FREE:
		hud.set_mode("free")
	else:
		hud.set_mode("follow")


func _store_player_state() -> void:
	var p: Vector3 = player.global_position
	CityData.set_player_state({"pos": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
			"yaw": snappedf(rig.yaw, 0.001)})


func _on_settings_changed() -> void:
	_apply_settings()
	world.reload_all()
	for s in systems:
		s.on_settings_changed()


func _apply_settings() -> void:
	var far: float = Settings.get_v("far_distance")
	Engine.max_fps = Settings.get_v("max_fps")
	library.set_per_vertex(Settings.get_v("per_vertex"))
	sun.shadow_enabled = Settings.get_v("shadows")
	sun.directional_shadow_max_distance = Settings.get_v("shadow_distance")
	env.fog_depth_begin = far * 0.55
	env.fog_depth_end = far * 0.97
	rig.camera.far = far + 60.0
	get_viewport().msaa_3d = Viewport.MSAA_2X if Settings.get_v("msaa") else Viewport.MSAA_DISABLED
	if fill:
		set_time_of_day(time_of_day)


func _setup_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	_sky = ProceduralSkyMaterial.new()
	_sky.sky_top_color = Color("5fa8e0")
	_sky.sky_horizon_color = Color("cde6f3")
	_sky.ground_horizon_color = Color("cde6f3")
	_sky.ground_bottom_color = Color("cde6f3")
	var sky := Sky.new()
	sky.sky_material = _sky
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("dfe9f2")
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.tonemap_white = 1.4
	# Depth fog reaches 100% at the draw distance, so the cut-off is invisible.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 1.0
	env.fog_light_color = Color("cde6f3")
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.2
	add_child(sun)
	# Soft "sky bounce" from the opposite side. Ambient light is kept low because
	# the Compatibility renderer applies it twice when sun shadows are enabled;
	# a shadowless fill light lights the shade the same way on every GPU.
	fill = DirectionalLight3D.new()
	fill.name = "SkyFill"
	fill.shadow_enabled = false
	fill.light_color = Color("cfe0f5")
	fill.light_specular = 0.0
	add_child(fill)


## 6:00 sunrise .. 19:00 sunset. Warmer, lower light near the edges of the day.
func set_time_of_day(h: float) -> void:
	time_of_day = clampf(h, 5.5, 19.5)
	var t := clampf((time_of_day - 6.0) / 13.0, 0.0, 1.0)
	var elev := sin(t * PI) * 62.0 + 5.0
	sun.rotation_degrees = Vector3(-elev, lerpf(110.0, -110.0, t), 0.0)
	var warm := 1.0 - clampf((elev - 5.0) / 30.0, 0.0, 1.0)
	sun.light_color = Color(1.0, 0.97, 0.92).lerp(Color(1.0, 0.62, 0.38), warm)
	# With shadows the Compatibility renderer adds the sun in a second pass in
	# sRGB space, which over-brightens; dim the base lighting to compensate.
	var k := 0.3 if sun.shadow_enabled else 1.0
	sun.light_energy = lerpf(1.0, 0.7, warm) * (0.62 if sun.shadow_enabled else 1.0)
	fill.rotation_degrees = Vector3(-55.0, sun.rotation_degrees.y + 180.0, 0.0)
	fill.light_energy = lerpf(0.38, 0.3, warm) * k
	env.ambient_light_energy = lerpf(0.2, 0.16, warm) * k
	_sky.sky_horizon_color = Color("cde6f3").lerp(Color("f5c59a"), warm * 0.8)
	_sky.ground_horizon_color = _sky.sky_horizon_color
	_sky.ground_bottom_color = _sky.sky_horizon_color
	env.fog_light_color = _sky.sky_horizon_color


func take_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://screenshots")
	var path := "user://screenshots/tel_batata_%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
	img.save_png(path)
	hud.toast("צילום נשמר: " + ProjectSettings.globalize_path(path), 4.0)


# ------------------------------------------------------------- self test

## Renders preset views to user://shots/*.png and quits (for checking changes).
func _run_shots() -> void:
	var b: Rect2 = CityData.bounds
	var c := Vector3(b.get_center().x, 0.0, b.get_center().y)
	var views := {
		"overview": [c + Vector3(-120, 110, 150), c],
		"plaza": [c + Vector3(-40, 22, -10), c + Vector3(-24, 0, -24)],
		"street": [Vector3(c.x - 40, 1.7, c.z + 1.8), Vector3(c.x + 10, 1.5, c.z + 1.8)],
		"beach": [Vector3(-60, 14, c.z + 40), Vector3(-10, 0, c.z)],
		"houses": [Vector3(b.end.x + 25, 20, c.z + 30), Vector3(b.end.x - 30, 0, c.z)],
	}
	rig.external = true
	hud.visible = false
	var dir := "user://shots"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots-tag="):
			dir += "_" + a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(dir)
	for name in views:
		var v: Array = views[name]
		rig.camera.global_position = v[0]
		rig.camera.look_at(v[1])
		world.load_all_now()
		for i in 20:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [dir, name])
		print("SHOT %s  draw calls %d  fps %d" % [name,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Engine.get_frames_per_second()])
	get_tree().quit()


func _run_smoke_test() -> void:
	var ok := true
	var t0 := Time.get_ticks_msec()
	for id in library.types:
		for v in library.variant_count(id):
			library.get_mesh(id, v, false)
			library.get_mesh(id, v, true)
	print("SMOKE: built meshes for %d types in %d ms" % [library.types.size(), Time.get_ticks_msec() - t0])
	t0 = Time.get_ticks_msec()
	world.load_all_now()
	print("SMOKE: built all chunks in %d ms -> %s" % [Time.get_ticks_msec() - t0, world.stats()])
	print("SMOKE: city '%s' objects=%d blocks=%d roads=%d districts=%d" % [CityData.city_name,
			CityData.objects.size(), CityData.blocks.size(), CityData.roads.size(), CityData.districts.size()])
	var unknown := 0
	for id in CityData.objects:
		if not library.has_type(str(CityData.objects[id]["type"])):
			unknown += 1
	if unknown > 0:
		push_error("SMOKE: %d objects have unknown types" % unknown)
		ok = false

	var spot := Vector3(CityData.bounds.end.x + 30.0, 0.0, CityData.bounds.get_center().y)
	if not CityData.is_area_free(spot, library.footprint("house_small"), 0.0):
		push_error("SMOKE: expected free spot outside the city")
		ok = false
	var plaza_busy := not CityData.is_area_free(Vector3(CityData.roads[0]["a"][0], 0, CityData.roads[0]["a"][1]), Vector2(4, 4), 0.0)
	if not plaza_busy:
		push_error("SMOKE: road should block building")
		ok = false
	var n_before: int = CityData.objects.size()
	var id: String = CityData.add_object("house_small", spot, 90.0, 2)
	if CityData.is_area_free(spot, library.footprint("house_small"), 0.0):
		push_error("SMOKE: new house should occupy its spot")
		ok = false
	var removed: Dictionary = CityData.remove_object(id)
	CityData.restore_object(removed)
	CityData.remove_object(id)
	var base_id: String = CityData.objects.keys()[0]
	var base_obj: Dictionary = CityData.remove_object(base_id)
	CityData.restore_object(base_obj)
	if CityData.objects.size() != n_before:
		push_error("SMOKE: object count changed after add/remove/undo")
		ok = false
	if not CityData.save():
		ok = false

	# Drive the interactive modes through simulated key presses.
	var keys := [KEY_C, KEY_C, KEY_B, KEY_X, KEY_V, KEY_R, KEY_B, KEY_P, KEY_K, KEY_D, KEY_K, KEY_K,
			KEY_ENTER, KEY_T, KEY_G, KEY_BRACKETLEFT, KEY_Z, KEY_N, KEY_ENTER, KEY_O, KEY_O, KEY_BACKSPACE,
			KEY_P, KEY_F3, KEY_F3, KEY_H, KEY_H]
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		ev.pressed = true
		Input.parse_input_event(ev)
		for i in 3:
			await get_tree().process_frame
		var up := ev.duplicate()
		up.pressed = false
		Input.parse_input_event(up)
		await get_tree().process_frame
	if photo_mode.active or build_mode.active or rig.mode != CameraRig.Mode.FOLLOW:
		push_error("SMOKE: modes did not return to walking")
		ok = false
	build_mode.toggle()
	var n0: int = CityData.objects.size()
	build_mode._pos = spot
	build_mode._has_pos = true
	build_mode._valid = true
	build_mode._place()
	build_mode._undo_last()
	build_mode.toggle()
	if CityData.objects.size() != n0:
		push_error("SMOKE: build + undo changed object count")
		ok = false
	var vehicles := get_tree().get_first_node_in_group("vehicle_system")
	if vehicles:
		var drove: bool = await vehicles.debug_drive(1.5)
		print("SMOKE: drive test moved car: %s" % drove)
		if not drove or vehicles.is_driving() or not player.visible:
			push_error("SMOKE: driving test failed")
			ok = false
	Effects.puff(player.global_position, "dust", 6)
	Audio.play_sfx("coin")
	for i in 30:
		await get_tree().process_frame
	print("SMOKE %s" % ("OK" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)
