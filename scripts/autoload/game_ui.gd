extends CanvasLayer
## Game interface (OWNER: agent C). Other systems call only these methods.

signal dialogue_finished(speaker: String)


## Shows a dialogue box. lines: Array of Strings. Locks input until closed,
## then calls on_done (if valid) and emits dialogue_finished.
func show_dialogue(speaker: String, lines: Array, on_done := Callable()) -> void:
	for l in lines:
		print("%s: %s" % [speaker, l])
	dialogue_finished.emit(speaker)
	if on_done.is_valid():
		on_done.call()


## Opens the shop window for a building type (items come from data/items.json).
func open_shop(_shop_type: String, _shop_name: String) -> void:
	pass


func toast(text: String) -> void:
	print(text)


## Interaction prompt near the player ("" hides it).
func set_prompt(_text: String) -> void:
	pass


## True while any modal window (dialogue, shop, menu) is open.
func is_modal_open() -> bool:
	return false
