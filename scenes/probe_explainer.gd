extends SceneTree

# Headless deep-probe of character_explainer.glb (HER / MH_Explainer).
# Dumps: full tree, per-mesh surfaces+material names+blendshape names,
# every Skeleton3D's key bones (+ any bone containing "Eye"), and AnimationPlayers.
# Usage: Godot --headless --script scenes/probe_explainer.gd --path godot_project

const GLB := "res://character_explainer.glb"

func _init() -> void:
	var scene: PackedScene = load(GLB)
	if scene == null:
		printerr("[probe] FAIL load ", GLB); quit(1); return
	var root: Node = scene.instantiate()
	print("\n==== TREE ", GLB, " ====")
	_walk(root, 0)
	print("\n==== SKELETONS ====")
	_skels(root)
	print("\n==== ANIM PLAYERS ====")
	_anims(root)
	print("\n==== MESH DETAIL ====")
	_meshes(root)
	quit(0)

func _walk(n: Node, d: int) -> void:
	var ind := "  ".repeat(d)
	var extra := ""
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		extra = "  surf=%d bs=%d" % [(n as MeshInstance3D).mesh.get_surface_count(), (n as MeshInstance3D).get_blend_shape_count()]
	elif n is Skeleton3D:
		extra = "  bones=%d" % (n as Skeleton3D).get_bone_count()
	elif n is AnimationPlayer:
		extra = "  anims=%s" % str((n as AnimationPlayer).get_animation_list())
	print(ind, n.name, " (", n.get_class(), ")", extra)
	for c in n.get_children(): _walk(c, d + 1)

func _skels(root: Node) -> void:
	for s in _all(root, "Skeleton3D"):
		var sk := s as Skeleton3D
		print("\nSkeleton '", sk.name, "' bones=", sk.get_bone_count(), " parent_chain=", _chain(sk))
		var probe := ["FACIAL_L_Eye", "FACIAL_R_Eye", "spine_03", "head", "pelvis",
			"calf_l", "calf_r", "neck_01", "neck_02", "FACIAL_C_FacialRoot"]
		for b in probe:
			var idx := sk.find_bone(b)
			if idx >= 0: print("   has ", b, " @", idx)
		var eyebones := []
		for i in range(sk.get_bone_count()):
			var nm := sk.get_bone_name(i)
			if "Eye" in nm or "eye" in nm: eyebones.append(nm)
		print("   *Eye* bones (", eyebones.size(), "): ", eyebones if eyebones.size() <= 30 else eyebones.slice(0, 30))

func _anims(root: Node) -> void:
	var found := false
	for a in _all(root, "AnimationPlayer"):
		found = true
		var ap := a as AnimationPlayer
		print("AnimationPlayer '", ap.name, "' anims=", ap.get_animation_list())
		for an in ap.get_animation_list():
			var clip := ap.get_animation(an)
			print("   '", an, "' len=", clip.length, " tracks=", clip.get_track_count())
	if not found: print("(none — HER GLB ships NO AnimationPlayer)")

func _meshes(root: Node) -> void:
	for m in _all(root, "MeshInstance3D"):
		var mi := m as MeshInstance3D
		if mi.mesh == null: continue
		var am := mi.mesh as ArrayMesh
		print("\nMesh '", mi.name, "' surfaces=", mi.mesh.get_surface_count(), " blendshapes=", mi.get_blend_shape_count())
		for s in range(mi.mesh.get_surface_count()):
			var mat: Material = mi.mesh.surface_get_material(s)
			var rn := (mat.resource_name if mat else "<null>")
			var cnt := 0
			if am:
				var arr := am.surface_get_arrays(s)
				if arr.size() > 0 and arr[Mesh.ARRAY_VERTEX] != null:
					cnt = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			print("   surf[", s, "] mat='", rn, "' verts=", cnt)
		if am and mi.get_blend_shape_count() > 0:
			var names := []
			for i in range(mi.get_blend_shape_count()):
				names.append(am.get_blend_shape_name(i))
			print("   blendshapes(", names.size(), "): ", names)

func _all(root: Node, cls: String) -> Array:
	var out := []
	var st: Array[Node] = [root]
	while st.size() > 0:
		var n: Node = st.pop_back()
		if n.is_class(cls): out.append(n)
		for c in n.get_children(): st.append(c)
	return out

func _chain(n: Node) -> String:
	var s := ""
	var p := n.get_parent()
	while p != null:
		s = String(p.name) + "/" + s
		p = p.get_parent()
	return s
