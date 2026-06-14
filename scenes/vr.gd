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
#             F lighting · G face anim · H body idle · Tab cycle Mixamo pose ·
#             T shadows · V ASW · I toggle info overlay · M mouse-look
#   TOUCH:    left stick = fly (gaze-relative) · right stick X = smooth turn ·
#             right stick Y = up/down · right grip = boost · left grip = brake
#             A = swap char · B = lighting demo · X = face anim · Y = body idle
#             left MENU = cycle quality tier · right stick CLICK = cycle Mixamo pose
#             left stick CLICK = toggle info overlay · left TRIGGER = shadows
#             right TRIGGER = ASW (Application SpaceWarp 36→72)
#   QUALITY:  keys 1/2/3/4 = Low/Medium/High/Epic · 0 = toggle auto-adaptive
#             (auto-adaptive drops a tier if FPS can't hold the 72 Hz floor)
#   INFO:     a worldspace stats panel (fps/tier/settings/state) + a controls
#             legend float to the lower-left/right; ON by default on Quest, hide
#             with left-stick-click / I. Every toggle's live state shows there.
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

# Mixamo body-clip cycling. CURATED to IN-PLACE clips only: the right-stick-click "weird
# glitch" was cycling into "Walk"/"Turn", whose Mixamo root motion translates the whole
# character out of the fixed VR framing (reads as the figure sliding/teleporting away).
# Dropping the two locomotion clips leaves only planted-feet poses, so cycling never moves
# the character off its mark.
const ANIMS := ["BodyIdle_Procedural", "Idle", "Sway", "Wave", "HappyIdle"]
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
# STANDALONE QUEST ladder — far lighter than the PCVR build's (which topped out at SSAA 2x
# / MSAA 8x). On the Adreno 740 even "Epic" here is conservative. ss<1.0 renders below the
# per-eye target and upscales; fov is the fixed-foveation level (0=off .. 3=high).
# ★ ss MUST be 1.0 on standalone. scaling_3d_scale != 1.0 + XR + foveation makes Godot
# 4.7-beta3's Mobile renderer compute a foveated draw region that exceeds the scaled
# framebuffer ("custom region must be contained within the framebuffer rectangle") →
# draw_list_begin fails → garbage frames. Native scale = region matches framebuffer = stable.
# Perf is clawed back via aggressive fixed foveation (fov 3) + MSAA off + shadows off.
const QUALITY := [
	{"name": "Low",    "ss": 1.0, "msaa": Viewport.MSAA_DISABLED, "fov": 3},
	{"name": "Medium", "ss": 1.0, "msaa": Viewport.MSAA_DISABLED, "fov": 2},
	{"name": "High",   "ss": 1.0, "msaa": Viewport.MSAA_2X,       "fov": 2},
	{"name": "Epic",   "ss": 1.0, "msaa": Viewport.MSAA_2X,       "fov": 1},
]
var _quality_idx := 1          # default Medium on standalone (Android forces Low in _enable_xr)
var ADAPT_FLOOR := 0           # standalone: adaptive may drop all the way to Low
var ADAPT_CEIL := 3            # max tier adaptive will climb to (Android caps to High=2 in
                               # _enable_xr: Epic collapses to ~35 fps on the Adreno 740)
var _adaptive := true
var _xr_iface: XRInterface
var _fps_t := 0.0
var _fps_low := 0
var _fps_high := 0
# On-device perf readout: worldspace HUD (visible in screenshots) + periodic logcat print.
var _hud: Label3D
var _perf_t := 0.0
var _is_android := false
var _dumped := false
var _shadows_on := true
var _t_down := false
var _loading: Label3D
var _q_key_down := [false, false, false, false]
var _menu_btn_down := false
var _adapt_key_down := false

