extends Node3D
# VR harness for the MetaHumanGodot release tool (Godot 4.7-beta3, Fort 2026-06-11).
#
# Reuses the EXACT shipped release tool — its custom skin/eye/hair shaders, texture
# wiring, LeaderPose rig, and moonlight/studio light setup — by instancing
# release.tscn, then drops a stereo XR viewer in front of the character. No material
# code is duplicated: whatever the desktop tool renders is what you see in the headset.
#
# CONTROLS — keyboard AND Touch controllers (both live):
#   KEYBOARD: W/A/S/D fly · Q/E down/up · Shift boost · Space swap char ·
#             F lighting · G face anim · H body idle · Tab cycle Mixamo clip ·
#             M toggle mouse-look (mouse X turns the view)
#   TOUCH:    left stick = fly (gaze-relative) · right stick X = smooth turn ·
#             right stick Y = up/down · right grip = boost · left grip = brake ·
#             A = swap char · B = lighting · X = face anim · Y = body idle ·
#             right stick CLICK = cycle Mixamo clip · left MENU = cycle quality
#   QUALITY:  keys 1/2/3/4 = Low/Medium/High/Epic · 0 = toggle auto-adaptive
#             (auto-adaptive drops a tier if FPS can't hold the 72 Hz floor)
#
# Char swap is gated to GLBs actually present on this machine (Gal's assets are not on
# Fort), so swapping never loads a broken placeholder.
#
# The 2D menu CANNOT render into the headset (Godot composites flat Control UI only to
# the desktop mirror, not the HMD) — worldspace-menu build is the next task. So the demo
# states below are ON by default as the in-headset substitute.
#
# Headset present  -> stereo Forward+, XROrigin/XRCamera in front of the character.
# No headset       -> FLAT fallback: release tool's own camera renders to the desktop
#                     window; VR_SMOKE=1 captures one frame to VR_OUT then quits.

var _rel: Node3D
var _flat := false
var _frame := 0
var _smoke := false
var _smoke_at := 120

var _xr_origin: XROrigin3D
var _xr_cam: XRCamera3D
var _ctl_left: XRController3D
var _ctl_right: XRController3D
var _space_down := false
var _f_down := false
var _g_down := false
var _h_down := false
# controller button edge state
var _a_down := false
var _b_down := false
var _x_down := false
var _y_down := false
var _gal_available := false

# worldspace menu (opt-in: VR_MENU=1). Reuses the real release UI via a SubViewport.
var _menu_on := false
var _menu_vp: SubViewport
var _menu_quad: MeshInstance3D
var _menu_ray: RayCast3D
var _menu_size := Vector2i(1280, 1280)
var _trig_down := false

# Mixamo body-clip cycling (matches release.gd BODY_ANIM_ORDER).
const ANIMS := ["BodyIdle_Procedural", "Idle", "Sway", "Walk", "Turn", "Wave", "HappyIdle"]
var _anim_idx := 0
var _tab_down := false
var _rstick_click_down := false
# mouse-look (toggle with M): rotate the play space, since head-look is the headset's job
var _mouse_look := false
var _mlook_down := false

const FLY_SPEED := 1.6      # m/s
const FLY_BOOST := 5.0
const FLY_BRAKE := 0.3      # left grip = slow-mo precision move
var _deadzone := 0.25       # radial deadzone — resting a thumb must NOT move you (env VR_DEADZONE)
# Auto-recenter: learn each stick's true rest center from near-center readings and subtract
# it, so a stick that drifts past the deadzone gets cancelled instead of creeping.
var _bias_l := Vector2.ZERO
var _bias_r := Vector2.ZERO
const TURN_SPEED := 1.4     # rad/s smooth turn (right stick X / mouse)
const MOUSE_TURN := 0.0042  # rad per pixel of mouse motion
const MENU_W := 0.9         # metres

# Both characters kept resident so toggling has no cold-disk load hiccup.
var _prewarm: Array = []

# Quality tiers (GPU-intensive features scaled together). Switch manually with keys 1-4 or
# the left controller menu button; auto-adaptive steps DOWN a tier if FPS can't hold 72.
const QUALITY := [
	{"name": "Low",    "ss": 0.85, "msaa": Viewport.MSAA_2X,       "fov": 3},
	{"name": "Medium", "ss": 1.0,  "msaa": Viewport.MSAA_4X,       "fov": 2},
	{"name": "High",   "ss": 1.5,  "msaa": Viewport.MSAA_8X,       "fov": 1},
	{"name": "Epic",   "ss": 2.0,  "msaa": Viewport.MSAA_8X,       "fov": 0},
]
var _quality_idx := 3          # default Epic (auto-adaptive drops it if it can't hold)
const ADAPT_FLOOR := 2         # auto-adaptive never drops below High (1.5x SSAA) — keeps
                               # grooms clean; Low/Medium are manual-only (keys 1/2)
