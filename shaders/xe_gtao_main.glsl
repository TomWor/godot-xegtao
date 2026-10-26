#[compute]
#version 450

// XeGTAO main pass: ground-truth ambient occlusion ("Practical Real-Time
// Strategies for Accurate Indirect Occlusion", Jimenez et al. 2016) from the
// view-space depth MIP chain and the depth prepass normals. Also writes the
// depth edges the denoiser needs. Port of XeGTAO's XeGTAO_MainPass
// (Copyright (C) 2016-2021, Intel Corporation, MIT licence, see LICENSE.XeGTAO.txt).
//
// View space follows XeGTAO: +X right, +Y up, +Z away from the camera.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D viewspace_depth;
layout(set = 0, binding = 1) uniform sampler2D normal_roughness;
layout(r8, set = 0, binding = 2) uniform restrict writeonly image2D out_ao;
layout(r8, set = 0, binding = 3) uniform restrict writeonly image2D out_edges;

layout(push_constant, std430) uniform Params {
	ivec2 viewport_size;
	vec2 viewport_pixel_size;
	vec2 ndc_to_view_mul;
	vec2 ndc_to_view_add;
	vec2 ndc_to_view_mul_x_pixel_size;
	float effect_radius;
	float effect_falloff_range;
	float radius_multiplier;
	float final_value_power;
	float sample_distribution_power;
	float thin_occluder_compensation;
	float depth_mip_sampling_offset;
	float slice_count;
	float steps_per_slice;
	uint noise_index;
} params;

#define XE_GTAO_PI 3.1415926535897932384626433832795
#define XE_GTAO_PI_HALF 1.5707963267948966192313216916398
#define XE_GTAO_DEPTH_MIP_LEVELS 5.0
// The raw term can overshoot 1 before denoising; stored scaled down by this.
#define XE_GTAO_OCCLUSION_TERM_SCALE 1.5
#define XE_HILBERT_LEVEL 6u
#define XE_HILBERT_WIDTH (1u << XE_HILBERT_LEVEL)

vec3 compute_viewspace_position(vec2 screen_pos, float viewspace_z) {
	return vec3((params.ndc_to_view_mul * screen_pos + params.ndc_to_view_add) * viewspace_z, viewspace_z);
}

vec4 calculate_edges(float center_z, float left_z, float right_z, float top_z, float bottom_z) {
	vec4 edges_lrtb = vec4(left_z, right_z, top_z, bottom_z) - center_z;

	float slope_lr = (edges_lrtb.y - edges_lrtb.x) * 0.5;
	float slope_tb = (edges_lrtb.w - edges_lrtb.z) * 0.5;
	vec4 edges_lrtb_slope_adjusted = edges_lrtb + vec4(slope_lr, -slope_lr, slope_tb, -slope_tb);
	edges_lrtb = min(abs(edges_lrtb), abs(edges_lrtb_slope_adjusted));
	return clamp(1.25 - edges_lrtb / (center_z * 0.011), 0.0, 1.0);
}

// Two bits per edge: four gradient values (0, 1/3, 2/3, 1).
float pack_edges(vec4 edges_lrtb) {
	edges_lrtb = round(clamp(edges_lrtb, 0.0, 1.0) * 2.9);
	return dot(edges_lrtb, vec4(64.0 / 255.0, 16.0 / 255.0, 4.0 / 255.0, 1.0 / 255.0));
}

// [Drobot2014a] Low Level Optimizations for GCN.
float fast_sqrt(float x) {
	return intBitsToFloat(0x1fbd1df5 + (floatBitsToInt(x) >> 1));
}

// Input [-1, 1], output [0, PI] (Sebastien Lagarde, "Inverse trigonometric
// functions GPU optimization for AMD GCN architecture").
float fast_acos(float in_x) {
	float x = abs(in_x);
	float res = -0.156583 * x + XE_GTAO_PI_HALF;
	res *= fast_sqrt(1.0 - x);
	return in_x >= 0.0 ? res : XE_GTAO_PI - res;
}

// Position of a pixel along a Hilbert curve that fills a 64x64 tile. Each
// level adds the offset of the pixel's quadrant along the curve, then rotates
// or mirrors the remaining coordinates into that quadrant's orientation.
uint hilbert_index(uvec2 p) {
	uint index = 0u;
	for (uint half_size = XE_HILBERT_WIDTH / 2u; half_size > 0u; half_size >>= 1u) {
		uint quadrant_x = (p.x & half_size) != 0u ? 1u : 0u;
		uint quadrant_y = (p.y & half_size) != 0u ? 1u : 0u;
		index += half_size * half_size * ((3u * quadrant_x) ^ quadrant_y);
		if (quadrant_y == 0u) {
			if (quadrant_x == 1u) {
				// Mirror; only the lower bits are used from here on.
				p = ~p;
			}
			p = p.yx;
		}
	}
	return index;
}

