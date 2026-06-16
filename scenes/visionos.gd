extends Node3D
# visionOS XR harness for the MetaHumanGodot release tool — Godot's OWN renderer via Apple's
# CompositorServices fork (rsanchezsaez/Clancey, PR #109975). NOT godotrealitykit.
# ─────────────────────────────────────────────────────────────────────────────
# Godot's renderer skins MetaHumans natively (godotrealitykit rendered bind pose only → only the
# grooms showed). Validated in the visionOS Simulator AND on a physical AVP. See KB:
# projects/metahuman-godot-pipeline/visionos-port.md.
#
# Custom GLSL skin/eye/hair shaders don't compile on the visionOS Mobile/Metal renderer (same wall
# as Quest's Adreno), so _to_standard()/_coverage_to_alpha() (lifted verbatim from scenes/vr.gd)
# swap them to StandardMaterial3D before the first frame.
#
# MSAA MUST be off on this fork (Cascade/godot#78598) — with it on, the device renders only
# passthrough ("purgatory"). Forced off here + in project.godot.
#
# LIVE SETTINGS (user://mh_settings.cfg, polled): character (guy/her), scale, shadow (off/high),
# placement (front/height). Write the cfg into the app container and the change applies without a
# rebuild (sim: the Documents/ path; device: the in-world control panel). Defaults below.

# --- tunables -----------------------------------------------------------------
const FACE_USER_YAW_DEG := 90.0    # rotate the rig CCW so the figure faces the viewer
const DIAG := "user://mh_diag.txt"        # one-shot mesh dump + skinning verdict
const FRAMES := "user://mh_frames.txt"    # liveness samples (proves the loop runs)
const SETTINGS := "user://mh_settings.cfg"
const POLL_DT := 0.5               # how often to re-read the settings cfg (seconds)

# --- applied settings (mirror of the cfg; defaults) ---------------------------
var _s_char := "guy"               # "guy" | "her"
var _s_scale := 1.0                # uniform scale of the figure
var _s_shadow := "off"             # "off" | "high" — default OFF; toggle to crisp hi-res self-shadow
var _s_front := 0.9                # metres in front of the user
var _s_height := 0.0               # manual eye-height nudge (m); 0 = eyes level with the viewer
# (The LOOK-preset experiment was removed: post-contrast/AgX rendered fine in the sim but produced
# color artifacts on-device. The plain look-dev WorldEnvironment in visionos.tscn is the keeper.)

# --- state --------------------------------------------------------------------
var _rel: Node3D
var _xr_ok := false
var _swapped := 0
var _frames := 0
var _samples := 0
var _diag_t := 0.0
var _poll_t := 0.0
var _busy := false                 # guards against overlapping reloads

# --- hand-visualisation cycle (ported from Cascade Countdown) -----------------
# 3-way cycle that never shows nothing: MESH hands (HandMeshDriver3D) → BOTH → REAL arms
# (visionOS passthrough, via user://upper_limb.txt which the Clancey engine polls → .upperLimbVisibility).
var _hand_drivers: Array = []
var _hand_mesh_visible := true     # MESH-only at boot (matches Cascade's default)
var _real_arms_visible := false

# --- pinch-and-drag manipulation (ported from Cascade Countdown main_v2.gd) ----
# One-hand pinch = grab/MOVE (PickupHandler3D latches a PickupAbleBody3D, body follows the hand).
# Two-hand pinch on a grabbed body = SCALE + TURNTABLE-ROTATE. Rotation is CONSTRAINED TO YAW (Y)
# only — pitch/roll are discarded (the figure/panel never tips over). Grabbables: the figure
# (_rel, wrapped in _rel_body) and the control panel (_panel is itself a PickupAbleBody3D).
const GRAB_LAYER := 4              # physics layer 3: grabbable bodies. Distinct from GAZE_LAYER(2).
const PINCH_START := 0.024         # thumb–index TIP gap (m) to BEGIN a two-hand pinch point
const PINCH_END := 0.052           # gap to END it (hysteresis, prevents flicker)
const SCALE_MIN := 0.1
const SCALE_MAX := 10.0
const SCALE_END_GRACE := 8         # frames a pinch may drop mid-gesture before it truly ends
const SCALE_FOLLOW_ALPHA := 0.5    # ease toward the raw two-hand target (1 = no smoothing)
const SCALE_MAX_ORIGIN_STEP := 0.6 # metres/frame position cap (single-frame spike rejection)
var _hand_handlers: Dictionary = {}        # side → PickupHandler3D
var _rel_body: PickupAbleBody3D            # grab wrapper around the figure; _rel rides inside it
var _rel_grabbed := false                  # latched on first figure grab → stop auto-anchoring _rel
var _panel_grabbed := false                # latched on first panel grab (telemetry only)
var _index_pinch_state := {"left_hand": false, "right_hand": false}
var _scale_active := false
var _scale_target: Node3D = null
var _scale_lost_frames := 0
var _scale_A0 := Vector3.ZERO              # world pinch points (L,R) at engage
var _scale_B0 := Vector3.ZERO
var _scale_T0: Transform3D = Transform3D.IDENTITY  # target body transform at engage
var _scale_filt_ready := false
var _scale_filt_origin := Vector3.ZERO
var _scale_filt_basis := Basis.IDENTITY
var _grab_log_count := 0                   # bounds the device grab-telemetry file

# --- in-world gaze-dwell control panel (head-only; no hand tracking needed) ----
const BTN_W := 0.27
const BTN_H := 0.085
const BTN_GAP := 0.022
const DWELL_SEC := 1.1
const GAZE_LAYER := 2
const TOUCH_ENABLED := true        # poke-to-press (hand tracking, additive to gaze-dwell). Re-enabled in the
                                   # device-validated re-add; harmless when no hand-tracking data (early-returns).
