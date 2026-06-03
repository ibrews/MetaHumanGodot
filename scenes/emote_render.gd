extends Node3D

# Emote render scene — v29 material overhaul
# Drives a 5-keypose ARKit emote on a MetaHuman GLB assembled in Blender.
#
# Key changes from v28:
#   - MatMADNESS skin_shader on face + body (SSS, micro detail, real roughness from SRMF G)
#   - MatMADNESS eye_shader on eyeball surface 5 (proper iris/sclera + parallax)
#   - Hair cards: threshold raised to 0.65–0.80 (was 0.30 = too dense = solid sheets)
#   - ACES tonemap, warm-sky environment, rim light for depth separation
#   - _EYE_BIAS reduced to 0.15 (proper shaders don't need forced-wide bias)
#
# Headless render:
#   Godot ... --write-movie out/sequence.avi --fixed-fps 30
#       --quit-after <total frames>  --path <godot_project/>  --scene scenes/emote_render.tscn

const CHARACTER_GLB: String = "res://character.glb"

# Surface-index map for MetaHumanFace (re-verified 2026-05-27 via Godot
# surface_get_arrays probe in scenes/probe_face_surfaces.gd — material NAMES
# are shuffled by Blender's GLB export and don't reflect actual geometry.
# Trust the probe, not the names):
#   0  bulk face skin (12227 verts, full face bounds) — material named "Teeth"
#   1  small lower-face area (3356 verts, Y=1.72-1.77) — "M_Hide_0"
#   2  mouth-area band (424 verts, Y=1.74-1.76) — "EyeL_Baked" but NOT the eye
#   3  RIGHT eyeball sphere (386 verts, X=+0.02..+0.05, Y=1.81-1.84, full UV)
#   4  LEFT eyeball sphere (386 verts, X=-0.05..-0.02, Y=1.81-1.84, full UV)
#   5  lacrimal-fluid horizontal strip (330 verts, in front of both eyes —
#      MUST hide, otherwise it occludes the spheres with a flat-strip iris
#      that looks like a horror-eye oval)
#   6  hidden geometry around eye area (1560 verts)
#   7  small face-skin patch around eyes (276 verts)
#   8  eyelashes strip (338 verts, narrow UV band)

const HIDE_SLOT_PATTERNS: Array = ["eyeshell", "lacrimal", "m_hide", "mi_hide"]

# Slight eye-open bias so rest-pose lids don't droop. 0.15 is enough with
# proper MatMADNESS eye shaders (previously needed 0.40 because the eye
# shader itself was wrong, not the lids).
const _EYE_BIAS: float = 0.0

const KEYPOSES: Dictionary = {
	"neutral": {
		"eyeWideLeft": _EYE_BIAS, "eyeWideRight": _EYE_BIAS,
	},
	"smile": {
		"mouthSmileLeft": 1.0, "mouthSmileRight": 1.0,
		"cheekSquintLeft": 0.4, "cheekSquintRight": 0.4,
		"eyeWideLeft": _EYE_BIAS * 0.5, "eyeWideRight": _EYE_BIAS * 0.5,
	},
	"surprise": {
		"jawOpen": 0.7, "browInnerUp": 1.0,
		"browOuterUpLeft": 0.8, "browOuterUpRight": 0.8,
		"eyeWideLeft": 0.95, "eyeWideRight": 0.95,
		"mouthFunnel": 0.4,
	},
	"blink": {
		"eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0,
	},
	"frown": {
		"mouthFrownLeft": 0.9, "mouthFrownRight": 0.9,
		"browDownLeft": 0.8, "browDownRight": 0.8,
		"mouthLowerDownLeft": 0.3, "mouthLowerDownRight": 0.3,
		"eyeWideLeft": _EYE_BIAS * 0.6, "eyeWideRight": _EYE_BIAS * 0.6,
	},
}

# Performance arc, timed to the push-in: range early/mid while wide→medium
# (smile, surprise, frown), then LAND and HOLD a warm smile as the camera
# settles close on the face — an appealing final beat for a social hero clip.
const KEY_TIMES: Array = [
	[0.0, "neutral"],
	[0.7, "smile"],
	[1.9, "neutral"],
	[2.5, "surprise"],
	[3.5, "neutral"],
	[3.9, "blink"],
	[4.3, "frown"],
	[5.0, "neutral"],
	[5.7, "smile"],
	[8.2, "smile"],
]

const ANIM_DURATION: float = 8.4

var face_mesh: MeshInstance3D
var animation_player: AnimationPlayer

# Procedural body idle — breathing animation driven in _process via spine_03 bone scale.
# Composes cleanly with the AnimationPlayer face shape-key animation (different system).
var body_skeleton: Skeleton3D
var spine_bone_idx: int = -1
var spine_rest_scale: Vector3 = Vector3.ONE

# Runtime head tracking + LeaderPose seam fix (ported from release.gd 2026-06-02;
# see memory reference-godot-leaderpose-seam-fix). character.glb has TWO skeletons:
# the BODY skeleton (metahuman_base_skel, 341 bones) drives the body + outfit, and a
# SEPARATE FACE skeleton (Face_Archetype_Skeleton, 874 bones, carries the FACIAL_*
# bones) skins the face mesh = head + neck + bust-cap. The body idle animates only the
# body skeleton. The OLD code rigidly slaved the whole FaceArmature NODE to the body
# 'head' bone, which rode the bust-cap UP through the shirt collar while the body chest
# stayed put → a pale seam. The fix emulates UE's SetLeaderPoseComponent: each frame we
# drive every bone the FACE skel SHARES by name with the BODY skel so the neck/clavicle/
# bust deforms WITH the body (seam stays glued) while the head still bobs with the head
# bone. The FaceArmature NODE is left at its native bind transform, and FACIAL_* bones
# stay at rest, so the blend-shape emote (and the eyeball spheres) are untouched.
var head_bone_idx_body: int = -1
# Drift-free head-world reconstruction for the camera: the body skeleton's Node3D
# transform DRIFTS during the root-motion idle (Skeleton3D.position is animated while
# bone poses compensate), so we rebuild the rendered head world pos from the bind-time
# skeleton transform rather than reading the live node.
var skel_basis_norm: Basis = Basis.IDENTITY                  # body skeleton's orthonormalized world basis (bind)
var skel_scale_factor: float = 1.0                           # ~0.01 (cm→m)
var skel_bind_origin: Vector3 = Vector3.ZERO                 # body skeleton.global.origin at bind
# The CRITICAL subtlety: the two rigs were exported as separate FBXes, so
# automatic_bone_orientation chose different LOCAL rest frames (shared-bone rest deltas
# up to 180°). A raw local get_bone_pose→set_bone_pose copy distorts; we transfer motion
# through GLOBAL poses — desired face global PFg = PBg · rest_xfer, where
# rest_xfer = RBg⁻¹ · RFg (each rig's own rest global), precomputed per shared bone.
var _face_skel: Skeleton3D                                   # face mesh's skeleton (the one with FACIAL_L_Eye)
var _leader_pairs: Array = []                                # [body_idx, face_idx, face_parent_idx, rest_xfer], parent-first

# body_static: when the body has no idle animation (e.g. a future static-body render),
# the body skeleton stays put and the face is already at its correct native bind-pose
# from the GLB, so the LeaderPose copy + head tracking are unnecessary. Gates _process off.
var body_static: bool = false
var _dbg_count: int = 0

