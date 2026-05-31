extends Node3D

var _lines: Array = []

func _log(msg: String) -> void:
	print(msg)
	_lines.append(msg)

func _ready() -> void:
	var scene: PackedScene = load("res://character.glb")
	if scene == null:
		_log("[probe] failed to load character.glb")
		_flush()
		get_tree().quit()
		return
	var inst: Node = scene.instantiate()
	add_child(inst)
	await get_tree().process_frame
	_walk(inst, 0)
	_flush()
	get_tree().quit()

func _flush() -> void:
	var f: FileAccess = FileAccess.open("res://probe_shirt.out", FileAccess.WRITE)
	if f:
		for ln in _lines:
			f.store_line(ln)
		f.close()
		print("[probe] wrote res://probe_shirt.out (", _lines.size(), " lines)")
	else:
		print("[probe] FAILED to open output file")

func _walk(n: Node, depth: int) -> void:
	var indent: String = "  ".repeat(depth)
	_log("%s%s  [%s]" % [indent, n.name, n.get_class()])
	if n is Skeleton3D:
		var sk: Skeleton3D = n
		_log("%s  bones=%d  global_origin=%s" % [indent, sk.get_bone_count(), sk.global_transform.origin])
		for bname in ["head", "neck_01", "spine_03"]:
			var idx: int = sk.find_bone(bname)
			if idx >= 0:
				var rest: Transform3D = sk.get_bone_global_rest(idx)
				_log("%s    bone '%s' idx=%d rest_origin=%s" % [indent, bname, idx, rest.origin])
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		if mi.mesh:
			var aabb: AABB = mi.mesh.get_aabb()
			var world_xform: Transform3D = mi.global_transform
			_log("%s  mesh AABB y=(%.3f..%.3f) global=%s" % [indent, aabb.position.y, aabb.end.y, world_xform.origin])
	for child in n.get_children():
		_walk(child, depth+1)
