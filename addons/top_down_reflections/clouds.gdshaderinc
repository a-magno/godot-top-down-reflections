// Cloud noise shared by the water reflections and the cloud shadows, so both
// show the same clouds in the same place. Change the cloud look here and both
// follow. Remove this file only together with the clouds and cloud shadows.

float cloud_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Smooth value noise in 0..1.
float cloud_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_hash(i), cloud_hash(i + vec2(1.0, 0.0)), f.x),
	           mix(cloud_hash(i + vec2(0.0, 1.0)), cloud_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// A few octaves so clouds have soft lumps instead of blobs.
float cloud_noise(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * cloud_value_noise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v / 0.9375;  // sum of the amplitudes: back to 0..1
}

// Cloud cover (0..1) at a map pixel. `map_px` is the pixel offset from the
// map's top-left; the clouds scroll by whole pixels.
float cloud_cover(vec2 map_px, float time, vec2 speed, float scale, float coverage, float softness) {
	vec2 px = floor(map_px) + floor(time * speed);
	float edge = 1.0 - coverage;
	return smoothstep(edge - softness, edge + softness, cloud_noise(px / scale));
}
