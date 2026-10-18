extends Node
## --playtest: plays like a new player with real key presses and saves what
## the player would see to user://playtest/NN_name.png. For finding bugs that
## the logic tests can't see (layout, camera, things in the wrong place).

var main: Node
var dir := "user://playtest"
var n := 0


func run(m: Node) -> void:
	main = m
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	await frames(90)
	await shot("menu")
	GameUI.menu.show_page("settings")
	await frames(10)
	await shot("menu_settings")
	GameUI.menu.show_page("main")
	GameUI.menu.start_new_game()
	await frames(40)
	await shot("start")
	for i in 6:
		await key(KEY_E)
		await frames(20)
		if i == 0:
			await shot("intro_line2")
	await shot("after_intro")
	var story := get_tree().get_first_node_in_group("story_system")
	var player: CharacterBody3D = main.player
	# Walk a bit forward with W held, like a real player.
	Input.action_press("move_forward")
	await frames(30)
	print("PLAYTEST walk: locks ", GameState._locks, " ctrl ", player.control_enabled, " vel ", player.velocity,
			" floor ", player.is_on_floor(), " strength ", Input.get_action_strength("move_forward"), " proc ", player.process_mode)
	await frames(30)
	Input.action_release("move_forward")
	await shot("walked")
	# Go to the quest target (chief at the new home) and talk.
	var t: Vector3 = GameUI.hud.target
	print("PLAYTEST target ", t, " player ", player.global_position)
	await go_near(t)
	await shot("near_target")
	await key(KEY_E)
	await frames(30)
	await shot("talk")
	for i in 14:
		await key(KEY_E)
		await frames(15)
	await shot("after_talk")
	# Boxes.
	for i in 3:
		t = GameUI.hud.target
		if t == Vector3.INF:
			break
		await go_near(t, 0.0)
		await frames(10)
	await shot("boxes_done")
	t = GameUI.hud.target
	await go_near(t, 1.0)
	await shot("at_home_door")
	await key(KEY_E)
	await frames(40)
	await shot("inside_home")
	for i in 6:
		await key(KEY_E)
		await frames(15)
	await shot("inside_after")
	Input.action_press("move_back")
	await frames(40)
	Input.action_release("move_back")
	await shot("inside_walk")
	var interior := get_tree().get_first_node_in_group("interior_system")
	if interior.is_inside():
		interior.exit_interior()
	await frames(30)
	await shot("outside_again")
	# Windows.
	await key(KEY_I)
	await frames(15)
	await shot("inventory")
	await key(KEY_I)
	await key(KEY_TAB)
	await frames(15)
	await shot("quest_log")
	await key(KEY_TAB)
	await key(KEY_ESCAPE)
	await frames(15)
	await shot("pause_menu")
	await key(KEY_ESCAPE)
	await frames(5)
	# Bakery + shop.
	var bakery: Dictionary = preload("res://scripts/npc/npc_places.gd").first_of_type("bakery")
	await go_near(preload("res://scripts/npc/npc_places.gd").door_position(bakery), 0.5)
	await shot("bakery_door")
	await key(KEY_E)
	await frames(40)
	await shot("bakery_inside")
	await go_near(interior.ROOM_ORIGIN + Vector3(0, 0, -1.0), 0.5)
	await key(KEY_E)
	await frames(30)
	await shot("bakery_talk")
	for i in 6:
		await key(KEY_E)
		await frames(15)
	for i in 10:
		await key(KEY_E)
		await frames(12)
	await key(KEY_ESCAPE)
	await frames(10)
	await shot("bakery_after_talk")
	# Fight.
	interior.exit_interior()
	await frames(20)
	GameState.add_item("foam_baguette")
	var combat := get_tree().get_first_node_in_group("combat_system")
	for i in 3:
		combat.spawn("tomato", player.global_position + player.global_transform.basis.z * 4.0, 2.0, "pt")
	await frames(40)
	await shot("tomatoes")
	for i in 6:
		await key(KEY_F)
		await frames(12)
	await shot("fight")
	# Drive.
	var veh := get_tree().get_first_node_in_group("vehicle_system")
	if veh and not veh._cars.is_empty():
		await go_near(veh._cars[0].global_position, 2.2)
		await shot("near_car")
		await key(KEY_E)
		await frames(20)
		Input.action_press("move_forward")
		await frames(80)
		Input.action_release("move_forward")
		await shot("driving")
		await key(KEY_E)
		await frames(20)
	# Night chapter look.
	main.set_time_of_day(19.4)
	await frames(20)
	await shot("evening")
	print("PLAYTEST done %d shots" % n)
	get_tree().quit()


func frames(k: int) -> void:
	for i in k:
		await get_tree().process_frame


func key(k: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = k
	ev.keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	await frames(2)


## Teleports next to `p` (the walking itself is tested above) and faces it.
func go_near(p: Vector3, back := 2.0) -> void:
	if p == Vector3.INF:
		print("PLAYTEST no target!")
		return
	var player: CharacterBody3D = main.player
	var interior := get_tree().get_first_node_in_group("interior_system")
	if interior.is_inside() and p.x < 5000.0:
		interior.exit_interior()
		await frames(5)
	var from := player.global_position
	var d := Vector3(p.x - from.x, 0, p.z - from.z)
	var dirn := d.normalized() if d.length() > 0.1 else Vector3.BACK
	player.global_position = p - dirn * back + Vector3(0, 0.6, 0)
	player.rotation.y = atan2(dirn.x, dirn.z)
	main.rig.yaw = player.rotation.y + PI
	main.world.load_around_now(player.global_position, 1)
	await frames(25)


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	n += 1
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%02d_%s.png" % [dir, n, name])
	print("PLAYTEST shot %02d_%s  pos %s  prompt-modal %s" % [n, name, main.player.global_position, GameUI.is_modal_open()])