# Application SpaceWarp (Meta XR_FB_space_warp) — toggled live via the native extension's
# set_enabled(). Project setting is ON so the extension is REQUESTED at session init (it can't
# be toggled if it was never requested), but we start it disabled so the default look is the
# clean native render. ON = app may render ~36 and the compositor reprojects to 72 (with the
# known left-eye reprojection seam — that's the trade-off this toggle lets people judge).
var _asw_ext = null   # untyped: the singleton's methods are resolved dynamically
var _asw_on := false
var _asw_key_down := false
var _ltrig_down := false
var _rtrig_down := false
# Info overlay (live stats panel + controls legend). ON by default on Quest; toggle with the
# left stick click / I key. Both labels float off to the side, billboarded, depth-test off.
var _hud_on := true
var _legend: Label3D
var _lstick_click_down := false
var _info_key_down := false

func _ready() -> void:
	_smoke = OS.has_environment("VR_SMOKE")
	_deadzone = _envf("VR_DEADZONE", 0.22)
	# Gal's GLB is not deployed on Fort (assets repo ships the guy only). Gate the swap
	# so pressing it never loads a broken/headless placeholder.
	_gal_available = FileAccess.file_exists("res://character_explainer.glb")
	# The character (76 MB GLB + mesh/blendshape build) takes several seconds to load. We DON'T
	# load it here — instead _boot() brings up the XR session + a "Loading…" panel first, submits
	# a frame, THEN loads the character (the compositor holds the loading frame during the freeze)
	# so the user sees "Loading…" instead of a black void.
	call_deferred("_boot")

func _try_switch() -> void:
	if not _gal_available:
		print("[vr] char swap ignored — Gal assets (character_explainer.glb) not on this machine.")
		return
	if _rel and _rel.has_method("_switch_character"):
		_rel.call("_switch_character")
		# The swapped-in character is rebuilt with the custom shaders again — re-convert it to
		# StandardMaterial3D (immediately, before the first render) and catch its late grooms.
		if _is_android:
			_dumped = true
			_quest_mobile_materials()
			_apply_shadows()
			call_deferred("_post_switch_fixup")

func _post_switch_fixup() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_quest_mobile_materials()   # grooms attach a few frames after the rebuild
	_apply_shadows()
	# keep the standalone demo tuning (animated lighting off — per-frame shadow cost)
	if _rel and _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", false)

