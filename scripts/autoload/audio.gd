extends Node
## Music + sound effects (all synthesised by tools/make_audio.py).
##   Audio.play_sfx("coin")            one-shot UI/world sound (pooled players)
##   Audio.play_music("fight")         cross-fades to another loop ("city", "fight", "victory")
## Common gameplay sounds are hooked to GameState signals here, so other
## systems get sound without calling anything.

const DIR := "res://assets/audio/"
const MUSIC := {"city": "music_city", "fight": "music_fight", "victory": "music_victory"}
const POOL := 8

var _streams := {}
var _pool: Array = []
var _next := 0
var _music: Array = []  # two players for cross-fading
var _music_idx := 0
var _music_name := ""
var _fade := 0.0
var _ocean: AudioStreamPlayer
var _last_coins := 0
var _last_hearts := 0
var _fight_left := 0.0
var _scan_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	for i in 2:
		var m := AudioStreamPlayer.new()
		m.volume_db = -80.0
		add_child(m)
		_music.append(m)
	_ocean = AudioStreamPlayer.new()
	_ocean.stream = _load_stream("amb_ocean", true)
	_ocean.volume_db = -80.0
	add_child(_ocean)
	_last_coins = GameState.coins
	_last_hearts = GameState.hearts
	GameState.coins_changed.connect(_on_coins)
	GameState.hearts_changed.connect(_on_hearts)
	GameState.game_event.connect(_on_event)
	if not _is_test_run():
		play_music("city")
		_ocean.play()


func _is_test_run() -> bool:
	var a := OS.get_cmdline_user_args()
	return "--smoke" in a or "--shots" in a or "--benchmark" in a


## volume_db is added to the global SFX volume; pitch is randomised slightly.
func play_sfx(name: String, volume_db := 0.0, pitch_jitter := 0.06) -> void:
	var s := _load_stream("sfx_" + name)
	if s == null:
		return
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % POOL
	p.stream = s
	p.volume_db = linear_to_db(maxf(Settings.sfx_volume, 0.0001)) + volume_db
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func play_music(name: String) -> void:
	if name == _music_name or not MUSIC.has(name):
		return
	_music_name = name
	_music_idx = 1 - _music_idx
	var m: AudioStreamPlayer = _music[_music_idx]
	m.stream = _load_stream(MUSIC[name], name != "victory")
	m.volume_db = -40.0
	m.play()
	_fade = 1.0
	if name == "victory":
		m.finished.connect(func(): play_music("city"), CONNECT_ONE_SHOT)


## A looping stream for vehicles etc.
func get_stream(name: String, loop := true) -> AudioStream:
	return _load_stream(name, loop)


func _process(delta: float) -> void:
	var target := linear_to_db(maxf(Settings.music_volume, 0.0001))
	if _fade > 0.0:
		_fade = maxf(_fade - delta / 1.5, 0.0)
	var cur: AudioStreamPlayer = _music[_music_idx]
	var old: AudioStreamPlayer = _music[1 - _music_idx]
	cur.volume_db = lerpf(target, -40.0, _fade)
	old.volume_db = lerpf(-60.0, target, _fade)
	if _fade == 0.0 and old.playing:
		old.stop()
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = 0.5
		_update_ambience()


## Ocean volume by distance to the shore; fight music while enemies are near.
func _update_ambience() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		return
	var sea_x := float(CityData.environment.get("sea_x", -1e9))
	var d := player.global_position.x - sea_x
	var k := clampf(1.0 - d / 90.0, 0.0, 1.0) * Settings.sfx_volume
	_ocean.volume_db = linear_to_db(maxf(k * 0.8, 0.0001))
	var near := false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e is Node3D and (e as Node3D).global_position.distance_to(player.global_position) < 30.0:
			near = true
			break
	if near:
		_fight_left = 4.0
		if _music_name == "city":
			play_music("fight")
	elif _music_name == "fight":
		_fight_left -= 0.5
		if _fight_left <= 0.0:
			play_music("city")


func _on_coins(c: int) -> void:
	if c > _last_coins:
		play_sfx("coin", -4.0)
	_last_coins = c


func _on_hearts(h: int, _max_h: int) -> void:
	if h < _last_hearts:
		play_sfx("hurt")
	_last_hearts = h


func _on_event(name: String, _data: Dictionary) -> void:
	if name == "defeat:boss":
		play_music("victory")
		play_sfx("plop", 3.0)
	elif name.begins_with("defeat:"):
		play_sfx("plop")
	elif name.begins_with("pickup:"):
		play_sfx("pickup", -3.0)
	elif name.begins_with("enter:") or name == "exit_interior":
		play_sfx("door", -4.0)
	elif name.begins_with("quest_complete") or name.begins_with("chapter"):
		play_sfx("quest")


func _load_stream(name: String, loop := false) -> AudioStream:
	var key := "%s|%d" % [name, int(loop)]
	if _streams.has(key):
		return _streams[key]
	var path := DIR + name + ".ogg"
	if not ResourceLoader.exists(path):
		_streams[key] = null
		return null
	var s: AudioStream = load(path)
	if s is AudioStreamOggVorbis:
		s = s.duplicate()
		s.loop = loop
	_streams[key] = s
	return s
