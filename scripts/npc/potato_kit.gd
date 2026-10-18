extends RefCounted
## Builds cartoony potato-people (same style as the player in player.gd) into a
## single vertex-coloured mesh. A "look" is a plain Dictionary, usually from
## data/npcs.json:
##   skin, clothes, pants, shoes   "#hex" colours
##   hat      none|cap|police|chief|chef|top|beanie|sunhat|visor|sprout|bow
##   hat_color, band_color         colours for the hat
##   hair     none|bun|curly|short|pigtails     (hair_color)
##   glasses  none|round|sun        mustache true/false   cheeks true/false
##   extras   [apron, badge, tie, sash, whistle, scarf, yarn, lifebuoy,
##             baguette, ball, book, stars, bag]
##   scale    overall size (kids ~0.75)
## Front of the character faces +Z, feet at y = 0, about 1.5 m tall.

const MeshBuilder = preload("res://scripts/core/mesh_builder.gd")

const DARK := Color("2b2b2b")
const WHITE := Color("ffffff")
const GOLD := Color("e2b73c")

static var _cache := {}


static func build(look: Dictionary, material: Material, seated := false) -> ArrayMesh:
	var key := JSON.stringify(look) + str(seated)
	if _cache.has(key):
		return _cache[key]
	var mb := MeshBuilder.new()
	var s := float(look.get("scale", 1.0))
	var root := Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3.ZERO)
	_body(mb, root, look, seated)
	var mesh: ArrayMesh = mb.commit(material)
	_cache[key] = mesh
	return mesh


static func col(look: Dictionary, key: String, fallback: String) -> Color:
	return Color.html(str(look.get(key, fallback)))


static func _body(mb, root: Transform3D, look: Dictionary, seated: bool) -> void:
	var skin := col(look, "skin", "#c49a5a")
	var clothes := col(look, "clothes", "#5d86a6")
	var pants := col(look, "pants", "#3b4a6b")
	var shoes := col(look, "shoes", "#ffffff")
	var extras: Array = look.get("extras", [])
	var y0 := 0.0 if not seated else -0.05

	# Legs (stretched forward when sitting so they rest on the bench edge).
	for x in [-0.15, 0.15]:
		if seated:
			_box(mb, root, Vector3(0.12, 0.12, 0.38), Vector3(x, 0.42, 0.28), pants)
			_box(mb, root, Vector3(0.12, 0.36, 0.12), Vector3(x, 0.24, 0.45), pants)
			_box(mb, root, Vector3(0.16, 0.08, 0.24), Vector3(x, 0.04, 0.5), shoes)
		else:
			_box(mb, root, Vector3(0.12, 0.38, 0.12), Vector3(x, 0.19, 0), pants)
			_box(mb, root, Vector3(0.16, 0.08, 0.24), Vector3(x, 0.04, 0.05), shoes)
	var by := 0.85 + y0
	_sphere(mb, root, 0.45, Vector3(0, by, 0), Vector3(1.0, 1.25, 0.9), skin, 10, 6)
	# Clothes: a slightly larger squashed ellipsoid around the lower body.
	_sphere(mb, root, 0.47, Vector3(0, by - 0.23, 0.0), Vector3(1.0, 0.8, 0.92), clothes, 10, 6)
	# Potato spots.
	var spot := skin.darkened(0.3)
	_sphere(mb, root, 0.06, Vector3(0.3, by + 0.28, 0.24), Vector3.ONE, spot, 5, 3)
	_sphere(mb, root, 0.05, Vector3(-0.26, by + 0.4, 0.18), Vector3.ONE, spot, 5, 3)
	# Arms with round hands.
	for sx in [-1.0, 1.0]:
		var arm_xf := Transform3D(Basis(Vector3.BACK, sx * 0.5), Vector3(sx * 0.47, by - 0.12, 0.02))
		_prim(mb, root * arm_xf, _cyl(0.06, 0.06, 0.34, 6), clothes)
		_sphere(mb, root, 0.08, Vector3(sx * 0.56, by - 0.28, 0.05), Vector3.ONE, skin, 6, 4)
	# Face.
	var fy := by + 0.17
	for x in [-0.15, 0.15]:
		_sphere(mb, root, 0.09, Vector3(x, fy, 0.36), Vector3(1, 1, 0.6), WHITE, 6, 4)
		_sphere(mb, root, 0.045, Vector3(x, fy, 0.41), Vector3(1, 1, 0.6), DARK, 6, 3)
	# Smile: three little segments.
	var mouth := Color("5a3d1f")
	_box(mb, root, Vector3(0.1, 0.04, 0.05), Vector3(0, fy - 0.2, 0.39), mouth)
	_box(mb, root, Vector3(0.06, 0.04, 0.05), Vector3(-0.07, fy - 0.18, 0.385), mouth, 0.0, 0.5)
	_box(mb, root, Vector3(0.06, 0.04, 0.05), Vector3(0.07, fy - 0.18, 0.385), mouth, 0.0, -0.5)
	if bool(look.get("cheeks", true)):
		for x in [-0.27, 0.27]:
			_sphere(mb, root, 0.06, Vector3(x, fy - 0.1, 0.31), Vector3(1, 0.7, 0.5), Color("f08a8a"), 6, 3)
	if bool(look.get("mustache", false)):
		var mc := col(look, "hair_color", "#5a3d1f")
		for x in [-0.07, 0.07]:
			_sphere(mb, root, 0.08, Vector3(x, fy - 0.1, 0.39), Vector3(1.3, 0.5, 0.6), mc, 6, 3)
	match str(look.get("glasses", "none")):
		"round":
			for x in [-0.15, 0.15]:
				var t := TorusMesh.new()
				t.inner_radius = 0.085
				t.outer_radius = 0.11
				t.rings = 8
				t.ring_segments = 4
				_prim(mb, root * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(x, fy, 0.43)), t, DARK)
			_box(mb, root, Vector3(0.1, 0.025, 0.025), Vector3(0, fy + 0.01, 0.44), DARK)
		"sun":
			for x in [-0.15, 0.15]:
				_box(mb, root, Vector3(0.2, 0.12, 0.04), Vector3(x, fy, 0.43), Color("1d1d24"))
			_box(mb, root, Vector3(0.12, 0.03, 0.03), Vector3(0, fy + 0.03, 0.44), Color("1d1d24"))
	_hair(mb, root, look, by)
	_hat(mb, root, look, by)
	for e in extras:
		_extra(mb, root, str(e), look, by)


