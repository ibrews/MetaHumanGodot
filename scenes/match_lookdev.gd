extends Node3D
## INTERACTIVE look-dev for the UE "Moonlight" match (explainer) — FULL controls.
## Same matched rig as match_ue.gd (handedness-corrected camera + ported light
## positions/rotations + eye/hair/skin shader wiring) plus a big live panel:
##   LIGHTING : per-light energy + COLOR (key / key-rect / fill / rim / ambient),
##              exposure, env-ambient, glow
##   SKIN     : MatMADNESS skin shader on face+body — SSS, skin smoothness,
##              normal strength, roughness, specular, scatter, double-spec
##   HAIR     : card colour, alpha threshold, root darkening, roughness, specular
##   EYES     : sclera tint, iris scale/radius, roughness, specular
##   SCENE    : model yaw, UE-frame-0 overlay opacity, depth nudge
##   -> Save preset writes out/explainer2/03_godot/lookdev_preset.json (I bake it
##      back into match_ue.gd for the final renders).
##
## Launch (interactive):
##   & "H:/dev/godot-stock/Godot_v4.6-stable_win64.exe" --path "H:/Work01/MetaHumanGodot/godot_project" "scenes/match_lookdev.tscn" --resolution 1280x1280
## Keys: O = toggle UE overlay, H = toggle panel, P = save preset.

const GLB_PATH := "res://character_explainer.glb"
const UE_REF := "exp_ue_ref0.png"
const PRESET_OUT := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/lookdev_preset.json"
const PRESET_DIR := "H:/Work01/MetaHumanGodot/out/explainer2/lookdev_presets"
const MOVIE_DIR := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/frames"
const OUT_MP4 := "H:/Work01/MetaHumanGodot/out/explainer2/03_godot/godot_turntable.mp4"

# all tunables (defaults mirror match_ue.gd)
var p := {
	# lighting
	"key": 9.0, "keyrect": 4.0, "fill": 2.6, "rim": 5.0, "ambient": 1.2,
	"env_amb": 0.12, "exposure": 1.0, "glow": 0.5,
	"key_col": Color(19.0/255, 46.0/255, 93.0/255),
	"keyrect_col": Color(19.0/255, 46.0/255, 93.0/255),
	"fill_col": Color(82.0/255, 93.0/255, 77.0/255),
	"rim_col": Color(93.0/255, 62.0/255, 32.0/255),
	"amb_col": Color(0.0, 24.0/255, 139.0/255),
	# skin
	"sss": 0.34, "skin_smooth": 1.2, "skin_nrm": 1.3, "skin_rough": 0.95,
	"skin_spec": 0.30, "scatter": 1.4, "double_spec": false,
	# hair
	"hair_col": Color(0.20, 0.13, 0.075), "hair_thresh": 0.13,
	"hair_root": 0.42, "hair_rough": 0.72, "hair_spec": 0.12,
	# eyes
	"sclera_tint": 0.22, "iris_scale": 1.9, "iris_radius": 0.155,
	"eye_rough": 0.03, "eye_spec": 1.0, "eye_clearcoat": 0.25,
	# colour balance (Environment adjustment)
	"saturation": 1.06, "brightness": 1.0, "contrast": 1.05,
	# scene
	"model_yaw": 272.5, "overlay": 0.0, "zoff": 0.0,
	"view_pan": -1.2,   # interactive-only camera frustum shift so she clears the left panel
	"cap_pan": -0.176,  # capture-time centering offset so she matches UE's horizontal position (0.459)
}

var _character: Node3D
var _env: Environment
var _lights := {}
var _skin_mats: Array[ShaderMaterial] = []
var _hair_mats: Array[ShaderMaterial] = []
var _hair_back_mats: Array[ShaderMaterial] = []
var _eye_mats: Array[ShaderMaterial] = []
var _hair_meshes: Array[MeshInstance3D] = []
var _overlay: TextureRect
var _panel: Control
var _camera: Camera3D
var _preset_name: LineEdit
var _preset_dd: OptionButton
var _refreshers: Array = []   # callables that re-read p into each control

var _movie := false
var _movie_total := 120
var _movie_frame := 0
var _spin_start := 0.0

