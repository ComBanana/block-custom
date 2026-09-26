shader_type spatial;
render_mode diffuse_burley, specular_disabled, cull_back;

uniform sampler2D grass_top_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D grass_side_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D dirt_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D stone_texture : source_color, filter_nearest, repeat_disable;
uniform sampler2D sand_texture : source_color, filter_nearest, repeat_disable;

vec4 sample_block_texture(float encoded_x, float y) {
	float layer_f = floor(encoded_x / 2.0 + 0.0001);
	float local_u = encoded_x - layer_f * 2.0;
	vec2 block_uv = vec2(local_u, y);
	int layer = int(layer_f + 0.5);

	if (layer == 0) {
		return texture(grass_top_texture, block_uv);
	}
	if (layer == 1) {
		return texture(grass_side_texture, block_uv);
	}
	if (layer == 2) {
		return texture(dirt_texture, block_uv);
	}
	if (layer == 3) {
		return texture(stone_texture, block_uv);
	}

	return texture(sand_texture, block_uv);
}

void fragment() {
	vec4 albedo = sample_block_texture(UV.x, UV.y);
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
}
