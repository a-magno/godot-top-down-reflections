shader_type canvas_item;

// Mirror shader, used by MirrorMaskGenerator (mirror_mask_generator.gd).
// The script sets grid_data, reflection_texture, view_data, band_data and
// occluder_texture.
// screen_texture is read after the generator's BackBufferCopy.
//
// A pixel shows the reflection when its tile is a mirror tile and its screen
// color is close to one of the bands in hue, saturation and value.
//
// Safe to remove: debug_mask.
// Do not remove: grid_data, view_data, band_data, sample_reflection and
// rgb2hsv.

uniform sampler2D grid_data : filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform sampler2D reflection_texture : filter_nearest;

// Glass color bands from MirrorMaskGenerator.bands: one texel per band,
// rgb = the color already converted to HSV (once, on the CPU, instead of per
// pixel), a = tolerance (how far from that color still counts).
// A texture, not uniform arrays: arrays can't be kept out of saved scenes.
uniform sampler2D band_data : filter_nearest, hint_default_transparent;

uniform float band_softness : hint_range(0.0, 0.2) = 0.04;
uniform float reflection_opacity = 1.0;
uniform bool debug_mask = false;

// Set by the generator, 2x1 float texture (a texture, not uniforms: plain
// uniforms can't be kept out of saved scenes):
//   texel 0 = view rect: xy = top-left, zw = size, in pixels from the map's
//             top-left. The reflection buffer only covers the camera's view.
//   texel 1 = xy: map size in pixels.
uniform sampler2D view_data : filter_nearest, hint_default_transparent;
// Reflectable sprites at their real positions (same view as the reflection
// buffer). Covered pixels never show the reflection.
uniform sampler2D occluder_texture : filter_nearest, hint_default_transparent;

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

float check_band(vec3 hsv, vec3 target_hsv, float tolerance) {
	// Hue distance (wrapping)
	float hue_diff = abs(hsv.x - target_hsv.x);
	hue_diff = min(hue_diff, 1.0 - hue_diff);
	float hue_match = 1.0 - smoothstep(tolerance - band_softness, tolerance + band_softness, hue_diff);

	// Saturation distance
	float sat_diff = abs(hsv.y - target_hsv.y);
	float sat_match = 1.0 - smoothstep(tolerance - band_softness, tolerance + band_softness, sat_diff);

	// Value distance
	float val_diff = abs(hsv.z - target_hsv.z);
	float val_match = 1.0 - smoothstep(tolerance - band_softness, tolerance + band_softness, val_diff);

	return hue_match * sat_match * val_match;
}

void fragment() {
	vec4 view = texelFetch(view_data, ivec2(0, 0), 0);
	vec2 map_size = texelFetch(view_data, ivec2(1, 0), 0).xy;
	vec4 grid_pixel = texture(grid_data, UV);
	float match = 0.0;

	if (grid_pixel.r < 0.5) {
		vec4 screen_pixel = texture(screen_texture, SCREEN_UV);
		vec3 hsv = rgb2hsv(screen_pixel.rgb);

		int band_count = textureSize(band_data, 0).x;
		for (int i = 0; i < band_count; i++) {
			vec4 band = texelFetch(band_data, ivec2(i, 0), 0);
			// Tolerance 0 = no band (also the 1x1 default when bands is empty).
			if (band.a > 0.0) {
				match = max(match, check_band(hsv, band.rgb, band.a));
			}
		}
	}

	vec4 reflection = sample_reflection(reflection_texture, UV, view, map_size);
	if (sample_reflection(occluder_texture, UV, view, map_size).a > 0.5) {
		reflection = vec4(0.0);
	}
	reflection.a *= reflection_opacity;

	if (debug_mask) {
		if (grid_pixel.r < 0.5) {
			// Red = HSV match strength, Yellow = tagged but no match
			COLOR = mix(vec4(1.0, 1.0, 0.0, 0.5), vec4(1.0, 0.0, 0.0, 0.8), match);
		} else {
			COLOR = vec4(0.0);
		}
	} else {
		COLOR = reflection * match;
	}
}