extends SceneTree

# Headless probe: load character.glb, walk the tree, print mesh + blend shape names.
# Usage: Godot --headless --script scenes/probe_glb.gd --path godot_project

func _init() -> void:
	var scene: PackedScene = load("res://character.glb")
	if scene == null:
		printerr("[probe_glb] FAIL: could not load res://character.glb")
		quit(1)
		return
	var root: Node = scene.instantiate()
	print("[probe_glb] root: ", root.name, " (", root.get_class(), ")")
	_walk(root, 0)
	quit(0)


func _walk(node: Node, depth: int) -> void:
	var indent: String = "  ".repeat(depth)
	var info: String = "%s%s (%s)" % [indent, node.name, node.get_class()]
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mesh: Mesh = mi.mesh
		var n_keys: int = mi.get_blend_shape_count() if mi.has_method("get_blend_shape_count") else 0
		var n_surfaces: int = mesh.get_surface_count() if mesh != null else 0
		info += "  surfaces=%d  blend_shapes=%d" % [n_surfaces, n_keys]
		print(info)
		# If it has many blend shapes, list the first dozen names
		if n_keys > 0 and mesh is ArrayMesh:
			var am: ArrayMesh = mesh
			var names: Array = []
			for i in range(min(n_keys, 15)):
				names.append(am.get_blend_shape_name(i))
			print(indent, "  shape keys[0..14] = ", names)
			# Find ARKit specific names
			var arkit: Array = ["jawOpen", "eyeBlinkLeft", "mouthSmileLeft", "tongueOut", "browInnerUp"]
			var present: Array = []
			for j in range(n_keys):
				var nm: String = am.get_blend_shape_name(j)
				if nm in arkit:
					present.append(nm)
			print(indent, "  ARKit sentinels present: ", present)
	else:
		print(info)
	for child in node.get_children():
		_walk(child, depth + 1)
