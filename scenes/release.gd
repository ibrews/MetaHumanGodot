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
		"label": "Gal — MH_Gal",
		"glb": "res://character_explainer.glb",
		# Wire by SURFACE INDEX, not material name (the MetaHuman bake material names
		# are misleading: surface 0 is "..Teeth_Baked.." but is the MAIN face skin,
		# 24K verts). The eye wiring below is the EMPIRICALLY-GOOD config: the visible
		# eye reads off the corneal EyeShell (surf 4, given the eyeL iris) over the
		# eyeball (surf 3 = eyeR); surf 2 (a partial eyeball) stays HIDDEN. (A probe-
		# driven "correction" to 2:eyeL / 4:hide was WRONG — hiding the shell exposed
		# the lids and read as a closed eye. Don't re-map the eyes without a render.)
		#   0 MI_Teeth_Baked = face skin (24414 v)   7 Face_Skin cap (276 v)
		#   1 M_Hide_0       = mouth: teeth+tongue+gums (4613 v)
		#   3 eyeR + 4 EyeShell(eyeL) = the two visible eyes · 2,5,6 hidden
		#   8 MI_Face_EyelashesHiLODs = eyelashes (shown via the lash atlas)
		"face_mode": "index",
		"face_mesh_name": "Face",
		"face_index_map": {0: "skin", 1: "teeth", 2: "hide", 3: "eyeR", 4: "eyeL",
			5: "hide", 6: "hide", 7: "skin", 8: "lashes"},
		# head_bc is the brow-painted variant — her MetaHuman ships NO eyebrow groom and
		# none are baked into the skin, so brows are hand-painted onto a copy of the baked
		# head albedo (blender_work/paint_her_brows.py). Revert to "exp_head_bc.png" to disable.
		"head_bc": "exp_head_bc_brows.png", "head_n": "exp_head_n.png",
		"head_srmf": "exp_head_srmf.png", "head_scatter": "exp_head_scatter.png",
		# Mouth: her bake shipped no usable teeth albedo, so the mouth (surf 1) fell back
		# to flat off-white → "white tongue / chalky teeth". The MetaHuman teeth UVs are
		# shared, so the guy's real baked teeth map straight on (pink tongue + enamel).
		"teeth_bc": "character_T_Teeth_BC.png", "teeth_n": "character_T_Teeth_N.png",
		# Eyelashes: surf 8 (HiLOD lash mesh) drawn with the MH lash coverage atlas through
		# the alpha-clipped hair shader (was hidden, like the guy's flat-strip lashes).
		# The lash coverage mask is in the RGB channels (alpha is all-255) — use_red_mask
		# MUST be true or the lash card renders as a solid sheet that covers the eye.
		"lash_atlas": "T_Eyelashes_S_Sparse_Coverage.png",
		"lash_color": Color(0.028, 0.022, 0.018), "lash_mask_red": true,
		"body_bc": "exp_body_bc.png", "body_n": "exp_body_n.png",
		"body_srmf": "exp_body_srmf.png", "body_scatter": "exp_body_scatter.png",
		"iris_tpl": "exp_eye_iris_%s_bc.png", "iris_n_tpl": "exp_eye_iris_%s_n.png",
		"sclera_tpl": "exp_eye_sclera_%s_bc.png", "sclera_n_tpl": "exp_eye_sclera_%s_n.png",
		"hair_atlases": [["Hair_", "exp_hair_atlas.png", Color(0.20, 0.13, 0.075)]],
		"outfit_color": Color(0.86, 0.87, 0.90),   # white tee (contrast vs the guy)
		# Per-character anti-poke inflate (mesh-local units): her bust/shoulder seams need a
		# much bigger shell than the guy's to stop skin poking through (see _load_preset_file).
		"outfit_grow": 0.5,
		"overlay_img": "her_ue_ref0.png",          # her UE moonlight cinecam render (2026-06-01)
		"default_preset": "her__moonlight",
	},
	"guy": {
		"label": "Guy — MH_Guy",
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
		"outfit_grow": 0.1,                          # per-character anti-poke inflate (see _load_preset_file)
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
	"skin_tint": Color(1, 1, 1),   # multiplies the albedo — recolour skin (hue)
	"skin_bright": 1.0,            # albedo brightness multiplier (>1 lightens past current)
	"shadow_strength": 0.7,        # how dark cast shadows (e.g. hair on face) get; higher = stronger
	"outfit_grow": 0.006,          # inflate the shirt along normals (m) so skin can't poke through
	"body_shrink": 0.0,            # tuck the BODY skin inward (m). NOTE: the collar poke is the FACE bust-cap, not body, so this knob doesn't fix it — kept as a general tuck control
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
	"view_pan": -0.22,   # interactive camera h_offset: slides subject RIGHT of the left panel
	"cap_pan": -0.176,   # capture-time centering
	# DOF (applied to _cam_attrs)
	"dof_focus": 1.3, "dof_blur": 0.0,
	# eye gaze — single focal point in the eye-midpoint frame (meters):
	# (0,0,0) = cross-eyed at the point between the eyes; +z = ahead, +x = subject-right, +y = up.
	"eye_fx": 0.0, "eye_fy": 0.0, "eye_fz": 0.8, "eye_focus_abs": false,
	# "alive eyes": naturalistic saccades + blinks around the gaze target (demo).
	"eye_alive": true,
	# "look at camera": gaze target = camera; also live-populates the focal fields above
	# with the camera position so unchecking lets you take over from there.
	"eye_look_cam": true,
	# DEBUG: UE overlay align-aids (remove later) — horizontal stretch + sideways scoot (px)
	"overlay_stretch_x": 1.0, "overlay_off_x": 0.0,
}

var _char_key := "guy"
var _profile := {}
var _character: Node3D
var _env: Environment
var _backdrop_mat: ShaderMaterial
var _lights := {}
var _catch: OmniLight3D
var _rake: SpotLight3D                        # opt-in hard "hair rake" — skims the hairline so hair throws a crisp forehead shadow (off by default; doesn't disturb the moonlight rig)
var _rake_on := false
var _skin_mats: Array[ShaderMaterial] = []
var _hair_mats: Array[ShaderMaterial] = []
var _hair_back_mats: Array[ShaderMaterial] = []
var _eye_mats: Array[ShaderMaterial] = []
var _lash_mats: Array = []                  # eyelash card materials (alpha-clipped)
var _hair_meshes: Array[MeshInstance3D] = []
var _hair_back_meshes: Array = []            # backing-shell instances (toggled with the hair)
var _hair_visible := true                    # "Show hair" toggle — all groom cards + backings

# Static-character idle (HER explainer GLB has no skeleton/anim) — a gentle rigid
# sway/breath/weight-shift driven on the whole character node.
var _static_idle_on := false
var _static_idle_clock := 0.0
var _char_rest_pos := Vector3.ZERO

# Live light-colour cycling (the "Cycle light colours" animation toggle).
var _color_cycle := false
var _color_cycle_clock := 0.0

# Per-character LOOK memory: char_key -> captured {p copy + orbit camera}. Lighting/skin/
# camera start at the character's default preset the FIRST time it's shown, but any
# adjustments are remembered when you toggle away and restored when you toggle back.
# (The animation TOGGLES below are a separate layer that persists globally across switches.)
var _char_look := {}

# Faked iris gaze for boneless eyes (HER): the eye shader's iris_offset is driven
# instead of rotating FACIAL_*_Eye bones (which her static face mesh doesn't have).
var _iris_off := Vector2.ZERO

var _bs_map := {}          # shape name -> Array of [MeshInstance3D, idx]
var _bs_values := {}       # shape name -> float (current)

var _overlay: TextureRect
var _overlay_available := false
var _intro_tween: Tween                      # one-shot "reference → live character" reveal fade
var _intro_active := false                    # true WHILE the reveal fades — eyes held straight ahead
const INTRO_FADE_SEC := 3.0                    # reveal fade length; "alive eyes" resume after this
var _panel: Control
var _panel_handle: Panel
var _panel_collapse_btn: Button
var _panel_width := 470.0
var _panel_prev_width := 470.0
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

var _face_anim_on := false       # face emote toggle (independent)
var _body_anim_on := false       # body idle toggle (independent)
var _follow_active := false      # face-follow runs while the body idle plays
var _face_anim_player: AnimationPlayer
var _body_anim_player: AnimationPlayer
var _body_anim_name := ""          # selected body clip (Mixamo retargets: Idle/Sway/Walk/Turn/Wave/HappyIdle + BodyIdle_Procedural)
var _body_anim_dd: OptionButton    # the body-animation dropdown
# Preferred default + a clean display order for the dropdown (only the present ones are shown).
const BODY_ANIM_ORDER := ["Idle", "Sway", "Walk", "Turn", "Wave", "HappyIdle", "BodyIdle_Procedural"]
# leg idle (subtle weight-shift) + starting camera (for Reset) + outfit grow-shell
var _pelvis_idx := -1
var _calf_l_idx := -1
var _calf_r_idx := -1
var _leg_clock := 0.0
var _start_orbit_yaw := -72.0
var _start_orbit_pitch := 6.5
var _start_orbit_dist := 1.5
var _start_orbit_fov := 28.0
var _start_orbit_target := Vector3(0.0, 1.33, 0.0)
var _outfit_mats: Array = []
var _outfit_meshes: Array[MeshInstance3D] = []   # outfit mesh instances (for the clothes-off seam diagnostic)
var _body_skin_mat: ShaderMaterial   # the BODY skin material (for the anti-poke vertex shrink)
var _face_off := Transform3D.IDENTITY   # legacy (rigid follow); unused by the LeaderPose path
# LeaderPose emulation (collar-seam fix). The face mesh (head + neck + bust-cap) is skinned
# by the FACE skeleton; the body idle animates the SEPARATE body skeleton. Instead of rigidly
# moving the whole face armature by the head bone (which rode the bust-cap UP through the
# shirt collar), we drive every bone the two rigs SHARE by name so the face's neck/clavicle/
# bust deforms WITH the body (seam stays glued) while the head still bobs with the head bone.
# The two rigs' rest bone-frames DIFFER (separate FBX exports oriented bones up to 180° apart —
# see feedback-cross-fbx-bone-orientation), so we transfer motion through GLOBAL poses, NOT a
# local-pose copy:  desired face global  PFg = PBg · RBg⁻¹ · RFg  (rest_xfer = RBg⁻¹·RFg, const).
var _face_skel: Skeleton3D                 # the face mesh's skeleton (the one with FACIAL_L_Eye)
var _leader_pairs: Array = []              # [body_idx, face_idx, face_parent_idx, rest_xfer], parent-first

