extends Node3D

# ──────────────────────────────────────────────────────────────────────────
# Interactive LOOK-DEV tool for the MetaHuman→Godot pilot.
#
# Live sliders + orbit camera so the skin / lighting / hair look can be dialed
# in by eye instead of the slow guess-and-render loop. Modeled on the
# @__microdancing reference (left slider panel exposing the MatMADNESS skin
# uniforms + a lighting setup), but broader.
#
# This is a SEPARATE scene from scenes/emote_render.gd (the render scene) and
# duplicates the material/light wiring so it never disturbs the render path.
# Slider keys map 1:1 to emote_render.gd's _envf() env-var names where they
# exist (SKIN_NRM, KEY, FILL, ...) so a dialed-in look saved here can be locked
# straight back into emote_render.gd's defaults.
#
# Launch (windowed, NOT --headless / NOT --write-movie):
#   Godot_v4.6 --path godot_project scenes/look_dev.tscn
#
# Controls:  LMB-drag = orbit · wheel = zoom · RMB/MMB-drag = pan
# Hit "Save settings" when happy → writes H:/Work01/MetaHumanGodot/look_settings.json
# ──────────────────────────────────────────────────────────────────────────

const CHARACTER_GLB: String = "res://character.glb"
const SETTINGS_FILE: String = "look_settings.json"
var _placeholder: bool = false   # true when no character.glb is present

# In-app credits / legal notice. Kept in sync with NOTICE.txt in the build.
const CREDITS_TEXT: String = """MetaHuman → Godot  •  Look-Dev

Tool and shaders: © 2026 Agile Lens — released under the MIT License.
Skin / eye shaders are based on MatMADNESS HumanShaders (MIT), which build on
RustyRoboticsBV/GodotStandardLightShader.

— Unreal Engine / MetaHuman —
MetaHuman Godot Look-Dev uses Unreal® Engine. Unreal® is a trademark or registered
trademark of Epic Games, Inc. in the United States of America and elsewhere.
Unreal® Engine, Copyright 1998 – 2026, Epic Games, Inc. All rights reserved.

Character created with Epic Games' MetaHuman framework. MetaHuman is a trademark or
registered trademark of Epic Games, Inc. This project and Agile Lens are not
affiliated with, sponsored by, or endorsed by Epic Games, Inc.

MetaHuman character and animation assets are "Non-Engine Products" under the Unreal
Engine EULA (https://www.unrealengine.com/eula/unreal) and are distributed here
royalty-free; the MIT license covers only the tool/code, not the character.

You may NOT use the MetaHuman characters/animation in this build to build or enhance
any dataset, or to train or test any AI / machine-learning system, nor extract them
for incorporation into other products."""

var _credits_panel: Control

const HIDE_SLOT_PATTERNS: Array = ["eyeshell", "lacrimal", "m_hide", "mi_hide"]

# ── Held live references (slider callbacks poke these directly) ─────────────
var skin_mats: Array[ShaderMaterial] = []        # [face, body] — skin sliders mirror to both
var hair_scalp_cards: Array[ShaderMaterial] = []
var hair_scalp_backing: Array[ShaderMaterial] = []
var hair_beard_cards: Array[ShaderMaterial] = []
var hair_brow_cards: Array[ShaderMaterial] = []

var key_light: DirectionalLight3D
var fill_light: DirectionalLight3D
var rim_light: DirectionalLight3D
var catch_light: OmniLight3D
var env: Environment
var backdrop_mat: StandardMaterial3D
var camera: Camera3D
var cam_attrs: CameraAttributesPractical

# Light orientation state (deg) — yaw/pitch sliders rebuild the rotation.
# Defaults baked from Sam's saved look_settings.json (2026-05-31).
var key_yaw: float = -81.0
var key_pitch: float = -30.0
var fill_yaw: float = 21.0
var fill_pitch: float = 13.0
var rim_yaw: float = 51.0
var rim_pitch: float = -45.0

# Backdrop tint/brightness state.
var backdrop_tint: Color = Color("420043")
var backdrop_bright: float = 2.0

# DOF state.
var dof_enabled: bool = true
var dof_focus: float = 1.33
var dof_blur: float = 0.085

# ── Orbit camera rig ───────────────────────────────────────────────────────
# Default framing baked from Sam's saved camera.
const DEFAULT_CAM_TARGET: Vector3 = Vector3(0.0, 1.74, 0.0)  # aim higher → crown in frame
const DEFAULT_CAM_YAW: float = -21.35
const DEFAULT_CAM_PITCH: float = 6.5
const DEFAULT_CAM_DIST: float = 1.0
var orbit_target: Vector3 = DEFAULT_CAM_TARGET
var orbit_yaw: float = DEFAULT_CAM_YAW      # deg
var orbit_pitch: float = DEFAULT_CAM_PITCH  # deg
var orbit_dist: float = DEFAULT_CAM_DIST    # m
var _drag_mode: int = 0          # 0 none · 1 orbit · 2 pan
var auto_turntable: bool = false

# ── Character / animation / hero-camera state ───────────────────────────────
var _character: Node3D
const TURNTABLE_SPEED: float = 18.0          # deg/s — turntable spins the MODEL
# Face emote + body idle (ported from emote_render.gd; off until toggled).
var _anim_playing: bool = false
var _face_anim_player: AnimationPlayer
var _body_anim_player: AnimationPlayer
# Runtime LeaderPose seam fix (ported from emote_render.gd / release.gd 2026-06-02; see
# memory reference-godot-leaderpose-seam-fix). character.glb has TWO skeletons: the BODY
# skeleton (metahuman_base_skel) drives body+outfit; a SEPARATE FACE skeleton (carries the
# FACIAL_* bones) skins the face mesh = head + neck + bust-cap. The body idle animates ONLY
# the body skeleton. The OLD code rigidly slaved the whole FaceArmature NODE to the body
# 'head' bone, which rode the bust-cap UP through the shirt collar while the body chest stayed
# put → a pale seam. The fix emulates UE's SetLeaderPoseComponent: each frame we drive every
# bone the FACE skel SHARES by name with the BODY skel so the neck/clavicle/bust deforms WITH
# the body (seam stays glued) while the head still bobs with the head bone. The FaceArmature
# NODE is left at its bind transform and FACIAL_* bones stay at rest, so the blend-shape emote
# + eyes are untouched. The two rigs were separate FBX exports, so shared-bone LOCAL rest frames
# differ up to 180° — so we transfer motion through GLOBAL poses, NOT a local copy:
#   desired face global  PFg = PBg · rest_xfer,  rest_xfer = RBg⁻¹ · RFg  (each rig's own rest
# global, precomputed per shared bone). The bone math is skeleton-local, so the turntable composes.
var body_skeleton: Skeleton3D
var head_bone_idx_body: int = -1
# Drift-free head-world reconstruction (for the catchlight + hero-cam aim): the body skeleton's
# Node3D transform DRIFTS during the root-motion idle (its position is animated while the bone
# poses compensate), so we rebuild the head world pos from the bind-time skeleton transform.
var skel_basis_norm: Basis = Basis.IDENTITY
var skel_scale_factor: float = 1.0
var skel_bind_origin: Vector3 = Vector3.ZERO
var _face_skel: Skeleton3D                 # the face mesh's skeleton (the one with FACIAL_L_Eye)
var _leader_pairs: Array = []              # [body_idx, face_idx, face_parent_idx, rest_xfer], parent-first
# Hero camera (wide→close push-in, ping-pong). Independent of the turntable.
var _hero_cam: bool = false
var _hero_elapsed: float = 0.0
const HERO_DURATION: float = 15.0     # 1/3 the previous speed
const HERO_WIDE_POS: Vector3 = Vector3(0.0, 1.25, 4.3)    # full body
const HERO_CLOSE_POS: Vector3 = Vector3(0.08, 1.74, 0.50) # tight face
const HERO_WIDE_FOV: float = 40.0
const HERO_CLOSE_FOV: float = 24.0
const HERO_WIDE_AIM: Vector3 = Vector3(0.0, 1.02, 0.0)    # aim mid-body when wide
var _head_world: Vector3 = Vector3(0.0, 1.78, 0.05)