var _adaptive := true
var _xr_iface: XRInterface
var _fps_t := 0.0
var _fps_low := 0
var _fps_high := 0
var _q_key_down := [false, false, false, false]
var _menu_btn_down := false
var _adapt_key_down := false

func _ready() -> void:
	_smoke = OS.has_environment("VR_SMOKE")
	_deadzone = _envf("VR_DEADZONE", 0.22)
	# Gal's GLB is not deployed on Fort (assets repo ships the guy only). Gate the swap
	# so pressing it never loads a broken/headless placeholder.
	_gal_available = FileAccess.file_exists("res://character_explainer.glb")
	var ps := load("res://scenes/release.tscn") as PackedScene
	_rel = ps.instantiate() as Node3D
	add_child(_rel)
	call_deferred("_setup_viewer")

func _try_switch() -> void:
	if not _gal_available:
		print("[vr] char swap ignored — Gal assets (character_explainer.glb) not on this machine.")
		return
	if _rel and _rel.has_method("_switch_character"):
		_rel.call("_switch_character")

func _setup_viewer() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var xr := XRServer.find_interface("OpenXR")
	var ok := false
	if xr != null:
		ok = xr.is_initialized()
		if not ok:
			ok = xr.initialize()
	_menu_on = OS.has_environment("VR_MENU")
	if ok:
		_enable_xr(xr)
		if _menu_on:
			_build_menu()          # keep the real UI, shown on a worldspace panel
		else:
			_hide_release_ui()     # no menu: hide the flat UI for a clean look
	else:
		_flat = true
		print("[vr] OpenXR not available (no headset / runtime) -> FLAT fallback.")

	# Demo states ON by default (the in-headset substitute for the hidden 2D menu).
	_start_demo()
	_build_floor_credits()
	call_deferred("_prewarm_characters")

# Required Unreal attribution (EULA §7a) rendered as 3D text laid on the studio floor —
# the in-headset equivalent of the desktop build's 2D credits screen (flat Control UI does
# not composite into the HMD). Visible in-build, satisfies the credit requirement.
func _build_floor_credits() -> void:
	var lbl := Label3D.new()
	lbl.name = "FloorCredits"
	lbl.text = "MetaHumanGodot uses Unreal® Engine. Unreal® is a trademark or registered\n" \
		+ "trademark of Epic Games, Inc. in the United States of America and elsewhere.\n" \
		+ "Unreal® Engine, Copyright 1998 – 2026, Epic Games, Inc. All rights reserved.\n" \
		+ "MetaHuman is a trademark of Epic Games. This product is not affiliated with,\n" \
		+ "sponsored by, or endorsed by Epic Games."
	lbl.font_size = 64
	lbl.pixel_size = 0.0011
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.modulate = Color(0.62, 0.68, 0.82)
	lbl.outline_modulate = Color(0, 0, 0, 0.6)
	lbl.outline_size = 10
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.double_sided = true
	lbl.no_depth_test = false
	lbl.rotation_degrees = Vector3(-90, 0, 0)   # lay flat on the floor
	lbl.position = Vector3(0, 0.02, 0.75)        # on the floor, in front of the character's feet
	add_child(lbl)
	print("[vr] floor credits (Unreal attribution) placed")

# Keep BOTH characters' GLB scene + textures resident in the ResourceLoader cache so the
# first Guy<->Gal toggle doesn't stall on a cold 46-76 MB disk read. (release.gd still
# re-instantiates the mesh on swap — a smaller GPU-upload cost — but no disk I/O.)
func _prewarm_characters() -> void:
	var paths := ["res://character.glb", "res://character_explainer.glb"]
	var dir := DirAccess.open("res://")
	if dir:
		for f in dir.get_files():
			if (f.begins_with("exp_") or f.begins_with("character_T_") or f.begins_with("T_")) \
					and f.ends_with(".png"):
				paths.append("res://" + f)
	var n := 0
	for pth in paths:
		if ResourceLoader.exists(pth):
			var r := load(pth)
			if r:
				_prewarm.append(r)   # hold a ref so the cache entry is never evicted
				n += 1
	print("[vr] pre-warmed ", n, " character resources (both chars resident; swap = no disk load)")

