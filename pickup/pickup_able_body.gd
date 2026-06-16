extends RigidBody3D
class_name PickupAbleBody3D

# Hand-tracking pickup body — based on Marshall Nowak (Nocxr)'s PickupAbleBody3D from the
# visionosxr_hand_tracking reference project. Throw velocity on release is ours.
#
# ONE-HANDED GRAB. The grabbed POINT on the object stays pinned under your pinch and the object
# rotates ABOUT that point (grab-by-point), eased by a one-euro filter so raw hand-tracking jitter
# doesn't pass straight through (a raw 1:1 ride feels "electric"). Both the position anchor (pivot)
# AND the rotation come from the de-spiked THUMB-TIP joint (provided by the handler): a directly-
# tracked joint the INDEX can't disturb (pinch/pull/release move the index, not the thumb), and far
# stabler than the controller "aim" pose (which is pinch-derived and noisy). The handler holds the
# last good thumb value through a one-frame dropout, so brief self-occlusion doesn't snap the grab.

# Outline overlays (inverted-hull highlight shader): cyan when this is the closest grabbable, green
# while held, blue during two-hand scale. `grow` is LOCAL metres along the normal — keep small or the
# hull explodes. NOTE: the shader uniforms are `albedo` + `grow` (NOT outline_color/_width); the wrong
# names silently no-op (which is why every outline once rendered as the base yellow).
var _candidate_material : ShaderMaterial = _make_outline(Color(0.30, 0.80, 1.00, 1.0), 0.004)
var _held_material : ShaderMaterial = _make_outline(Color(0.45, 1.00, 0.55, 1.0), 0.008)
var _scale_material : ShaderMaterial = _make_outline(Color(0.12, 0.45, 1.00, 1.0), 0.014)
var picked_up_by : Area3D
var closest_areas : Array

# When true, the body stays frozen where dropped instead of falling/throwing (catch plates, wall).
@export var freeze_on_release := false

# Set by the handler each held frame: true while the pinch is OPEN (you're releasing). The follow
# then HOLDS its rotation — so the opening hand (the thumb swings as it extends) can't spin the
# object: the crazy-rotation-on-release fix. A freeze_on_release body also holds its POSITION (clean
# placement, no thumb-drag); a throwable body keeps following position so the throw captures velocity.
var follow_suspended := false

# External two-hand control (main_v2 scale): while true the driver owns the transform; the one-hand
# follow is suspended and the body frozen so physics can't fight it.
var two_hand := false
var _saved_collision_layer := 0
var _saved_collision_mask := 0
var _two_hand_follow_was_on := true

var original_parent : Node3D
var _saved_freeze_mode : int = FREEZE_MODE_STATIC   # resting freeze mode, restored on release

# Throw velocity: recent {pos, t} history while held.
var _pos_history : Array = []
const _POS_HISTORY_MAX := 6

static func _make_outline(color: Color, width: float) -> ShaderMaterial:
	var base := load("res://shaders/highlight_material.tres") as ShaderMaterial
	var m := base.duplicate() as ShaderMaterial
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("grow", width)
	return m


# --- Held-follow smoothing (one-euro: position + adaptive-slerp rotation) ---
# We keep a PERSISTENT world-space filtered transform and each render frame ease it toward the raw
# target pose. That persistent state is the stable frame the smoothing needs — we never read it back
# from the reparented body (that would re-absorb the jitter). One-euro is smooth at rest and opens its
# cutoff with speed so fast moves keep ~zero lag. Render-rate (_process), never physics.
# Tune on device: *_CUTOFF down = smoother/laggier at rest; *_BETA up = snappier when moving.
const FOLLOW_POS_CUTOFF := 9.0      # Hz — tight (~18 ms lag); the anchor is de-spiked upstream
const FOLLOW_ROT_CUTOFF := 4.0      # Hz
const FOLLOW_POS_BETA := 1.0        # per (m/s)
const FOLLOW_ROT_BETA := 0.5        # per (rad/s) — opens with angular speed so deliberate turns track
const FOLLOW_DCUTOFF := 4.0         # Hz — the speed estimate must react fast or quick moves lag
const FOLLOW_MAX_LIN_SPEED := 6.0   # m/s — spike backstop (pass real 1-3 m/s moves, reject teleports)
const FOLLOW_MAX_ANG_SPEED := 18.0  # rad/s — spike backstop for gross orientation teleports only
var _follow_ready := false
var _filt_pos : Vector3 = Vector3.ZERO       # filtered PIVOT (grab-point world pos), NOT the body origin
var _filt_basis : Basis = Basis.IDENTITY
var _filt_vel : Vector3 = Vector3.ZERO
var _filt_avel : float = 0.0
# Grab-by-point capture: the grabbed point in the body's own unscaled local frame, the body's basis
# relative to the thumb anchor at grab, and the scale. The follow keeps _grab_point_local pinned to
# the (smoothed) pivot and rotates the body about it — instead of snapping the body CENTRE to the finger.
var _grab_rot_offset : Basis = Basis.IDENTITY
var _grab_point_local : Vector3 = Vector3.ZERO
var _grab_scale : Vector3 = Vector3.ONE