# Face emote keyposes (ported from emote_render.gd).
# Softened from emote_render's dramatic performance — full mouthSmile (1.0) reads
# grotesque on a close-up; ~0.5 is a natural smile. Tracks use LINEAR interp so
# cubic overshoot can't push lip shapes past their valid range.
const KEYPOSES: Dictionary = {
	"neutral": {},
	"smile": {"mouthSmileLeft": 0.5, "mouthSmileRight": 0.5, "cheekSquintLeft": 0.18, "cheekSquintRight": 0.18},
	"surprise": {"jawOpen": 0.38, "browInnerUp": 0.65, "browOuterUpLeft": 0.5, "browOuterUpRight": 0.5, "eyeWideLeft": 0.55, "eyeWideRight": 0.55, "mouthFunnel": 0.18},
	"blink": {"eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0},
	"frown": {"mouthFrownLeft": 0.5, "mouthFrownRight": 0.5, "browDownLeft": 0.45, "browDownRight": 0.45, "mouthLowerDownLeft": 0.18, "mouthLowerDownRight": 0.18},
}
const KEY_TIMES: Array = [
	[0.0, "neutral"], [0.7, "smile"], [1.9, "neutral"], [2.5, "surprise"],
	[3.5, "neutral"], [3.9, "blink"], [4.3, "frown"], [5.0, "neutral"], [5.7, "smile"], [8.2, "smile"],
]
const ANIM_DURATION: float = 8.4

# Per-control default registry (for the small reset button on each setting).
var _defaults: Dictionary = {}

# Collapsible/resizable left panel.
var _panel: PanelContainer
var _panel_vb: VBoxContainer
var _panel_handle: Panel
var _panel_width: float = 400.0
var _panel_prev_width: float = 400.0
var _panel_dragging: bool = false
var _panel_collapse_btn: Button
var _orbit_fov: float = 28.0

# ── Save/Load registry ─────────────────────────────────────────────────────
var _savers: Dictionary = {}     # key -> Callable() returning Variant
var _loaders: Dictionary = {}    # key -> Callable(Variant)

# ── Headless-ish verification capture (LOOKDEV_CAPTURE env = path prefix) ────
# Runs windowed (needs a GPU framebuffer), grabs two viewport stills — one at
# defaults, one after driving sliders through their registered loaders — then
# quits. Proves the render builds AND that the slider→material/light binding is
# live. Not used in normal interactive operation.
var _cap_prefix: String = ""
var _cap_frame: int = 0

# ── UI / capture state ──────────────────────────────────────────────────────
var _ui_layer: CanvasLayer
var _hint_layer: CanvasLayer
var _toast_label: Label
var _toast_until: float = 0.0
var _time: float = 0.0

# Movie (turntable) recording state.
var _movie_recording: bool = false
var _movie_frame: int = 0
var _movie_total: int = 144
var _movie_dir: String = ""
var _movie_stamp: String = ""
var _movie_start_yaw: float = 0.0
var _prev_scale_3d: float = 1.0   # restore after capture-time supersampling

const ASSEMBLE_PY: String = """
import cv2, os, sys, glob
d, out = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, 'f*.png')))
if not files:
    sys.exit(2)
img = cv2.imread(files[0]); h, w = img.shape[:2]
for cc in ('avc1', 'mp4v'):
    vw = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*cc), 30, (w, h))
    if vw.isOpened():
        break
for f in files:
    vw.write(cv2.imread(f))
vw.release()
print('wrote', out, w, 'x', h, len(files), 'frames')
"""


func _ready() -> void:
	_setup_environment()
	_setup_backdrop()
	_setup_reflection()
	_setup_lights()
	_setup_camera()
	var root: Node3D = _instantiate_character()
	if root == null:
		push_error("[look_dev] failed to load character GLB")
		return
	_character = root
	_apply_materials(root)
	_find_body_anim_player(root)
	_stop_animations(root)
	if not _placeholder:
		await get_tree().process_frame      # let the stop settle before binding
		_resolve_body_skeleton(root)
		_capture_head_world_ref()           # head-bone world ref for the catchlight + hero cam
		_resolve_face_skeleton(root)        # the FACIAL_* (face mesh) skeleton
		_build_leader_pose_map()            # seam fix: shared body↔face bones for the LeaderPose copy
		_build_face_animation(root)
	_build_ui()
	_setup_window_icon()
	_update_orbit_camera()
	# Auto-load a previously dialed-in look if one exists.
	if not OS.has_environment("NO_LOAD_SETTINGS"):
		_load_settings()
	if OS.has_environment("LOOKDEV_CAPTURE"):
		_cap_prefix = OS.get_environment("LOOKDEV_CAPTURE")
		print("[look_dev] CAPTURE MODE → ", _cap_prefix)
	if OS.has_environment("LOOKDEV_MOVIETEST"):
		_run_movie_selftest()


func _process(delta: float) -> void:
	_time += delta
	if _toast_label and _toast_until > 0.0 and _time > _toast_until:
		_toast_label.visible = false
		_toast_until = 0.0
	# Turntable spins the MODEL (not the camera), so it composes with the hero cam.
	if auto_turntable and _character:
		_character.rotation.y += deg_to_rad(TURNTABLE_SPEED) * delta

	# Runtime LeaderPose (collar-seam fix). While the body idle plays, drive every bone the FACE
	# skeleton shares with the animated BODY skeleton so the neck/clavicle/bust-cap deforms WITH
	# the body (closing the collar seam) while the head still bobs with the head bone. The
	# FaceArmature NODE stays at its bind transform; FACIAL_* bones (incl. the eyes) stay at rest
	# so the blend-shape emote is untouched. The bone math is skeleton-local, so the character's
	# (turntable) rotation composes for free — no need to fold _character.global_transform in.
	if _anim_playing and not _placeholder and body_skeleton and head_bone_idx_body >= 0:
		# Drift-free head-world reconstruction (the catchlight + hero cam aim at the real face).
		var head_local_pose: Transform3D = body_skeleton.get_bone_global_pose(head_bone_idx_body)
		var head_world_origin: Vector3 = skel_bind_origin + skel_basis_norm * (head_local_pose.origin * skel_scale_factor)
		_head_world = _character.global_transform * head_world_origin
		# Glue the face mesh to the body via the per-bone LeaderPose copy.
		if _face_skel != null and not _leader_pairs.is_empty():
			_apply_leader_pose()

	# Camera: hero push-in (ping-pong) or the user-driven orbit.
	if _hero_cam:
		_hero_elapsed += delta
		_update_hero_camera()

	# Catchlight rides just off the camera axis, a frontal eye spark.
	if catch_light and camera:
		var aim: Vector3 = _head_world if (_anim_playing or _hero_cam) else orbit_target
		var to_cam: Vector3 = (camera.global_position - aim)
		if to_cam.length() > 0.001:
			catch_light.position = aim + to_cam.normalized() * 0.5 + Vector3(0.08, 0.24, 0.0)

	if _cap_prefix != "":
		_capture_tick()


func _capture_tick() -> void:
	_cap_frame += 1
	if OS.has_environment("LOOKDEV_README"):
		# Generate README images: clean portrait, UI screenshot, animated smile.
		if _cap_frame == 20:
			_ui_layer.visible = false
			if _hint_layer: _hint_layer.visible = false
		elif _cap_frame == 26:
			_grab("%s_clean.png" % _cap_prefix)
			_ui_layer.visible = true
		elif _cap_frame == 32:
			_grab("%s_ui.png" % _cap_prefix)
		elif _cap_frame == 36:
			_set_anim_playing(true)
			if _face_anim_player: _face_anim_player.speed_scale = 0.0
		elif _cap_frame == 40:
			if _face_anim_player: _face_anim_player.seek(5.9, true)
			_ui_layer.visible = false
		elif _cap_frame == 46:
			_grab("%s_smile.png" % _cap_prefix)
		elif _cap_frame == 52:
			print("[look_dev] readme shots done, quitting")
			get_tree().quit()
		return
	if OS.has_environment("LOOKDEV_ANIMTEST"):
		# Freeze the face anim and sample the worst-case poses (held smile, surprise).
		if _cap_frame == 8:
			_set_anim_playing(true)
			if _face_anim_player:
				_face_anim_player.speed_scale = 0.0
		elif _cap_frame == 12:
			if _face_anim_player: _face_anim_player.seek(5.9, true)
		elif _cap_frame == 16:
			_grab("%s_smile.png" % _cap_prefix)
		elif _cap_frame == 20:
			if _face_anim_player: _face_anim_player.seek(2.6, true)
		elif _cap_frame == 24:
			_grab("%s_surprise.png" % _cap_prefix)
		elif _cap_frame == 28:
			print("[look_dev] animtest done, quitting")
			get_tree().quit()
		return
	if OS.has_environment("LOOKDEV_SEAMTEST"):
		# Collar-seam regression for the LeaderPose fix: body idle ON, frame the collar, freeze
		# the idle at two head-bob extremes (seek 1.6 & 4.4 — the worst-case phases from the
		# release verification) and confirm the bust-cap stays glued (no seam, no neck gap) while
		# the head pose visibly differs between seeks; then a face-framed smile to prove the emote
		# + eyes are untouched. DOF off for a sharp collar; the default look-dev key/fill read it.
		if _cap_frame == 6:
			_set_anim_playing(true)
			if _body_anim_player: _body_anim_player.speed_scale = 0.0
			if _face_anim_player: _face_anim_player.speed_scale = 0.0
			_ui_layer.visible = false
			if _hint_layer: _hint_layer.visible = false
			dof_enabled = false
			# Brighten so the dark collar reads (mirrors the release seam recipe: exposure 1.7,
			# ambient 0.7). Zero-cost interactively — only the LOOKDEV_SEAMTEST path sets these.
			if env:
				env.tonemap_exposure = 1.7
				env.ambient_light_energy = 0.7
			# Frontal-ish, aimed at the neckline (look_dev's model faces ~yaw -21, its default
			# portrait direction). Slight downward tilt reads the collar line where a poking
			# bust-cap sliver would show.
			orbit_yaw = -21.0
			orbit_pitch = 4.0
			orbit_dist = 0.85
			orbit_target = Vector3(0.0, 1.50, 0.0)
			_set_fov(30.0)
			_update_orbit_camera()
		elif _cap_frame == 10:
			if _body_anim_player: _body_anim_player.seek(1.6, true)
		elif _cap_frame == 14:
			_grab("%s_seam_seek16.png" % _cap_prefix)
		elif _cap_frame == 18:
			if _body_anim_player: _body_anim_player.seek(4.4, true)
		elif _cap_frame == 22:
			_grab("%s_seam_seek44.png" % _cap_prefix)
		elif _cap_frame == 26:
			# Face-framed smile — the LeaderPose copy must leave FACIAL_* bones + blend shapes alone.
			if _body_anim_player: _body_anim_player.seek(0.0, true)   # head upright for the face beauty shot
			orbit_yaw = -16.0
			orbit_pitch = 2.0
			orbit_dist = 0.78
			orbit_target = Vector3(0.0, 1.70, 0.0)
			_set_fov(32.0)
			_update_orbit_camera()
			if _face_anim_player: _face_anim_player.seek(5.9, true)
		elif _cap_frame == 30:
			_grab("%s_seam_emote.png" % _cap_prefix)
		elif _cap_frame == 34:
			print("[look_dev] seamtest done, quitting")
			get_tree().quit()
		return
	if _cap_frame == 24:
		_grab("%s_a.png" % _cap_prefix)
	elif _cap_frame == 30:
		# Drive sliders through their registered loaders (the exact slider path)
		# so the second still must differ if the binding is live.
		_loaders["KEY"].call(0.3)
		_loaders["AMBIENT"].call(0.0)
		_loaders["FILL"].call(0.0)
		_loaders["SKIN_NRM"].call(4.0)
		_loaders["hair_scalp_color"].call("ff2200")
		orbit_yaw = 40.0
		orbit_dist = 0.7
		_update_orbit_camera()
	elif _cap_frame == 54:
		_grab("%s_b.png" % _cap_prefix)
	elif _cap_frame == 60:
		print("[look_dev] capture done, quitting")
		get_tree().quit()


func _grab(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(path)
	print("[look_dev] grabbed %s (err %d, %dx%d)" % [path, err, img.get_width(), img.get_height()])


# ════════════════════════════════════════════════════════════════════════════
# Scene construction (duplicated from emote_render.gd, refs held for live edit)
# ════════════════════════════════════════════════════════════════════════════

func _envf(name: String, def: float) -> float:
	return float(OS.get_environment(name)) if OS.has_environment(name) else def


func _instantiate_character() -> Node3D:
	# Public "bring your own MetaHuman" build: the MH character assets are NOT
	# distributed (gitignored). If character.glb is absent, fall back to a simple
	# placeholder so the tool still launches and the skin/lighting sliders are
	# demonstrable. Drop your own export at res://character.glb to use the full rig.
	if OS.has_environment("FORCE_PLACEHOLDER") or not ResourceLoader.exists(CHARACTER_GLB):
		push_warning("[look_dev] %s not found — showing placeholder (bring your own MetaHuman)" % CHARACTER_GLB)
		return _make_placeholder()
	var scene: PackedScene = load(CHARACTER_GLB)
	if scene == null:
		push_warning("[look_dev] failed to load %s — showing placeholder" % CHARACTER_GLB)
		return _make_placeholder()
	var inst: Node = scene.instantiate()
	inst.name = "Character"
	add_child(inst)
	return inst as Node3D


func _make_placeholder() -> Node3D:
	_placeholder = true
	var c: Node3D = Node3D.new()
	c.name = "Character"
	add_child(c)
	# Head — a sphere wearing the real MatMADNESS skin shader (flat fleshtone, no
	# MH textures) so the Skin + Lighting + Environment sliders all visibly work.
	var head: MeshInstance3D = MeshInstance3D.new()
	head.name = "PlaceholderHead"
	var sm: SphereMesh = SphereMesh.new()
	sm.radius = 0.115
	sm.height = 0.27
	head.mesh = sm
	head.position = Vector3(0.0, 1.66, 0.0)
	var skin: ShaderMaterial = _make_placeholder_skin()
	head.material_override = skin
	skin_mats.append(skin)
	c.add_child(head)
	# Torso — neutral capsule so the figure reads as a bust.
	var torso: MeshInstance3D = MeshInstance3D.new()
	torso.name = "PlaceholderTorso"
	var cap: CapsuleMesh = CapsuleMesh.new()
	cap.radius = 0.16
	cap.height = 0.62
	torso.mesh = cap
	torso.position = Vector3(0.0, 1.28, 0.0)
	var tm: StandardMaterial3D = StandardMaterial3D.new()
	tm.albedo_color = Color(0.10, 0.11, 0.14)
	tm.roughness = 0.85
	torso.material_override = tm
	c.add_child(torso)
	return c


func _make_placeholder_skin() -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_local.gdshader") as Shader
	mat.set_shader_parameter("texture_albedo", _solid_tex(Color(1, 1, 1)))
	mat.set_shader_parameter("albedo", Color(0.86, 0.62, 0.50))   # fleshtone tint
	mat.set_shader_parameter("texture_normal", _solid_tex(Color(0.5, 0.5, 1.0)))
	mat.set_shader_parameter("texture_roughness", _solid_tex(Color(1, 1, 1)))
	mat.set_shader_parameter("normal_strength", 1.0)
	mat.set_shader_parameter("roughness", 0.55)
	mat.set_shader_parameter("specular", 0.4)
	mat.set_shader_parameter("double_specularity", false)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	mat.set_shader_parameter("subsurface_scattering_strength", 0.34)
	mat.set_shader_parameter("skin_smoothness", 1.2)
	mat.set_shader_parameter("skin_fallof_smoothness", 1.05)
	mat.set_shader_parameter("old_lightwarp_fallof", false)
	mat.set_shader_parameter("tinted_shadow_penumbra", true)  # warm fleshy terminator (microdancing look)
	mat.set_shader_parameter("use_micro_detail", false)
	mat.set_shader_parameter("micro_normal_strength", 0.0)
	mat.set_shader_parameter("use_ambient_occlusion", false)
	mat.set_shader_parameter("translucency", false)
	mat.set_shader_parameter("use_scatter_map", false)
	mat.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv1_offset", Vector3(0, 0, 0))
	mat.set_shader_parameter("uv2_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv2_offset", Vector3(0, 0, 0))
	return mat


func _solid_tex(col: Color) -> ImageTexture:
	var img: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return ImageTexture.create_from_image(img)


func _stop_animations(root: Node) -> void:
	# Hold the figure static at the native bind pose (neutral face, no idle drift)
	# so the look can be judged on a stable frame. Body static → the face system
	# is already correct at its GLB bind position (no runtime face-follow needed).
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			(n as AnimationPlayer).stop()
		for c in n.get_children():
			stack.append(c)


func _setup_environment() -> void:
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.05, 0.07, 0.12)
	sky_mat.sky_horizon_color = Color(0.06, 0.08, 0.12)
	sky_mat.ground_horizon_color = Color(0.04, 0.04, 0.05)
	sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)
	sky_mat.sun_angle_max = 1.0
	sky_mat.energy_multiplier = 0.6
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.07
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.82
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.2
	env.ssao_power = 1.5
	env.ssr_enabled = false
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.10
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.05
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.10
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	we.name = "WorldEnvironment"
	add_child(we)


