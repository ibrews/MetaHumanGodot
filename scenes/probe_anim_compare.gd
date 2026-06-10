extends Node3D
## Generic GLB-animation render harness for side-by-side comparison (Vitruvian vs MetaHuman vs
## any GLB). Loads CMP_GLB, plays CMP_CLIP, seeks CMP_SEEK (paused for a clean still), frames the
## full body from a 3/4 angle, captures to CMP_OUT. Excluded from builds (scenes/probe_*).
## Run: CMP_GLB=<abs.glb> CMP_CLIP=Walk CMP_SEEK=0.4 CMP_OUT=<abs.png> godot --path <proj> scenes/probe_anim_compare.tscn --resolution 700x950

func _env(n: String, d: String) -> String:
	return OS.get_environment(n) if OS.has_environment(n) else d

func _ready() -> void:
	var glb := _env("CMP_GLB", "")
	var clip := _env("CMP_CLIP", "Walk")
	var seek := float(_env("CMP_SEEK", "0.4"))
	var out := _env("CMP_OUT", "H:/Work01/MetaHumanGodot/out/release/signoff/_cmp.png")

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -42, 0); sun.light_energy = 1.5
	add_child(sun)
	var we := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.11, 0.13, 0.2)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62); e.ambient_light_energy = 0.7
	we.environment = e; add_child(we)

	var cam := Camera3D.new(); add_child(cam)
	cam.position = Vector3(2.0, 0.95, 2.7)         # 3/4 view, full body
	cam.look_at(Vector3(0, 0.92, 0), Vector3.UP)
	cam.fov = 34

	var doc := GLTFDocument.new(); var st := GLTFState.new()
	var err := doc.append_from_file(glb, st)
	if err != OK:
		push_error("load failed %s" % glb); get_tree().quit(); return
	var scene := doc.generate_scene(st)
	add_child(scene)

	var ap := _find_ap(scene)
	var status := "no AnimationPlayer"
	if ap:
		var list := ap.get_animation_list()
		if clip in list:
			var a := ap.get_animation(clip); a.loop_mode = Animation.LOOP_LINEAR
			ap.play(clip); ap.seek(seek, true); ap.pause()
			status = "playing %s @ %.2f (of %s)" % [clip, seek, str(list)]
		else:
			status = "clip '%s' NOT in %s" % [clip, str(list)]
	print("[cmp] ", glb.get_file(), " -> ", status)

	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[cmp] saved ", out)
	await get_tree().create_timer(0.05).timeout
	get_tree().quit()

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r: return r
	return null
