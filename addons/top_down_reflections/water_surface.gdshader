shader_type canvas_item;

// Water reflection shader, used by ReflectionMaskGenerator
// (reflective_surface.gd). The script sets grid_data, reflection_texture,
// view_data, shadow_color and shadow_offset. Do not set them by hand.
//
// Steps for each pixel:
// 1. Skip pixels outside water tiles (grid_data R of 0.5 or more).
// 2. Check the screen color against the hue, saturation and value ranges.
// 3. Shift the row by whole pixels (distortion) and read the reflection.
// 4. Put the reflection over the clouds.
// 5. On the non-water pixels of water tiles, draw the cloud shadow.
//
// Safe to remove: the distortion block, reflection_tint, debug_mask, and the
// clouds together with the cloud shadows (the shadows copy the cloud values
// from this material).
// Do not remove: grid_data, view_data, sample_reflection and rgb2hsv.

#include "res://addons/top_down_reflections/clouds.gdshaderinc"

uniform sampler2D grid_data : filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform sampler2D reflection_texture : filter_nearest;
uniform float reflection_opacity = 0.7;

// Color band in HSV; pixels inside all three ranges = water
uniform float hue_center : hint_range(0.0, 1.0) = 0.58;        // target hue (0-1 wrapping)
uniform float hue_tolerance : hint_range(0.0, 0.5) = 0.08;     // +/- from center
uniform vec2 saturation_range = vec2(0.25, 1.0);                // min, max
uniform vec2 value_range = vec2(0.2, 1.0);                      // min, max
uniform float band_softness : hint_range(0.0, 0.1) = 0.02;     // 0 = hard cutoff

// Distortion; pixel-snapped sine wave
uniform int distortion_pixels : hint_range(0, 4) = 1;       // max pixel offset
uniform float distortion_speed : hint_range(0.0, 5.0) = 0.8;
uniform float distortion_frequency : hint_range(0.0, 40.0) = 8.0;

// Visual Controls
uniform vec4 reflection_tint : source_color = vec4(1.0);
uniform bool debug_mask = false;

// Clouds: procedural noise, one value per game pixel, scrolled by whole pixels.
uniform bool clouds_enabled = true;
uniform float cloud_scale : hint_range(4.0, 256.0) = 48.0;       // rough cloud size, in pixels
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;      // how much of the water has clouds
uniform float cloud_softness : hint_range(0.0, 0.5) = 0.08;      // edge fade; 0 = hard pixel edges
uniform vec2 cloud_speed = vec2(6.0, 2.0);                       // pixels per second
uniform vec4 cloud_tint : source_color = vec4(1.0, 1.0, 1.0, 0.3);
// Cloud shadows on the non-water pixels of water tiles (shore grass, snow).
// The overlay skips water tiles entirely; set from the generator's exports.
uniform vec4 shadow_color : source_color = vec4(0.0);
uniform vec2 shadow_offset = vec2(0.0);

// Set by the generator, 2x1 float texture (a texture, not uniforms: plain
// uniforms can't be kept out of saved scenes):
//   texel 0 = view rect: xy = top-left, zw = size, in pixels from the map's
//             top-left. The reflection buffer only covers the camera's view.
//   texel 1 = xy: map size in pixels.
uniform sampler2D view_data : filter_nearest, hint_default_transparent;

