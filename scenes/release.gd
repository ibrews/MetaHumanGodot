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
		# Wire by SURFACE INDEX, not material name. The MetaHuman face material
		# names are misleading leftovers from the UE bake: surface 0 is named
		# "..Teeth_Baked.." but is actually the MAIN face skin geometry (24K verts),
		# while the tiny "..Skin_Baked.." surface 7 is a 276-vert cap. Her face has
		# the IDENTICAL 9-surface layout as the guy, so the guy's verified map
		# applies unchanged. (Name-based wiring left surface 0 on its baked teeth
		# material → the whole face rendered flat gray.)
		"face_mode": "index",
		"face_mesh_name": "Face",
		"face_index_map": {0: "skin", 1: "teeth", 2: "hide", 3: "eyeR", 4: "eyeL",
			5: "hide", 6: "hide", 7: "skin", 8: "hide"},
		"head_bc": "exp_head_bc.png", "head_n": "exp_head_n.png",
		"head_srmf": "exp_head_srmf.png", "head_scatter": "exp_head_scatter.png",
		"body_bc": "exp_body_bc.png", "body_n": "exp_body_n.png",
		"body_srmf": "exp_body_srmf.png", "body_scatter": "exp_body_scatter.png",
		"iris_tpl": "exp_eye_iris_%s_bc.png", "iris_n_tpl": "exp_eye_iris_%s_n.png",
		"sclera_tpl": "exp_eye_sclera_%s_bc.png", "sclera_n_tpl": "exp_eye_sclera_%s_n.png",
		"hair_atlases": [["Hair_", "exp_hair_atlas.png", Color(0.20, 0.13, 0.075)]],
		"outfit_color": Color(0.86, 0.87, 0.90),   # white tee (contrast vs the guy)
		"overlay_img": "her_ue_ref0.png",          # her UE moonlight cinecam render (2026-06-01)
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
		"outfit_color": Color(0.045, 0.05, 0.06),   # black tee (contrast vs her white)
		"overlay_img": "guy_ue_ref0.png",           # UE moonlight cinecam render (black shirt)
		"default_preset": "guy__moonlight",
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
	"bg_col": Color(0.050, 0.118, 0.280),   # backdrop tint (preset-driven for mood)
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
	# DOF (applied to _cam_attrs)
	"dof_focus": 1.3, "dof_blur": 0.0,
}

var _char_key := "guy"
var _profile := {}
var _character: Node3D
var _env: Environment
var _backdrop_mat: ShaderMaterial
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
var _overlay_available := false
var _panel: Control
var _panel_handle: Panel
var _panel_collapse_btn: Button
var _panel_width := 360.0
var _panel_prev_width := 360.0
var _panel_dragging := false
var _bs_panel: Control
var _bs_handle: Panel
var _bs_collapse_btn: Button
var _bs_width := 380.0
var _bs_prev_width := 380.0
var _bs_dragging := false
var _bs_rows := {}         # name -> {slider, spin, label}
var _camera: Camera3D
var _cam_attrs: CameraAttributesPractical
var _preset_name: LineEdit
var _preset_dd: OptionButton
var _char_btn: Button
var _status: Label
var _refreshers: Array = []
var _file_dialog: FileDialog

# ---- orbit camera rig -------------------------------------------------------
# Default interactive framing: a gentle 3/4 head-and-shoulders portrait. Target
# the face (y≈1.52, not the crown at 1.74) and pull back to 1.5 m so the subject
# fills the frame instead of sitting low with empty space above. Yaw -72° lines
# the orbit up with the front-3/4 of the model (which loads at model_yaw 272.5).
const DEFAULT_ORBIT_YAW   := -72.0
const DEFAULT_ORBIT_PITCH := 6.5
const DEFAULT_ORBIT_DIST  := 1.5
# Aim at the upper chest (≈1.33) rather than the face: this lifts the figure so
# the hair sits near the TOP of the frame (head-and-shoulders), per the request.
const DEFAULT_ORBIT_TARGET := Vector3(0.0, 1.33, 0.0)
var _orbit_yaw   := DEFAULT_ORBIT_YAW
var _orbit_pitch := DEFAULT_ORBIT_PITCH
var _orbit_dist  := DEFAULT_ORBIT_DIST
var _orbit_target := DEFAULT_ORBIT_TARGET
var _drag_mode   := 0     # 0=none 1=orbit 2=pan
var _orbit_fov   := 28.0
var _turntable   := false
const TURNTABLE_SPEED := 18.0   # deg/s

# ---- hero camera (ping-pong push-in) + animation (ported from look_dev.gd) --
var _hero_cam := false
var _hero_elapsed := 0.0
const HERO_DURATION := 15.0
const HERO_WIDE_POS := Vector3(0.0, 1.25, 4.3)     # full body
const HERO_CLOSE_POS := Vector3(0.08, 1.74, 0.50)  # tight face
const HERO_WIDE_FOV := 40.0
const HERO_CLOSE_FOV := 24.0
const HERO_WIDE_AIM := Vector3(0.0, 1.02, 0.0)
var _head_world := Vector3(0.0, 1.62, 0.05)

