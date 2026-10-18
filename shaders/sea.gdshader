shader_type spatial;
// Cheap stylised sea: two sine bands for colour variation + shore foam.
render_mode cull_disabled;

uniform vec3 deep_color : source_color = vec3(0.17, 0.52, 0.72);
uniform vec3 shallow_color : source_color = vec3(0.38, 0.78, 0.86);
uniform float shore_x = -40.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float w = sin(world_pos.x * 0.35 + TIME * 1.1) * 0.5 + sin(world_pos.z * 0.27 - TIME * 0.8) * 0.5;
	float near_shore = 1.0 - smoothstep(0.0, 35.0, shore_x - world_pos.x);
	vec3 col = mix(deep_color, shallow_color, clamp(near_shore * 0.8 + w * 0.12, 0.0, 1.0));
	float foam_edge = 2.5 + sin(TIME * 1.3 + world_pos.z * 0.25) * 1.2;
	float foam = 1.0 - smoothstep(0.0, foam_edge, shore_x - world_pos.x);
	ALBEDO = mix(col, vec3(0.97), foam * 0.85);
	ROUGHNESS = 0.3;
	SPECULAR = 0.6;
}