const ASSEMBLE_PY := """
import cv2, os, sys, glob
d, out = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, 'f*.png')))
if not files: sys.exit(2)
img = cv2.imread(files[0]); h, w = img.shape[:2]
# H.264 (avc1) requires EVEN dimensions; the windowed capture is 1080x1061 (odd)
# which encodes to a BLACK video. Crop to even.
w -= w % 2; h -= h % 2
for cc in ('avc1','mp4v'):
    vw = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*cc), 30, (w, h))
    if vw.isOpened(): break
for f in files: vw.write(cv2.imread(f)[:h, :w])
vw.release(); print('wrote', out, w, 'x', h, len(files), 'frames')
"""

func _ready() -> void:
	_load_preset(PRESET_OUT)   # start from the last-saved look
	_setup_world(); _setup_backdrop(); _setup_lights(); _setup_camera()
	_load_character(); _setup_ui(); _apply_all()
	if OS.has_environment("MOVIE_FRAMES"):
		_movie_total = max(2, int(OS.get_environment("MOVIE_FRAMES")))
	# Headless: MATCH_CAPTURE=1 -> still (+ MATCH_MOVIETEST=1 -> 120f turntable mp4).
	if OS.has_environment("MATCH_CAPTURE"):
		if _panel: _panel.visible = false
		if _overlay: _overlay.modulate.a = 0.0
		await get_tree().create_timer(0.6).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("H:/Work01/MetaHumanGodot/out/explainer2/03_godot/lookdev_still.png")
		print("[lookdev] still saved")
		if OS.has_environment("MATCH_MOVIETEST"):
			_start_movie()
		else:
			await get_tree().create_timer(0.1).timeout
			get_tree().quit()

# ---- UE -> Godot conversion (gx=-ux handedness fix; matches match_ue.gd) -----
func _ue_pos(ux: float, uy: float, uz: float) -> Vector3:
	return Vector3(-ux / 100.0, uz / 100.0, -uy / 100.0)
func _ue_dir(ux: float, uy: float, uz: float) -> Vector3:
	return Vector3(-ux, uz, -uy).normalized()
func _ue_forward(pitch_deg: float, yaw_deg: float) -> Vector3:
	var pr := deg_to_rad(pitch_deg); var yr := deg_to_rad(yaw_deg)
	var uf := Vector3(cos(pr) * cos(yr), cos(pr) * sin(yr), sin(pr))
	return _ue_dir(uf.x, uf.y, uf.z)
func _stable_up(fwd: Vector3) -> Vector3:
	return Vector3.UP if absf(fwd.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD

func _setup_world() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	# Navy fallback so the frame reads UE-navy even where the backdrop quad doesn't
	# reach (the flat quad fell off to black on one side). Pre-comp for AgX+grade.
	_env.background_color = Color(0.050, 0.118, 0.280)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.0, 0.094, 0.545)
	_env.ambient_light_energy = p.env_amb
	# AgX: modern filmic curve (desaturated highlights, gentle rolloff) — much
	# closer to UE's look than ACES, and stops the oversaturation we were fighting.
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX
	_env.tonemap_exposure = p.exposure
	_env.glow_enabled = true
	_env.glow_intensity = p.glow
	_env.glow_bloom = 0.15
	_env.ssao_enabled = true
	_env.ssao_radius = 0.3
	_env.ssao_intensity = 0.7
	# SSIL: screen-space indirect light — the GI bounce/fill UE gets from Lumen.
	_env.ssil_enabled = true
	_env.ssil_radius = 5.0
	_env.ssil_intensity = 1.0
	_env.ssil_sharpness = 0.98
	_env.adjustment_enabled = true
	_env.adjustment_contrast = p.contrast
	_env.adjustment_saturation = p.saturation
	_env.adjustment_brightness = p.brightness
	var we := WorldEnvironment.new(); we.environment = _env; add_child(we)

func _setup_backdrop() -> void:
	var quad := QuadMesh.new(); quad.size = Vector2(26, 16)
	var mi := MeshInstance3D.new(); mi.mesh = quad; mi.position = Vector3(0, 1.4, -3.0)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