# ---- Quest standalone material conversion (Mobile renderer) -----------------
# Replace each custom ShaderMaterial with a StandardMaterial3D built from the textures the
# release tool already loaded. Plain PBR — no screen-space SSS (Mobile lacks it), no custom
# wrapped-diffuse — but it compiles on the Adreno where the custom light() shaders don't.
func _quest_mobile_materials() -> void:
	var swapped := 0
	# owned=false: release.gd's meshes are runtime-instantiated with no owner, so the default
	# owned=true scan finds nothing (this is why the first attempt swapped 0).
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		# single material_override (floor/backdrop custom shaders also won't compile on Mobile)
		if m.material_override is ShaderMaterial:
			var so := _to_standard(m.material_override as ShaderMaterial)
			if so:
				m.material_override = so
				swapped += 1
		var cnt := m.get_surface_override_material_count()
		for s in cnt:
			var mat: Material = m.get_surface_override_material(s)
			if mat == null and m.mesh:
				mat = m.mesh.surface_get_material(s)
			if mat is ShaderMaterial:
				var st := _to_standard(mat as ShaderMaterial)
				if st:
					m.set_surface_override_material(s, st)
					swapped += 1
			elif DBG_BLOB and mat is StandardMaterial3D:
				# pre-existing SM3D my swap skipped (hide shells, teeth, outfit) -> MAGENTA
				var dm := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				dm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				dm.emission_enabled = true; dm.emission = Color(0.9, 0, 0.9)
				dm.albedo_color = Color(0.9, 0, 0.9, 1)
				m.set_surface_override_material(s, dm)
	print("[vr] quest mobile materials: swapped ", swapped, " ShaderMaterial(s) -> StandardMaterial3D")
	# One-time geometry dump to locate the floating-black-blob artifact (AABB world center,
	# since skinned meshes sit at the origin). Gated so it only spams once.
	if not _dumped:
		_dumped = true
		for mi in _rel.find_children("*", "MeshInstance3D", true, false):
			var v := mi as MeshInstance3D
			var ctr: Vector3 = (v.global_transform * v.get_aabb()).get_center()
			var mt := "?"
			var m0 := v.get_surface_override_material(0)
			if m0 == null and v.mesh and v.mesh.get_surface_count() > 0:
				m0 = v.mesh.surface_get_material(0)
			if m0:
				mt = m0.get_class()
				if m0 is StandardMaterial3D and (m0 as StandardMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					mt += "(transp)"
			print("[mesh] %-28s vis=%s ctr=(%.2f,%.2f,%.2f) surf=%d mat=%s" % [v.name, v.visible, ctr.x, ctr.y, ctr.z, (v.mesh.get_surface_count() if v.mesh else 0), mt])

const DBG_BLOB := false   # diag: tint materials to ID the left-eye blob (was an ASW artifact)
const BOOT_AS_HER := false   # test hook: boot directly as Gal to verify her materials swap

func _to_standard(sm: ShaderMaterial) -> StandardMaterial3D:
	var path := sm.shader.resource_path.get_file() if sm.shader else ""
	var st := StandardMaterial3D.new()
	# NOTE: order matters — "eyelash" contains "eye", so test hair/eyelash before eye.
	if path.contains("skin_shader"):
		st.albedo_texture = sm.get_shader_parameter("texture_albedo")
		var nt = sm.get_shader_parameter("texture_normal")
		if nt:
			st.normal_enabled = true
			st.normal_texture = nt
			st.normal_scale = 0.9
		var rt = sm.get_shader_parameter("texture_roughness")
		if rt:
			st.roughness_texture = rt
			st.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		st.roughness = 1.0
		st.metallic = 0.0
		st.metallic_specular = 0.35
		if DBG_BLOB:
			st.emission_enabled = true; st.emission = Color(0.8, 0, 0)   # skin/hands = RED
		return st
	elif path.contains("hair") or path.contains("eyelash"):
		var col = sm.get_shader_parameter("hair_color")
		if not (col is Color):
			col = sm.get_shader_parameter("lash_color")
		var hc: Color = col if col is Color else Color(0.2, 0.14, 0.08)
		# Keep the brown — earlier ×1.7 + emission washed it to white. Modest lift + matte.
		var bright := Color(clampf(hc.r * 1.25, 0, 1), clampf(hc.g * 1.25, 0, 1), clampf(hc.b * 1.25, 0, 1))
		st.albedo_color = bright
		st.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		st.alpha_scissor_threshold = 0.18   # low: groom atlas strands are thin/sparse in R
		st.cull_mode = BaseMaterial3D.CULL_DISABLED
		st.roughness = 0.9                  # matte: less cool-rim sheen washing it white
		st.metallic_specular = 0.1
		st.emission_enabled = true          # tiny COLOURED lift so it isn't black, not white
		st.emission = hc * 0.06
		if DBG_BLOB:
			st.albedo_color = Color(0, 0.9, 0.9); st.emission = Color(0, 0.9, 0.9)  # grooms = CYAN
		var cov = sm.get_shader_parameter("coverage_atlas")
		var use_red := bool(sm.get_shader_parameter("use_red_mask")) if sm.get_shader_parameter("use_red_mask") != null else false
		# Coverage → ALPHA, RGB white. Prefer the OFFLINE-baked `<atlas>_alpha.png` (instant load).
		# The old runtime per-pixel bake blocked the main thread ~2-3 s at startup → stalled XR
		# frame submission → Adreno GPU faults / corruption. Offline bake removes that entirely.
		if cov is Texture2D:
			var stem := String(cov.resource_path).get_file().get_basename()
			var pre := "res://%s_alpha.png" % stem
			if ResourceLoader.exists(pre):
				st.albedo_texture = load(pre)
			else:
				st.albedo_texture = _coverage_to_alpha(cov, Color.WHITE, use_red or path.contains("eyelash"))
		return st
	elif path.contains("eye"):
		# The eye.gdshader composites a small iris disc over the (light) sclera. Using the iris
		# texture alone made the whole eyeball dark-brown -> black under moonlight. Use the
		# pre-baked composite (sclera + centered iris disc + limbal ring); pick L/R off the
		# iris texture path. Fall back to the (light) sclera so eyes are never black.
		var iris = sm.get_shader_parameter("iris_texture")
		var sclera = sm.get_shader_parameter("sclera_texture")
		var ipath := String(iris.resource_path) if (iris and iris is Resource) else ""
		var side := "R" if ipath.contains("_R") else "L"
		# Gal's eye textures are exp_eye_*; the guy's are eye_*. Pick the matching composite.
		var who := "exp_" if ipath.contains("exp_") else ""
		var comp := "res://eye_composite_%s%s.png" % [who, side]
		st.albedo_texture = load(comp) if ResourceLoader.exists(comp) else (sclera if sclera else iris)
		st.clearcoat_enabled = true
		st.clearcoat = 1.0
		st.clearcoat_roughness = 0.06
		st.roughness = 0.30
		st.metallic_specular = 0.5
		st.emission_enabled = true     # tiny self-lift so eyes read under the dim rig, never black
		st.emission = Color(0.05, 0.05, 0.05)
		var en = sm.get_shader_parameter("iris_normal")
		if en:
			st.normal_enabled = true
			st.normal_texture = en
			st.normal_scale = 0.4
		return st
	# unknown/outfit/floor custom shader: keep its albedo if any, else a neutral material so
	# nothing custom survives to fail compilation on the Adreno.
	var a = sm.get_shader_parameter("texture_albedo")
	if a:
		st.albedo_texture = a
	else:
		# floor/backdrop shaders are procedural — approximate with the project clear colour.
		st.albedo_color = Color(0.05, 0.055, 0.07)
		st.roughness = 1.0
		if DBG_BLOB:
			st.emission_enabled = true; st.emission = Color(0, 0.7, 0)   # floor/backdrop = GREEN
	return st

# Bake a groom coverage atlas (strand mask in R, alpha=255) into an RGBA texture whose ALPHA
# is the strand coverage so StandardMaterial3D's alpha-scissor cuts the strands. Done at a
# capped resolution so the per-pixel GDScript loop stays a sub-second one-time startup cost.
func _coverage_to_alpha(tex: Texture2D, rgb: Color, red_is_coverage: bool) -> Texture2D:
	var img := tex.get_image()
	if img == null:
		return tex
	if img.is_compressed():
		img.decompress()
	var cap := 768   # balance strand detail vs the per-pixel GDScript bake cost (ANR risk)
	if img.get_width() > cap:
		img.resize(cap, cap, Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var cover := c.r if red_is_coverage else maxf(c.a, c.r)
			# boost: strand cores are bright but sparse; widen them so scissor keeps strands
			cover = clampf(cover * 1.7, 0.0, 1.0)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, cover))
	out.generate_mipmaps()
	return ImageTexture.create_from_image(out)

