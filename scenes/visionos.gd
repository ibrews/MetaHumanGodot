extends Node3D
# visionOS / godotrealitykit harness for the MetaHumanGodot release tool.
# ─────────────────────────────────────────────────────────────────────────────
# SCOPING SPIKE (alex-mbp, 2026-06-14). Sibling to scenes/vr.gd (Quest standalone).
# Where vr.gd targets Quest (OpenXR + Mobile/Vulkan, custom→StandardMaterial3D swap
# gated to Android), THIS targets Apple's godotrealitykit plugin, where RealityKit
# renders the Godot scene (App Role = Window → a volumetric window, "bust on a plinth").
#
# Why the same StandardMaterial3D swap is needed here as on Quest:
#   godotrealitykit's renderer supports PBR materials (StandardMaterial3D) and Visual
#   Shaders, but NOT Godot GLSL text shaders (documentation/Rendering.md: "GLSL shaders ◻").
#   The release tool's skin/eye/hair MatMADNESS shaders are GLSL `light()` shaders — exactly
#   the ones the Adreno/Mobile renderer also can't compile. So the conversion that makes the
#   MetaHuman work on Quest is the SAME bridge that makes it render under RealityKit.
#
# The _to_standard()/_coverage_to_alpha() conversion below is lifted verbatim from
# scenes/vr.gd so the look matches the shipped Quest result. The two should be unified into a
# shared helper once this path graduates from a spike. Quest code is deliberately untouched.
#
# Run modes:
#   • godotrealitykit macOS debug render (reality_kit/debug_rendering_on_macos=true): RealityKit
#     renders this scene inside a macOS window — no device/sim needed. Primary spike proof.
#   • visionOS export, App Role = Window: builds an Xcode project → physical Apple Vision Pro.
#     (The visionOS *Simulator* cannot host this — godotrealitykit ships a device-only template
#     slice; see the KB doc projects/metahuman-godot-pipeline/visionos-port.md.)
#   • Flat fallback (no godotrealitykit, plain Godot on macOS): set VISIONOS_FLAT=1 to render
#     the swapped character with a normal Camera3D for a quick desktop sanity capture.

var _rel: Node3D
var _vol: Node3D            # RealityVolumeCamera3D (godotrealitykit) if present in the scene
const DBG_BLOB := false     # parity with vr.gd; never tint in the visionOS path

func _ready() -> void:
	# Load the guy by default (character.glb). release.gd reads RELEASE_CHAR (see vr.gd BOOT_AS_HER).
	if not OS.has_environment("RELEASE_CHAR"):
		OS.set_environment("RELEASE_CHAR", "guy")
	_vol = get_node_or_null("RealityVolumeCamera3D")
	call_deferred("_boot")

func _boot() -> void:
	await get_tree().process_frame
	_load_character()
	# release.gd wires the custom GLSL ShaderMaterials synchronously in its _ready (during
	# add_child). Convert them before RealityKit mirrors the scene. Grooms attach to the head
	# bone a few frames later, so run a second pass (same two-pass timing as vr.gd).
	_convert_materials()
	await get_tree().process_frame
	await get_tree().process_frame
	_convert_materials()
	_hide_release_ui()
	_quiet_demo()
	_frame_volume_on_character()
	print("[visionos] ready — release tool instanced, materials -> StandardMaterial3D, volume framed")

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

# Hide the desktop look-dev 2D UI (sliders/panels) — not wanted in the volume.
func _hide_release_ui() -> void:
	if _rel == null:
		return
	for cl in _rel.find_children("*", "CanvasLayer", true):
		(cl as CanvasLayer).visible = false
	for c in _rel.find_children("*", "Control", true):
		(c as CanvasItem).visible = false

# Start a calm idle (face + body) but keep the per-frame hue-cycle lighting OFF (it re-renders
# shadow maps every frame — needless cost under RealityKit, same call vr.gd makes on Android).
func _quiet_demo() -> void:
	if _rel == null:
		return
	if _rel.has_method("_set_body_anim"):
		_rel.call("_set_body_anim", true)
	if _rel.has_method("_set_face_anim"):
		_rel.call("_set_face_anim", true)
	if _rel.has_method("_set_color_cycle"):
		_rel.call("_set_color_cycle", false)

# Size + center the RealityVolumeCamera3D on the character's head so the volume shows a
# head-and-shoulders bust. The volume + the RealityKit shadow node are created from script (only
# when the godotrealitykit extension is loaded) so the .tscn stays vanilla and imports even in
# plain Godot. Falls back to a flat Camera3D framing if VISIONOS_FLAT=1.
func _frame_volume_on_character() -> void:
	var head := _character_head_y()
	# Clamp out the backdrop/floor: the owned=false AABB scan catches the huge studio cyc mesh
	# (head_y read ~26 m), so fall back to a sane human head height when it's out of range
	# (same guard vr.gd uses in _frame_to_character).
	if head < 0.5 or head > 3.0:
		head = 1.65
	# Center the volume on the face (~just below eye line) for a head-and-shoulders bust.
	var center := Vector3(0, head - 0.10, 0)
	# Create the RealityVolumeCamera3D if the extension class exists and none is in the scene.
	if _vol == null and ClassDB.class_exists("RealityVolumeCamera3D"):
		_vol = ClassDB.instantiate("RealityVolumeCamera3D")
		_vol.name = "RealityVolumeCamera3D"
		add_child(_vol)
	# Preview cam for the macOS debug render / editor (guard: the volume may auto-create one).
	if _vol and _vol.get_node_or_null("PreviewCamera") == null:
		var prev := Camera3D.new()
		prev.name = "PreviewCamera"
		prev.near = 0.05
		_vol.add_child(prev)
		prev.global_position = center + Vector3(0, 0.02, 1.05)
		prev.look_at(center, Vector3.UP)
	# Attach a RealityKit shadow node to the first DirectionalLight3D (godotrealitykit shadows).
	if ClassDB.class_exists("RealityKitDirectionalLightShadow3D"):
		var dl := get_node_or_null("DirectionalLight3D")
		if dl and dl.get_node_or_null("RealityKitDirectionalLightShadow3D") == null:
			var sh = ClassDB.instantiate("RealityKitDirectionalLightShadow3D")
			sh.name = "RealityKitDirectionalLightShadow3D"
			dl.add_child(sh)
	if _vol:
		_vol.global_position = center
		if "size" in _vol:
			_vol.set("size", 1.4)   # ~1.4 m volume → head + shoulders bust
		print("[visionos] volume centered at ", center, " (head y=", head, ")")
	if OS.has_environment("VISIONOS_FLAT"):
		var cam := Camera3D.new()
		cam.near = 0.05
		cam.far = 100.0
		cam.current = true
		add_child(cam)
		cam.global_position = center + Vector3(0, 0, 0.9)
		cam.look_at(center, Vector3.UP)
		print("[visionos] FLAT camera framing the bust at ", center)

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