static func _hair(mb, root: Transform3D, look: Dictionary, by: float) -> void:
	var hc := col(look, "hair_color", "#5a3d1f")
	match str(look.get("hair", "none")):
		"bun":
			_sphere(mb, root, 0.32, Vector3(0, by + 0.42, -0.06), Vector3(1.25, 0.6, 1.15), hc, 8, 4)
			_sphere(mb, root, 0.17, Vector3(0, by + 0.68, -0.12), Vector3.ONE, hc, 8, 4)
		"curly":
			for i in 7:
				var a := TAU * i / 7.0
				_sphere(mb, root, 0.13, Vector3(sin(a) * 0.28, by + 0.48, cos(a) * 0.22 - 0.06), Vector3.ONE, hc, 6, 3)
			_sphere(mb, root, 0.16, Vector3(0, by + 0.6, -0.04), Vector3.ONE, hc, 6, 3)
		"short":
			_sphere(mb, root, 0.35, Vector3(0, by + 0.45, -0.07), Vector3(1.15, 0.55, 1.05), hc, 8, 4)
		"pigtails":
			_sphere(mb, root, 0.35, Vector3(0, by + 0.45, -0.07), Vector3(1.15, 0.55, 1.05), hc, 8, 4)
			for sx in [-1.0, 1.0]:
				_sphere(mb, root, 0.12, Vector3(sx * 0.42, by + 0.35, -0.08), Vector3(1, 1.3, 1), hc, 6, 3)