const BTN_IDLE := Color(0.10, 0.13, 0.18, 0.85)
const BTN_HOT := Color(0.10, 0.78, 0.98, 0.96)
var _panel: Node3D
var _cam: XRCamera3D
var _buttons: Array = []
var _cooldown := 0.0
var _s_px := -0.42                 # control-panel X (cfg panel_x): to the left, out of forward gaze
var _s_py := 0.0                   # control-panel Y OFFSET from the viewer's eye height (cfg panel_y)
var _s_pz := -0.60                 # control-panel Z (cfg panel_z): in front; its MIDDLE sits at eye level

func _ready() -> void:
	_load_settings()                       # read cfg → _s_* before instancing so the right char boots
	OS.set_environment("RELEASE_CHAR", _s_char)
	_init_visionos_xr()
	call_deferred("_boot")

# Initialize the visionOS XR interface and route the viewport through it. MSAA/FSR/screen-space-AA
# forced off — MSAA does not render on this fork on-device (Cascade: godot#78598), and the project
# default (Quest inherited msaa_3d=1) would otherwise reintroduce the empty render.
func _init_visionos_xr() -> void:
	var interface := XRServer.find_interface("visionOS")
	if interface and interface.initialize():
		var vp := get_viewport()
		vp.use_xr = true
		vp.vrs_mode = Viewport.VRS_XR
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		# FXAA is a post-process pass (NOT the hardware MSAA that's broken here) — it smooths the
		# alpha-scissor hair/beard card edges that otherwise alias into a blocky/flickering mass.
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		var origin := get_node_or_null("XROrigin3D") as XROrigin3D
		if origin:
			origin.current = true
		_cam = get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
		# NOTE: XRServer has NO `pose_recentered` signal in this fork's editor/runtime — referencing it
		# was a PARSE ERROR that failed the WHOLE script to load → no _ready → device "passthrough
		# purgatory" (the real multi-round root cause). Crown-recenter auto-reanchor is dropped; the
		# figure still anchors on boot via _position_character(). (_on_recenter stays defined/unused.)
		_xr_ok = true
		print("[visionos-xr] visionOS XR interface initialized — use_xr + VRS_XR; MSAA off; FXAA on")
	else:
		push_warning("[visionos-xr] visionOS interface unavailable — desktop flat-camera fallback")
		var cam := Camera3D.new()
		cam.name = "FlatFallbackCamera"
		cam.near = 0.05
		cam.far = 100.0
		cam.current = true
		add_child(cam)
		cam.position = Vector3(0, 1.4, 0)

func _boot() -> void:
	await get_tree().process_frame
	_load_character()
	await _setup_loaded_character()
	_apply_shadow()
	_build_panel()
	_setup_hands()
	_apply_hand_visibility()
	_dump_meshes()
	print("[visionos-xr] ready — char=%s scale=%.2f shadow=%s front=%.2f" % [_s_char, _s_scale, _s_shadow, _s_front])

func _load_character() -> void:
	# The figure rides inside a PickupAbleBody3D so a one-hand pinch can grab/move it and a two-hand
	# pinch can scale/turntable it. The body is the transform owner (placement/scale/eye-anchor all
	# write _rel_body); _rel stays at local identity inside it. The body persists across guy↔gal
	# reloads (so a switched character reappears wherever the user last placed it).
	if _rel_body == null:
		_rel_body = PickupAbleBody3D.new()
		_rel_body.name = "FigureBody"
		_setup_figure_body(_rel_body)
		add_child(_rel_body)
	var ps := load("res://scenes/release.tscn") as PackedScene
	_rel = ps.instantiate() as Node3D
	_rel_body.add_child(_rel)

# Grab-body setup for the figure: a capsule roughly enclosing a standing MetaHuman (feet at the body
# origin), grab-only layer, frozen + stay-where-placed on release (a figure shouldn't fall/throw).
func _setup_figure_body(body: PickupAbleBody3D) -> void:
	body.collision_layer = GRAB_LAYER
	body.collision_mask = 0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze_on_release = true
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = 1.70                 # spans ~0.05..1.75 m in body space → covers a standing figure
	cs.shape = cap
	cs.position = Vector3(0.0, 0.9, 0.0)
	body.add_child(cs)

# Convert materials (2-pass, grooms attach a few frames late), strip look-dev UI/cameras, calm the
# demo, place + scale + face the user, hide the studio backdrop. Used by both _boot and reload.
func _setup_loaded_character() -> void:
	_convert_materials()
	await get_tree().process_frame
	await get_tree().process_frame
	_convert_materials()
	_hide_release_ui()
	_disable_release_cameras()
	_quiet_demo()
	_apply_scale()
	_position_character()
	_hide_studio_meshes()
	_tame_hair_backing()

# The head hair ships as TWO coincident surfaces — the visible cards (bone-attached, skin=false) and
# a "_Backing" fill (skin=true). Driven by different transforms, they micro-slide against each other
# as the head moves → z-fighting flicker (the beard/mustache have no backing, so they're clean).
# Hide the backing; the cards are the actual hair.
func _tame_hair_backing() -> void:
	if _rel == null:
		return
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if String(m.name).contains("Backing"):
			m.visible = false

