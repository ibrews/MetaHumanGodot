extends Node3D
## ============================================================================
## MetaHuman -> Godot  ·  RELEASE look-dev / turntable tool
## ============================================================================
## "Best of both worlds" — consolidates scenes/look_dev.gd (the rich MH_Test
## tuner) and scenes/match_lookdev.gd (the UE-matched explainer tuner) into ONE
## scene. Stock Godot 4.6 Forward+; no engine fork.
##
##   * CHARACTER TOGGLE  — switch live between the shipped "guy" (character.glb,
##     MetaHumanFace index-surface wiring, 51 ARKit shapes baked) and "her"
##     (character_explainer.glb, MI_*_Baked name-surface wiring). Re-wires
##     skin / eyes / hair / hide slots per the character profile.
##   * LOAD CUSTOM       — file dialog -> runtime GLTFDocument load of any GLB,
##     per-mesh unit-normalize (skeletal-vs-static cm/m fix), best-effort wiring.
##   * 51 ARKit SHAPES   — toggleable scrollable panel of the canonical ARKit
##     blendshapes; each drives set_blend_shape_value across every mesh that
##     carries that named shape (face + propagated grooms). Disabled when a
##     character lacks it (e.g. a static explainer until it is re-baked).
##   * FULL LOOK-DEV     — skin (SSS/scatter/smoothness/normal/rough/spec/micro),
##     hair (colour/threshold/root/rough/spec/backing), eyes (iris/sclera/
##     clearcoat), per-light energy+colour, exposure/glow/env-amb, AgX tonemap,
##     SSIL, colour balance, catchlight, model yaw, manual numeric entry on every
##     slider, UE-frame-0 overlay.
##   * PER-CHARACTER PRESETS — save/load JSON keyed by character; ships moonlight
##     + neutral-studio samples for each.
##   * HEADLESS CAPTURE  — RELEASE_CHAR=guy|her RELEASE_CAPTURE=1 [RELEASE_MOVIE=1]
##     renders a still (+ 120f turntable mp4 via cv2), for regenerating matched
##     side-by-sides.
##
## Launch (interactive):
##   & "H:/dev/godot-stock/Godot_v4.6-stable_win64.exe" --path "H:/Work01/MetaHumanGodot/godot_project" "scenes/release.tscn" --resolution 1280x1280
## Keys:  C = next character · B = blendshape panel · H = look panel · O = overlay · P = save preset
## ============================================================================

# ---- character profiles -----------------------------------------------------
# Everything that differs between the two shipped MetaHumans. The unified
# wiring/material code is profile-driven so adding a third character is data,
# not code.
const PROFILES := {
	"her": {
		"label": "Her — MH_Explainer",
		"glb": "res://character_explainer.glb",
		"face_mode": "name",                       # wire face surfaces by material name
		"face_mesh_name": "Face",
		"head_bc": "exp_head_bc.png", "head_n": "exp_head_n.png",
		"head_srmf": "exp_head_srmf.png", "head_scatter": "exp_head_scatter.png",
		"body_bc": "exp_body_bc.png", "body_n": "exp_body_n.png",
		"body_srmf": "exp_body_srmf.png", "body_scatter": "exp_body_scatter.png",
		"iris_tpl": "exp_eye_iris_%s_bc.png", "iris_n_tpl": "exp_eye_iris_%s_n.png",
		"sclera_tpl": "exp_eye_sclera_%s_bc.png", "sclera_n_tpl": "exp_eye_sclera_%s_n.png",
		"hair_atlases": [["Hair_", "exp_hair_atlas.png", Color(0.20, 0.13, 0.075)]],
		"default_preset": "her__moonlight",
	},
	"guy": {
		"label": "Guy — MH_Test",
		"glb": "res://character.glb",
		"face_mode": "index",                      # MetaHumanFace per-surface-index map
		"face_mesh_name": "MetaHumanFace",
		# verified surface map (see emote_render.gd header): 0,7 skin · 1 teeth ·
		# 3 eyeR · 4 eyeL · 2,5,6,8 hide
		"face_index_map": {0: "skin", 1: "teeth", 2: "hide", 3: "eyeR", 4: "eyeL",
			5: "hide", 6: "hide", 7: "skin", 8: "hide"},
		"head_bc": "character_T_Head_LOD1_BC_VT.png", "head_n": "character_T_Head_LOD1_N_VT.png",
		"head_srmf": "character_T_Head_LOD1_SRMF_VT.png", "head_scatter": "T_Head_LOD1_Scatter_VT.png",
		"body_bc": "character_T_Body_BC_VT.png", "body_n": "character_T_Body_N_VT.png",
		"body_srmf": "character_T_Body_SRMF_VT.png", "body_scatter": "T_Body_Scatter_VT.png",
		"teeth_bc": "character_T_Teeth_BC.png", "teeth_n": "character_T_Teeth_N.png",
		"iris_tpl": "eye_iris_%s_bc.png", "iris_n_tpl": "eye_iris_%s_n.png",
		"sclera_tpl": "eye_sclera_%s_bc.png", "sclera_n_tpl": "eye_sclera_%s_n.png",
		"hair_atlases": [
			["Hair_", "hair_attr.png", Color(0.34, 0.27, 0.17)],
			["Beard_", "beard_attr.png", Color(0.28, 0.205, 0.115)],
			["Eyebrows_", "eyebrows_attr.png", Color(0.22, 0.16, 0.095)],
			["Mustache_", "mustache_attr.png", Color(0.28, 0.205, 0.115)],
			["Moustache_", "mustache_attr.png", Color(0.28, 0.205, 0.115)],
		],
		"default_preset": "guy__studio",
	},
}
const CHAR_ORDER := ["her", "guy"]

# Canonical Apple/ARKit 52 blendshape names (MetaHuman camelCase). The panel
# builds a slider per name; only those present on the loaded face are enabled.
const ARKIT_NAMES := [
	"browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
	"cheekPuff", "cheekSquintLeft", "cheekSquintRight",
	"eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
	"eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
	"eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
	"eyeWideLeft", "eyeWideRight",
	"jawForward", "jawLeft", "jawOpen", "jawRight",
	"mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight",
	"mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight",
	"mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight",
	"mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
	"mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight",
	"mouthUpperUpLeft", "mouthUpperUpRight",
	"noseSneerLeft", "noseSneerRight", "tongueOut",
]

const PRESET_DIR := "res://presets"          # shipped samples (tracked, code)
const OUT_DIR := "H:/Work01/MetaHumanGodot/out/release"