# Cinematic push-in camera (dramatic, square 1:1, dolly from wide body to face).
var camera: Camera3D
var cam_attrs: CameraAttributesPractical
var catch_light: OmniLight3D
var _elapsed: float = 0.0
var _head_world: Vector3 = Vector3(0.0, 1.78, 0.05)   # latest tracked face/head world pos
const PUSH_DURATION: float = 7.2                       # dolly spans the (longer) emote
# Wide framing (start): slight 3/4, head + torso. Close (end): face fills frame.
const CAM_WIDE_POS: Vector3 = Vector3(0.52, 1.60, 2.30)
const CAM_CLOSE_POS: Vector3 = Vector3(0.15, 1.80, 0.70)   # tight on the face to show detail
const CAM_WIDE_FOV: float = 34.0
const CAM_CLOSE_FOV: float = 29.0
const CAM_WIDE_AIM: Vector3 = Vector3(0.0, 1.52, 0.0)   # aim lower (chest/face) when wide
const CAM_CLOSE_AIM_YOFF: float = 0.05                  # aim just above head bone (eyes) when close


func _ready() -> void:
	_setup_environment()
	_setup_reflection()
	_setup_lights()
	_setup_camera()
	var character_root: Node3D = _instantiate_character()
	if character_root == null:
		push_error("[emote_render] failed to load character GLB")
		return
	_apply_materials(character_root)
	face_mesh = _find_face_mesh(character_root)
	if face_mesh == null:
		push_error("[emote_render] face mesh not found")
		return
	print("[emote_render] face mesh: %s (%d blend shapes)" % [face_mesh.name, face_mesh.mesh.get_blend_shape_count()])
	_resolve_body_skeleton(character_root)
	# Stop any auto-playing imported AnimationPlayer so the rest pose is stable
	# when _capture_head_world_ref()/_build_leader_pose_map() read the rest data.
	var stack: Array[Node] = [character_root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			(n as AnimationPlayer).stop()
		for c in n.get_children():
			stack.append(c)
	await get_tree().process_frame   # let the stop settle before capturing rest data
	_capture_head_world_ref()                 # head-bone world ref for the push-in camera
	_resolve_face_skeleton(character_root)    # the FACIAL_* (face mesh) skeleton
	_build_leader_pose_map()                  # seam fix: shared body↔face bones for the LeaderPose copy
	_build_animation(character_root)
	if not OS.has_environment("NO_BODY_IDLE"):
		_play_body_idle(character_root)


func _play_body_idle(character_root: Node) -> void:
	# Phase 10: AS_Unarmed_Idle_Ready was baked into the GLB via Blender.
	# Godot's glTF importer creates an AnimationPlayer inside the imported
	# scene with the body action(s). Find it and play the first animation.
	# Bone tracks (body skeleton) compose cleanly with the script-built
	# 'emote' AnimationPlayer (face blend shapes) — different target system,
	# no conflict.
	var stack: Array[Node] = [character_root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			var ap: AnimationPlayer = n
			var names: PackedStringArray = ap.get_animation_list()
			if names.size() == 0:
				continue
			# Loop the body idle so a 6.83s render gets continuous motion even
			# if the action is shorter or runs short of the emote tail.
			var anim_name: String = names[0]
			var anim: Animation = ap.get_animation(anim_name)
			if anim:
				anim.loop_mode = Animation.LOOP_LINEAR
			ap.play(anim_name)
			print("[emote_render] body idle: %s playing '%s' (%.2fs%s)" % [
				ap.get_path(), anim_name,
				anim.length if anim else 0.0,
				", looping" if anim else ""])
			return
		for child in n.get_children():
			stack.append(child)
	body_static = true
	push_warning("[emote_render] no body AnimationPlayer found — body static; disabling runtime LeaderPose seam-follow (face stays at native bind pose)")


func _capture_head_world_ref() -> void:
	# Capture the reference data needed to reconstruct the body 'head' bone's REAL
	# rendered world position at runtime, for the push-in camera to track the face.
	# The body skeleton's Node3D transform DRIFTS during the root-motion idle
	# (Skeleton3D.position is animated while bone poses compensate), but the mesh
	# renders stably, so we rebuild the bone world pos from the bind-time skeleton
	# transform:  head_world = skel_bind_origin + skel_basis_norm * (bone_local · scale).
	# (The face mesh is glued to the body by the per-bone LeaderPose copy below, NOT by
	# moving the FaceArmature node — so there is no whole-armature rest transform to grab.)
	if body_skeleton == null:
		push_warning("[emote_render] body skeleton not bound — can't capture head ref")
		return
	head_bone_idx_body = body_skeleton.find_bone("head")
	if head_bone_idx_body < 0:
		push_warning("[emote_render] body has no 'head' bone")
		return
	var skel_basis: Basis = body_skeleton.global_transform.basis
	skel_basis_norm = skel_basis.orthonormalized()
	skel_scale_factor = skel_basis.x.length()
	skel_bind_origin = body_skeleton.global_transform.origin
	print("[emote_render] head ref captured: head idx=%d skel_bind_origin=%s skel_scale=%.4f" % [
		head_bone_idx_body, skel_bind_origin, skel_scale_factor])


func _resolve_face_skeleton(root: Node) -> void:
	# The face mesh (head + neck + bust-cap) is skinned by the MetaHuman FACE skeleton —
	# the one carrying the FACIAL_* bones. Identify it by FACIAL_L_Eye (the BODY skeleton
	# has spine/head but never the facial bones). This is the skeleton the LeaderPose copy
	# drives; FACIAL_* bones are deliberately left out of the map so the emote/eyes hold.
	_face_skel = null
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D and (n as Skeleton3D).find_bone("FACIAL_L_Eye") >= 0:
			_face_skel = n as Skeleton3D
			return
		for c in n.get_children():
			stack.append(c)
	push_warning("[emote_render] face skeleton (FACIAL_L_Eye) not found — LeaderPose seam fix disabled")


func _build_leader_pose_map() -> void:
	# For every BODY bone that the FACE skeleton also has (by name), precompute
	# rest_xfer = RBg⁻¹ · RFg (each rig's own rest global pose) so per frame we only do
	# PFg = PBg · rest_xfer. Sorted by face-bone index so parents are driven before
	# children (Godot keeps a bone's parent index below its own). The shared set is the
	# bust region: pelvis→spine→neck→head→clavicle→upperarm — exactly what must move with
	# the body to keep the collar glued, while the head still bobs with the head bone.
	_leader_pairs.clear()
	if body_skeleton == null or _face_skel == null:
		push_warning("[emote_render] leader-pose map skipped (body or face skeleton missing)")
		return
	for bi in range(body_skeleton.get_bone_count()):
		var fi: int = _face_skel.find_bone(body_skeleton.get_bone_name(bi))
		if fi < 0:
			continue
		var rest_xfer: Transform3D = body_skeleton.get_bone_global_rest(bi).affine_inverse() \
			* _face_skel.get_bone_global_rest(fi)
		_leader_pairs.append([bi, fi, _face_skel.get_bone_parent(fi), rest_xfer])
	_leader_pairs.sort_custom(func(a, b): return a[1] < b[1])
	print("[emote_render] leader-pose map: %d shared bones (body %d / face %d)" % [
		_leader_pairs.size(), body_skeleton.get_bone_count(), _face_skel.get_bone_count()])


func _apply_leader_pose() -> void:
	# Per-frame: set each shared face bone's pose so its GLOBAL pose tracks the body's
	# global motion (PFg = PBg · rest_xfer). Cache the desired face global per bone and
	# convert to a local pose via the (already-computed, parent-first) parent global —
	# no skeleton readback, no dependence on Godot's recompute order. FACIAL_* bones are
	# never in the map, so they (incl. the eyes) stay at rest and the blend-shape emote
	# is untouched. At rest PBg = RBg → PFg = RFg → no distortion.
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
	# Restore every driven face bone to its local rest. emote_render plays the body idle
	# for the whole clip and never stops it, so this is currently only reached if a future
	# caller toggles the idle off — kept for parity with release.gd's _set_body_anim(false).
	if _face_skel == null:
		return
	for pair in _leader_pairs:
		var fi: int = pair[1]
		var r: Transform3D = _face_skel.get_bone_rest(fi)
		_face_skel.set_bone_pose_position(fi, r.origin)
		_face_skel.set_bone_pose_rotation(fi, r.basis.get_rotation_quaternion())
		_face_skel.set_bone_pose_scale(fi, r.basis.get_scale())


func _resolve_body_skeleton(root: Node) -> void:
	# Find the BODY Skeleton3D. CAUTION: the MetaHuman Face_Archetype_Skeleton
	# (under FaceArmature, 874 bones) ALSO contains the full body hierarchy
	# including 'spine_03' and 'head' — so "first skeleton with spine_03" is
	# ambiguous and used to wrongly pick the FACE skeleton, which the body idle
	# never animates (the runtime face-follow then read a static head bone and
	# trans_delta was always 0 → the head did NOT track body motion).
	#
	# The body skeleton (metahuman_base_skel, 341 bones, under BodyArmature) is
	# the one the idle animates and has FAR fewer bones than the face skeleton.
	# Collect every candidate with spine_03+head and prefer non-FaceArmature
	# ancestry, then fewest bones (body=341 < face=874).
	var candidates: Array[Skeleton3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			var s: Skeleton3D = n
			if s.find_bone("spine_03") >= 0 and s.find_bone("head") >= 0:
				candidates.append(s)
		for child in n.get_children():
			stack.append(child)
	if candidates.is_empty():
		push_warning("[emote_render] no skeleton with spine_03+head found — face-follow disabled")
		return
	var best: Skeleton3D = candidates[0]
	for s in candidates:
		var under_face: bool = _has_ancestor_named(s, "FaceArmature")
		var best_under_face: bool = _has_ancestor_named(best, "FaceArmature")
		if (best_under_face and not under_face) \
				or (under_face == best_under_face and s.get_bone_count() < best.get_bone_count()):
			best = s
	body_skeleton = best
	spine_bone_idx = best.find_bone("spine_03")
	spine_rest_scale = best.get_bone_pose_scale(spine_bone_idx)
	print("[emote_render] body skeleton: %s  bones=%d  spine_03 idx=%d  (candidates=%d)"
		  % [best.name, best.get_bone_count(), spine_bone_idx, candidates.size()])


func _envf(name: String, def: float) -> float:
	return float(OS.get_environment(name)) if OS.has_environment(name) else def


func _has_ancestor_named(node: Node, target: String) -> bool:
	var p: Node = node.get_parent()
	while p != null:
		if String(p.name).begins_with(target):
			return true
		p = p.get_parent()
	return false


func _process(delta: float) -> void:
	# Deterministic clock under --fixed-fps; drives the camera push-in.
	_elapsed += delta

	# Runtime LeaderPose (collar-seam fix). Drive the FACE skeleton's shared bones from
	# the animated BODY skeleton so the neck/clavicle/bust-cap deforms WITH the body
	# (closing the collar seam) while the head still bobs with the head bone. The
	# FaceArmature NODE stays at its native bind transform; FACIAL_* bones (incl. the
	# eyeball spheres) stay at rest, so the blend-shape emote is untouched. body_static
	# gates this off for a future static-body render (no idle → face already at bind pose).
	# (The Phase 11 spine_03 breathing scale was retired — all body motion comes from the
	# authored AnimationPlayer idle.)
	if not body_static and body_skeleton != null and head_bone_idx_body >= 0:
		# Reconstruct the head bone's REAL world position (drift-free, from the bind-pose
		# skeleton transform) so the push-in camera keeps aiming at the face.
		var head_local_pose: Transform3D = body_skeleton.get_bone_global_pose(head_bone_idx_body)
		_head_world = skel_bind_origin + skel_basis_norm * (head_local_pose.origin * skel_scale_factor)
		# Glue the face mesh to the body via the per-bone LeaderPose copy.
		if _face_skel != null and not _leader_pairs.is_empty():
			_apply_leader_pose()
		if OS.has_environment("FOLLOW_DEBUG"):
			_dbg_count += 1
			if _dbg_count % 30 == 0:
				print("[follow] f%d leader_bones=%d head_world=%s" % [
					_dbg_count, _leader_pairs.size(), _head_world])

	# Cinematic push-in (runs every frame, independent of the body state).
	_update_camera()


func _setup_environment() -> void:
	# Dramatic-cinematic studio: a very dim sky for ambient/reflection only
	# (skin + eyes need *something* to reflect or they read flat/plastic), with
	# the visible background handled by a dark gradient backdrop plane. Deep
	# shadows, filmic grade, subtle bloom — game-reveal-trailer look.
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.05, 0.07, 0.12)         # cool blue ambient
	sky_mat.sky_horizon_color = Color(0.06, 0.08, 0.12)
	sky_mat.ground_horizon_color = Color(0.04, 0.04, 0.05)
	sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)
	sky_mat.sun_angle_max = 1.0
	sky_mat.energy_multiplier = 0.6
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	var look_light: bool = OS.has_environment("LOOK_LIGHT")
	if look_light:
		# Bright neutral studio (turntable/product look).
		sky_mat.sky_top_color = Color(0.42, 0.45, 0.52)
		sky_mat.sky_horizon_color = Color(0.50, 0.52, 0.56)
		sky_mat.ground_horizon_color = Color(0.45, 0.46, 0.48)
		sky_mat.ground_bottom_color = Color(0.30, 0.30, 0.32)
		sky_mat.energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Portrait default: lift ambient so the shadow side reads soft (not crushed noir).
	# DRAMATIC=1 restores the old moody near-black fill.
	var dramatic: bool = OS.has_environment("DRAMATIC")
	env.ambient_light_energy = 1.05 if look_light else (0.22 if dramatic else _envf("AMBIENT", 0.07))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# ACES filmic tone-mapping with natural skin highlight rolloff
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.95 if look_light else (0.78 if dramatic else _envf("EXPOSURE", 0.82))
	env.tonemap_white = 6.0
	# Contact shadows / micro-occlusion for depth
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.2
	env.ssao_power = 1.5
	env.ssr_enabled = false
	# Subtle bloom on the rim/catchlights and bright skin speculars
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.10
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.05
	# Filmic color grade — a touch of contrast + saturation punch
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.12 if dramatic else 1.05
	env.adjustment_saturation = 1.10
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	we.name = "WorldEnvironment"
	add_child(we)

	_setup_backdrop()


func _setup_backdrop() -> void:
	# Dark studio seamless with a soft brighter pool behind the subject — the
	# classic "spotlight on the backdrop" that separates the silhouette and
	# fakes a vignette. Unshaded radial gradient so lighting never washes it out.
	var grad: Gradient = Gradient.new()
	if OS.has_environment("LOOK_LIGHT"):
		grad.set_color(0, Color(0.78, 0.79, 0.82))    # bright seamless
		grad.add_point(0.5, Color(0.56, 0.57, 0.60))
		grad.set_color(1, Color(0.34, 0.35, 0.38))
	elif OS.has_environment("DRAMATIC"):
		grad.set_color(0, Color(0.22, 0.24, 0.32))    # bright pool (halo behind head)
		grad.add_point(0.5, Color(0.07, 0.08, 0.12))
		grad.set_color(1, Color(0.010, 0.012, 0.018)) # near-black edges
	else:
		# Portrait: dim neutral-warm room (like the reference's soft olive backdrop) —
		# a gentle pool behind the head, never pure black, so it reads as a real space.
		grad.set_color(0, Color(0.20, 0.19, 0.17))    # warm grey pool behind head
		grad.add_point(0.5, Color(0.10, 0.10, 0.10))
		grad.set_color(1, Color(0.035, 0.037, 0.043)) # dim, not black
	var tex: GradientTexture2D = GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 1024
	tex.height = 1024
	tex.fill = GradientTexture2D.FILL_RADIAL
	# Center the pool HIGH so the halo reads above the shoulders, not hidden
	# behind the torso. Tighter falloff keeps it a defined pool, not a wash.
	tex.fill_from = Vector2(0.5, 0.30)
	tex.fill_to = Vector2(0.92, 0.78)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var plane: MeshInstance3D = MeshInstance3D.new()
	plane.name = "Backdrop"
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(7.0, 7.0)
	plane.mesh = quad
	plane.material_override = mat
	plane.position = Vector3(0.0, 1.35, -2.0)
	add_child(plane)


func _setup_reflection() -> void:
	# Give the eyes (low-roughness + corneal clearcoat) and skin something real to
	# reflect. A ReflectionProbe bakes the surrounding scene into a cubemap; an
	# off-camera emissive "softbox" provides a bright, shaped source that reads as
	# a crisp eye catchlight in the reflection. The softbox is on render layer 2,
	# which the main camera excludes (see _setup_camera) — visible only in
	# reflections, never directly in frame.
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
	m.emission_energy_multiplier = 14.0   # bright eye catch but not a pure-white blowout
	sb.material_override = m
	sb.layers = 1 << 1                         # render layer 2 — reflections only
	sb.position = Vector3(0.35, 2.35, 0.95)    # upper-front, out of camera frame
	add_child(sb)
	sb.look_at(Vector3(0.0, 1.80, 0.05), Vector3.UP)

	var probe: ReflectionProbe = ReflectionProbe.new()
	probe.name = "ReflProbe"
	probe.size = Vector3(5.0, 5.0, 5.0)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.intensity = 2.6
	probe.max_distance = 10.0
	probe.interior = false
	probe.position = Vector3(0.0, 1.6, 0.0)
	add_child(probe)


func _setup_lights() -> void:
	# Dramatic 3-point. Strong warm KEY raking from camera-right + a strong cool
	# RIM/kicker from behind-left for the signature edge-separation glow.
	# Minimal fill so the shadow side stays moody (but not pure black).
	# Soft, warm KEY — calmer than before, big penumbra (angular size + blur) so
	# shadows are gentle, not hard. Slightly off warm so the cool fill can do the
	# cinematic teal-shadow contrast.
	var look_light: bool = OS.has_environment("LOOK_LIGHT")
	var dramatic: bool = OS.has_environment("DRAMATIC")
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.name = "KeyLight"
	# Portrait: soft warm key, larger angular size = softer shadow edges, raked a bit
	# more from above so the hair casts a real shadow onto the forehead/scalp.
	key.light_energy = 2.0 if look_light else (1.55 if dramatic else _envf("KEY", 3.6))
	key.light_color = Color(1.0, 0.98, 0.94) if look_light else (Color(1.0, 0.95, 0.87) if dramatic else Color(1.0, 0.90, 0.76))
	key.shadow_enabled = true
	key.shadow_bias = 0.04
	key.shadow_normal_bias = 2.0
	key.shadow_blur = 2.0 if dramatic else 3.5     # softer penumbra for portrait
	key.light_angular_distance = 2.5 if dramatic else 4.5
	key.rotation = Vector3(deg_to_rad(-22.0 if dramatic else -26.0), deg_to_rad(-50.0 if dramatic else -52.0), 0.0)
	add_child(key)

	# Rim/back kicker: cool blue, up-and-behind — carves hair/jaw/shoulder out of
	# the dark (bloom turns it into a cinematic glow). Softened a bit from before.
	var rim: DirectionalLight3D = DirectionalLight3D.new()
	rim.name = "RimLight"
	rim.light_energy = 1.4 if look_light else (1.7 if dramatic else _envf("RIM", 3.5))
	rim.light_specular = 0.25                        # rim is for edge fill, not a spec hotspot
	rim.light_color = Color(0.9, 0.93, 1.0) if look_light else (Color(0.6, 0.72, 1.0) if dramatic else Color(0.34, 0.58, 1.0))
	rim.shadow_enabled = false
	rim.rotation = Vector3(deg_to_rad(-45.0), deg_to_rad(150.0), 0.0)
	add_child(rim)

	# FILL — bright neutral in studio look; cool-blue teal fill in dramatic look.
	var fill: DirectionalLight3D = DirectionalLight3D.new()
	fill.name = "FillLight"
	# Dramatic look: very low fill so the shadow side of the face goes deep/dark
	# (mysterious, one-sided key). Studio look keeps a bright even fill.
	# Portrait fill is the big change: a real cool soft fill (~0.7) so the shadow side
	# reads with soft subsurface modelling instead of crushing to black. (Reference has
	# a clear cool fill on the shadow cheek.) Dramatic keeps the near-black 0.07.
	fill.light_energy = 1.15 if look_light else (0.07 if dramatic else _envf("FILL", 1.0))
	fill.light_color = Color(0.92, 0.94, 1.0) if look_light else (Color(0.45, 0.60, 1.0) if dramatic else Color(0.26, 0.50, 1.0))
	fill.shadow_enabled = false
	# Portrait: pull the cool fill round to the OPPOSITE side of the warm key and rake
	# it (not frontal) so it reads as a distinct cool side-key — warm cheek / cool cheek
	# split with a dark centre line. Dramatic/studio keep the gentle frontal fill.
	if look_light or dramatic:
		fill.rotation = Vector3(deg_to_rad(-10.0), deg_to_rad(46.0), 0.0)
	else:
		fill.rotation = Vector3(deg_to_rad(-8.0), deg_to_rad(48.0), 0.0)
	add_child(fill)

	# Catchlight: small bright omni near camera for the eye spark + lifts the
	# orbital floor a touch. Tracks toward the face; updated in _update_camera.
	# Small + dim — an EYE SPARK only. A strong frontal catchlight was flattening
	# the face (washing out the key's modeling) while the legs, which get no
	# catchlight, showed beautiful directional chiaroscuro. Keep it tiny so the
	# face reads with the same dramatic key/shadow falloff as the body.
	catch_light = OmniLight3D.new()
	catch_light.name = "CatchLight"
	# This frontal tracking omni is the #1 face-flattener — at 0.7 it fills the shadow
	# side head-on and kills the warm/cool modelling. For portrait keep it an EYE SPARK
	# only (~0.12 diffuse, spec still gives the glint). CATCH env to tune / 0 to kill.
	catch_light.light_energy = (1.0 if look_light else (0.7 if dramatic else _envf("CATCH", 0.12)))
	catch_light.light_color = Color(1.0, 0.97, 0.93)
	catch_light.light_specular = 1.0           # visible eye glint but kept just under pure-white
	catch_light.shadow_enabled = false
	catch_light.omni_range = 1.5
	catch_light.omni_attenuation = 2.6
	catch_light.position = Vector3(0.10, 1.80, 1.10)
	add_child(catch_light)


func _setup_camera() -> void:
	# Cinematic push-in: starts on a wide 3/4 of the body (idle reads) and
	# slowly dollies into the face for the smile→surprise→frown performance.
	# Shallow depth of field throws the dark backdrop out of focus; the focus
	# distance tracks the face every frame in _update_camera().
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.near = 0.05
	camera.far = 50.0
	camera.current = true
	# Exclude render layer 2 (the off-camera softbox) — the reflection probe still
	# captures it for eye catchlights, but it never shows directly in frame.
	camera.cull_mask = 1048575 & ~(1 << 1)

	cam_attrs = CameraAttributesPractical.new()
	cam_attrs.dof_blur_far_enabled = true
	cam_attrs.dof_blur_far_distance = 2.3       # updated per-frame to the face
	cam_attrs.dof_blur_far_transition = 0.6
	cam_attrs.dof_blur_near_enabled = true
	cam_attrs.dof_blur_near_distance = 0.4
	cam_attrs.dof_blur_near_transition = 0.5
	cam_attrs.dof_blur_amount = 0.10
	camera.attributes = cam_attrs
	add_child(camera)

	if OS.has_environment("FACE_CLOSEUP"):
		camera.position = Vector3(0.0, 1.82, 0.30)
		camera.rotation = Vector3(deg_to_rad(-2.0), 0.0, 0.0)
		camera.fov = 16.0
	else:
		# Initialise at the wide framing; _update_camera() animates from here.
		camera.position = CAM_WIDE_POS
		camera.fov = CAM_WIDE_FOV
		camera.look_at(CAM_WIDE_AIM, Vector3.UP)


func _update_camera() -> void:
	if camera == null or OS.has_environment("FACE_CLOSEUP"):
		return
	# FACE_STILL: parameterized still camera for honing detail / multi-angle stills.
	# Env: STILL_YAW (deg, orbit), STILL_DIST (m), STILL_FOV, STILL_AIMY (extra
	# height on the aim), STILL_ELEV (camera height offset). No push-in.
	if OS.has_environment("FACE_STILL"):
		var yaw: float = deg_to_rad(_envf("STILL_YAW", 0.0))
		var dist: float = _envf("STILL_DIST", 0.58)
		var aimy: float = _envf("STILL_AIMY", 0.02)
		var elev: float = _envf("STILL_ELEV", 0.0)
		var aim_s: Vector3 = Vector3(0.0, _head_world.y + aimy, _head_world.z + 0.02)
		camera.position = aim_s + Vector3(sin(yaw) * dist, elev, cos(yaw) * dist)
		camera.fov = _envf("STILL_FOV", 26.0)
		camera.look_at(aim_s, Vector3.UP)
		var fds: float = camera.global_transform.origin.distance_to(aim_s)
		cam_attrs.dof_blur_far_distance = fds + 0.20
		cam_attrs.dof_blur_near_distance = maxf(0.15, fds - 0.35)
		if catch_light:
			catch_light.position = aim_s + Vector3(0.1, 0.25, 0.5)
		return
	# ORBIT variant: slow arc around the figure showing the full 3D model.
	if OS.has_environment("ORBIT"):
		var op: float = smoothstep(0.0, 1.0, clampf(_elapsed / 7.0, 0.0, 1.0))
		var ang: float = deg_to_rad(lerpf(-58.0, 58.0, op))
		var radius: float = 3.5
		var aimc: Vector3 = Vector3(0.0, 1.05, 0.0)
		camera.position = Vector3(sin(ang) * radius, 1.02, cos(ang) * radius)
		camera.fov = 36.0
		camera.look_at(aimc, Vector3.UP)
		var fd: float = camera.global_transform.origin.distance_to(aimc)
		cam_attrs.dof_blur_far_distance = fd + 0.7
		cam_attrs.dof_blur_near_distance = maxf(0.2, fd - 0.9)
		if catch_light:
			catch_light.position = aimc + (camera.global_transform.origin - aimc).normalized() * 0.6 + Vector3(0, 0.75, 0)
		return
	# Default: smooth dolly + zoom from wide to close over PUSH_DURATION.
	# VERT (9:16) pulls the close framing back so the head isn't cropped in a
	# taller frame (vertical FOV is the same, so the face fills more).
	var close_pos: Vector3 = CAM_CLOSE_POS
	var close_fov: float = CAM_CLOSE_FOV
	if OS.has_environment("VERT"):
		close_pos = Vector3(0.14, 1.76, 1.18)
		close_fov = 30.0
	var p: float = clampf(_elapsed / PUSH_DURATION, 0.0, 1.0)
	p = smoothstep(0.0, 1.0, p)               # ease in/out
	var pos: Vector3 = CAM_WIDE_POS.lerp(close_pos, p)
	camera.position = pos
	camera.fov = lerpf(CAM_WIDE_FOV, close_fov, p)
	# Aim: blend from the wide chest/face point to the tracked face as we push in.
	var face_aim: Vector3 = _head_world + Vector3(0.0, CAM_CLOSE_AIM_YOFF, 0.0)
	var aim: Vector3 = CAM_WIDE_AIM.lerp(face_aim, p)
	camera.look_at(aim, Vector3.UP)
	# Keep the face tack-sharp; throw the backdrop out.
	var focus: float = camera.global_transform.origin.distance_to(face_aim)
	cam_attrs.dof_blur_far_distance = focus + 0.12
	cam_attrs.dof_blur_near_distance = maxf(0.15, focus - 0.45)
	# Catchlight rides just off the camera axis, in front of the eyes.
	if catch_light:
		catch_light.position = face_aim + (camera.global_transform.origin - face_aim).normalized() * 0.5 + Vector3(0.08, 0.24, 0.0)


func _instantiate_character() -> Node3D:
	var scene: PackedScene = load(CHARACTER_GLB)
	if scene == null:
		return null
	var inst: Node = scene.instantiate()
	inst.name = "Character"
	add_child(inst)
	return inst as Node3D


func _apply_materials(root: Node) -> void:
	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(root, mesh_instances)
	print("[emote_render] found %d mesh instances" % mesh_instances.size())

	for mi in mesh_instances:
		_apply_to_mesh_instance(mi)

	# ── Hair / groom cards ──────────────────────────────────────────────
	# hair_card.gdshader reads alpha channel (invert_mask=false for all).
	# Threshold governs strand density — higher = wispier / fewer pixels shown.
	# alpha channel diagnosis (probe_hair_alpha.py, 2026-05-27):
	#   character_Hair_S_Casual_RootUVSeedCoverage: A max=0.996, mean=0.367
	#     >0.80 = 16.9% of pixels (sparse individual strand cores) ← target
	#   character_Beard_M_MuttonChops_RootUVSeedCoverage: A max=0.843, mean=0.288
	#     >0.65 = ~20% of pixels (strand lines visible in alpha viz)
	#   Texture2D_0 (eyebrow atlas): A max=1.0, mean=0.429
	#     >0.80 = 30.8% of pixels (crisp strand lines from alpha viz)
	# Format: [name_prefix, atlas_path, hair_color, invert_mask, threshold, root_darken]
	var card_atlases: Array = [
		# [prefix, atlas, hair_color, invert_mask, threshold, root_darken, use_red_mask]
		# Real MetaHuman CardsAtlas_Attribute — R channel = per-strand coverage,
		# so cards mask into individual strands instead of opaque ribbons.
		# Hair blonder (dark-blond) + thicker: lower alpha_threshold keeps more strand
		# coverage so the cards fill in and the scalp doesn't read bald underneath.
		# Facial hair lifted toward blond too (kept a touch darker than the scalp).
		["Hair_",      "res://hair_attr.png",     Color(0.34, 0.27, 0.17), false, 0.070, 0.42, true],
		["Beard_",     "res://beard_attr.png",    Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
		["Eyebrows_",  "res://eyebrows_attr.png", Color(0.22, 0.16, 0.095), false, 0.060, 0.50, true],
		["Mustache_",  "res://mustache_attr.png", Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
		["Moustache_", "res://mustache_attr.png", Color(0.28, 0.205, 0.115), false, 0.12, 0.45, true],
	]
	var hair_shader: Shader = load("res://scenes/hair_card.gdshader") as Shader
	for mi in mesh_instances:
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
			push_warning("[emote_render] card atlas not found: %s" % atlas_path)
			continue
		var card_mat: ShaderMaterial = ShaderMaterial.new()
		card_mat.shader = hair_shader
		card_mat.set_shader_parameter("hair_color", entry[2])
		card_mat.set_shader_parameter("coverage_atlas", load(atlas_path) as Texture2D)
		card_mat.set_shader_parameter("invert_mask", entry[3])
		card_mat.set_shader_parameter("alpha_threshold", entry[4])
		card_mat.set_shader_parameter("root_darkening", entry[5])
		card_mat.set_shader_parameter("use_red_mask", entry.size() > 6 and entry[6])
		card_mat.set_shader_parameter("roughness_val", 0.72)   # less shine = strands don't blow white
		card_mat.set_shader_parameter("specular_val", 0.12)
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, card_mat)
		print("[emote_render] hair card %s  atlas=%s  threshold=%.2f" % [mi.name, atlas_path.get_file(), entry[4]])

		# Scalp hair only: add a solid hair-colored BACKING shell tucked just under
		# the strand cards so the bald scalp never shows through gaps (Sam's note).
		# Same geometry, inset along normals, hard coverage cutoff (no haze).
		if mi.name.begins_with("Hair_") and not OS.has_environment("NO_HAIR_BACKING"):
			var back_mat: ShaderMaterial = ShaderMaterial.new()
			back_mat.shader = load("res://scenes/hair_backing.gdshader") as Shader
			# A touch darker than the strands so it reads as shadowed under-hair.
			back_mat.set_shader_parameter("hair_color", Color(0.20, 0.155, 0.090))
			back_mat.set_shader_parameter("coverage_atlas", load(atlas_path) as Texture2D)
			back_mat.set_shader_parameter("use_red_mask", entry.size() > 6 and entry[6])
			back_mat.set_shader_parameter("cutoff", _envf("HAIR_BACK_CUT", 0.035))
			back_mat.set_shader_parameter("inset", _envf("HAIR_BACK_INSET", 0.009))
			var backing: MeshInstance3D = MeshInstance3D.new()
			backing.name = mi.name + "_Backing"
			backing.mesh = mi.mesh
			for s in range(mi.mesh.get_surface_count()):
				backing.set_surface_override_material(s, back_mat)
			mi.add_sibling(backing)
			backing.global_transform = mi.global_transform
			print("[emote_render] hair backing shell added under %s" % mi.name)

	# ── Body mesh ────────────────────────────────────────────────────────
	# StandardMaterial3D with body BC + N + SRMF G=roughness + scatter SSS.
	# The body mesh is renamed to "Body" by reassemble_metahuman.py for both
	# body sources (SK_BaseBody legacy, SKM_<MH>_BodyMesh current). The SKM
	# body has 1 material slot (MI_Body_Baked_VT); SK has many. Either way,
	# we apply the body skin material to every surface.
	for mi in mesh_instances:
		if mi.name != "Body":
			continue
		var body_mat: Material
		if OS.has_environment("SKIN_STD"):
			body_mat = _make_std_skin_material(
				"res://character_T_Body_BC_VT.png",
				"res://character_T_Body_N_VT.png",
				"res://character_T_Body_SRMF_VT.png",
				"res://T_Body_Scatter_VT.png")
		else:
			body_mat = _make_skin_shader_material(
				"res://character_T_Body_BC_VT.png",
				"res://character_T_Body_N_VT.png",
				"res://character_T_Body_SRMF_VT.png",
				"res://T_Body_Scatter_VT.png")
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, body_mat)
		print("[emote_render] MatMADNESS skin on body: %s (%d surfaces)" % [mi.name, mi.mesh.get_surface_count()])

	# ── Outfit (Phase 12-rework — MH_Test_Outfits: correct DG clothing) ──
	# Single SkeletalMesh "Outfit" carrying the bodyShapeD shirt + shorts
	# sections (8 material slots, all M_DG_bodyShapeD_Shirt/Short). The DG
	# garments are plain light cloth, so we wire a light-grey cloth material
	# to every surface to match the in-UE look. (Per-slot DG textures can be
	# layered later; this is the correct geometry on the correct skeleton.)
	for mi in mesh_instances:
		if mi.name != "Outfit":
			continue
		var outfit_mat: StandardMaterial3D = _make_outfit_material()
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, outfit_mat)
		print("[emote_render] outfit material on %s (%d surfaces)" % [mi.name, mi.mesh.get_surface_count()])

	# ── Shirt (Phase 8 — body+clothes integration) ──────────────────────
	# SK_TShirt mesh, renamed to "Shirt" in Blender, MI_Shirt material wired
	# in reassemble_metahuman.py. T_Shirt_ORMF: R=AO, G=Roughness, B=Metallic.
	# Prefer GLB-extracted textures (character_T_Shirt_*); fall back to loose
	# PNGs at project root if the GLB import didn't extract them.
	for mi in mesh_instances:
		if not mi.name.begins_with("Shirt"):
			continue
		var shirt_mat: StandardMaterial3D = _make_shirt_material()
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, shirt_mat)
		print("[emote_render] shirt material on %s (%d surfaces)" % [mi.name, mi.mesh.get_surface_count()])

	# ── Pants (Phase 12 — leg coverage) ─────────────────────────────────
	# Same channel layout as shirt (T_Pants_ORMF: R=AO G=Rough B=Metal A=Fuzz).
	# Override is required because Blender Principled BSDF's SeparateColor→
	# Roughness wiring doesn't survive GLB round-trip; we re-state the channel
	# mapping in StandardMaterial3D.
	for mi in mesh_instances:
		if not mi.name.begins_with("Pants"):
			continue
		var pants_mat: StandardMaterial3D = _make_pants_material()
		for s in range(mi.mesh.get_surface_count()):
			mi.set_surface_override_material(s, pants_mat)
		print("[emote_render] pants material on %s (%d surfaces)" % [mi.name, mi.mesh.get_surface_count()])