# Diagnostic written to the app container (Godot stdout isn't captured on this fork). The full
# skinned figure rendering is the real proof — get_aabb() returns pre-skin (collapsed) bounds for
# GPU-skinned meshes, so AABB size is NOT a skinning indicator under Godot's own renderer.
func _dump_meshes() -> void:
	if _rel == null:
		return
	var lines: Array[String] = []
	lines.append("=== MetaHuman visionOS XR diag — Godot's OWN renderer (CompositorServices) ===")
	lines.append("char=%s scale=%.2f shadow=%s front=%.2f height=%.2f xr_ok=%s swapped=%d" \
		% [_s_char, _s_scale, _s_shadow, _s_front, _s_height, _xr_ok, _swapped])
	lines.append("")
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var aabb := m.global_transform * m.get_aabb()
		var ctr := aabb.get_center()
		var sz := aabb.size
		var skinned := (m.skin != null) or (m.skeleton != NodePath() and m.get_node_or_null(m.skeleton) != null)
		var bs := 0
		if m.mesh and m.mesh is ArrayMesh:
			bs = (m.mesh as ArrayMesh).get_blend_shape_count()
		var ov := m.material_override.get_class() if m.material_override else "-"
		var surfmats := ""
		var sc := (m.mesh.get_surface_count() if m.mesh else 0)
		for s in sc:
			var sm := m.get_surface_override_material(s)
			var src := "ovr" if sm else "mesh"
			if sm == null and m.mesh:
				sm = m.mesh.surface_get_material(s)
			surfmats += "%s:%s " % [src, (sm.get_class() if sm else "null")]
		var line := "[mesh] %-26s vis=%s skin=%s bs=%d surf=%d override=%s [%s] ctr=(%.2f,%.2f,%.2f) size=(%.2f,%.2f,%.2f)" \
			% [m.name, m.visible, skinned, bs, sc, ov, surfmats.strip_edges(), ctr.x, ctr.y, ctr.z, sz.x, sz.y, sz.z]
		lines.append(line)
		print(line)
	var f := FileAccess.open(DIAG, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f.close()

# Walk every MeshInstance3D under the release tool and replace custom ShaderMaterials with
# StandardMaterial3D (material_override AND per-surface). owned=false: release.gd's meshes are
# runtime-instantiated with no owner, so the default owned=true scan finds nothing.
func _convert_materials() -> void:
	if _rel == null:
		return
	var swapped := 0
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
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
	_swapped += swapped
	print("[visionos] converted ", swapped, " ShaderMaterial(s) -> StandardMaterial3D")

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
		return st
	elif path.contains("hair") or path.contains("eyelash"):
		var col = sm.get_shader_parameter("hair_color")
		if not (col is Color):
			col = sm.get_shader_parameter("lash_color")
		var hc: Color = col if col is Color else Color(0.2, 0.14, 0.08)
		var bright := Color(clampf(hc.r * 1.25, 0, 1), clampf(hc.g * 1.25, 0, 1), clampf(hc.b * 1.25, 0, 1))
		st.albedo_color = bright
		st.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		st.alpha_scissor_threshold = 0.18
		st.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Matte hair: specular highlights on the thin hair cards alias into a flickering light/dark
		# shimmer as the head moves (no MSAA to damp it). Disable specular entirely + full roughness.
		st.roughness = 1.0
		st.metallic_specular = 0.0
		st.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		st.emission_enabled = true
		st.emission = hc * 0.06
		var cov = sm.get_shader_parameter("coverage_atlas")
		var use_red := bool(sm.get_shader_parameter("use_red_mask")) if sm.get_shader_parameter("use_red_mask") != null else false
		if cov is Texture2D:
			var stem := String(cov.resource_path).get_file().get_basename()
			var pre := "res://%s_alpha.png" % stem
			if ResourceLoader.exists(pre):
				st.albedo_texture = load(pre)
			else:
				st.albedo_texture = _coverage_to_alpha(cov, Color.WHITE, use_red or path.contains("eyelash"))
		return st
	elif path.contains("eye"):
		var iris = sm.get_shader_parameter("iris_texture")
		var sclera = sm.get_shader_parameter("sclera_texture")
		var ipath := String(iris.resource_path) if (iris and iris is Resource) else ""
		var side := "R" if ipath.contains("_R") else "L"
		var who := "exp_" if ipath.contains("exp_") else ""
		var comp := "res://eye_composite_%s%s.png" % [who, side]
		st.albedo_texture = load(comp) if ResourceLoader.exists(comp) else (sclera if sclera else iris)
		st.clearcoat_enabled = true
		st.clearcoat = 1.0
		st.clearcoat_roughness = 0.06
		st.roughness = 0.30
		st.metallic_specular = 0.5
		st.emission_enabled = true
		st.emission = Color(0.05, 0.05, 0.05)
		var en = sm.get_shader_parameter("iris_normal")
		if en:
			st.normal_enabled = true
			st.normal_texture = en
			st.normal_scale = 0.4
		return st
	# unknown/outfit/floor custom shader: keep albedo if any, else a neutral material.
	var a = sm.get_shader_parameter("texture_albedo")
	if a:
		st.albedo_texture = a
	else:
		st.albedo_color = Color(0.05, 0.055, 0.07)
		st.roughness = 1.0
	return st

func _coverage_to_alpha(tex: Texture2D, rgb: Color, red_is_coverage: bool) -> Texture2D:
	var img := tex.get_image()
	if img == null:
		return tex
	if img.is_compressed():
		img.decompress()
	var cap := 1024
	if img.get_width() > cap:
		img.resize(cap, cap, Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var cover := c.r if red_is_coverage else maxf(c.a, c.r)
			cover = clampf(cover * 1.7, 0.0, 1.0)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, cover))
	out.generate_mipmaps()
	return ImageTexture.create_from_image(out)

# Hide the desktop look-dev 2D UI (sliders/panels) — not wanted in the immersive view.
func _hide_release_ui() -> void:
	if _rel == null:
		return
	for cl in _rel.find_children("*", "CanvasLayer", true):
		(cl as CanvasLayer).visible = false
	for c in _rel.find_children("*", "Control", true):
		(c as CanvasItem).visible = false

# release.gd creates its own Camera3D with current=true (look-dev framing) — disable every camera
# under the release tool so the XRCamera (or the desktop flat fallback) is the only active one.
func _disable_release_cameras() -> void:
	if _rel == null:
		return
	for c in _rel.find_children("*", "Camera3D", true, false):
		(c as Camera3D).current = false

# The release tool ships a studio backdrop cyc + floor plane (huge flat meshes). They don't belong
# in immersive AR, and rotating the rig would swing the backdrop into view. Hide any oversized mesh
# (skinned character meshes report a collapsed get_aabb() from GPU skinning; grooms are sub-metre).
func _hide_studio_meshes() -> void:
	if _rel == null:
		return
	var n := 0
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var sz := (m.global_transform * m.get_aabb()).size
		if maxf(sz.x, maxf(sz.y, sz.z)) > 4.0:
			m.visible = false
			n += 1
	print("[visionos-xr] hid ", n, " oversized studio mesh(es) (backdrop/floor)")

