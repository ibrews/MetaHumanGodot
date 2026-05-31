extends Node3D

@export var face_name_hint: String = "face"

func _ready() -> void:
	var face := _find_mesh_with_shape_keys()
	if face == null:
		push_error("Morph test: no MeshInstance3D with blend shapes found.")
		return

	var count: int = face.mesh.get_blend_shape_count()
	print("Morph test: face mesh '%s' has %d blend shapes." % [face.name, count])

	if count == 0:
		push_error("Morph test: face mesh has 0 blend shapes — re-export needed.")
		return

	var jaw_idx := face.find_blend_shape_by_name("jawOpen")
	if jaw_idx >= 0:
		face.set_blend_shape_value(jaw_idx, 0.8)
		print("Morph test: jawOpen set to 0.8 — ✅ ARKit-named morph targets present.")
	else:
		print("Morph test: 'jawOpen' not found. Available blend shape names:")
		for i in range(count):
			print("  [%d] %s" % [i, face.mesh.get_blend_shape_name(i)])
		print("If names look mangled, see Blender export step — names may be prefixed.")

func _find_mesh_with_shape_keys() -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_count := -1
	var stack: Array[Node] = [self]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var m := n as MeshInstance3D
			if m.mesh and m.mesh.get_blend_shape_count() > best_count:
				best = m
				best_count = m.mesh.get_blend_shape_count()
		for c in n.get_children():
			stack.append(c)
	return best