vec4 sample_reflection(sampler2D tex, vec2 map_uv, vec4 view, vec2 map_size) {
	if (view.z <= 0.0 || view.w <= 0.0) {
		return vec4(0.0);
	}
	vec2 ruv = (map_uv * map_size - view.xy) / view.zw;
	if (any(lessThan(ruv, vec2(0.0))) || any(greaterThan(ruv, vec2(1.0)))) {
		return vec4(0.0);
	}
	return texture(tex, ruv);
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

void fragment() {
	vec4 view = texelFetch(view_data, ivec2(0, 0), 0);
	vec2 map_size = texelFetch(view_data, ivec2(1, 0), 0).xy;
	vec4 grid_pixel = texture(grid_data, UV);
	float match = 0.0;

	// If the grid data is black (is_water == true)
	if (grid_pixel.r < 0.5) {
		vec4 screen_pixel = texture(screen_texture, SCREEN_UV);
		vec3 hsv = rgb2hsv(screen_pixel.rgb);

		// Hue check (wraps around 0/1 boundary)
		float hue_diff = abs(hsv.x - hue_center);
		hue_diff = min(hue_diff, 1.0 - hue_diff);
		float hue_match = 1.0 - smoothstep(hue_tolerance - band_softness, hue_tolerance + band_softness, hue_diff);

		// Saturation check (must be within range)
		float sat_match = smoothstep(saturation_range.x - band_softness, saturation_range.x + band_softness, hsv.y)
		                * (1.0 - smoothstep(saturation_range.y - band_softness, saturation_range.y + band_softness, hsv.y));

		// Value/brightness check (must be within range)
		float val_match = smoothstep(value_range.x - band_softness, value_range.x + band_softness, hsv.z)
		                * (1.0 - smoothstep(value_range.y - band_softness, value_range.y + band_softness, hsv.z));

		// All three must pass
		match = hue_match * sat_match * val_match;
	}

	// DISTORTION; pixel-snapped sine wave, per-tile strength from grid green channel
	vec2 dist_uv = UV;

	if (distortion_pixels > 0) {
		float tile_distortion = grid_pixel.g; // 0-1 from tile data, 1.0 = full
		// Quantize to pixel rows for crisp per-row shifting
		// draw_rect has no texture (TEXTURE_PIXEL_SIZE is 1), so use the viewport height.
		float row = floor(UV.y * map_size.y);
		float phase = row * 0.7 + TIME * distortion_speed;
		// Rows move by whole game pixels only. Per-tile strength sets how many
		// rows ripple (only where the wave is strong enough), not how far:
		// scaling the distance made weak tiles (e.g. 0.1) round to 0 everywhere.
		float s = sin(phase * distortion_frequency);
		float shift_px = abs(s) >= 1.0 - tile_distortion ? round(s * float(distortion_pixels)) : 0.0;
		// Sample at the centre of the shifted game pixel.
		vec2 px = floor(UV * map_size) + vec2(0.5 + shift_px, 0.5);
		dist_uv = px / map_size;
	}

	// Fetch the displaced reflection
	vec4 reflection = sample_reflection(reflection_texture, dist_uv, view, map_size);
	reflection.rgb *= reflection_tint.rgb;
	// Per-tile opacity from grid alpha, falling back to global knob
	float tile_opacity = grid_pixel.a;
	reflection.a *= tile_opacity * reflection_opacity;

	// SCROLLING CLOUDS: sampled per game pixel, scrolled by whole pixels.
	vec4 clouds = vec4(0.0);
	if (clouds_enabled) {
		float cover = cloud_cover(UV * map_size, TIME, cloud_speed, cloud_scale, cloud_coverage, cloud_softness);
		clouds = vec4(cloud_tint.rgb, cloud_tint.a * cover);
	}

	// Reflection over clouds ("over" blend). A plain mix() against transparent
	// clouds darkened the color and applied alpha twice.
	float out_a = reflection.a + clouds.a * (1.0 - reflection.a);
	vec3 out_rgb = (reflection.rgb * reflection.a + clouds.rgb * clouds.a * (1.0 - reflection.a)) / max(out_a, 1e-5);
	vec4 final_water = vec4(out_rgb, out_a);

	if (debug_mask) {
		if (grid_pixel.r < 0.5) {
			// Tile tagged as water: red = matched water, yellow = rejected (shore/edge)
			COLOR = mix(vec4(1.0, 1.0, 0.0, 0.5), vec4(1.0, 0.0, 0.0, 0.8), match);
		} else {
			// Tile not tagged; fully transparent
			COLOR = vec4(0.0);
		}
	} else {
		// Where a tagged tile isn't water (match 0), draw the cloud shadow instead.
		float shadow_a = 0.0;
		if (clouds_enabled && grid_pixel.r < 0.5 && shadow_color.a > 0.0) {
			shadow_a = shadow_color.a * (1.0 - match)
				* cloud_cover(UV * map_size - shadow_offset, TIME, cloud_speed, cloud_scale, cloud_coverage, cloud_softness);
		}
		COLOR = final_water * match + vec4(shadow_color.rgb, 1.0) * shadow_a;
	}
}
