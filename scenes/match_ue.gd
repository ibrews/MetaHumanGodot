extends Node3D
## UE "Moonlight" scene match for the explainer side-by-side (v2, 2026-05-31).
## Self-contained; does NOT touch look_dev.gd / emote_render.gd.
##
## v2 changes (the four fixes):
##  1. EYES  — proper eye.gdshader on the MI_EyeL/R_Baked eyeball surfaces, with
##             the real baked iris+sclera textures; eye shell / lashes / lacrimal
##             / hide slots are hidden. The old _tame_materials darkening is gone.
##  2. CAMERA — the EXACT UE CineCamera transform is ported (cm->m, Z-up->Y-up),
##             so height / distance / angle / FOV match the Unreal shot. Model
##             start yaw is env-tunable (MATCH_YAW) and dialled to UE frame 0.
##  3. HAIR  — hair_card.gdshader (alpha-clipped, double-sided) reading the
##             Hair_M_BobMessy CardsAtlas_Attribute R-channel coverage, so the
##             cards read as strands, not flat ribbons.
##  4. LIGHTS — the four UE lights are ported to SpotLight3D / OmniLight3D at the
##             CONVERTED positions + rotations (matched to UE relative to the
##             character). Energies are env-overridable starting values (Sam tunes).
##
## Loads character_explainer.glb at runtime, captures a still (MATCH_CAPTURE=1)
## and/or a 120-frame turntable (MATCH_MOVIETEST=1 MOVIE_FRAMES=120) -> cv2 mp4.

const GLB_PATH := "res://character_explainer.glb"
const MOVIE_DIR := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/frames"
const OUT_STILL := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/godot_still.png"
const OUT_MP4 := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/godot_turntable.mp4"
const LIGHTLOG := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/light_rig_converted.txt"

# Model start yaw: dialled so Godot frame 0 lines up with UE frame 0. The UE
# actor is at yaw -90 and the camera is ported exactly, so this is the residual
# GLB-bind-pose facing offset (found empirically, ~1deg, via frame-0 overlay).
@export var model_yaw_deg := 272.5   # Sam's tuned frame-0 match (gx=-ux handedness-corrected camera); see _ue_pos note. match_lookdev.tscn is now the canonical scene (rich materials + preset).
@export var z_offset := 0.0   # fine depth nudge (m) to match UE framing if needed

var _character: Node3D
var _movie := false
var _movie_total := 120
var _movie_frame := 0
var _spin_start := 0.0

const ASSEMBLE_PY := """
import cv2, os, sys, glob
d, out = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, 'f*.png')))
if not files: sys.exit(2)
img = cv2.imread(files[0]); h, w = img.shape[:2]
for cc in ('avc1','mp4v'):
    vw = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*cc), 30, (w, h))
    if vw.isOpened(): break
for f in files: vw.write(cv2.imread(f))
vw.release(); print('wrote', out, w, 'x', h, len(files), 'frames')
"""

func _envf(n: String, d: float) -> float:
	return float(OS.get_environment(n)) if OS.has_environment(n) else d

func _rtex(filename: String, mip: bool = true) -> Texture2D:
	# Runtime-load a PNG straight from the project dir — no editor .import needed
	# (this scene runs the GLB through GLTFDocument too, same philosophy).
	var p := ProjectSettings.globalize_path("res://" + filename)
	if not FileAccess.file_exists(p):
		push_warning("[match] texture missing on disk: " + p)
		return null
	var img := Image.load_from_file(p)
	if img == null:
		push_warning("[match] failed to load image: " + p)
		return null
	if mip:
		img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _ready() -> void:
	model_yaw_deg = _envf("MATCH_YAW", model_yaw_deg)
	z_offset = _envf("MATCH_ZOFF", z_offset)
	_setup_world()
	_setup_backdrop()
	_setup_lights()
	_setup_camera()
	_load_character()
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = max(2, int(OS.get_environment("MOVIE_FRAMES")))
	if OS.has_environment("MATCH_CAPTURE"):
		await get_tree().create_timer(0.6).timeout
		await _do_still()
		if OS.has_environment("MATCH_MOVIETEST"):
			_start_movie()
		else:
			await get_tree().create_timer(0.2).timeout
			get_tree().quit()

