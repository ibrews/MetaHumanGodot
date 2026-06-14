// Quest-standalone STUB. The custom light() skin/eye/hair shaders do NOT compile on the
// Mobile renderer (light_compute) — their failed pipelines intermittently flood draw_list
// errors and corrupt frames. The real look is applied via the StandardMaterial3D swap in
// vr.gd; this trivial shader just always compiles so nothing ever renders a null pipeline.
// If the swap ever misses a surface it shows a neutral textured fallback, not garbage.
shader_type spatial;
uniform sampler2D texture_albedo : source_color, hint_default_white;
void fragment() {
	ALBEDO = texture(texture_albedo, UV).rgb;
	ROUGHNESS = 0.75;
}