# Start a calm idle (face + body) but keep the per-frame hue-cycle lighting OFF.
func _quiet_demo() -> void:
	if _rel == null:
		return
	if _rel.has_method("_set_body_anim"):
		_rel.call("_set_body_anim", true)
	if _rel.has_method("_set_face_anim"):
		_rel.call("_set_face_anim", true)
	if _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", false)

# Place the figure: feet on the floor (height, default 0), `front` metres ahead, facing the user.
func _position_character() -> void:
	if _rel_body == null:
		return
	# Once the user has manually grabbed the figure, NEVER re-anchor it — the grab owns the transform
	# (the RECONCILE requirement: the eye-anchor must not fight a manual move).
	if _rel_grabbed:
		return
	_rel_body.position.x = 0.0
	_rel_body.position.z = -_s_front
	_rel_body.rotation = Vector3(0.0, deg_to_rad(FACE_USER_YAW_DEG), 0.0)
	_match_eye_height()
	print("[visionos-xr] placed: eye-matched y=%.2f, front=%.2f m, scale=%.2f, yaw +%.0f°" \
		% [_rel_body.position.y, _s_front, _s_scale, FACE_USER_YAW_DEG])

# Sit the figure so its eyes are at the VIEWER's eye height (XRCamera Y) — feet then fall naturally
# on the floor, at any scale (the user asked to match eyes, not feet). This is robust to the root-
# pivot ambiguity that left the feet underground when placing the root at y=0. _s_height is a manual
# nudge on top (0 = level with the viewer).
func _match_eye_height() -> void:
	if _rel_body == null:
		return
	if _cam == null:
		_rel_body.position.y = _s_height   # desktop / no-XR fallback
		return
	var eye := _character_eye_y()
	# eye_y is linear in _rel_body.position.y, so this moves the eyes exactly onto the target.
	_rel_body.position.y += (_cam.global_position.y + _s_height) - eye

# Crown-recenter (the user holds the Digital Crown → XRServer.pose_recentered): re-anchor the figure
# + panel to the new eye height. This and boot are the ONLY times we re-anchor — never on normal head
# motion (which was causing the constant drift).
func _on_recenter() -> void:
	_position_character()
	if _panel and _cam:
		_panel.position = Vector3(_s_px, _cam.global_position.y + _s_py, _s_pz)

# World Y of the character's eyes, estimated from the head grooms (hair/brows/beard — real AABBs).
# The skinned face/body report a COLLAPSED get_aabb() (GPU skinning) so they're skipped; the studio
# backdrop/floor is hidden / oversized so it's skipped too.
func _character_eye_y() -> float:
	if _rel == null:
		return 1.5
	var aabb := AABB()
	var first := true
	for mi in _rel.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if not m.visible:
			continue
		var b := m.global_transform * m.get_aabb()
		var mx := maxf(b.size.x, maxf(b.size.y, b.size.z))
		if mx < 0.03 or mx > 4.0:   # skip collapsed skinned meshes and oversized studio geo
			continue
		aabb = b if first else aabb.merge(b)
		first = false
	if first:
		return _rel.global_position.y + 1.5
	return aabb.end.y - 0.12   # crown of the grooms minus ~12 cm ≈ eye line

# Uniform scale about the figure's origin (feet) — grows/shrinks upward from the floor. Applied to
# the grab body (the figure rides inside it), so the grab collider scales with the figure too.
func _apply_scale() -> void:
	if _rel_body == null:
		return
	_rel_body.scale = Vector3(_s_scale, _s_scale, _s_scale)

# Directional shadow: OFF, or HIGH (crisp self-shadowing — 4096 map via project.godot + tuned bias,
# a single orthogonal split tight on the figure so it isn't blocky).
func _apply_shadow() -> void:
	# release.gd builds its OWN rig — key/fill/rim SpotLights + a "HairRake" spot, several with
	# shadow_enabled. THOSE (blocky, low positional-shadow filter) were the "other shadow" the toggle
	# never touched. Force EVERY light's shadow off first, so OFF really is off.
	for n in find_children("*", "Light3D", true, false):
		(n as Light3D).shadow_enabled = false
	# Our single directional is the toggle: OFF, or one crisp hi-res self-shadow.
	var dl := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if dl and _s_shadow == "high":
		dl.shadow_enabled = true
		dl.shadow_bias = 0.03
		dl.shadow_normal_bias = 1.5
		dl.shadow_blur = 1.0
		dl.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		# Tight frustum on the figure: 8192 atlas (project.godot) over ~1.8 m ≈ huge texel density.
		dl.directional_shadow_max_distance = 1.8   # was 2.5 — tighter = crisper (less blocky)

# --- UI actions (also persist to the cfg so panel + external writers share one source) --------
func ui_toggle_char() -> void:
	_s_char = "her" if _s_char == "guy" else "guy"
	_save_settings()
	_reload_character()

func ui_bump_scale(d: float) -> void:
	_s_scale = clampf(_s_scale + d, 0.3, 3.0)
	_save_settings()
	_apply_scale()
	_position_character()   # re-match eye height at the new scale (so the feet stay grounded)

func ui_toggle_shadow() -> void:
	_s_shadow = "off" if _s_shadow == "high" else "high"
	_save_settings()
	_apply_shadow()

