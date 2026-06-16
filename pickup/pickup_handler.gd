@tool
extends Area3D
class_name PickupHandler3D

# Area3D that detects PickupAbleBody3D bodies within range, tracks the closest one, and runs the
# pinch grab/release latch. It hangs under an XRController3D (one per hand) and re-pins its origin to
# the pinch each render frame; the held body reads the handler for its anchor and rotation sources.

# Radius within which we detect grabbable bodies.
@export var detect_range : float = 0.3:
	set(value):
		detect_range = value
		if is_inside_tree():
			_update_detect_range()
			_update_closest_body()

# OpenXR action that triggers pickup on a physical controller (hand tracking uses pinch distance).
@export var pickup_action : String = "pickup"
@export var pickup_press_threshold : float = 0.35
@export var pickup_release_threshold : float = 0.12
@export var release_grace_msec : int = 180
@export var quick_release_value : float = 0.04
# A "clearly wide-open" pinch must STAY open this long before the quick release fires — a tracking
# burst splays the thumb-index estimate for 1-3 frames mid-grab (val 1.0 -> ~0 -> 1.0), which would
# otherwise drop the grab. Any frame back above the release threshold resets the timer.
@export var quick_release_debounce_msec : int = 300
@export var follow_fingertips : bool = true
@export var hold_while_hand_tracking_uncertain : bool = true

# Hand-tracked pinch geometry: thumb–index TIP distance. The grab begins as the tips close to
# HAND_PINCH_GRAB (~1 cm) and holds until they open past HAND_PINCH_RELEASE (hysteresis).
const HAND_PINCH_GRAB := 0.010
const HAND_PINCH_RELEASE := 0.024

var closest_body : PickupAbleBody3D
var picked_up_body: PickupAbleBody3D
var was_pickup_pressed : bool = false
var release_started_msec : int = 0

# EVERY grab anchors right where you grab — no carried-over "grab point" from a previous hold. (A
# scoped lost-view restore was tried and removed: the hand-tracking VALID/TRACKED flags flicker during
# a normal fast open gesture, so it kept false-firing and sliding the object to the old grab point. The
# real need — not dropping an object when the pinch view blinks out — is already covered by
# sticky-release, which HOLDS the grab through a dropout instead of dropping it.)

# Thumb-index midpoint continuity: when both tips track we record each tip's offset to the midpoint;
# if one tip drops to untracked for a frame (common mid-rotation), we reconstruct the SAME midpoint
# from the surviving tip instead of snapping the anchor onto the bare fingertip (a ~1-2 cm lurch).
var _mid_from_index : Vector3 = Vector3.ZERO
var _mid_from_thumb : Vector3 = Vector3.ZERO
var _have_mid_offsets : bool = false

# Median-of-3 de-spiker for the fingertip anchor: a component-wise median of the last 3 samples kills
# an isolated single-frame jump (occluded fingers teleport ~8 cm while the hand moves ~1 m/s) with
# ~zero lag on real motion — the right tool for spikes (a low-pass lags everything). Tracking space.
var _anchor_hist : Array[Vector3] = []

func _median3(a: float, b: float, c: float) -> float:
	return a + b + c - minf(a, minf(b, c)) - maxf(a, maxf(b, c))

# Sticky-release stability signal: a leaky-max of the fingertip-midpoint per-frame jump (mm). High =
# the hand is poorly observed (jumping / going out of view), so its pinch-open can't be trusted to
# mean "released" — hold the grab instead. The release gate below depends on it; maintained every frame.
const JITTER_DECAY := 0.88           # per physics frame (~60 Hz) → a spike decays over ~150 ms
const STABLE_JITTER_MM := 28.0       # recent jitter under this = observed well enough to act on a release
const RELEASE_FALLBACK_MSEC := 2500  # open + degraded this long still releases (can't get permanently stuck)
var _recent_jitter_mm : float = 0.0
var _jit_prev_mid : Vector3 = Vector3.ZERO
var _jit_have : bool = false

# Simulator override: -1 = inactive (real hand tracking). 0..1 replaces _get_pickup_value
# and forces _hand_well_observed true so releases don't hang for 2.5 s. Set by simulator_input.gd.
var sim_pickup_override: float = -1.0