func _start_demo() -> void:
	if _rel == null:
		return
	if _rel.has_method("_set_body_anim"):
		_rel.call("_set_body_anim", true)    # procedural idle + leg shift + face-follow
	if _rel.has_method("_set_face_anim"):
		_rel.call("_set_face_anim", true)     # blendshape emote performance
	if _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", true)   # animated lighting (hue cycle)
	# Groom shadows on the face: the opt-in hair-rake light skims the hairline so the
	# hair cards throw a crisp forehead shadow (off by default; doesn't disturb the rig).
	if _rel.has_method("_set_rake"):
		_rel.call("_set_rake", true)
	# Hair-card noise: raise the coverage alpha_threshold a touch (sparser = less wispy
	# partial-coverage shimmer) unless overridden. p is a live dict; re-apply to push it.
	var thr := _envf("VR_HAIR_THRESH", 0.065)
	var pd = _rel.get("p")
	if pd is Dictionary:
		pd["hair_thresh"] = thr
		if _rel.has_method("_apply_all"):
			_rel.call("_apply_all")
	print("[vr] demo: body idle + face anim + lighting cycle + hair rake; hair_thresh=", thr)

func _hide_release_ui() -> void:
	for cl in _rel.find_children("*", "CanvasLayer", true):
		(cl as CanvasLayer).visible = false
	for c in _rel.find_children("*", "Control", true):
		(c as CanvasItem).visible = false

func _enable_xr(xr: XRInterface) -> void:
	get_viewport().use_xr = true
	_xr_iface = xr
	# Starting quality tier (env VR_QUALITY=low|medium|high|epic; VR_SS still forces a raw
	# supersample + disables adaptive for manual A/B). Auto-adaptive can be turned off with
	# VR_ADAPTIVE=0 or the 0 key in-session.
	_adaptive = _envf("VR_ADAPTIVE", 1.0) > 0.5
	if OS.has_environment("VR_QUALITY"):
		var qn := OS.get_environment("VR_QUALITY").to_lower()
		for i in QUALITY.size():
			if String(QUALITY[i]["name"]).to_lower() == qn:
				_quality_idx = i
	_apply_quality(_quality_idx)
	if OS.has_environment("VR_SS"):
		_adaptive = false
		get_viewport().scaling_3d_scale = _envf("VR_SS", 2.0)
		print("[vr] VR_SS override ", _envf("VR_SS", 2.0), "x (adaptive off)")

	_xr_origin = XROrigin3D.new()
	_xr_origin.name = "XROrigin3D"
	_xr_cam = XRCamera3D.new()
	_xr_cam.name = "XRCamera3D"
	_xr_cam.near = 0.05
	_xr_cam.far = 100.0
	_xr_origin.add_child(_xr_cam)
	# Touch controllers (read via the standard OpenXR action map copied into the project).
	_ctl_left = XRController3D.new()
	_ctl_left.name = "LeftHand"
	_ctl_left.tracker = "left_hand"
	_xr_origin.add_child(_ctl_left)
	_ctl_right = XRController3D.new()
	_ctl_right.name = "RightHand"
	_ctl_right.tracker = "right_hand"
	_xr_origin.add_child(_ctl_right)
	add_child(_xr_origin)

	# Stand the viewer where the release tool's framing camera sits (tuned to face the
	# lit 3/4 of the head), projected to the floor so head-height puts eyes at face level.
	var target := Vector3(0, 1.55, 0)
	var head := _character_head_y()
	if head > 0.0:
		target.y = head
	var relcam := _find_camera(_rel)
	var stand := Vector3(target.x, 0.0, target.z + 1.1)
	if relcam != null:
		var c := relcam.global_transform.origin
		var front := Vector3(c.x - target.x, 0.0, c.z - target.z)
		if front.length() < 0.01:
			front = Vector3(0, 0, 1)
		front = front.normalized()
		var dist: float = _envf("VR_DIST", maxf(0.9, Vector2(c.x - target.x, c.z - target.z).length()))
		stand = Vector3(target.x + front.x * dist, 0.0, target.z + front.z * dist)
	_xr_origin.global_position = stand
	_xr_origin.look_at(Vector3(target.x, 0.0, target.z), Vector3.UP)
	print("[vr] OpenXR initialized -> stereo Forward+. Viewer at ", stand, " facing head y=", target.y)