# ---- eye gaze (item 3, redesigned): both eyes LOOK-AT a single focal point. The 8
# ARKit eyeLook* shapes were stripped (horror-eye fix), so we aim the
# FACIAL_L_Eye/FACIAL_R_Eye bones via a minimal-rotation look-at. The focal point is
# given in an eye-midpoint frame (see p.eye_fx/fy/fz): (0,0,0) = the point between the
# eyes (cross-eyed); +z ahead. Relative mode tracks the head; absolute freezes a world point.
# The 8 ARKit eyeLook* names — still recognised so they never appear as dead sliders.
const EYE_LOOK_NAMES := ["eyeLookUpLeft","eyeLookDownLeft","eyeLookInLeft","eyeLookOutLeft",
	"eyeLookUpRight","eyeLookDownRight","eyeLookInRight","eyeLookOutRight"]
var _face_eye_skel: Skeleton3D
var _eye_bone_l := -1
var _eye_bone_r := -1
var _eye_fwd_axis := Vector3(0, 0, 1)   # bone-local "look" axis (sign calibrated via capture)
var _eye_abs_point := Vector3.ZERO      # frozen world focal point used in absolute mode
var _focus_ctrls := {}                   # key -> {spin, sl} for live focal-slider updates
# "alive eyes" — gaze the camera with saccadic darts + natural blinks (demo)
var _rng := RandomNumberGenerator.new()
var _alive_clock := 0.0
var _sacc_off := Vector2.ZERO           # current dart offset (camera screen-plane, metres)
var _sacc_tgt := Vector2.ZERO
var _sacc_next := 0.0
var _blink_t := -1.0                     # >=0 while a blink is in progress
var _blink_next := 1.5
const ANIM_DURATION := 8.4
const KEYPOSES := {
	"neutral": {},
	"smile": {"mouthSmileLeft": 0.5, "mouthSmileRight": 0.5, "cheekSquintLeft": 0.18, "cheekSquintRight": 0.18},
	"surprise": {"jawOpen": 0.38, "browInnerUp": 0.65, "browOuterUpLeft": 0.5, "browOuterUpRight": 0.5, "eyeWideLeft": 0.55, "eyeWideRight": 0.55, "mouthFunnel": 0.18},
	"frown": {"mouthFrownLeft": 0.5, "mouthFrownRight": 0.5, "browDownLeft": 0.45, "browDownRight": 0.45, "mouthLowerDownLeft": 0.18, "mouthLowerDownRight": 0.18},
	# Nose scrunch — contorts the skin around the nose/cheeks (noseSneer + cheekSquint +
	# a touch of upper-lip raise + inner-brow). Both characters carry these shapes; the
	# anim builder skips any a character lacks, so it degrades gracefully.
	"noseScrunch": {"noseSneerLeft": 0.85, "noseSneerRight": 0.85, "cheekSquintLeft": 0.45, "cheekSquintRight": 0.45, "mouthUpperUpLeft": 0.3, "mouthUpperUpRight": 0.3, "browInnerUp": 0.2},
}
# NOTE: no "blink" keypose — blinking is owned by "alive eyes" (naturalistic + random),
# so the emote anim must NOT drive eyeBlink or its per-frame track would cancel them.
const KEY_TIMES := [
	[0.0, "neutral"], [0.7, "smile"], [1.9, "neutral"], [2.5, "surprise"],
	[3.5, "neutral"], [4.3, "frown"], [5.0, "neutral"], [5.5, "noseScrunch"],
	[6.2, "neutral"], [6.7, "smile"], [8.2, "smile"],
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
	# Interactive launch starts in borderless windowed-fullscreen (Godot's
	# WINDOW_MODE_FULLSCREEN is a borderless desktop-sized window, not exclusive).
	# Skipped during headless capture, which drives a fixed --resolution offscreen.
	if not OS.has_environment("RELEASE_CAPTURE"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_rng.randomize()
	# Bigger, full-precision positional shadow atlas → far less shadow shimmer/flicker
	# (the spot-light shadows aliased badly at the 2048/16-bit default while animating).
	var vp := get_viewport()
	vp.positional_shadow_atlas_size = 4096
	vp.positional_shadow_atlas_16_bits = false
	# Default launch character is the guy (MH_Guy); RELEASE_CHAR=her overrides.
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
	# QA hook: RELEASE_FOCAL="x,y,z" sets the eye focal point (eye-midpoint frame).
	if OS.has_environment("RELEASE_FOCAL"):
		var fc := OS.get_environment("RELEASE_FOCAL").split(",")
		if fc.size() == 3:
			p.eye_fx = float(fc[0]); p.eye_fy = float(fc[1]); p.eye_fz = float(fc[2])
			_refreeze_abs_point(); _update_eye_focus()
	# QA: sweep the eye look without rewriting a preset — overrides applied before _apply_all.
	if OS.has_environment("RELEASE_EYE_RADIUS"): p.iris_radius = _envf("RELEASE_EYE_RADIUS", p.iris_radius)
	if OS.has_environment("RELEASE_EYE_SCALE"): p.iris_scale = _envf("RELEASE_EYE_SCALE", p.iris_scale)
	if OS.has_environment("RELEASE_EYE_TINT"): p.sclera_tint = _envf("RELEASE_EYE_TINT", p.sclera_tint)
	if OS.has_environment("RELEASE_EYE_ROUGH"): p.eye_rough = _envf("RELEASE_EYE_ROUGH", p.eye_rough)
	if OS.has_environment("RELEASE_EYE_CC"): p.eye_clearcoat = _envf("RELEASE_EYE_CC", p.eye_clearcoat)
	# Headless QA hook: RELEASE_TOGGLE=1 exercises the live character switch.
	if OS.has_environment("RELEASE_TOGGLE"):
		_switch_character()
	# Headless QA hook: RELEASE_CUSTOM=<abs path> exercises the custom-GLB loader.
	if OS.has_environment("RELEASE_CUSTOM"):
		_load_character(OS.get_environment("RELEASE_CUSTOM"))
		_rebuild_bs_panel(); _refresh_controls()
	_apply_all()
	_play_intro_reveal()   # launch: reveal the MetaHuman reference, then fade to the live render
	# Headless QA hook: RELEASE_HAIR=0 hides all hair grooms (the "Show hair" toggle).
	if OS.has_environment("RELEASE_HAIR"):
		_set_hair_visible(OS.get_environment("RELEASE_HAIR") != "0")
	# Seam-diagnostic hooks: RELEASE_NOCLOTH=1 hides the outfit so the raw bust-cap <-> body
	# interpenetration is directly visible; RELEASE_RAKE=1 turns on the opt-in hard hair rake.
	if OS.has_environment("RELEASE_NOCLOTH") and OS.get_environment("RELEASE_NOCLOTH") != "0":
		for om in _outfit_meshes:
			if is_instance_valid(om): om.visible = false
	if OS.has_environment("RELEASE_RAKE") and OS.get_environment("RELEASE_RAKE") != "0":
		_set_rake(true)
	# QA: RELEASE_BODY_ANIM=<clip> selects + plays a specific body clip (Walk/Wave/…).
	if OS.has_environment("RELEASE_BODY_ANIM"):
		_select_body_anim(OS.get_environment("RELEASE_BODY_ANIM"))
		_set_body_anim(true)
		if OS.has_environment("RELEASE_ANIM_SEEK") and _body_anim_player:
			_body_anim_player.seek(_envf("RELEASE_ANIM_SEEK", 0.0), true)
			if OS.has_environment("RELEASE_CAPTURE"):
				_body_anim_player.pause()   # hold the seeked frame for a clean still
	# Headless QA hooks for the toggles. RELEASE_ANIM_SEEK sets the face-anim time.
	if OS.has_environment("RELEASE_ANIM"):
		_set_face_anim(true); _set_body_anim(true)
		if OS.has_environment("RELEASE_ANIM_SEEK"):
			if _face_anim_player: _face_anim_player.seek(_envf("RELEASE_ANIM_SEEK", 0.0), true)
			if _body_anim_player: _body_anim_player.seek(_envf("RELEASE_ANIM_SEEK", 0.0), true)
	if OS.has_environment("RELEASE_HERO"):
		_set_hero_cam(true)
		_hero_elapsed = _envf("RELEASE_HERO_T", 0.0)
		_update_hero_camera()
	# Headless QA: RELEASE_SMOKE=<secs> runs the tool WINDOWED with face emote + body idle +
	# colour-cycle ON for <secs> (so the _process-driven paths — static idle, faked iris gaze,
	# hue cycling — actually execute, not gated off as during capture), then grabs a frame and
	# quits. Verifies those paths run without error and captures their live state.
	if OS.has_environment("RELEASE_SMOKE"):
		_set_face_anim(true); _set_body_anim(true); _set_color_cycle(true)
		await get_tree().create_timer(_envf("RELEASE_SMOKE", 2.0)).timeout
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
		get_viewport().get_texture().get_image().save_png("%s/smoke_%s.png" % [OUT_DIR, _char_key])
		print("[release] smoke done for ", _char_key, " (idle=", _static_idle_on, " cycle=", _color_cycle, ")")
		get_tree().quit()
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
	_env.ssao_radius = 0.4         # a touch wider so the gap under the hairline (floating cards) registers
	_env.ssao_intensity = 0.7      # live-scaled by "Shadow strength" in _apply_all
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
	if shadow:
		# Tame shadow acne/shimmer (the source of the flicker) + soften the edge a touch.
		# normal_bias is kept LOW: the hair cards float only ~mm off the scalp/forehead, and a
		# high normal_bias pushes their thin contact shadow right off the face (which is why
		# "hair never shadows the face" — the shadow was being biased away, not missing).
		s.shadow_bias = 0.02
		s.shadow_normal_bias = 0.25
		s.shadow_blur = 1.3
	add_child(s); return s

func _setup_lights() -> void:
	# Shadows on the front lights (key + keyrect + the bright fill) so hair/brow/nose cast
	# onto the face — the fill is the brightest, so it MUST cast or it washes the key's shadow
	# out. Darkness is controlled live by the "Shadow strength" slider (shadow_opacity).
	_lights["key"] = _spot("KeyLight_Spot", [63.40, 67.03, 279.20], -75.27, -138.92, p.key_col, 65.0, 20.0, true)
	_lights["keyrect"] = _spot("KeyLight_Rect", [63.40, 67.03, 279.20], -75.27, -138.92, p.keyrect_col, 80.0, 50.0, true)
	_lights["fill"] = _spot("FillLight", [28.57, 111.70, 111.70], -2.20, -96.03, p.fill_col, 70.0, 40.0, true)
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
	# Opt-in HARD hair rake (Task 2): a focused, shadow-casting spot placed front-high on the
	# CAMERA side and aimed to skim the hairline, so the hair cards throw a crisp shadow DOWN the
	# forehead. OFF by default so it never disturbs the ported moonlight key/fill/rim; positioned
	# per-frame in _update_rake() relative to the current view, so it rakes from any orbit angle.
	_rake = SpotLight3D.new(); _rake.name = "HairRake"
	_rake.light_color = Color(0.95, 0.96, 1.0)
	_rake.light_energy = 1.8   # low: the rake's value is the SHADOW it throws, not adding fill — high energy washes the forehead and kills the shadow contrast
	_rake.spot_angle = 26.0
	_rake.spot_angle_attenuation = 0.5
	_rake.spot_range = 6.0; _rake.spot_attenuation = 0.7
	_rake.light_specular = 0.2
	_rake.shadow_enabled = true
	_rake.shadow_bias = 0.02
	_rake.shadow_normal_bias = 0.16   # even lower than the rig spots — its whole job is the thin hairline contact shadow
	_rake.shadow_blur = 0.9
	_rake.visible = false
	add_child(_rake)

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
	# Lens-shift the subject right of the left settings panel (item 1). Negative
	# h_offset slides the framed subject to the RIGHT (same sign convention as the
	# capture-time cap_pan). Tunable live via the "View pan" slider. RELEASE_PAN is a
	# headless QA override (e.g. RELEASE_PAN=0 centres the subject for diagnostics).
	_camera.h_offset = _envf("RELEASE_PAN", float(p.get("view_pan", -0.22)))

# Position the opt-in hair rake front-high on the CAMERA side, aimed at the forehead (_head_world),
# so the hair cards skim a crisp shadow down the brow. Camera-relative → it rakes from any orbit
# angle and is unaffected by model_yaw (the camera always views the lit face side).
func _update_rake() -> void:
	if _rake == null or not _rake.visible or _camera == null: return
	var head: Vector3 = _head_world
	var to_cam: Vector3 = _camera.global_transform.origin - head
	to_cam.y = 0.0
	to_cam = to_cam.normalized() if to_cam.length() > 0.001 else Vector3(0, 0, 1)
	var side: Vector3 = to_cam.cross(Vector3.UP).normalized()   # graze ACROSS the hairline, not straight down
	# Higher + a touch to the side + less frontal = a steeper graze so the hairline throws LONG
	# shadows down the forehead instead of a flat frontal fill. Tunable via RELEASE_RAKE_* for sweeps.
	var pos: Vector3 = head \
		+ to_cam * _envf("RELEASE_RAKE_FWD", 0.40) \
		+ Vector3(0, _envf("RELEASE_RAKE_UP", 0.62), 0) \
		+ side * _envf("RELEASE_RAKE_SIDE", 0.22)
	var fwd: Vector3 = (head - pos).normalized()
	_rake.look_at_from_position(pos, head, _stable_up(fwd))

func _process(delta: float) -> void:
	# Turntable spins the MODEL (composes with hero cam + orbit). Gated off while the
	# body idle plays — the bind-basis face-follow assumes a fixed node yaw, so a live
	# turntable would detach the head. The idle itself supplies body motion.
	# Turntable spins the MODEL. It now COEXISTS with body/face anim + hero cam: the
	# face-follow below uses the CURRENT skeleton world transform, so a rotating node is
	# handled (no more gating it off during animation).
	if _turntable and _character and not OS.has_environment("RELEASE_CAPTURE"):
		_character.rotation.y += deg_to_rad(TURNTABLE_SPEED) * delta
		p["model_yaw"] = rad_to_deg(_character.rotation.y)

	# Subtle leg weight-shift while the body idles (knee bends + tiny pelvis bob), composed
	# on top of the body animation. Runs AFTER the AnimationPlayer applied this frame.
	if _body_anim_on and _body_skeleton:
		_update_leg_idle(delta)

	# Runtime LeaderPose: drive the FACE skeleton's shared bones from the animated BODY skeleton
	# so the neck/clavicle/bust-cap deforms WITH the body (closing the collar seam) while the head
	# still bobs with the head bone. The face armature NODE stays at rest — only bone poses move.
	# Composes with a turntable (works in skeleton-local space) and runs BEFORE the eye-gaze writes.
	if _follow_active and _body_skeleton and _face_skel and not _leader_pairs.is_empty():
		_apply_leader_pose()

	# Static-character idle (HER explainer GLB has no skeleton): a gentle rigid sway/breath/
	# weight-shift on the whole node. Runs after the turntable so the two compose (idle yaw
	# rides on top of model_yaw). Gated off during capture (the movie path owns rotation.y).
	if _static_idle_on and _character and not OS.has_environment("RELEASE_CAPTURE"):
		_update_static_idle(delta)

	# Camera: hero push-in (ping-pong) OR user-driven orbit.
	if _hero_cam and not OS.has_environment("RELEASE_CAPTURE"):
		_hero_elapsed += delta
		_update_hero_camera()
	else:
		_update_orbit_camera()

	# Opt-in hair rake follows the view (front-high, camera side) so it skims the hairline.
	if _rake_on:
		_update_rake()

	# Eyes: bone-driven gaze when the face rig HAS eye bones (the guy). Otherwise FAKE gaze by
	# driving the eye shader's iris_offset — HER explainer face is a static bake with no
	# FACIAL_*_Eye bones, so this is what makes "her eyes move" (look-at-camera + darts + blinks).
	if _intro_active:
		_eyes_straight_ahead()              # neutral forward gaze during the reveal (no double pupils)
	elif _face_eye_skel != null and _eye_bone_l >= 0:
		_update_eyes(delta)
	elif not _eye_mats.is_empty():
		_update_eyes_iris(delta)

	# Live light-colour cycling (demo toggle).
	if _color_cycle:
		_update_color_cycle(delta)

func _update_hero_camera() -> void:
	# Clean ping-pong dolly: the aim stays on the model's vertical axis (x=z=0) so the
	# subject is ALWAYS centered; it rises chest→face as we push in. Camera moves along the
	# current orbit azimuth with a gentle constant downward tilt — no curving/off-centre path.
	if _camera == null: return
	var phase: float = fmod(_hero_elapsed, 2.0 * HERO_DURATION) / HERO_DURATION
	var pp: float = phase if phase <= 1.0 else (2.0 - phase)
	pp = smoothstep(0.0, 1.0, pp)
	# Dolly between a wide pull-back and the user's EXACT current framing (their orbit
	# target/dist/yaw/pitch/fov/view-pan) at the close end — so the close hero matches the
	# portrait they composed, and the whole move stays centred the way they set it.
	var yaw_rad := deg_to_rad(_orbit_yaw)
	var pitch_rad := deg_to_rad(_orbit_pitch)
	var dir := Vector3(sin(yaw_rad) * cos(pitch_rad), sin(pitch_rad), cos(yaw_rad) * cos(pitch_rad))
	var aim := Vector3(_orbit_target.x, lerpf(_orbit_target.y - 0.28, _orbit_target.y, pp), _orbit_target.z)
	var dist: float = lerpf(_orbit_dist + 2.3, _orbit_dist, pp)
	_camera.position = aim + dir * dist
	_camera.look_at(aim, Vector3.UP)
	_camera.fov = _orbit_fov
	_camera.h_offset = float(p.get("view_pan", 0.0))   # same lens-shift/composition as the orbit view

# ---- animation (face emote + body idle, independent toggles) ----------------
func _anim_active() -> bool:
	return _body_anim_on or _face_anim_on

func _set_rake(on: bool) -> void:
	_rake_on = on
	if _rake:
		_rake.visible = on
		if on: _rake.light_energy = _envf("RELEASE_RAKE_E", _rake.light_energy)   # quick energy sweeps
	if on: _update_rake()

func _set_hero_cam(on: bool) -> void:
	_hero_cam = on
	if on:
		_hero_elapsed = 0.0
		if _camera: _camera.h_offset = 0.0
	else:
		if _camera: _camera.fov = _orbit_fov
		_update_orbit_camera()

# FACE emote (blend-shape performance). Independent of body idle.
func _set_face_anim(on: bool) -> void:
	_face_anim_on = on
	if on:
		if _face_anim_player: _face_anim_player.play("emote")
	else:
		if _face_anim_player: _face_anim_player.stop()
		_zero_all_blendshapes()
		_reapply_blendshapes()

# BODY idle (+ face-follow so the separate face armature tracks the head bone, + subtle
# leg weight-shift). Independent of the face emote; coexists with turntable + hero cam.
func _set_body_anim(on: bool) -> void:
	_body_anim_on = on
	if on:
		if _body_anim_player and _body_anim_player.get_animation_list().size() > 0:
			var bn: String = _resolve_body_anim()
			var ba: Animation = _body_anim_player.get_animation(bn)
			if ba: ba.loop_mode = Animation.LOOP_LINEAR
			_body_anim_player.play(bn)
			_body_anim_name = bn
			_follow_active = _body_skeleton != null and _face_skel != null and not _leader_pairs.is_empty()
		else:
			# No imported idle clip. HER explainer GLB is a STATIC bake (no skeleton, no
			# AnimationPlayer), so drive a gentle rigid idle on the whole character node.
			_static_idle_on = true
			_static_idle_clock = 0.0
			_set_status("static idle (no skeleton) — gentle rigid sway")
	else:
		if _body_anim_player: _body_anim_player.stop()
		_follow_active = false
		_leg_clock = 0.0
		_reset_leg_bones()
		_reset_face_leader_pose()   # return the driven face bones to their rest (face node never moved)
		if _static_idle_on:
			_static_idle_on = false
			if _character:
				_character.position = _char_rest_pos
				_character.rotation.y = deg_to_rad(p.model_yaw)

# Which body clip to play: the explicit selection if present, else the first preferred
# (Idle → … → BodyIdle_Procedural) that exists, else whatever is first in the GLB.
func _resolve_body_anim() -> String:
	if _body_anim_player == null: return ""
	var list := _body_anim_player.get_animation_list()
	if list.is_empty(): return ""
	if _body_anim_name != "" and _body_anim_name in list: return _body_anim_name
	for nm in BODY_ANIM_ORDER:
		if nm in list: return nm
	return list[0]

# Switch the live body clip from the dropdown (crossfades if the body idle is playing).
func _select_body_anim(nm: String) -> void:
	_body_anim_name = nm
	if _body_anim_player == null or not (nm in _body_anim_player.get_animation_list()): return
	var a: Animation = _body_anim_player.get_animation(nm)
	if a: a.loop_mode = Animation.LOOP_LINEAR
	if _body_anim_on:
		_body_anim_player.play(nm, 0.3)   # 0.3s crossfade
		_follow_active = _body_skeleton != null and _face_skel != null and not _leader_pairs.is_empty()

# Dropdown → switch the live body clip (turns the body idle on if it was off).
func _on_body_anim_dd(idx: int) -> void:
	if _body_anim_dd == null: return
	var nm := _body_anim_dd.get_item_text(idx)
	if not _body_anim_on:
		_set_body_anim(true)
	_select_body_anim(nm)
	_refresh_controls()

# Repopulate the body-clip dropdown from the character's AnimationPlayer (ordered Idle→…→
# procedural, then any extras). Hidden when the character ships fewer than 2 body clips.
func _refresh_body_anim_dd() -> void:
	if _body_anim_dd == null: return
	_body_anim_dd.clear()
	var list := PackedStringArray()
	if _body_anim_player: list = _body_anim_player.get_animation_list()
	var ordered: Array[String] = []
	for nm in BODY_ANIM_ORDER:
		if list.has(nm): ordered.append(String(nm))
	for nm in list:
		if not ordered.has(nm): ordered.append(String(nm))
	var sel := _resolve_body_anim()
	for i in ordered.size():
		_body_anim_dd.add_item(ordered[i])
		if ordered[i] == sel: _body_anim_dd.select(i)
	if _body_anim_dd.get_parent(): (_body_anim_dd.get_parent() as Control).visible = ordered.size() >= 2

# Subtle leg weight-shift: a gentle knee bend composed on top of the body idle.
# CRITICAL: base each rotation on the bone's REST pose, NOT the live pose. The body
# idle animation does NOT key the calf bones, so reading the live pose and multiplying
# a delta each frame COMPOUNDS — the calves spun right around ("legs below the knees
# spinning"). Rest-based is bounded: a fixed ±deg sway, never accumulating. The pelvis
# IS keyed by the idle (it re-resets each frame), so it composes without compounding.
func _update_leg_idle(delta: float) -> void:
	_leg_clock += delta
	var t := _leg_clock
	if _calf_l_idx >= 0:
		var rest_l: Quaternion = _body_skeleton.get_bone_rest(_calf_l_idx).basis.get_rotation_quaternion()
		_body_skeleton.set_bone_pose_rotation(_calf_l_idx, rest_l * Quaternion(Vector3(1, 0, 0), (0.5 + 0.5 * sin(t * 1.0)) * deg_to_rad(1.6)))
	if _calf_r_idx >= 0:
		var rest_r: Quaternion = _body_skeleton.get_bone_rest(_calf_r_idx).basis.get_rotation_quaternion()
		_body_skeleton.set_bone_pose_rotation(_calf_r_idx, rest_r * Quaternion(Vector3(1, 0, 0), (0.5 + 0.5 * sin(t * 1.0 + PI)) * deg_to_rad(1.6)))
	if _pelvis_idx >= 0:
		var rp: Quaternion = _body_skeleton.get_bone_pose_rotation(_pelvis_idx)
		_body_skeleton.set_bone_pose_rotation(_pelvis_idx, rp * Quaternion(Vector3(0, 0, 1), sin(t * 1.0) * deg_to_rad(0.8)))

func _reset_leg_bones() -> void:
	if _body_skeleton == null: return
	for idx in [_calf_l_idx, _calf_r_idx, _pelvis_idx]:
		if idx >= 0:
			_body_skeleton.set_bone_pose_rotation(idx, _body_skeleton.get_bone_rest(idx).basis.get_rotation_quaternion())

# Gentle rigid idle for a boneless static character (HER explainer): a seamless-looping
# lateral weight shift + breathing bob + slow yaw drift on the whole node, layered on top
# of the rest pose / model_yaw. Head, face and body stay locked together (no rig, no seam).
func _update_static_idle(delta: float) -> void:
	_static_idle_clock += delta
	var t := _static_idle_clock
	var sway_x := sin(t * 0.55) * 0.013          # ±1.3 cm lateral weight shift
	var bob_y := sin(t * 0.95) * 0.006           # ±6 mm breathing bob
	var lean_z := sin(t * 0.40) * 0.006
	var yaw := sin(t * 0.37) * deg_to_rad(1.8)   # subtle turn (±1.8°)
	_character.position = _char_rest_pos + Vector3(sway_x, bob_y, lean_z)
	_character.rotation.y = deg_to_rad(p.model_yaw) + yaw

# ---- faked iris gaze (boneless eyes) ----------------------------------------
# Calibration for the iris-offset gaze (UV space). Flip IRIS_SIGN components after a test
# render if "look at camera" sends the irises the wrong way.
const IRIS_MAX_OFF := 0.075      # clamp so the iris disc stays on the sclera
const IRIS_FOLLOW_K := 0.13      # camera-follow gain
const IRIS_SIGN := Vector2(1.0, 1.0)

func _update_eyes_iris(delta: float) -> void:
	var capture_static := OS.has_environment("RELEASE_CAPTURE") and not _anim_active()
	var off := Vector2.ZERO
	if bool(p.get("eye_look_cam", true)) and _camera and _character and not capture_static:
		# gaze toward the lens: head→camera direction projected into the model's local frame
		var dir: Vector3 = (_camera.global_transform.origin - _head_world).normalized()
		var loc: Vector3 = _character.global_transform.basis.inverse() * dir
		off += Vector2(loc.x * IRIS_SIGN.x, loc.y * IRIS_SIGN.y) * IRIS_FOLLOW_K
	elif not capture_static:
		off += Vector2(p.eye_fx, p.eye_fy) * 0.12   # manual focal when look-cam is off
	if bool(p.get("eye_alive", true)) and not capture_static:
		off += _alive_offset_uv(delta)
		_update_blink(delta)                          # blinks via eyeBlink* blendshapes (she has them)
	off.x = clampf(off.x, -IRIS_MAX_OFF, IRIS_MAX_OFF)
	off.y = clampf(off.y, -IRIS_MAX_OFF, IRIS_MAX_OFF)
	_iris_off = _iris_off.lerp(off, clampf(delta * 12.0, 0.0, 1.0))
	for m in _eye_mats:
		m.set_shader_parameter("iris_offset", _iris_off)

# Small candid saccadic dart + micro-drift, in iris-UV units (mirror of _alive_offset).
func _alive_offset_uv(delta: float) -> Vector2:
	_alive_clock += delta
	if _alive_clock >= _sacc_next:
		if _rng.randf() < 0.45:
			_sacc_tgt = Vector2(_rng.randf_range(-0.05, 0.05), _rng.randf_range(-0.035, 0.022))
			_sacc_next = _alive_clock + _rng.randf_range(0.7, 1.8)
		else:
			_sacc_tgt = Vector2(_rng.randfn(0.0, 0.006), _rng.randfn(0.0, 0.005))
			_sacc_next = _alive_clock + _rng.randf_range(0.4, 1.1)
	_sacc_off = _sacc_off.lerp(_sacc_tgt, clampf(delta * 20.0, 0.0, 1.0))
	return _sacc_off + Vector2(sin(_alive_clock * 6.1) * 0.0016, cos(_alive_clock * 4.7) * 0.0013)

# ---- live light-colour cycling (demo) ---------------------------------------
func _set_color_cycle(on: bool) -> void:
	_color_cycle = on
	_color_cycle_clock = 0.0
	if not on:
		_apply_all()   # restore the preset's light colours + backdrop

func _update_color_cycle(delta: float) -> void:
	_color_cycle_clock += delta
	var t := _color_cycle_clock
	_cycle_light("key", t * 0.06, 0.0)
	_cycle_light("keyrect", t * 0.06, 0.02)
	_cycle_light("fill", t * 0.05, 0.5)     # ~complementary to the key
	_cycle_light("rim", t * 0.08, 0.33)
	if _lights.has("ambient"):
		(_lights["ambient"] as Light3D).light_color = Color.from_hsv(fmod(t * 0.04 + 0.66, 1.0), 0.55, 0.5)
	# tint the backdrop gradient + environment bg for full-scene mood
	var bgc := Color.from_hsv(fmod(t * 0.03, 1.0), 0.5, 0.28)
	if _env: _env.background_color = bgc
	if _backdrop_mat:
		_backdrop_mat.set_shader_parameter("top_col", bgc.darkened(0.12))
		_backdrop_mat.set_shader_parameter("bot_col", bgc.lightened(0.06))
		_backdrop_mat.set_shader_parameter("glow_col", bgc.lightened(0.12))

func _cycle_light(key: String, phase: float, offset: float) -> void:
	if not _lights.has(key): return
	var base: Color = p.get(key + "_col", Color(1, 1, 1))
	var v: float = maxf(base.v, 0.6)
	(_lights[key] as Light3D).light_color = Color.from_hsv(fmod(phase + offset, 1.0), 0.7, v)

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
	_pelvis_idx = best.find_bone("pelvis")
	_calf_l_idx = best.find_bone("calf_l")
	_calf_r_idx = best.find_bone("calf_r")

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
	# Capture the face armature's transform RELATIVE to the head bone's world transform
	# (at rest). At runtime: face.global = (skel.global * head_pose) * _face_off — which
	# tracks the idle bob AND a turntable-rotated character node.
	_face_arm_rest_local = _face_armature.transform   # for restore on stop
	var head_world: Transform3D = _body_skeleton.global_transform * _body_skeleton.get_bone_global_rest(_head_bone_idx)
	_face_off = head_world.affine_inverse() * _face_armature.global_transform

# Build the body→face shared-bone map for the LeaderPose copy. For every BODY bone that the
# FACE skeleton also has (by name), precompute rest_xfer = RBg⁻¹ · RFg (each rig's own rest
# global pose) so per frame we only do PFg = PBg · rest_xfer. Sorted by face-bone index so
# parents are driven before children (Godot keeps a bone's parent index below its own).
func _build_leader_pose_map() -> void:
	_leader_pairs.clear()
	_face_skel = _face_eye_skel   # the FACIAL_L_Eye skeleton == the face mesh's skeleton
	if _body_skeleton == null or _face_skel == null:
		return
	for bi in range(_body_skeleton.get_bone_count()):
		var fi: int = _face_skel.find_bone(_body_skeleton.get_bone_name(bi))
		if fi < 0:
			continue
		var rest_xfer: Transform3D = _body_skeleton.get_bone_global_rest(bi).affine_inverse() \
			* _face_skel.get_bone_global_rest(fi)
		_leader_pairs.append([bi, fi, _face_skel.get_bone_parent(fi), rest_xfer])
	_leader_pairs.sort_custom(func(a, b): return a[1] < b[1])
	print("[release] leader-pose map: %d shared bones (body %d / face %d)" % \
		[_leader_pairs.size(), _body_skeleton.get_bone_count(), _face_skel.get_bone_count()])

# Per-frame LeaderPose: set each shared face bone's pose so its GLOBAL pose tracks the body's
# global motion (PFg = PBg · rest_xfer). We cache the desired face global per bone and convert
# to a local pose using the (already-computed, parent-first) parent global — no skeleton readback
# and no dependence on Godot's recompute order. Leaves FACIAL_* bones (incl. the eyes) at rest so
# the blend-shape emote and the eye-gaze writes (which run AFTER this) are untouched.
func _apply_leader_pose() -> void:
	var pfg_cache := {}
	for pair in _leader_pairs:
		var bi: int = pair[0]
		var fi: int = pair[1]
		var fpar: int = pair[2]
		var pfg: Transform3D = _body_skeleton.get_bone_global_pose(bi) * (pair[3] as Transform3D)
		pfg_cache[fi] = pfg
		var parent_g: Transform3D = Transform3D.IDENTITY
		if fpar >= 0:
			parent_g = pfg_cache[fpar] if pfg_cache.has(fpar) else _face_skel.get_bone_global_pose(fpar)
		var local: Transform3D = parent_g.affine_inverse() * pfg
		_face_skel.set_bone_pose_position(fi, local.origin)
		_face_skel.set_bone_pose_rotation(fi, local.basis.get_rotation_quaternion())
		_face_skel.set_bone_pose_scale(fi, local.basis.get_scale())

# Restore every driven face bone to its local rest (called when the body idle stops).
func _reset_face_leader_pose() -> void:
	if _face_skel == null: return
	for pair in _leader_pairs:
		var fi: int = pair[1]
		var r: Transform3D = _face_skel.get_bone_rest(fi)
		_face_skel.set_bone_pose_position(fi, r.origin)
		_face_skel.set_bone_pose_rotation(fi, r.basis.get_rotation_quaternion())
		_face_skel.set_bone_pose_scale(fi, r.basis.get_scale())

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
	_eye_mats.clear(); _lash_mats.clear(); _hair_meshes.clear(); _hair_back_meshes.clear()
	_static_idle_on = false; _static_idle_clock = 0.0; _iris_off = Vector2.ZERO
	_bs_map.clear()
	# tear down per-character animation state
	if _face_anim_player and is_instance_valid(_face_anim_player):
		_face_anim_player.queue_free()
	_face_anim_player = null; _body_anim_player = null
	_body_skeleton = null; _face_armature = null; _head_bone_idx = -1
	_face_skel = null; _leader_pairs.clear()
	_face_eye_skel = null; _eye_bone_l = -1; _eye_bone_r = -1
	_face_anim_on = false; _body_anim_on = false; _follow_active = false
	_pelvis_idx = -1; _calf_l_idx = -1; _calf_r_idx = -1; _leg_clock = 0.0
	_outfit_mats.clear(); _outfit_meshes.clear(); _body_skin_mat = null

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
	_char_rest_pos = node.position   # base pose for the static (boneless) idle
	node.rotation.y = deg_to_rad(p.model_yaw)
	if custom_path == "":
		_wire_materials(node)
	else:
		_wire_custom(node)
	_collect_blendshapes(node)
	var aabb3 := _world_aabb(node)
	_head_world = Vector3(0.0, aabb3.position.y + aabb3.size.y - 0.12, 0.05)
	# Resolve skeletons + eye bones FIRST — the groom-attach needs the face skeleton's
	# head bone, and the face emote must be built AFTER the grooms are reparented so its
	# blend-shape tracks resolve to the grooms' new node paths.
	_resolve_body_skeleton(node)
	_find_body_anim_player(node)
	_resolve_eye_bones(node)          # FACIAL_L/R_Eye for bone-driven gaze + the head bone
	# Grooms (hair/beard/mustache/eyebrow cards) were object-parented to the FaceArmature
	# NODE, so they did NOT follow the head BONE — they detached the moment the body idle /
	# LeaderPose bobbed the head. Reparent each under a BoneAttachment3D on the face head
	# bone so they ride head motion (their shape keys still deform for expressions).
	_attach_grooms_to_head()
	# Face emote animation (blend-shape performance). Built but NOT played; the toggle drives it.
	_build_face_animation(node)
	_bind_face_to_head_bone(node)
	_build_leader_pose_map()          # seam fix: shared body↔face bones for the LeaderPose copy
	_set_hair_visible(_hair_visible)  # carry the "Show hair" toggle across loads/switches

func _switch_character() -> void:
	# 1. Remember the LEAVING character's current look (lighting/skin/eyes/camera).
	_char_look[_char_key] = _capture_look()
	# 2. Capture the persistent ANIMATION-TOGGLE layer — it carries across the switch.
	var toggles := _capture_toggles()
	# 3. Advance to the next character.
	var i := CHAR_ORDER.find(_char_key)
	_char_key = CHAR_ORDER[(i + 1) % CHAR_ORDER.size()]
	_profile = PROFILES[_char_key]
	# 4. Lighting/look: restore this character's REMEMBERED look if we've seen it before,
	#    else fall back to its default preset (first-time = defaults).
	if _char_look.has(_char_key):
		_restore_look(_char_look[_char_key])
	else:
		_load_preset_file("%s/%s.json" % [PRESET_DIR, _profile.get("default_preset", "")])
	# 5. Load the mesh (this resets the per-load toggle member-vars to off).
	_load_character()
	_reapply_blendshapes()   # carry the current ARKit pose across the character swap
	_apply_overlay_image()   # show THIS character's UE reference (or none)
	_rebuild_bs_panel()
	_refresh_preset_list()
	# 6. Re-apply the persistent toggle layer on top of the loaded look.
	_apply_toggles(toggles)
	_refresh_controls()
	_apply_all()
	if _char_btn: _char_btn.text = "Character: " + _profile["label"]
	_play_intro_reveal()   # switch: cross-dissolve from this character's MetaHuman reference
	_set_status("Loaded " + _profile["label"])

# ---- per-character look memory + persistent toggle layer --------------------
# Capture the current LOOK (everything that is NOT an animation toggle): the full p dict
# (deep copy — Colors are values) + the orbit camera. eye_alive/eye_look_cam live in p but
# are treated as toggles (see _capture/_apply_toggles), which win on restore.
func _capture_look() -> Dictionary:
	return {
		"p": p.duplicate(true),
		"oy": _orbit_yaw, "op": _orbit_pitch, "od": _orbit_dist,
		"of": _orbit_fov, "ot": _orbit_target,
	}

func _restore_look(s: Dictionary) -> void:
	var sp: Dictionary = s.get("p", {})
	for k in sp.keys():
		if p.has(k): p[k] = sp[k]
	_orbit_yaw = s.get("oy", _orbit_yaw); _orbit_pitch = s.get("op", _orbit_pitch)
	_orbit_dist = s.get("od", _orbit_dist); _orbit_fov = s.get("of", _orbit_fov)
	_orbit_target = s.get("ot", _orbit_target)
	_start_orbit_yaw = _orbit_yaw; _start_orbit_pitch = _orbit_pitch
	_start_orbit_dist = _orbit_dist; _start_orbit_fov = _orbit_fov
	_start_orbit_target = _orbit_target
	if _camera and not OS.has_environment("RELEASE_CAPTURE"):
		_camera.fov = _orbit_fov; _update_orbit_camera()

# The animation toggles persist GLOBALLY across character switches (per the request).
func _capture_toggles() -> Dictionary:
	return {
		"face": _face_anim_on, "body": _body_anim_on, "hero": _hero_cam,
		"turntable": _turntable, "cycle": _color_cycle, "hair": _hair_visible, "rake": _rake_on,
		"eye_alive": bool(p.get("eye_alive", true)), "eye_look_cam": bool(p.get("eye_look_cam", true)),
	}

func _apply_toggles(t: Dictionary) -> void:
	# eye_alive / eye_look_cam are part of p but behave as persistent toggles → set them
	# BEFORE the camera/eye drivers run, overriding whatever the restored look carried.
	p.eye_alive = t.get("eye_alive", true)
	p.eye_look_cam = t.get("eye_look_cam", true)
	_turntable = bool(t.get("turntable", false))
	_set_hair_visible(bool(t.get("hair", true)))
	_set_face_anim(bool(t.get("face", false)))
	_set_body_anim(bool(t.get("body", false)))
	_set_hero_cam(bool(t.get("hero", false)))
	_set_color_cycle(bool(t.get("cycle", false)))   # if on, lighting stays ANIMATED across the switch
	_set_rake(bool(t.get("rake", false)))           # carry the opt-in hair rake across switches

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
	_body_skin_mat = body_skin   # tag the body material for the anti-poke shrink
	var eye_l := _make_eye("L"); var eye_r := _make_eye("R")
	_eye_mats = [eye_l, eye_r]
	var hide_mat := _make_hide()
	var teeth_mat := _make_teeth()
	var lash_mat := _make_lash()
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
				_wire_face_by_index(mi, face_skin, teeth_mat, eye_r, eye_l, hide_mat, lash_mat)
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
			# Grow-shell: inflate the shirt slightly along normals so the neck/shoulder skin
			# can't poke through it when the body deforms. Tunable via "Outfit inflate".
			cloth.grow = true
			cloth.grow_amount = float(p.get("outfit_grow", 0.006))
			for s in range(mesh.get_surface_count()):
				mi.set_surface_override_material(s, cloth)
			_outfit_mats.append(cloth)
			_outfit_meshes.append(mi)

func _wire_face_by_index(mi: MeshInstance3D, skin, teeth, eye_r, eye_l, hide, lash = null) -> void:
	var imap: Dictionary = _profile["face_index_map"]
	var role_mat := {"skin": skin, "teeth": teeth, "eyeR": eye_r, "eyeL": eye_l, "hide": hide,
		"lashes": (lash if lash != null else hide)}
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
			_hair_back_meshes.append(backing)

# Show/hide ALL hair-card grooms (scalp hair + beard/mustache/eyebrows on the guy) and their
# backing shells. Toggleable live; re-applied after a character switch so it persists.
func _set_hair_visible(on: bool) -> void:
	_hair_visible = on
	for m in _hair_meshes:
		if is_instance_valid(m): (m as MeshInstance3D).visible = on
	for b in _hair_back_meshes:
		if is_instance_valid(b): (b as MeshInstance3D).visible = on

# Reparent the groom cards (+ backing shells) under a BoneAttachment3D on the face skeleton's
# `head` bone so they FOLLOW head motion. They were object-parented to the FaceArmature NODE,
# which stays put while the body idle / LeaderPose drive the head BONE — so they detached the
# moment she/he moved. The BoneAttachment3D rides the bone; the grooms' own blend-shape
# (expression) deformation still works locally. Idempotent (skips already-attached).
func _attach_grooms_to_head() -> void:
	if _face_eye_skel == null or _face_eye_skel.find_bone("head") < 0:
		return
	var to_attach: Array = []
	to_attach.append_array(_hair_meshes)
	to_attach.append_array(_hair_back_meshes)
	var n := 0
	for g in to_attach:
		if not (g is Node3D) or not is_instance_valid(g):
			continue
		var n3 := g as Node3D
		if n3.get_parent() is BoneAttachment3D:
			continue
		var ba := BoneAttachment3D.new()
		ba.name = n3.name + "_HeadBA"
		_face_eye_skel.add_child(ba)
		ba.bone_name = "head"
		n3.reparent(ba, true)   # keep world transform — grooms stay put, now ride the head bone
		n += 1
	if n > 0:
		print("[release] attached %d groom mesh(es) to the head bone" % n)

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
	# The "teeth" surface is the whole mouth — teeth + tongue + gums — so it MUST use the
	# real baked albedo (pink tongue, gum line). With a texture, keep albedo white so the
	# texture shows true; only the no-texture fallback uses a tint, and that tint is BONE,
	# not chalk-white (the old 0.95 fallback is what made her tongue + teeth read white).
	var m := StandardMaterial3D.new()
	var bc := _rtex(_profile.get("teeth_bc", ""))
	if bc:
		m.albedo_texture = bc
		m.albedo_color = Color(1, 1, 1)
	else:
		m.albedo_color = Color(0.74, 0.70, 0.64)
	var nn := _rtex(_profile.get("teeth_n", ""))
	if nn:
		m.normal_enabled = true; m.normal_texture = nn
	m.roughness = 0.42; m.metallic = 0.0
	# A little subsurface so the tongue/gums read as wet flesh rather than plastic.
	m.subsurf_scatter_enabled = true
	m.subsurf_scatter_strength = 0.22
	return m

# Eyelash material: the MH lash card coverage atlas through the alpha-clipped, shadow-
# casting hair shader. With no lash atlas in the profile (e.g. the guy) we keep the old
# behaviour of hiding the flat lash strips (solid-dark strips read as raccoon rings).
func _make_lash() -> Material:
	var atlas_name: String = _profile.get("lash_atlas", "")
	if atlas_name == "":
		return _make_hide()
	var tex := _rtex(atlas_name)
	if tex == null:
		return _make_hide()
	var m := ShaderMaterial.new()
	m.shader = load("res://scenes/hair_card_shadow.gdshader") as Shader
	m.set_shader_parameter("coverage_atlas", tex)
	m.set_shader_parameter("use_red_mask", bool(_profile.get("lash_mask_red", false)))
	m.set_shader_parameter("invert_mask", false)
	m.set_shader_parameter("hair_color", _profile.get("lash_color", Color(0.03, 0.022, 0.018)))
	m.set_shader_parameter("alpha_threshold", 0.12)
	m.set_shader_parameter("root_darkening", 0.0)
	m.set_shader_parameter("roughness_val", 0.5)
	m.set_shader_parameter("specular_val", 0.12)
	_lash_mats.append(m)
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

# ---- eye gaze (look-at a single focal point) --------------------------------
func _resolve_eye_bones(root: Node) -> void:
	_face_eye_skel = null; _eye_bone_l = -1; _eye_bone_r = -1
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			var s := n as Skeleton3D
			var li := s.find_bone("FACIAL_L_Eye")
			var ri := s.find_bone("FACIAL_R_Eye")
			if li >= 0 and ri >= 0:
				_face_eye_skel = s; _eye_bone_l = li; _eye_bone_r = ri
				return
		for c in n.get_children(): stack.append(c)

# World position + rest orientation (world) of an eye bone, after any face-follow.
func _eye_world_pos(idx: int) -> Vector3:
	return _face_eye_skel.global_transform * _face_eye_skel.get_bone_global_pose(idx).origin
func _eye_rest_basis_world(idx: int) -> Basis:
	return (_face_eye_skel.global_transform.basis * _face_eye_skel.get_bone_global_rest(idx).basis).orthonormalized()

# Build the eye-midpoint frame: origin between the eyes, +z = mean rest look dir,
# +x = subject-right, +y = up. The user's focal vector is expressed in this frame.
func _eye_gaze_frame() -> Array:  # [origin, basis]
	var lp := _eye_world_pos(_eye_bone_l)
	var rp := _eye_world_pos(_eye_bone_r)
	var origin := (lp + rp) * 0.5
	var fwd := ((_eye_rest_basis_world(_eye_bone_l) * _eye_fwd_axis) \
			+ (_eye_rest_basis_world(_eye_bone_r) * _eye_fwd_axis)).normalized()
	if fwd.length() < 0.5: fwd = Vector3(0, 0, 1)
	var up := Vector3.UP
	var right := fwd.cross(up).normalized()
	if right.length() < 0.5: right = Vector3(1, 0, 0)
	up = right.cross(fwd).normalized()
	return [origin, Basis(right, up, fwd)]

# Current focal point in world space (relative = tracks head; absolute = frozen world point).
func _focal_world() -> Vector3:
	var fr: Array = _eye_gaze_frame()
	if bool(p.get("eye_focus_abs", false)):
		return _eye_abs_point
	var origin: Vector3 = fr[0]; var basis: Basis = fr[1]
	return origin + basis * Vector3(p.eye_fx, p.eye_fy, p.eye_fz)

# Recompute & freeze the absolute world point from the current frame + focal vector.
func _refreeze_abs_point() -> void:
	if _face_eye_skel == null or _eye_bone_l < 0: return
	var fr: Array = _eye_gaze_frame()
	_eye_abs_point = (fr[0] as Vector3) + (fr[1] as Basis) * Vector3(p.eye_fx, p.eye_fy, p.eye_fz)

func _update_eye_focus() -> void:
	if _face_eye_skel == null or _eye_bone_l < 0: return
	var target := _focal_world()
	_aim_eye(_eye_bone_l, target)
	_aim_eye(_eye_bone_r, target)

# Force a neutral, PARALLEL straight-ahead gaze (no darts, no convergence) for BOTH eye rigs —
# used during the intro reveal so the live pupils sit still on the static reference's pupils
# (a converged or darting gaze shows as double pupils through the cross-dissolve).
func _eyes_straight_ahead() -> void:
	if _face_eye_skel != null and _eye_bone_l >= 0:
		# Guy: aim both bone-eyes at a FAR forward point (far ⇒ parallel ⇒ no cross-eye convergence).
		var fr: Array = _eye_gaze_frame()
		var fwd: Vector3 = (fr[0] as Vector3) + (fr[1] as Basis) * Vector3(0.0, 0.0, 20.0)
		_aim_eye(_eye_bone_l, fwd)
		_aim_eye(_eye_bone_r, fwd)
	elif not _eye_mats.is_empty():
		# Gal: boneless face — centre the iris (offset zero = looking straight ahead).
		_iris_off = Vector2.ZERO
		for m in _eye_mats:
			m.set_shader_parameter("iris_offset", Vector2.ZERO)

# Unified per-frame eye driver.
#  - Target = camera (if "Look at camera") else the manual focal point.
#  - "Look at camera" also writes the camera's position back into the manual focal
#    fields (in the eye-midpoint frame) so the sliders track it; uncheck to take over
#    starting from those values (e.g. nudge to "look slightly left of camera").
#  - "Alive eyes" adds candid saccadic darts + blinks around whatever the target is.
#  - Static UE-match captures (no anim) skip both, holding the manual focal for stability.
func _update_eyes(delta: float) -> void:
	if _face_eye_skel == null or _eye_bone_l < 0: return
	var capture_static := OS.has_environment("RELEASE_CAPTURE") and not _anim_active()
	var look_cam := bool(p.get("eye_look_cam", true)) and _camera != null and not capture_static
	var target: Vector3
	if look_cam:
		target = _camera.global_transform.origin
		_set_focal_from_world(target)   # keep the manual focal fields synced to the camera
	else:
		target = _focal_world()
	if bool(p.get("eye_alive", true)) and _camera != null and not capture_static:
		target += _alive_offset(delta)
		_update_blink(delta)
	_aim_eye(_eye_bone_l, target)
	_aim_eye(_eye_bone_r, target)

# Candid saccadic dart + micro-drift, returned as a world offset in the camera's
# screen plane (so it reads as small natural eye movements around the target).
func _alive_offset(delta: float) -> Vector3:
	_alive_clock += delta
	if _alive_clock >= _sacc_next:
		if _rng.randf() < 0.45:
			_sacc_tgt = Vector2(_rng.randf_range(-0.35, 0.35), _rng.randf_range(-0.32, 0.12))
			_sacc_next = _alive_clock + _rng.randf_range(0.7, 1.8)
		else:
			_sacc_tgt = Vector2(_rng.randfn(0.0, 0.02), _rng.randfn(0.0, 0.014))
			_sacc_next = _alive_clock + _rng.randf_range(0.4, 1.1)
	_sacc_off = _sacc_off.lerp(_sacc_tgt, clampf(delta * 20.0, 0.0, 1.0))
	var drift := Vector2(sin(_alive_clock * 6.1) * 0.0016, cos(_alive_clock * 4.7) * 0.0013)
	var rb := _camera.global_transform.basis
	return rb.x * (_sacc_off.x + drift.x) + rb.y * (_sacc_off.y + drift.y)

func _update_blink(delta: float) -> void:
	if _blink_t < 0.0 and _alive_clock >= _blink_next:
		_blink_t = 0.0
	if _blink_t >= 0.0:
		_blink_t += delta
		var bl := 0.13
		var v := 0.0
		if _blink_t < bl * 0.35:
			v = _blink_t / (bl * 0.35)
		elif _blink_t < bl:
			v = 1.0 - (_blink_t - bl * 0.35) / (bl * 0.65)
		else:
			_blink_t = -1.0
			_blink_next = _alive_clock + _rng.randf_range(2.5, 6.0)
			v = 0.0
		_set_blink(v)

# Convert a WORLD point into the eye-midpoint frame and store it as the manual focal
# (eye_fx/fy/fz), updating the focal sliders so they read the live value.
func _set_focal_from_world(world: Vector3) -> void:
	var fr: Array = _eye_gaze_frame()
	var local: Vector3 = (fr[1] as Basis).inverse() * (world - (fr[0] as Vector3))
	p.eye_fx = local.x; p.eye_fy = local.y; p.eye_fz = local.z
	for key in ["eye_fx", "eye_fy", "eye_fz"]:
		if _focus_ctrls.has(key):
			_focus_ctrls[key]["spin"].set_value_no_signal(float(p[key]))
			_focus_ctrls[key]["sl"].set_value_no_signal(float(p[key]))

func _set_blink(v: float) -> void:
	for nm in ["eyeBlinkLeft", "eyeBlinkRight"]:
		if _bs_map.has(nm):
			for pair in _bs_map[nm]:
				pair[0].set_blend_shape_value(pair[1], v)

# Minimal-rotation look-at: rotate the eye bone so its look axis points at `focal_world`.
func _aim_eye(idx: int, focal_world: Vector3) -> void:
	if idx < 0 or _face_eye_skel == null: return
	var eye_pos := _eye_world_pos(idx)
	var desired := (focal_world - eye_pos)
	if desired.length() < 1e-5: return
	desired = desired.normalized()
	var rest_basis_w := _eye_rest_basis_world(idx)
	var rest_fwd := (rest_basis_w * _eye_fwd_axis).normalized()
	var q := _quat_between(rest_fwd, desired)
	var target_basis_w := Basis(q) * rest_basis_w
	# world -> skeleton-space global pose basis -> bone-local (relative to parent)
	var target_in_skel := _face_eye_skel.global_transform.basis.inverse() * target_basis_w
	var parent := _face_eye_skel.get_bone_parent(idx)
	var parent_basis := (_face_eye_skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY)
	var local_basis := parent_basis.inverse() * target_in_skel
	_face_eye_skel.set_bone_pose_rotation(idx, local_basis.orthonormalized().get_rotation_quaternion())

func _quat_between(a: Vector3, b: Vector3) -> Quaternion:
	a = a.normalized(); b = b.normalized()
	var d := clampf(a.dot(b), -1.0, 1.0)
	if d > 0.99999: return Quaternion.IDENTITY
	if d < -0.99999:
		var ax := a.cross(Vector3(1, 0, 0))
		if ax.length() < 1e-4: ax = a.cross(Vector3(0, 1, 0))
		return Quaternion(ax.normalized(), PI)
	return Quaternion(a.cross(b).normalized(), acos(d))

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

# Intro reveal: show THIS character's MetaHuman reference overlay at full opacity, then fade
# it to zero over 3s — a soft "reference → live Godot character" cross-dissolve. Fired on
# launch and on every Guy/Gal switch. Reuses the aligned _overlay (stretch/scoot already
# applied by _apply_all) so the reference lines up with the render. No-op during headless
# capture/smoke so QA frames stay clean.
func _play_intro_reveal() -> void:
	if _overlay == null or not _overlay_available: return
	if OS.has_environment("RELEASE_CAPTURE") or OS.has_environment("RELEASE_SMOKE"): return
	if _intro_tween and _intro_tween.is_valid(): _intro_tween.kill()
	# Hold the eyes dead straight ahead for the whole reveal: "alive eyes" (saccadic darts +
	# look-at-camera convergence) would dart the live pupils off the static reference's pupils
	# mid-dissolve → a double-pupil ghost. Alive eyes resume when the fade ends (the callback).
	_intro_active = true
	_eyes_straight_ahead()
	_overlay.modulate = Color(1, 1, 1, 1.0)
	_intro_tween = create_tween()
	_intro_tween.tween_property(_overlay, "modulate:a", 0.0, INTRO_FADE_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_intro_tween.tween_callback(func(): _intro_active = false)

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
	# clip_contents keeps the controls inside the panel rect: when the resize handle
	# is dragged narrow (or the panel is collapsed to 0), content is clipped instead
	# of spilling across the 3D view. The AUTO horizontal scrollbar keeps every
	# control reachable at any width.
	_panel.clip_contents = true
	layer.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
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
	# Reset (camera/view) + Quit
	var rq := HBoxContainer.new()
	var resetbtn := Button.new(); resetbtn.text = "Reset view [R]"
	resetbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resetbtn.pressed.connect(_reset_orbit); rq.add_child(resetbtn)
	var quitbtn := Button.new(); quitbtn.text = "Quit [Esc]"
	quitbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quitbtn.pressed.connect(func(): get_tree().quit()); rq.add_child(quitbtn)
	vb.add_child(rq)
	_status = Label.new(); _status.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	vb.add_child(_status)

	_section(vb, "CAMERA  [R] = reset  LMB=orbit  RMB=pan  wheel=zoom")
	_orbit_slider(vb, "Orbit yaw",    func(v): _orbit_yaw = v,                           func(): return _orbit_yaw,   -180.0, 180.0, 0.5)
	_orbit_slider(vb, "Orbit pitch",  func(v): _orbit_pitch = clampf(v, -89.0, 89.0),    func(): return _orbit_pitch,  -89.0,  89.0, 0.5)
	_orbit_slider(vb, "Orbit dist",   func(v): _orbit_dist = v,                           func(): return _orbit_dist,    0.1,   6.0, 0.02)
	_orbit_slider(vb, "FOV",          func(v): _orbit_fov = v; if _camera: _camera.fov=v, func(): return _orbit_fov,    10.0,  90.0, 1.0)
	# Look-at target (the point the camera orbits) as explicit numbers — formerly only
	# reachable by RMB-pan. Together with yaw/pitch/dist/FOV this fully specifies the camera.
	_orbit_slider(vb, "Target X (m)", func(v): _orbit_target.x = v, func(): return _orbit_target.x, -2.0, 2.0, 0.005)
	_orbit_slider(vb, "Target Y (m)", func(v): _orbit_target.y = v, func(): return _orbit_target.y,  0.0, 2.5, 0.005)
	_orbit_slider(vb, "Target Z (m)", func(v): _orbit_target.z = v, func(): return _orbit_target.z, -2.0, 2.0, 0.005)
	_slider(vb, "dof_focus", "DOF focus (m)", 0.1, 8.0, 0.05)
	_slider(vb, "dof_blur",  "DOF blur",      0.0, 0.5, 0.005)
	# Animation toggles — these persist across character switches (set_pressed_no_signal +
	# a refresher so the box reflects the carried-over state after a swap).
	var tt_cb := CheckBox.new(); tt_cb.text = "Turntable (rotate character)"
	tt_cb.button_pressed = _turntable
	tt_cb.toggled.connect(func(on): _turntable = on)
	_style_checkbox(tt_cb); vb.add_child(tt_cb)
	_refreshers.append(func(): tt_cb.set_pressed_no_signal(_turntable))
	var hero_cb := CheckBox.new(); hero_cb.text = "Hero camera (ping-pong push-in)"
	hero_cb.button_pressed = _hero_cam
	hero_cb.toggled.connect(func(on): _set_hero_cam(on))
	_style_checkbox(hero_cb); vb.add_child(hero_cb)
	_refreshers.append(func(): hero_cb.set_pressed_no_signal(_hero_cam))
	var face_cb := CheckBox.new(); face_cb.text = "Face animation (emote)"
	face_cb.button_pressed = _face_anim_on
	face_cb.toggled.connect(func(on): _set_face_anim(on))
	_style_checkbox(face_cb); vb.add_child(face_cb)
	_refreshers.append(func(): face_cb.set_pressed_no_signal(_face_anim_on))
	var body_cb := CheckBox.new(); body_cb.text = "Body animation (idle + legs)"
	body_cb.button_pressed = _body_anim_on
	body_cb.toggled.connect(func(on): _set_body_anim(on))
	_style_checkbox(body_cb); vb.add_child(body_cb)
	_refreshers.append(func(): body_cb.set_pressed_no_signal(_body_anim_on))
	# Body-clip dropdown (Mixamo retargets: Idle/Sway/Walk/Turn/Wave/HappyIdle + the procedural
	# idle). Picking a clip switches it live (0.3s crossfade) and turns the body idle on.
	var dd_row := HBoxContainer.new()
	var dd_lab := Label.new(); dd_lab.text = "   clip"; dd_row.add_child(dd_lab)
	_body_anim_dd = OptionButton.new(); _body_anim_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_anim_dd.item_selected.connect(_on_body_anim_dd)
	dd_row.add_child(_body_anim_dd); vb.add_child(dd_row)
	_refresh_body_anim_dd()
	_refreshers.append(_refresh_body_anim_dd)
	# Lighting animation — same toggle group. When ON, the lighting stays ANIMATED (and
	# persists) across character switches; when OFF, lighting follows each character's preset.
	var lcyc_cb := CheckBox.new(); lcyc_cb.text = "Animate lighting (cycle colours)"
	lcyc_cb.button_pressed = _color_cycle
	lcyc_cb.toggled.connect(func(on): _set_color_cycle(on))
	_style_checkbox(lcyc_cb); vb.add_child(lcyc_cb)
	_refreshers.append(func(): lcyc_cb.set_pressed_no_signal(_color_cycle))

	_section(vb, "SCENE")
	_slider(vb, "model_yaw", "Model yaw", 0.0, 360.0, 0.5)
	_slider(vb, "view_pan", "View pan (subject X)", -1.0, 1.0, 0.01)
	_slider(vb, "overlay", "UE overlay opacity", 0.0, 1.0, 0.01)
	_slider(vb, "overlay_stretch_x", "Overlay stretch X (debug)", 0.9, 1.1, 0.001)
	_slider(vb, "overlay_off_x", "Overlay scoot X px (debug)", -1200.0, 1200.0, 5.0)
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
	# ("Animate lighting" toggle lives with the other animation toggles in the CAMERA section.)

	_section(vb, "SKIN (face + body)")
	_color(vb, "skin_tint", "Skin colour (tint)")
	_slider(vb, "skin_bright", "Skin lightness", 0.0, 2.5, 0.01)
	_slider(vb, "shadow_strength", "Shadow strength (hair on face)", 0.0, 1.0, 0.01)
	_slider(vb, "outfit_grow", "Outfit inflate (anti-poke)", 0.0, 1.0, 0.01)
	_slider(vb, "body_shrink", "Body tuck (anti-poke) m", 0.0, 0.02, 0.0005)
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
	# Show/hide ALL hair grooms for the current character (her: scalp bob; the guy: hair +
	# beard + mustache + eyebrow cards). Persists across character switches.
	var hair_cb := CheckBox.new(); hair_cb.text = "Show hair"
	hair_cb.button_pressed = _hair_visible
	hair_cb.toggled.connect(func(on): _set_hair_visible(on))
	_style_checkbox(hair_cb); vb.add_child(hair_cb)
	_refreshers.append(func(): hair_cb.set_pressed_no_signal(_hair_visible))
	# Opt-in hard hair rake — a grazing front-high shadow-caster that makes the hair throw a
	# crisp shadow onto the forehead/brow (most visible on her overhanging hairstyle). Off by
	# default so it never disturbs the ported moonlight rig.
	var rake_cb := CheckBox.new(); rake_cb.text = "Hair rake light (hairline shadow)"
	rake_cb.button_pressed = _rake_on
	rake_cb.toggled.connect(func(on): _set_rake(on))
	_style_checkbox(rake_cb); vb.add_child(rake_cb)
	_refreshers.append(func(): rake_cb.set_pressed_no_signal(_rake_on))
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

	_section(vb, "EYE GAZE — focal point")
	# Alive eyes = candid saccadic darts + blinks around the gaze target.
	var alive_cb := CheckBox.new()
	alive_cb.text = "Alive eyes (darts + blinks)"
	alive_cb.button_pressed = bool(p.eye_alive)
	var alive_toggle := func(on):
		p.eye_alive = on
		if not on: _set_blink(0.0); _blink_t = -1.0
	alive_cb.toggled.connect(alive_toggle)
	_style_checkbox(alive_cb); vb.add_child(alive_cb)
	_refreshers.append(func(): alive_cb.set_pressed_no_signal(bool(p.eye_alive)))
	# Look at camera = gaze target is the camera; also live-fills the focal fields below
	# with the camera position. Uncheck to take over from those values (e.g. look just
	# left of the lens).
	var lookcam_cb := CheckBox.new()
	lookcam_cb.text = "Look at camera (auto-fills focal below)"
	lookcam_cb.button_pressed = bool(p.eye_look_cam)
	lookcam_cb.toggled.connect(func(on): p.eye_look_cam = on)
	_style_checkbox(lookcam_cb); vb.add_child(lookcam_cb)
	_refreshers.append(func(): lookcam_cb.set_pressed_no_signal(bool(p.eye_look_cam)))
	# Manual focal point — the gaze target when "Look at camera" is OFF. Single look-at
	# point in the eye-midpoint frame: (0,0,0)=cross-eyed at the point between the eyes;
	# +Z ahead/depth, +X subject-right, +Y up. Both eyes converge on it.
	_focus_slider(vb, "eye_fx", "Focal X (m)", -1.0, 1.0, 0.005)
	_focus_slider(vb, "eye_fy", "Focal Y (m)", -1.0, 1.0, 0.005)
	_focus_slider(vb, "eye_fz", "Focal Z / depth (m)", -0.5, 5.0, 0.01)
	var abs_cb := CheckBox.new()
	abs_cb.text = "Absolute (world-locked gaze)"
	abs_cb.button_pressed = bool(p.eye_focus_abs)
	var abs_toggle := func(on):
		p.eye_focus_abs = on
		if on: _refreeze_abs_point()
		_update_eye_focus()
	abs_cb.toggled.connect(abs_toggle)
	_style_checkbox(abs_cb); vb.add_child(abs_cb)
	_refreshers.append(func(): abs_cb.set_pressed_no_signal(bool(p.eye_focus_abs)))

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
	_style_checkbox(cb); parent.add_child(cb)
	_refreshers.append(func(): cb.set_pressed_no_signal(bool(p[key])))

# Outline + subtle fill behind checkboxes so they read clearly against the 3D view.
func _style_checkbox(cb: CheckBox) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.17, 0.55)
	sb.border_color = Color(0.55, 0.60, 0.72, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6; sb.content_margin_right = 6
	sb.content_margin_top = 3; sb.content_margin_bottom = 3
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		cb.add_theme_stylebox_override(st, sb)

# Eye focal-point slider: like _slider but re-aims the eyes (and re-freezes the
# absolute world point) on change instead of calling _apply_all.
func _focus_slider(parent: Control, key: String, label: String, lo: float, hi: float, step: float) -> void:
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
	var on_change := func(v):
		p[key] = v
		if bool(p.eye_focus_abs): _refreeze_abs_point()
		_update_eye_focus()
	sl.value_changed.connect(func(v): on_change.call(v); spin.set_value_no_signal(v))
	spin.value_changed.connect(func(v): on_change.call(v); sl.set_value_no_signal(clampf(v, lo, hi)))
	_refreshers.append(func(): spin.set_value_no_signal(float(p[key])); sl.set_value_no_signal(clampf(float(p[key]), lo, hi)))
	_focus_ctrls[key] = {"spin": spin, "sl": sl}   # for live "look at camera" sync

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
	_bs_panel.visible = true   # ARKit panel shown by default (hidden during RELEASE_CAPTURE by _hide_chrome)
	_bs_panel.clip_contents = true
	layer.add_child(_bs_panel)
	_build_bs_handle(layer)
	_rebuild_bs_panel()

func _rebuild_bs_panel() -> void:
	if _bs_panel == null: return
	for c in _bs_panel.get_children(): c.queue_free()
	_bs_rows.clear()
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
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
	# eyeLook* are now driven by the single Eye Focal Point (in the main panel), so they
	# get no row here.
	if sname in EYE_LOOK_NAMES:
		return
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
		_set_left_width(_panel_prev_width if _panel_prev_width > 40.0 else 470.0)
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
	h.visible = true   # matches the panel default-on
	layer.add_child(h); _bs_handle = h
	var cb := Button.new(); cb.name = "BsCollapse"; cb.text = "››"
	cb.tooltip_text = "Collapse / expand the ARKit panel"
	cb.anchor_left = 1.0; cb.anchor_right = 1.0
	cb.offset_left = -_bs_width - 50.0; cb.offset_top = 12.0
	cb.offset_right = -_bs_width - 16.0; cb.offset_bottom = 40.0
	cb.pressed.connect(_toggle_bs_collapse)
	cb.visible = true   # matches the panel default-on
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
		# "Shadow strength" also scales screen-space AO so it deepens the hair/brow/nose CONTACT
		# onto the face (a screen-space crease, independent of light angle) — not just the cast
		# shadow_opacity below. This is what makes the slider read as "hair shadow on the face".
		_env.ssao_intensity = 0.6 + clampf(float(p.get("shadow_strength", 0.7)), 0.0, 1.0) * 0.9
	_apply_backdrop_color()
	var col_map := {"key": "key_col", "keyrect": "keyrect_col", "fill": "fill_col", "rim": "rim_col", "ambient": "amb_col"}
	for k in col_map.keys():
		if _lights.has(k):
			var L: Light3D = _lights[k]
			L.light_energy = p[k]; L.light_color = p[col_map[k]]
			# "Shadow strength" → shadow darkness on every shadow-casting light (this is
			# what actually makes hair/nose/brow cast onto the face). 0 = no shadow (flat).
			if L.shadow_enabled:
				L.shadow_opacity = clampf(float(p.get("shadow_strength", 0.7)), 0.0, 1.0)
	if _catch:
		_catch.light_energy = p.catch; _catch.light_color = p.catch_col
		if _camera:
			_catch.global_transform.origin = _camera.global_transform.origin + _camera.global_transform.basis.y * 0.12
	for m in _skin_mats:
		var b: float = float(p.get("skin_bright", 1.0))
		var t: Color = p.skin_tint
		m.set_shader_parameter("albedo", Color(t.r * b, t.g * b, t.b * b, 1.0))
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
		m.set_shader_parameter("vertex_shrink", 0.0)   # default: no shrink (face + any custom skin)
	# Body skin only: tuck it inward so its neck/clavicle hides under the bust cap + shirt.
	if _body_skin_mat and is_instance_valid(_body_skin_mat):
		_body_skin_mat.set_shader_parameter("vertex_shrink", float(p.get("body_shrink", 0.006)))
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
	for m in _outfit_mats:
		(m as StandardMaterial3D).grow_amount = float(p.get("outfit_grow", 0.006))
	if _character: _character.rotation.y = deg_to_rad(p.model_yaw)
	if _overlay:
		# While the intro reveal is mid-fade, the tween owns the alpha — don't stomp it.
		var oa: float = _overlay.modulate.a if (_intro_tween and _intro_tween.is_running()) else float(p.overlay)
		_overlay.modulate = Color(1, 1, 1, oa)
		# DEBUG overlay horizontal stretch: scale about the screen center so the UE
		# reference image can be matched to the (slightly narrower) Godot render.
		var sx: float = float(p.get("overlay_stretch_x", 1.0))
		var vp := get_viewport().get_visible_rect().size
		_overlay.pivot_offset = vp * 0.5
		_overlay.scale = Vector2(sx, 1.0)
		# Scoot the overlay sideways (px) so both faces sit side-by-side while tuning.
		var ox: float = float(p.get("overlay_off_x", 0.0))
		_overlay.offset_left = ox
		_overlay.offset_right = ox
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
	# Camera/orbit state lives outside p — persist it so alignment saves with the preset.
	out["cam_yaw"] = _orbit_yaw
	out["cam_pitch"] = _orbit_pitch
	out["cam_dist"] = _orbit_dist
	out["cam_fov"] = _orbit_fov
	out["cam_tx"] = _orbit_target.x
	out["cam_ty"] = _orbit_target.y
	out["cam_tz"] = _orbit_target.z
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
	# Outfit inflate is a per-CHARACTER geometric anti-poke correction, NOT a lighting look —
	# force the profile's value on every preset load so swapping lighting presets can never
	# reintroduce bust/shoulder skin poke-through. (A live tweak is still remembered per
	# character in the look memory until the next preset load.)
	p["outfit_grow"] = float(_profile.get("outfit_grow", p.get("outfit_grow", 0.006)))
	# Restore camera/orbit (only if the preset carries it — older presets won't).
	if data.has("cam_yaw"):   _orbit_yaw = float(data["cam_yaw"])
	if data.has("cam_pitch"): _orbit_pitch = float(data["cam_pitch"])
	if data.has("cam_dist"):  _orbit_dist = float(data["cam_dist"])
	if data.has("cam_fov"):   _orbit_fov = float(data["cam_fov"])
	if data.has("cam_tx"):    _orbit_target.x = float(data["cam_tx"])
	if data.has("cam_ty"):    _orbit_target.y = float(data["cam_ty"])
	if data.has("cam_tz"):    _orbit_target.z = float(data["cam_tz"])
	# Remember this as the STARTING camera so "Reset view" returns here.
	_start_orbit_yaw = _orbit_yaw; _start_orbit_pitch = _orbit_pitch
	_start_orbit_dist = _orbit_dist; _start_orbit_fov = _orbit_fov
	_start_orbit_target = _orbit_target
	if _camera and not OS.has_environment("RELEASE_CAPTURE"):
		_camera.fov = _orbit_fov; _update_orbit_camera()
	_refreeze_abs_point()
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
			KEY_ESCAPE: get_tree().quit()
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
			_orbit_dist = maxf(0.1, _orbit_dist - 0.08); _refresh_controls()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_dist = minf(10.0, _orbit_dist + 0.08); _refresh_controls()
	elif e is InputEventMouseMotion and _drag_mode > 0:
		var rel := (e as InputEventMouseMotion).relative
		if _drag_mode == 1:  # orbit
			_orbit_yaw -= rel.x * 0.35
			_orbit_pitch = clampf(_orbit_pitch + rel.y * 0.25, -89.0, 89.0)
			_refresh_controls()
		elif _drag_mode == 2:  # pan
			var right := _camera.global_transform.basis.x
			var up    := _camera.global_transform.basis.y
			_orbit_target -= right * rel.x * _orbit_dist * 0.002
			_orbit_target += up    * rel.y * _orbit_dist * 0.002
			_refresh_controls()   # keep the Orbit/Target sliders truthful while dragging

func _reset_orbit() -> void:
	# Return to the STARTING camera (the loaded preset's camera), not hardcoded defaults.
	_orbit_yaw = _start_orbit_yaw; _orbit_pitch = _start_orbit_pitch
	_orbit_dist = _start_orbit_dist; _orbit_target = _start_orbit_target
	_orbit_fov = _start_orbit_fov; if _camera: _camera.fov = _orbit_fov
	_refresh_controls()
	_update_orbit_camera()
