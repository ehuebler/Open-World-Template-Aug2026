// The wall of compressed air a meteor punch pushes ahead of its fist.
//
// Drawn the way a real one is seen rather than the way it is shaped. A bow
// shock is a surface, not a volume: looked at face on there is nothing there,
// and looked at edge on you are seeing through metres of squeezed air, which is
// why the whole thing reads as a bright rim around a clear middle. That is a
// Fresnel term and it is doing almost all of the work here — without it a dome
// mesh is a dome, and no amount of colour makes it look like weather.
//
// Premultiplied alpha rather than additive. Additive alone vanishes against
// bright ground, which on this planet is most of the ground; mix alone reads as
// painted plastic. Premultiplied gives both at once: the colour is added, so it
// glows, and the alpha still takes some of the background out behind it, so the
// shell has body over pale sand as well as over night.
shader_type spatial;
render_mode blend_premul_alpha, depth_draw_never, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

group_uniforms Shell;
uniform vec3 tint : source_color = vec3(1.0, 0.09, 0.04);
// Hot enough at the rim to bloom. Almost none of the shell reaches this; the
// Fresnel below is what decides how much of it any given pixel gets, and the
// answer for most of them is nearly none.
uniform float energy : hint_range(0.0, 24.0) = 3.0;
// How hard the shell hides face on. Higher is a thinner, sharper rim. This is
// the number that decides whether the effect is weather or a red balloon: the
// dome is eight metres across and the player has to be able to see the world
// through it.
uniform float rim_power : hint_range(0.5, 16.0) = 7.5;
// The trailing circle, drawn whichever way it is looked at. On a shell this
// wide the Fresnel alone only lights the two points of the rim that happen to
// be edge on, and the shape is read from the whole ring.
uniform float edge_gain : hint_range(0.0, 4.0) = 1.7;
group_uniforms;

group_uniforms Air;
// Shells of air stacked through the front, travelling back off the nose.
uniform float band_count : hint_range(0.0, 24.0) = 6.0;
uniform float band_speed : hint_range(0.0, 12.0) = 3.2;
uniform float band_depth : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

group_uniforms Drive;
// Nothing at all at zero. Everything the punch does to this — fading it in at
// the launch, out at the landing, and leaning on it as the speed builds — comes
// through here, so the material has one input and the movement code owns it.
uniform float strength : hint_range(0.0, 1.0) = 0.0;
group_uniforms;

void fragment() {
	// Zero at the nose of the dome, one at its open trailing rim, written into
	// V by the code that builds the surface. Everything below is placed along
	// it, so stretching the dome as the punch accelerates slides nothing.
	float along = UV.y;

	// A shell is only visible where you are looking along it. Face on there is
	// nothing there; at a grazing angle you are seeing through metres of
	// squeezed air, and that is the bright edge the shape is read from.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - facing, rim_power);

	float phase = (along * band_count - TIME * band_speed) * 6.2831853;
	float bands = 1.0 - band_depth * 0.5 * (1.0 + sin(phase));

	// Faded at both ends. The nose is a single point the mesh cannot resolve,
	// and air running out of somewhere to be compressed does not stop on a
	// line.
	float ends = smoothstep(0.0, 0.2, along)
		* (1.0 - smoothstep(0.72, 1.0, along));
	float shell = rim * bands * ends;

	// The trailing circle, kept out of the fade above because it is the one
	// part that has to survive being looked at face on.
	float ring = edge_gain * smoothstep(0.70, 0.90, along)
		* (1.0 - smoothstep(0.90, 1.0, along)) * bands;

	float amount = clamp((shell + ring) * strength, 0.0, 1.0);
	ALBEDO = tint * energy * amount;
	// Well under the colour, so the shell glows far more than it occludes. A
	// shock that hid what was behind it would read as a solid object, and the
	// player is about to fly through whatever that is.
	ALPHA = amount * 0.2;
}