func _setup_backdrop() -> void:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.20, 0.19, 0.17))
	grad.add_point(0.5, Color(0.10, 0.10, 0.10))
	grad.set_color(1, Color(0.035, 0.037, 0.043))
	var tex: GradientTexture2D = GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 1024
	tex.height = 1024
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.30)
	tex.fill_to = Vector2(0.92, 0.78)
	backdrop_mat = StandardMaterial3D.new()
	backdrop_mat.albedo_texture = tex
	backdrop_mat.albedo_color = Color(1, 1, 1)
	backdrop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backdrop_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var plane: MeshInstance3D = MeshInstance3D.new()
	plane.name = "Backdrop"
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(7.0, 7.0)
	plane.mesh = quad
	plane.material_override = backdrop_mat
	plane.position = Vector3(0.0, 1.35, -2.0)
	add_child(plane)


func _setup_reflection() -> void:
	# Off-camera emissive softbox (render layer 2, excluded from the camera) +
	# a ReflectionProbe so the eyes get a real corneal catchlight.
	var sb: MeshInstance3D = MeshInstance3D.new()
	sb.name = "Softbox"
	var q: QuadMesh = QuadMesh.new()
	q.size = Vector2(1.4, 0.9)
	sb.mesh = q
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1, 1, 1)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.98, 0.95)
	m.emission_energy_multiplier = 14.0
	sb.material_override = m
	sb.layers = 1 << 1
	sb.position = Vector3(0.35, 2.35, 0.95)
	add_child(sb)
	sb.look_at(Vector3(0.0, 1.80, 0.05), Vector3.UP)

	var probe: ReflectionProbe = ReflectionProbe.new()
	probe.name = "ReflProbe"
	probe.size = Vector3(5.0, 5.0, 5.0)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.intensity = 2.6
	probe.max_distance = 10.0
	probe.position = Vector3(0.0, 1.6, 0.0)
	add_child(probe)


func _setup_lights() -> void:
	key_light = DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.light_energy = 3.6
	key_light.light_color = Color(1.0, 0.90, 0.76)
	key_light.shadow_enabled = true
	key_light.shadow_bias = 0.04
	key_light.shadow_normal_bias = 2.0
	key_light.shadow_blur = 3.5
	key_light.light_angular_distance = 4.5
	key_light.rotation = Vector3(deg_to_rad(key_pitch), deg_to_rad(key_yaw), 0.0)
	add_child(key_light)

	rim_light = DirectionalLight3D.new()
	rim_light.name = "RimLight"
	rim_light.light_energy = 3.5
	rim_light.light_specular = 0.25
	rim_light.light_color = Color(0.34, 0.58, 1.0)
	rim_light.shadow_enabled = false
	rim_light.rotation = Vector3(deg_to_rad(rim_pitch), deg_to_rad(rim_yaw), 0.0)
	add_child(rim_light)

	fill_light = DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.light_energy = 1.0
	fill_light.light_color = Color(0.26, 0.50, 1.0)
	fill_light.shadow_enabled = false
	fill_light.rotation = Vector3(deg_to_rad(fill_pitch), deg_to_rad(fill_yaw), 0.0)
	add_child(fill_light)

	catch_light = OmniLight3D.new()
	catch_light.name = "CatchLight"
	catch_light.light_energy = 0.12
	catch_light.light_color = Color(1.0, 0.97, 0.93)
	catch_light.light_specular = 1.0
	catch_light.shadow_enabled = false
	catch_light.omni_range = 1.5
	catch_light.omni_attenuation = 2.6
	catch_light.position = Vector3(0.10, 1.80, 1.10)
	add_child(catch_light)


func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.near = 0.05
	camera.far = 50.0
	camera.current = true
	camera.fov = 28.0
	camera.cull_mask = 1048575 & ~(1 << 1)
	cam_attrs = CameraAttributesPractical.new()
	cam_attrs.dof_blur_far_enabled = false
	cam_attrs.dof_blur_far_distance = 0.9
	cam_attrs.dof_blur_far_transition = 0.6
	cam_attrs.dof_blur_amount = 0.12
	camera.attributes = cam_attrs
	add_child(camera)


# ── Material wiring ─────────────────────────────────────────────────────────

func _collect_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, out)