// Hilbert curve driving the R2 sequence; the temporal index only changes
// with TAA.
vec2 spatio_temporal_noise(uvec2 pixel, uint temporal_index) {
	uint index = hilbert_index(pixel % XE_HILBERT_WIDTH);
	index += 288u * (temporal_index % 64u);
	return fract(0.5 + float(index) * vec2(0.75487766624669276005, 0.5698402909980532659114));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.viewport_size))) {
		return;
	}
	ivec2 last = params.viewport_size - 1;
	vec2 normalized_screen_pos = (vec2(pixel) + 0.5) * params.viewport_pixel_size;

	float viewspace_z = texelFetch(viewspace_depth, pixel, 0).r;
	float pix_lz = texelFetch(viewspace_depth, clamp(pixel + ivec2(-1, 0), ivec2(0), last), 0).r;
	float pix_rz = texelFetch(viewspace_depth, clamp(pixel + ivec2(1, 0), ivec2(0), last), 0).r;
	float pix_tz = texelFetch(viewspace_depth, clamp(pixel + ivec2(0, -1), ivec2(0), last), 0).r;
	float pix_bz = texelFetch(viewspace_depth, clamp(pixel + ivec2(0, 1), ivec2(0), last), 0).r;

	vec4 edges_lrtb = calculate_edges(viewspace_z, pix_lz, pix_rz, pix_tz, pix_bz);
	imageStore(out_edges, pixel, vec4(pack_edges(edges_lrtb)));

	// Godot's view space looks along -Z; XeGTAO's along +Z.
	vec3 viewspace_normal = normalize(texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0);
	viewspace_normal.z = -viewspace_normal.z;

	// Move the centre slightly towards the camera against depth imprecision.
	viewspace_z *= 0.99999;

	vec3 pix_center_pos = compute_viewspace_position(normalized_screen_pos, viewspace_z);
	vec3 view_vec = normalize(-pix_center_pos);

	float effect_radius = params.effect_radius * params.radius_multiplier;
	float falloff_range = params.effect_falloff_range * effect_radius;
	float falloff_from = effect_radius * (1.0 - params.effect_falloff_range);
	float falloff_mul = -1.0 / falloff_range;
	float falloff_add = falloff_from / falloff_range + 1.0;

	float visibility = 0.0;

	// "Algorithm 1" of the GTAO paper.
	vec2 local_noise = spatio_temporal_noise(uvec2(pixel), params.noise_index);
	float noise_slice = local_noise.x;
	float noise_sample = local_noise.y;

	// Offsets under about a pixel are pushed out to this minimum distance.
	const float pixel_too_close_threshold = 1.3;

	// Approximate view-space size of a pixel at the centre's depth.
	vec2 pixel_dir_rb_viewspace_size_at_center_z = viewspace_z * params.ndc_to_view_mul_x_pixel_size;
	float screenspace_radius = effect_radius / pixel_dir_rb_viewspace_size_at_center_z.x;

	// Fade out for small screen radii.
	visibility += clamp((10.0 - screenspace_radius) / 100.0, 0.0, 1.0) * 0.5;

	// Minimum distance to start sampling from, so the centre pixel is skipped.
	float min_s = pixel_too_close_threshold / screenspace_radius;

	for (float slice = 0.0; slice < params.slice_count; slice++) {
		float slice_k = (slice + noise_slice) / params.slice_count;
		// Lines 5, 6 of the paper.
		float phi = slice_k * XE_GTAO_PI;
		float cos_phi = cos(phi);
		float sin_phi = sin(phi);
		vec2 omega = vec2(cos_phi, -sin_phi);

		// Converted to pixels.
		omega *= screenspace_radius;

		// Line 8.
		vec3 direction_vec = vec3(cos_phi, sin_phi, 0.0);
		// Line 9.
		vec3 ortho_direction_vec = direction_vec - dot(direction_vec, view_vec) * view_vec;
		// Line 10: orthogonal to direction_vec and view_vec, defines the projected normal.
		vec3 axis_vec = normalize(cross(ortho_direction_vec, view_vec));
		// Line 11.
		vec3 projected_normal_vec = viewspace_normal - axis_vec * dot(viewspace_normal, axis_vec);
		// Line 13.
		float sign_norm = sign(dot(ortho_direction_vec, projected_normal_vec));
		// Line 14.
		float projected_normal_vec_length = length(projected_normal_vec);
		float cos_norm = clamp(dot(projected_normal_vec, view_vec) / projected_normal_vec_length, 0.0, 1.0);
		// Line 15.
		float n = sign_norm * fast_acos(cos_norm);

		// Lower weight targets, below the horizon for this normal.
		float low_horizon_cos0 = cos(n + XE_GTAO_PI_HALF);
		float low_horizon_cos1 = cos(n - XE_GTAO_PI_HALF);

		// Lines 17, 18, with the per-side loop unrolled.
		float horizon_cos0 = low_horizon_cos0;
		float horizon_cos1 = low_horizon_cos1;

		for (float step = 0.0; step < params.steps_per_slice; step++) {
			// R1 sequence.
			float step_base_noise = (slice + step * params.steps_per_slice) * 0.6180339887498948482;
			float step_noise = fract(noise_sample + step_base_noise);

			// Approximately line 20, with noise.
			float s = (step + step_noise) / params.steps_per_slice;
			s = pow(s, params.sample_distribution_power);
			s += min_s;

			// Approximately lines 21, 22.
			vec2 sample_offset = s * omega;
			float sample_offset_length = length(sample_offset);

			// Point sampling only: interpolating depth between texels would
			// distort the slopes.
			float mip_level = clamp(log2(sample_offset_length) - params.depth_mip_sampling_offset, 0.0, XE_GTAO_DEPTH_MIP_LEVELS);

			// Snap to pixel centres.
			sample_offset = round(sample_offset) * params.viewport_pixel_size;

			vec2 sample_screen_pos0 = normalized_screen_pos + sample_offset;
			float sz0 = textureLod(viewspace_depth, sample_screen_pos0, mip_level).r;
			vec3 sample_pos0 = compute_viewspace_position(sample_screen_pos0, sz0);

			vec2 sample_screen_pos1 = normalized_screen_pos - sample_offset;
			float sz1 = textureLod(viewspace_depth, sample_screen_pos1, mip_level).r;
			vec3 sample_pos1 = compute_viewspace_position(sample_screen_pos1, sz1);

			vec3 sample_delta0 = sample_pos0 - pix_center_pos;
			vec3 sample_delta1 = sample_pos1 - pix_center_pos;
			float sample_dist0 = length(sample_delta0);
			float sample_dist1 = length(sample_delta1);

			// Approximately lines 23, 24.
			vec3 sample_horizon_vec0 = sample_delta0 / sample_dist0;
			vec3 sample_horizon_vec1 = sample_delta1 / sample_dist1;

			// Samples beyond the radius fade out; the thickness heuristic
			// discards samples behind the centre sooner.
			float falloff_base0 = length(vec3(sample_delta0.xy, sample_delta0.z * (1.0 + params.thin_occluder_compensation)));
			float falloff_base1 = length(vec3(sample_delta1.xy, sample_delta1.z * (1.0 + params.thin_occluder_compensation)));
			float weight0 = clamp(falloff_base0 * falloff_mul + falloff_add, 0.0, 1.0);
			float weight1 = clamp(falloff_base1 * falloff_mul + falloff_add, 0.0, 1.0);

			// Sample horizon cosines.
			float shc0 = dot(sample_horizon_vec0, view_vec);
			float shc1 = dot(sample_horizon_vec1, view_vec);

			// Discard unwanted samples.
			shc0 = mix(low_horizon_cos0, shc0, weight0);
			shc1 = mix(low_horizon_cos1, shc1, weight1);

			horizon_cos0 = max(horizon_cos0, shc0);
			horizon_cos1 = max(horizon_cos1, shc1);
		}

		// Intel's fudge against slight over-darkening on steep slopes.
		projected_normal_vec_length = mix(projected_normal_vec_length, 1.0, 0.05);

		// Approximately line 27.
		float h0 = -fast_acos(horizon_cos1);
		float h1 = fast_acos(horizon_cos0);
		float iarc0 = (cos_norm + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) / 4.0;
		float iarc1 = (cos_norm + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) / 4.0;
		visibility += projected_normal_vec_length * (iarc0 + iarc1);
	}
	visibility /= params.slice_count;
	visibility = pow(visibility, params.final_value_power);
	// Full occlusion makes no sense for a visible pixel.
	visibility = max(0.03, visibility);

	imageStore(out_ao, pixel, vec4(clamp(visibility / XE_GTAO_OCCLUSION_TERM_SCALE, 0.0, 1.0)));
}