# ---- live look parameters (defaults mirror the explainer moonlight match) ----
var p := {
	# lighting
	"key": 3.0, "keyrect": 1.5, "fill": 6.3, "rim": 10.8, "ambient": 1.0,
	"env_amb": 0.25, "exposure": 1.06, "glow": 0.9, "catch": 0.0,
	"key_col": Color(19.0/255, 46.0/255, 93.0/255),
	"keyrect_col": Color(19.0/255, 46.0/255, 93.0/255),
	"fill_col": Color(82.0/255, 93.0/255, 77.0/255),
	"rim_col": Color(93.0/255, 62.0/255, 32.0/255),
	"amb_col": Color(0.0, 24.0/255, 139.0/255),
	"catch_col": Color(1.0, 0.98, 0.95),
	# skin
	"sss": 0.1, "skin_smooth": 0.62, "skin_nrm": 1.65, "skin_rough": 0.59,
	"skin_spec": 0.33, "scatter": 2.15, "double_spec": false, "sss_depth": 6.0,
	"micro": 0.0,
	# hair
	"hair_col": Color(0.20, 0.13, 0.075), "hair_thresh": 0.07,
	"hair_root": 0.42, "hair_rough": 0.72, "hair_spec": 0.12,
	"hair_back_cut": 0.035, "hair_back_inset": 0.009,
	# eyes
	"sclera_tint": 0.35, "iris_scale": 1.62, "iris_radius": 0.185,
	"eye_rough": 0.03, "eye_spec": 1.0, "eye_clearcoat": 0.25,
	# colour balance
	"saturation": 1.06, "brightness": 1.0, "contrast": 1.05,
	# scene
	"model_yaw": 272.5, "overlay": 0.0, "zoff": 0.0,
	"view_pan": -1.2,    # interactive frustum shift so subject clears the panel
	"cap_pan": -0.176,   # capture-time centering
}

var _char_key := "her"
var _profile := {}
var _character: Node3D
var _env: Environment
var _lights := {}
var _catch: OmniLight3D
var _skin_mats: Array[ShaderMaterial] = []
var _hair_mats: Array[ShaderMaterial] = []
var _hair_back_mats: Array[ShaderMaterial] = []
var _eye_mats: Array[ShaderMaterial] = []
var _hair_meshes: Array[MeshInstance3D] = []

var _bs_map := {}          # shape name -> Array of [MeshInstance3D, idx]
var _bs_values := {}       # shape name -> float (current)

var _overlay: TextureRect
var _panel: Control
var _bs_panel: Control
var _bs_rows := {}         # name -> {slider, spin, label}
var _camera: Camera3D
var _preset_name: LineEdit
var _preset_dd: OptionButton
var _char_btn: Button
var _status: Label
var _refreshers: Array = []
var _file_dialog: FileDialog

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

func _ready() -> void:
	_char_key = OS.get_environment("RELEASE_CHAR") if OS.has_environment("RELEASE_CHAR") else "her"
	if not PROFILES.has(_char_key):
		_char_key = "her"
	_profile = PROFILES[_char_key]
	# start from the character's default preset, if shipped
	_load_preset_file("%s/%s.json" % [PRESET_DIR, _profile.get("default_preset", "")])
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = max(2, int(OS.get_environment("MOVIE_FRAMES")))
	_setup_world(); _setup_backdrop(); _setup_lights(); _setup_camera()
	_load_character()
	_setup_ui()
	# Headless QA hook: RELEASE_TOGGLE=1 exercises the live character switch.
	if OS.has_environment("RELEASE_TOGGLE"):
		_switch_character()
	# Headless QA hook: RELEASE_CUSTOM=<abs path> exercises the custom-GLB loader.
	if OS.has_environment("RELEASE_CUSTOM"):
		_load_character(OS.get_environment("RELEASE_CUSTOM"))
		_rebuild_bs_panel(); _refresh_controls()
	_apply_all()
	# Headless QA hook: RELEASE_BS="jawOpen=1.0,eyeBlinkLeft=1.0" drives shapes.
	if OS.has_environment("RELEASE_BS"):
		for tok in OS.get_environment("RELEASE_BS").split(","):
			var kv := tok.split("=")
			if kv.size() == 2:
				_set_blendshape(kv[0].strip_edges(), float(kv[1]))
	# Headless: RELEASE_CAPTURE=1 -> still (+ RELEASE_MOVIE=1 -> 120f turntable).
	if OS.has_environment("RELEASE_CAPTURE"):
		if _panel: _panel.visible = false
		if _bs_panel: _bs_panel.visible = false
		if _overlay: _overlay.modulate.a = 0.0
		await get_tree().create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/release_%s_still.png" % [OUT_DIR, _char_key])
		print("[release] still saved for ", _char_key)
		if OS.has_environment("RELEASE_MOVIE"):
			_start_movie()
		else:
			await get_tree().create_timer(0.1).timeout
			get_tree().quit()

# ---- UE -> Godot conversion (gx=-ux handedness fix) -------------------------
func _ue_pos(ux: float, uy: float, uz: float) -> Vector3:
	return Vector3(-ux / 100.0, uz / 100.0, -uy / 100.0)
func _ue_forward(pitch_deg: float, yaw_deg: float) -> Vector3:
	var pr := deg_to_rad(pitch_deg); var yr := deg_to_rad(yaw_deg)
	var uf := Vector3(cos(pr) * cos(yr), cos(pr) * sin(yr), sin(pr))
	return Vector3(-uf.x, uf.z, -uf.y).normalized()
func _stable_up(fwd: Vector3) -> Vector3:
	return Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
func _envf(n: String, d: float) -> float:
	return float(OS.get_environment(n)) if OS.has_environment(n) else d

# ---- environment / backdrop -------------------------------------------------
func _setup_world() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.050, 0.118, 0.280)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.0, 0.094, 0.545)
	_env.ambient_light_energy = p.env_amb
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX   # filmic, gentle rolloff
	_env.tonemap_exposure = p.exposure
	_env.glow_enabled = true
	_env.glow_intensity = p.glow
	_env.glow_bloom = 0.15
	_env.ssao_enabled = true
	_env.ssao_radius = 0.3
	_env.ssao_intensity = 0.7
	_env.ssil_enabled = true
	_env.ssil_radius = 5.0
	_env.ssil_intensity = 1.0
	_env.ssil_sharpness = 0.98
	_env.adjustment_enabled = true
	_env.adjustment_contrast = p.contrast
	_env.adjustment_saturation = p.saturation
	_env.adjustment_brightness = p.brightness
	var we := WorldEnvironment.new(); we.environment = _env; add_child(we)

func _setup_backdrop() -> void:
	var quad := QuadMesh.new(); quad.size = Vector2(26, 16)
	var mi := MeshInstance3D.new(); mi.mesh = quad; mi.position = Vector3(0, 1.4, -3.0)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 top_col : source_color = vec3(0.045, 0.110, 0.260);