var _anim_playing := false
var _face_anim_player: AnimationPlayer
var _body_anim_player: AnimationPlayer
const ANIM_DURATION := 8.4
const KEYPOSES := {
	"neutral": {},
	"smile": {"mouthSmileLeft": 0.5, "mouthSmileRight": 0.5, "cheekSquintLeft": 0.18, "cheekSquintRight": 0.18},
	"surprise": {"jawOpen": 0.38, "browInnerUp": 0.65, "browOuterUpLeft": 0.5, "browOuterUpRight": 0.5, "eyeWideLeft": 0.55, "eyeWideRight": 0.55, "mouthFunnel": 0.18},
	"blink": {"eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0},
	"frown": {"mouthFrownLeft": 0.5, "mouthFrownRight": 0.5, "browDownLeft": 0.45, "browDownRight": 0.45, "mouthLowerDownLeft": 0.18, "mouthLowerDownRight": 0.18},
}
const KEY_TIMES := [
	[0.0, "neutral"], [0.7, "smile"], [1.9, "neutral"], [2.5, "surprise"],
	[3.5, "neutral"], [3.9, "blink"], [4.3, "frown"], [5.0, "neutral"], [5.7, "smile"], [8.2, "smile"],
]
# face-follow bind state (glue the separate face armature to the animated head bone)
var _body_skeleton: Skeleton3D
var _head_bone_idx := -1
var _face_armature: Node3D
var _face_arm_rest_origin := Vector3.ZERO
var _face_arm_rest_basis := Basis.IDENTITY
var _face_arm_rest_local := Transform3D.IDENTITY
var _skel_basis_norm := Basis.IDENTITY
var _skel_scale_factor := 1.0
var _skel_bind_origin := Vector3.ZERO
var _head_world_bind_origin := Vector3.ZERO
var _head_world_bind_basis := Basis.IDENTITY

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
	_char_key = OS.get_environment("RELEASE_CHAR") if OS.has_environment("RELEASE_CHAR") else "guy"
	if not PROFILES.has(_char_key):
		_char_key = "guy"
	_profile = PROFILES[_char_key]
	# start from the character's default preset, if shipped (RELEASE_PRESET overrides
	# the basename for QA, e.g. RELEASE_PRESET=her__sunset)
	var _start_preset: String = OS.get_environment("RELEASE_PRESET") if OS.has_environment("RELEASE_PRESET") else _profile.get("default_preset", "")
	_load_preset_file("%s/%s.json" % [PRESET_DIR, _start_preset])
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = max(2, int(OS.get_environment("MOVIE_FRAMES")))
	_setup_world(); _setup_backdrop(); _setup_lights(); _setup_camera()
	_load_character()
	_setup_ui()
	# Headless QA hook: RELEASE_BS="jawOpen=1.0,eyeBlinkLeft=1.0" drives shapes.
	# Applied BEFORE the toggle so RELEASE_BS + RELEASE_TOGGLE together prove that
	# an ARKit pose persists across a character swap (the toggled capture shows it).
	if OS.has_environment("RELEASE_BS"):
		for tok in OS.get_environment("RELEASE_BS").split(","):
			var kv := tok.split("=")
			if kv.size() == 2:
				_set_blendshape(kv[0].strip_edges(), float(kv[1]))
	# Headless QA hook: RELEASE_TOGGLE=1 exercises the live character switch.
	if OS.has_environment("RELEASE_TOGGLE"):
		_switch_character()
	# Headless QA hook: RELEASE_CUSTOM=<abs path> exercises the custom-GLB loader.
	if OS.has_environment("RELEASE_CUSTOM"):
		_load_character(OS.get_environment("RELEASE_CUSTOM"))
		_rebuild_bs_panel(); _refresh_controls()
	_apply_all()
	# Headless QA hooks for the toggles. RELEASE_ANIM_SEEK sets the face-anim time.
	if OS.has_environment("RELEASE_ANIM"):
		_set_anim_playing(true)
		if _face_anim_player and OS.has_environment("RELEASE_ANIM_SEEK"):
			_face_anim_player.seek(_envf("RELEASE_ANIM_SEEK", 0.0), true)
	if OS.has_environment("RELEASE_HERO"):
		_set_hero_cam(true)
		_hero_elapsed = _envf("RELEASE_HERO_T", 0.0)
		_update_hero_camera()
	# Headless: RELEASE_CAPTURE=1 -> still (+ RELEASE_MOVIE=1 -> 120f turntable).
	if OS.has_environment("RELEASE_CAPTURE"):
		if not OS.has_environment("SHOW_CHROME"):
			_hide_chrome()
		elif _bs_panel:    # SHOW_CHROME: also reveal the ARKit panel for QA
			_bs_panel.visible = true
			if _bs_handle: _bs_handle.visible = true
			if _bs_collapse_btn: _bs_collapse_btn.visible = true
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
	_env.background_color = p.get("bg_col", Color(0.050, 0.118, 0.280))
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
	# Large + further back so its edges never enter frame at any orbit angle.
	var quad := QuadMesh.new(); quad.size = Vector2(80, 50)
	var mi := MeshInstance3D.new(); mi.mesh = quad; mi.position = Vector3(0, 1.4, -6.0)
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
	_backdrop_mat = sm
	_apply_backdrop_color()

# Tint the backdrop gradient + environment bg from p.bg_col (drives mood variety).
func _apply_backdrop_color() -> void:
	var bg: Color = p.get("bg_col", Color(0.050, 0.118, 0.280))
	if _env: _env.background_color = bg
	if _backdrop_mat:
		_backdrop_mat.set_shader_parameter("top_col", bg.darkened(0.12))
		_backdrop_mat.set_shader_parameter("bot_col", bg.lightened(0.06))
		_backdrop_mat.set_shader_parameter("glow_col", bg.lightened(0.12))

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
	_camera.near = 0.05; _camera.far = 100.0
	_cam_attrs = CameraAttributesPractical.new()
	_cam_attrs.dof_blur_far_enabled = false
	_cam_attrs.dof_blur_near_enabled = false
	_camera.attributes = _cam_attrs
	_camera.current = true; add_child(_camera)
	# RELEASE_VIEW_ORBIT lets a headless capture frame from the live orbit camera
	# (so the interactive launch framing can be QA'd), instead of the fixed UE cam.
	if OS.has_environment("RELEASE_CAPTURE") and not OS.has_environment("RELEASE_VIEW_ORBIT"):
		# Headless capture: use the fixed UE-matched camera
		_camera.fov = _envf("RELEASE_FOV", 16.0)
		_camera.position = _ue_pos(160.0, -42.0, 158.0)
		var fwd := _ue_forward(-4.0, 165.0)
		_camera.look_at_from_position(_camera.position, _camera.position + fwd, Vector3.UP)
		_camera.h_offset = _envf("CAP_H", p.get("cap_pan", 0.0))
	else:
		# QA overrides for dialing in the default framing (no rebuild needed).
		_orbit_yaw   = _envf("ORB_YAW", _orbit_yaw)
		_orbit_pitch = _envf("ORB_PITCH", _orbit_pitch)
		_orbit_dist  = _envf("ORB_DIST", _orbit_dist)
		_orbit_fov   = _envf("ORB_FOV", _orbit_fov)
		_orbit_target.y = _envf("ORB_TY", _orbit_target.y)
		_camera.fov = _orbit_fov
		_update_orbit_camera()

func _update_orbit_camera() -> void:
	if _camera == null: return
	if OS.has_environment("RELEASE_CAPTURE") and not OS.has_environment("RELEASE_VIEW_ORBIT"): return
	var yaw_rad   := deg_to_rad(_orbit_yaw)
	var pitch_rad := deg_to_rad(_orbit_pitch)
	var offset := Vector3(
		sin(yaw_rad) * cos(pitch_rad),
		sin(pitch_rad),
		cos(yaw_rad) * cos(pitch_rad)
	) * _orbit_dist
	_camera.position = _orbit_target + offset
	_camera.look_at(_orbit_target, Vector3.UP)
	_camera.fov = _orbit_fov

func _process(delta: float) -> void:
	# Turntable spins the MODEL (composes with hero cam + orbit).
	if _turntable and _character and not OS.has_environment("RELEASE_CAPTURE"):
		_character.rotation.y += deg_to_rad(TURNTABLE_SPEED) * delta
		p["model_yaw"] = rad_to_deg(_character.rotation.y)

	# Camera: hero push-in (ping-pong) OR user-driven orbit.
	if _hero_cam and not OS.has_environment("RELEASE_CAPTURE"):
		_hero_elapsed += delta
		_update_hero_camera()
	else:
		_update_orbit_camera()

func _update_hero_camera() -> void:
	# Ping-pong dolly from a wide full-body shot to a tight face, ALONG the current
	# orbit azimuth so it always frames the front (independent of the model's yaw).
	if _camera == null: return
	var phase: float = fmod(_hero_elapsed, 2.0 * HERO_DURATION) / HERO_DURATION
	var pp: float = phase if phase <= 1.0 else (2.0 - phase)
	pp = smoothstep(0.0, 1.0, pp)
	var yaw_rad := deg_to_rad(_orbit_yaw)
	var dir := Vector3(sin(yaw_rad), 0.0, cos(yaw_rad))   # horizontal view direction
	var close_aim: Vector3 = _head_world if _anim_playing else Vector3(0.0, 1.62, 0.05)
	var aim: Vector3 = HERO_WIDE_AIM.lerp(close_aim + Vector3(0.0, 0.05, 0.0), pp)
	var dist: float = lerpf(4.3, 0.8, pp)
	var elev: float = lerpf(0.22, 0.08, pp)
	_camera.position = aim + dir * dist + Vector3(0.0, elev, 0.0)
	_camera.fov = lerpf(HERO_WIDE_FOV, HERO_CLOSE_FOV, pp)
	_camera.look_at(aim, Vector3.UP)

# ---- animation (face emote + body idle) -------------------------------------
func _set_hero_cam(on: bool) -> void:
	_hero_cam = on
	if on:
		_hero_elapsed = 0.0
		if _camera: _camera.h_offset = 0.0   # the hero move centers the subject itself
	else:
		if _camera: _camera.fov = _orbit_fov
		_update_orbit_camera()

func _set_anim_playing(on: bool) -> void:
	# Plays the FACE emote (blend-shape performance: smile→surprise→blink→frown) on
	# a static body. Body-idle + cross-armature head-follow is deliberately NOT used
	# here: it only exists on the guy and its bind math assumes an un-transformed
	# character node (true in look_dev, false here — we scale/rotate/place the node),
	# which detaches the head. The turntable provides body motion; this drives the face.
	_anim_playing = on
	if on:
		if _face_anim_player:
			_face_anim_player.play("emote")
	else:
		if _face_anim_player: _face_anim_player.stop()
		# restore the user's manual ARKit pose (the anim overwrote the shapes)
		_zero_all_blendshapes()
		_reapply_blendshapes()

func _zero_all_blendshapes() -> void:
	for sname in _bs_map.keys():
		for pair in _bs_map[sname]:
			pair[0].set_blend_shape_value(pair[1], 0.0)

func _find_body_anim_player(root: Node) -> void:
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer and (n as AnimationPlayer).get_animation_list().size() > 0:
			_body_anim_player = n
			# stop any auto-play so the bind pose is stable until the toggle
			(n as AnimationPlayer).stop()
			return
		for c in n.get_children(): stack.append(c)

func _has_ancestor_named(node: Node, target: String) -> bool:
	var par: Node = node.get_parent()
	while par != null:
		if String(par.name).begins_with(target): return true
		par = par.get_parent()
	return false

func _resolve_body_skeleton(root: Node) -> void:
	# The MetaHuman FACE skeleton also has spine_03/head bones; pick the real BODY
	# skeleton by non-FaceArmature ancestry, then fewest bones.
	var candidates: Array[Skeleton3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			var s: Skeleton3D = n
			if s.find_bone("spine_03") >= 0 and s.find_bone("head") >= 0:
				candidates.append(s)
		for c in n.get_children(): stack.append(c)
	if candidates.is_empty(): return
	var best: Skeleton3D = candidates[0]
	for s in candidates:
		var uf: bool = _has_ancestor_named(s, "FaceArmature")
		var bf: bool = _has_ancestor_named(best, "FaceArmature")
		if (bf and not uf) or (uf == bf and s.get_bone_count() < best.get_bone_count()):
			best = s
	_body_skeleton = best

func _bind_face_to_head_bone(root: Node) -> void:
	if _body_skeleton == null: return
	_head_bone_idx = _body_skeleton.find_bone("head")
	if _head_bone_idx < 0: return
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Node3D and String(n.name).begins_with("FaceArmature"):
			_face_armature = n
			break
		for c in n.get_children(): stack.append(c)
	if _face_armature == null: return
	var head_rest: Transform3D = _body_skeleton.get_bone_global_rest(_head_bone_idx)
	_face_arm_rest_origin = _face_armature.global_transform.origin
	_face_arm_rest_basis = _face_armature.global_transform.basis
	_face_arm_rest_local = _face_armature.transform
	var sb: Basis = _body_skeleton.global_transform.basis
	_skel_basis_norm = sb.orthonormalized()
	_skel_scale_factor = sb.x.length()
	_skel_bind_origin = _body_skeleton.global_transform.origin
	_head_world_bind_origin = _skel_bind_origin + _skel_basis_norm * (head_rest.origin * _skel_scale_factor)
	_head_world_bind_basis = (_skel_basis_norm * head_rest.basis).orthonormalized()

func _find_face_mesh(root: Node) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	var best: MeshInstance3D = null
	var best_count := 0
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var c: int = (n as MeshInstance3D).mesh.get_blend_shape_count()
			if c > best_count: best = n; best_count = c
		for child in n.get_children(): stack.append(child)
	return best

func _build_face_animation(root: Node) -> void:
	if _find_face_mesh(root) == null: return
	var driven: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh and (n as MeshInstance3D).mesh.get_blend_shape_count() > 0:
			driven.append(n)
		for c in n.get_children(): stack.append(c)
	var anim := Animation.new()
	anim.length = ANIM_DURATION
	anim.loop_mode = Animation.LOOP_LINEAR
	var touched := {}
	for entry in KEY_TIMES:
		for sh in KEYPOSES[entry[1]].keys(): touched[sh] = true
	for sh in touched.keys():
		for mim in driven:
			var mesh: ArrayMesh = mim.mesh as ArrayMesh
			if mesh == null: continue
			var found := false
			for si in range(mesh.get_blend_shape_count()):
				if mesh.get_blend_shape_name(si) == sh: found = true; break
			if not found: continue
			var t: int = anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t, NodePath("%s:blend_shapes/%s" % [mim.get_path(), sh]))
			anim.track_set_interpolation_type(t, Animation.INTERPOLATION_LINEAR)
			for entry in KEY_TIMES:
				anim.track_insert_key(t, entry[0], KEYPOSES[entry[1]].get(sh, 0.0))
	var lib := AnimationLibrary.new()
	lib.add_animation("emote", anim)
	_face_anim_player = AnimationPlayer.new()
	_face_anim_player.name = "FaceAnimRelease"
	add_child(_face_anim_player)
	_face_anim_player.add_animation_library("", lib)

# ---- textures ---------------------------------------------------------------
func _rtex(filename: String, mip := true) -> Texture2D:
	if filename == "" or filename == null: return null
	# Try the resource system first — works from a packed PCK build.
	var res_path := "res://" + filename
	if ResourceLoader.exists(res_path):
		var t := load(res_path) as Texture2D
		if t != null: return t
	# Fallback: raw filesystem load (custom GLB textures, dev builds, side-loaded files)
	var pa := ProjectSettings.globalize_path(res_path)
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
	# tear down per-character animation state
	if _face_anim_player and is_instance_valid(_face_anim_player):
		_face_anim_player.queue_free()
	_face_anim_player = null; _body_anim_player = null
	_body_skeleton = null; _face_armature = null; _head_bone_idx = -1
	_anim_playing = false

func _load_character(custom_path := "") -> void:
	_clear_character()
	var abs_path := custom_path
	if abs_path == "":
		abs_path = ProjectSettings.globalize_path(_profile["glb"])
	var node: Node3D = null
	# In a packed PCK build, GLBs are imported as .scn scenes — load via resource system.
	if custom_path == "":
		var res_path: String = _profile["glb"]
		if ResourceLoader.exists(res_path):
			var ps: PackedScene = load(res_path) as PackedScene
			if ps != null: node = ps.instantiate() as Node3D
	# Fallback: raw filesystem GLB load (dev builds, custom GLBs from file dialog)
	if node == null and FileAccess.file_exists(abs_path):
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
	# Face emote animation (blend-shape performance). Built but NOT played; the
	# "Play animation" toggle drives it.
	var aabb3 := _world_aabb(node)
	_head_world = Vector3(0.0, aabb3.position.y + aabb3.size.y - 0.12, 0.05)
	_build_face_animation(node)

func _switch_character() -> void:
	var i := CHAR_ORDER.find(_char_key)
	_char_key = CHAR_ORDER[(i + 1) % CHAR_ORDER.size()]
	_profile = PROFILES[_char_key]
	_load_preset_file("%s/%s.json" % [PRESET_DIR, _profile.get("default_preset", "")])
	_load_character()
	_reapply_blendshapes()   # carry the current ARKit pose across the character swap
	_apply_overlay_image()   # show THIS character's UE reference (or none)
	_rebuild_bs_panel()
	_refresh_preset_list()
	_refresh_controls()
	_apply_all()
	if _char_btn: _char_btn.text = "Character: " + _profile["label"]
	_set_status("Loaded " + _profile["label"])

# Re-drive every stored ARKit value onto the freshly-loaded character's meshes.
# _bs_values persists across _switch_character / _load_character (only _bs_map is
# rebuilt), so a jawOpen=0.6 set on "her" stays applied after toggling to "guy".
func _reapply_blendshapes() -> void:
	for sname in _bs_values.keys():
		if not _bs_map.has(sname): continue
		var v: float = _bs_values[sname]
		if v == 0.0: continue
		for pair in _bs_map[sname]:
			pair[0].set_blend_shape_value(pair[1], v)

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
			cloth.albedo_color = _profile.get("outfit_color", Color(0.80, 0.81, 0.84))
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
	# Generic name-based fallback for face meshes whose material names DO reflect
	# their geometry. NOTE: stock MetaHuman face meshes do NOT — their main skin
	# geometry sits on a surface mislabeled "..Teeth_Baked..", so prefer
	# face_mode "index" (see PROFILES) for any real MetaHuman export. Both shipped
	# characters use the index map; this path is kept for arbitrary custom faces.
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

# Set the UE-reference overlay to the CURRENT character's image (her has one,
# the guy doesn't). Prevents showing her reference over him after a toggle.
func _apply_overlay_image() -> void:
	if _overlay == null: return
	var img_name: String = _profile.get("overlay_img", "")
	_overlay_available = img_name != ""
	if _overlay_available:
		_overlay.texture = _rtex(img_name, false)
	else:
		_overlay.texture = null
		p.overlay = 0.0
	_overlay.modulate = Color(1, 1, 1, p.overlay)

# ---- UI ---------------------------------------------------------------------
func _setup_ui() -> void:
	var layer := CanvasLayer.new(); add_child(layer)
	_overlay = TextureRect.new()
	_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Keep the UE reference at its native aspect (no horizontal stretch).
	_overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.modulate = Color(1, 1, 1, p.overlay)
	layer.add_child(_overlay)
	_apply_overlay_image()

	# file dialog (custom GLB)
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.glb,*.gltf ; glTF model"])
	_file_dialog.size = Vector2i(800, 560)
	_file_dialog.file_selected.connect(func(pth): _load_character(pth); _rebuild_bs_panel(); _refresh_controls(); _apply_all())
	layer.add_child(_file_dialog)

	# main look-dev panel — full-height left column, drag-resizable + collapsible
	_panel = PanelContainer.new()
	_panel.anchor_top = 0.0; _panel.anchor_bottom = 1.0
	_panel.offset_left = 0.0; _panel.offset_top = 0.0
	_panel.offset_right = _panel_width; _panel.offset_bottom = 0.0
	layer.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	_build_left_handle(layer)

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

	_section(vb, "CAMERA  [R] = reset  LMB=orbit  RMB=pan  wheel=zoom")
	_orbit_slider(vb, "Orbit yaw",    func(v): _orbit_yaw = v,                           func(): return _orbit_yaw,   -180.0, 180.0, 0.5)
	_orbit_slider(vb, "Orbit pitch",  func(v): _orbit_pitch = clampf(v, -89.0, 89.0),    func(): return _orbit_pitch,  -89.0,  89.0, 0.5)
	_orbit_slider(vb, "Orbit dist",   func(v): _orbit_dist = v,                           func(): return _orbit_dist,    0.1,   6.0, 0.02)
	_orbit_slider(vb, "FOV",          func(v): _orbit_fov = v; if _camera: _camera.fov=v, func(): return _orbit_fov,    10.0,  90.0, 1.0)
	_slider(vb, "dof_focus", "DOF focus (m)", 0.1, 8.0, 0.05)
	_slider(vb, "dof_blur",  "DOF blur",      0.0, 0.5, 0.005)
	var tt_cb := CheckBox.new(); tt_cb.text = "Turntable (rotate character)"
	tt_cb.toggled.connect(func(on): _turntable = on)
	vb.add_child(tt_cb)
	var hero_cb := CheckBox.new(); hero_cb.text = "Hero camera (ping-pong push-in)"
	hero_cb.toggled.connect(func(on): _set_hero_cam(on))
	vb.add_child(hero_cb)
	var anim_cb := CheckBox.new(); anim_cb.text = "Play face animation (emote)"
	anim_cb.toggled.connect(func(on): _set_anim_playing(on))
	vb.add_child(anim_cb)

	_section(vb, "SCENE")
	_slider(vb, "model_yaw", "Model yaw", 0.0, 360.0, 0.5)
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
	_color(vb, "bg_col", "Background colour")

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

# Orbit-camera live slider (getter/setter callables, not keyed to p dict)
func _orbit_slider(parent: Control, label: String, setter: Callable, getter: Callable,
		lo: float, hi: float, step: float) -> void:
	var row := VBoxContainer.new()
	var top := HBoxContainer.new()
	var lab := Label.new(); lab.text = label; lab.custom_minimum_size = Vector2(175, 0)
	top.add_child(lab)
	var spin := SpinBox.new()
	spin.min_value = lo; spin.max_value = hi; spin.step = step
	spin.allow_greater = true; spin.allow_lesser = true
	spin.custom_minimum_size = Vector2(120, 0); spin.value = getter.call()
	top.add_child(spin); row.add_child(top)
	var sl := HSlider.new()
	sl.min_value = lo; sl.max_value = hi; sl.step = step
	sl.value = clampf(getter.call(), lo, hi)
	sl.custom_minimum_size = Vector2(300, 16); row.add_child(sl); parent.add_child(row)
	sl.value_changed.connect(func(v): setter.call(v); spin.set_value_no_signal(v))
	spin.value_changed.connect(func(v): setter.call(v); sl.set_value_no_signal(clampf(v, lo, hi)))
	_refreshers.append(func(): var v = getter.call(); spin.set_value_no_signal(v); sl.set_value_no_signal(clampf(v, lo, hi)))

# ---- ARKit blendshape panel -------------------------------------------------
func _build_bs_panel(layer: CanvasLayer) -> void:
	# Full-height RIGHT column, drag-resizable + collapsible (mirror of left panel).
	_bs_panel = PanelContainer.new()
	_bs_panel.anchor_left = 1.0; _bs_panel.anchor_right = 1.0
	_bs_panel.anchor_top = 0.0; _bs_panel.anchor_bottom = 1.0
	_bs_panel.offset_left = -_bs_width; _bs_panel.offset_right = 0.0
	_bs_panel.visible = false
	layer.add_child(_bs_panel)
	_build_bs_handle(layer)
	_rebuild_bs_panel()

func _rebuild_bs_panel() -> void:
	if _bs_panel == null: return
	for c in _bs_panel.get_children(): c.queue_free()
	_bs_rows.clear()
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bs_panel.add_child(scroll)
	var vb := VBoxContainer.new(); vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL; scroll.add_child(vb)
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
	if _bs_panel == null: return
	var vis := not _bs_panel.visible
	_bs_panel.visible = vis
	if _bs_handle: _bs_handle.visible = vis
	if _bs_collapse_btn: _bs_collapse_btn.visible = vis

# ---- resizable / collapsible panel chrome -----------------------------------
func _build_left_handle(layer: CanvasLayer) -> void:
	var h := Panel.new(); h.name = "LeftHandle"
	h.anchor_top = 0.0; h.anchor_bottom = 1.0
	h.offset_left = _panel_width; h.offset_right = _panel_width + 12.0
	h.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.20, 0.22, 0.28, 0.9)
	h.add_theme_stylebox_override("panel", sb)
	var grip := Label.new(); grip.text = "⋮"; grip.set_anchors_preset(Control.PRESET_CENTER)
	grip.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8)); h.add_child(grip)
	h.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_panel_dragging = (ev as InputEventMouseButton).pressed)
	layer.add_child(h); _panel_handle = h
	var cb := Button.new(); cb.name = "LeftCollapse"; cb.text = "‹‹"
	cb.tooltip_text = "Collapse / expand the settings panel"
	cb.offset_left = _panel_width + 16.0; cb.offset_top = 12.0
	cb.offset_right = _panel_width + 50.0; cb.offset_bottom = 40.0
	cb.pressed.connect(_toggle_left_collapse)
	layer.add_child(cb); _panel_collapse_btn = cb