func _apply_quality(idx: int) -> void:
	_quality_idx = clampi(idx, 0, QUALITY.size() - 1)
	var q: Dictionary = QUALITY[_quality_idx]
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = q["ss"]
	vp.msaa_3d = q["msaa"]
	if _xr_iface and _xr_iface.has_method("set_foveation_level"):
		_xr_iface.set_foveation_level(q["fov"])
	print("[vr] quality -> ", q["name"], "  (SSAA ", q["ss"], "x, foveation ", q["fov"], ")")

func _update_adaptive(dt: float) -> void:
	if not _adaptive or _xr_iface == null:
		return
	_fps_t += dt
	if _fps_t < 1.0:
		return
	_fps_t = 0.0
	var fps := Engine.get_frames_per_second()
	# Sustained below the 72 Hz floor → drop a tier. Sustained comfortably above with a
	# tier in hand → climb back (long window so it doesn't oscillate).
	if fps < 67.0 and _quality_idx > ADAPT_FLOOR:
		_fps_high = 0
		_fps_low += 1
		if _fps_low >= 2:
			_fps_low = 0
			_apply_quality(_quality_idx - 1)
			print("[vr] adaptive: ", fps, " fps -> down to ", QUALITY[_quality_idx]["name"])
	elif fps >= 71.0 and _quality_idx < QUALITY.size() - 1:
		_fps_low = 0
		_fps_high += 1
		if _fps_high >= 8:
			_fps_high = 0
			_apply_quality(_quality_idx + 1)
			print("[vr] adaptive: ", fps, " fps -> up to ", QUALITY[_quality_idx]["name"])
	else:
		_fps_low = 0
		_fps_high = 0

func _find_camera(n: Node) -> Camera3D:
	for c in n.find_children("*", "Camera3D", true):
		return c as Camera3D
	return null

func _character_head_y() -> float:
	var aabb := AABB()
	var first := true
	for mi in _rel.find_children("*", "MeshInstance3D", true):
		var v := mi as MeshInstance3D
		if not v.visible:
			continue
		var b := v.global_transform * v.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	if first:
		return -1.0
	return aabb.end.y - 0.18

func _envf(n: String, d: float) -> float:
	return float(OS.get_environment(n)) if OS.has_environment(n) else d

# ---- worldspace menu (VR_MENU=1) --------------------------------------------
# Reparent the release tool's actual 2D UI (its CanvasLayers) into a SubViewport, show
# that on a worldspace quad, and forward a right-controller ray as mouse input — so the
# real sliders/buttons work in-headset without rebuilding them.
func _build_menu() -> void:
	_menu_vp = SubViewport.new()
	_menu_vp.size = _menu_size
	_menu_vp.transparent_bg = true
	_menu_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_menu_vp.gui_embed_subwindows = true
	add_child(_menu_vp)
	# Move the release UI into the SubViewport.
	for cl in _rel.find_children("*", "CanvasLayer", true):
		var par := cl.get_parent()
		if par:
			par.remove_child(cl)
		_menu_vp.add_child(cl)
		(cl as CanvasLayer).visible = true

	# Worldspace quad textured with the SubViewport.
	_menu_quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(MENU_W, MENU_W)
	_menu_quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _menu_vp.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_menu_quad.material_override = mat
	# Collision so the controller RayCast3D can hit it.
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(MENU_W, MENU_W, 0.02)
	col.shape = box
	body.add_child(col)
	_menu_quad.add_child(body)
	add_child(_menu_quad)
	# Place it floating front-left of the start view, angled toward the viewer.
	var anchor := _xr_origin.global_position if _xr_origin else Vector3(0, 1.3, 1.1)
	_menu_quad.global_position = Vector3(anchor.x - 0.5, 1.3, anchor.z - 0.45)
	_menu_quad.look_at(Vector3(anchor.x, 1.5, anchor.z), Vector3.UP)

	# Pointer ray from the right controller.
	if _ctl_right:
		_menu_ray = RayCast3D.new()
		_menu_ray.target_position = Vector3(0, 0, -6)
		_menu_ray.collide_with_areas = false
		_ctl_right.add_child(_menu_ray)
	print("[vr] worldspace menu built (SubViewport ", _menu_size, ") at ", _menu_quad.global_position)