func _boot() -> void:
	await get_tree().process_frame
	var xr := XRServer.find_interface("OpenXR")
	var ok := false
	if xr != null:
		ok = xr.is_initialized()
		if not ok:
			ok = xr.initialize()
	_menu_on = OS.has_environment("VR_MENU")
	_is_android = OS.get_name() == "Android"
	if ok:
		# 1) Bring up the XR session + camera + a "Loading…" panel FIRST, and submit a few frames
		#    so the compositor has the loading image, BEFORE the multi-second character load.
		_enable_xr(xr)
		_build_loading_screen()
		for _i in range(6):
			await get_tree().process_frame
		# 2) Heavy character load — the main thread freezes ~4-9 s; the compositor holds the last
		#    submitted frame (the loading panel) the whole time instead of going black.
		_load_character()
		await get_tree().process_frame
		await get_tree().process_frame
		if _is_android:
			_quest_mobile_materials()   # catch late-attached grooms (a 2nd pass)
		# 3) Reveal: frame the viewer on the character, start the demo, drop the loading panel.
		_frame_to_character()
		if _menu_on:
			_build_menu()
		else:
			_hide_release_ui()
		_start_demo()
		_build_floor_credits()
		if _is_android:
			_apply_shadows()   # shadows default OFF on standalone (locked-High territory)
		_remove_loading_screen()
	else:
		# --- No VR: load the shipped desktop tool exactly as-is (sliders, orbit cam, 2D credits). ---
		_load_character()
		_flat = true
		print("[vr] OpenXR not available -> desktop tool (full sliders, no VR overrides).")

	if not _is_android:
		call_deferred("_prewarm_characters")