static func _hat(mb, root: Transform3D, look: Dictionary, by: float) -> void:
	var hc := col(look, "hat_color", "#d1495b")
	var band := col(look, "band_color", "#222222")
	var top := by + 0.56
	match str(look.get("hat", "none")):
		"cap":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top + 0.02, 0)), _cyl(0.26, 0.3, 0.18, 10), hc)
			_box(mb, root, Vector3(0.4, 0.04, 0.3), Vector3(0, top - 0.05, 0.3), hc)
		"police", "chief":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top - 0.02, 0)), _cyl(0.29, 0.29, 0.1, 10), band)
			_prim(mb, root * Transform3D(Basis(Vector3.RIGHT, -0.12), Vector3(0, top + 0.1, -0.02)), _cyl(0.36, 0.3, 0.12, 10), hc)
			_box(mb, root, Vector3(0.38, 0.04, 0.2), Vector3(0, top - 0.06, 0.3), Color("1d1d24"), -0.2)
			_box(mb, root, Vector3(0.11, 0.11, 0.04), Vector3(0, top + 0.08, 0.33), GOLD)
			if str(look.get("hat")) == "chief":
				_box(mb, root, Vector3(0.5, 0.04, 0.05), Vector3(0, top - 0.01, 0.3), GOLD)
		"chef":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top + 0.12, 0)), _cyl(0.27, 0.26, 0.3, 10), WHITE)
			_sphere(mb, root, 0.3, Vector3(0, top + 0.36, 0), Vector3(1.15, 0.75, 1.15), WHITE, 8, 4)
		"top":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top - 0.03, 0)), _cyl(0.42, 0.42, 0.04, 12), hc)
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top + 0.22, 0)), _cyl(0.24, 0.26, 0.48, 12), hc)
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top + 0.06, 0)), _cyl(0.265, 0.265, 0.09, 12), band)
		"beanie":
			_sphere(mb, root, 0.33, Vector3(0, top - 0.06, -0.02), Vector3(1.05, 0.7, 1.0), hc, 8, 4)
			_sphere(mb, root, 0.08, Vector3(0, top + 0.18, -0.02), Vector3.ONE, band, 6, 3)
		"sunhat":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top - 0.04, 0)), _cyl(0.55, 0.55, 0.03, 14), hc)
			_sphere(mb, root, 0.27, Vector3(0, top, 0), Vector3(1, 0.6, 1), hc, 8, 4)
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top - 0.0, 0)), _cyl(0.272, 0.272, 0.07, 10), band)
		"visor":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top - 0.12, 0)), _cyl(0.33, 0.33, 0.08, 10), hc)
			_box(mb, root, Vector3(0.42, 0.03, 0.28), Vector3(0, top - 0.14, 0.4), hc)
		"sprout":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, top + 0.06, 0)), _cyl(0.025, 0.03, 0.16, 4), Color("5fa04e"))
			_sphere(mb, root, 0.08, Vector3(0.07, top + 0.15, 0), Vector3(1.4, 0.4, 0.7), Color("6fbf55"), 6, 3)
			_sphere(mb, root, 0.07, Vector3(-0.07, top + 0.12, 0), Vector3(1.4, 0.4, 0.7), Color("6fbf55"), 6, 3)
		"bow":
			_sphere(mb, root, 0.1, Vector3(-0.12, top - 0.02, 0.05), Vector3(1.2, 0.8, 0.5), hc, 6, 3)
			_sphere(mb, root, 0.1, Vector3(0.12, top - 0.02, 0.05), Vector3(1.2, 0.8, 0.5), hc, 6, 3)
			_sphere(mb, root, 0.05, Vector3(0, top - 0.02, 0.07), Vector3.ONE, band, 6, 3)