func _apply_materials(root: Node) -> void:
	if _placeholder:
		return   # placeholder already wired its own materials
	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(root, mesh_instances)
	print("[look_dev] found %d mesh instances" % mesh_instances.size())

	for mi in mesh_instances:
		if mi.mesh == null:
			continue
		if mi.name.begins_with("Icosphere"):
			mi.queue_free()
			continue
		if mi.name == "MetaHumanFace":
			_apply_face_by_index(mi)

	# Hair / groom cards ----------------------------------------------------
	# [prefix, atlas, hair_color, invert_mask, threshold, root_darken, use_red_mask]
	var card_atlases: Array = [
		["Hair_",      "res://hair_attr.png",     Color(0.34, 0.27, 0.17), false, 0.070, 0.42, true],
		["Beard_",     "res://beard_attr.png",    Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
		["Eyebrows_",  "res://eyebrows_attr.png", Color(0.22, 0.16, 0.095), false, 0.060, 0.50, true],
		["Mustache_",  "res://mustache_attr.png", Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
		["Moustache_", "res://mustache_attr.png", Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
	]
	var hair_shader: Shader = load("res://scenes/hair_card.gdshader") as Shader
	for mi in mesh_instances:
		if mi.mesh == null:
			continue
		var match_idx: int = -1
		for i in range(card_atlases.size()):
			if mi.name.begins_with(card_atlases[i][0]):
				match_idx = i
				break
		if match_idx < 0:
			continue
		var entry: Array = card_atlases[match_idx]
		var atlas_path: String = entry[1]
		if not ResourceLoader.exists(atlas_path):
			push_warning("[look_dev] card atlas not found: %s" % atlas_path)
			continue
		var card_mat: ShaderMaterial = ShaderMaterial.new()
		card_mat.shader = hair_shader
		card_mat.set_shader_parameter("hair_color", entry[2])
		card_mat.set_shader_parameter("coverage_atlas", load(atlas_path) as Texture2D)
		card_mat.set_shader_parameter("invert_mask", entry[3])
		card_mat.set_shader_parameter("alpha_threshold", entry[4])
		card_mat.set_shader_parameter("root_darkening", entry[5])
		card_mat.set_shader_parameter("use_red_mask", entry.size() > 6 and entry[6])
		card_mat.set_shader_parameter("roughness_val", 0.72)
		card_mat.set_shader_parameter("specular_val", 0.12)
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, card_mat)
		# Register the card mat to its slider group.
		var pfx: String = entry[0]
		if pfx == "Hair_":
			hair_scalp_cards.append(card_mat)
		elif pfx == "Eyebrows_":
			hair_brow_cards.append(card_mat)
		else:
			hair_beard_cards.append(card_mat)

		# Scalp hair only: solid backing shell so the bald scalp never shows.
		if mi.name.begins_with("Hair_"):
			var back_mat: ShaderMaterial = ShaderMaterial.new()
			back_mat.shader = load("res://scenes/hair_backing.gdshader") as Shader
			back_mat.set_shader_parameter("hair_color", Color(0.20, 0.155, 0.090))
			back_mat.set_shader_parameter("coverage_atlas", load(atlas_path) as Texture2D)
			back_mat.set_shader_parameter("use_red_mask", entry.size() > 6 and entry[6])
			back_mat.set_shader_parameter("cutoff", 0.035)
			back_mat.set_shader_parameter("inset", 0.009)
			var backing: MeshInstance3D = MeshInstance3D.new()
			backing.name = mi.name + "_Backing"
			backing.mesh = mi.mesh
			for s in range(mi.mesh.get_surface_count()):
				backing.set_surface_override_material(s, back_mat)
			mi.add_sibling(backing)
			backing.global_transform = mi.global_transform
			hair_scalp_backing.append(back_mat)

	# Body skin -------------------------------------------------------------
	for mi in mesh_instances:
		if mi.mesh == null or mi.name != "Body":
			continue
		var body_mat: ShaderMaterial = _make_skin_shader_material(
			"res://character_T_Body_BC_VT.png",
			"res://character_T_Body_N_VT.png",
			"res://character_T_Body_SRMF_VT.png",
			"res://T_Body_Scatter_VT.png")
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, body_mat)
		skin_mats.append(body_mat)

	# Outfit / shirt / pants ------------------------------------------------
	for mi in mesh_instances:
		if mi.mesh == null:
			continue
		if mi.name == "Outfit":
			var om: StandardMaterial3D = _make_outfit_material()
			for s in range(mi.mesh.get_surface_count()):
				mi.set_surface_override_material(s, om)
		elif mi.name.begins_with("Shirt"):
			var sm: StandardMaterial3D = _make_shirt_material()
			for s in range(mi.mesh.get_surface_count()):
				mi.set_surface_override_material(s, sm)
		elif mi.name.begins_with("Pants"):
			var pm: StandardMaterial3D = _make_pants_material()
			for s in range(mi.mesh.get_surface_count()):
				mi.set_surface_override_material(s, pm)


func _apply_face_by_index(mi: MeshInstance3D) -> void:
	var face_mat: ShaderMaterial = _make_skin_shader_material(
		"res://character_T_Head_LOD1_BC_VT.png",
		"res://character_T_Head_LOD1_N_VT.png",
		"res://character_T_Head_LOD1_SRMF_VT.png",
		"res://T_Head_LOD1_Scatter_VT.png")
	# Face skin goes first so skin_mats[0] is the face (sliders read it for defaults).
	skin_mats.append(face_mat)

	var teeth_mat: StandardMaterial3D = StandardMaterial3D.new()
	if ResourceLoader.exists("res://character_T_Teeth_BC.png"):
		teeth_mat.albedo_texture = load("res://character_T_Teeth_BC.png") as Texture2D
	teeth_mat.albedo_color = Color(0.95, 0.93, 0.88)
	if ResourceLoader.exists("res://character_T_Teeth_N.png"):
		teeth_mat.normal_enabled = true
		teeth_mat.normal_texture = load("res://character_T_Teeth_N.png") as Texture2D
	teeth_mat.roughness = 0.35
	teeth_mat.metallic = 0.0

	var hide_mat: StandardMaterial3D = StandardMaterial3D.new()
	hide_mat.albedo_color = Color(0, 0, 0, 0)
	hide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hide_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var eye_mat_r: ShaderMaterial = _make_eye_material("_r")
	var eye_mat_l: ShaderMaterial = _make_eye_material("_l")

	var per_surface: Dictionary = {
		0: face_mat, 1: teeth_mat, 2: hide_mat, 3: eye_mat_r, 4: eye_mat_l,
		5: hide_mat, 6: hide_mat, 7: face_mat, 8: hide_mat,
	}
	for s in range(mi.mesh.get_surface_count()):
		if per_surface.has(s):
			mi.set_surface_override_material(s, per_surface[s])


func _make_skin_shader_material(bc_path: String, normal_path: String,
		srmf_path: String, scatter_path: String = "") -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_local.gdshader") as Shader
	if ResourceLoader.exists(bc_path):
		mat.set_shader_parameter("texture_albedo", load(bc_path) as Texture2D)
	mat.set_shader_parameter("albedo", Color(1, 1, 1, 1))
	if ResourceLoader.exists(normal_path):
		mat.set_shader_parameter("texture_normal", load(normal_path) as Texture2D)
	mat.set_shader_parameter("normal_strength", 1.3)
	if ResourceLoader.exists(srmf_path):
		mat.set_shader_parameter("texture_roughness", load(srmf_path) as Texture2D)
	mat.set_shader_parameter("roughness", 0.95)
	mat.set_shader_parameter("specular", 0.30)
	mat.set_shader_parameter("double_specularity", false)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	mat.set_shader_parameter("subsurface_scattering_strength", 0.34)
	mat.set_shader_parameter("skin_smoothness", 1.2)
	mat.set_shader_parameter("skin_fallof_smoothness", 1.05)
	mat.set_shader_parameter("old_lightwarp_fallof", false)
	mat.set_shader_parameter("tinted_shadow_penumbra", true)  # warm fleshy terminator (microdancing look)
	if ResourceLoader.exists("res://skin_micro_n.png"):
		mat.set_shader_parameter("texture_micro_detail", load("res://skin_micro_n.png") as Texture2D)
		mat.set_shader_parameter("use_micro_detail", true)
		mat.set_shader_parameter("micro_detail_scale", 22.0)
		mat.set_shader_parameter("micro_normal_strength", 0.45)
		mat.set_shader_parameter("micro_ao_strength", 0.5)
	else:
		mat.set_shader_parameter("use_micro_detail", false)
		mat.set_shader_parameter("micro_normal_strength", 0.0)
	if ResourceLoader.exists("res://skin_micro_cav.png"):
		mat.set_shader_parameter("ambient_occlusion_texture", load("res://skin_micro_cav.png") as Texture2D)
		mat.set_shader_parameter("use_ambient_occlusion", true)
		mat.set_shader_parameter("ao_strength", 0.6)
		mat.set_shader_parameter("ao_block_light", 0.5)
	else:
		mat.set_shader_parameter("use_ambient_occlusion", false)
	mat.set_shader_parameter("translucency", false)
	if scatter_path != "" and ResourceLoader.exists(scatter_path):
		mat.set_shader_parameter("texture_scatter", load(scatter_path) as Texture2D)
		mat.set_shader_parameter("use_scatter_map", true)
		mat.set_shader_parameter("scatter_strength", 1.4)
	else:
		mat.set_shader_parameter("use_scatter_map", false)
	mat.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv1_offset", Vector3(0, 0, 0))
	mat.set_shader_parameter("uv2_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv2_offset", Vector3(0, 0, 0))
	return mat


func _make_eye_material(side: String) -> ShaderMaterial:
	var S: String = side.substr(1, 1).to_upper()
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://scenes/eye.gdshader") as Shader
	var iris_bc: String = "res://eye_iris_%s_bc.png" % S
	var iris_n: String = "res://eye_iris_%s_n.png" % S
	var scl_bc: String = "res://eye_sclera_%s_bc.png" % S
	var scl_n: String = "res://eye_sclera_%s_n.png" % S
	if ResourceLoader.exists(iris_bc):
		mat.set_shader_parameter("iris_texture", load(iris_bc) as Texture2D)
	if ResourceLoader.exists(iris_n):
		mat.set_shader_parameter("iris_normal", load(iris_n) as Texture2D)
	if ResourceLoader.exists(scl_bc):
		mat.set_shader_parameter("sclera_texture", load(scl_bc) as Texture2D)
	if ResourceLoader.exists(scl_n):
		mat.set_shader_parameter("sclera_normal", load(scl_n) as Texture2D)
	mat.set_shader_parameter("iris_radius", 0.155)
	mat.set_shader_parameter("blend_softness", 0.02)
	mat.set_shader_parameter("iris_scale", 1.9)
	mat.set_shader_parameter("sclera_tint", 0.35)
	mat.set_shader_parameter("normal_strength", 0.55)
	mat.set_shader_parameter("roughness_val", 0.03)
	mat.set_shader_parameter("specular_val", 1.0)
	return mat


func _make_outfit_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.085, 0.092, 0.11, 1.0)
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.metallic_specular = 0.18
	if ResourceLoader.exists("res://dg_shirt_normal.png"):
		mat.normal_enabled = true
		mat.normal_texture = load("res://dg_shirt_normal.png") as Texture2D
		mat.normal_scale = 1.0
	if ResourceLoader.exists("res://dg_shirt_ao.png"):
		mat.ao_enabled = true
		mat.ao_texture = load("res://dg_shirt_ao.png") as Texture2D
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.subsurf_scatter_enabled = true
	mat.subsurf_scatter_strength = 0.08
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _make_shirt_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	for p in ["res://character_T_Shirt_BaseColor.png", "res://T_Shirt_BaseColor.png"]:
		if ResourceLoader.exists(p):
			mat.albedo_texture = load(p) as Texture2D
			break
	mat.albedo_color = Color(0.85, 0.85, 0.85, 1.0)
	for p in ["res://character_T_Shirt_Normal.png", "res://T_Shirt_Normal.png"]:
		if ResourceLoader.exists(p):
			mat.normal_enabled = true
			mat.normal_texture = load(p) as Texture2D
			break
	mat.roughness = 1.0
	for p in ["res://character_T_Shirt_ORMF.png", "res://T_Shirt_ORMF.png"]:
		if ResourceLoader.exists(p):
			mat.roughness_texture = load(p) as Texture2D
			mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			mat.ao_enabled = true
			mat.ao_texture = load(p) as Texture2D
			mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			break
	mat.metallic = 0.0
	mat.metallic_specular = 0.35
	return mat


func _make_pants_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	for p in ["res://character_T_Pants_BaseColor.png", "res://T_Pants_BaseColor.png"]:
		if ResourceLoader.exists(p):
			mat.albedo_texture = load(p) as Texture2D
			break
	mat.albedo_color = Color(1, 1, 1, 1)
	for p in ["res://character_T_Pants_Normal.png", "res://T_Pants_Normal.png"]:
		if ResourceLoader.exists(p):
			mat.normal_enabled = true
			mat.normal_texture = load(p) as Texture2D
			break
	mat.roughness = 1.0
	for p in ["res://character_T_Pants_ORMF.png", "res://T_Pants_ORMF.png"]:
		if ResourceLoader.exists(p):
			mat.roughness_texture = load(p) as Texture2D
			mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			mat.ao_enabled = true
			mat.ao_texture = load(p) as Texture2D
			mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			break
	mat.metallic = 0.0
	mat.metallic_specular = 0.30
	return mat


