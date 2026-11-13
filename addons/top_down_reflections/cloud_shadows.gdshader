shader_type canvas_item;

// Cloud shadows over the whole map: the same clouds as the water reflections
// (same noise, same pixel grid, same scroll), drawn dark instead of light.
// The cloud_* values are copied from the water material every frame by
// ReflectionMaskGenerator, so tweak them there.
// The script also sets grid_data and map_size. Remove this file only together
// with the cloud shadow code in reflective_surface.gd.

#include "res://addons/top_down_reflections/clouds.gdshaderinc"

uniform bool clouds_enabled = true;
uniform float cloud_scale = 48.0;
uniform float cloud_coverage = 0.45;
uniform float cloud_softness = 0.08;
uniform vec2 cloud_speed = vec2(6.0, 2.0);
uniform vec4 shadow_color : source_color = vec4(0.05, 0.05, 0.15, 0.25);
// Shadows fall this many pixels away from the cloud (a reflected cloud and its
// shadow aren't in the same place).
uniform vec2 shadow_offset = vec2(0.0);
// The water generator's tile mask (R < 0.5 = water tile) and the map size, so
// water tiles get the reflected cloud only, not a shadow on top of it.
uniform sampler2D grid_data : filter_nearest, hint_default_white;
uniform vec2 map_size = vec2(1.0);

// The overlay node sits at the map's top-left, so its local vertex position
// is the same map pixel offset the water shader computes from UV.
varying vec2 map_px;

void vertex() {
	map_px = VERTEX;
}

void fragment() {
	bool water = texture(grid_data, map_px / map_size).r < 0.5;
	float cover = clouds_enabled && !water
		? cloud_cover(map_px - shadow_offset, TIME, cloud_speed, cloud_scale, cloud_coverage, cloud_softness)
		: 0.0;
	COLOR = vec4(shadow_color.rgb, shadow_color.a * cover);
}