# Raw thumb-index fingertip midpoint in TRACKING space, or null if either tip isn't VALID.
func _raw_fingertip_mid(hand_tracker: XRHandTracker):
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thb := XRHandTracker.HAND_JOINT_THUMB_TIP
	var iv := (int(hand_tracker.get_hand_joint_flags(idx)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	var tv := (int(hand_tracker.get_hand_joint_flags(thb)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	if not (iv and tv):
		return null
	return (hand_tracker.get_hand_joint_transform(idx).origin + hand_tracker.get_hand_joint_transform(thb).origin) * 0.5

# Maintain _recent_jitter_mm from the fingertip-midpoint per-frame jump (leaky-max). Every frame.
func _sample_jitter() -> void:
	var mid = _raw_fingertip_mid(_get_hand_tracker())
	if mid == null:
		_recent_jitter_mm *= JITTER_DECAY
		_jit_have = false
		return
	if _jit_have:
		var d := ((mid as Vector3) - _jit_prev_mid).length() * 1000.0
		_recent_jitter_mm = maxf(d, _recent_jitter_mm * JITTER_DECAY)
	_jit_prev_mid = mid
	_jit_have = true

# "Is the hand observed well enough to TRUST a pinch-open as a real release?" Pinch joints tracked and
# recent jitter low. When false (hand jumping / out of view), the release logic holds the grab.
func _hand_well_observed() -> bool:
	if sim_pickup_override >= 0.0:
		return true
	var ht := _get_hand_tracker()
	if ht == null or not ht.get_has_tracking_data():
		return false
	if not (_joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP) and _joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_THUMB_TIP)):
		return false
	return _recent_jitter_mm <= STABLE_JITTER_MM


# Normalized pickup value. Hand tracking drives it SOLELY from thumb–index TIP distance (the
# platform's pinch/grip actions fire from ~2 inches out — far looser than wanted), requiring the tips
# to actually meet (~1 cm). Physical controllers fall back to the OpenXR action map + generic aliases.
func _get_pickup_value(controller: XRController3D) -> float:
	if sim_pickup_override >= 0.0:
		return sim_pickup_override
	var hand_tracker := _get_hand_tracker()
	if hand_tracker != null and hand_tracker.get_has_tracking_data():
		var index_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
		var thumb_joint := XRHandTracker.HAND_JOINT_THUMB_TIP
		if _joint_has_tracked_position(hand_tracker, index_joint) and _joint_has_tracked_position(hand_tracker, thumb_joint):
			var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
			var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
			var pinch_distance := index_tip.distance_to(thumb_tip)
			return clampf((HAND_PINCH_RELEASE - pinch_distance) / (HAND_PINCH_RELEASE - HAND_PINCH_GRAB), 0.0, 1.0)
		return 0.0

	var pickup_value : float = 0.0
	var mapped_input: Variant = controller.get_input(pickup_action)
	if mapped_input != null:
		pickup_value = maxf(pickup_value, controller.get_float(pickup_action))
	pickup_value = maxf(pickup_value, controller.get_float("grip"))
	pickup_value = maxf(pickup_value, controller.get_float("grip_click"))
	pickup_value = maxf(pickup_value, controller.get_float("select_button"))
	pickup_value = maxf(pickup_value, controller.get_float("trigger"))
	pickup_value = maxf(pickup_value, controller.get_float("trigger_click"))
	pickup_value = maxf(pickup_value, controller.get_float("primary"))
	pickup_value = maxf(pickup_value, controller.get_float("primary_click"))
	pickup_value = maxf(pickup_value, controller.get_float("pinch"))
	pickup_value = maxf(pickup_value, controller.get_float("grasp"))
	return pickup_value


func _get_hand_tracker() -> XRHandTracker:
	var controller : XRController3D = _get_parent_controller()
	if controller == null:
		return null
	var tracker_name := ""
	match controller.get_tracker_hand():
		XRPositionalTracker.TRACKER_HAND_LEFT:
			tracker_name = "/user/hand_tracker/left"
		XRPositionalTracker.TRACKER_HAND_RIGHT:
			tracker_name = "/user/hand_tracker/right"
		_:
			return null
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker is XRHandTracker:
		return tracker
	return null


func _joint_has_tracked_position(hand_tracker: XRHandTracker, joint: int) -> bool:
	var flags := int(hand_tracker.get_hand_joint_flags(joint))
	var position_valid := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0
	var position_tracked := (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0
	return position_valid and position_tracked


# Re-pin the handler origin to the (de-spiked) thumb-index midpoint each render frame. This is the
# proximity/reach anchor used for detection, and the FALLBACK grab pivot — the held body normally
# rides the de-spiked thumb-tip anchor (thumb_anchor_xform) instead. Render rate, NOT physics: the
# held body rides this pose, and re-pinning at 60 Hz under a 90 Hz display injected a 3:2-beat saw-tooth.
func _update_anchor_from_hand_tracker() -> void:
	if not follow_fingertips:
		return
	var hand_tracker := _get_hand_tracker()
	if hand_tracker == null or not hand_tracker.get_has_tracking_data():
		return

	var index_joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb_joint := XRHandTracker.HAND_JOINT_THUMB_TIP
	var has_index := _joint_has_tracked_position(hand_tracker, index_joint)
	var has_thumb := _joint_has_tracked_position(hand_tracker, thumb_joint)
	var fingertip_mid = null
	if has_index and has_thumb:
		var index_tip := hand_tracker.get_hand_joint_transform(index_joint).origin
		var thumb_tip := hand_tracker.get_hand_joint_transform(thumb_joint).origin
		fingertip_mid = (index_tip + thumb_tip) * 0.5
		_mid_from_index = fingertip_mid - index_tip
		_mid_from_thumb = fingertip_mid - thumb_tip
		_have_mid_offsets = true
	elif has_index:
		fingertip_mid = hand_tracker.get_hand_joint_transform(index_joint).origin + (_mid_from_index if _have_mid_offsets else Vector3.ZERO)
	elif has_thumb:
		fingertip_mid = hand_tracker.get_hand_joint_transform(thumb_joint).origin + (_mid_from_thumb if _have_mid_offsets else Vector3.ZERO)
	if fingertip_mid == null:
		return   # nothing tracked — hold the last anchor (don't snap/drop)

	_anchor_hist.push_back(fingertip_mid)
	if _anchor_hist.size() > 3:
		_anchor_hist.pop_front()
	var despiked : Vector3 = fingertip_mid
	if _anchor_hist.size() == 3:
		despiked = Vector3(
			_median3(_anchor_hist[0].x, _anchor_hist[1].x, _anchor_hist[2].x),
			_median3(_anchor_hist[0].y, _anchor_hist[1].y, _anchor_hist[2].y),
			_median3(_anchor_hist[0].z, _anchor_hist[1].z, _anchor_hist[2].z))

	# Tracking-space → world (through the XROrigin) so a world-handle drag doesn't shift the anchor.
	var anchor_transform := global_transform
	anchor_transform.origin = _origin_xform() * despiked
	global_transform = anchor_transform


# World transform of the XROrigin this handler hangs under (tracking→world).
func _origin_xform() -> Transform3D:
	var n: Node = get_parent()
	while n != null:
		if n is XROrigin3D:
			return (n as XROrigin3D).global_transform
		n = n.get_parent()
	return Transform3D.IDENTITY

# De-spiked THUMB-TIP world transform — the grab pivot AND the rotation source the held body uses.
# The thumb is the stable side of a pinch (the index moves as you pinch/pull/release; the thumb
# barely does), so anchoring both position and rotation to it is far calmer than the controller
# "aim" pose. The raw thumb-tip POSITION still glitches at the grab instant (telemetry: ~14% of
# grabs spiked 0.35-0.40 m, baking a wrong grab point → a ~15-20 cm jump), so we median-of-3 de-spike
# the position, sampled every render frame, and hold the last good value through a dropout.
var _thumb_pos_hist : Array[Vector3] = []
var _thumb_anchor_xf : Variant = null
func _sample_thumb_anchor() -> void:
	var ht := _get_hand_tracker()
	if ht == null or not ht.get_has_tracking_data() or not _joint_has_tracked_position(ht, XRHandTracker.HAND_JOINT_THUMB_TIP):
		return   # keep the last good anchor (don't null) so a brief dropout holds rather than snaps
	var raw := _origin_xform() * ht.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP)
	_thumb_pos_hist.push_back(raw.origin)
	if _thumb_pos_hist.size() > 3:
		_thumb_pos_hist.pop_front()
	var pos := raw.origin
	if _thumb_pos_hist.size() == 3:
		pos = Vector3(
			_median3(_thumb_pos_hist[0].x, _thumb_pos_hist[1].x, _thumb_pos_hist[2].x),
			_median3(_thumb_pos_hist[0].y, _thumb_pos_hist[1].y, _thumb_pos_hist[2].y),
			_median3(_thumb_pos_hist[0].z, _thumb_pos_hist[1].z, _thumb_pos_hist[2].z))
	_thumb_anchor_xf = Transform3D(raw.basis, pos)

func thumb_anchor_xform():
	return _thumb_anchor_xf


func _update_detect_range() -> void:
	var shape : SphereShape3D = $CollisionShape3D.shape
	if shape:
		shape.radius = detect_range


func _update_closest_body() -> void:
	if Engine.is_editor_hint():
		return
	# Don't re-pick while we're already holding something.
	if picked_up_body:
		if closest_body:
			closest_body.remove_is_closest(self)
			closest_body = null
		return

	var new_closest_body : PickupAbleBody3D
	var closest_distance : float = 1000000.0
	for body in get_overlapping_bodies():
		if body is PickupAbleBody3D and not body.is_picked_up():
			var distance_squared = (body.global_position - global_position).length_squared()
			if distance_squared < closest_distance:
				new_closest_body = body
				closest_distance = distance_squared

	if closest_body == new_closest_body:
		return
	if closest_body:
		closest_body.remove_is_closest(self)
	closest_body = new_closest_body
	if closest_body:
		closest_body.add_is_closest(self)


func _get_parent_controller() -> XRController3D:
	var parent : Node = get_parent()
	while parent:
		if parent is XRController3D:
			return parent
		parent = parent.get_parent()
	return null


func _ready() -> void:
	_update_detect_range()
	_update_closest_body()


# Anchor re-pin runs at render rate (90 Hz); the held body rides this pose, so re-pinning at physics
# rate (60 Hz) under a 90 Hz display injected a 3:2-beat saw-tooth. Pickup/release latch + closest-body
# detection stay in _physics_process (logic, not visual smoothness).
func _process(_delta: float) -> void:
	_update_anchor_from_hand_tracker()
	_sample_thumb_anchor()   # keep the de-spiked thumb-tip anchor warm (the held body reads it)


func _physics_process(_delta) -> void:
	_update_closest_body()

	# Our own pinch threshold logic (platforms differ on the boolean), with press/release hysteresis.
	var pickup_pressed = false
	var pickup_value : float = 0.0
	var threshold : float = pickup_press_threshold
	var controller : XRController3D = _get_parent_controller()
	if controller:
		pickup_value = _get_pickup_value(controller)
		threshold = pickup_release_threshold if was_pickup_pressed else pickup_press_threshold
		pickup_pressed = pickup_value > threshold
		_sample_jitter()   # keep the recent-jitter stability signal warm (the release gate needs it)

	# Do we need to let go?
	if picked_up_body:
		if pickup_pressed:
			release_started_msec = 0
			picked_up_body.follow_suspended = false
		else:
			# Pinch is OPEN. Signal the held body to hold its rotation (and, if a place-only body, its
			# position) so the opening hand can't spin/drag it — the clean-release fix. The latch below
			# still HOLDS the grab through the grace window (no false drop on a finger-splay).
			picked_up_body.follow_suspended = true
			# STICKY RELEASE: only release on a CONFIDENT open — clearly open, SUSTAINED, AND the hand
			# currently well-observed. Only accrue the release timer while WELL-OBSERVED and open; if
			# tracking is degraded (pinch joints gone / hand jumping), RESET it so a multi-frame dropout
			# can't carry an elapsed timer (that was the false "(grace)" release: tips vanished while
			# still pinching, the timer ran past the grace window, and the instant tracking returned a
			# release fired). A long fallback still guarantees a release can't get permanently stuck.
			var well_observed := (not hold_while_hand_tracking_uncertain) or _hand_well_observed()
			var now_msec := Time.get_ticks_msec()
			if not well_observed:
				release_started_msec = 0
			elif release_started_msec == 0:
				release_started_msec = now_msec
			var held_open_ms := (now_msec - release_started_msec) if release_started_msec != 0 else 0
			var quick := pickup_value <= quick_release_value and held_open_ms >= quick_release_debounce_msec
			var graced := held_open_ms >= release_grace_msec
			var fallback := held_open_ms >= RELEASE_FALLBACK_MSEC
			if (well_observed and (quick or graced)) or fallback:
				picked_up_body.let_go()
				picked_up_body = null
				release_started_msec = 0
				was_pickup_pressed = false
				return
			else:
				pickup_pressed = true   # hold the latch (the body holds its pose; no detach/blip)
	else:
		release_started_msec = 0

	# Do we need to pick something up?
	if not picked_up_body and not was_pickup_pressed and pickup_pressed and closest_body:
		picked_up_body = closest_body
		picked_up_body.pick_up(self)

	was_pickup_pressed = pickup_pressed
