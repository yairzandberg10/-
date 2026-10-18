extends Node
## Player progress shared by every gameplay system (OWNER: agent C – story/combat/UI).
## Other systems only use the public API below; keep these signatures stable.
##
## Event names (emit_event) – the contract between systems:
##   "talk:<npc_id>"          dialogue with a named NPC finished        (NPC system)
##   "enter:<building_type>"  player entered a building interior        (interior system)
##   "enter_id:<object_id>"   same, by CityData object id               (interior system)
##   "exit_interior"          player left an interior                   (interior system)
##   "buy:<item_id>"          item bought in a shop                      (shop UI)
##   "pickup:<item_id>"       collectible picked up                      (story system)
##   "defeat:<enemy_type>"    enemy defeated                             (combat system)

signal coins_changed(coins: int)
signal hearts_changed(hearts: int, max_hearts: int)
signal inventory_changed
signal game_event(name: String, data: Dictionary)

var coins := 0
var hearts := 5
var max_hearts := 5
var inventory: Dictionary = {}  # item_id -> count
var flags: Dictionary = {}      # free-form story flags
## True while a menu/dialogue is open: player movement and attacks are ignored.
var input_locked := false


func add_coins(n: int) -> void:
	coins = maxi(coins + n, 0)
	coins_changed.emit(coins)


func spend_coins(n: int) -> bool:
	if coins < n:
		return false
	add_coins(-n)
	return true


func add_item(item_id: String, n := 1) -> void:
	inventory[item_id] = int(inventory.get(item_id, 0)) + n
	inventory_changed.emit()


func has_item(item_id: String, n := 1) -> bool:
	return int(inventory.get(item_id, 0)) >= n


func damage(n := 1) -> void:
	hearts = maxi(hearts - n, 0)
	hearts_changed.emit(hearts, max_hearts)


func heal(n := 1) -> void:
	hearts = mini(hearts + n, max_hearts)
	hearts_changed.emit(hearts, max_hearts)


func emit_event(name: String, data := {}) -> void:
	game_event.emit(name, data)


## Story hook for NPCs: returns {"lines": [...], "speaker": "..."} when the story
## wants to override what `npc_id` says right now, otherwise {}.
func get_story_dialogue(_npc_id: String) -> Dictionary:
	return {}
