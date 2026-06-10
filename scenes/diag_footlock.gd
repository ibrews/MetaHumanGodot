extends SceneTree
## Foot-WOBBLE probe: over each clip, how much does each foot's WORLD position drift (X/Y/Z range)?
## A planted (stance) foot should have ~0 horizontal (X,Z) drift; large range = skating/wobble.
## Samples one tick per (clip,frame) so the AnimationMixer applies. Units = metres (tool-native GLB).
## Run: godot --headless --script scenes/diag_footlock.gd --path godot_project
var inst: Node
var skel: Skeleton3D
var ap: AnimationPlayer
var feet := ["foot_l", "foot_r", "ball_l", "ball_r"]
var clips := ["BodyIdle_Procedural", "Idle", "Sway", "Turn"]
var jobs := []          # [clip, t]
var cur_clip := ""
var acc := {}           # clip -> { bone -> [minx,maxx,miny,maxy,minz,maxz] }
var f := 0
var started := false

func _initialize() -> void:
	var ps := load("res://character.glb") as PackedScene
	if ps == null: print("DIAG: no glb"); quit(); return
	inst = ps.instantiate(); get_root().add_child(inst)

func _process(_d: float) -> bool:
	f += 1
	if f < 3: return false
	if not started:
		started = true
		skel = _find_skel(inst); ap = _find_ap(inst)
		if skel == null or ap == null: print("DIAG: skel/ap missing"); return true
		for clip in clips:
			if not ap.has_animation(clip): continue
			var L: float = ap.get_animation(clip).length
			acc[clip] = {}
			for b in feet: acc[clip][b] = [1e9, -1e9, 1e9, -1e9, 1e9, -1e9]
			for i in range(41): jobs.append([clip, L * float(i) / 40.0])
		return false
	if jobs.is_empty(): _report(); return true
	var job = jobs.pop_front()
	if job[0] != cur_clip: ap.play(job[0]); cur_clip = job[0]
	ap.seek(job[1], true); skel.force_update_all_bone_transforms()
	var sgt := skel.global_transform
	for b in feet:
		var bi := skel.find_bone(b)
		if bi < 0: continue
		var p: Vector3 = sgt * skel.get_bone_global_pose(bi).origin
		var a = acc[cur_clip][b]
		a[0] = minf(a[0], p.x); a[1] = maxf(a[1], p.x)
		a[2] = minf(a[2], p.y); a[3] = maxf(a[3], p.y)
		a[4] = minf(a[4], p.z); a[5] = maxf(a[5], p.z)
	return false

func _report() -> void:
	for clip in clips:
		if not acc.has(clip): print("  %-20s (absent)" % clip); continue
		print("  ", clip)
		for b in feet:
			var a = acc[clip][b]
			print("      %-7s drift  X=%.3f  Y=%.3f  Z=%.3f  (m)" % [b, a[1]-a[0], a[3]-a[2], a[5]-a[4]])

func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D and (n as Skeleton3D).find_bone("pelvis") >= 0 and (n as Skeleton3D).find_bone("FACIAL_L_Eye") < 0: return n
	for c in n.get_children():
		var r := _find_skel(c)
		if r: return r
	return null

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer and ((n as AnimationPlayer).has_animation("Walk") or (n as AnimationPlayer).has_animation("BodyIdle_Procedural")): return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r: return r
	return null