# Instance the release tool + character (the heavy part) and swap its custom ShaderMaterials to
# StandardMaterial3D before the next frame renders it (release.gd wires them synchronously in its
# own _ready, which runs inside add_child here).
func _load_character() -> void:
	if BOOT_AS_HER:
		OS.set_environment("RELEASE_CHAR", "her")
	var ps := load("res://scenes/release.tscn") as PackedScene
	_rel = ps.instantiate() as Node3D
	add_child(_rel)
	if OS.get_name() == "Android":
		_quest_mobile_materials()

# Camera-locked "Loading…" panel shown while the character loads (see _boot).
func _build_loading_screen() -> void:
	_loading = Label3D.new()
	_loading.name = "LoadingScreen"
	_loading.text = "Digital Human Test\n" \
		+ "Featuring Epic Games MetaHumans,\nrunning in the Godot engine\n\nLoading…"
	_loading.font_size = 56
	_loading.pixel_size = 0.0013
	_loading.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_loading.modulate = Color(0.86, 0.89, 0.96)
	_loading.outline_modulate = Color(0, 0, 0, 0.85)
	_loading.outline_size = 14
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading.no_depth_test = true
	if _xr_cam:
		_xr_cam.add_child(_loading)
		_loading.position = Vector3(0, 0, -1.4)
	else:
		add_child(_loading)
		_loading.position = Vector3(0, 1.5, -0.3)
	print("[vr] loading screen shown")

func _remove_loading_screen() -> void:
	if _loading and is_instance_valid(_loading):
		_loading.queue_free()
	_loading = null
	print("[vr] loading screen removed; character ready")

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
	# Animated hue-cycle lighting re-renders the directional shadow map every frame — on the
	# Adreno that intermittently blows the 13.8 ms (72 Hz) budget, so the compositor halves to
	# 36. Keep it OFF on standalone (static moonlight) for a stable 72; on PCVR it's free.
	if _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", not _is_android)
	# Groom shadows on the face: the opt-in hair-rake light skims the hairline so the
	# hair cards throw a crisp forehead shadow (off by default; doesn't disturb the rig).
	# On standalone the extra shadow-casting spot is another per-frame cost — skip it.
	if _rel.has_method("_set_rake") and not _is_android:
		_rel.call("_set_rake", true)
	# Hair-card noise: raise the coverage alpha_threshold a touch (sparser = less wispy
	# partial-coverage shimmer) unless overridden. p is a live dict; re-apply to push it.
	var thr := _envf("VR_HAIR_THRESH", 0.065)
	var pd = _rel.get("p")
	if pd is Dictionary:
		pd["hair_thresh"] = thr
		if _rel.has_method("_apply_all"):
			_rel.call("_apply_all")
	print("[vr] demo: body idle + face anim; lighting_cycle=", not _is_android, " rake=", not _is_android, " hair_thresh=", thr)

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
	_is_android = OS.get_name() == "Android"
	if _is_android:
		# ★ PIN a fixed tier, NO adaptive. Changing SSAA scale / MSAA / foveation at runtime
		# reallocates the XR render target + recreates pipelines, and on the Adreno that
		# intermittently fails -> the whole frame's draw pass dies (draw_list.active errors) ->
		# garbage framebuffer. The old adaptive system thrashed High<->Medium every ~2s on the
		# 3S (High only hits ~50 fps there), corrupting the view "half the time". Medium (SSAA
		# 0.85 / MSAA 2x / fov 3) holds a stable 72 with shadows off, so just lock it.
		# Pin LOW (SSAA 0.70 / MSAA OFF / fov 3). MSAA + foveation together is a flaky Adreno
		# combo that intermittently corrupts frames; Low has no MSAA and the lightest GPU load
		# (most thermally robust). No adaptive — runtime render-config changes also corrupt.
		_quality_idx = 0          # Low
		_adaptive = false
		ADAPT_FLOOR = 0
		ADAPT_CEIL = 0
		_shadows_on = false   # shadows off by default — locked-High territory (see _setup_viewer)
	if OS.has_environment("VR_QUALITY"):
		var qn := OS.get_environment("VR_QUALITY").to_lower()
		for i in QUALITY.size():
			if String(QUALITY[i]["name"]).to_lower() == qn:
				_quality_idx = i
	# Application SpaceWarp (Meta XR_FB_space_warp). The project setting requests the extension at
	# session init so it CAN be toggled live (set_enabled() is a no-op if it was never requested).
	# We grab the singleton and force it OFF at boot: the default experience is the clean native
	# render; the user flips it on with the right trigger to A/B the 36→72 reprojection (and its
	# left-eye seam). Pin tier still applies — ASW reprojection rides on top of whatever we render.
	if Engine.has_singleton("OpenXRFbSpaceWarpExtension"):
		_asw_ext = Engine.get_singleton("OpenXRFbSpaceWarpExtension")
		if _asw_ext and _asw_ext.has_method("set_enabled"):
			_asw_ext.set_enabled(false)
		_asw_on = false
		print("[vr] ASW extension present; started OFF (right-trigger toggles 36→72)")
	_apply_quality(_quality_idx)
	# Info overlay default visibility: shown on Quest, opt-in (VR_HUD=1) on PCVR so the working
	# desktop/PCVR build isn't visually disturbed. The overlay itself is BUILT below, once the XR
	# camera exists (it parents to the camera). Perf is logged to logcat as [perf] regardless.
	_hud_on = _is_android or OS.has_environment("VR_HUD")
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
	# Default stand (character not loaded yet — the loading screen is camera-locked so this is
	# just a sane world position). _frame_to_character() re-stands us once the character exists.
	_xr_origin.global_position = Vector3(0, 0, 1.1)
	_xr_origin.look_at(Vector3(0, 0, 0), Vector3.UP)
	# Build the info overlay now that _xr_cam exists (it parents to the camera so it tracks gaze).
	_build_hud()
	print("[vr] OpenXR initialized -> stereo Forward+ (loading…).")