func _make_outfit_material() -> StandardMaterial3D:
	# MH_Test_Outfits = bodyShapeD DefaultGarment tee + shorts. The DG garments
	# are plain light cloth (white in the UE viewport). No dedicated BC/N/ORMF
	# textures are exported yet, so wire a neutral light-grey cloth: high
	# roughness, no metallic, subtle off-white tint. Backface-cull off so thin
	# cloth edges (collar, sleeve hem, short hem) don't drop out.
	# Charcoal fitted tee + shorts. Now with the REAL DG garment Normal + AO maps
	# (exported from UE) layered on for actual knit-fabric weave + stitch/seam
	# depth — turns the flat cloth into believable fabric. DG base color is plain
	# white, so we keep a charcoal albedo tint (reads better than white under the
	# strong key) and let the maps carry the detail.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.085, 0.092, 0.11, 1.0)   # charcoal, hint of cool
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


func _make_pants_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()

	# Prefer extracted GLB textures, fall back to loose PNGs.
	var bc_paths: Array = ["res://character_T_Pants_BaseColor.png", "res://T_Pants_BaseColor.png"]
	var n_paths: Array = ["res://character_T_Pants_Normal.png", "res://T_Pants_Normal.png"]
	var ormf_paths: Array = ["res://character_T_Pants_ORMF.png", "res://T_Pants_ORMF.png"]

	for p in bc_paths:
		if ResourceLoader.exists(p):
			mat.albedo_texture = load(p) as Texture2D
			break
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)

	for p in n_paths:
		if ResourceLoader.exists(p):
			mat.normal_enabled = true
			mat.normal_texture = load(p) as Texture2D
			mat.normal_scale = 1.0
			break

	mat.roughness = 1.0
	for p in ormf_paths:
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