func _activate(action: String) -> void:
	var f := FileAccess.open(FRAMES, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(FRAMES, FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string("activated: %s\n" % action)
		f.close()
	match action:
		"char": ui_toggle_char()
		"up": ui_bump_scale(0.15)
		"down": ui_bump_scale(-0.15)
		"shadow": ui_toggle_shadow()
		"hands": _cycle_hands_mode()

# --- hand-visualisation cycle (ported from Cascade Countdown) -----------------
# One HandMeshDriver3D per hand, parented to XROrigin3D (renders the XR-Tools low-poly hand mesh
# from XRHandTracker joints). The real (passthrough) arms are toggled via user://upper_limb.txt.
func _setup_hands() -> void:
	var origin := get_node_or_null("XROrigin3D") as Node3D
	if origin == null:
		return
	for side in ["left_hand", "right_hand"]:
		# Cascade's pinch-drag rig: an XRController3D per hand carries a PickupHandler3D that re-pins
		# to the thumb-index midpoint each frame, detects nearby PickupAbleBody3D within detect_range,
		# and runs the pinch grab/release latch. Hand tracking drives the pinch from thumb–index TIP
		# distance (the controller action map is an unused fallback), so no input map is needed.
		var controller := XRController3D.new()
		controller.tracker = side
		var handler := PickupHandler3D.new()
		handler.detect_range = 0.07               # near-contact: pinch within ~7 cm of the body to grab
		handler.follow_fingertips = true
		handler.hold_while_hand_tracking_uncertain = true
		handler.pickup_press_threshold = 0.85      # firm pinch — tips must close to ~1.2 cm
		handler.collision_mask = GRAB_LAYER
		var hcs := CollisionShape3D.new()
		hcs.name = "CollisionShape3D"               # PickupHandler3D._update_detect_range() expects this name
		var sphere := SphereShape3D.new()
		sphere.radius = 0.3                          # overwritten by detect_range in the handler's _ready
		hcs.shape = sphere
		handler.add_child(hcs)
		controller.add_child(handler)
		origin.add_child(controller)
		_hand_handlers[side] = handler

		# Existing low-poly hand mesh (kept — the visualisation cycle still drives it).
		var d := HandMeshDriver3D.new()
		d.tracker_name = "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
		d.is_left = (side == "left_hand")
		origin.add_child(d)
		_hand_drivers.append(d)

# 3-way cycle that can NEVER land on "no hands": MESH only → BOTH → REAL only → (wrap) MESH only.
func _cycle_hands_mode() -> void:
	if _hand_mesh_visible and not _real_arms_visible:
		_real_arms_visible = true            # MESH → BOTH
	elif _hand_mesh_visible and _real_arms_visible:
		_hand_mesh_visible = false           # BOTH → REAL only
	else:
		_hand_mesh_visible = true             # REAL (or empty) → MESH only
		_real_arms_visible = false
	_apply_hand_visibility()

# Apply current hand visibility; invariant: at least one of {mesh hands, real arms} is always shown.
func _apply_hand_visibility() -> void:
	if not _hand_mesh_visible and not _real_arms_visible:
		_hand_mesh_visible = true
	for d in _hand_drivers:
		(d as HandMeshDriver3D).set_shown(_hand_mesh_visible)
	_write_arms_pref()

# Real (passthrough) arms preference; the Clancey engine polls user://upper_limb.txt (~0.5s) and
# applies it to SwiftUI .upperLimbVisibility live (no relaunch). Same mechanism as Cascade Countdown.
func _write_arms_pref() -> void:
	var f := FileAccess.open("user://upper_limb.txt", FileAccess.WRITE)
	if f:
		f.store_string("visible" if _real_arms_visible else "hidden")
		f.close()

# Floating gaze-dwell control panel: look at a button for DWELL_SEC and it fires (a filling
# cyan tint shows progress). Head-only — works on device with no hand tracking, and renders in the
# sim. The figure-facing quads sit to the lower-left so they don't occlude the figure.
func _build_panel() -> void:
	_cam = get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
	if _panel:
		_panel.queue_free()
	_buttons.clear()
	# The panel is itself a grabbable body (a one-hand pinch moves it; two hands scale/turntable it).
	# Its gaze/poke buttons are Area3D children on GAZE_LAYER, so they ride along and keep working
	# after a grab. freeze_on_release → it stays where placed. Plate quad is the only direct
	# MeshInstance3D child, so it's the only thing the grab outline overlay tints.
	var pbody := PickupAbleBody3D.new()
	pbody.name = "ControlPanel"
	pbody.collision_layer = GRAB_LAYER
	pbody.collision_mask = 0
	pbody.freeze = true
	pbody.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	pbody.freeze_on_release = true
	_panel = pbody
	add_child(_panel)
	# Panel MIDDLE at the viewer's eye height (cam Y) + the cfg Y offset.
	_panel.position = Vector3(_s_px, (_cam.global_position.y if _cam else 1.5) + _s_py, _s_pz)
	var defs := [["GUY / GAL", "char"], ["BIGGER", "up"], ["SMALLER", "down"], ["SHADOW", "shadow"], ["HANDS", "hands"]]
	var plate := MeshInstance3D.new()
	var pm := QuadMesh.new()
	pm.size = Vector2(BTN_W + 0.05, (BTN_H + BTN_GAP) * defs.size() + 0.05)
	plate.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.02, 0.03, 0.05, 0.5)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate.material_override = pmat
	plate.position = Vector3(0, 0, -0.01)
	_panel.add_child(plate)
	# Grab collider: a thin box covering the plate face (a pinch within detect_range of it grabs the
	# panel). On GRAB_LAYER, so it's invisible to the GAZE_LAYER gaze ray and never blocks dwell.
	var grab_cs := CollisionShape3D.new()
	grab_cs.name = "CollisionShape3D"
	var grab_box := BoxShape3D.new()
	grab_box.size = Vector3(pm.size.x + 0.02, pm.size.y + 0.02, 0.06)
	grab_cs.shape = grab_box
	grab_cs.position = Vector3(0.0, 0.0, 0.0)
	_panel.add_child(grab_cs)
	var y := (defs.size() - 1) * (BTN_H + BTN_GAP) * 0.5
	for d in defs:
		_buttons.append(_make_button(d[0], d[1], Vector3(0.0, y, 0.0)))
		y -= (BTN_H + BTN_GAP)

func _make_button(text: String, action: String, local_pos: Vector3) -> Dictionary:
	var area := Area3D.new()
	area.collision_layer = GAZE_LAYER
	area.collision_mask = 0
	area.position = local_pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BTN_W, BTN_H, 0.04)
	cs.shape = box
	area.add_child(cs)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(BTN_W, BTN_H)
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BTN_IDLE
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material_override = mat
	area.add_child(quad)
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 64
	lbl.pixel_size = 0.0011
	lbl.modulate = Color.WHITE
	lbl.outline_size = 10
	lbl.position = Vector3(0, 0, 0.02)
	area.add_child(lbl)
	_panel.add_child(area)
	return {"area": area, "mat": mat, "action": action, "dwell": 0.0}

