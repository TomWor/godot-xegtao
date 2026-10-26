#[compute]
#version 450

// XeGTAO depth MIP chain: each level keeps the depth of the 2x2 block,
// weighted towards the nearer samples so thin foreground occluders survive.
// Port of XeGTAO (Copyright (C) 2016-2021, Intel Corporation, MIT licence,
// see LICENSE.XeGTAO.txt).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D source_mip;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D out_mip;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	ivec2 source_size;
	float effect_radius;
	float effect_falloff_range;
	float radius_multiplier;
	float pad;
} params;

float depth_mip_filter(float depth0, float depth1, float depth2, float depth3) {
	float max_depth = max(max(depth0, depth1), max(depth2, depth3));

	const float depth_range_scale_factor = 0.75; // Found empirically by Intel.
	float effect_radius = depth_range_scale_factor * params.effect_radius * params.radius_multiplier;
	float falloff_range = params.effect_falloff_range * effect_radius;
	float falloff_from = effect_radius * (1.0 - params.effect_falloff_range);
	float falloff_mul = -1.0 / falloff_range;
	float falloff_add = falloff_from / falloff_range + 1.0;

	float weight0 = clamp((max_depth - depth0) * falloff_mul + falloff_add, 0.0, 1.0);
	float weight1 = clamp((max_depth - depth1) * falloff_mul + falloff_add, 0.0, 1.0);
	float weight2 = clamp((max_depth - depth2) * falloff_mul + falloff_add, 0.0, 1.0);
	float weight3 = clamp((max_depth - depth3) * falloff_mul + falloff_add, 0.0, 1.0);

	float weight_sum = weight0 + weight1 + weight2 + weight3;
	return (weight0 * depth0 + weight1 * depth1 + weight2 * depth2 + weight3 * depth3) / weight_sum;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	ivec2 source = pixel * 2;
	ivec2 last = params.source_size - 1;
	float depth0 = imageLoad(source_mip, min(source, last)).r;
	float depth1 = imageLoad(source_mip, min(source + ivec2(1, 0), last)).r;
	float depth2 = imageLoad(source_mip, min(source + ivec2(0, 1), last)).r;
	float depth3 = imageLoad(source_mip, min(source + ivec2(1, 1), last)).r;
	imageStore(out_mip, pixel, vec4(depth_mip_filter(depth0, depth1, depth2, depth3)));
}
