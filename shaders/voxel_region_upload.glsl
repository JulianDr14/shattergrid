#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, r8ui) uniform restrict writeonly uimage3D destination_image;
layout(set = 0, binding = 1, std430) readonly buffer SourceBytes {
	uint words[];
} source_data;

layout(push_constant, std430) uniform Params {
	ivec4 destination;
	ivec4 source_size;
	ivec4 source_offset;
} params;

void main() {
	ivec3 local = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 copy_size = ivec3(
		params.destination.w, params.source_size.w, params.source_offset.w
	);
	if (any(greaterThanEqual(local, copy_size))) {
		return;
	}
	ivec3 source = params.source_offset.xyz + local;
	uint byte_index = uint(source.x + source.y * params.source_size.x
		+ source.z * params.source_size.x * params.source_size.y);
	uint word = source_data.words[byte_index >> 2u];
	uint value = (word >> ((byte_index & 3u) * 8u)) & 255u;
	imageStore(destination_image, params.destination.xyz + local, uvec4(value, 0u, 0u, 1u));
}