# Gaze raycast from the XRCamera; dwell on a button to fire it.
func _update_gaze(delta: float) -> void:
	if _panel == null or _cam == null or _buttons.is_empty() or _busy:
		return
	if _cooldown > 0.0:
		_cooldown -= delta
	# Direct touch (poke): a fingertip inside a button's face fires it instantly. Additive to the
	# gaze-dwell — active only when hand tracking has data (otherwise gaze alone still works).
	if TOUCH_ENABLED and _cooldown <= 0.0:
		for side in ["left_hand", "right_hand"]:
			var tip = _index_tip_world(side)
			if tip == null:
				continue
			var lp: Vector3 = _panel.to_local(tip)
			for b in _buttons:
				var bp: Vector3 = (b["area"] as Area3D).position
				if absf(lp.x - bp.x) < BTN_W * 0.5 and absf(lp.y - bp.y) < BTN_H * 0.5 and absf(lp.z - bp.z) < 0.04:
					_cooldown = 0.7
					(b["mat"] as StandardMaterial3D).albedo_color = BTN_HOT
					_activate(b["action"])
					return
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * 3.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.collision_mask = GAZE_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var focused = hit.get("collider") if hit else null
	for b in _buttons:
		var mat: StandardMaterial3D = b["mat"]
		if b["area"] == focused and _cooldown <= 0.0:
			b["dwell"] = float(b["dwell"]) + delta
			if b["dwell"] >= DWELL_SEC:
				b["dwell"] = 0.0
				_cooldown = 0.7
				mat.albedo_color = BTN_IDLE
				_activate(b["action"])
				return
		else:
			# Decay slower than it builds so head micro-jitter (a 1-frame ray miss) doesn't reset
			# progress — a steady gaze still completes; a glance-away still cancels.
			b["dwell"] = maxf(0.0, float(b["dwell"]) - delta * 0.7)
		mat.albedo_color = BTN_IDLE.lerp(BTN_HOT, clampf(float(b["dwell"]) / DWELL_SEC, 0.0, 1.0))

# Index fingertip in WORLD space (tracking-space joint through XROrigin) — for "poke" touch input.
# Lifted from Cascade's _index_tip_world. Returns null when hand tracking has no data.
func _index_tip_world(side: String):
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		return null
	var idx := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	if not (int(ht.get_hand_joint_flags(idx)) & 8):   # HAND_JOINT_FLAG_POSITION_TRACKED
		return null
	var origin := get_node_or_null("XROrigin3D") as Node3D
	if origin == null:
		return null
	return origin.global_transform * ht.get_hand_joint_transform(idx).origin

# --- live settings ------------------------------------------------------------
# Read user://mh_settings.cfg into _s_*. Returns true if any value changed since last read.
func _load_settings() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) != OK:
		return false   # no file yet → keep defaults
	var c := str(cfg.get_value("mh", "character", _s_char))
	var sc := float(cfg.get_value("mh", "scale", _s_scale))
	var sh := str(cfg.get_value("mh", "shadow", _s_shadow))
	var fr := float(cfg.get_value("mh", "front", _s_front))
	var hi := float(cfg.get_value("mh", "height", _s_height))
	var px := float(cfg.get_value("mh", "panel_x", _s_px))
	var py := float(cfg.get_value("mh", "panel_y", _s_py))
	var pz := float(cfg.get_value("mh", "panel_z", _s_pz))
	sc = clampf(sc, 0.2, 4.0)
	fr = clampf(fr, 0.3, 5.0)
	var changed := (c != _s_char) or (not is_equal_approx(sc, _s_scale)) or (sh != _s_shadow) \
		or (not is_equal_approx(fr, _s_front)) or (not is_equal_approx(hi, _s_height)) \
		or (not is_equal_approx(px, _s_px)) or (not is_equal_approx(py, _s_py)) or (not is_equal_approx(pz, _s_pz))
	_s_char = c
	_s_scale = sc
	_s_shadow = sh
	_s_front = fr
	_s_height = hi
	_s_px = px
	_s_py = py
	_s_pz = pz
	return changed

# Persist current settings (so the in-world panel and external writers share one source of truth).
func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("mh", "character", _s_char)
	cfg.set_value("mh", "scale", _s_scale)
	cfg.set_value("mh", "shadow", _s_shadow)
	cfg.set_value("mh", "front", _s_front)
	cfg.set_value("mh", "height", _s_height)
	cfg.set_value("mh", "panel_x", _s_px)
	cfg.set_value("mh", "panel_y", _s_py)
	cfg.set_value("mh", "panel_z", _s_pz)
	cfg.save(SETTINGS)

# Poll the cfg; apply diffs live. Character change → full reload (cheap re-instance); the rest are
# cheap in-place updates.
func _poll_settings() -> void:
	if _busy:
		return
	var prev_char := _s_char
	var changed := _load_settings()
	if changed and _s_char != prev_char:
		_reload_character()
		return
	# External cfg edits re-apply scale/placement — but NOT once the figure is under a manual grab
	# (don't fight the user's pinch). The in-world BIGGER/SMALLER buttons go through ui_bump_scale,
	# which still scales the grabbed body in place; only the auto re-anchor is suppressed.
	if changed and not _rel_grabbed:
		_apply_scale()
		_position_character()
		_dump_meshes()
	# Enforce every poll: release.gd re-creates its rig's shadows + re-asserts groom visibility, so
	# keep shadows off (or our one directional) and the hair backing hidden. Eye-height anchoring is
	# NOT done here — only on boot + crown-recenter (see _on_recenter) — so the figure and panel don't
	# drift with normal head motion.
	_apply_shadow()
	_tame_hair_backing()

