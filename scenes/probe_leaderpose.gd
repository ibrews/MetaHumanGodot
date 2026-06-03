extends SceneTree

# Headless probe for the LeaderPose-emulation seam fix.
# Loads character.glb, identifies the BODY skeleton (metahuman_base_skel, 341) and
# the FACE skeleton (Face_Archetype_Skeleton, 874, has FACIAL_L_Eye), then for every
# bone shared by NAME reports whether the LOCAL REST transforms match (origin + basis
# angle + scale). If they match, a direct local-pose copy transfers cleanly; if they
# differ, we must copy the rest-relative delta instead.
#
# Usage: <godot> --headless --path godot_project --script res://scenes/probe_leaderpose.gd

func _init() -> void:
	var scene: PackedScene = load("res://character.glb")
	if scene == null:
		printerr("[probe_lp] FAIL: could not load res://character.glb")
		quit(1)
		return
	var root: Node = scene.instantiate()
	var skels: Array = []
	_collect(root, skels)
	print("[probe_lp] found ", skels.size(), " Skeleton3D nodes")
	for s in skels:
		print("  SKEL '", s.name, "'  bones=", s.get_bone_count(),
			"  ancestry=[", _ancestry(s), "]",
			"  spine_03=", s.find_bone("spine_03"),
			"  head=", s.find_bone("head"),
			"  FACIAL_L_Eye=", s.find_bone("FACIAL_L_Eye"))

	# classify
	var face: Skeleton3D = null
	var body: Skeleton3D = null
	for s in skels:
		if s.find_bone("FACIAL_L_Eye") >= 0:
			face = s
	# body = a spine_03+head skeleton WITHOUT FACIAL_L_Eye, fewest bones
	for s in skels:
		if s.find_bone("spine_03") >= 0 and s.find_bone("head") >= 0 and s.find_bone("FACIAL_L_Eye") < 0:
			if body == null or s.get_bone_count() < body.get_bone_count():
				body = s
	if body == null:
		# fall back: the non-face spine_03 skel even if it also has FACIAL (shouldn't happen)
		for s in skels:
			if s != face and s.find_bone("spine_03") >= 0:
				body = s
	print("[probe_lp] BODY = ", (body.name if body else "<none>"),
		"  FACE = ", (face.name if face else "<none>"))
	if body == null or face == null:
		quit(2)
		return

	# which mesh is skinned by which skeleton, and which carries blendshapes (= face mesh)
	print("[probe_lp] mesh -> skeleton mapping:")
	_report_meshes(root, body, face)

	# Shared-bone rest comparison. Walk EVERY body bone; if the face has the same name,
	# compare local rests. Tally matches/mismatches, and spotlight the seam-region bones.
	var spotlight: Array = ["pelvis", "spine_01", "spine_02", "spine_03", "spine_04", "spine_05",
		"neck_01", "neck_02", "head", "clavicle_l", "clavicle_r",
		"upperarm_l", "upperarm_r", "lowerarm_l", "calf_l"]
	var shared := 0
	var origin_max := 0.0
	var angle_max := 0.0
	var scale_max := 0.0
	var parent_mismatch := 0
	var worst: Array = []   # [name, d_origin, d_angle_deg]
	for bi in range(body.get_bone_count()):
		var bn: String = body.get_bone_name(bi)
		var fi: int = face.find_bone(bn)
		if fi < 0:
			continue
		shared += 1
		var rb: Transform3D = body.get_bone_rest(bi)
		var rf: Transform3D = face.get_bone_rest(fi)
		var d_origin: float = (rb.origin - rf.origin).length()
		var qb: Quaternion = rb.basis.get_rotation_quaternion()
		var qf: Quaternion = rf.basis.get_rotation_quaternion()
		var d_angle: float = rad_to_deg(qb.angle_to(qf))
		var d_scale: float = (rb.basis.get_scale() - rf.basis.get_scale()).length()
		origin_max = maxf(origin_max, d_origin)
		angle_max = maxf(angle_max, d_angle)
		scale_max = maxf(scale_max, d_scale)
		# parent-name topology check
		var pb: int = body.get_bone_parent(bi)
		var pf: int = face.get_bone_parent(fi)
		var pbn: String = (body.get_bone_name(pb) if pb >= 0 else "<root>")
		var pfn: String = (face.get_bone_name(pf) if pf >= 0 else "<root>")
		if pbn != pfn:
			parent_mismatch += 1
			print("  PARENT MISMATCH ", bn, " body.parent=", pbn, " face.parent=", pfn)
		if d_origin > 1e-4 or d_angle > 0.05:
			worst.append([bn, d_origin, d_angle, pbn, pfn])
		if bn in spotlight:
			print("  [spot] %-13s d_origin=%.6f m  d_angle=%.4f deg  d_scale=%.6f  parent(body=%s face=%s)" % [bn, d_origin, d_angle, d_scale, pbn, pfn])

	print("[probe_lp] shared bones=", shared, " / body=", body.get_bone_count(), " face=", face.get_bone_count())
	print("[probe_lp] REST DELTA max: origin=", origin_max, " m  angle=", angle_max, " deg  scale=", scale_max)
	print("[probe_lp] parent-topology mismatches among shared bones: ", parent_mismatch)
	print("[probe_lp] shared bones with non-trivial rest delta (d_origin>0.1mm or d_angle>0.05deg): ", worst.size())
	for w in worst.slice(0, 40):
		print("     ", w[0], "  d_origin=", w[1], " m  d_angle=", w[2], " deg  parent(b=", w[3], " f=", w[4], ")")

	# Skeleton node local transforms (relative to scene root), to understand world placement.
	print("[probe_lp] body skel rel-xform=", _relative_xform(root, body))
	print("[probe_lp] face skel rel-xform=", _relative_xform(root, face))
	quit(0)


func _collect(n: Node, out: Array) -> void:
	if n is Skeleton3D:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)


func _ancestry(n: Node) -> String:
	var parts: Array = []
	var p: Node = n.get_parent()
	while p != null:
		parts.append(p.name)
		p = p.get_parent()
	return ", ".join(parts)


func _relative_xform(root: Node, target: Node) -> Transform3D:
	# Accumulate local .transform from root down to target (works outside the main tree).
	var chain: Array = []
	var n: Node = target
	while n != null and n != root.get_parent():
		if n is Node3D:
			chain.append(n)
		n = n.get_parent()
	var x := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		x = x * (chain[i] as Node3D).transform
	return x


func _report_meshes(root: Node, body: Skeleton3D, face: Skeleton3D) -> void:
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var bs: int = (mi.mesh.get_blend_shape_count() if mi.mesh else 0)
			var skel_node: Node = null
			if mi.skeleton != NodePath():
				skel_node = mi.get_node_or_null(mi.skeleton)
			var tag := "?"
			if skel_node == body: tag = "BODY"
			elif skel_node == face: tag = "FACE"
			elif skel_node != null: tag = String(skel_node.name)
			print("   mesh '", mi.name, "'  surfaces=", (mi.mesh.get_surface_count() if mi.mesh else 0),
				"  blendshapes=", bs, "  skeleton=", tag)
		for c in n.get_children():
			stack.append(c)