// Matched to the UE half-sphere backdrop navy (sampled sRGB ~0.03,0.12,0.27,
// a touch brighter toward the bottom). Mostly flat with a subtle AirGlow.
// Pre-compensated brighter than the raw sample because AgX + the grade darken it.
uniform vec3 top_col : source_color = vec3(0.045, 0.110, 0.260);
uniform vec3 bot_col : source_color = vec3(0.055, 0.130, 0.295);
uniform vec3 glow_col : source_color = vec3(0.05, 0.13, 0.28);
uniform float glow_amt = 0.18;
void fragment() {
	float v = clamp(UV.y, 0.0, 1.0);
	vec3 c = mix(bot_col, top_col, v);
	float gx = smoothstep(0.6, 0.0, abs(UV.x - 0.5));
	float gy = smoothstep(0.0, 0.6, UV.y) * smoothstep(1.0, 0.45, UV.y);
	c += glow_col * gx * gy * glow_amt;
	ALBEDO = c;
}
"""
	var sm := ShaderMaterial.new(); sm.shader = sh; mi.material_override = sm; add_child(mi)

func _spot(nm: String, ue_loc: Array, pitch: float, yaw: float, col: Color,
		outer_deg: float, inner_deg: float, shadow: bool) -> SpotLight3D:
	var s := SpotLight3D.new(); s.name = nm
	s.position = _ue_pos(ue_loc[0], ue_loc[1], ue_loc[2])
	var fwd := _ue_forward(pitch, yaw)
	s.look_at_from_position(s.position, s.position + fwd, _stable_up(fwd))
	s.light_color = col
	s.spot_angle = outer_deg
	s.spot_angle_attenuation = clampf(inner_deg / maxf(outer_deg, 1.0), 0.1, 1.0)
	s.spot_range = 20.0; s.spot_attenuation = 0.6
	s.shadow_enabled = shadow; s.light_specular = 0.4
	add_child(s); return s

func _setup_lights() -> void:
	_lights["key"] = _spot("KeyLight_Spot", [63.40, 67.03, 279.20], -75.27, -138.92, p.key_col, 65.0, 20.0, true)
	_lights["keyrect"] = _spot("KeyLight_Rect", [63.40, 67.03, 279.20], -75.27, -138.92, p.keyrect_col, 80.0, 50.0, false)
	_lights["fill"] = _spot("FillLight", [28.57, 111.70, 111.70], -2.20, -96.03, p.fill_col, 70.0, 40.0, false)
	_lights["rim"] = _spot("RimLight", [-136.30, -87.34, 140.94], -1.00, 34.20, p.rim_col, 80.0, 45.4, false)
	var amb := OmniLight3D.new(); amb.name = "AmbientLight"
	amb.position = _ue_pos(0.0, 0.0, 300.0)
	amb.light_color = p.amb_col
	amb.omni_range = 30.0; amb.omni_attenuation = 0.4
	add_child(amb); _lights["ambient"] = amb

func _setup_camera() -> void:
	_camera = Camera3D.new(); _camera.name = "Camera3D"
	_camera.fov = 16.0; _camera.near = 0.05; _camera.far = 100.0
	_camera.position = _ue_pos(160.0, -42.0, 158.0)
	var fwd := _ue_forward(-4.0, 165.0)
	_camera.look_at_from_position(_camera.position, _camera.position + fwd, Vector3.UP)
	# Interactive frustum pan so the subject clears the left control panel.
	# ZEROED during capture so the matched shot is pixel-identical to match_ue.
	# Interactive: view_pan (clear the panel). Capture: a small centering offset so
	# she sits centered in the square frame (the matched camera frames her a touch
	# left). CAP_H env overrides for calibration.
	if OS.has_environment("KEEP_PAN") or not OS.has_environment("MATCH_CAPTURE"):
		_camera.h_offset = p.view_pan
	else:
		_camera.h_offset = _envf("CAP_H", p.get("cap_pan", 0.0))
	_camera.current = true; add_child(_camera)

func _envf(n: String, d: float) -> float:
	return float(OS.get_environment(n)) if OS.has_environment(n) else d

func _rtex(filename: String, mip := true) -> Texture2D:
	var pa := ProjectSettings.globalize_path("res://" + filename)
	if not FileAccess.file_exists(pa): return null
	var img := Image.load_from_file(pa)
	if img == null: return null
	if mip: img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _load_character() -> void:
	var node: Node3D = null
	var abs_path := ProjectSettings.globalize_path(GLB_PATH)
	if FileAccess.file_exists(abs_path):
		var doc := GLTFDocument.new(); var st := GLTFState.new()
		if doc.append_from_file(abs_path, st) == OK:
			node = doc.generate_scene(st)
	if node == null: push_error("[lookdev] load failed"); return
	add_child(node); _character = node
	var aabb := _world_aabb(node)
	var sf: float = 1.74 / maxf(aabb.size.y, 0.0001)
	node.scale = Vector3(sf, sf, sf)
	var aabb2 := _world_aabb(node)
	node.position = Vector3(0.0, -aabb2.position.y, p.zoff)
	node.rotation.y = deg_to_rad(p.model_yaw)
	_wire_materials(node)

func _wire_materials(root: Node) -> void:
	var meshes := _find_meshes(root)
	var hair_shader: Shader = load("res://scenes/hair_card_shadow.gdshader") as Shader
	var hair_tex := _rtex("exp_hair_atlas.png")
	# hide slots
	var hide_mat := StandardMaterial3D.new()
	hide_mat.albedo_color = Color(0, 0, 0, 0)
	hide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hide_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# skin material (face) + a separate one for body (different textures)
	var face_skin := _make_skin("head")
	var body_skin := _make_skin("body")
	_skin_mats = [face_skin, body_skin]
	var eye_l := _make_eye_material("L"); var eye_r := _make_eye_material("R")
	_eye_mats = [eye_l, eye_r]
	for mi in meshes:
		# hair
		if String(mi.name).begins_with("Hair"):
			if hair_tex:
				var cm := ShaderMaterial.new(); cm.shader = hair_shader
				cm.set_shader_parameter("coverage_atlas", hair_tex)
				cm.set_shader_parameter("use_red_mask", true)
				cm.set_shader_parameter("invert_mask", false)
				_hair_mats.append(cm)
				for s in range(mi.mesh.get_surface_count()):
					mi.set_surface_override_material(s, cm)
				# cast + receive shadows (depth_prepass_alpha shader writes depth)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				_hair_meshes.append(mi)
				# Backing shell: solid hair-coloured inset mesh under the strand
				# cards so the bald scalp never shows through the gaps (fuller hair).
				var bsh: Shader = load("res://scenes/hair_backing.gdshader") as Shader
				if bsh:
					var bm := ShaderMaterial.new(); bm.shader = bsh
					bm.set_shader_parameter("coverage_atlas", hair_tex)
					bm.set_shader_parameter("use_red_mask", true)
					bm.set_shader_parameter("cutoff", 0.035)
					bm.set_shader_parameter("inset", 0.009)
					bm.set_shader_parameter("hair_color", (p.hair_col as Color).darkened(0.25))
					_hair_back_mats.append(bm)
					var backing := MeshInstance3D.new()
					backing.name = mi.name + "_Backing"
					backing.mesh = mi.mesh
					for s in range(mi.mesh.get_surface_count()):
						backing.set_surface_override_material(s, bm)
					backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					mi.add_sibling(backing)
					backing.global_transform = mi.global_transform
			continue
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		if mesh == null: continue
		var is_body := String(mi.name) == "Body" or String(mi.name).begins_with("Body")
		for s in range(mesh.get_surface_count()):
			var m: Material = mesh.surface_get_material(s)
			var nm := (m.resource_name if m else "").to_lower()
			if "eyel_baked" in nm: mi.set_surface_override_material(s, eye_l)
			elif "eyer_baked" in nm: mi.set_surface_override_material(s, eye_r)
			elif ("eyeshell" in nm or "eyelash" in nm or "lacrimal" in nm
					or nm.begins_with("m_hide") or "_hide" in nm):
				mi.set_surface_override_material(s, hide_mat)
			elif "skin" in nm:
				mi.set_surface_override_material(s, face_skin)
			elif is_body:
				mi.set_surface_override_material(s, body_skin)

func _white_tex() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color(1, 1, 1))
	return ImageTexture.create_from_image(img)

func _make_skin(which: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/skin_shader_explainer.gdshader") as Shader
	mat.set_shader_parameter("sss_depth_scale", 6.0)
	var bc := _rtex("exp_%s_bc.png" % which)
	var nn := _rtex("exp_%s_n.png" % which)
	var sr := _rtex("exp_%s_srmf.png" % which)
	var sc := _rtex("exp_%s_scatter.png" % which)
	if bc: mat.set_shader_parameter("texture_albedo", bc)
	mat.set_shader_parameter("albedo", Color(1, 1, 1, 1))
	if nn: mat.set_shader_parameter("texture_normal", nn)
	if sr: mat.set_shader_parameter("texture_roughness", sr)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("metallic_texture_channel", Plane(1, 0, 0, 0))
	mat.set_shader_parameter("use_subsurface_scattering", true)
	mat.set_shader_parameter("use_noise", false)
	mat.set_shader_parameter("old_lightwarp_fallof", false)
	mat.set_shader_parameter("skin_fallof_smoothness", 1.05)
	if sc:
		mat.set_shader_parameter("texture_scatter", sc)
		mat.set_shader_parameter("use_scatter_map", true)
	else:
		mat.set_shader_parameter("use_scatter_map", false)
	# Micro-detail is a hero-CLOSEUP feature: tiled ~10-22x it adds high-frequency
	# normal noise that, under the hard spot key, reads as all-over speckle/"freckles"
	# at this framing. Off by default here; the base T_Head_N already carries pores.
	# (MICRO env > 0 re-enables for closeups.)
	var micro := _envf("MICRO", 0.0)
	if micro > 0.0 and ResourceLoader.exists("res://skin_micro_n.png"):
		mat.set_shader_parameter("texture_micro_detail", load("res://skin_micro_n.png") as Texture2D)
		mat.set_shader_parameter("use_micro_detail", true)
		mat.set_shader_parameter("micro_detail_scale", 10.0)
		mat.set_shader_parameter("micro_normal_strength", micro)
		mat.set_shader_parameter("micro_ao_strength", 0.2)
	else:
		mat.set_shader_parameter("use_micro_detail", false)
		mat.set_shader_parameter("micro_normal_strength", 0.0)
		mat.set_shader_parameter("micro_ao_strength", 0.0)
	# CRITICAL: the shader does SSS_STRENGTH *= texture(ambient_occlusion_texture).r
	# UNCONDITIONALLY (line ~198). Binding the old generic skin_micro_cav.png there
	# (1) smeared its vein-WEB over the face and (2) — being mostly black — multiplied
	# SSS by ~0 so the SSS/scatter/smoothness knobs looked dead. Bind a flat WHITE
	# texture instead: no webbing, and SSS now scales 1:1 with the slider.
	mat.set_shader_parameter("ambient_occlusion_texture", _white_tex())
	mat.set_shader_parameter("use_ambient_occlusion", false)
	mat.set_shader_parameter("translucency", false)
	mat.set_shader_parameter("uv1_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv1_offset", Vector3(0, 0, 0))
	mat.set_shader_parameter("uv2_scale", Vector3(1, 1, 1))
	mat.set_shader_parameter("uv2_offset", Vector3(0, 0, 0))
	return mat

func _make_eye_material(side: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/eye.gdshader") as Shader
	var ib := _rtex("exp_eye_iris_%s_bc.png" % side)
	var inr := _rtex("exp_eye_iris_%s_n.png" % side)
	var sb := _rtex("exp_eye_sclera_%s_bc.png" % side)
	var sn := _rtex("exp_eye_sclera_%s_n.png" % side)
	if ib: mat.set_shader_parameter("iris_texture", ib)
	if inr: mat.set_shader_parameter("iris_normal", inr)
	if sb: mat.set_shader_parameter("sclera_texture", sb)
	if sn: mat.set_shader_parameter("sclera_normal", sn)
	mat.set_shader_parameter("blend_softness", 0.02)
	mat.set_shader_parameter("normal_strength", 0.55)
	mat.set_shader_parameter("clearcoat_val", p.eye_clearcoat)
	mat.set_shader_parameter("clearcoat_roughness_val", 0.15)
	return mat

func _world_aabb(node: Node) -> AABB:
	var aabb := AABB(); var first := true
	for mi in _find_meshes(node):
		var wa: AABB = mi.global_transform * mi.get_aabb()
		if first: aabb = wa; first = false
		else: aabb = aabb.merge(wa)
	return aabb

func _find_meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D: out.append(n)
	for c in n.get_children(): out.append_array(_find_meshes(c))
	return out

# ---- UI ---------------------------------------------------------------------
func _setup_ui() -> void:
	var layer := CanvasLayer.new(); add_child(layer)
	_overlay = TextureRect.new()
	_overlay.texture = _rtex(UE_REF, false)
	_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.modulate = Color(1, 1, 1, p.overlay)
	layer.add_child(_overlay)

	_panel = PanelContainer.new()
	_panel.position = Vector2(10, 10)
	_panel.custom_minimum_size = Vector2(340, 0)
	layer.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 760)
	_panel.add_child(scroll)
	var vb := VBoxContainer.new(); vb.custom_minimum_size = Vector2(320, 0); scroll.add_child(vb)

	var title := Label.new(); title.text = "UE Moonlight match — look-dev\nO overlay · H panel · P save"; vb.add_child(title)

	_section(vb, "SCENE")
	_slider(vb, "model_yaw", "Model yaw", 0.0, 360.0, 0.5)
	_slider(vb, "view_pan", "View pan (look-dev only)", -4.0, 4.0, 0.05)
	_slider(vb, "overlay", "UE overlay opacity", 0.0, 1.0, 0.01)
	_slider(vb, "zoff", "Depth nudge (m)", -0.5, 0.5, 0.005)

	_section(vb, "LIGHTING — energy")
	_slider(vb, "exposure", "Exposure", 0.2, 3.0, 0.01)
	_slider(vb, "glow", "Glow", 0.0, 2.0, 0.01)
	_slider(vb, "env_amb", "Env ambient", 0.0, 1.0, 0.01)
	_slider(vb, "key", "Key", 0.0, 40.0, 0.1)
	_slider(vb, "keyrect", "Key-rect", 0.0, 40.0, 0.1)
	_slider(vb, "fill", "Fill", 0.0, 30.0, 0.1)
	_slider(vb, "rim", "Rim", 0.0, 30.0, 0.1)
	_slider(vb, "ambient", "Ambient pt", 0.0, 10.0, 0.05)

	_section(vb, "COLOUR BALANCE")
	_slider(vb, "saturation", "Saturation", 0.0, 2.0, 0.01)
	_slider(vb, "brightness", "Brightness", 0.3, 2.0, 0.01)
	_slider(vb, "contrast", "Contrast", 0.3, 2.0, 0.01)

	_section(vb, "LIGHTING — colour")
	_color(vb, "key_col", "Key colour")
	_color(vb, "keyrect_col", "Key-rect colour")
	_color(vb, "fill_col", "Fill colour")
	_color(vb, "rim_col", "Rim colour")
	_color(vb, "amb_col", "Ambient colour")

	_section(vb, "SKIN (face + body)")
	_slider(vb, "sss", "Subsurface", 0.0, 1.0, 0.01)
	_slider(vb, "scatter", "Scatter strength", 0.0, 3.0, 0.01)
	_slider(vb, "skin_smooth", "Skin smoothness", 0.0, 4.0, 0.01)
	_slider(vb, "skin_nrm", "Normal strength", 0.0, 6.0, 0.05)
	_slider(vb, "skin_rough", "Roughness", 0.0, 1.0, 0.01)
	_slider(vb, "skin_spec", "Specular", 0.0, 1.0, 0.01)
	_toggle(vb, "double_spec", "Double specular")

	_section(vb, "HAIR")
	_color(vb, "hair_col", "Hair colour")
	_slider(vb, "hair_thresh", "Alpha threshold", 0.0, 0.6, 0.005)
	_slider(vb, "hair_root", "Root darkening", 0.0, 1.0, 0.01)
	_slider(vb, "hair_rough", "Roughness", 0.0, 1.0, 0.01)
	_slider(vb, "hair_spec", "Specular", 0.0, 1.0, 0.01)

	_section(vb, "EYES")
	_slider(vb, "sclera_tint", "Sclera tint", 0.0, 1.0, 0.01)
	_slider(vb, "iris_scale", "Iris scale", 0.5, 4.0, 0.01)
	_slider(vb, "iris_radius", "Iris radius", 0.05, 0.4, 0.005)
	_slider(vb, "eye_rough", "Roughness", 0.0, 0.5, 0.005)
	_slider(vb, "eye_spec", "Specular", 0.0, 1.0, 0.01)
	_slider(vb, "eye_clearcoat", "Clearcoat (eye glow)", 0.0, 1.0, 0.01)

	_section(vb, "PRESETS")
	var btn := Button.new(); btn.text = "Save current (lookdev_preset.json)"
	btn.pressed.connect(_save_preset); vb.add_child(btn)
	# named save-as
	var saverow := HBoxContainer.new()
	_preset_name = LineEdit.new(); _preset_name.placeholder_text = "preset name"
	_preset_name.custom_minimum_size = Vector2(180, 0); saverow.add_child(_preset_name)
	var saveas := Button.new(); saveas.text = "Save as"
	saveas.pressed.connect(_save_preset_as); saverow.add_child(saveas)
	vb.add_child(saverow)
	# load dropdown
	var loadrow := HBoxContainer.new()
	_preset_dd = OptionButton.new(); _preset_dd.custom_minimum_size = Vector2(200, 0)
	loadrow.add_child(_preset_dd)
	var loadbtn := Button.new(); loadbtn.text = "Load"
	loadbtn.pressed.connect(_load_selected_preset); loadrow.add_child(loadbtn)
	vb.add_child(loadrow)
	_refresh_preset_list()

func _section(parent: Control, txt: String) -> void:
	var l := Label.new(); l.text = "── " + txt + " ──"
	l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	parent.add_child(l)

func _slider(parent: Control, key: String, label: String, lo: float, hi: float, step: float) -> void:
	var row := VBoxContainer.new()
	var top := HBoxContainer.new()
	var lab := Label.new(); lab.text = label; lab.custom_minimum_size = Vector2(175, 0)
	top.add_child(lab)
	# Numeric entry — allow_greater/allow_lesser lets you type values BEYOND the
	# slider range to test extremes.
	var spin := SpinBox.new()
	spin.min_value = lo; spin.max_value = hi; spin.step = step
	spin.allow_greater = true; spin.allow_lesser = true
	spin.custom_minimum_size = Vector2(120, 0)
	spin.value = float(p[key])
	top.add_child(spin)
	row.add_child(top)
	var sl := HSlider.new()
	sl.min_value = lo; sl.max_value = hi; sl.step = step
	sl.value = clampf(float(p[key]), lo, hi)
	sl.custom_minimum_size = Vector2(300, 16)
	row.add_child(sl); parent.add_child(row)
	sl.value_changed.connect(func(v):
		p[key] = v; spin.set_value_no_signal(v); _apply_all())
	spin.value_changed.connect(func(v):
		p[key] = v; sl.set_value_no_signal(clampf(v, lo, hi)); _apply_all())
	_refreshers.append(func():
		spin.set_value_no_signal(float(p[key])); sl.set_value_no_signal(clampf(float(p[key]), lo, hi)))

func _color(parent: Control, key: String, label: String) -> void:
	var row := HBoxContainer.new()
	var lab := Label.new(); lab.text = label; lab.custom_minimum_size = Vector2(150, 0)
	row.add_child(lab)
	var cp := ColorPickerButton.new()
	cp.color = p[key]; cp.custom_minimum_size = Vector2(140, 24)
	cp.color_changed.connect(func(c): p[key] = c; _apply_all())
	row.add_child(cp); parent.add_child(row)
	_refreshers.append(func(): cp.color = p[key])

func _toggle(parent: Control, key: String, label: String) -> void:
	var cb := CheckBox.new(); cb.text = label; cb.button_pressed = bool(p[key])
	cb.toggled.connect(func(on): p[key] = on; _apply_all())
	parent.add_child(cb)
	_refreshers.append(func(): cb.set_pressed_no_signal(bool(p[key])))

func _refresh_controls() -> void:
	for r in _refreshers:
		r.call()

func _apply_all() -> void:
	if _env:
		_env.tonemap_exposure = p.exposure
		_env.ambient_light_energy = p.env_amb
		_env.glow_intensity = p.glow
		_env.adjustment_saturation = p.saturation
		_env.adjustment_brightness = p.brightness
		_env.adjustment_contrast = p.contrast
	var col_map := {"key": "key_col", "keyrect": "keyrect_col", "fill": "fill_col", "rim": "rim_col", "ambient": "amb_col"}
	for k in col_map.keys():
		if _lights.has(k):
			var L: Light3D = _lights[k]
			L.light_energy = p[k]
			L.light_color = p[col_map[k]]
	for m in _skin_mats:
		m.set_shader_parameter("subsurface_scattering_strength", p.sss)
		m.set_shader_parameter("scatter_strength", p.scatter)
		m.set_shader_parameter("skin_smoothness", p.skin_smooth)
		m.set_shader_parameter("normal_strength", p.skin_nrm)
		m.set_shader_parameter("roughness", p.skin_rough)
		m.set_shader_parameter("specular", p.skin_spec)
		m.set_shader_parameter("double_specularity", p.double_spec)
	for m in _hair_mats:
		m.set_shader_parameter("hair_color", p.hair_col)
		m.set_shader_parameter("alpha_threshold", p.hair_thresh)
		m.set_shader_parameter("root_darkening", p.hair_root)
		m.set_shader_parameter("roughness_val", p.hair_rough)
		m.set_shader_parameter("specular_val", p.hair_spec)
	for m in _hair_back_mats:
		m.set_shader_parameter("hair_color", (p.hair_col as Color).darkened(0.25))
	for m in _eye_mats:
		m.set_shader_parameter("sclera_tint", p.sclera_tint)
		m.set_shader_parameter("iris_scale", p.iris_scale)
		m.set_shader_parameter("iris_radius", p.iris_radius)
		m.set_shader_parameter("roughness_val", p.eye_rough)
		m.set_shader_parameter("specular_val", p.eye_spec)
		m.set_shader_parameter("clearcoat_val", p.eye_clearcoat)
	if _character: _character.rotation.y = deg_to_rad(p.model_yaw)
	if _overlay: _overlay.modulate = Color(1, 1, 1, p.overlay)
	if _camera and not OS.has_environment("MATCH_CAPTURE"): _camera.h_offset = p.view_pan

func _serialize() -> Dictionary:
	# JSON can't store Color directly -> serialize colours as [r,g,b].
	var out := {}
	for k in p.keys():
		if p[k] is Color:
			var c: Color = p[k]
			out[k] = [c.r, c.g, c.b]
		else:
			out[k] = p[k]
	return out

func _write_json(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_serialize(), "  ")); f.close()
		print("[lookdev] saved -> ", path)

func _save_preset() -> void:
	_write_json(PRESET_OUT)

func _save_preset_as() -> void:
	var nm := "preset"
	if _preset_name and _preset_name.text.strip_edges() != "":
		nm = _preset_name.text.strip_edges().validate_filename()
	DirAccess.make_dir_recursive_absolute(PRESET_DIR)
	_write_json("%s/%s.json" % [PRESET_DIR, nm])
	_write_json(PRESET_OUT)   # also update the working/last-saved
	_refresh_preset_list()

func _load_preset(path: String) -> void:
	if not FileAccess.file_exists(path): return
	var txt := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY: return
	for k in data.keys():
		if not p.has(k): continue
		if p[k] is Color and data[k] is Array and data[k].size() >= 3:
			p[k] = Color(data[k][0], data[k][1], data[k][2])
		else:
			p[k] = data[k]
	print("[lookdev] loaded <- ", path)

func _load_selected_preset() -> void:
	if _preset_dd == null or _preset_dd.item_count == 0: return
	var fn := _preset_dd.get_item_text(_preset_dd.selected)
	_load_preset("%s/%s.json" % [PRESET_DIR, fn])
	_refresh_controls(); _apply_all()

func _refresh_preset_list() -> void:
	if _preset_dd == null: return
	_preset_dd.clear()
	var d := DirAccess.open(PRESET_DIR)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".json"):
			_preset_dd.add_item(f.get_basename())

# ---- turntable capture (mirrors match_ue.gd) --------------------------------
func _start_movie() -> void:
	DirAccess.make_dir_recursive_absolute(MOVIE_DIR)
	_movie = true; _movie_frame = 0
	_spin_start = _character.rotation.y if _character else 0.0
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.connect(_on_post_draw)
	print("[lookdev] recording turntable -> ", MOVIE_DIR)

func _on_post_draw() -> void:
	if not _movie: return
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [MOVIE_DIR, _movie_frame])
	_movie_frame += 1
	if _movie_frame >= _movie_total:
		_finish_movie()
	elif _character:
		_character.rotation.y = _spin_start + deg_to_rad(360.0) * float(_movie_frame) / float(_movie_total)

func _finish_movie() -> void:
	_movie = false
	if RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	var py := "%s/_assemble.py" % MOVIE_DIR
	var pf := FileAccess.open(py, FileAccess.WRITE)
	pf.store_string(ASSEMBLE_PY); pf.close()
	var o := []
	OS.execute("python", [py, MOVIE_DIR, OUT_MP4], o, true)
	print("[lookdev] movie -> ", OUT_MP4, " ", o)
	get_tree().quit()

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_O:
				p.overlay = 0.5 if p.overlay < 0.05 else 0.0; _apply_all()
			KEY_H:
				if _panel: _panel.visible = not _panel.visible
			KEY_P:
				_save_preset()