# Swap guy↔gal by re-instancing the release tool with the new RELEASE_CHAR (bulletproof — reuses the
# whole boot path: convert/position/scale/hide). Costs a GLB reload (~1-2 s) but never half-applies.
func _reload_character() -> void:
	if _busy:
		return
	_busy = true
	print("[visionos-xr] reloading character -> ", _s_char)
	if _rel:
		_rel.queue_free()
		_rel = null
		await get_tree().process_frame
	OS.set_environment("RELEASE_CHAR", _s_char)
	_swapped = 0
	_load_character()
	await _setup_loaded_character()
	_apply_shadow()
	_dump_meshes()
	_busy = false

func _process(delta: float) -> void:
	_frames += 1
	_update_gaze(delta)
	_update_two_hand_scale()   # both hands pinch a grabbed body → scale + yaw-rotate it
	_latch_grab_flags()        # mark the figure as manually controlled (stops auto re-anchoring)
	# settings poll
	_poll_t += delta
	if _poll_t >= POLL_DT:
		_poll_t = 0.0
		_poll_settings()
	# liveness + grab telemetry (bounded — device stdout isn't captured; this file is the channel)
	if _samples < 30:
		_diag_t += delta
		if _diag_t >= 3.0:
			_diag_t = 0.0
			_samples += 1
			var f := FileAccess.open(FRAMES, FileAccess.READ_WRITE)
			if f == null:
				f = FileAccess.open(FRAMES, FileAccess.WRITE)
			if f:
				f.seek_end()
				f.store_string("sample %d: frames=%d char=%s xr_ok=%s  %s\n" \
					% [_samples, _frames, _s_char, _xr_ok, _grab_state_str()])
				f.close()

# --- pinch-and-drag manipulation (ported from Cascade Countdown main_v2.gd) ----

# Latch "the user has taken manual control" the first time each body is picked up. Once latched the
# figure is never auto-re-anchored again (see _position_character) — it stays wherever it's left.
func _latch_grab_flags() -> void:
	if not _rel_grabbed and _rel_body != null and _rel_body.is_picked_up():
		_rel_grabbed = true
		_grab_log("figure grabbed (one-hand)")
	if not _panel_grabbed and _panel != null and _panel.has_method("is_picked_up") and _panel.is_picked_up():
		_panel_grabbed = true
		_grab_log("panel grabbed (one-hand)")