# --- UE -> Godot coordinate conversion --------------------------------------
# UE: cm, Z-up, left-handed (X fwd, Y right, Z up).
# Godot: m, Y-up, right-handed.  Mapping: gx = ux/100, gy = uz/100, gz = -uy/100.
# NOTE the -ux: UE is LEFT-handed, Godot RIGHT-handed. A pure rotation (gx=+ux)
# mirrors the camera VIEW left/right vs the (Blender-handedness-corrected)
# character — that's why the fill light came from the wrong side. Negating X is
# the reflection that makes the whole rig match UE at every frame.
func _ue_pos(ux: float, uy: float, uz: float) -> Vector3:
	return Vector3(-ux / 100.0, uz / 100.0, -uy / 100.0)

func _ue_dir(ux: float, uy: float, uz: float) -> Vector3:
	return Vector3(-ux, uz, -uy).normalized()

func _ue_forward(pitch_deg: float, yaw_deg: float) -> Vector3:
	# UE forward vector from a (pitch, yaw) rotator, in UE axes.
	var p := deg_to_rad(pitch_deg)
	var y := deg_to_rad(yaw_deg)
	var uf := Vector3(cos(p) * cos(y), cos(p) * sin(y), sin(p))
	return _ue_dir(uf.x, uf.y, uf.z)

func _setup_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Faint blue dome so shadow side isn't crushed (UE AmbientLight is also added
	# as a real OmniLight below). Keep low; the real lights do the work.
	env.ambient_light_color = Color(0.0, 0.094, 0.545)   # UE AmbientLight sRGB (0,24,139)
	env.ambient_light_energy = _envf("MATCH_ENVAMB", 0.12)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = _envf("MATCH_EXPOSURE", 1.0)
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 0.5
	env.ssao_intensity = 1.6
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.06
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _setup_backdrop() -> void:
	# Vertical-gradient panel ~ UE SM_HalfSphereBackground + AirGlow.
	var quad := QuadMesh.new()
	quad.size = Vector2(12, 9)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.position = Vector3(0, 1.4, -2.4)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 top_col : source_color = vec3(0.012, 0.03, 0.085);