func _set_left_width(w: float) -> void:
	_panel_width = clampf(w, 0.0, 760.0)
	if _panel: _panel.offset_right = _panel_width
	if _panel_handle:
		_panel_handle.offset_left = _panel_width; _panel_handle.offset_right = _panel_width + 12.0
	if _panel_collapse_btn:
		_panel_collapse_btn.offset_left = _panel_width + 16.0; _panel_collapse_btn.offset_right = _panel_width + 50.0

func _toggle_left_collapse() -> void:
	if _panel_width > 40.0:
		_panel_prev_width = _panel_width; _set_left_width(0.0)
		if _panel_collapse_btn: _panel_collapse_btn.text = "››"
	else:
		_set_left_width(_panel_prev_width if _panel_prev_width > 40.0 else 360.0)
		if _panel_collapse_btn: _panel_collapse_btn.text = "‹‹"

func _build_bs_handle(layer: CanvasLayer) -> void:
	var h := Panel.new(); h.name = "BsHandle"
	h.anchor_left = 1.0; h.anchor_right = 1.0; h.anchor_top = 0.0; h.anchor_bottom = 1.0
	h.offset_left = -_bs_width - 12.0; h.offset_right = -_bs_width
	h.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.20, 0.22, 0.28, 0.9)
	h.add_theme_stylebox_override("panel", sb)
	var grip := Label.new(); grip.text = "⋮"; grip.set_anchors_preset(Control.PRESET_CENTER)
	grip.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8)); h.add_child(grip)
	h.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_bs_dragging = (ev as InputEventMouseButton).pressed)
	h.visible = false
	layer.add_child(h); _bs_handle = h
	var cb := Button.new(); cb.name = "BsCollapse"; cb.text = "››"
	cb.tooltip_text = "Collapse / expand the ARKit panel"
	cb.anchor_left = 1.0; cb.anchor_right = 1.0
	cb.offset_left = -_bs_width - 50.0; cb.offset_top = 12.0
	cb.offset_right = -_bs_width - 16.0; cb.offset_bottom = 40.0
	cb.pressed.connect(_toggle_bs_collapse)
	cb.visible = false
	layer.add_child(cb); _bs_collapse_btn = cb

