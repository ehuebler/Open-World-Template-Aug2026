class_name MeepBlueprintSettlement
extends SurfaceAnchor

## The only physical part of a city blueprint. Its hull-sized interaction body
## lets E find the local planning menu; projected roads and buildings remain
## draw-only.

var blueprint_id: StringName = &""
var registry: MeepBlueprintPreviewRegistry

var _body: StaticBody3D


func configure(host: Planet, previews: MeepBlueprintPreviewRegistry,
		id: StringName, at_direction: Vector3, at_facing: float) -> void:
	planet = host
	registry = previews
	blueprint_id = id
	direction = at_direction.normalized()
	facing = at_facing
	clearance = SettlementShip.FOOTPRINT.y * 0.5
	name = "BlueprintSettlement_%s" % id
	_raise_marker()


func _ready() -> void:
	super()
	if _body == null:
		_raise_marker()


func _raise_marker() -> void:
	if _body != null:
		return
	var hull := MeshInstance3D.new()
	hull.name = "BlueprintHull"
	var mesh := BoxMesh.new()
	mesh.size = SettlementShip.FOOTPRINT
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.18, 0.72, 1.0, 0.32)
	material.emission_enabled = true
	material.emission = Color(0.08, 0.45, 1.0)
	material.emission_energy_multiplier = 1.4
	material.metallic = 0.18
	material.roughness = 0.42
	mesh.material = material
	hull.mesh = mesh
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hull)

	_body = StaticBody3D.new()
	_body.name = "BlueprintInteraction"
	_body.collision_layer = 1
	_body.collision_mask = 0
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SettlementShip.FOOTPRINT
	collider.shape = box
	_body.add_child(collider)
	add_child(_body)


func interact_prompt() -> String:
	return "Edit Blueprint City"


func interact(player: OnlinePlayer) -> void:
	if player != null and registry != null \
			and registry.has_blueprint(blueprint_id):
		player.open_blueprint_city_menu(blueprint_id)


func collision_enabled() -> bool:
	return _body != null and _body.collision_layer != 0