# ════════════════════════════════════════════════════════════════════════════
# Orbit camera input
# ════════════════════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_H:
			_toggle_ui()
			return
		if event.keycode == KEY_ESCAPE:
			if _credits_panel and _credits_panel.visible:
				_credits_panel.visible = false
			else:
				get_tree().quit()
			return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					orbit_dist = maxf(0.15, orbit_dist * 0.90)
					_update_orbit_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					orbit_dist = minf(12.0, orbit_dist * 1.10)
					_update_orbit_camera()
			MOUSE_BUTTON_LEFT:
				_drag_mode = 1 if mb.pressed else 0
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_drag_mode = 2 if mb.pressed else 0
	elif event is InputEventMouseMotion and _drag_mode != 0:
		var rel: Vector2 = (event as InputEventMouseMotion).relative
		if _drag_mode == 1:
			# Inverted per Sam: drag up → view goes down, drag left → goes right.
			orbit_yaw -= rel.x * 0.35
			orbit_pitch = clampf(orbit_pitch + rel.y * 0.35, -89.0, 89.0)
		else:
			# Pan: shift the orbit target along the camera's right/up axes.
			var basis: Basis = camera.global_transform.basis
			var scale: float = orbit_dist * 0.0016
			orbit_target -= basis.x * (rel.x * scale)
			orbit_target += basis.y * (rel.y * scale)
		_update_orbit_camera()


func _update_orbit_camera() -> void:
	if camera == null:
		return
	var p: float = deg_to_rad(orbit_pitch)
	var y: float = deg_to_rad(orbit_yaw)
	var dir: Vector3 = Vector3(sin(y) * cos(p), sin(p), cos(y) * cos(p))
	camera.position = orbit_target + dir * orbit_dist
	camera.look_at(orbit_target, Vector3.UP)
	if dof_enabled:
		_apply_dof()


func _apply_dof() -> void:
	cam_attrs.dof_blur_far_enabled = dof_enabled
	cam_attrs.dof_blur_near_enabled = dof_enabled
	cam_attrs.dof_blur_far_distance = dof_focus
	cam_attrs.dof_blur_near_distance = maxf(0.05, dof_focus - 0.35)
	cam_attrs.dof_blur_amount = dof_blur


func _reset_camera() -> void:
	orbit_target = DEFAULT_CAM_TARGET
	orbit_yaw = DEFAULT_CAM_YAW
	orbit_pitch = DEFAULT_CAM_PITCH
	orbit_dist = DEFAULT_CAM_DIST
	_update_orbit_camera()


# ════════════════════════════════════════════════════════════════════════════
# UI
# ════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	_ui_layer = layer

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 0.0
	panel.offset_top = 0.0
	panel.offset_right = _panel_width
	panel.offset_bottom = 0.0
	panel.clip_contents = true
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.07, 0.88)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	_panel = panel

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.custom_minimum_size = Vector2(0, 0)
	vb.add_theme_constant_override("separation", 3)
	scroll.add_child(vb)
	_panel_vb = vb

	# Header + top buttons -------------------------------------------------
	var title: Label = Label.new()
	title.text = "MetaHuman Look-Dev"
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)
	var hint: Label = Label.new()
	hint.text = "LMB orbit · wheel zoom · RMB/MMB pan"
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)

	var btn_row: HBoxContainer = HBoxContainer.new()
	vb.add_child(btn_row)
	var save_btn: Button = Button.new()
	save_btn.text = "Save settings"
	save_btn.pressed.connect(_save_settings)
	btn_row.add_child(save_btn)
	var load_btn: Button = Button.new()
	load_btn.text = "Load"
	load_btn.pressed.connect(func(): _load_settings())
	btn_row.add_child(load_btn)
	var reset_btn: Button = Button.new()
	reset_btn.text = "Reset cam"
	reset_btn.pressed.connect(_reset_camera)
	btn_row.add_child(reset_btn)

	var tt: CheckButton = CheckButton.new()
	tt.text = "Auto-turntable (spins the model)"
	tt.toggled.connect(func(on): auto_turntable = on)
	vb.add_child(tt)

	var anim_tt: CheckButton = CheckButton.new()
	anim_tt.text = "Play animation (face + body)"
	anim_tt.disabled = _placeholder
	anim_tt.toggled.connect(_set_anim_playing)
	vb.add_child(anim_tt)

	var hero_tt: CheckButton = CheckButton.new()
	hero_tt.text = "Hero camera (wide → close, loops)"
	hero_tt.toggled.connect(_set_hero_cam)
	vb.add_child(hero_tt)

	# ── SKIN ──────────────────────────────────────────────────────────────
	_hdr(vb, "Skin")
	_mkslider(vb, "SKIN_NRM", "normal_strength", 0.0, 8.0, 0.01, 0.73, _skin_setter("normal_strength"))
	_mkslider(vb, "SKIN_SSS", "subsurface_scattering", 0.0, 1.0, 0.01, 1.0, _skin_setter("subsurface_scattering_strength"))
	_mkslider(vb, "SKIN_SMOOTH", "skin_smoothness", 0.0, 6.0, 0.01, 2.6, _skin_setter("skin_smoothness"))
	_mkslider(vb, "skin_fallof", "skin_fallof_smoothness", 0.5, 3.0, 0.01, 1.0, _skin_setter("skin_fallof_smoothness"))
	_mkslider(vb, "SKIN_MICRO", "micro_normal_strength", 0.0, 2.0, 0.01, 0.62, _skin_setter("micro_normal_strength"))
	_mkslider(vb, "micro_scale", "micro_detail_scale", 1.0, 120.0, 0.5, 21.0, _skin_setter("micro_detail_scale"))
	_mkslider(vb, "micro_ao", "micro_ao_strength", 0.0, 2.0, 0.01, 0.48, _skin_setter("micro_ao_strength"))
	_mkslider(vb, "scatter", "scatter_strength", 0.0, 4.0, 0.01, 2.3, _skin_setter("scatter_strength"))
	_mkslider(vb, "skin_rough", "roughness", 0.0, 1.0, 0.01, 0.72, _skin_setter("roughness"))
	_mkslider(vb, "skin_spec", "specular", 0.0, 2.0, 0.01, 1.2, _skin_setter("specular"))
	_mkslider(vb, "skin_ao", "ao_strength", 0.0, 2.0, 0.01, 0.61, _skin_setter("ao_strength"))
	_mkcheck(vb, "double_spec", "double_specularity", false, _skin_setter_b("double_specularity"))
	_mkcheck(vb, "use_sss", "use_subsurface_scattering", true, _skin_setter_b("use_subsurface_scattering"))
	_mkcheck(vb, "use_micro", "use_micro_detail", true, _skin_setter_b("use_micro_detail"))
	_mkcheck(vb, "use_scatter", "use_scatter_map", true, _skin_setter_b("use_scatter_map"))
	_mkcheck(vb, "tinted_pen", "tinted_shadow_penumbra", true, _skin_setter_b("tinted_shadow_penumbra"))

	# ── KEY LIGHT ─────────────────────────────────────────────────────────
	_hdr(vb, "Key light")
	_mkslider(vb, "KEY", "energy", 0.0, 10.0, 0.01, 0.67, func(v): key_light.light_energy = v)
	_mkcolor(vb, "key_color", "color", Color("ffe6c2"), func(c): key_light.light_color = c)
	_mkslider(vb, "key_yaw", "yaw", -180.0, 180.0, 1.0, key_yaw, func(v): key_yaw = v; _apply_light_rot(key_light, key_pitch, key_yaw))
	_mkslider(vb, "key_pitch", "pitch", -90.0, 30.0, 1.0, key_pitch, func(v): key_pitch = v; _apply_light_rot(key_light, key_pitch, key_yaw))
	_mkslider(vb, "key_angular", "softness (angular)", 0.0, 20.0, 0.1, 20.0, func(v): key_light.light_angular_distance = v)
	_mkcheck(vb, "key_shadow", "cast shadow", true, func(on): key_light.shadow_enabled = on)
	_mkslider(vb, "key_shadow_blur", "shadow blur", 0.0, 10.0, 0.1, 4.4, func(v): key_light.shadow_blur = v)

	# ── FILL LIGHT ────────────────────────────────────────────────────────
	_hdr(vb, "Fill light")
	_mkslider(vb, "FILL", "energy", 0.0, 6.0, 0.01, 0.7, func(v): fill_light.light_energy = v)
	_mkcolor(vb, "fill_color", "color", Color("ff8442"), func(c): fill_light.light_color = c)
	_mkslider(vb, "fill_yaw", "yaw", -180.0, 180.0, 1.0, fill_yaw, func(v): fill_yaw = v; _apply_light_rot(fill_light, fill_pitch, fill_yaw))
	_mkslider(vb, "fill_pitch", "pitch", -90.0, 30.0, 1.0, fill_pitch, func(v): fill_pitch = v; _apply_light_rot(fill_light, fill_pitch, fill_yaw))

	# ── RIM LIGHT ─────────────────────────────────────────────────────────
	_hdr(vb, "Rim light")
	_mkslider(vb, "RIM", "energy", 0.0, 10.0, 0.01, 5.25, func(v): rim_light.light_energy = v)
	_mkcolor(vb, "rim_color", "color", Color("005dff"), func(c): rim_light.light_color = c)
	_mkslider(vb, "rim_yaw", "yaw", -180.0, 180.0, 1.0, rim_yaw, func(v): rim_yaw = v; _apply_light_rot(rim_light, rim_pitch, rim_yaw))
	_mkslider(vb, "rim_pitch", "pitch", -90.0, 30.0, 1.0, rim_pitch, func(v): rim_pitch = v; _apply_light_rot(rim_light, rim_pitch, rim_yaw))

	# ── CATCHLIGHT ────────────────────────────────────────────────────────
	_hdr(vb, "Catchlight (frontal omni)")
	_mkslider(vb, "CATCH", "energy", 0.0, 4.0, 0.01, 0.14, func(v): catch_light.light_energy = v)

	# ── ENVIRONMENT ───────────────────────────────────────────────────────
	_hdr(vb, "Environment")
	_mkslider(vb, "AMBIENT", "ambient energy", 0.0, 3.0, 0.01, 0.13, func(v): env.ambient_light_energy = v)
	_mkslider(vb, "EXPOSURE", "exposure", 0.2, 3.0, 0.01, 0.99, func(v): env.tonemap_exposure = v)
	_mkslider(vb, "tonemap_white", "tonemap white", 1.0, 16.0, 0.1, 5.4, func(v): env.tonemap_white = v)
	_mkslider(vb, "contrast", "contrast", 0.0, 3.0, 0.01, 1.05, func(v): env.adjustment_contrast = v)
	_mkslider(vb, "saturation", "saturation", 0.0, 3.0, 0.01, 0.88, func(v): env.adjustment_saturation = v)
	_mkslider(vb, "backdrop_bright", "backdrop brightness", 0.0, 4.0, 0.01, 2.0, func(v): backdrop_bright = v; _apply_backdrop())
	_mkcolor(vb, "backdrop_tint", "backdrop tint", Color("420043"), func(c): backdrop_tint = c; _apply_backdrop())

	# ── HAIR ──────────────────────────────────────────────────────────────
	_hdr(vb, "Hair")
	_mkcolor(vb, "hair_scalp_color", "scalp color", Color("4b381d"), _hair_color_setter(hair_scalp_cards))
	_mkslider(vb, "hair_threshold", "alpha_threshold", 0.0, 0.5, 0.005, 0.07, _hair_param_setter(hair_scalp_cards, "alpha_threshold"))
	_mkslider(vb, "hair_root_dark", "root_darkening", 0.0, 1.0, 0.01, 0.66, _hair_param_setter(hair_scalp_cards, "root_darkening"))
	_mkcolor(vb, "hair_backing_color", "backing color", Color("332817"), _hair_color_setter(hair_scalp_backing))
	_mkslider(vb, "HAIR_BACK_INSET", "backing inset", 0.0, 0.06, 0.0005, 0.024, _hair_param_setter(hair_scalp_backing, "inset"))
	_mkslider(vb, "HAIR_BACK_CUT", "backing cutoff", 0.0, 0.4, 0.002, 0.08, _hair_param_setter(hair_scalp_backing, "cutoff"))
	_mkcolor(vb, "beard_color", "beard/mustache color", Color("3d3021"), _hair_color_setter(hair_beard_cards))
	_mkcolor(vb, "eyebrow_color", "eyebrow color", Color("382918"), _hair_color_setter(hair_brow_cards))

	# ── CAMERA / DOF ──────────────────────────────────────────────────────
	_hdr(vb, "Camera / DOF")
	_mkslider(vb, "fov", "FOV", 8.0, 90.0, 0.5, 28.0, func(v): _set_fov(v))
	_mkcheck(vb, "dof_enabled", "DOF enabled", true, func(on): dof_enabled = on; _apply_dof())
	_mkslider(vb, "dof_focus", "focus distance", 0.1, 6.0, 0.01, 1.33, func(v): dof_focus = v; _apply_dof())
	_mkslider(vb, "dof_blur", "blur amount", 0.0, 1.0, 0.005, 0.085, func(v): dof_blur = v; _apply_dof())

	# Corner overlays: screenshot/movie buttons (bottom-right), hide button
	# (top-right), and a "press H" hint shown only while the UI is hidden.
	_build_corner_ui(layer)
	_build_panel_handle(layer)


