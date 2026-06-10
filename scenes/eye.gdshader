shader_type spatial;
// Eye shader (v2 — real MetaHuman baked eye textures).
// Composites the real iris disc (T_EyeIris*_BC, centered in UV) over the real
// veined sclera (T_EyeSclera*_BC, full eyeball UV) with their NORMAL maps for
// surface relief (iris fiber + sclera), plus a corneal clearcoat for a wet,
// reflective eye that catches the softbox/reflection-probe.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D iris_texture : source_color, filter_linear_mipmap;
uniform sampler2D sclera_texture : source_color, filter_linear_mipmap;
uniform sampler2D iris_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D sclera_normal : hint_normal, filter_linear_mipmap;
uniform float iris_radius : hint_range(0.05, 0.5) = 0.27;
uniform float blend_softness : hint_range(0.0, 0.15) = 0.025;
uniform float iris_scale : hint_range(0.5, 4.0) = 1.0;
// Iris/pupil UV shift — used to FAKE eye gaze on a static (boneless) eyeball, e.g. the
// MH_Explainer face which ships no FACIAL_*_Eye bones. The driver shifts the iris disc
// within the sclera so the eye appears to look around. (0,0) = dead ahead.
uniform vec2 iris_offset = vec2(0.0, 0.0);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.03;
uniform float specular_val : hint_range(0.0, 1.0) = 1.0;
uniform float clearcoat_val : hint_range(0.0, 1.0) = 1.0;
uniform float clearcoat_roughness_val : hint_range(0.0, 1.0) = 0.03;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.6;
uniform float sclera_tint : hint_range(0.0, 1.0) = 1.0;  // 1 = full veins, lower = whiter
// Limbal ring: the dark band where iris meets sclera — reads as eye "contact/definition";
// straddles the iris edge (peaks AT iris_radius, fades both ways).
uniform float limbal_amount : hint_range(0.0, 1.0) = 0.45;
uniform float limbal_width : hint_range(0.0, 0.15) = 0.05;
// Upper-lid shadow: soft occlusion where the lid overhangs the eyeball. Kills the
// "ping-pong ball" uniform-white sclera. In eye-UV: +y = up (same convention the
// iris_offset gaze was calibrated to); the band eases in above lid_shadow_start.
uniform float lid_shadow : hint_range(0.0, 1.0) = 0.30;
uniform float lid_shadow_start = 0.60;
uniform float lid_shadow_end = 0.88;

void fragment() {
	// iris_offset shifts the iris/pupil center (fake gaze for boneless eyes).
	vec2 ctr = UV - vec2(0.5) - iris_offset;
	float dist = length(ctr);

	// Iris disc, centered in UV (optionally zoomed).
	vec2 iris_uv = clamp(ctr * iris_scale + vec2(0.5), vec2(0.0), vec2(1.0));
	vec3 iris_rgb = texture(iris_texture, iris_uv).rgb;

	// Real veined sclera at the eyeball's native UV. Mix toward off-white so it
	// doesn't read too pink/gray; sclera_tint controls how much vein detail.
	vec3 sclera_raw = texture(sclera_texture, UV).rgb;
	vec3 sclera_rgb = mix(vec3(0.80, 0.78, 0.76), sclera_raw, sclera_tint);  // not pure white — real sclera is light grey

	float mask = smoothstep(iris_radius, iris_radius + blend_softness, dist);
	ALBEDO = mix(iris_rgb, sclera_rgb, mask);

	// Limbal ring (dark iris rim), centred on the iris edge.
	float ring = smoothstep(iris_radius - limbal_width, iris_radius, dist)
		* (1.0 - smoothstep(iris_radius, iris_radius + limbal_width * 0.7, dist));
	ALBEDO *= 1.0 - limbal_amount * ring;

	// Upper-lid occlusion: soft vertical AO toward the top of the eyeball (the iris
	// moves with gaze via iris_offset; the lid shadow stays put with the lid).
	ALBEDO *= 1.0 - lid_shadow * smoothstep(lid_shadow_start, lid_shadow_end, UV.y);

	// Surface relief: iris fiber normal inside, sclera normal outside.
	vec3 n_iris = texture(iris_normal, iris_uv).rgb;
	vec3 n_scle = texture(sclera_normal, UV).rgb;
	NORMAL_MAP = mix(n_iris, n_scle, mask);
	NORMAL_MAP_DEPTH = normal_strength;

	ROUGHNESS = roughness_val;
	SPECULAR = specular_val;
	METALLIC = 0.0;
	CLEARCOAT = clearcoat_val;
	CLEARCOAT_ROUGHNESS = clearcoat_roughness_val;
}