# Re-stand the viewer to face the loaded character (called after the GLB is in the tree).
func _frame_to_character() -> void:
	if _xr_origin == null or _rel == null:
		return
	var target := Vector3(0, 1.55, 0)
	var head := _character_head_y()
	if head > 0.5 and head < 3.0:   # clamp: owned=false AABB can catch the huge backdrop mesh
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
	print("[vr] framed viewer at ", stand, " facing head y=", target.y)

# Worldspace perf HUD — a Label3D floating to the viewer's left, billboarded, showing live
# fps / frame time / tier / per-eye render size. Visible in headset screenshots so on-device
# perf can be read without a logcat round-trip. Updated once per second in _update_perf.
func _build_hud() -> void:
	# Live stats panel — lower-LEFT of view. fps/frame-time/tier/every setting + toggle state.
	_hud = Label3D.new()
	_hud.name = "PerfHUD"
	_hud.text = "fps --"
	_hud.font_size = 38
	_hud.pixel_size = 0.0009
	_hud.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hud.modulate = Color(0.4, 1.0, 0.5)
	_hud.outline_modulate = Color(0, 0, 0, 0.85)
	_hud.outline_size = 12
	_hud.no_depth_test = true                 # always readable, never occluded by the head
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Parent to the camera so it tracks the gaze; offset to the lower-left of view.
	if _xr_cam:
		_xr_cam.add_child(_hud)
		_hud.position = Vector3(-0.42, -0.20, -1.0)
	else:
		add_child(_hud)
		_hud.position = Vector3(-0.5, 1.4, 0.4)
	# Controls legend — lower-RIGHT of view. Static; tells people what every button does so the
	# build is self-documenting in-headset (no printed manual, no desktop mirror in standalone).
	_legend = Label3D.new()
	_legend.name = "ControlsLegend"
	_legend.font_size = 32
	_legend.pixel_size = 0.0009
	_legend.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_legend.modulate = Color(0.66, 0.78, 0.95)
	_legend.outline_modulate = Color(0, 0, 0, 0.85)
	_legend.outline_size = 10
	_legend.no_depth_test = true
	_legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_legend.text = "A swap character   B lighting demo\n" \
		+ "X face anim        Y body idle\n" \
		+ "L-menu quality   R-stick click: pose\n" \
		+ "L-trig shadows   R-trig ASW\n" \
		+ "L-stick click: hide this panel\n" \
		+ "L-stick move · R-stick turn/up-down · grip speed"
	if _xr_cam:
		_xr_cam.add_child(_legend)
		_legend.position = Vector3(0.42, -0.24, -1.0)
	else:
		add_child(_legend)
		_legend.position = Vector3(0.5, 1.4, 0.4)
	_set_hud_visible(_hud_on)
	print("[vr] info overlay built (stats + controls legend)")