func _make_shirt_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()

	# Prefer extracted GLB textures, fall back to loose PNGs.
	var bc_paths: Array = ["res://character_T_Shirt_BaseColor.png", "res://T_Shirt_BaseColor.png"]
	var n_paths: Array = ["res://character_T_Shirt_Normal.png", "res://T_Shirt_Normal.png"]
	var ormf_paths: Array = ["res://character_T_Shirt_ORMF.png", "res://T_Shirt_ORMF.png"]

	for p in bc_paths:
		if ResourceLoader.exists(p):
			mat.albedo_texture = load(p) as Texture2D
			break
	# Slight tint toward neutral gray so the default white shirt reads as fabric
	mat.albedo_color = Color(0.85, 0.85, 0.85, 1.0)
	if OS.has_environment("DIAG_SHIRT_RED"):
		mat.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
		mat.albedo_texture = null

	for p in n_paths:
		if ResourceLoader.exists(p):
			mat.normal_enabled = true
			mat.normal_texture = load(p) as Texture2D
			mat.normal_scale = 1.0
			break

	# T_Shirt_ORMF: R=AO, G=Roughness, B=Metallic, A=Fuzz
	mat.roughness = 1.0
	for p in ormf_paths:
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


func _make_skin_shader_material(
		bc_path: String,
		normal_path: String,
		srmf_path: String,
		scatter_path: String = "") -> ShaderMaterial:
	# MatMADNESS HumanShader (skin_shader_local.gdshader): wrapped-normal SSS +
	# double-spec + per-channel roughness — far more detailed/realistic skin than
	# StandardMaterial3D (which reads waxy under a strong key). Uses the baked MH
	# head/body textures. Default SSS path (old_lightwarp_fallof=false) needs no
	# lightwarp texture; noise/micro/AO disabled (we have no maps for them).
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_local.gdshader") as Shader
	if ResourceLoader.exists(bc_path):
		mat.set_shader_parameter("texture_albedo", load(bc_path) as Texture2D)
	mat.set_shader_parameter("albedo", Color(1, 1, 1, 1))
	if ResourceLoader.exists(normal_path):
		mat.set_shader_parameter("texture_normal", load(normal_path) as Texture2D)
	# normal_strength was 3.6 for the OLD smooth 2048 normal; the 8192 cine normal
	# already carries all pore/wrinkle relief, so 3.6 over-roughens into leather.
	# ~1.3 lets the real detail read without the harsh embossed look. Env-tunable.
	mat.set_shader_parameter("normal_strength", _envf("SKIN_NRM", 1.3))
	if ResourceLoader.exists(srmf_path):
		# SRMF: R=spec, G=roughness, B=metallic, A=fuzz. Shader picks G internally.
		mat.set_shader_parameter("texture_roughness", load(srmf_path) as Texture2D)
	mat.set_shader_parameter("roughness", 0.95)
	mat.set_shader_parameter("specular", 0.30)
	mat.set_shader_parameter("double_specularity", false)   # ×2 spec was blowing forehead highlights to white
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	# SSS — modest. High SSS lifts shadows and flattens the face under a strong
	# key (the "washed out" look). Keep it low so the key's directional modeling
	# reads (like the legs), just enough to avoid plastic.
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	# Real skin needs real subsurface — 0.13 read as dry/dead. ~0.42 gives the fleshy
	# soft terminator + translucency. Soft portrait lighting (below) means the higher
	# SSS no longer flattens the face the way it did under the harsh noir key.
	mat.set_shader_parameter("subsurface_scattering_strength", _envf("SKIN_SSS", 0.34))
	# skin_smoothness LOD-blurs the normal for the SSS diffuse. ~1.2 softens the
	# over-sharp shading (less leathery) while the relief still reads.
	mat.set_shader_parameter("skin_smoothness", _envf("SKIN_SMOOTH", 1.2))
	mat.set_shader_parameter("skin_fallof_smoothness", 1.05)
	mat.set_shader_parameter("old_lightwarp_fallof", false)
	# Pore-level MICRO-DETAIL normal (tiling) + CAVITY — the real MetaHuman skin
	# detail. Tiles over the 1024² base so close-ups show pores/texture. Cavity
	# darkens creases (AO) and the SSS in them.
	if ResourceLoader.exists("res://skin_micro_n.png"):
		mat.set_shader_parameter("texture_micro_detail", load("res://skin_micro_n.png") as Texture2D)
		mat.set_shader_parameter("use_micro_detail", true)
		mat.set_shader_parameter("micro_detail_scale", 22.0)
		# Was 1.15 — too strong on top of the 8192 normal = sandpaper skin. ~0.45 adds
		# subtle pore tooth without the leathery look (reference skin is smooth+fleshy).
		mat.set_shader_parameter("micro_normal_strength", _envf("SKIN_MICRO", 0.45))
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
	# MetaHuman Scatter map (T_Head_LOD1_Scatter_VT / T_Body_Scatter_VT) → drives
	# subsurface scattering per region for fleshy, translucent skin.
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


