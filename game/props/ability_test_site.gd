class_name AbilityTestSite
extends Landmark

## A visible, non-colliding practice pad for destructive abilities. The HUD
## waypoint gets players here; the tall cyan beacon and ground ring identify the
## site after the waypoint moves out of the centre of the view.

const SITE_COLOUR := Color("58e0c2")
const PAD_COLOUR := Color("233d43")
const PAD_RADIUS := 13.0


func _ready() -> void:
	super()
	_build_pad()


func _build_pad() -> void:
	var pad_material := StandardMaterial3D.new()
	pad_material.albedo_color = PAD_COLOUR
	pad_material.metallic = 0.18
	pad_material.roughness = 0.78

	var glow_material := StandardMaterial3D.new()
	glow_material.albedo_color = SITE_COLOUR
	glow_material.emission_enabled = true
	glow_material.emission = SITE_COLOUR
	glow_material.emission_energy_multiplier = 1.4
	glow_material.roughness = 0.42

	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = PAD_RADIUS - 0.34
	ring_mesh.outer_radius = PAD_RADIUS
	ring_mesh.rings = 64
	ring_mesh.ring_segments = 8
	ring_mesh.material = glow_material
	_add_mesh(&"BoundaryRing", ring_mesh, Vector3.UP * 0.13)

	for lane in [-5.0, 0.0, 5.0]:
		var stripe_mesh := BoxMesh.new()
		stripe_mesh.size = Vector3(0.12, 0.04, 7.5)
		stripe_mesh.material = glow_material
		_add_mesh(
			StringName("Lane%+d" % int(lane)),
			stripe_mesh, Vector3(lane, 0.13, 1.5))

	var mast_mesh := CylinderMesh.new()
	mast_mesh.top_radius = 0.14
	mast_mesh.bottom_radius = 0.22
	mast_mesh.height = 8.0
	mast_mesh.radial_segments = 12
	mast_mesh.material = pad_material
	_add_mesh(&"BeaconMast", mast_mesh, Vector3(0.0, 4.0, 9.5))

	var beacon_mesh := SphereMesh.new()
	beacon_mesh.radius = 0.62
	beacon_mesh.height = 1.24
	beacon_mesh.radial_segments = 20
	beacon_mesh.rings = 10
	beacon_mesh.material = glow_material
	_add_mesh(&"Beacon", beacon_mesh, Vector3(0.0, 8.2, 9.5))

	var light := OmniLight3D.new()
	light.name = &"BeaconLight"
	light.position = Vector3(0.0, 8.2, 9.5)
	light.light_color = SITE_COLOUR
	light.light_energy = 2.0
	light.omni_range = 24.0
	light.shadow_enabled = false
	add_child(light, false, Node.INTERNAL_MODE_BACK)

	var label := Label3D.new()
	label.name = &"SiteLabel"
	label.position = Vector3(0.0, 9.4, 9.5)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = SITE_COLOUR
	label.outline_modulate = Color("071216")
	label.font_size = 48
	label.outline_size = 10
	label.text = "ABILITY TEST SITE"
	add_child(label, false, Node.INTERNAL_MODE_BACK)


func _add_mesh(node_name: StringName, mesh: Mesh,
		at: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.position = at
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance, false, Node.INTERNAL_MODE_BACK)
	return instance
