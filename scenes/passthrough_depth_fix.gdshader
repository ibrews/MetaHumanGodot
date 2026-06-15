// passthrough_depth_fix.gdshader
//
// Fixes the blocky alpha halo around content in visionOS MIXED immersion.
//
// WHY: CompositorServices requires alpha == 0 wherever depth == 0. Godot's mobile
// XR path uses reverse-Z, so "nothing drawn" pixels keep depth == 0 — and any
// transparent / additive / no-depth-write geometry (the control panel, etc.)
// leaves a nonzero alpha there, which trips the compositor's blocky artifact.
//
// FIX: a full-screen quad that writes a tiny non-zero depth to EVERY pixel and
// alpha 0 (no color). Real geometry, being closer, overwrites it via the depth
// test; uncovered pixels get DEPTH_BIAS instead of exactly 0, so depth is never 0.
//
// Source: huisedenanhai, godotengine/godot PR #109975
//   https://github.com/godotengine/godot/pull/109975#issuecomment-3446873204
//   (confirmed working by Godot XR maintainer dsnopek, 2026-05-30).
// Lifted verbatim from the Cascade Countdown project (test-project/passthrough_depth_fix.gdshader).

shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_always, cull_disabled, blend_mix;

#define DEPTH_BIAS 0.00000001

void vertex() {
	// VERTEX.xy spans the full clip-space quad (-1..1); write clip space directly.
	POSITION = vec4(VERTEX.xy, DEPTH_BIAS, 1.0);
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