# ── Setter factories ────────────────────────────────────────────────────────

func _skin_setter(param: String) -> Callable:
	return func(v: float) -> void:
		for m in skin_mats:
			m.set_shader_parameter(param, v)


func _skin_setter_b(param: String) -> Callable:
	return func(on: bool) -> void:
		for m in skin_mats:
			m.set_shader_parameter(param, on)


func _hair_color_setter(mats: Array) -> Callable:
	return func(c: Color) -> void:
		for m in mats:
			m.set_shader_parameter("hair_color", c)


func _hair_param_setter(mats: Array, param: String) -> Callable:
	return func(v: float) -> void:
		for m in mats:
			m.set_shader_parameter(param, v)


func _apply_light_rot(light: DirectionalLight3D, pitch: float, yaw: float) -> void:
	light.rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)


func _apply_backdrop() -> void:
	if backdrop_mat:
		backdrop_mat.albedo_color = Color(
			backdrop_tint.r * backdrop_bright,
			backdrop_tint.g * backdrop_bright,
			backdrop_tint.b * backdrop_bright, 1.0)


func _set_fov(v: float) -> void:
	_orbit_fov = v
	if not _hero_cam and camera:
		camera.fov = v


# ════════════════════════════════════════════════════════════════════════════
# Window icon (force the taskbar + titlebar icon at runtime)
# ════════════════════════════════════════════════════════════════════════════

func _setup_window_icon() -> void:
	if not ResourceLoader.exists("res://icon.png"):
		return
	var tex: Texture2D = load("res://icon.png") as Texture2D
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null:
		print("[look_dev] window icon: get_image() returned null")
		return
	if img.is_compressed():
		img.decompress()
	DisplayServer.set_icon(img)
	print("[look_dev] window icon set (%dx%d)" % [img.get_width(), img.get_height()])


# ════════════════════════════════════════════════════════════════════════════
# Collapsible / resizable left panel
# ════════════════════════════════════════════════════════════════════════════

func _build_panel_handle(layer: CanvasLayer) -> void:
	var handle: Panel = Panel.new()
	handle.name = "PanelHandle"
	handle.anchor_top = 0.0
	handle.anchor_bottom = 1.0
	handle.offset_left = _panel_width
	handle.offset_right = _panel_width + 12.0
	handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	var hs: StyleBoxFlat = StyleBoxFlat.new()
	hs.bg_color = Color(0.20, 0.22, 0.28, 0.9)
	handle.add_theme_stylebox_override("panel", hs)
	var grip: Label = Label.new()
	grip.text = "⋮"
	grip.set_anchors_preset(Control.PRESET_CENTER)
	grip.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	handle.add_child(grip)
	handle.gui_input.connect(_on_handle_input)
	layer.add_child(handle)
	_panel_handle = handle

	var collapse: Button = Button.new()
	collapse.name = "CollapseBtn"
	collapse.text = "‹‹"
	collapse.tooltip_text = "Collapse / expand the settings panel"
	collapse.offset_left = _panel_width + 16.0
	collapse.offset_top = 12.0
	collapse.offset_right = _panel_width + 50.0
	collapse.offset_bottom = 40.0
	collapse.pressed.connect(_toggle_panel_collapse)
	layer.add_child(collapse)
	_panel_collapse_btn = collapse


func _on_handle_input(ev: InputEvent) -> void:
	# Only START the drag here; the motion is tracked in _input() with the
	# ABSOLUTE mouse X, so dragging left over the panel still resizes (the panel's
	# own controls would otherwise eat the motion events and the crunch would stall).
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_panel_dragging = (ev as InputEventMouseButton).pressed


