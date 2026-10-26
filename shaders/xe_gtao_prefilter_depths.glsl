#[compute]
#version 450

// XeGTAO depth prefilter, MIP 0: converts the depth buffer to linear
// view-space depth. Port of XeGTAO (Copyright (C) 2016-2021, Intel
// Corporation, MIT licence, see LICENSE.XeGTAO.txt).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D out_depth;

// The start of Godot's scene data uniform buffer. Its inverse projection
// matches the depth convention of whichever rendering backend is in use.
layout(set = 0, binding = 2, std140) uniform SceneDataBlock {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
} scene_data;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	vec2 pad;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	float depth = texelFetch(source_depth, pixel, 0).r;
	vec4 view = scene_data.inv_projection_matrix * vec4(0.0, 0.0, depth, 1.0);
	// XeGTAO's view space looks along +Z; Godot's along -Z.
	imageStore(out_depth, pixel, vec4(-view.z / view.w));
}