func _set_bs_width(w: float) -> void:
	_bs_width = clampf(w, 0.0, 760.0)
	if _bs_panel: _bs_panel.offset_left = -_bs_width
	if _bs_handle:
		_bs_handle.offset_left = -_bs_width - 12.0; _bs_handle.offset_right = -_bs_width
	if _bs_collapse_btn:
		_bs_collapse_btn.offset_left = -_bs_width - 50.0; _bs_collapse_btn.offset_right = -_bs_width - 16.0

func _toggle_bs_collapse() -> void:
	if _bs_width > 40.0:
		_bs_prev_width = _bs_width; _set_bs_width(0.0)
		if _bs_collapse_btn: _bs_collapse_btn.text = "‹‹"
	else:
		_set_bs_width(_bs_prev_width if _bs_prev_width > 40.0 else 380.0)
		if _bs_collapse_btn: _bs_collapse_btn.text = "››"

# Hide all UI chrome (panels, handles, buttons, overlay) for clean captures.
func _hide_chrome() -> void:
	for n in [_panel, _panel_handle, _panel_collapse_btn, _bs_panel, _bs_handle, _bs_collapse_btn]:
		if n: (n as CanvasItem).visible = false
	if _overlay: _overlay.modulate.a = 0.0

# ---- apply ------------------------------------------------------------------
func _apply_all() -> void:
	if _env:
		_env.tonemap_exposure = p.exposure
		_env.ambient_light_energy = p.env_amb
		_env.glow_intensity = p.glow
		_env.adjustment_saturation = p.saturation
		_env.adjustment_brightness = p.brightness
		_env.adjustment_contrast = p.contrast
	_apply_backdrop_color()
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
	if _cam_attrs and not OS.has_environment("RELEASE_CAPTURE"):
		var blur: float = float(p.get("dof_blur", 0.0))
		var enabled: bool = blur > 0.001
		_cam_attrs.dof_blur_near_enabled = enabled
		_cam_attrs.dof_blur_far_enabled  = enabled
		if enabled:
			var focus: float = float(p.get("dof_focus", 1.3))
			_cam_attrs.dof_blur_near_distance   = focus * 0.6
			_cam_attrs.dof_blur_near_transition  = focus * 0.4
			_cam_attrs.dof_blur_far_distance    = focus * 1.3
			_cam_attrs.dof_blur_far_transition  = focus * 0.8
			_cam_attrs.dof_blur_amount          = blur

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
	# Accepts a res:// path (shipped presets — read straight from the PCK / editor
	# VFS via FileAccess) or an absolute disk path (user-saved presets). Only fall
	# back to a globalized on-disk copy if the res:// resource is missing — e.g. a
	# side-loaded override dropped next to the exe. (The previous version ALWAYS
	# globalized res://, which resolves to a non-existent <exe_dir>/presets/* in a
	# clean PCK build, so the shipped studio look silently never loaded.)
	var rp := path
	if not FileAccess.file_exists(rp):
		if path.begins_with("res://"):
			rp = ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(rp):
			return
	var txt := FileAccess.get_file_as_string(rp)
	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY: return
	for k in data.keys():
		if not p.has(k): continue
		if p[k] is Color and data[k] is Array and data[k].size() >= 3:
			p[k] = Color(data[k][0], data[k][1], data[k][2])
		else:
			p[k] = data[k]
	_set_status("loaded <- " + rp.get_file())