func add_is_closest(area : Area3D) -> void:
	if not closest_areas.has(area):
		closest_areas.push_back(area)
	_update_highlight()

func remove_is_closest(area : Area3D) -> void:
	if closest_areas.has(area):
		closest_areas.erase(area)
	_update_highlight()

func is_picked_up() -> bool:
	return picked_up_by != null


# Track global position while held (for throw velocity) — physics rate is fine.
func _physics_process(_delta: float) -> void:
	if not is_picked_up():
		return
	_pos_history.append({"pos": global_position, "t": Time.get_ticks_msec()})
	if _pos_history.size() > _POS_HISTORY_MAX:
		_pos_history.pop_front()


# The de-spiked THUMB-TIP world transform from the handler — the anchor for BOTH the position pivot
# and the rotation. Falls back to the holder (controller) transform if the thumb anchor isn't ready.
func _anchor_xform(holder: Node3D) -> Transform3D:
	if holder != null and holder.has_method("thumb_anchor_xform"):
		var a = holder.thumb_anchor_xform()
		if a != null:
			return a
	return holder.global_transform if holder != null else Transform3D.IDENTITY


# Render-frame follow while held.
func _process(delta: float) -> void:
	if two_hand:
		return  # main_v2 two-hand scale owns the transform this frame
	if not is_picked_up():
		return
	var holder := picked_up_by as Node3D
	if holder == null:
		return

	var src := _anchor_xform(holder)   # de-spiked thumb transform (pivot + rotation source)
	var target_pivot := src.origin
	var target_basis := (src.basis.orthonormalized() * _grab_rot_offset).orthonormalized()

	# Clean release: while the pinch is OPEN, never rotate toward the source (the opening hand swings
	# the thumb — that was the release spin). Hold the current orientation. A place-only body also
	# holds position; a throwable body keeps following position so the throw gets its velocity.
	if follow_suspended:
		target_basis = _filt_basis
		if freeze_on_release:
			target_pivot = _filt_pos

	if not _follow_ready or delta <= 0.0:
		# Adopt the body's CURRENT scale on every (re)seed so the follow never forces a stale scale,
		# and seed the filtered pivot from the grab point's CURRENT world pos so it eases in.
		_grab_scale = global_transform.basis.get_scale()
		_filt_basis = global_transform.basis.orthonormalized()
		_filt_pos = global_position + _filt_basis.scaled(_grab_scale) * _grab_point_local
		_filt_vel = Vector3.ZERO
		_filt_avel = 0.0
		_follow_ready = true
	else:
		# Spike rejection: a superhuman jump is a tracking glitch — clamp to the max-speed sphere /
		# max angular step. The pivot tracks the hand at hand speed, so real moves are never clamped.
		var max_step := FOLLOW_MAX_LIN_SPEED * delta
		var to_target := target_pivot - _filt_pos
		if to_target.length() > max_step:
			target_pivot = _filt_pos + to_target.normalized() * max_step
		var max_ang_step := FOLLOW_MAX_ANG_SPEED * delta
		var raw_ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		if raw_ang > max_ang_step and raw_ang > 0.0:
			target_basis = _filt_basis.slerp(target_basis, max_ang_step / raw_ang).orthonormalized()
		# One-euro on the pivot (position) and an adaptive slerp on the orientation.
		var a_d := _oe_alpha(FOLLOW_DCUTOFF, delta)
		var d_pos := (target_pivot - _filt_pos) / delta
		_filt_vel = _filt_vel.lerp(d_pos, a_d)
		var p_cut := FOLLOW_POS_CUTOFF + FOLLOW_POS_BETA * minf(_filt_vel.length(), FOLLOW_MAX_LIN_SPEED)
		_filt_pos = _filt_pos.lerp(target_pivot, _oe_alpha(p_cut, delta))
		var ang := _filt_basis.get_rotation_quaternion().angle_to(target_basis.get_rotation_quaternion())
		_filt_avel = lerpf(_filt_avel, ang / delta, a_d)
		var r_cut := FOLLOW_ROT_CUTOFF + FOLLOW_ROT_BETA * minf(_filt_avel, FOLLOW_MAX_ANG_SPEED)
		_filt_basis = _filt_basis.slerp(target_basis, _oe_alpha(r_cut, delta)).orthonormalized()

	# Reconstruct the body origin so the grabbed local point lands EXACTLY on the filtered pivot.
	var body_origin := _filt_pos - _filt_basis.scaled(_grab_scale) * _grab_point_local
	global_transform = Transform3D(_filt_basis.scaled(_grab_scale), body_origin)


