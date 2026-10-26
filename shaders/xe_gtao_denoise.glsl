#[compute]
#version 450

// XeGTAO denoiser: an edge-aware 3x3 blur driven by the depth edges of the
// main pass. The last pass restores the occlusion term's scale and applies
// the intensity. Port of XeGTAO's XeGTAO_Denoise, one pixel per invocation
// (Copyright (C) 2016-2021, Intel Corporation, MIT licence, see
// LICENSE.XeGTAO.txt).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_ao;
layout(set = 0, binding = 1) uniform sampler2D source_edges;
layout(r8, set = 0, binding = 2) uniform restrict writeonly image2D out_ao;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	float blur_beta;
	uint final_apply;
	float intensity;
	float pad0;
	float pad1;
	float pad2;
} params;

#define XE_GTAO_OCCLUSION_TERM_SCALE 1.5

vec4 unpack_edges(float packed_value) {
	uint packed_bits = uint(packed_value * 255.5);
	vec4 edges_lrtb = vec4(float((packed_bits >> 6) & 3u), float((packed_bits >> 4) & 3u), float((packed_bits >> 2) & 3u), float(packed_bits & 3u)) / 3.0;
	return clamp(edges_lrtb, 0.0, 1.0);
}

float ao_at(ivec2 pixel) {
	return texelFetch(source_ao, clamp(pixel, ivec2(0), params.size - 1), 0).r;
}

vec4 edges_at(ivec2 pixel) {
	return unpack_edges(texelFetch(source_edges, clamp(pixel, ivec2(0), params.size - 1), 0).r);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	bool final_apply = params.final_apply != 0u;
	float blur_amount = final_apply ? params.blur_beta : params.blur_beta / 5.0;
	const float diag_weight = 0.85 * 0.5;

	vec4 edges_l = edges_at(pixel + ivec2(-1, 0));
	vec4 edges_t = edges_at(pixel + ivec2(0, -1));
	vec4 edges_r = edges_at(pixel + ivec2(1, 0));
	vec4 edges_b = edges_at(pixel + ivec2(0, 1));
	vec4 edges_c = edges_at(pixel);

	// Edge detection isn't symmetrical between neighbours; enforce it.
	edges_c *= vec4(edges_l.y, edges_r.x, edges_t.w, edges_b.z);

	// Let a little AO leak in from neighbours where there are 3 or 4 edges,
	// against spatial and temporal aliasing.
	const float leak_threshold = 2.5;
	const float leak_strength = 0.5;
	float edginess = (clamp(4.0 - leak_threshold - dot(edges_c, vec4(1.0)), 0.0, 1.0) / (4.0 - leak_threshold)) * leak_strength;
	edges_c = clamp(edges_c + edginess, 0.0, 1.0);

	float weight_tl = diag_weight * (edges_c.x * edges_l.z + edges_c.z * edges_t.x);
	float weight_tr = diag_weight * (edges_c.z * edges_t.y + edges_c.y * edges_r.z);
	float weight_bl = diag_weight * (edges_c.w * edges_b.x + edges_c.x * edges_l.w);
	float weight_br = diag_weight * (edges_c.y * edges_r.w + edges_c.w * edges_b.y);

	float sum_weight = blur_amount;
	float sum = ao_at(pixel) * sum_weight;

	sum += ao_at(pixel + ivec2(-1, 0)) * edges_c.x;
	sum += ao_at(pixel + ivec2(1, 0)) * edges_c.y;
	sum += ao_at(pixel + ivec2(0, -1)) * edges_c.z;
	sum += ao_at(pixel + ivec2(0, 1)) * edges_c.w;
	sum_weight += edges_c.x + edges_c.y + edges_c.z + edges_c.w;

	sum += ao_at(pixel + ivec2(-1, -1)) * weight_tl;
	sum += ao_at(pixel + ivec2(1, -1)) * weight_tr;
	sum += ao_at(pixel + ivec2(-1, 1)) * weight_bl;
	sum += ao_at(pixel + ivec2(1, 1)) * weight_br;
	sum_weight += weight_tl + weight_tr + weight_bl + weight_br;

	float visibility = sum / sum_weight;
	if (final_apply) {
		visibility = mix(1.0, visibility * XE_GTAO_OCCLUSION_TERM_SCALE, params.intensity);
	}
	imageStore(out_ao, pixel, vec4(clamp(visibility, 0.0, 1.0)));
}