func _set_hud_visible(on: bool) -> void:
	_hud_on = on
	if _hud and is_instance_valid(_hud):
		_hud.visible = on
	if _legend and is_instance_valid(_legend):
		_legend.visible = on

func _toggle_hud() -> void:
	_set_hud_visible(not _hud_on)
	print("[vr] info overlay ", ("shown" if _hud_on else "hidden"))

# Toggle Application SpaceWarp live via the native extension. set_enabled() flips the per-frame
# motion-vector + depth submission the compositor reprojects from; it only works because the
# project setting requested XR_FB_space_warp at session init (see project.godot).
func _toggle_asw() -> void:
	if _asw_ext == null:
		print("[vr] ASW toggle ignored — XR_FB_space_warp extension not available")
		return
	_asw_on = not _asw_on
	if _asw_ext.has_method("set_enabled"):
		_asw_ext.set_enabled(_asw_on)
	print("[vr] ASW ", ("ON (36→72 reproject)" if _asw_on else "OFF (native rate)"))

func _update_perf(dt: float) -> void:
	_perf_t += dt
	if _perf_t < 1.0:
		return
	_perf_t = 0.0
	var fps := Engine.get_frames_per_second()
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var draw := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prim := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
	var q: Dictionary = QUALITY[_quality_idx]
	var eye := "?"
	if _xr_iface and _xr_iface.has_method("get_render_target_size"):
		var rts: Vector2 = _xr_iface.get_render_target_size()
		eye = "%dx%d" % [int(rts.x), int(rts.y)]
	# Live feature/toggle state (read from the release tool so the panel never drifts from truth).
	var who := "—"
	var pose := "—"
	var light_on := false
	var face_on := false
	var body_on := false
	if _rel:
		who = "Gal" if String(_rel.get("_char_key")) == "her" else "Guy"
		pose = String(_rel.get("_body_anim_name"))
		if pose == "": pose = ANIMS[_anim_idx]
		pose = pose.replace("BodyIdle_Procedural", "Procedural")
		light_on = bool(_rel.get("_color_cycle"))
		face_on = bool(_rel.get("_face_anim_on"))
		body_on = bool(_rel.get("_body_anim_on"))
	# logcat line (parsed off-device): keep it grep-friendly and on one line.
	print("[perf] fps=%.1f proc=%.2fms draw=%d prim=%d vmem=%.0fMB tier=%s ss=%.2f msaa=%d fov=%d eye=%s asw=%s shadows=%s light=%s char=%s pose=%s" \
		% [fps, proc_ms, draw, prim, vmem, q["name"], q["ss"], int(q["msaa"]), int(q["fov"]), eye, _asw_on, _shadows_on, light_on, who, pose])
	if _hud and _hud_on:
		var col := Color(0.4, 1.0, 0.5) if fps >= 71.0 else (Color(1.0, 0.85, 0.3) if fps >= 60.0 else Color(1.0, 0.4, 0.4))
		_hud.modulate = col
		_hud.text = "fps %.0f   (%.1f ms)\nchar %s   pose %s\ntier %s   ss%.2f msaa%d fov%d\nASW %s   shadows %s\nlighting %s   face %s   body %s\neye %s   draw %d   vmem %.0fMB" \
			% [fps, proc_ms, who, pose, q["name"], q["ss"], int(q["msaa"]), int(q["fov"]), \
			_on(_asw_on), _on(_shadows_on), _on(light_on), _on(face_on), _on(body_on), eye, draw, vmem]

