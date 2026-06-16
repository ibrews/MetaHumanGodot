class_name HandMeshDriver3D
extends Node3D

# Drives the XR Tools low-poly hand GLTF from XRHandTracker joints via
# set_bone_global_pose_override().
#
# The Clancey fork pre-rotates each joint basis into Godot's humanoid-rig
# convention, which doesn't match how the XR Tools GLTF is rigged. Correction
# is a bone-frame rotation, found via an on-device A-F sweep (right = Y +90°,
# magenta winner). The left rig is the sagittal mirror of the right, so the
# left correction is that rotation conjugated through the X-reflection:
#   C_left = X · Ry(+90) · X = Ry(-90)
# (X = reflect across YZ plane). Hence per-hand corrections below.
#
# Joint indices are raw OpenXR values (0-25) — stable across Godot versions
# that rename enum members (PHALANX_* vs PROXIMAL_*, PINKY_* vs LITTLE_*).

@export var tracker_name: String
@export var is_left: bool = true

var _bone_correction: Basis
var _skeleton: Skeleton3D
var _mesh_root: Node3D
var _bone_to_joint: Dictionary = {}  # bone_idx → joint_idx (0-25)
var _shown := true
# Simulator: there's no hand-tracking data, so the driver would hide the mesh forever. When
# true we instead park a static hand mesh in view so it (and the V show/hide) are visible.
var _sim := false

func _ready() -> void:
	_sim = OS.has_environment("SIMULATOR_DEVICE_NAME") \
		or OS.has_environment("SIMULATOR_UDID") \
		or OS.has_environment("SIMULATOR_ROOT")
	# Right hand: Y +90°. Left hand (mirrored rig): Y -90°.
	_bone_correction = Basis(Vector3(0, 1, 0), (-PI / 2.0) if is_left else (PI / 2.0))

	var path := "res://hands/hand_l.gltf" if is_left else "res://hands/hand_r.gltf"
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("HandMeshDriver: cannot load %s" % path)
		return

	_mesh_root = scene.instantiate()
	add_child(_mesh_root)

	var white := StandardMaterial3D.new()
	white.albedo_color = Color.WHITE
	white.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_apply_material(_mesh_root, white)

	_skeleton = _find_skeleton(_mesh_root)
	if _skeleton == null:
		push_error("HandMeshDriver: Skeleton3D not found in %s" % path)
		return

	_build_bone_map()
	print("[HandMesh] %s: mapped %d / 26 bones" % [tracker_name, _bone_to_joint.size()])

# Show/hide the hand mesh. Dissolves/collapses into particles on BOTH toggle
# directions so each transition reads (white-cyan dissolve on hide, cyan
# materialize on show).
func set_shown(shown: bool) -> void:
	if shown == _shown:
		return
	_shown = shown
	_burst(Color(0.4, 0.9, 1.0) if shown else Color(0.85, 0.92, 1.0))

func is_shown() -> bool:
	return _shown