func _make_std_skin_material(
		bc_path: String,
		normal_path: String,
		srmf_path: String,
		scatter_path: String) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()

	# Albedo (base color)
	if ResourceLoader.exists(bc_path):
		mat.albedo_texture = load(bc_path) as Texture2D

	# Normal map
	if ResourceLoader.exists(normal_path):
		mat.normal_enabled = true
		mat.normal_texture = load(normal_path) as Texture2D
		mat.normal_scale = 1.0

	# Roughness from SRMF G channel (R=Spec, G=Roughness, B=Metallic, A=Fuzz)
	mat.roughness = 1.0
	if ResourceLoader.exists(srmf_path):
		mat.roughness_texture = load(srmf_path) as Texture2D
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	mat.metallic = 0.0
	mat.metallic_specular = 0.5

	# Subsurface scattering for skin translucency (modest — strong key + high SSS
	# reads waxy; keep it subtle so the skin stays believable under the dramatic key)
	mat.subsurf_scatter_enabled = true
	mat.subsurf_scatter_strength = 0.22
	if ResourceLoader.exists(scatter_path):
		mat.subsurf_scatter_texture = load(scatter_path) as Texture2D

	return mat


func _collect_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, out)


func _apply_to_mesh_instance(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	if mi.name.begins_with("Icosphere"):
		mi.queue_free()
		return
	# MetaHumanFace: per-surface-index wiring (Blender→GLB shuffles material names)
	if mi.name == "MetaHumanFace":
		if OS.has_environment("DIAG_PALETTE"):
			_apply_face_by_index_PALETTE_DIAG(mi)
		else:
			_apply_face_by_index(mi)
		return
	# Hair card meshes and body are handled in _apply_materials(); skip here.
	# Other meshes (teeth, eyelashes) fall through to generic wiring below.
	for i in range(mi.mesh.get_surface_count()):
		var orig_mat: Material = mi.mesh.surface_get_material(i)
		if orig_mat == null:
			continue
		var mat_name: String = orig_mat.resource_name if orig_mat.resource_name else ""
		var mat_low: String = mat_name.to_lower()
		var hide: bool = false
		for h in HIDE_SLOT_PATTERNS:
			if mat_low.find(h) >= 0:
				hide = true
				break
		if hide:
			var trans: StandardMaterial3D = StandardMaterial3D.new()
			trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			trans.albedo_color = Color(0, 0, 0, 0)
			mi.set_surface_override_material(i, trans)


func _apply_face_by_index_PALETTE_DIAG(mi: MeshInstance3D) -> void:
	var palette: Array = [
		Color(1.0, 0.0, 0.0), Color(0.0, 1.0, 0.0), Color(0.0, 0.0, 1.0),
		Color(1.0, 1.0, 0.0), Color(1.0, 0.0, 1.0), Color(0.0, 1.0, 1.0),
		Color(1.0, 0.5, 0.0), Color(0.5, 0.0, 1.0), Color(1.0, 1.0, 1.0),
	]
	for s in range(mi.mesh.get_surface_count()):
		var pal: StandardMaterial3D = StandardMaterial3D.new()
		pal.albedo_color = palette[s] if s < palette.size() else Color(0.5, 0.5, 0.5)
		pal.roughness = 0.5
		mi.set_surface_override_material(s, pal)


func _make_eye_material(side: String) -> ShaderMaterial:
	# side "_r"/"_l" → real baked textures eye_iris_R/L_bc etc.
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
	# Smaller iris so the white sclera shows around it; iris_scale fits the FULL
	# iris (with its radial fiber detail) into that smaller disc instead of a flat
	# brown blob. Higher eye-normal so the iris fiber reads.
	mat.set_shader_parameter("iris_radius", 0.155)
	mat.set_shader_parameter("blend_softness", 0.02)
	mat.set_shader_parameter("iris_scale", 1.9)
	mat.set_shader_parameter("sclera_tint", 0.35)
	mat.set_shader_parameter("normal_strength", 0.55)
	mat.set_shader_parameter("roughness_val", 0.03)
	mat.set_shader_parameter("specular_val", 1.0)
	return mat


func _apply_face_by_index(mi: MeshInstance3D) -> void:
	# ── Face skin (surfaces 0 and 7) ────────────────────────────────────
	# MatMADNESS skin shader for detailed, non-waxy skin (SKIN_STD=1 falls back
	# to StandardMaterial3D for comparison).
	var face_mat: Material
	if OS.has_environment("SKIN_STD"):
		face_mat = _make_std_skin_material(
			"res://character_T_Head_LOD1_BC_VT.png",
			"res://character_T_Head_LOD1_N_VT.png",
			"res://character_T_Head_LOD1_SRMF_VT.png",
			"res://T_Head_LOD1_Scatter_VT.png")
	else:
		face_mat = _make_skin_shader_material(
			"res://character_T_Head_LOD1_BC_VT.png",
			"res://character_T_Head_LOD1_N_VT.png",
			"res://character_T_Head_LOD1_SRMF_VT.png",
			"res://T_Head_LOD1_Scatter_VT.png")

	# ── Teeth (surface 1) ───────────────────────────────────────────────
	var teeth_mat: StandardMaterial3D = StandardMaterial3D.new()
	if ResourceLoader.exists("res://character_T_Teeth_BC.png"):
		teeth_mat.albedo_texture = load("res://character_T_Teeth_BC.png") as Texture2D
	teeth_mat.albedo_color = Color(0.95, 0.93, 0.88)
	if ResourceLoader.exists("res://character_T_Teeth_N.png"):
		teeth_mat.normal_enabled = true
		teeth_mat.normal_texture = load("res://character_T_Teeth_N.png") as Texture2D
	teeth_mat.roughness = 0.35
	teeth_mat.metallic = 0.0

	# ── Hide material (transparent, no specular) ────────────────────────
	# Used for surfaces that should be invisible — the lacrimal strip
	# (surface 5) needs hiding so it doesn't occlude the eyeball spheres
	# behind it with a flat-strip iris that reads as an oval.
	var hide_mat: StandardMaterial3D = StandardMaterial3D.new()
	hide_mat.albedo_color = Color(0, 0, 0, 0)
	hide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hide_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hide_mat.no_depth_test = false

	# ── Eyeball spheres (surfaces 3 + 4) — eye.gdshader ─────────────────
	# eye.gdshader composites iris + sclera textures via UV-distance mask.
	# Two ShaderMaterial instances because the right and left eyes use
	# different iris textures (mirrored copies).
	# Real MetaHuman baked eye textures: iris BC + iris N (fiber relief) over the
	# veined sclera BC + sclera N, with corneal clearcoat. R/L mirrored copies.
	var eye_mat_r: ShaderMaterial = _make_eye_material("_r")
	var eye_mat_l: ShaderMaterial = _make_eye_material("_l")

	# Surface-3-was-iris_r and surface-4-was-hide assignments dropped —
	# both spheres now get the eye shader directly.
	var per_surface: Dictionary = {
		0: face_mat,           # bulk face skin
		1: teeth_mat,          # inner mouth area
		2: hide_mat,           # mouth-band geometry (not eye-related)
		3: eye_mat_r,          # RIGHT eyeball sphere
		4: eye_mat_l,          # LEFT eyeball sphere
		5: hide_mat,           # lacrimal strip — MUST hide; flat-strip eye
		                       # shader = the horror-eye oval bug we just fixed.
		6: hide_mat,           # hidden geometry
		7: face_mat,           # small face-skin patch around eyes
		8: hide_mat,           # eyelashes — keep hidden until proper atlas
	}
	for s in range(mi.mesh.get_surface_count()):
		if per_surface.has(s):
			mi.set_surface_override_material(s, per_surface[s])
	print("[emote_render] skin+eye on MetaHumanFace (%d surfaces, eye shader on s3+s4 spheres, lacrimal s5 hidden)" % mi.mesh.get_surface_count())


func _find_face_mesh(root: Node) -> MeshInstance3D:
	var stack: Array[Node] = [root]
	var best: MeshInstance3D = null
	var best_count: int = 0
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			var c: int = n.mesh.get_blend_shape_count()
			if c > best_count:
				best = n
				best_count = c
		for child in n.get_children():
			stack.append(child)
	return best


func _build_animation(character_root: Node3D) -> void:
	if face_mesh == null:
		return
	# Find every mesh with ARKit blend shapes (face + groom cards that got propagation).
	var driven_meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [character_root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mim: MeshInstance3D = n
			if mim.mesh.get_blend_shape_count() > 0:
				driven_meshes.append(mim)
		for child in n.get_children():
			stack.append(child)
	print("[emote_render] meshes with blend shapes: %s" % [driven_meshes.map(func(x): return "%s(%d)" % [x.name, x.mesh.get_blend_shape_count()])])

	var anim: Animation = Animation.new()
	anim.length = ANIM_DURATION
	anim.loop_mode = Animation.LOOP_NONE

	var all_touched_shapes: Dictionary = {}
	for entry in KEY_TIMES:
		var pose_dict: Dictionary = KEYPOSES[entry[1]]
		for shape_name in pose_dict.keys():
			all_touched_shapes[shape_name] = true

	var tracks_added: int = 0
	for shape_name in all_touched_shapes.keys():
		for mim in driven_meshes:
			var mesh: ArrayMesh = mim.mesh as ArrayMesh
			if mesh == null:
				continue
			var found: bool = false
			for si in range(mesh.get_blend_shape_count()):
				if mesh.get_blend_shape_name(si) == shape_name:
					found = true
					break
			if not found:
				continue
			var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
			var prop: String = "%s:blend_shapes/%s" % [mim.get_path(), shape_name]
			anim.track_set_path(track_idx, NodePath(prop))
			anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_CUBIC)
			for entry in KEY_TIMES:
				var t: float = entry[0]
				var pose_dict: Dictionary = KEYPOSES[entry[1]]
				var value: float = pose_dict.get(shape_name, 0.0)
				anim.track_insert_key(track_idx, t, value)
			tracks_added += 1

	var library: AnimationLibrary = AnimationLibrary.new()
	library.add_animation("emote", anim)
	animation_player = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	add_child(animation_player)
	animation_player.add_animation_library("", library)
	animation_player.play("emote")
	print("[emote_render] AnimationPlayer '%s' (%.1fs, %d tracks across %d meshes)" % [
		"emote", anim.length, tracks_added, driven_meshes.size()])

	animation_player.animation_finished.connect(_on_animation_finished)


func _on_animation_finished(_anim_name: StringName) -> void:
	print("[emote_render] animation finished, quitting in 0.3s")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()
