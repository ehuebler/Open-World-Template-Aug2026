shader_type canvas_item;

// Bleach and colour inversion for standing inside a detonation.
//
// This reads the frame underneath it rather than tinting over the top, because
// that is the only way to invert: a blend mode can lighten or darken what has
// already been drawn but cannot turn it inside out. It draws over the world and
// the reticle and under the damage flash and the readouts, so what goes negative
// is what the player is looking at and not the numbers telling them about it.

uniform sampler2D frame : hint_screen_texture, repeat_disable, filter_nearest;

// Nothing at zero, the exact negative of the frame at one.
uniform float invert : hint_range(0.0, 1.0) = 0.0;
// A wash laid over the top of that, for the instant of the flash itself.
uniform float bleach : hint_range(0.0, 1.0) = 0.0;
uniform vec3 wash : source_color = vec3(1.0, 0.96, 0.9);

void fragment() {
	vec3 seen = texture(frame, SCREEN_UV).rgb;
	vec3 shown = mix(seen, vec3(1.0) - seen, invert);
	COLOR = vec4(mix(shown, wash, bleach), 1.0);
}