# Thumb–index TIP midpoint in TRACKING space (XROrigin-relative) with pinch hysteresis, or null —
# drives the two-hand scale/turntable. Joint ints are raw OpenXR (5=thumb tip, 10=index tip,
# 15/20/25=middle/ring/pinky tip); the enum NAMES differ between the 4.6.3 editor and 4.6.2 runtime,
# so never use them. Only VALID (not TRACKED) is required so close-together hands holding through
# mutual occlusion don't tear the gesture down. Verbatim from Cascade's _index_pinch_point.
func _index_pinch_point(side: String):
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	if ht == null or not ht.get_has_tracking_data():
		_index_pinch_state[side] = false
		return null
	if not ((int(ht.get_hand_joint_flags(5)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) and (int(ht.get_hand_joint_flags(10)) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)):
		_index_pinch_state[side] = false
		return null
	var thumb := ht.get_hand_joint_transform(5).origin
	var index := ht.get_hand_joint_transform(10).origin
	var d_index := index.distance_to(thumb)
	var was: bool = _index_pinch_state[side]
	var active: bool
	if was:
		active = d_index < PINCH_END                       # stay pinched until it clearly opens
	else:
		var d_mid := ht.get_hand_joint_transform(15).origin.distance_to(thumb)
		var d_ring := ht.get_hand_joint_transform(20).origin.distance_to(thumb)
		var d_pinky := ht.get_hand_joint_transform(25).origin.distance_to(thumb)
		var index_closest := d_index <= d_mid and d_index <= d_ring and d_index <= d_pinky
		active = index_closest and d_index < PINCH_START   # to BEGIN: index closest + within start dist
	_index_pinch_state[side] = active
	if not active:
		return null
	return (index + thumb) * 0.5

# Two-hand "glued pinch": one hand holds a body (its PickupHandler latched it), the other pinches near
# it → SCALE by the inter-hand distance ratio + TURNTABLE-ROTATE by the inter-hand vector's yaw delta.
# Rotation is CONSTRAINED TO YAW (Y) only — pitch/roll are discarded so the figure/panel never tips.
# (Cascade applies the full Quaternion(v0,v1); here we take only the XZ-plane angle delta.) Smoothing
# + spike-reject are Cascade's. The world/handle case is dropped (no scene handle here).
func _update_two_hand_scale() -> void:
	var pL = _index_pinch_point("left_hand")     # tracking space
	var pR = _index_pinch_point("right_hand")
	if pL == null or pR == null:
		# Debounce: a 1-frame pinch dropout shouldn't tear down a live gesture.
		if _scale_active:
			_scale_lost_frames += 1
			if _scale_lost_frames < SCALE_END_GRACE:
				return
		_end_scale()
		return
	_scale_lost_frames = 0
	var origin := get_node_or_null("XROrigin3D") as Node3D
	if origin == null:
		return
	var PA: Vector3 = origin.global_transform * (pL as Vector3)   # current world pinch L
	var PB: Vector3 = origin.global_transform * (pR as Vector3)   # current world pinch R

	# --- Engage: one hand must already HOLD a body, and the other pinch must be near it. ---
	if not _scale_active:
		var lh = _hand_handlers.get("left_hand")
		var rh = _hand_handlers.get("right_hand")
		var cand: Node3D = null
		var free_pt := Vector3.ZERO
		if lh != null and lh.picked_up_body != null:
			cand = lh.picked_up_body
			free_pt = PB          # left holds → right is the free pinch
		elif rh != null and rh.picked_up_body != null:
			cand = rh.picked_up_body
			free_pt = PA          # right holds → left is the free pinch
		if cand == null:
			return
		if free_pt.distance_to(_grab_center(cand)) > _grab_reach(cand):
			return
		_scale_active = true
		_scale_target = cand
		_scale_A0 = PA
		_scale_B0 = PB
		_scale_T0 = cand.global_transform
		_scale_filt_ready = false
		if cand.has_method("set_two_hand"):
			cand.set_two_hand(true)
		if cand == _rel_body:
			_rel_grabbed = true
		_grab_log("two-hand engage: %s" % cand.name)

	# --- Apply (yaw-only rotation). ---
	if not is_instance_valid(_scale_target):
		_end_scale()
		return
	var v0: Vector3 = _scale_B0 - _scale_A0
	var v1: Vector3 = PB - PA
	if v0.length() < 0.001 or v1.length() < 0.001:
		return
	var s: float = clampf(v1.length() / v0.length(), SCALE_MIN, SCALE_MAX)
	# TURNTABLE: yaw = angle of the inter-hand vector in the XZ plane; rotate about world Y by the
	# delta. Discards pitch/roll entirely (no Quaternion(v0,v1) tip-over). Same convention for both
	# angles ⇒ the figure turns the same direction the hands swing.
	var yaw0 := atan2(v0.x, v0.z)
	var yaw1 := atan2(v1.x, v1.z)
	var rot := Basis(Vector3.UP, yaw1 - yaw0)
	var lin := rot * s
	var raw_origin: Vector3 = PA + lin * (_scale_T0.origin - _scale_A0)
	var raw_basis: Basis = lin * _scale_T0.basis
	# Spike-reject + smooth (the raw path amplifies pinch jitter by the scale factor).
	if not _scale_filt_ready:
		_scale_filt_origin = raw_origin
		_scale_filt_basis = raw_basis
		_scale_filt_ready = true
	else:
		var step: Vector3 = raw_origin - _scale_filt_origin
		if step.length() > SCALE_MAX_ORIGIN_STEP:
			raw_origin = _scale_filt_origin + step.normalized() * SCALE_MAX_ORIGIN_STEP
		_scale_filt_origin = _scale_filt_origin.lerp(raw_origin, SCALE_FOLLOW_ALPHA)
		# Basis carries scale, so ease componentwise (slerp is rotation-only).
		_scale_filt_basis = Basis(
			_scale_filt_basis.x.lerp(raw_basis.x, SCALE_FOLLOW_ALPHA),
			_scale_filt_basis.y.lerp(raw_basis.y, SCALE_FOLLOW_ALPHA),
			_scale_filt_basis.z.lerp(raw_basis.z, SCALE_FOLLOW_ALPHA))
	_scale_target.global_transform = Transform3D(_scale_filt_basis, _scale_filt_origin)

# End the two-hand gesture: release the body so EITHER hand can re-grab it, restore its collision, and
# (for the figure) sync _s_scale to the new size so the BIGGER/SMALLER buttons continue smoothly.
func _end_scale() -> void:
	if _scale_active and _scale_target != null and is_instance_valid(_scale_target):
		if _scale_target.has_method("set_two_hand"):
			_scale_target.set_two_hand(false)
		for side in ["left_hand", "right_hand"]:
			var h = _hand_handlers.get(side)
			if h != null and h.picked_up_body == _scale_target:
				h.picked_up_body = null
				h.was_pickup_pressed = true   # require a fresh pinch edge before re-grab
		if _scale_target.has_method("let_go"):
			_scale_target.let_go()
		if _scale_target == _rel_body:
			_s_scale = clampf(_rel_body.scale.x, 0.2, 4.0)
			_save_settings()
		_grab_log("two-hand end: %s scale=%.2f" % [_scale_target.name, _scale_target.scale.x])
	_scale_active = false
	_scale_target = null
	_scale_lost_frames = 0

# First CollisionShape3D child of a grab body (used to size the "free pinch near it" engage test).
func _first_collision_shape(body: Node) -> CollisionShape3D:
	for c in body.get_children():
		if c is CollisionShape3D:
			return c as CollisionShape3D
	return null

# World-space CENTRE of a grab body's collider (NOT its origin — the figure's origin is at the feet).
func _grab_center(body: Node3D) -> Vector3:
	var cs := _first_collision_shape(body)
	if cs != null:
		return cs.global_position
	return body.global_position

# World-space grab radius of a body, from its collider extent × world scale + grace.
func _grab_reach(body: Node3D) -> float:
	var r := 0.3
	var cs := _first_collision_shape(body)
	if cs != null and cs.shape != null:
		var sh := cs.shape
		if sh is CapsuleShape3D:
			r = maxf((sh as CapsuleShape3D).height * 0.5, (sh as CapsuleShape3D).radius)
		elif sh is BoxShape3D:
			r = (sh as BoxShape3D).size.length() * 0.5
		elif sh is SphereShape3D:
			r = (sh as SphereShape3D).radius
	return r * maxf(body.scale.x, 0.2) + 0.15

# --- grab telemetry (device has no stdout; pull user://mh_frames.txt) ----------
func _has_hand_tracker(side: String) -> bool:
	var tname := "/user/hand_tracker/" + ("left" if side == "left_hand" else "right")
	var ht := XRServer.get_tracker(tname) as XRHandTracker
	return ht != null and ht.get_has_tracking_data()

func _held_name(h) -> String:
	if h != null and h.picked_up_body != null:
		return String(h.picked_up_body.name)
	return "-"

func _grab_state_str() -> String:
	var lh = _hand_handlers.get("left_hand")
	var rh = _hand_handlers.get("right_hand")
	var tgt := String(_scale_target.name) if _scale_target != null else "-"
	return "grab L[trk=%s held=%s] R[trk=%s held=%s] scale=%s tgt=%s relG=%s panelG=%s" % [
		_has_hand_tracker("left_hand"), _held_name(lh),
		_has_hand_tracker("right_hand"), _held_name(rh),
		_scale_active, tgt, _rel_grabbed, _panel_grabbed]

# Bounded append to the telemetry file so an event log can't grow without limit on a long session.
func _grab_log(msg: String) -> void:
	if _grab_log_count >= 80:
		return
	_grab_log_count += 1
	var f := FileAccess.open(FRAMES, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(FRAMES, FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string("[grab] %s\n" % msg)
		f.close()