func _input(event: InputEvent) -> void:
	if not _panel_dragging:
		return
	if event is InputEventMouseMotion:
		_set_panel_width((event as InputEventMouseMotion).position.x + 6.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_panel_dragging = false


func _set_panel_width(w: float) -> void:
	_panel_width = clampf(w, 0.0, 760.0)
	if _panel:
		_panel.offset_right = _panel_width
	if _panel_handle:
		_panel_handle.offset_left = _panel_width
		_panel_handle.offset_right = _panel_width + 12.0
	if _panel_collapse_btn:
		_panel_collapse_btn.offset_left = _panel_width + 16.0
		_panel_collapse_btn.offset_right = _panel_width + 50.0


func _toggle_panel_collapse() -> void:
	if _panel_width > 40.0:
		_panel_prev_width = _panel_width
		_set_panel_width(0.0)
		if _panel_collapse_btn:
			_panel_collapse_btn.text = "››"
	else:
		_set_panel_width(_panel_prev_width if _panel_prev_width > 40.0 else 400.0)
		if _panel_collapse_btn:
			_panel_collapse_btn.text = "‹‹"


# ════════════════════════════════════════════════════════════════════════════
# Animation (face emote + body idle) + hero camera (ported from emote_render.gd)
# ════════════════════════════════════════════════════════════════════════════

func _set_anim_playing(on: bool) -> void:
	_anim_playing = on
	if _placeholder:
		return
	if on:
		if _body_anim_player:
			var names: PackedStringArray = _body_anim_player.get_animation_list()
			if names.size() > 0:
				var a: Animation = _body_anim_player.get_animation(names[0])
				if a:
					a.loop_mode = Animation.LOOP_LINEAR
				_body_anim_player.play(names[0])
		if _face_anim_player:
			_face_anim_player.play("emote")
	else:
		if _body_anim_player:
			_body_anim_player.stop()
		if _face_anim_player:
			_face_anim_player.stop()
		_reset_face_leader_pose()   # return the driven face bones to rest (the face node never moved)
		_reset_face_blendshapes()


func _reset_face_blendshapes() -> void:
	if _character == null:
		return
	var stack: Array[Node] = [_character]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mim: MeshInstance3D = n
			for i in range(mim.mesh.get_blend_shape_count()):
				mim.set("blend_shapes/%s" % mim.mesh.get_blend_shape_name(i), 0.0)
		for c in n.get_children():
			stack.append(c)


func _set_hero_cam(on: bool) -> void:
	_hero_cam = on
	if on:
		_hero_elapsed = 0.0
	else:
		if camera:
			camera.fov = _orbit_fov
		_update_orbit_camera()


func _update_hero_camera() -> void:
	if camera == null:
		return
	# Ping-pong wide→close→wide over 2 × HERO_DURATION.
	var phase: float = fmod(_hero_elapsed, 2.0 * HERO_DURATION) / HERO_DURATION
	var p: float = phase if phase <= 1.0 else (2.0 - phase)
	p = smoothstep(0.0, 1.0, p)
	var aim: Vector3 = _head_world if _anim_playing else orbit_target
	camera.position = HERO_WIDE_POS.lerp(HERO_CLOSE_POS, p)
	camera.fov = lerpf(HERO_WIDE_FOV, HERO_CLOSE_FOV, p)
	var aim_blend: Vector3 = HERO_WIDE_AIM.lerp(aim + Vector3(0.0, 0.05, 0.0), p)
	camera.look_at(aim_blend, Vector3.UP)
	if dof_enabled:
		var focus: float = camera.global_transform.origin.distance_to(aim_blend)
		cam_attrs.dof_blur_far_distance = focus + 0.12
		cam_attrs.dof_blur_near_distance = maxf(0.05, focus - 0.45)


func _find_body_anim_player(root: Node) -> void:
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer and (n as AnimationPlayer).get_animation_list().size() > 0:
			_body_anim_player = n
			return
		for c in n.get_children():
			stack.append(c)


func _has_ancestor_named(node: Node, target: String) -> bool:
	var p: Node = node.get_parent()
	while p != null:
		if String(p.name).begins_with(target):
			return true
		p = p.get_parent()
	return false


func _resolve_body_skeleton(root: Node) -> void:
	# The MetaHuman face skeleton ALSO contains body bones (spine_03/head); pick
	# the real body skeleton by non-FaceArmature ancestry, then fewest bones.
	var candidates: Array[Skeleton3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			var s: Skeleton3D = n
			if s.find_bone("spine_03") >= 0 and s.find_bone("head") >= 0:
				candidates.append(s)
		for c in n.get_children():
			stack.append(c)
	if candidates.is_empty():
		return
	var best: Skeleton3D = candidates[0]
	for s in candidates:
		var under_face: bool = _has_ancestor_named(s, "FaceArmature")
		var best_under_face: bool = _has_ancestor_named(best, "FaceArmature")
		if (best_under_face and not under_face) \
				or (under_face == best_under_face and s.get_bone_count() < best.get_bone_count()):
			best = s
	body_skeleton = best


func _capture_head_world_ref() -> void:
	# Capture the data to reconstruct the body 'head' bone's REAL rendered world position at
	# runtime (for the catchlight + hero-cam aim). The body skeleton's Node3D transform DRIFTS
	# during the root-motion idle, so we rebuild from the bind-time skeleton transform. The face
	# mesh is glued to the body by the per-bone LeaderPose copy (below), NOT by moving the
	# FaceArmature node — so there is no whole-armature rest transform to grab anymore.
	if body_skeleton == null:
		return
	head_bone_idx_body = body_skeleton.find_bone("head")
	if head_bone_idx_body < 0:
		return
	var skel_basis: Basis = body_skeleton.global_transform.basis
	skel_basis_norm = skel_basis.orthonormalized()
	skel_scale_factor = skel_basis.x.length()
	skel_bind_origin = body_skeleton.global_transform.origin


func _resolve_face_skeleton(root: Node) -> void:
	# The face mesh (head + neck + bust-cap) is skinned by the MetaHuman FACE skeleton — the one
	# carrying the FACIAL_* bones. Identify it by FACIAL_L_Eye (the BODY skeleton has spine/head
	# but never the facial bones). This is the skeleton the LeaderPose copy drives; FACIAL_* bones
	# are deliberately left OUT of the map so the emote + eyes hold.
	_face_skel = null
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D and (n as Skeleton3D).find_bone("FACIAL_L_Eye") >= 0:
			_face_skel = n as Skeleton3D
			return
		for c in n.get_children():
			stack.append(c)
	push_warning("[look_dev] face skeleton (FACIAL_L_Eye) not found — LeaderPose seam fix disabled")


func _build_leader_pose_map() -> void:
	# For every BODY bone the FACE skeleton also has (by name), precompute rest_xfer = RBg⁻¹ · RFg
	# (each rig's own rest global pose) so per frame we only do PFg = PBg · rest_xfer. Sorted by
	# face-bone index so parents are driven before children (Godot keeps a bone's parent index
	# below its own). The shared set is the bust region: pelvis→spine→neck→head→clavicle→upperarm
	# — exactly what must move with the body to keep the collar glued, while the head still bobs.
	_leader_pairs.clear()
	if body_skeleton == null or _face_skel == null:
		push_warning("[look_dev] leader-pose map skipped (body or face skeleton missing)")
		return
	for bi in range(body_skeleton.get_bone_count()):
		var fi: int = _face_skel.find_bone(body_skeleton.get_bone_name(bi))
		if fi < 0:
			continue
		var rest_xfer: Transform3D = body_skeleton.get_bone_global_rest(bi).affine_inverse() \
			* _face_skel.get_bone_global_rest(fi)
		_leader_pairs.append([bi, fi, _face_skel.get_bone_parent(fi), rest_xfer])
	_leader_pairs.sort_custom(func(a, b): return a[1] < b[1])
	print("[look_dev] leader-pose map: %d shared bones (body %d / face %d)" % [
		_leader_pairs.size(), body_skeleton.get_bone_count(), _face_skel.get_bone_count()])


func _apply_leader_pose() -> void:
	# Per-frame: set each shared face bone's pose so its GLOBAL pose tracks the body's global
	# motion (PFg = PBg · rest_xfer). Cache the desired face global per bone and convert to a
	# local pose via the (already-computed, parent-first) parent global — no skeleton readback,
	# no dependence on Godot's recompute order. FACIAL_* bones are never in the map, so they
	# (incl. the eyes) stay at rest and the blend-shape emote is untouched. At rest PBg = RBg →
	# PFg = RFg → no distortion.
	var pfg_cache: Dictionary = {}
	for pair in _leader_pairs:
		var bi: int = pair[0]
		var fi: int = pair[1]
		var fpar: int = pair[2]
		var pfg: Transform3D = body_skeleton.get_bone_global_pose(bi) * (pair[3] as Transform3D)
		pfg_cache[fi] = pfg
		var parent_g: Transform3D = Transform3D.IDENTITY
		if fpar >= 0:
			parent_g = pfg_cache[fpar] if pfg_cache.has(fpar) else _face_skel.get_bone_global_pose(fpar)
		var local: Transform3D = parent_g.affine_inverse() * pfg
		_face_skel.set_bone_pose_position(fi, local.origin)
		_face_skel.set_bone_pose_rotation(fi, local.basis.get_rotation_quaternion())
		_face_skel.set_bone_pose_scale(fi, local.basis.get_scale())


func _reset_face_leader_pose() -> void:
	# Restore every driven face bone to its local rest (called when the body idle stops).
	if _face_skel == null:
		return
	for pair in _leader_pairs:
		var fi: int = pair[1]
		var r: Transform3D = _face_skel.get_bone_rest(fi)
		_face_skel.set_bone_pose_position(fi, r.origin)
		_face_skel.set_bone_pose_rotation(fi, r.basis.get_rotation_quaternion())
		_face_skel.set_bone_pose_scale(fi, r.basis.get_scale())


func _find_face_mesh(root: Node) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	var best: MeshInstance3D = null
	var best_count: int = 0
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var c: int = (n as MeshInstance3D).mesh.get_blend_shape_count()
			if c > best_count:
				best = n
				best_count = c
		for child in n.get_children():
			stack.append(child)
	return best


func _build_face_animation(root: Node) -> void:
	# Build the face emote AnimationPlayer (blend-shape keyframes) but DON'T play
	# it — the "Play animation" toggle controls it.
	var face_mesh: MeshInstance3D = _find_face_mesh(root)
	if face_mesh == null:
		return
	var driven: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh and (n as MeshInstance3D).mesh.get_blend_shape_count() > 0:
			driven.append(n)
		for c in n.get_children():
			stack.append(c)
	var anim: Animation = Animation.new()
	anim.length = ANIM_DURATION
	anim.loop_mode = Animation.LOOP_LINEAR
	var touched: Dictionary = {}
	for entry in KEY_TIMES:
		for sh in KEYPOSES[entry[1]].keys():
			touched[sh] = true
	for sh in touched.keys():
		for mim in driven:
			var mesh: ArrayMesh = mim.mesh as ArrayMesh
			if mesh == null:
				continue
			var found: bool = false
			for si in range(mesh.get_blend_shape_count()):
				if mesh.get_blend_shape_name(si) == sh:
					found = true
					break
			if not found:
				continue
			var t: int = anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(t, NodePath("%s:blend_shapes/%s" % [mim.get_path(), sh]))
			anim.track_set_interpolation_type(t, Animation.INTERPOLATION_LINEAR)
			for entry in KEY_TIMES:
				anim.track_insert_key(t, entry[0], KEYPOSES[entry[1]].get(sh, 0.0))
	var lib: AnimationLibrary = AnimationLibrary.new()
	lib.add_animation("emote", anim)
	_face_anim_player = AnimationPlayer.new()
	_face_anim_player.name = "FaceAnimLookDev"
	add_child(_face_anim_player)
	_face_anim_player.add_animation_library("", lib)


# ════════════════════════════════════════════════════════════════════════════
# Corner UI: capture buttons, hide toggle, toast
# ════════════════════════════════════════════════════════════════════════════

func _build_corner_ui(layer: CanvasLayer) -> void:
	# Bottom-right capture buttons.
	var caps: VBoxContainer = VBoxContainer.new()
	caps.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	caps.offset_left = -260
	caps.offset_top = -84
	caps.offset_right = -12
	caps.offset_bottom = -12
	caps.alignment = BoxContainer.ALIGNMENT_END
	caps.add_theme_constant_override("separation", 6)
	layer.add_child(caps)
	var shot_btn: Button = Button.new()
	shot_btn.text = "Screenshot"
	shot_btn.pressed.connect(_capture_screenshot)
	caps.add_child(shot_btn)
	var movie_btn: Button = Button.new()
	movie_btn.text = "Capture movie (turntable)"
	movie_btn.pressed.connect(_start_movie)
	caps.add_child(movie_btn)

	# Top-right hide button.
	var hide_btn: Button = Button.new()
	hide_btn.text = "Hide UI  [H]"
	hide_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	hide_btn.offset_left = -120
	hide_btn.offset_top = 12
	hide_btn.offset_right = -12
	hide_btn.offset_bottom = 40
	hide_btn.pressed.connect(_toggle_ui)
	layer.add_child(hide_btn)

	# Credits / Legal button (top-right, under Hide UI).
	var cred_btn: Button = Button.new()
	cred_btn.text = "Credits / Legal"
	cred_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	cred_btn.offset_left = -120
	cred_btn.offset_top = 46
	cred_btn.offset_right = -12
	cred_btn.offset_bottom = 74
	cred_btn.pressed.connect(_toggle_credits)
	layer.add_child(cred_btn)
	_build_credits_panel(layer)

	# Quit button (top-right, under Credits). Esc also quits.
	var quit_btn: Button = Button.new()
	quit_btn.text = "Quit  [Esc]"
	quit_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	quit_btn.offset_left = -120
	quit_btn.offset_top = 80
	quit_btn.offset_right = -12
	quit_btn.offset_bottom = 108
	quit_btn.pressed.connect(func(): get_tree().quit())
	layer.add_child(quit_btn)

	# Toast (transient status message), bottom-centre.
	_toast_label = Label.new()
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.offset_left = -400
	_toast_label.offset_right = 400
	_toast_label.offset_top = -48
	_toast_label.offset_bottom = -20
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	_toast_label.add_theme_font_size_override("font_size", 15)
	_toast_label.visible = false
	layer.add_child(_toast_label)

	# Placeholder banner (only when no character.glb was found).
	if _placeholder:
		var banner: Label = Label.new()
		banner.text = "No character.glb — showing placeholder.  Drop your exported MetaHuman at res://character.glb (godot_project/character.glb) for the full rig."
		banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
		banner.offset_left = -520
		banner.offset_right = 520
		banner.offset_top = 12
		banner.offset_bottom = 40
		banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		banner.add_theme_font_size_override("font_size", 13)
		layer.add_child(banner)

	# Separate always-on hint layer, shown only while the main UI is hidden.
	_hint_layer = CanvasLayer.new()
	_hint_layer.name = "UIHint"
	add_child(_hint_layer)
	var hint: Label = Label.new()
	hint.text = "[H] show UI"
	hint.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	hint.offset_left = -110
	hint.offset_top = 12
	hint.offset_right = -12
	hint.offset_bottom = 36
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	_hint_layer.add_child(hint)
	_hint_layer.visible = false


func _toggle_ui() -> void:
	if _ui_layer == null:
		return
	_ui_layer.visible = not _ui_layer.visible
	if _hint_layer:
		_hint_layer.visible = not _ui_layer.visible


func _build_credits_panel(layer: CanvasLayer) -> void:
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.visible = false
	# Dim scrim behind the dialog.
	var scrim: ColorRect = ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(scrim)
	var panel: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.12, 0.98)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.3, 0.35, 0.45)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	var body: Label = Label.new()
	body.text = CREDITS_TEXT + "\n\n— Engine —\nBuilt with Godot Engine %s — stock/official build from https://godotengine.org (MIT License). Forward+ renderer. Not a custom Godot fork." % Engine.get_version_info().get("string", "4.6")
	body.add_theme_font_size_override("font_size", 14)
	body.custom_minimum_size = Vector2(680, 0)
	vb.add_child(body)
	var close: Button = Button.new()
	close.text = "Close"
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(_toggle_credits)
	vb.add_child(close)
	layer.add_child(center)
	_credits_panel = center