uniform vec3 bot_col : source_color = vec3(0.055, 0.130, 0.295);
uniform vec3 glow_col : source_color = vec3(0.05, 0.13, 0.28);
uniform float glow_amt = 0.18;
void fragment() {
	float v = clamp(UV.y, 0.0, 1.0);
	vec3 c = mix(bot_col, top_col, v);
	float gx = smoothstep(0.6, 0.0, abs(UV.x - 0.5));
	float gy = smoothstep(0.0, 0.6, UV.y) * smoothstep(1.0, 0.45, UV.y);
	c += glow_col * gx * gy * glow_amt;
	ALBEDO = c;
}
"""
	var sm := ShaderMaterial.new(); sm.shader = sh; mi.material_override = sm; add_child(mi)

# ---- lights (ported UE moonlight rig) ---------------------------------------
func _spot(nm: String, ue_loc: Array, pitch: float, yaw: float, col: Color,
		outer_deg: float, inner_deg: float, shadow: bool) -> SpotLight3D:
	var s := SpotLight3D.new(); s.name = nm
	s.position = _ue_pos(ue_loc[0], ue_loc[1], ue_loc[2])
	var fwd := _ue_forward(pitch, yaw)
	s.look_at_from_position(s.position, s.position + fwd, _stable_up(fwd))
	s.light_color = col
	s.spot_angle = outer_deg
	s.spot_angle_attenuation = clampf(inner_deg / maxf(outer_deg, 1.0), 0.1, 1.0)
	s.spot_range = 20.0; s.spot_attenuation = 0.6
	s.shadow_enabled = shadow; s.light_specular = 0.4
	add_child(s); return s

func _setup_lights() -> void:
	_lights["key"] = _spot("KeyLight_Spot", [63.40, 67.03, 279.20], -75.27, -138.92, p.key_col, 65.0, 20.0, true)
	_lights["keyrect"] = _spot("KeyLight_Rect", [63.40, 67.03, 279.20], -75.27, -138.92, p.keyrect_col, 80.0, 50.0, false)
	_lights["fill"] = _spot("FillLight", [28.57, 111.70, 111.70], -2.20, -96.03, p.fill_col, 70.0, 40.0, false)
	_lights["rim"] = _spot("RimLight", [-136.30, -87.34, 140.94], -1.00, 34.20, p.rim_col, 80.0, 45.4, false)
	var amb := OmniLight3D.new(); amb.name = "AmbientLight"
	amb.position = _ue_pos(0.0, 0.0, 300.0)
	amb.light_color = p.amb_col
	amb.omni_range = 30.0; amb.omni_attenuation = 0.4
	add_child(amb); _lights["ambient"] = amb
	# Catchlight: tiny omni near the camera (the #1 eye/skin life-giver). Off by
	# default for the moonlight match; raise "Catchlight" for a portrait look.
	_catch = OmniLight3D.new(); _catch.name = "Catchlight"
	_catch.light_color = p.catch_col
	_catch.omni_range = 5.0; _catch.omni_attenuation = 1.0
	_catch.shadow_enabled = false
	add_child(_catch)

func _setup_camera() -> void:
	_camera = Camera3D.new(); _camera.name = "Camera3D"
	_camera.fov = _envf("RELEASE_FOV", 16.0); _camera.near = 0.05; _camera.far = 100.0
	_camera.position = _ue_pos(160.0, -42.0, 158.0)
	var fwd := _ue_forward(-4.0, 165.0)
	_camera.look_at_from_position(_camera.position, _camera.position + fwd, Vector3.UP)
	if OS.has_environment("KEEP_PAN") or not OS.has_environment("RELEASE_CAPTURE"):
		_camera.h_offset = p.view_pan
	else:
		_camera.h_offset = _envf("CAP_H", p.get("cap_pan", 0.0))
	_camera.current = true; add_child(_camera)

# ---- textures ---------------------------------------------------------------
func _rtex(filename: String, mip := true) -> Texture2D:
	if filename == "" or filename == null: return null
	var pa := ProjectSettings.globalize_path("res://" + filename)
	if not FileAccess.file_exists(pa): return null
	var img := Image.load_from_file(pa)
	if img == null: return null
	if mip: img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _white_tex() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color(1, 1, 1))
	return ImageTexture.create_from_image(img)

# ---- character load / switch ------------------------------------------------
func _clear_character() -> void:
	if _character and is_instance_valid(_character):
		_character.queue_free()
	_character = null
	_skin_mats.clear(); _hair_mats.clear(); _hair_back_mats.clear()
	_eye_mats.clear(); _hair_meshes.clear()
	_bs_map.clear()

func _load_character(custom_path := "") -> void:
	_clear_character()
	var abs_path := custom_path
	if abs_path == "":
		abs_path = ProjectSettings.globalize_path(_profile["glb"])
	var node: Node3D = null
	if FileAccess.file_exists(abs_path):
		var doc := GLTFDocument.new(); var st := GLTFState.new()
		if doc.append_from_file(abs_path, st) == OK:
			node = doc.generate_scene(st)
	if node == null:
		push_error("[release] load failed: " + abs_path)
		_set_status("LOAD FAILED: " + abs_path.get_file())
		return
	add_child(node); _character = node
	# Per-mesh unit normalize — ONLY for arbitrary custom GLBs, which may mix
	# skeletal (cm scale on armature) and static (cm on mesh) meshes. Gauge in
	# WORLD space so a skeletal mesh whose parent already supplies the 0.01 isn't
	# double-shrunk. The two shipped characters are already internally consistent
	# (her static-metres; guy cm-on-armature but world-correct) so we skip this and
	# let the whole-node scale-to-1.74 handle them, exactly like look_dev/match_ue.
	if custom_path != "":
		for mi in _find_meshes(node):
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if maxf(wa.size.x, maxf(wa.size.y, wa.size.z)) > 10.0:
				mi.scale = mi.scale * 0.01
	# Scale whole figure to ~1.74 m, feet to y=0, anchored at GLB origin (UE pelvis).
	var aabb := _world_aabb(node)
	var sf: float = 1.74 / maxf(aabb.size.y, 0.0001)
	node.scale = Vector3(sf, sf, sf)
	var aabb2 := _world_aabb(node)
	node.position = Vector3(0.0, -aabb2.position.y, p.zoff)
	node.rotation.y = deg_to_rad(p.model_yaw)
	if custom_path == "":
		_wire_materials(node)
	else:
		_wire_custom(node)
	_collect_blendshapes(node)

func _switch_character() -> void:
	var i := CHAR_ORDER.find(_char_key)
	_char_key = CHAR_ORDER[(i + 1) % CHAR_ORDER.size()]
	_profile = PROFILES[_char_key]
	_load_preset_file("%s/%s.json" % [PRESET_DIR, _profile.get("default_preset", "")])
	_load_character()
	_rebuild_bs_panel()
	_refresh_preset_list()
	_refresh_controls()
	_apply_all()
	if _char_btn: _char_btn.text = "Character: " + _profile["label"]
	_set_status("Loaded " + _profile["label"])

# ---- material wiring (profile-driven) ---------------------------------------
func _wire_materials(root: Node) -> void:
	var meshes := _find_meshes(root)
	var face_skin := _make_skin(_profile["head_bc"], _profile["head_n"], _profile["head_srmf"], _profile.get("head_scatter", ""))
	var body_skin := _make_skin(_profile["body_bc"], _profile["body_n"], _profile["body_srmf"], _profile.get("body_scatter", ""))
	_skin_mats = [face_skin, body_skin]
	var eye_l := _make_eye("L"); var eye_r := _make_eye("R")
	_eye_mats = [eye_l, eye_r]
	var hide_mat := _make_hide()
	var teeth_mat := _make_teeth()
	for mi in meshes:
		# --- hair / groom cards ---
		var atlas_entry := _hair_atlas_for(mi.name)
		if not atlas_entry.is_empty():
			_wire_hair(mi, atlas_entry)
			continue
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		if mesh == null: continue
		# --- face ---
		if String(mi.name) == _profile.get("face_mesh_name", ""):
			if _profile.get("face_mode", "name") == "index":
				_wire_face_by_index(mi, face_skin, teeth_mat, eye_r, eye_l, hide_mat)
			else:
				_wire_face_by_name(mi, face_skin, eye_l, eye_r, hide_mat)
			continue
		# --- body ---
		if String(mi.name) == "Body" or String(mi.name).begins_with("Body"):
			for s in range(mesh.get_surface_count()):
				mi.set_surface_override_material(s, body_skin)
			continue
		# --- outfit -> light cloth ---
		if String(mi.name).begins_with("Outfit"):
			var cloth := StandardMaterial3D.new()
			cloth.albedo_color = Color(0.80, 0.81, 0.84)
			cloth.roughness = 0.85; cloth.metallic = 0.0
			for s in range(mesh.get_surface_count()):
				mi.set_surface_override_material(s, cloth)

func _wire_face_by_index(mi: MeshInstance3D, skin, teeth, eye_r, eye_l, hide) -> void:
	var imap: Dictionary = _profile["face_index_map"]
	var role_mat := {"skin": skin, "teeth": teeth, "eyeR": eye_r, "eyeL": eye_l, "hide": hide}
	for s in range(mi.mesh.get_surface_count()):
		var role: String = imap.get(s, "")
		if role_mat.has(role):
			mi.set_surface_override_material(s, role_mat[role])

func _wire_face_by_name(mi: MeshInstance3D, skin, eye_l, eye_r, hide) -> void:
	for s in range(mi.mesh.get_surface_count()):
		var m: Material = mi.mesh.surface_get_material(s)
		var nm := (m.resource_name if m else "").to_lower()
		if "eyel_baked" in nm: mi.set_surface_override_material(s, eye_l)
		elif "eyer_baked" in nm: mi.set_surface_override_material(s, eye_r)
		elif ("eyeshell" in nm or "eyelash" in nm or "lacrimal" in nm
				or nm.begins_with("m_hide") or "_hide" in nm):
			mi.set_surface_override_material(s, hide)
		elif "skin" in nm:
			mi.set_surface_override_material(s, skin)

func _hair_atlas_for(node_name: String) -> Array:
	for entry in _profile.get("hair_atlases", []):
		if String(node_name).begins_with(entry[0]):
			return entry
	return []

func _wire_hair(mi: MeshInstance3D, entry: Array) -> void:
	var tex := _rtex(entry[1])
	if tex == null: return
	var cm := ShaderMaterial.new()
	cm.shader = load("res://scenes/hair_card_shadow.gdshader") as Shader
	cm.set_shader_parameter("coverage_atlas", tex)
	cm.set_shader_parameter("use_red_mask", true)
	cm.set_shader_parameter("invert_mask", false)
	cm.set_shader_parameter("hair_color", entry[2])
	cm.set_meta("base_col", entry[2])
	_hair_mats.append(cm)
	for s in range(mi.mesh.get_surface_count()):
		mi.set_surface_override_material(s, cm)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_hair_meshes.append(mi)
	# backing shell (scalp fill) — scalp prefix only
	if String(mi.name).begins_with("Hair_"):
		var bsh: Shader = load("res://scenes/hair_backing.gdshader") as Shader
		if bsh:
			var bm := ShaderMaterial.new(); bm.shader = bsh
			bm.set_shader_parameter("coverage_atlas", tex)
			bm.set_shader_parameter("use_red_mask", true)
			bm.set_shader_parameter("hair_color", (entry[2] as Color).darkened(0.25))
			bm.set_meta("base_col", entry[2])
			_hair_back_mats.append(bm)
			var backing := MeshInstance3D.new()
			backing.name = mi.name + "_Backing"; backing.mesh = mi.mesh
			for s in range(mi.mesh.get_surface_count()):
				backing.set_surface_override_material(s, bm)
			backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			mi.add_sibling(backing)
			backing.global_transform = mi.global_transform

func _make_skin(bc: String, nn: String, srmf: String, scatter: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_explainer.gdshader") as Shader
	mat.set_shader_parameter("sss_depth_scale", p.sss_depth)
	var t_bc := _rtex(bc); var t_n := _rtex(nn); var t_sr := _rtex(srmf); var t_sc := _rtex(scatter)
	if t_bc: mat.set_shader_parameter("texture_albedo", t_bc)
	mat.set_shader_parameter("albedo", Color(1, 1, 1, 1))
	if t_n: mat.set_shader_parameter("texture_normal", t_n)
	if t_sr: mat.set_shader_parameter("texture_roughness", t_sr)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	mat.set_shader_parameter("old_lightwarp_fallof", false)
	mat.set_shader_parameter("skin_fallof_smoothness", 1.05)
	if t_sc:
		mat.set_shader_parameter("texture_scatter", t_sc)
		mat.set_shader_parameter("use_scatter_map", true)
	else:
		mat.set_shader_parameter("use_scatter_map", false)
	# Bind a WHITE AO texture: the shader multiplies SSS by ao.r unconditionally;
	# a black/cavity map there kills SSS and smears veins.
	mat.set_shader_parameter("ambient_occlusion_texture", _white_tex())
	mat.set_shader_parameter("use_ambient_occlusion", false)
	mat.set_shader_parameter("use_micro_detail", false)
	mat.set_shader_parameter("micro_normal_strength", 0.0)
	mat.set_shader_parameter("micro_ao_strength", 0.0)
	mat.set_shader_parameter("translucency", false)
	mat.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv1_offset", Vector3(0, 0, 0))
	mat.set_shader_parameter("uv2_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv2_offset", Vector3(0, 0, 0))
	return mat

func _make_eye(side: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/eye.gdshader") as Shader
	var ib := _rtex(_profile["iris_tpl"] % side)
	var inr := _rtex(_profile["iris_n_tpl"] % side)
	var sb := _rtex(_profile["sclera_tpl"] % side)
	var sn := _rtex(_profile["sclera_n_tpl"] % side)
	if ib: mat.set_shader_parameter("iris_texture", ib)
	if inr: mat.set_shader_parameter("iris_normal", inr)
	if sb: mat.set_shader_parameter("sclera_texture", sb)
	if sn: mat.set_shader_parameter("sclera_normal", sn)
	mat.set_shader_parameter("blend_softness", 0.02)
	mat.set_shader_parameter("normal_strength", 0.55)
	mat.set_shader_parameter("clearcoat_roughness_val", 0.15)
	return mat

func _make_hide() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0, 0, 0, 0)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

func _make_teeth() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var bc := _rtex(_profile.get("teeth_bc", ""))
	if bc: m.albedo_texture = bc
	m.albedo_color = Color(0.95, 0.93, 0.88)
	var nn := _rtex(_profile.get("teeth_n", ""))
	if nn: m.normal_enabled = true; m.normal_texture = nn
	m.roughness = 0.35; m.metallic = 0.0
	return m

# ---- custom GLB best-effort wiring ------------------------------------------
func _wire_custom(root: Node) -> void:
	# No known texture set; reuse the GLB's own baked textures. For skin-like
	# surfaces, lift the baked albedo/normal/rough into the MatMADNESS skin shader
	# so the skin sliders work. Eyes/hair get their shaders only if names match
	# AND we can find textures; otherwise leave the baked material (graceful).
	var wired_skin := 0; var wired_hair := 0; var wired_eye := 0
	for mi in _find_meshes(root):
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		if mesh == null: continue
		var lname := String(mi.name).to_lower()
		var is_hairish := "hair" in lname or "beard" in lname or "brow" in lname or "stache" in lname
		for s in range(mesh.get_surface_count()):
			var m: Material = mesh.surface_get_material(s)
			var nm := (m.resource_name if m else "").to_lower()
			if is_hairish:
				continue   # leave baked hair (no atlas to drive strands)
			if "eye" in nm and ("iris" in nm or "_l" in nm or "_r" in nm or "baked" in nm):
				wired_eye += 1
				continue   # leave baked eye (no iris/sclera atlas)
			if ("lash" in nm or "lacrimal" in nm or "eyeshell" in nm
					or nm.begins_with("m_hide") or "_hide" in nm):
				mi.set_surface_override_material(s, _make_hide())
				continue
			if "skin" in nm or "head" in nm or "face" in nm or "body" in nm:
				var sk := _make_skin_from_existing(m)
				if sk:
					mi.set_surface_override_material(s, sk)
					_skin_mats.append(sk); wired_skin += 1
	_set_status("Custom: skin=%d eye(baked)=%d hair(baked)=%s" % [wired_skin, wired_eye, "yes" if wired_hair == 0 else "no"])

func _make_skin_from_existing(src: Material) -> ShaderMaterial:
	if not (src is BaseMaterial3D): return null
	var b := src as BaseMaterial3D
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_explainer.gdshader") as Shader
	mat.set_shader_parameter("sss_depth_scale", p.sss_depth)
	if b.albedo_texture: mat.set_shader_parameter("texture_albedo", b.albedo_texture)
	mat.set_shader_parameter("albedo", Color(1, 1, 1, 1))
	if b.normal_enabled and b.normal_texture: mat.set_shader_parameter("texture_normal", b.normal_texture)
	# ROUGHNESS = texture_roughness.g * roughness uniform; an unbound sampler reads
	# ~0 (glassy skin). Bind white so the uniform/slider controls roughness instead.
	mat.set_shader_parameter("texture_roughness", _white_tex())
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	mat.set_shader_parameter("use_scatter_map", false)
	mat.set_shader_parameter("ambient_occlusion_texture", _white_tex())
	mat.set_shader_parameter("use_ambient_occlusion", false)
	mat.set_shader_parameter("use_micro_detail", false)
	mat.set_shader_parameter("translucency", false)
	mat.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv1_offset", Vector3(0, 0, 0))
	mat.set_shader_parameter("uv2_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv2_offset", Vector3(0, 0, 0))
	return mat

# ---- blendshapes ------------------------------------------------------------
func _collect_blendshapes(root: Node) -> void:
	_bs_map.clear()
	for mi in _find_meshes(root):
		if mi.mesh == null: continue
		var n: int = mi.mesh.get_blend_shape_count()
		for i in range(n):
			var sname: String = String(mi.mesh.get_blend_shape_name(i))
			if not _bs_map.has(sname): _bs_map[sname] = []
			_bs_map[sname].append([mi, i])
	print("[release] %s blendshapes: %d names across meshes" % [_char_key, _bs_map.size()])

func _set_blendshape(sname: String, v: float) -> void:
	_bs_values[sname] = v
	if not _bs_map.has(sname): return
	for pair in _bs_map[sname]:
		var mi: MeshInstance3D = pair[0]
		mi.set_blend_shape_value(pair[1], v)

func _world_aabb(node: Node) -> AABB:
	var aabb := AABB(); var first := true
	for mi in _find_meshes(node):
		var wa: AABB = mi.global_transform * mi.get_aabb()
		if first: aabb = wa; first = false
		else: aabb = aabb.merge(wa)
	return aabb

func _find_meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D: out.append(n)
	for c in n.get_children(): out.append_array(_find_meshes(c))
	return out

# ---- UI ---------------------------------------------------------------------
func _setup_ui() -> void:
	var layer := CanvasLayer.new(); add_child(layer)
	_overlay = TextureRect.new()
	_overlay.texture = _rtex("exp_ue_ref0.png", false)
	_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.modulate = Color(1, 1, 1, p.overlay)
	layer.add_child(_overlay)

	# file dialog (custom GLB)
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.glb,*.gltf ; glTF model"])
	_file_dialog.size = Vector2i(800, 560)
	_file_dialog.file_selected.connect(func(pth): _load_character(pth); _rebuild_bs_panel(); _refresh_controls(); _apply_all())
	layer.add_child(_file_dialog)

	# main look-dev panel
	_panel = PanelContainer.new()
	_panel.position = Vector2(10, 10)
	_panel.custom_minimum_size = Vector2(340, 0)
	layer.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 820)
	_panel.add_child(scroll)
	var vb := VBoxContainer.new(); vb.custom_minimum_size = Vector2(320, 0); scroll.add_child(vb)

	var title := Label.new()
	title.text = "MetaHuman → Godot — RELEASE look-dev\nC char · B shapes · H panel · O overlay · P save"
	vb.add_child(title)

	_char_btn = Button.new(); _char_btn.text = "Character: " + _profile["label"]
	_char_btn.pressed.connect(_switch_character); vb.add_child(_char_btn)
	var loadcustom := Button.new(); loadcustom.text = "Load custom character (GLB)…"
	loadcustom.pressed.connect(func(): _file_dialog.popup_centered()); vb.add_child(loadcustom)
	var bsbtn := Button.new(); bsbtn.text = "Toggle ARKit shapes panel [B]"
	bsbtn.pressed.connect(_toggle_bs_panel); vb.add_child(bsbtn)
	_status = Label.new(); _status.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	vb.add_child(_status)

	_section(vb, "SCENE")
	_slider(vb, "model_yaw", "Model yaw", 0.0, 360.0, 0.5)
	_slider(vb, "view_pan", "View pan (look-dev only)", -4.0, 4.0, 0.05)
	_slider(vb, "overlay", "UE overlay opacity", 0.0, 1.0, 0.01)
	_slider(vb, "zoff", "Depth nudge (m)", -0.5, 0.5, 0.005)

	_section(vb, "LIGHTING — energy")
	_slider(vb, "exposure", "Exposure", 0.2, 3.0, 0.01)
	_slider(vb, "glow", "Glow", 0.0, 2.0, 0.01)
	_slider(vb, "env_amb", "Env ambient", 0.0, 1.0, 0.01)
	_slider(vb, "key", "Key", 0.0, 40.0, 0.1)
	_slider(vb, "keyrect", "Key-rect", 0.0, 40.0, 0.1)
	_slider(vb, "fill", "Fill", 0.0, 30.0, 0.1)
	_slider(vb, "rim", "Rim", 0.0, 30.0, 0.1)
	_slider(vb, "ambient", "Ambient pt", 0.0, 10.0, 0.05)
	_slider(vb, "catch", "Catchlight", 0.0, 8.0, 0.05)

	_section(vb, "COLOUR BALANCE")
	_slider(vb, "saturation", "Saturation", 0.0, 2.0, 0.01)
	_slider(vb, "brightness", "Brightness", 0.3, 2.0, 0.01)
	_slider(vb, "contrast", "Contrast", 0.3, 2.0, 0.01)

	_section(vb, "LIGHTING — colour")
	_color(vb, "key_col", "Key colour")
	_color(vb, "keyrect_col", "Key-rect colour")
	_color(vb, "fill_col", "Fill colour")
	_color(vb, "rim_col", "Rim colour")
	_color(vb, "amb_col", "Ambient colour")
	_color(vb, "catch_col", "Catchlight colour")

	_section(vb, "SKIN (face + body)")
	_slider(vb, "sss", "Subsurface", 0.0, 1.0, 0.01)
	_slider(vb, "scatter", "Scatter strength", 0.0, 3.0, 0.01)
	_slider(vb, "skin_smooth", "Skin smoothness", 0.0, 4.0, 0.01)
	_slider(vb, "skin_nrm", "Normal strength", 0.0, 6.0, 0.05)
	_slider(vb, "skin_rough", "Roughness", 0.0, 1.0, 0.01)
	_slider(vb, "skin_spec", "Specular", 0.0, 1.0, 0.01)
	_slider(vb, "sss_depth", "SSS depth scale", 0.0, 16.0, 0.1)
	_slider(vb, "micro", "Micro detail", 0.0, 1.0, 0.01)
	_toggle(vb, "double_spec", "Double specular")

	_section(vb, "HAIR")
	_color(vb, "hair_col", "Hair colour")
	_slider(vb, "hair_thresh", "Alpha threshold", 0.0, 0.6, 0.005)
	_slider(vb, "hair_root", "Root darkening", 0.0, 1.0, 0.01)
	_slider(vb, "hair_rough", "Roughness", 0.0, 1.0, 0.01)
	_slider(vb, "hair_spec", "Specular", 0.0, 1.0, 0.01)
	_slider(vb, "hair_back_cut", "Backing cutoff", 0.0, 0.5, 0.005)
	_slider(vb, "hair_back_inset", "Backing inset (m)", 0.0, 0.05, 0.001)

	_section(vb, "EYES")
	_slider(vb, "sclera_tint", "Sclera tint", 0.0, 1.0, 0.01)
	_slider(vb, "iris_scale", "Iris scale", 0.5, 4.0, 0.01)
	_slider(vb, "iris_radius", "Iris radius", 0.05, 0.4, 0.005)
	_slider(vb, "eye_rough", "Roughness", 0.0, 0.5, 0.005)
	_slider(vb, "eye_spec", "Specular", 0.0, 1.0, 0.01)
	_slider(vb, "eye_clearcoat", "Clearcoat (eye glow)", 0.0, 1.0, 0.01)

	_section(vb, "PRESETS")
	var btn := Button.new(); btn.text = "Save (overwrite default)"
	btn.pressed.connect(_save_default_preset); vb.add_child(btn)
	var saverow := HBoxContainer.new()
	_preset_name = LineEdit.new(); _preset_name.placeholder_text = "preset name"
	_preset_name.custom_minimum_size = Vector2(180, 0); saverow.add_child(_preset_name)
	var saveas := Button.new(); saveas.text = "Save as"
	saveas.pressed.connect(_save_preset_as); saverow.add_child(saveas)
	vb.add_child(saverow)
	var loadrow := HBoxContainer.new()
	_preset_dd = OptionButton.new(); _preset_dd.custom_minimum_size = Vector2(200, 0)
	loadrow.add_child(_preset_dd)
	var loadbtn := Button.new(); loadbtn.text = "Load"
	loadbtn.pressed.connect(_load_selected_preset); loadrow.add_child(loadbtn)
	vb.add_child(loadrow)
	_refresh_preset_list()

	# capture buttons
	_section(vb, "CAPTURE")
	var shotbtn := Button.new(); shotbtn.text = "Screenshot"
	shotbtn.pressed.connect(_screenshot); vb.add_child(shotbtn)
	var moviebtn := Button.new(); moviebtn.text = "Capture turntable (120f mp4)"
	moviebtn.pressed.connect(func(): _start_movie()); vb.add_child(moviebtn)

	_build_bs_panel(layer)

func _section(parent: Control, txt: String) -> void:
	var l := Label.new(); l.text = "── " + txt + " ──"
	l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	parent.add_child(l)

func _slider(parent: Control, key: String, label: String, lo: float, hi: float, step: float) -> void:
	var row := VBoxContainer.new()
	var top := HBoxContainer.new()
	var lab := Label.new(); lab.text = label; lab.custom_minimum_size = Vector2(175, 0)
	top.add_child(lab)
	var spin := SpinBox.new()
	spin.min_value = lo; spin.max_value = hi; spin.step = step
	spin.allow_greater = true; spin.allow_lesser = true
	spin.custom_minimum_size = Vector2(120, 0); spin.value = float(p[key])
	top.add_child(spin); row.add_child(top)
	var sl := HSlider.new()
	sl.min_value = lo; sl.max_value = hi; sl.step = step
	sl.value = clampf(float(p[key]), lo, hi)
	sl.custom_minimum_size = Vector2(300, 16); row.add_child(sl); parent.add_child(row)
	sl.value_changed.connect(func(v): p[key] = v; spin.set_value_no_signal(v); _apply_all())
	spin.value_changed.connect(func(v): p[key] = v; sl.set_value_no_signal(clampf(v, lo, hi)); _apply_all())
	_refreshers.append(func(): spin.set_value_no_signal(float(p[key])); sl.set_value_no_signal(clampf(float(p[key]), lo, hi)))

func _color(parent: Control, key: String, label: String) -> void:
	var row := HBoxContainer.new()
	var lab := Label.new(); lab.text = label; lab.custom_minimum_size = Vector2(150, 0)
	row.add_child(lab)
	var cp := ColorPickerButton.new()
	cp.color = p[key]; cp.custom_minimum_size = Vector2(140, 24)
	cp.color_changed.connect(func(c): p[key] = c; _apply_all())
	row.add_child(cp); parent.add_child(row)
	_refreshers.append(func(): cp.color = p[key])

func _toggle(parent: Control, key: String, label: String) -> void:
	var cb := CheckBox.new(); cb.text = label; cb.button_pressed = bool(p[key])
	cb.toggled.connect(func(on): p[key] = on; _apply_all())
	parent.add_child(cb)
	_refreshers.append(func(): cb.set_pressed_no_signal(bool(p[key])))

func _refresh_controls() -> void:
	for r in _refreshers: r.call()

# ---- ARKit blendshape panel -------------------------------------------------
func _build_bs_panel(layer: CanvasLayer) -> void:
	_bs_panel = PanelContainer.new()
	_bs_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_bs_panel.position = Vector2(-370, 10)
	_bs_panel.custom_minimum_size = Vector2(360, 0)
	_bs_panel.visible = false
	layer.add_child(_bs_panel)
	_rebuild_bs_panel()

func _rebuild_bs_panel() -> void:
	if _bs_panel == null: return
	for c in _bs_panel.get_children(): c.queue_free()
	_bs_rows.clear()
	var scroll := ScrollContainer.new(); scroll.custom_minimum_size = Vector2(360, 880)
	_bs_panel.add_child(scroll)
	var vb := VBoxContainer.new(); vb.custom_minimum_size = Vector2(340, 0); scroll.add_child(vb)
	var present := 0
	for nm in ARKIT_NAMES:
		if _bs_map.has(nm): present += 1
	var hdr := Label.new()
	hdr.text = "ARKit blendshapes — %d / %d present on %s" % [present, ARKIT_NAMES.size(), _profile["label"]]
	hdr.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4)); vb.add_child(hdr)
	var allrow := HBoxContainer.new()
	var resetb := Button.new(); resetb.text = "All → 0"
	resetb.pressed.connect(_reset_all_shapes); allrow.add_child(resetb)
	vb.add_child(allrow)
	for nm in ARKIT_NAMES:
		_bs_slider(vb, nm)

func _bs_slider(parent: Control, sname: String) -> void:
	var has := _bs_map.has(sname)
	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = sname + ("" if has else "  (n/a)")
	lab.custom_minimum_size = Vector2(165, 0)
	if not has: lab.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	row.add_child(lab)
	var sl := HSlider.new()
	sl.min_value = 0.0; sl.max_value = 1.0; sl.step = 0.01
	sl.value = float(_bs_values.get(sname, 0.0))
	sl.custom_minimum_size = Vector2(150, 16); sl.editable = has
	row.add_child(sl)
	var spin := SpinBox.new()
	spin.min_value = 0.0; spin.max_value = 1.0; spin.step = 0.01
	spin.custom_minimum_size = Vector2(70, 0); spin.editable = has
	spin.value = float(_bs_values.get(sname, 0.0))
	row.add_child(spin)
	parent.add_child(row)
	if has:
		sl.value_changed.connect(func(v): _set_blendshape(sname, v); spin.set_value_no_signal(v))
		spin.value_changed.connect(func(v): _set_blendshape(sname, v); sl.set_value_no_signal(v))
	_bs_rows[sname] = {"slider": sl, "spin": spin}

func _reset_all_shapes() -> void:
	for nm in _bs_map.keys():
		_set_blendshape(nm, 0.0)
	for nm in _bs_rows.keys():
		_bs_rows[nm]["slider"].set_value_no_signal(0.0)
		_bs_rows[nm]["spin"].set_value_no_signal(0.0)

func _toggle_bs_panel() -> void:
	if _bs_panel: _bs_panel.visible = not _bs_panel.visible

# ---- apply ------------------------------------------------------------------
func _apply_all() -> void:
	if _env:
		_env.tonemap_exposure = p.exposure
		_env.ambient_light_energy = p.env_amb
		_env.glow_intensity = p.glow
		_env.adjustment_saturation = p.saturation
		_env.adjustment_brightness = p.brightness
		_env.adjustment_contrast = p.contrast
	var col_map := {"key": "key_col", "keyrect": "keyrect_col", "fill": "fill_col", "rim": "rim_col", "ambient": "amb_col"}
	for k in col_map.keys():
		if _lights.has(k):
			var L: Light3D = _lights[k]
			L.light_energy = p[k]; L.light_color = p[col_map[k]]
	if _catch:
		_catch.light_energy = p.catch; _catch.light_color = p.catch_col
		if _camera:
			_catch.global_transform.origin = _camera.global_transform.origin + _camera.global_transform.basis.y * 0.12
	for m in _skin_mats:
		m.set_shader_parameter("subsurface_scattering_strength", p.sss)
		m.set_shader_parameter("scatter_strength", p.scatter)
		m.set_shader_parameter("skin_smoothness", p.skin_smooth)
		m.set_shader_parameter("normal_strength", p.skin_nrm)
		m.set_shader_parameter("roughness", p.skin_rough)
		m.set_shader_parameter("specular", p.skin_spec)
		m.set_shader_parameter("double_specularity", p.double_spec)
		m.set_shader_parameter("sss_depth_scale", p.sss_depth)
		m.set_shader_parameter("use_micro_detail", p.micro > 0.001)
		m.set_shader_parameter("micro_normal_strength", p.micro)
	for m in _hair_mats:
		m.set_shader_parameter("hair_color", p.hair_col)
		m.set_shader_parameter("alpha_threshold", p.hair_thresh)
		m.set_shader_parameter("root_darkening", p.hair_root)
		m.set_shader_parameter("roughness_val", p.hair_rough)
		m.set_shader_parameter("specular_val", p.hair_spec)
	for m in _hair_back_mats:
		m.set_shader_parameter("hair_color", (p.hair_col as Color).darkened(0.25))
		m.set_shader_parameter("cutoff", p.hair_back_cut)
		m.set_shader_parameter("inset", p.hair_back_inset)
	for m in _eye_mats:
		m.set_shader_parameter("sclera_tint", p.sclera_tint)
		m.set_shader_parameter("iris_scale", p.iris_scale)
		m.set_shader_parameter("iris_radius", p.iris_radius)
		m.set_shader_parameter("roughness_val", p.eye_rough)
		m.set_shader_parameter("specular_val", p.eye_spec)
		m.set_shader_parameter("clearcoat_val", p.eye_clearcoat)
	if _character: _character.rotation.y = deg_to_rad(p.model_yaw)
	if _overlay: _overlay.modulate = Color(1, 1, 1, p.overlay)
	if _camera and not OS.has_environment("RELEASE_CAPTURE"): _camera.h_offset = p.view_pan

# ---- presets (per character) ------------------------------------------------
func _set_status(s: String) -> void:
	if _status: _status.text = s
	print("[release] ", s)

func _serialize() -> Dictionary:
	var out := {}
	for k in p.keys():
		if p[k] is Color:
			var c: Color = p[k]; out[k] = [c.r, c.g, c.b]
		else:
			out[k] = p[k]
	return out

func _write_json(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_serialize(), "  ")); f.close()
		_set_status("saved -> " + path.get_file())

func _preset_path(name_no_ext: String) -> String:
	return "%s/%s.json" % [ProjectSettings.globalize_path(PRESET_DIR), name_no_ext]

func _save_default_preset() -> void:
	_write_json(_preset_path(_profile.get("default_preset", _char_key + "__default")))

func _save_preset_as() -> void:
	var nm := "preset"
	if _preset_name and _preset_name.text.strip_edges() != "":
		nm = _preset_name.text.strip_edges().validate_filename()
	_write_json(_preset_path("%s__%s" % [_char_key, nm]))
	_refresh_preset_list()

func _load_preset_file(path: String) -> void:
	# accepts a res:// path or absolute; resolves res:// to disk for runtime read
	var disk := path
	if path.begins_with("res://"):
		disk = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(disk): return
	var txt := FileAccess.get_file_as_string(disk)
	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY: return
	for k in data.keys():
		if not p.has(k): continue
		if p[k] is Color and data[k] is Array and data[k].size() >= 3:
			p[k] = Color(data[k][0], data[k][1], data[k][2])
		else:
			p[k] = data[k]
	_set_status("loaded <- " + disk.get_file())

func _load_selected_preset() -> void:
	if _preset_dd == null or _preset_dd.item_count == 0: return
	var fn := _preset_dd.get_item_text(_preset_dd.selected)
	_load_preset_file(_preset_path(fn))
	_refresh_controls(); _apply_all()

func _refresh_preset_list() -> void:
	if _preset_dd == null: return
	_preset_dd.clear()
	var d := DirAccess.open(ProjectSettings.globalize_path(PRESET_DIR))
	if d == null: return
	# show only presets for the current character (prefix "<char>__")
	for f in d.get_files():
		if f.ends_with(".json") and f.begins_with(_char_key + "__"):
			_preset_dd.add_item(f.get_basename())

# ---- capture ----------------------------------------------------------------
func _screenshot() -> void:
	_capture_still()

func _capture_still() -> void:
	var pv := _panel.visible if _panel else false
	var bv := _bs_panel.visible if _bs_panel else false
	if _panel: _panel.visible = false
	if _bs_panel: _bs_panel.visible = false
	await get_tree().create_timer(0.05).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var img := get_viewport().get_texture().get_image()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	img.save_png("%s/release_%s_%s.png" % [OUT_DIR, _char_key, stamp])
	if _panel: _panel.visible = pv
	if _bs_panel: _bs_panel.visible = bv
	_set_status("screenshot saved")

func _start_movie() -> void:
	var mdir := "%s/frames_%s" % [OUT_DIR, _char_key]
	DirAccess.make_dir_recursive_absolute(mdir)
	_movie = true; _movie_frame = 0
	_spin_start = _character.rotation.y if _character else 0.0
	if _panel: _panel.visible = false
	if _bs_panel: _bs_panel.visible = false
	if _overlay: _overlay.modulate.a = 0.0
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.connect(_on_post_draw)
	_set_status("recording turntable…")

func _on_post_draw() -> void:
	if not _movie: return
	var mdir := "%s/frames_%s" % [OUT_DIR, _char_key]
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [mdir, _movie_frame])
	_movie_frame += 1
	if _movie_frame >= _movie_total:
		_finish_movie()
	elif _character:
		_character.rotation.y = _spin_start + deg_to_rad(360.0) * float(_movie_frame) / float(_movie_total)

func _finish_movie() -> void:
	_movie = false
	if RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	var mdir := "%s/frames_%s" % [OUT_DIR, _char_key]
	var out_mp4 := "%s/release_%s_turntable.mp4" % [OUT_DIR, _char_key]
	var py := "%s/_assemble.py" % mdir
	var pf := FileAccess.open(py, FileAccess.WRITE)
	pf.store_string(ASSEMBLE_PY); pf.close()
	var o := []
	OS.execute("python", [py, mdir, out_mp4], o, true)
	print("[release] movie -> ", out_mp4, " ", o)
	if OS.has_environment("RELEASE_CAPTURE"):
		get_tree().quit()

# ---- input ------------------------------------------------------------------
func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_C: _switch_character()
			KEY_B: _toggle_bs_panel()
			KEY_H:
				if _panel: _panel.visible = not _panel.visible
			KEY_O:
				p.overlay = 0.5 if p.overlay < 0.05 else 0.0; _apply_all()
			KEY_P: _save_default_preset()
