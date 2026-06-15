extends Node3D
# visionOS XR harness for the MetaHumanGodot release tool — Godot's OWN renderer via
# Apple's CompositorServices fork (rsanchezsaez/Clancey, PR #109975). NOT godotrealitykit.
# ─────────────────────────────────────────────────────────────────────────────
# PIVOT (alex-mbp, 2026-06-15). The earlier godotrealitykit (RealityKit-renders) spike proved
# RealityKit renders the MetaHuman at BIND POSE and does not apply the skeletal skinning
# (43 blendshapes, 874 face bones, leader-pose) — so the skinned face/body/eyes collapse to a
# point at the origin and only the bone-attached grooms survive. There is no plugin knob to fix
# it. Godot's OWN renderer (this path) skins MetaHumans natively — the desktop release tool does
# it daily — AND runs in the visionOS Simulator + on device (Cascade Countdown is existence-proof).
# See KB: projects/metahuman-godot-pipeline/visionos-port.md.
#
# Sibling to scenes/vr.gd (Quest standalone, OpenXR). Where vr.gd targets Quest (OpenXR +
# Mobile/Vulkan), THIS targets the visionOS XR interface (XRServer.find_interface("visionOS"),
# Mobile/Metal, immersive via CompositorServices).
#
# Why the StandardMaterial3D swap is STILL needed (same as Quest): the release tool's skin/eye/
# hair MatMADNESS shaders are custom GLSL `light()` shaders. They do not compile on the visionOS
# Mobile/Metal renderer (the same wall as Quest's Adreno). The _to_standard()/_coverage_to_alpha()
# conversion below is lifted verbatim from scenes/vr.gd so the look matches the shipped Quest
# result; unify into a shared helper once this graduates. Quest code is deliberately untouched.
#
# REQUIRED scene/project settings for this path (see godot-visionos-xr.md "Confirmed-working
# recipe"): XROrigin3D.current=true, XRCamera3D.near>=0.1, WorldEnvironment bg alpha 0,
# rendering_method="mobile", [xr] shaders/enabled=true. The silent-failure killer is
# XROrigin3D.current — without it XR inits, the loop runs at 90fps, but frames are empty.
#
# Run modes:
#   • visionOS Simulator / device (CompositorServices): the visionOS XR interface initializes,
#     the viewport goes use_xr + VRS_XR, and this scene renders immersively. Validate in the sim
#     first (build.sh sim), then device (build.sh device).
#   • Desktop fallback (plain Godot, no visionOS interface): a flat Camera3D frames the bust so a
#     headless/editor run still shows the swapped character for a quick sanity capture.

var _rel: Node3D
const DBG_BLOB := false     # parity with vr.gd; never tint in the visionOS path
# File-based diagnostics. Godot print() on the visionOS fork does NOT reach simctl's captured
# stdout, so the verification artifacts are written into the app data container (user:// maps to
# Documents/) and pulled with `xcrun simctl get_app_container <udid> <bundle> data`. Matches the
# KB recipe (godot-visionos-xr.md "Diagnostic GDScript pattern").
const DIAG := "user://mh_diag.txt"       # one-shot mesh dump + skinning verdict (written in _boot)
const FRAMES := "user://mh_frames.txt"   # liveness samples (proves the 90 fps loop runs)
var _xr_ok := false
var _swapped := 0
var _frames := 0
var _samples := 0
var _diag_t := 0.0

func _ready() -> void:
	# Load the guy by default (character.glb). release.gd reads RELEASE_CHAR (see vr.gd BOOT_AS_HER).
	if not OS.has_environment("RELEASE_CHAR"):
		OS.set_environment("RELEASE_CHAR", "guy")
	_init_visionos_xr()
	call_deferred("_boot")

# Initialize the visionOS XR interface and route the viewport through it. Per the canonical
# rsanchezsaez demo: find the interface, initialize(), then use_xr=true + vrs_mode=VRS_XR.
# VRS_XR is REQUIRED for the layered compositor to produce output; XROrigin3D.current=true (set
# in the .tscn AND re-asserted here) is the #1 silent-failure cause if missing.
func _init_visionos_xr() -> void:
	var interface := XRServer.find_interface("visionOS")
	if interface and interface.initialize():
		var vp := get_viewport()
		vp.use_xr = true
		vp.vrs_mode = Viewport.VRS_XR
		var origin := get_node_or_null("XROrigin3D") as XROrigin3D
		if origin:
			origin.current = true
		_xr_ok = true
		print("[visionos-xr] visionOS XR interface initialized — use_xr + VRS_XR; origin current")
	else:
		# Not on visionOS (or interface unavailable): flat camera so a desktop/headless run shows
		# the swapped bust. Framed by _position_character() once the character is loaded.
		push_warning("[visionos-xr] visionOS interface unavailable — desktop flat-camera fallback")
		var cam := Camera3D.new()
		cam.name = "FlatFallbackCamera"
		cam.near = 0.05
		cam.far = 100.0
		cam.current = true
		add_child(cam)

