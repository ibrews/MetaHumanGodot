shader_type spatial;
// Eyelash shader: alpha-blended dark lash band with strand-atlas detail.
//
// The MetaHuman lash atlas has only ~4% non-zero strand pixels with 96% pure
// black gaps. Pure alpha-clip would leave the bright eye visible through gaps.
// Instead we composite a uniform `base_alpha` dark layer + strand-atlas highs
// on top, so the lash mesh appears as a dense dark band with strand variation.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 lash_color : source_color = vec4(0.025, 0.016, 0.010, 1.0);
uniform sampler2D coverage_atlas : filter_linear_mipmap, repeat_enable;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.55;
uniform float strand_boost : hint_range(0.5, 6.0) = 3.0;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;
uniform float specular_val : hint_range(0.0, 1.0) = 0.05;

void fragment() {
	vec4 atlas = texture(coverage_atlas, UV);
	float strand_val = dot(atlas.rgb, vec3(0.299, 0.587, 0.114));
	float strand_alpha = clamp(strand_val * strand_boost, 0.0, 1.0);
	// Composite: base dark layer + strand detail on top
	float final_alpha = clamp(base_alpha + strand_alpha * (1.0 - base_alpha), 0.0, 1.0);

	if (final_alpha < 0.02) {
		discard;
	}

	ALBEDO = lash_color.rgb;
	ROUGHNESS = roughness_val;
	SPECULAR = specular_val;
	METALLIC = 0.0;
	ALPHA = final_alpha;
}