func _update_menu() -> void:
	if not _menu_on or _menu_ray == null or _menu_vp == null:
		return
	_menu_ray.force_raycast_update()
	if not _menu_ray.is_colliding():
		return
	var hit := _menu_ray.get_collision_point()
	var local := _menu_quad.to_local(hit)
	var u := local.x / MENU_W + 0.5
	var v := 0.5 - local.y / MENU_W
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return
	var px := Vector2(u * float(_menu_size.x), v * float(_menu_size.y))
	var mm := InputEventMouseMotion.new()
	mm.position = px
	_menu_vp.push_input(mm)
	# Trigger = click.
	var trig := _ctl_right.get_float("trigger") > 0.6 if _ctl_right else false
	if trig != _trig_down:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = trig
		mb.position = px
		_menu_vp.push_input(mb)
		_trig_down = trig

func _process(dt: float) -> void:
	_handle_keys()
	_handle_controllers()
	_fly(dt)
	_update_menu()
	_update_adaptive(dt)
	if _flat:
		_frame += 1
		if _smoke and _frame == _smoke_at:
			var img := get_viewport().get_texture().get_image()
			var outp := OS.get_environment("VR_OUT") if OS.has_environment("VR_OUT") \
				else "D:/Projects/MetaHumanGodot-fort/out_pt/vr_flat_smoke.png"
			DirAccess.make_dir_recursive_absolute(outp.get_base_dir())
			img.save_png(outp)
			print("[vr] flat smoke saved -> ", outp, " (", img.get_width(), "x", img.get_height(), ")")
			get_tree().quit()

func _edge(pressed: bool, was: bool) -> bool:
	return pressed and not was

func _toggle_rel(method: String, flag: String) -> void:
	if _rel and _rel.has_method(method):
		_rel.call(method, not bool(_rel.get(flag)))

func _handle_keys() -> void:
	var sp := Input.is_physical_key_pressed(KEY_SPACE)
	if _edge(sp, _space_down):
		_try_switch()
	_space_down = sp

	var f := Input.is_physical_key_pressed(KEY_F)
	if _edge(f, _f_down):
		_toggle_rel("_set_color_cycle", "_color_cycle")
	_f_down = f

	var g := Input.is_physical_key_pressed(KEY_G)
	if _edge(g, _g_down):
		_toggle_rel("_set_face_anim", "_face_anim_on")
	_g_down = g

	var h := Input.is_physical_key_pressed(KEY_H)
	if _edge(h, _h_down):
		_toggle_rel("_set_body_anim", "_body_anim_on")
	_h_down = h

	var tab := Input.is_physical_key_pressed(KEY_TAB)
	if _edge(tab, _tab_down):
		_cycle_anim()
	_tab_down = tab

	var m := Input.is_physical_key_pressed(KEY_M)
	if _edge(m, _mlook_down):
		_mouse_look = not _mouse_look
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_look else Input.MOUSE_MODE_VISIBLE
		print("[vr] mouse-look ", _mouse_look)
	_mlook_down = m

	# Quality tiers: keys 1-4 set Low/Medium/High/Epic; 0 toggles auto-adaptive.
	var qkeys := [KEY_1, KEY_2, KEY_3, KEY_4]
	for i in qkeys.size():
		var d: bool = Input.is_physical_key_pressed(qkeys[i])
		if _edge(d, _q_key_down[i]):
			_adaptive = false
			_apply_quality(i)
		_q_key_down[i] = d
	var z := Input.is_physical_key_pressed(KEY_0)
	if _edge(z, _adapt_key_down):
		_adaptive = not _adaptive
		print("[vr] auto-adaptive ", _adaptive)
	_adapt_key_down = z

func _cycle_anim() -> void:
	if _rel == null or not _rel.has_method("_select_body_anim"):
		return
	_anim_idx = (_anim_idx + 1) % ANIMS.size()
	_rel.call("_select_body_anim", ANIMS[_anim_idx])
	_rel.call("_set_body_anim", true)
	print("[vr] body clip -> ", ANIMS[_anim_idx])

func _handle_controllers() -> void:
	if _ctl_right == null:
		return
	# A = swap char · B = lighting · grip = boost (read in _fly)
	var a: bool = _ctl_right.is_button_pressed("ax_button")
	if _edge(a, _a_down):
		_try_switch()
	_a_down = a
	var b: bool = _ctl_right.is_button_pressed("by_button")
	if _edge(b, _b_down):
		_toggle_rel("_set_color_cycle", "_color_cycle")
	_b_down = b
	# Right thumbstick click = cycle Mixamo body clip.
	var rsc: bool = _ctl_right.is_button_pressed("primary_click")
	if _edge(rsc, _rstick_click_down):
		_cycle_anim()
	_rstick_click_down = rsc
	# Left menu button = cycle quality tier (Low→Medium→High→Epic→Low), disables adaptive.
	if _ctl_left:
		var mb: bool = _ctl_left.is_button_pressed("menu_button")
		if _edge(mb, _menu_btn_down):
			_adaptive = false
			_apply_quality((_quality_idx + 1) % QUALITY.size())
		_menu_btn_down = mb
	if _ctl_left:
		# X = face anim · Y = body idle (left controller)
		var x: bool = _ctl_left.is_button_pressed("ax_button")
		if _edge(x, _x_down):
			_toggle_rel("_set_face_anim", "_face_anim_on")
		_x_down = x
		var y: bool = _ctl_left.is_button_pressed("by_button")
		if _edge(y, _y_down):
			_toggle_rel("_set_body_anim", "_body_anim_on")
		_y_down = y