# Smoothing factor for a first-order low-pass at the given cutoff (Hz) and dt (s).
func _oe_alpha(cutoff: float, dt: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / dt)


func pick_up(pick_up_by) -> void:
	if picked_up_by:
		if picked_up_by == pick_up_by:
			return
		let_go()

	original_parent = get_parent()
	var current_transform = global_transform
	original_parent.remove_child(self)
	picked_up_by = pick_up_by
	picked_up_by.add_child(self)
	global_transform = current_transform
	# Held bodies MUST use STATIC freeze: the follow rewrites global_transform every frame and STATIC
	# applies it as a clean teleport. KINEMATIC (course obstacles at rest) sweeps it through the solver
	# one frame behind, fighting the follow = stutter.
	_saved_freeze_mode = freeze_mode
	freeze_mode = FREEZE_MODE_STATIC
	freeze = true
	_pos_history.clear()
	_update_highlight()

	# Grab-by-point capture: the body's orientation relative to the thumb anchor (so the object keeps
	# its current orientation, then rotates WITH the thumb — no snap) and the grabbed point in the
	# body's unscaled local frame (so THAT exact spot stays under the thumb and the object rotates
	# about it). EVERY grab anchors right where you grab. affine_inverse divides out the body's scale.
	var holder := pick_up_by as Node3D
	_grab_scale = current_transform.basis.get_scale()
	if holder != null:
		var src := _anchor_xform(holder)
		_grab_rot_offset = src.basis.orthonormalized().inverse() * current_transform.basis.orthonormalized()
		_grab_point_local = current_transform.affine_inverse() * src.origin
	else:
		_grab_rot_offset = Basis.IDENTITY
		_grab_point_local = Vector3.ZERO
	follow_suspended = false   # a fresh grab follows actively until the handler reports the pinch open
	_follow_ready = false      # seed the filter from the current pose on the first frame


# Let this object go — applies throw velocity from position history (skipped for stay-put bodies).
func let_go() -> void:
	if not picked_up_by:
		return

	var throw_velocity := Vector3.ZERO
	if not freeze_on_release and _pos_history.size() >= 2:
		var newest: Dictionary = _pos_history[-1]
		var oldest: Dictionary = _pos_history[0]
		var dt_sec: float = (float(newest["t"]) - float(oldest["t"])) / 1000.0
		if dt_sec > 0.001:
			throw_velocity = (newest["pos"] - oldest["pos"]) / dt_sec
	_pos_history.clear()

	var current_transform = global_transform
	picked_up_by.remove_child(self)
	picked_up_by = null
	original_parent.add_child(self)
	global_transform = current_transform

	freeze_mode = _saved_freeze_mode   # restore resting freeze (e.g. KINEMATIC obstacles)
	if freeze_on_release:
		freeze = true   # stay where dropped (plates/wall)
	else:
		freeze = false
		linear_velocity = throw_velocity
		angular_velocity = Vector3.ZERO   # keep the exact let-go orientation, no resumed spin
	_update_highlight()


# Outline state: two-hand (blue) > held (green) > candidate (cyan) > none.
func _update_highlight() -> void:
	var overlay : Material = null
	if two_hand:
		overlay = _scale_material
	elif picked_up_by:
		overlay = _held_material
	elif not closest_areas.is_empty():
		overlay = _candidate_material
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_overlay = overlay


# Enter/exit external two-hand control (main_v2 scale). Freeze + disable collision so the driver isn't
# fought, and freeze the holding handler's fingertip-follow so it can't drag this body — the two-writer
# bug: the body is a CHILD of the handler, so the handler's per-frame motion would carry it AFTER the
# scale already placed it. The scale math reads the hand tracker directly, not the handler anchor, so
# scaling is unaffected and the grab/release lifecycle (which assumes child-of-handler) is untouched.
func set_two_hand(on: bool) -> void:
	two_hand = on
	if on:
		freeze_mode = FREEZE_MODE_STATIC
		freeze = true
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
		collision_layer = 0
		collision_mask = 0
		if picked_up_by != null:
			_two_hand_follow_was_on = bool(picked_up_by.get("follow_fingertips"))
			picked_up_by.set("follow_fingertips", false)
	else:
		if picked_up_by != null:
			picked_up_by.set("follow_fingertips", _two_hand_follow_was_on)
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
		freeze = true if freeze_on_release else false
		_follow_ready = false   # re-seed the follow from the current pose
	_update_highlight()
