extends SceneTree
# Probe MetaHumanFace surfaces: for each surface index, print vert count,
# material name from original mesh, and the 3D bounds of the verts on that
# surface. Run via:
#   Godot --headless --script res://scenes/probe_face_surfaces.gd

func _init() -> void:
	var scene: PackedScene = load("res://character.glb")
	var root: Node = scene.instantiate()
	var face: MeshInstance3D = _find(root, "MetaHumanFace") as MeshInstance3D
	if face == null:
		print("no MetaHumanFace")
		quit()
		return
	var mesh: Mesh = face.mesh
	print("MetaHumanFace: %d surfaces, %d blend shapes" % [mesh.get_surface_count(), mesh.get_blend_shape_count()])

	for s in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var orig_mat: Material = mesh.surface_get_material(s)
		var mat_name: String = "(null)"
		if orig_mat:
			mat_name = orig_mat.resource_name
		var n: int = verts.size()
		if n == 0:
			print("  surf %d: 0 verts" % s)
			continue
		var xmin = INF; var xmax = -INF
		var ymin = INF; var ymax = -INF
		var zmin = INF; var zmax = -INF
		var umin = INF; var umax = -INF
		var vmin = INF; var vmax = -INF
		for v in verts:
			if v.x < xmin: xmin = v.x
			if v.x > xmax: xmax = v.x
			if v.y < ymin: ymin = v.y
			if v.y > ymax: ymax = v.y
			if v.z < zmin: zmin = v.z
			if v.z > zmax: zmax = v.z
		for uv in uvs:
			if uv.x < umin: umin = uv.x
			if uv.x > umax: umax = uv.x
			if uv.y < vmin: vmin = uv.y
			if uv.y > vmax: vmax = uv.y
		print("  surf %d: verts=%d mat='%s'  xyz=[(%.3f..%.3f), (%.3f..%.3f), (%.3f..%.3f)]  uv=[(%.3f..%.3f), (%.3f..%.3f)]" % [
			s, n, mat_name,
			xmin, xmax, ymin, ymax, zmin, zmax,
			umin, umax, vmin, vmax])
	quit()

func _find(n: Node, name: String) -> Node:
	if n.name == name: return n
	for c in n.get_children():
		var r = _find(c, name)
		if r: return r
	return null
