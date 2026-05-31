/*
MIT License
Copyright (c) 2025 MatMADNESS

Permission is hereby granted, free of charge, to use, copy, modify, and
distribute this software as permitted under the MIT License.

This Shader is part of the Human Shaders collection by MatMADNESS
and is built upon https://github.com/RustyRoboticsBV/GodotStandardLightShader
*/

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 sclera_albedo : source_color = vec4(1.);
uniform vec4 iris_albedo : source_color = vec4(1.);
uniform sampler2D sclera_albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D iris_albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool height_enabled = true;

group_uniforms normal;
uniform sampler2D sclera_normal_texture : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D iris_normal_texture : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_strength : hint_range(-16.0, 16.0) = 1.;

uniform float iris_scale : hint_range(0.0, 10.0, 0.1) = 3.5;

uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float specular : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float metallic : hint_range(0.0, 1.0, 0.01);

group_uniforms height;
uniform bool use_heightmap = true;
uniform sampler2D texture_heightmap : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float heightmap_scale : hint_range(0.0, 128.0, 0.1) = 32.0;
uniform vec2 heightmap_flip;

group_uniforms subsurface_scattering;
uniform bool subsurface_scattering = true;
uniform bool use_noise = false;
uniform float subsurface_scattering_strength : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform sampler2D texture_sss_noise : filter_linear, repeat_enable, source_color;

uniform vec3 uv1_scale;
uniform vec3 uv1_offset;

varying vec3 albedo;
varying vec3 DIFFUSE_NORMAL;

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
}

vec3 normal_blending(vec3 b, vec3 d, float factor) {
	return vec3(b.xy + mix(vec2(.5), d.xy, factor) - 0.5, b.z);
}

void fragment() {
	vec2 base_uv = UV;

	//float depth_tex = texture(depth_texture, base_uv).r * .5;
	float fresnel = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0 );
	fresnel = clamp(pow(1.- fresnel + 0.32,7.), 0., 1.) +1.;

	vec2 uv_center = vec2(0.5);
	vec2 iris_uv = clamp(((UV - uv_center) * iris_scale + uv_center), 0.0, 1.);
	float iris_alpha = texture(iris_albedo_texture, iris_uv).a;
	vec4 iris_depth = texture(texture_heightmap, iris_uv);
	iris_alpha = smoothstep(0.0,0.2, 1.- iris_depth.b);
	float iris_uv_size = 1.6;

//Parallax effect. Only runs of not in compatibility renderer.
#if CURRENT_RENDERER != RENDERER_COMPATIBILITY
	if (use_heightmap) {
		iris_uv_size /= (1. + heightmap_scale * 0.025);
		vec3 view_dir = normalize(normalize(-VERTEX + EYE_OFFSET) * mat3(TANGENT * heightmap_flip.x, -BINORMAL * heightmap_flip.y, NORMAL));
		float depth = 1.0 - iris_depth.b;
		vec2 ofs = iris_uv - view_dir.xy / (view_dir.z * fresnel) * depth * heightmap_scale * 0.01;
		iris_uv = clamp(ofs,0.,1.);
	}
#endif

	iris_uv = (iris_uv - uv_center) * iris_uv_size + uv_center;

	vec4 sclera_diff = texture(sclera_albedo_texture, base_uv) * sclera_albedo;
	vec4 iris_diff = texture(iris_albedo_texture, iris_uv) * iris_albedo;

	albedo = mix(sclera_diff, iris_diff, iris_alpha).rgb;

	ALBEDO = albedo;

	ROUGHNESS = roughness;

	vec3 sclera_normal_tex = textureLod(sclera_normal_texture, base_uv, 4).rgb;
	vec3 iris_normal_tex = textureLod(iris_normal_texture, iris_uv, 4).rgb;

	vec3 iris_normal_mix = normal_blending(1.5 - iris_depth.rgb * 2., iris_normal_tex, 1.0);

	mat3 TBN = mat3(TANGENT, -BINORMAL, NORMAL);
	vec3 diff_normal_map = mix(
		vec3(.5,.5,1.),
		iris_normal_mix,
		smoothstep(0.05,0.8,1. - iris_depth.b) * 5.0);
	vec3 diff_normal_tangent = vec3(
		diff_normal_map.r * 2.0 - 1.0,  // X-axis (unchanged)
		(1.0 - diff_normal_map.g) * 2.0 - 1.0,  // Y-axis (inverted)
		1   // Z-axis (solid blue)
	);
	DIFFUSE_NORMAL = normalize(TBN * diff_normal_tangent);

	NORMAL_MAP = mix(sclera_normal_tex, vec3(.5,.5,1.), iris_alpha);
	NORMAL_MAP_DEPTH = normal_strength;

	//SSS
	if (subsurface_scattering){
		float sss_strength_value = subsurface_scattering_strength;
		if (use_noise){
			vec2 tiling_screen_uv = FRAGCOORD.xy / (0.64 * -1.);
			float noise = 3.* texture(texture_sss_noise, tiling_screen_uv).r;
			sss_strength_value *= noise;
		}
		SSS_STRENGTH = sss_strength_value * (1.- iris_alpha * .5);
	}

}

float DistributionGGX(float cos_theta_m, float alpha){
	float alpha2 = alpha * alpha;
	float d = 1.0 + (alpha2 - 1.0) * cos_theta_m * cos_theta_m;
	return alpha2 / (PI * d * d);
}

float GeometryGGX(float NdotL, float NdotV, float alpha){
	return 0.5 / mix(2.0 * NdotL * NdotV, NdotL + NdotV, alpha);
}

vec3 SchlickBaseReflectivity(){
	float dielectric = 0.04 * specular * specular;
	return mix(vec3(dielectric), albedo.rgb, vec3(metallic));
}

float SchlickFresnel(float u){
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m;
}

void light()
{
	// Calculate some vectors.
	vec3 lightColor = LIGHT_COLOR / PI;

	vec3 half = normalize(VIEW + LIGHT);

	float NdotL = max(dot(NORMAL, LIGHT), 0.0);
	float NdotV = max(dot(NORMAL, VIEW), 0.0);
	float NdotH = max(dot(NORMAL, half), 0.0);
	float LdotH = max(dot(LIGHT, half), 0.0);

	// Diffuse light (Lambert).

	DIFFUSE_LIGHT += clamp(dot(mix(DIFFUSE_NORMAL, NORMAL, 0.3), LIGHT),0.,1.) * ATTENUATION * lightColor;

	//Custom Diffuse Light.

	// Specular light (Schlick-GGX).
	float ggxAlpha = clamp(ROUGHNESS * ROUGHNESS, 0.01, 1.0);//clamping to avoid weird behavior at 0 roughness
	float D = DistributionGGX(NdotH, ggxAlpha);
	float G = GeometryGGX(NdotL, NdotV, ggxAlpha);

	vec3 f0 = SchlickBaseReflectivity();
	float LdotH5 = SchlickFresnel(LdotH);
	float f90 = clamp(50.0 * f0.g, 0.0, 1.0);
	vec3 F = f0 + (f90 - f0) * LdotH5;

	vec3 specularBRDF = max(NdotL * D * G * F, 0.0);
	SPECULAR_LIGHT += specularBRDF * LIGHT_COLOR * ATTENUATION;
}