func _load_selected_preset() -> void:
	if _preset_dd == null or _preset_dd.item_count == 0: return
	var fn := _preset_dd.get_item_text(_preset_dd.selected)
	_load_preset_file(_preset_path(fn))
	_refresh_controls(); _apply_all()

func _refresh_preset_list() -> void:
	if _preset_dd == null: return
	_preset_dd.clear()
	# List from res:// first (works in the editor AND a packed exe); fall back to a
	# globalized on-disk presets dir (side-loaded user presets next to the exe).
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		d = DirAccess.open(ProjectSettings.globalize_path(PRESET_DIR))
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
	var ov: float = p.overlay
	_hide_chrome()
	await get_tree().create_timer(0.05).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var img := get_viewport().get_texture().get_image()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	img.save_png("%s/release_%s_%s.png" % [OUT_DIR, _char_key, stamp])
	# restore chrome
	if _panel: _panel.visible = pv
	if _panel_handle: _panel_handle.visible = true
	if _panel_collapse_btn: _panel_collapse_btn.visible = true
	if _bs_panel: _bs_panel.visible = bv
	if _bs_handle: _bs_handle.visible = bv
	if _bs_collapse_btn: _bs_collapse_btn.visible = bv
	p.overlay = ov
	if _overlay: _overlay.modulate.a = ov
	_set_status("screenshot saved")

