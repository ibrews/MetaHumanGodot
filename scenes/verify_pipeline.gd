extends SceneTree
## ============================================================================
## MetaHuman → Godot — PIPELINE REGRESSION PROBE
## ============================================================================
## Structural invariant check for the two shipped character GLBs, so a silent
## pipeline break (a re-export that drops the skeleton / shape keys / idle, a
## groom that vanishes, a face that loses surfaces) is caught immediately.
##
## Run (headless, ~5s):
##   & "H:/dev/godot-stock/Godot_v4.6-stable_win64.exe" --headless \
##       --script scenes/verify_pipeline.gd --path "H:/Work01/MetaHumanGodot/godot_project"
## Exit code 0 = all PASS, 1 = a check FAILED (drives the verify_pipeline.py runner).
## Expected baselines below are the validated 2026-06-04 rigged build.
## ============================================================================

var _fails := 0

func _init() -> void:
	for spec in [["res://character.glb", "guy / MH_Guy"], ["res://character_explainer.glb", "gal / MH_Gal"]]:
		print("\n== %s  (%s) ==" % [spec[1], spec[0]])
		_check(spec[0])
	print("\n== SUMMARY: %s ==" % ("ALL CHECKS PASSED" if _fails == 0 else "%d CHECK(S) FAILED" % _fails))
	quit(1 if _fails > 0 else 0)

func _ok(cond: bool, msg: String) -> void:
	print(("  PASS  " if cond else "  FAIL  ") + msg)
	if not cond: _fails += 1

func _check(path: String) -> void:
	var ps: PackedScene = load(path)
	if ps == null:
		_ok(false, "GLB loads"); return
	_ok(true, "GLB loads")
	var root: Node = ps.instantiate()
	var skels := _all(root, "Skeleton3D")
	var meshes := _all(root, "MeshInstance3D")
	var anims := _all(root, "AnimationPlayer")

	# --- skeletons: a body rig (idle/legs) + a face rig (gaze/expressions) ---
	var body: Skeleton3D = null
	var face: Skeleton3D = null
	for s in skels:
		var sk := s as Skeleton3D
		if sk.find_bone("FACIAL_L_Eye") >= 0 and sk.find_bone("FACIAL_R_Eye") >= 0:
			face = sk
		elif sk.find_bone("spine_03") >= 0 and sk.find_bone("head") >= 0 and sk.find_bone("calf_l") >= 0:
			body = sk
	_ok(body != null, "BODY skeleton (spine_03 + head + calf_l) — body idle + leg idle")
	if body:
		_ok(body.find_bone("pelvis") >= 0 and body.find_bone("calf_r") >= 0, "body has pelvis + calf_r")
	_ok(face != null, "FACE skeleton (FACIAL_L/R_Eye) — bone-driven gaze")

	# --- idle animation ---
	var has_idle := false
	for a in anims:
		if (a as AnimationPlayer).get_animation_list().size() > 0: has_idle = true
	_ok(has_idle, "AnimationPlayer with >=1 clip (body idle)")

	# --- face mesh: shape keys + 9 surfaces + ARKit sentinels ---
	var facemesh: MeshInstance3D = null
	var best := 0
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi.mesh and mi.get_blend_shape_count() > best:
			best = mi.get_blend_shape_count(); facemesh = mi
	_ok(facemesh != null and best >= 40, "face mesh has >=40 blend shapes (got %d)" % best)
	if facemesh:
		_ok(facemesh.mesh.get_surface_count() == 9, "face mesh has 9 surfaces (got %d)" % facemesh.mesh.get_surface_count())
		if facemesh.mesh is ArrayMesh:
			var names := []
			for i in range(facemesh.get_blend_shape_count()):
				names.append(str((facemesh.mesh as ArrayMesh).get_blend_shape_name(i)))
			var missing := []
			for n in ["jawOpen", "eyeBlinkLeft", "mouthSmileLeft", "noseSneerLeft", "tongueOut"]:
				if not (n in names): missing.append(n)
			_ok(missing.is_empty(), "ARKit sentinels present (missing: %s)" % str(missing))

	# --- body mesh + at least one groom card ---
	var has_body := false
	var grooms := 0
	for m in meshes:
		var nm := String((m as MeshInstance3D).name)
		if nm == "Body" or nm.begins_with("Body"): has_body = true
		for pre in ["Hair", "Beard", "Eyebrows", "Mustache", "Moustache"]:
			if nm.begins_with(pre): grooms += 1; break
	_ok(has_body, "Body mesh present")
	_ok(grooms >= 1, "at least one groom card mesh (got %d)" % grooms)
	root.free()

func _all(root: Node, cls: String) -> Array:
	var out := []
	var st: Array[Node] = [root]
	while st.size() > 0:
		var n: Node = st.pop_back()
		if n.is_class(cls): out.append(n)
		for c in n.get_children(): st.append(c)
	return out