uniform vec3 bot_col : source_color = vec3(0.05, 0.12, 0.26);
uniform vec3 glow_col : source_color = vec3(0.07, 0.18, 0.38);
void fragment() {
	float v = clamp(UV.y, 0.0, 1.0);
	vec3 c = mix(bot_col, top_col, v);
	float gx = smoothstep(0.55, 0.0, abs(UV.x - 0.5));
	float gy = smoothstep(0.0, 0.6, UV.y) * smoothstep(1.0, 0.45, UV.y);
	c += glow_col * gx * gy * 0.6;
	ALBEDO = c;
}
"""
	var sm := ShaderMaterial.new()
	sm.shader = sh
	mi.material_override = sm
	add_child(mi)

# --- LIGHTS: exact UE transforms, ported -------------------------------------
func _spot(nm: String, ue_loc: Array, pitch: float, yaw: float, col: Color,
		energy: float, outer_deg: float, inner_deg: float, shadow: bool) -> SpotLight3D:
	var s := SpotLight3D.new()
	s.name = nm
	s.position = _ue_pos(ue_loc[0], ue_loc[1], ue_loc[2])
	var fwd := _ue_forward(pitch, yaw)
	s.look_at_from_position(s.position, s.position + fwd, _stable_up(fwd))
	s.light_color = col
	s.light_energy = energy
	s.spot_angle = outer_deg                       # outer cone half-angle (UE outer)
	# inner/outer softness: smaller attenuation = softer edge, less pooling.
	s.spot_angle_attenuation = clampf(inner_deg / maxf(outer_deg, 1.0), 0.1, 1.0)
	s.spot_range = 20.0                            # generous so inverse-square doesn't pool
	s.spot_attenuation = 0.6                       # soft falloff (avoids flashlight blob)
	s.shadow_enabled = shadow
	s.light_specular = 0.4
	add_child(s)
	print("[match] %s  pos=%s  fwd=%s  E=%.2f outer=%.1f" % [nm, s.position, fwd, energy, outer_deg])
	return s

func _stable_up(fwd: Vector3) -> Vector3:
	# avoid look_at gimbal when forward is near-vertical
	return Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD

func _setup_lights() -> void:
	# Energies are STARTING values (UE candela doesn't map to Godot energy with
	# the -12EV exposure removed). Sam tunes via MATCH_KEY/FILL/RIM/AMBIENT/KEYRECT.
	var ke := _envf("MATCH_KEY", 9.0)
	var kre := _envf("MATCH_KEYRECT", 4.0)
	var fe := _envf("MATCH_FILL", 2.6)
	var re := _envf("MATCH_RIM", 5.0)
	var ae := _envf("MATCH_AMBIENT", 1.2)

	# KeyLight_Spot: deep blue top-key, camera-left, the shadow caster.
	_spot("KeyLight_Spot", [63.40, 67.03, 279.20], -75.27, -138.92,
		Color(19.0/255, 46.0/255, 93.0/255), ke, 65.0, 20.0, true)
	# KeyLight_Rect: coincident soft fill (UE RectLight, no shadow) — wide spot.
	_spot("KeyLight_Rect", [63.40, 67.03, 279.20], -75.27, -138.92,
		Color(19.0/255, 46.0/255, 93.0/255), kre, 80.0, 50.0, false)
	# FillLight: olive, lifts shadow side.
	_spot("FillLight", [28.57, 111.70, 111.70], -2.20, -96.03,
		Color(82.0/255, 93.0/255, 77.0/255), fe, 70.0, 40.0, false)
	# RimLight: warm amber, behind — the only warm light (complement to the blue).
	_spot("RimLight", [-136.30, -87.34, 140.94], -1.00, 34.20,
		Color(93.0/255, 62.0/255, 32.0/255), re, 80.0, 45.4, false)

	# AmbientLight: dim saturated-blue point at (0,0,300).
	var amb := OmniLight3D.new()
	amb.name = "AmbientLight"
	amb.position = _ue_pos(0.0, 0.0, 300.0)
	amb.light_color = Color(0.0, 24.0/255, 139.0/255)
	amb.light_energy = ae
	amb.omni_range = 30.0
	amb.omni_attenuation = 0.4
	amb.shadow_enabled = false
	add_child(amb)
	print("[match] AmbientLight pos=%s E=%.2f" % [amb.position, ae])

	# audit log of the converted rig (so the match is reproducible / tunable)
	var f := FileAccess.open(LIGHTLOG, FileAccess.WRITE)
	if f:
		f.store_line("UE -> Godot light rig (cm->m, Z-up->Y-up; gx=ux/100, gy=uz/100, gz=-uy/100)")
		for c in get_children():
			if c is SpotLight3D:
				var s: SpotLight3D = c
				f.store_line("%-14s pos=%v  basisZ(-fwd)=%v  energy=%.2f spot_angle=%.1f" % [
					s.name, s.position, -s.global_transform.basis.z, s.light_energy, s.spot_angle])
			elif c is OmniLight3D:
				f.store_line("%-14s pos=%v  energy=%.2f (Point)" % [c.name, (c as OmniLight3D).position, (c as OmniLight3D).light_energy])
		f.close()

func _setup_camera() -> void:
	# EXACT UE CineCameraActor0: loc(160,-42,158)cm rot(P-4,Y165,R0) FOV28.
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	# 16 (not 28): the UE CineCamera FOV 28 is HORIZONTAL over a 16:9 filmback;
	# its vertical FOV is ~16 deg, which is what a square render must use to match
	# the (letterbox-cropped, square) UE turntable framing in the side-by-side.
	cam.fov = _envf("MATCH_FOV", 16.0)
	cam.near = 0.05
	cam.far = 100.0
	cam.position = _ue_pos(160.0, -42.0, 158.0)            # (1.60, 1.58, 0.42)
	# Aim along the ported UE forward (roll 0 -> up = Y gives roll 0).
	var fwd := _ue_forward(-4.0, 165.0)
	cam.look_at_from_position(cam.position, cam.position + fwd, Vector3.UP)
	cam.current = true
	add_child(cam)
	print("[match] camera pos=%s fwd=%s fov=%.1f" % [cam.position, fwd, cam.fov])

func _load_character() -> void:
	var node: Node3D = null
	var abs_path := ProjectSettings.globalize_path(GLB_PATH)
	if FileAccess.file_exists(abs_path):
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err := doc.append_from_file(abs_path, st)
		if err == OK:
			node = doc.generate_scene(st)
	if node == null and ResourceLoader.exists(GLB_PATH):
		node = (load(GLB_PATH) as PackedScene).instantiate()
	if node == null:
		push_error("[match] could not load " + GLB_PATH); return
	add_child(node)
	_character = node
	# Scale to the character's true height (UE figure ~1.74 m), feet at y=0,
	# centred on X (and Z, with an optional nudge), matching the UE actor at origin.
	var aabb := _world_aabb(node)
	const TARGET_H := 1.74
	var sf: float = TARGET_H / maxf(aabb.size.y, 0.0001)
	node.scale = Vector3(sf, sf, sf)
	# Anchor at the GLB origin (= UE pelvis at world origin): keep X/Z = 0 so the
	# Y-rotation pivots about the SAME axis as the UE actor yaw, and only drop the
	# feet to y=0. (Re-centring the AABB then rotating shifted the figure sideways.)
	var aabb2 := _world_aabb(node)
	node.position = Vector3(0.0, -aabb2.position.y, z_offset)
	node.rotation.y = deg_to_rad(model_yaw_deg)
	_wire_materials(node)
	print("[match] loaded; raw_h=", aabb.size.y, " sf=", sf, " yaw=", model_yaw_deg)

# --- material wiring: eyes + hair + hide slots -------------------------------
func _wire_materials(root: Node) -> void:
	var meshes := _find_meshes(root)
	# 1) Hair cards -> alpha-clipped strand shader (CardsAtlas_Attribute R channel)
	var hair_shader: Shader = load("res://scenes/hair_card.gdshader") as Shader
	var hair_tex := _rtex("exp_hair_atlas.png")
	for mi in meshes:
		if not String(mi.name).begins_with("Hair"):
			continue
		if hair_tex == null:
			push_warning("[match] hair atlas missing"); continue
		var cm := ShaderMaterial.new()
		cm.shader = hair_shader
		cm.set_shader_parameter("hair_color", Color(0.20, 0.13, 0.075))
		cm.set_shader_parameter("coverage_atlas", hair_tex)
		cm.set_shader_parameter("use_red_mask", true)
		cm.set_shader_parameter("invert_mask", false)
		cm.set_shader_parameter("alpha_threshold", _envf("HAIR_THRESH", 0.13))
		cm.set_shader_parameter("root_darkening", 0.42)
		cm.set_shader_parameter("roughness_val", 0.72)
		cm.set_shader_parameter("specular_val", 0.12)
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, cm)
		print("[match] hair cards -> strand shader on %s (%d surf)" % [mi.name, mi.mesh.get_surface_count()])

	# 2) Face: eye shader on eyeball surfaces; hide shell/lash/lacrimal/hide.
	var hide_mat := StandardMaterial3D.new()
	hide_mat.albedo_color = Color(0, 0, 0, 0)
	hide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hide_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var eye_l := _make_eye_material("L")
	var eye_r := _make_eye_material("R")
	for mi in meshes:
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		if mesh == null:
			continue
		var hit := false
		for s in range(mesh.get_surface_count()):
			var nm := _surface_mat_name(mi, s).to_lower()
			if nm == "":
				continue
			if "eyel_baked" in nm or nm == "mi_eyel_baked":
				mi.set_surface_override_material(s, eye_l); hit = true
			elif "eyer_baked" in nm or nm == "mi_eyer_baked":
				mi.set_surface_override_material(s, eye_r); hit = true
			elif ("eyeshell" in nm or "eyelash" in nm or "lacrimal" in nm
					or nm.begins_with("m_hide") or "_hide" in nm):
				mi.set_surface_override_material(s, hide_mat); hit = true
		if hit:
			print("[match] eye/hide wiring on %s (%d surfaces)" % [mi.name, mesh.get_surface_count()])

func _surface_mat_name(mi: MeshInstance3D, s: int) -> String:
	# Prefer the override (none yet), then the active, then the mesh's own material.
	var m: Material = mi.mesh.surface_get_material(s)
	if m and m.resource_name != "":
		return m.resource_name
	if m and m is BaseMaterial3D:
		return (m as BaseMaterial3D).resource_name
	return m.resource_name if m else ""

func _make_eye_material(side: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/eye.gdshader") as Shader
	var ib := _rtex("exp_eye_iris_%s_bc.png" % side)
	var inr := _rtex("exp_eye_iris_%s_n.png" % side)
	var sb := _rtex("exp_eye_sclera_%s_bc.png" % side)
	var sn := _rtex("exp_eye_sclera_%s_n.png" % side)
	if ib: mat.set_shader_parameter("iris_texture", ib)
	if inr: mat.set_shader_parameter("iris_normal", inr)
	if sb: mat.set_shader_parameter("sclera_texture", sb)
	if sn: mat.set_shader_parameter("sclera_normal", sn)
	mat.set_shader_parameter("iris_radius", 0.155)
	mat.set_shader_parameter("blend_softness", 0.02)
	mat.set_shader_parameter("iris_scale", 1.9)
	# sclera reads as light off-white (the MH sclera BC is mid-grey; blend toward white)
	mat.set_shader_parameter("sclera_tint", _envf("EYE_SCLERA_TINT", 0.22))
	mat.set_shader_parameter("normal_strength", 0.55)
	mat.set_shader_parameter("roughness_val", 0.03)
	mat.set_shader_parameter("specular_val", 1.0)
	return mat

func _world_aabb(node: Node) -> AABB:
	var aabb := AABB()
	var first := true
	for mi in _find_meshes(node):
		var world_aabb: AABB = mi.global_transform * mi.get_aabb()
		if first:
			aabb = world_aabb; first = false
		else:
			aabb = aabb.merge(world_aabb)
	return aabb

func _find_meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_meshes(c))
	return out

# --- capture -----------------------------------------------------------------
func _do_still() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(MOVIE_DIR.get_base_dir())
	img.save_png(OUT_STILL)
	print("[match] still -> ", OUT_STILL)

func _start_movie() -> void:
	DirAccess.make_dir_recursive_absolute(MOVIE_DIR)
	_movie = true
	_movie_frame = 0
	_spin_start = _character.rotation.y if _character else 0.0
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.connect(_on_post_draw)
	print("[match] recording turntable -> ", MOVIE_DIR)

func _on_post_draw() -> void:
	if not _movie: return
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [MOVIE_DIR, _movie_frame])
	_movie_frame += 1
	if _movie_frame >= _movie_total:
		_finish_movie()
	elif _character:
		_character.rotation.y = _spin_start + deg_to_rad(360.0) * float(_movie_frame) / float(_movie_total)

func _finish_movie() -> void:
	_movie = false
	if RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	var py := "%s/_assemble.py" % MOVIE_DIR
	var pf := FileAccess.open(py, FileAccess.WRITE)
	pf.store_string(ASSEMBLE_PY); pf.close()
	var o := []
	OS.execute("python", [py, MOVIE_DIR, OUT_MP4], o, true)
	print("[match] movie -> ", OUT_MP4, " ", o)
	get_tree().quit()