func _start_movie() -> void:
	var mdir := "%s/frames_%s" % [OUT_DIR, _char_key]
	DirAccess.make_dir_recursive_absolute(mdir)
	_movie = true; _movie_frame = 0
	_spin_start = _character.rotation.y if _character else 0.0
	_hide_chrome()
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
	# Panel-resize drags use ABSOLUTE mouse X and capture the event so dragging the
	# handle keeps resizing even when the cursor passes over the panel's own controls.
	if _panel_dragging or _bs_dragging:
		if e is InputEventMouseMotion:
			var mx: float = (e as InputEventMouseMotion).position.x
			if _panel_dragging: _set_left_width(mx + 6.0)
			if _bs_dragging:
				var sw: float = get_viewport().get_visible_rect().size.x
				_set_bs_width(sw - mx + 6.0)
			get_viewport().set_input_as_handled()
		elif e is InputEventMouseButton and not (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_panel_dragging = false; _bs_dragging = false
		return
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_C: _switch_character()
			KEY_B: _toggle_bs_panel()
			KEY_H: _toggle_left_collapse()
			KEY_O:
				if _overlay_available:
					p.overlay = 0.5 if p.overlay < 0.05 else 0.0; _apply_all()
			KEY_P: _save_default_preset()
			KEY_R: _reset_orbit()
# Camera orbit/pan/zoom lives in _unhandled_input so it ONLY fires for events the
# UI didn't already consume. Dragging a slider / button / panel is eaten by that
# Control first, so it no longer also spins the character — rotation happens only
# when you drag on the empty viewport. (Panel-resize uses _input + set_input_as_handled.)
func _unhandled_input(e: InputEvent) -> void:
	if OS.has_environment("RELEASE_CAPTURE"): return
	if _hero_cam: return   # hero move owns the camera; ignore drags while it plays
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_drag_mode = 1 if mb.pressed else 0
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag_mode = 2 if mb.pressed else 0
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_dist = maxf(0.1, _orbit_dist - 0.08)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_dist = minf(10.0, _orbit_dist + 0.08)
	elif e is InputEventMouseMotion and _drag_mode > 0:
		var rel := (e as InputEventMouseMotion).relative
		if _drag_mode == 1:  # orbit
			_orbit_yaw -= rel.x * 0.35
			_orbit_pitch = clampf(_orbit_pitch + rel.y * 0.25, -89.0, 89.0)
		elif _drag_mode == 2:  # pan
			var right := _camera.global_transform.basis.x
			var up    := _camera.global_transform.basis.y
			_orbit_target -= right * rel.x * _orbit_dist * 0.002
			_orbit_target += up    * rel.y * _orbit_dist * 0.002

func _reset_orbit() -> void:
	_orbit_yaw = DEFAULT_ORBIT_YAW; _orbit_pitch = DEFAULT_ORBIT_PITCH
	_orbit_dist = DEFAULT_ORBIT_DIST; _orbit_target = DEFAULT_ORBIT_TARGET
	_orbit_fov = 28.0; if _camera: _camera.fov = _orbit_fov