# Hand "falls apart" / "reassembles": shed small cube shards from each tracked
# joint so the dissolve traces the actual hand shape. On hide they fly outward +
# fall; on show they implode inward. Emits from real joint world positions.
func _burst(col: Color) -> void:
	if _skeleton == null:
		return
	var tracker := XRServer.get_tracker(tracker_name)
	if not tracker is XRHandTracker:
		return
	var ht := tracker as XRHandTracker

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(col.r, col.g, col.b, 0.95)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.2

	# One small shard mesh reused for all joints.
	var shard := BoxMesh.new()
	shard.size = Vector3(0.012, 0.012, 0.012)
	shard.material = mat

	var root := get_tree().current_scene
	var origin_x := _origin_xform()  # joints are tracking-space; render through XROrigin
	# Shed a shard from each of the 26 joints (whatever is tracked).
	for j in range(26):
		var flags := int(ht.get_hand_joint_flags(j))
		if not (flags & 8):  # POSITION_TRACKED
			continue
		var jp: Vector3 = (origin_x * ht.get_hand_joint_transform(j)).origin
		var mi := MeshInstance3D.new()
		mi.mesh = shard
		root.add_child(mi)
		mi.global_position = jp
		# Outward (hide) or inward-from-outside (show) motion via a tween.
		var dir := (jp - _skeleton.global_transform.origin).normalized()
		if dir.length() < 0.01:
			dir = Vector3(0, 1, 0)
		var spread := dir * randf_range(0.12, 0.28) + Vector3(
			randf_range(-0.05, 0.05), randf_range(-0.05, 0.05), randf_range(-0.05, 0.05))
		var tw := create_tween().set_parallel(true)
		if _shown:
			# Materialize: start spread out, converge to the joint.
			mi.global_position = jp + spread
			tw.tween_property(mi, "global_position", jp, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(mi, "scale", Vector3.ONE * 0.2, 0.35)
			mi.scale = Vector3.ONE * 1.4
		else:
			# Dissolve: fly outward + fall, shrinking away.
			tw.tween_property(mi, "global_position", jp + spread + Vector3(0, -0.15, 0), 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(mi, "scale", Vector3.ZERO, 0.5)
		tw.chain().tween_callback(mi.queue_free)

func _process(_delta: float) -> void:
	if _skeleton == null or _mesh_root == null:
		return
	if not _shown:
		_mesh_root.visible = false
		return
	var tracker := XRServer.get_tracker(tracker_name)
	var ht := tracker as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		# No real hand tracking (always the case in the simulator). On device → hide. In the
		# sim → park a static hand mesh in front of the camera so the mesh AND the V show/hide
		# toggle are actually visible. See KB godot-avp-simulator-input.
		if _sim:
			_park_in_view()
			_mesh_root.visible = true
		else:
			_mesh_root.visible = false
		return
	_mesh_root.visible = true

	var world_to_skel := _skeleton.global_transform.affine_inverse()
	# XRHandTracker joint poses are TRACKING-space (XROrigin-relative). The real
	# passthrough hand appears in Godot world at XROrigin * joint. Without this the
	# virtual mesh renders at the un-shifted pose and swims away from the real hand
	# after a world-handle drag moves the origin. Reduces to identity at origin-home.
	var origin_x := _origin_xform()

	for bone_idx: int in _bone_to_joint:
		var joint_idx: int = _bone_to_joint[bone_idx]
		var flags := int(ht.get_hand_joint_flags(joint_idx))
		if not (flags & 8):  # HAND_JOINT_FLAG_POSITION_TRACKED = 8
			continue
		var t := world_to_skel * (origin_x * ht.get_hand_joint_transform(joint_idx))
		t.basis = t.basis * _bone_correction  # bone-frame correction (per-hand)
		_skeleton.set_bone_global_pose_override(bone_idx, t, 1.0, false)

# Sim-only: park the (un-articulated) hand mesh at a resting pose in front of the camera so
# it's visible without hand-tracking data. Position + a roughly palm-toward-user orientation;
# the GLTF rest pose shows. Tune offsets here if the hands sit too low / close.
func _park_in_view() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var ct := cam.global_transform
	# Lower-FOV, ~0.45 m ahead, one hand each side. Orientation = camera basis (the GLTF rest
	# pose then reads as open hands in view). VERIFIED visible in the sim; the exact resting
	# pose is rough (the GLTF rig orientation isn't ideal here) — tune offsets/basis to taste.
	var side: float = -0.16 if is_left else 0.16
	var pos: Vector3 = ct.origin + ct.basis.z * -0.45 + ct.basis.y * -0.22 + ct.basis.x * side
	_mesh_root.global_transform = Transform3D(ct.basis, pos)

# World transform of the XROrigin this hand renders through (tracking→world).
func _origin_xform() -> Transform3D:
	var n: Node = get_parent()
	while n != null:
		if n is XROrigin3D:
			return (n as XROrigin3D).global_transform
		n = n.get_parent()
	return Transform3D.IDENTITY

func _build_bone_map() -> void:
	var sfx := "L" if is_left else "R"
	var name_to_joint := {
		"Wrist_" + sfx:               1,
		"Palm_" + sfx:                0,
		"Thumb_Metacarpal_" + sfx:    2,
		"Thumb_Proximal_" + sfx:      3,
		"Thumb_Distal_" + sfx:        4,
		"Thumb_Tip_" + sfx:           5,
		"Index_Metacarpal_" + sfx:    6,
		"Index_Proximal_" + sfx:      7,
		"Index_Intermediate_" + sfx:  8,
		"Index_Distal_" + sfx:        9,
		"Index_Tip_" + sfx:           10,
		"Middle_Metacarpal_" + sfx:   11,
		"Middle_Proximal_" + sfx:     12,
		"Middle_Intermediate_" + sfx: 13,
		"Middle_Distal_" + sfx:       14,
		"Middle_Tip_" + sfx:          15,
		"Ring_Metacarpal_" + sfx:     16,
		"Ring_Proximal_" + sfx:       17,
		"Ring_Intermediate_" + sfx:   18,
		"Ring_Distal_" + sfx:         19,
		"Ring_Tip_" + sfx:            20,
		"Little_Metacarpal_" + sfx:   21,
		"Little_Proximal_" + sfx:     22,
		"Little_Intermediate_" + sfx: 23,
		"Little_Distal_" + sfx:       24,
		"Little_Tip_" + sfx:          25,
	}
	for bone_idx in range(_skeleton.get_bone_count()):
		var name: String = _skeleton.get_bone_name(bone_idx)
		if name_to_joint.has(name):
			_bone_to_joint[bone_idx] = name_to_joint[name]

func _apply_material(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_apply_material(child, mat)

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null
