extends CharacterBody3D
## The walking character: a small potato person (it is Tel Batata after all).

const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")

const WALK := 4.5
const RUN := 9.0
const JUMP := 5.5

var control_enabled := true
var cam_yaw := 0.0

var _model: Node3D
var _bob := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func setup(material: Material) -> void:
	collision_layer = 4
	collision_mask = 1 | 2
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.3
	cs.shape = cap
	cs.position.y = 0.65
	add_child(cs)
	_model = Node3D.new()
	add_child(_model)
	var mi := MeshInstance3D.new()
	mi.mesh = _build_mesh(material)
	_model.add_child(mi)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var input := Vector2.ZERO
	if control_enabled and not GameState.input_locked:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := Vector3(input.x, 0.0, input.y).rotated(Vector3.UP, cam_yaw)
	var speed := RUN if Input.is_action_pressed("run") else WALK
	velocity.x = move_toward(velocity.x, dir.x * speed, 40.0 * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, 40.0 * delta)
	if control_enabled and not GameState.input_locked and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP
	move_and_slide()

	if dir.length_squared() > 0.01:
		_model.rotation.y = lerp_angle(_model.rotation.y, atan2(dir.x, dir.z), 12.0 * delta)
		_bob += delta * (14.0 if speed == RUN else 10.0)
		_model.position.y = absf(sin(_bob)) * 0.1
	else:
		_model.position.y = lerpf(_model.position.y, 0.0, 10.0 * delta)
	if global_position.y < -20.0:
		global_position = CityData.get_player_spawn()
		velocity = Vector3.ZERO


func _build_mesh(material: Material) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var potato := Color("c49a5a")
	var spot := Color("8c6a3a")
	var white := Color("ffffff")
	var dark := Color("2b2b2b")
	var cap := Color("d1495b")
	_sphere(mb, 0.45, Vector3(0, 0.85, 0), Vector3(1.0, 1.25, 0.9), potato, 10)
	_sphere(mb, 0.07, Vector3(0.3, 1.1, 0.25), Vector3.ONE, spot, 6)
	_sphere(mb, 0.06, Vector3(-0.33, 0.7, 0.2), Vector3.ONE, spot, 6)
	for x in [-0.15, 0.15]:
		_sphere(mb, 0.09, Vector3(x, 1.02, 0.36), Vector3(1, 1, 0.6), white, 6)
		_sphere(mb, 0.045, Vector3(x, 1.02, 0.41), Vector3(1, 1, 0.6), dark, 6)
		mb.add_box(Vector3(0.12, 0.38, 0.12), Vector3(x, 0.19, 0), dark)
		mb.add_box(Vector3(0.16, 0.08, 0.24), Vector3(x, 0.04, 0.05), Color("ffffff"))
	mb.add_box(Vector3(0.22, 0.05, 0.05), Vector3(0, 0.82, 0.39), Color("5a3d1f"))
	var hat := CylinderMesh.new()
	hat.top_radius = 0.26
	hat.bottom_radius = 0.3
	hat.height = 0.18
	hat.radial_segments = 10
	mb.add_primitive(hat, Transform3D(Basis(), Vector3(0, 1.43, 0)), cap)
	mb.add_box(Vector3(0.4, 0.04, 0.3), Vector3(0, 1.36, 0.3), cap)
	return mb.commit(material)


func _sphere(mb, r: float, pos: Vector3, scale: Vector3, color: Color, seg: int) -> void:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = maxi(seg / 2, 3)
	mb.add_primitive(s, Transform3D(Basis.from_scale(scale), pos), color)