func _fly(dt: float) -> void:
	if _xr_origin == null:
		return
	var move := Vector3.ZERO
	# Horizontal basis from where the headset is looking.
	var basis := (_xr_cam.global_transform.basis if _xr_cam else _xr_origin.global_transform.basis)
	var fwd := -basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var right := basis.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.01 else Vector3(1, 0, 0)

	if Input.is_physical_key_pressed(KEY_W): move += fwd
	if Input.is_physical_key_pressed(KEY_S): move -= fwd
	if Input.is_physical_key_pressed(KEY_D): move += right
	if Input.is_physical_key_pressed(KEY_A): move -= right
	if Input.is_physical_key_pressed(KEY_E): move += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q): move -= Vector3.UP

	var boost := Input.is_physical_key_pressed(KEY_SHIFT)
	# Left thumbstick = horizontal fly relative to gaze. Auto-recenter + radial deadzone +
	# response curve so resting a thumb / capacitive touch / drift does NOT move you.
	if _ctl_left:
		var ls := _stick(_ctl_left.get_vector2("primary"), true)
		move += fwd * ls.y + right * ls.x
	var brake := false
	if _ctl_right:
		var rs := _stick(_ctl_right.get_vector2("primary"), false)
		move += Vector3.UP * rs.y          # right stick Y = vertical
		if absf(rs.x) > 0.0:               # right stick X = smooth turn
			_turn(-rs.x * TURN_SPEED * dt)
		if _ctl_right.get_float("grip") > 0.7:
			boost = true                   # right grip = speed up
	if _ctl_left and _ctl_left.get_float("grip") > 0.7:
		brake = true                       # left grip = slow down (precision)

	if move != Vector3.ZERO:
		var sp := FLY_SPEED
		if boost: sp *= FLY_BOOST
		if brake: sp *= FLY_BRAKE
		if move.length() > 1.0:
			move = move.normalized()
		_xr_origin.global_position += move * sp * dt

# Full stick processing: subtract the learned rest center (auto-recenter), apply a radial
# deadzone with rescale, then a square response curve (gentle near center → full at edge,
# which kills the "drifting slowly" feel). is_left picks which bias to learn/use.
func _stick(raw: Vector2, is_left: bool) -> Vector2:
	# Learn the rest center ONLY from near-center readings (when the stick isn't really
	# being pushed), so genuine input never poisons the bias.
	if raw.length() < _deadzone * 1.5:
		if is_left:
			_bias_l = _bias_l.lerp(raw, 0.05)
		else:
			_bias_r = _bias_r.lerp(raw, 0.05)
	var v := raw - (_bias_l if is_left else _bias_r)
	return _dz(v)

# Radial deadzone with rescale + square curve: output is 0 until the stick passes the
# deadzone, then ramps 0 → full with a gentle (squared) toe so small deflections barely move.
func _dz(v: Vector2) -> Vector2:
	var m := v.length()
	if m < _deadzone:
		return Vector2.ZERO
	var t := (m - _deadzone) / (1.0 - _deadzone)
	return (v / m) * (t * t)

# Smooth-turn / mouse-turn: rotate the play space about the headset's world position so
# you pivot in place (not orbit the room).
func _turn(angle: float) -> void:
	if _xr_origin == null or _xr_cam == null:
		return
	var pivot := _xr_cam.global_position
	var r := Basis(Vector3.UP, angle)
	var xf := _xr_origin.global_transform
	_xr_origin.global_transform = Transform3D(r * xf.basis, pivot + r * (xf.origin - pivot))

func _input(event: InputEvent) -> void:
	if _mouse_look and event is InputEventMouseMotion:
		_turn(-(event as InputEventMouseMotion).relative.x * MOUSE_TURN)