func _boot() -> void:
	await get_tree().process_frame
	_load_character()
	# release.gd wires the custom GLSL ShaderMaterials synchronously in its _ready (during
	# add_child). Convert them before the first rendered frame. Grooms attach to the head bone a
	# few frames later, so run a second pass (same two-pass timing as vr.gd).
	_convert_materials()
	await get_tree().process_frame
	await get_tree().process_frame
	_convert_materials()
	_hide_release_ui()
	_disable_release_cameras()
	_quiet_demo()
	_position_character()
	_dump_meshes()
	print("[visionos-xr] ready — release tool instanced, materials -> StandardMaterial3D, character placed")

# Diagnostic: what meshes exist, are they skinned/blendshaped, where are they, how is the
# material attached (override vs surface)? Under Godot's own renderer the skinned face/body/eyes
# MUST now have real, head-height world AABBs (skinning applied) — NOT points at the origin (which
# is the godotrealitykit bind-pose failure signature). Verify that before trusting any screenshot.
func _dump_meshes() -> void:
	if _rel == null:
		return
	var lines: Array[String] = []
	lines.append("=== MetaHuman visionOS XR diag — Godot's OWN renderer (CompositorServices) ===")
	lines.append("xr_interface_ok=%s  materials_swapped=%d  character_pos=%s" % [_xr_ok, _swapped, str(_rel.position)])
	lines.append("PASS = skin/face/body meshes have real, HEAD-HEIGHT world AABBs (skinning applied).")
	lines.append("FAIL (godotrealitykit signature) = those meshes are point-sized AABBs at the origin.")
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
		print("[visionos-xr] wrote ", lines.size(), " diag lines -> ", DIAG)

# Liveness sample: confirms the game loop actually runs (≈90 fps under the compositor → frames
# accumulate). Written to the app container so it survives the (uncaptured) stdout. Stops after a
# handful of samples to keep the file bounded. Distinguishes "scene loaded + skinned but not
# presenting" from "engine hung / not running".
func _process(delta: float) -> void:
	_frames += 1
	if _samples >= 6:
		return
	_diag_t += delta
	if _diag_t >= 3.0:
		_diag_t = 0.0
		_samples += 1
		var f := FileAccess.open(FRAMES, FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open(FRAMES, FileAccess.WRITE)
		if f:
			f.seek_end()
			f.store_string("sample %d: frames=%d xr_ok=%s\n" % [_samples, _frames, _xr_ok])
			f.close()

func _load_character() -> void:
	var ps := load("res://scenes/release.tscn") as PackedScene
	_rel = ps.instantiate() as Node3D
	add_child(_rel)

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
		st.roughness = 0.9
		st.metallic_specular = 0.1
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
	var cap := 768
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

# release.gd creates its own Camera3D with current=true (look-dev framing). In XR that camera
# would compete with the XRCamera3D for the viewport — disable every camera under the release
# tool so the XRCamera (or the desktop flat fallback) is the only active one.
func _disable_release_cameras() -> void:
	if _rel == null:
		return
	for c in _rel.find_children("*", "Camera3D", true, false):
		(c as Camera3D).current = false

# Start a calm idle (face + body) but keep the per-frame hue-cycle lighting OFF (it re-renders
# shadow maps every frame — needless cost, same call vr.gd makes on Android).
func _quiet_demo() -> void:
	if _rel == null:
		return
	if _rel.has_method("_set_body_anim"):
		_rel.call("_set_body_anim", true)
	if _rel.has_method("_set_face_anim"):
		_rel.call("_set_face_anim", true)
	if _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", false)

# Place the character so its (skinned) head sits ~0.9 m in front of the user at a comfortable
# eye line. Under Godot's OWN renderer the skeleton skins the meshes, so the head AABB is real
# and head-height (unlike godotrealitykit, where the unskinned face collapsed to the origin).
# In immersive XR the XROrigin3D is the floor and the XRCamera3D tracks the user's real head, so
# we push the character back along -Z and lift it so the head lands ~1.5 m. Tunable via env:
# MH_FRONT (forward distance, default 0.90) and MH_HEAD_Y (target head height, default 1.50).
func _position_character() -> void:
	if _rel == null:
		return
	var head := _character_head_y()
	# Clamp out a stray backdrop/floor AABB (same guard vr.gd uses): fall back to a human head.
	if head < 0.5 or head > 3.0:
		head = 1.65
	var front := 0.90
	if OS.has_environment("MH_FRONT"):
		front = float(OS.get_environment("MH_FRONT"))
	var target_head_y := 1.50
	if OS.has_environment("MH_HEAD_Y"):
		target_head_y = float(OS.get_environment("MH_HEAD_Y"))
	_rel.position = Vector3(0.0, target_head_y - head, -front)
	print("[visionos-xr] character placed: local head_y=%.2f -> world head ~(0, %.2f, %.2f)" \
		% [head, target_head_y, -front])

func _character_head_y() -> float:
	if _rel == null:
		return 1.5
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
		return 1.5
	return aabb.end.y - 0.18
