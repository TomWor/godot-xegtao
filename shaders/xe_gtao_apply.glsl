#[compute]
#version 450

// XeGTAO "multiply" apply mode: darkens the rendered HDR colour by the
// ambient occlusion, for materials that can't sample the AO themselves.
// Sky pixels (depth at the far plane) are left alone.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D ao_texture;
layout(set = 0, binding = 2) uniform sampler2D viewspace_depth;

// The start of Godot's scene data uniform buffer.
layout(set = 0, binding = 3, std140) uniform SceneDataBlock {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
} scene_data;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	float intensity;
	float pad;
} params;

float view_depth(float buffer_depth) {
	vec4 view = scene_data.inv_projection_matrix * vec4(0.0, 0.0, buffer_depth, 1.0);
	return -view.z / view.w;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	// Whichever end of the depth range is the far plane, depending on the backend.
	float far_depth = max(view_depth(0.0), view_depth(1.0));
	if (texelFetch(viewspace_depth, pixel, 0).r >= far_depth * 0.999) {
		return;
	}
	float ao = texelFetch(ao_texture, pixel, 0).r;
	vec4 color = imageLoad(color_image, pixel);
	color.rgb *= mix(1.0, ao, params.intensity);
	imageStore(color_image, pixel, color);
}
