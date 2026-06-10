extends SceneTree
## Foot/pelvis height probe — what does GODOT actually do across each body clip?
## Samples one (clip,t) per process tick (so the AnimationMixer applies between seeks), reading
## bone world Y from the skeleton. Reports per clip: pelvis Y range (bob/jumps) + lowest foot Y
## reached (contact) vs the highest per-frame-lowest-foot (dangle). Units = GLB native (cm here).
## Run: godot --headless --script scenes/diag_feet.gd --path godot_project [GLB=res://character.glb]
var inst: Node
var skel: Skeleton3D
var ap: AnimationPlayer
var feet_idx := []
var pelvis_i := -1
var clips := ["BodyIdle_Procedural", "Idle", "Sway", "Walk", "Turn", "Wave", "HappyIdle"]
var jobs := []          # [clip, t]
var cur_clip := ""
var acc := {}           # clip -> [pel_lo, pel_hi, foot_min, foot_contact_max]
var f := 0
var started := false

func _initialize() -> void:
	var glb := OS.get_environment("GLB") if OS.has_environment("GLB") else "res://character.glb"
	var ps := load(glb) as PackedScene
	if ps == null: print("DIAG: cannot load ", glb); quit(); return
	inst = ps.instantiate(); get_root().add_child(inst)
	print("DIAG GLB=", glb)

func _process(_d: float) -> bool:
	f += 1
	if f < 3: return false   # let _ready run on the instanced scene
	if not started:
		started = true
		skel = _find_body_skel(inst); ap = _find_ap(inst)
		if skel == null or ap == null: print("DIAG: skel=", skel, " ap=", ap); return true
		pelvis_i = skel.find_bone("pelvis")
		for fn in ["foot_l", "foot_r", "ball_l", "ball_r"]:
			var bi := skel.find_bone(fn)
			if bi >= 0: feet_idx.append(bi)
		print("DIAG skel=", skel.name, " bones=", skel.get_bone_count(), " feet=", feet_idx.size())
		for clip in clips:
			if not ap.has_animation(clip): continue
			var L: float = ap.get_animation(clip).length
			acc[clip] = [1e9, -1e9, 1e9, -1e9]
			for i in range(21):
				jobs.append([clip, L * float(i) / 20.0])
		return false
	if jobs.is_empty():
		_report(); return true
	var job = jobs.pop_front()
	var clip: String = job[0]
	if clip != cur_clip:
		ap.play(clip); cur_clip = clip
	ap.seek(job[1], true)
	skel.force_update_all_bone_transforms()
	var sgt := skel.global_transform
	var pely: float = (sgt * skel.get_bone_global_pose(pelvis_i).origin).y
	var a = acc[clip]
	a[0] = minf(a[0], pely); a[1] = maxf(a[1], pely)
	var frame_lowest := 1e9
	for bi in feet_idx:
		frame_lowest = minf(frame_lowest, (sgt * skel.get_bone_global_pose(bi).origin).y)
	a[2] = minf(a[2], frame_lowest); a[3] = maxf(a[3], frame_lowest)
	return false

func _report() -> void:
	for clip in clips:
		if not acc.has(clip): print("  %-20s (absent)" % clip); continue
		var a = acc[clip]
		print("  %-20s pelvisY=[%.2f..%.2f] bob=%.2f | lowestFootY contact=%.2f highest=%.2f danglespan=%.2f"
			% [clip, a[0], a[1], a[1] - a[0], a[2], a[3], a[3] - a[2]])

func _find_body_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D and (n as Skeleton3D).find_bone("pelvis") >= 0 and (n as Skeleton3D).find_bone("FACIAL_L_Eye") < 0:
		return n
	for c in n.get_children():
		var r := _find_body_skel(c)
		if r: return r
	return null

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer and ((n as AnimationPlayer).has_animation("Walk") or (n as AnimationPlayer).has_animation("BodyIdle_Procedural")):
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r: return r
	return null
