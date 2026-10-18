extends Node
## E-to-interact. Systems register as providers; a provider implements
##   get_interactions(player_pos: Vector3) -> Array
## returning dicts {"position": Vector3, "prompt": String, "action": Callable}.
## The closest one within RANGE of the walking player is shown and run on E.

const RANGE := 2.6

var _providers: Array = []
var _current: Dictionary = {}


func register_provider(p: Object) -> void:
	if not _providers.has(p):
		_providers.append(p)


func unregister_provider(p: Object) -> void:
	_providers.erase(p)


func _process(_delta: float) -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var best := {}
	if player and _can_interact(player):
		var pos := player.global_position
		var best_d := RANGE
		for p in _providers:
			if not is_instance_valid(p):
				continue
			for it in p.get_interactions(pos):
				# "priority" (metres) lets talking win over a door right behind the NPC.
				var d := pos.distance_to(it["position"]) - float(it.get("priority", 0.0))
				if d < best_d:
					best_d = d
					best = it
	if best.get("prompt", "") != _current.get("prompt", "") or best.is_empty() != _current.is_empty():
		GameUI.set_prompt("[E] " + str(best["prompt"]) if not best.is_empty() else "")
	_current = best


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_E and not _current.is_empty():
		var action: Callable = _current["action"]
		_current = {}
		GameUI.set_prompt("")
		get_viewport().set_input_as_handled()
		action.call()


func _can_interact(player: Node) -> bool:
	# Hidden / disabled player = driving a car (the car handles its own E).
	if not player.visible or player.process_mode == Node.PROCESS_MODE_DISABLED:
		return false
	return bool(player.get("control_enabled")) and not GameState.input_locked and not GameUI.is_modal_open()