static func _extra(mb, root: Transform3D, e: String, look: Dictionary, by: float) -> void:
	var ec := col(look, "extra_color", "#ffffff")
	match e:
		"apron":
			_box(mb, root, Vector3(0.5, 0.55, 0.04), Vector3(0, by - 0.3, 0.44), WHITE, -0.25)
			_box(mb, root, Vector3(0.3, 0.2, 0.04), Vector3(0, by + 0.0, 0.42), WHITE)
		"badge":
			_box(mb, root, Vector3(0.1, 0.12, 0.04), Vector3(0.17, by - 0.06, 0.42), GOLD, -0.3)
		"stars":
			for sx in [-1.0, 1.0]:
				_box(mb, root, Vector3(0.1, 0.04, 0.16), Vector3(sx * 0.42, by - 0.04, 0.0), GOLD)
		"tie":
			_box(mb, root, Vector3(0.09, 0.3, 0.04), Vector3(0, by - 0.12, 0.43), col(look, "extra_color", "#c0392b"), -0.15)
			_box(mb, root, Vector3(0.13, 0.08, 0.05), Vector3(0, by + 0.03, 0.42), col(look, "extra_color", "#c0392b"))
		"sash":
			var xf := Transform3D(Basis(Vector3.BACK, 0.75), Vector3(0, by - 0.1, 0.0))
			_prim(mb, root * xf * Transform3D(Basis.from_scale(Vector3(1, 1, 0.92)), Vector3.ZERO), _cyl(0.48, 0.48, 0.12, 12), GOLD)
		"whistle":
			_box(mb, root, Vector3(0.02, 0.25, 0.02), Vector3(0, by - 0.02, 0.43), DARK)
			_box(mb, root, Vector3(0.08, 0.06, 0.12), Vector3(0, by - 0.16, 0.46), Color("e0e0e0"))
		"scarf":
			_prim(mb, root * Transform3D(Basis(), Vector3(0, by + 0.0, 0)), _cyl(0.4, 0.43, 0.12, 10), ec)
			_box(mb, root, Vector3(0.12, 0.3, 0.06), Vector3(0.18, by - 0.15, 0.4), ec, -0.2)
		"yarn":
			_sphere(mb, root, 0.12, Vector3(0, by - 0.25, 0.5), Vector3.ONE, ec, 6, 4)
			_prim(mb, root * Transform3D(Basis(Vector3.BACK, 0.7), Vector3(-0.08, by - 0.18, 0.55)), _cyl(0.012, 0.012, 0.34, 4), Color("d8b23a"))
			_prim(mb, root * Transform3D(Basis(Vector3.BACK, -0.7), Vector3(0.08, by - 0.18, 0.55)), _cyl(0.012, 0.012, 0.34, 4), Color("d8b23a"))
		"lifebuoy":
			var t := TorusMesh.new()
			t.inner_radius = 0.18
			t.outer_radius = 0.3
			t.rings = 12
			t.ring_segments = 6
			_prim(mb, root * Transform3D(Basis(Vector3.BACK, PI * 0.5) * Basis(Vector3.UP, 0.3), Vector3(0.66, by - 0.3, 0.1)), t, Color("e63946"))
			for k in 4:
				var a := TAU * k / 4.0 + 0.3
				_box(mb, root, Vector3(0.06, 0.13, 0.13), Vector3(0.68, by - 0.3 + sin(a) * 0.24, 0.1 + cos(a) * 0.24), WHITE)
		"baguette":
			_prim(mb, root * Transform3D(Basis(Vector3.RIGHT, 1.0), Vector3(-0.6, by - 0.15, 0.1)), _cyl(0.06, 0.06, 0.7, 6), Color("d9a456"))
		"ball":
			_sphere(mb, root, 0.17, Vector3(0.62, by - 0.38, 0.2), Vector3.ONE, ec, 8, 4)
		"book":
			_box(mb, root, Vector3(0.28, 0.36, 0.08), Vector3(0, by - 0.22, 0.5), ec, 0.0, 0.0, 0.4)
		"bag":
			_box(mb, root, Vector3(0.12, 0.3, 0.35), Vector3(-0.6, by - 0.38, 0.0), ec)


# -------------------------------------------------------------- primitives

static func _box(mb, root: Transform3D, size: Vector3, pos: Vector3, color: Color, rot_x := 0.0, rot_z := 0.0, rot_y := 0.0) -> void:
	var b := Basis.from_euler(Vector3(rot_x, rot_y, rot_z)) * Basis.from_scale(size)
	mb.add_arrays(_unit_box(), root * Transform3D(b, pos), color)


static func _sphere(mb, root: Transform3D, r: float, pos: Vector3, scale: Vector3, color: Color, seg: int, rings: int) -> void:
	var key := "s%d_%d" % [seg, rings]
	if not _cache.has(key):
		var s := SphereMesh.new()
		s.radius = 1.0
		s.height = 2.0
		s.radial_segments = seg
		s.rings = rings
		_cache[key] = s.get_mesh_arrays()
	mb.add_arrays(_cache[key], root * Transform3D(Basis.from_scale(scale * r), pos), color)


static func _cyl(top: float, bottom: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 0
	return c


static func _prim(mb, xf: Transform3D, prim: PrimitiveMesh, color: Color) -> void:
	mb.add_primitive(prim, xf, color)


static func _unit_box() -> Array:
	if not _cache.has("box"):
		_cache["box"] = BoxMesh.new().get_mesh_arrays()
	return _cache["box"]