func _toggle_credits() -> void:
	if _credits_panel:
		_credits_panel.visible = not _credits_panel.visible


func _toast(msg: String) -> void:
	if _toast_label:
		_toast_label.text = msg
		_toast_label.visible = true
		_toast_until = _time + 4.0


func _begin_capture_quality() -> void:
	# Supersample on capture: render 3D at ≥2× internal res then downsample → crisp
	# stills/video (tames hair-card shimmer + sharpens pores).
	var vp: Viewport = get_viewport()
	_prev_scale_3d = vp.scaling_3d_scale
	if _prev_scale_3d < 2.0:
		vp.scaling_3d_scale = 2.0


func _end_capture_quality() -> void:
	get_viewport().scaling_3d_scale = _prev_scale_3d


func _capture_screenshot() -> void:
	# Hide the whole UI so the still is clean, draw a frame, grab, restore.
	var was_visible: bool = _ui_layer.visible
	_ui_layer.visible = false
	if _hint_layer:
		_hint_layer.visible = false
	_begin_capture_quality()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw   # extra frame for the scale change to land
	var img: Image = get_viewport().get_texture().get_image()
	var stamp: String = _stamp()
	var path: String = "H:/Work01/MetaHumanGodot/out/lookdev_shot_%s.png" % stamp
	var err: int = img.save_png(path)
	_end_capture_quality()
	_ui_layer.visible = was_visible
	print("[look_dev] screenshot → %s (err %d)" % [path, err])
	_toast("Saved %s" % path)


func _run_movie_selftest() -> void:
	# Verification path: exercise the screenshot then a short turntable movie,
	# then quit. Triggered by LOOKDEV_MOVIETEST env only.
	await get_tree().create_timer(0.4).timeout
	await _capture_screenshot()
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = int(OS.get_environment("MOVIE_FRAMES"))
	_start_movie()


func _start_movie() -> void:
	if _movie_recording:
		return
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = maxi(2, int(OS.get_environment("MOVIE_FRAMES")))
	_movie_stamp = _stamp()
	_movie_dir = "H:/Work01/MetaHumanGodot/out/lookdev_movie_%s" % _movie_stamp
	DirAccess.make_dir_recursive_absolute(_movie_dir)
	_begin_capture_quality()
	_movie_recording = true
	_movie_frame = 0
	_movie_start_yaw = _character.rotation.y if _character else 0.0
	_ui_layer.visible = false
	if _hint_layer:
		_hint_layer.visible = false
	print("[look_dev] recording turntable → ", _movie_dir)
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)


func _on_frame_post_draw() -> void:
	if not _movie_recording:
		return
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [_movie_dir, _movie_frame])
	_movie_frame += 1
	if _movie_frame >= _movie_total:
		_finish_movie()
	elif _character:
		# Spin the MODEL for the turntable movie (camera stays put).
		_character.rotation.y = _movie_start_yaw + deg_to_rad(360.0) * float(_movie_frame) / float(_movie_total)


func _finish_movie() -> void:
	_movie_recording = false
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	_end_capture_quality()
	if _character:
		_character.rotation.y = _movie_start_yaw
	_ui_layer.visible = true
	# Assemble the PNG sequence into an mp4 via python+cv2 (no ffmpeg on Archie).
	var py: String = "%s/_assemble.py" % _movie_dir
	var pf: FileAccess = FileAccess.open(py, FileAccess.WRITE)
	if pf:
		pf.store_string(ASSEMBLE_PY)
		pf.close()
	var out_mp4: String = "H:/Work01/MetaHumanGodot/out/lookdev_movie_%s.mp4" % _movie_stamp
	var output: Array = []
	var code: int = OS.execute("python", [py, _movie_dir, out_mp4], output, true)
	if code == 0:
		print("[look_dev] movie → %s" % out_mp4)
		_toast("Movie saved: %s" % out_mp4)
	else:
		print("[look_dev] cv2 assemble failed (code %d); frames in %s" % [code, _movie_dir])
		print(output)
		_toast("Frames saved (assemble manually): %s" % _movie_dir)
	if OS.has_environment("LOOKDEV_MOVIETEST"):
		print("[look_dev] movietest done, quitting")
		get_tree().quit()


func _stamp() -> String:
	# Filesystem-safe timestamp (Time is allowed in GDScript runtime).
	return Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")


# ── UI widget builders ───────────────────────────────────────────────────────

func _hdr(parent: Node, text: String) -> void:
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	parent.add_child(spacer)
	var l: Label = Label.new()
	l.text = "── " + text + " ──"
	l.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	l.add_theme_font_size_override("font_size", 14)
	parent.add_child(l)


func _reset_btn(key: String) -> Button:
	# Small per-setting reset button → restores this control to its baked default.
	var b: Button = Button.new()
	b.text = "↺"
	b.tooltip_text = "Reset to default"
	b.custom_minimum_size = Vector2(26, 0)
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(func():
		if _loaders.has(key) and _defaults.has(key):
			_loaders[key].call(_defaults[key]))
	return b


func _fmt(v: float, step: float) -> String:
	if step >= 1.0:
		return str(int(round(v)))
	elif step >= 0.1:
		return "%.1f" % v
	elif step >= 0.01:
		return "%.2f" % v
	else:
		return "%.4f" % v


func _mkslider(parent: Node, key: String, label: String, mn: float, mx: float,
		step: float, val: float, setter: Callable) -> HSlider:
	# Slider + numeric SpinBox, two-way bound. The SpinBox has allow_greater/
	# allow_lesser so you can TYPE values beyond the slider range for extremes.
	var row: HBoxContainer = HBoxContainer.new()
	var l: Label = Label.new()
	l.text = label
	l.custom_minimum_size.x = 150
	l.add_theme_font_size_override("font_size", 12)
	var s: HSlider = HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.y = 18
	var sp: SpinBox = SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.allow_greater = true
	sp.allow_lesser = true
	sp.value = val
	sp.custom_minimum_size.x = 76
	sp.add_theme_font_size_override("font_size", 12)
	s.value_changed.connect(func(v):
		sp.set_value_no_signal(v)
		setter.call(v))
	sp.value_changed.connect(func(v):
		s.set_value_no_signal(v)
		setter.call(v))
	row.add_child(l)
	row.add_child(s)
	row.add_child(sp)
	row.add_child(_reset_btn(key))
	parent.add_child(row)
	setter.call(val)
	_defaults[key] = val
	_savers[key] = func(): return sp.value
	_loaders[key] = func(x):
		var fx: float = float(x)
		sp.set_value_no_signal(fx)
		s.set_value_no_signal(fx)
		setter.call(fx)
	return s


func _mkcheck(parent: Node, key: String, label: String, val: bool, setter: Callable) -> CheckBox:
	var row: HBoxContainer = HBoxContainer.new()
	var c: CheckBox = CheckBox.new()
	c.text = label
	c.button_pressed = val
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_theme_font_size_override("font_size", 12)
	c.toggled.connect(func(on): setter.call(on))
	row.add_child(c)
	row.add_child(_reset_btn(key))
	parent.add_child(row)
	setter.call(val)
	_defaults[key] = val
	_savers[key] = func(): return c.button_pressed
	_loaders[key] = func(x):
		c.button_pressed = bool(x)
		setter.call(bool(x))
	return c


func _mkcolor(parent: Node, key: String, label: String, col: Color, setter: Callable) -> ColorPickerButton:
	var row: HBoxContainer = HBoxContainer.new()
	var l: Label = Label.new()
	l.text = label
	l.custom_minimum_size.x = 158
	l.add_theme_font_size_override("font_size", 12)
	var cp: ColorPickerButton = ColorPickerButton.new()
	cp.color = col
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(80, 22)
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.color_changed.connect(func(c): setter.call(c))
	row.add_child(l)
	row.add_child(cp)
	row.add_child(_reset_btn(key))
	parent.add_child(row)
	setter.call(col)
	_defaults[key] = col.to_html(false)
	_savers[key] = func(): return cp.color.to_html(false)
	_loaders[key] = func(x):
		var c: Color = Color(str(x))
		cp.color = c
		setter.call(c)
	return cp


# ── Save / Load ──────────────────────────────────────────────────────────────

func _settings_paths() -> Array:
	# Portable: a repo-adjacent mirror (sits next to the Godot project, e.g.
	# H:/Work01/MetaHumanGodot/look_settings.json on Archie — used to lock the
	# dialed-in look into emote_render.gd) PLUS user:// (always writable on any
	# machine). Mirror takes precedence on load. Order = [mirror, user].
	var mirror: String = ProjectSettings.globalize_path("res://").path_join("..").path_join(SETTINGS_FILE)
	return [mirror, "user://".path_join(SETTINGS_FILE)]


func _save_settings() -> void:
	var d: Dictionary = {}
	for k in _savers:
		d[k] = _savers[k].call()
	# Also persist the camera framing so a session resumes where you left off.
	d["cam_yaw"] = orbit_yaw
	d["cam_pitch"] = orbit_pitch
	d["cam_dist"] = orbit_dist
	var txt: String = JSON.stringify(d, "  ")
	var wrote: Array = []
	for p in _settings_paths():
		var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(txt)
			f.close()
			wrote.append(p)
	if wrote.is_empty():
		push_error("[look_dev] could not write settings to any of %s" % str(_settings_paths()))
		_toast("Save FAILED — no writable path")
		return
	print("[look_dev] saved settings → ", wrote)
	print(txt)
	_toast("Saved → %s" % wrote[0])


func _load_settings() -> void:
	for p in _settings_paths():
		if not FileAccess.file_exists(p):
			continue
		var f: FileAccess = FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var txt: String = f.get_as_text()
		f.close()
		var d: Variant = JSON.parse_string(txt)
		if typeof(d) != TYPE_DICTIONARY:
			push_error("[look_dev] settings file is not a JSON object: %s" % p)
			continue
		for k in d:
			if _loaders.has(k):
				_loaders[k].call(d[k])
		if d.has("cam_yaw"): orbit_yaw = float(d["cam_yaw"])
		if d.has("cam_pitch"): orbit_pitch = float(d["cam_pitch"])
		if d.has("cam_dist"): orbit_dist = float(d["cam_dist"])
		_update_orbit_camera()
		print("[look_dev] loaded settings ← ", p)
		return
	print("[look_dev] no saved settings found yet")
