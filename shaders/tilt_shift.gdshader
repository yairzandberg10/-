shader_type canvas_item;
// Photo mode "miniature" look: blur the top and bottom of the screen and
// boost saturation, like a tilt-shift lens. Only active while enabled.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float focus_center = 0.55;
uniform float focus_width = 0.16;
uniform float blur = 3.5;
uniform float saturation = 1.25;

void fragment() {
	vec2 uv = SCREEN_UV;
	float d = abs(uv.y - focus_center);
	float amt = smoothstep(focus_width, focus_width + 0.3, d) * blur;
	vec2 px = SCREEN_PIXEL_SIZE * amt;
	vec3 c = texture(screen_tex, uv).rgb;
	if (amt > 0.05) {
		c += texture(screen_tex, uv + vec2(px.x, 0.0)).rgb;
		c += texture(screen_tex, uv - vec2(px.x, 0.0)).rgb;
		c += texture(screen_tex, uv + vec2(0.0, px.y)).rgb;
		c += texture(screen_tex, uv - vec2(0.0, px.y)).rgb;
		c += texture(screen_tex, uv + px * 0.7).rgb;
		c += texture(screen_tex, uv - px * 0.7).rgb;
		c += texture(screen_tex, uv + vec2(px.x, -px.y) * 0.7).rgb;
		c += texture(screen_tex, uv + vec2(-px.x, px.y) * 0.7).rgb;
		c /= 9.0;
	}
	float g = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(g), c, saturation);
	float vig = smoothstep(0.95, 0.35, distance(uv, vec2(0.5)));
	COLOR = vec4(c * mix(0.85, 1.0, vig), 1.0);
}
