extends Node
## Graphics quality presets + input map. Defaults to "low" because the
## target machine is a weak PC; F2 cycles presets in-game.

signal changed

const PATH := "user://settings.cfg"
const ORDER := ["low", "medium", "high"]
const LABELS := {"low": "נמוכה", "medium": "בינונית", "high": "גבוהה"}

## view_chunks: chunk radius kept loaded around the camera (chunk = 64m).
## lod_distance: beyond it a chunk switches to its merged low-detail mesh.
## far_distance: nothing is drawn beyond it (hidden by fog).
const PRESETS := {
	"low": {
		"shadows": false, "shadow_distance": 40.0, "prop_shadows": false,
		"view_chunks": 4, "lod_distance": 85.0, "far_distance": 320.0,
		"prop_distance": 55.0, "per_vertex": true, "cars": 12,
		"max_fps": 60, "msaa": false, "chunks_per_frame": 1,
	},
	"medium": {
		"shadows": false, "shadow_distance": 45.0, "prop_shadows": false,
		"view_chunks": 5, "lod_distance": 110.0, "far_distance": 380.0,
		"prop_distance": 80.0, "per_vertex": false, "cars": 24,
		"max_fps": 60, "msaa": false, "chunks_per_frame": 1,
	},
	"high": {
		"shadows": true, "shadow_distance": 80.0, "prop_shadows": true,
		"view_chunks": 6, "lod_distance": 150.0, "far_distance": 460.0,
		"prop_distance": 115.0, "per_vertex": false, "cars": 40,
		"max_fps": 120, "msaa": true, "chunks_per_frame": 2,
	},
}

var quality := "low"
var presets: Dictionary = PRESETS.duplicate(true)
var show_stats := false
var music_volume := 0.6
var sfx_volume := 0.85
var auto_quality := true


func _ready() -> void:
	_ensure_input()
	_load()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality=") and PRESETS.has(arg.get_slice("=", 1)):
			quality = arg.get_slice("=", 1)  # this run only, not saved
			auto_quality = false
	# Testing aid: --set:shadows=false overrides one preset value for this run.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--set:"):
			var kv := arg.trim_prefix("--set:").split("=")
			if kv.size() == 2 and presets[quality].has(kv[0]):
				presets[quality][kv[0]] = str_to_var(kv[1])


func get_v(key: String) -> Variant:
	return presets[quality][key]


func quality_label() -> String:
	return LABELS.get(quality, quality)


func set_quality(q: String) -> void:
	if not PRESETS.has(q) or q == quality:
		return
	quality = q
	save()
	changed.emit()


func cycle_quality() -> void:
	set_quality(ORDER[(ORDER.find(quality) + 1) % ORDER.size()])


## Returns false when already at the lowest preset.
func lower_quality() -> bool:
	var i := ORDER.find(quality)
	if i <= 0:
		return false
	set_quality(ORDER[i - 1])
	return true


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "show_fps", show_stats)
	cfg.set_value("graphics", "auto_quality", auto_quality)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.save(PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	var q := str(cfg.get_value("graphics", "quality", quality))
	if PRESETS.has(q):
		quality = q
	show_stats = bool(cfg.get_value("graphics", "show_fps", show_stats))
	auto_quality = bool(cfg.get_value("graphics", "auto_quality", auto_quality))
	music_volume = float(cfg.get_value("audio", "music", music_volume))
	sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))


## Physical keycodes, so WASD works the same on a Hebrew keyboard layout.
func _ensure_input() -> void:
	var map := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"run": [KEY_SHIFT],
		"fly_up": [KEY_E, KEY_SPACE],
		"fly_down": [KEY_Q, KEY_CTRL],
	}
	for action in map:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