func _on(b: bool) -> String:
	return "ON" if b else "off"

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
	elif fps >= 71.0 and _quality_idx < ADAPT_CEIL:
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
	for c in n.find_children("*", "Camera3D", true, false):
		return c as Camera3D
	return null

func _character_head_y() -> float:
	var aabb := AABB()
	var first := true
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
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
	_update_perf(dt)
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

	var t := Input.is_physical_key_pressed(KEY_T)
	if _edge(t, _t_down):
		_toggle_shadows()
	_t_down = t

	var m := Input.is_physical_key_pressed(KEY_M)
	if _edge(m, _mlook_down):
		_mouse_look = not _mouse_look
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_look else Input.MOUSE_MODE_VISIBLE
		print("[vr] mouse-look ", _mouse_look)
	_mlook_down = m

	var info := Input.is_physical_key_pressed(KEY_I)
	if _edge(info, _info_key_down):
		_toggle_hud()
	_info_key_down = info

	var vk := Input.is_physical_key_pressed(KEY_V)
	if _edge(vk, _asw_key_down):
		_toggle_asw()
	_asw_key_down = vk

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
	# Gal's explainer GLB is a static bake (no skeleton / AnimationPlayer) — cycling Mixamo poses
	# on her does nothing but a rigid sway, so skip it and surface why in the panel.
	if String(_rel.get("_char_key")) == "her":
		print("[vr] pose cycle skipped — Gal is a static bake (no skeleton)")
		return
	_anim_idx = (_anim_idx + 1) % ANIMS.size()
	_rel.call("_select_body_anim", ANIMS[_anim_idx])
	_rel.call("_set_body_anim", true)
	print("[vr] body clip -> ", ANIMS[_anim_idx])

# Toggle shadow casting on every light in the scene. On the Adreno the shadow maps are both a
# real per-frame cost AND read blobby/low-res — this lets the user A/B them live (B button / T).
func _toggle_shadows() -> void:
	_shadows_on = not _shadows_on
	_apply_shadows()

func _apply_shadows() -> void:
	var n := 0
	for li in _rel.find_children("*", "Light3D", true, false):
		(li as Light3D).shadow_enabled = _shadows_on
		n += 1
	print("[vr] shadows ", ("ON" if _shadows_on else "OFF"), " on ", n, " light(s)")

func _handle_controllers() -> void:
	if _ctl_right == null:
		return
	# A = swap char · B = lighting · grip = boost (read in _fly)
	var a: bool = _ctl_right.is_button_pressed("ax_button")
	if _edge(a, _a_down):
		_try_switch()
	_a_down = a
	# B = lighting demo (the hue-cycle "crazy lighting"). Now cheap on standalone too: with
	# shadows OFF by default its per-frame shadow re-render cost is gone, so it holds 72.
	var b: bool = _ctl_right.is_button_pressed("by_button")
	if _edge(b, _b_down):
		_toggle_rel("_set_color_cycle", "_color_cycle")
	_b_down = b
	# Right thumbstick click = cycle Mixamo pose (curated in-place clips).
	var rsc: bool = _ctl_right.is_button_pressed("primary_click")
	if _edge(rsc, _rstick_click_down):
		_cycle_anim()
	_rstick_click_down = rsc
	# Right trigger = toggle ASW (Application SpaceWarp 36→72).
	var rt: bool = _ctl_right.get_float("trigger") > 0.8
	if _edge(rt, _rtrig_down):
		_toggle_asw()
	_rtrig_down = rt
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
		# Left thumbstick click = toggle the info overlay (panel + legend).
		var lsc: bool = _ctl_left.is_button_pressed("primary_click")
		if _edge(lsc, _lstick_click_down):
			_toggle_hud()
		_lstick_click_down = lsc
		# Left trigger = toggle shadows (was the B button on standalone).
		var lt: bool = _ctl_left.get_float("trigger") > 0.8
		if _edge(lt, _ltrig_down):
			_toggle_shadows()
		_ltrig_down = lt

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
