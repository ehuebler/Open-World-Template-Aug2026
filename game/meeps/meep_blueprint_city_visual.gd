class_name MeepBlueprintCityVisual
extends Node3D

## Production city presentation rebuilt from a local projection snapshot. Roads,
## lamps, lights and structures use their normal renderers; collision/proxy and
## flora-clearance paths are explicitly disabled.

var blueprint_id: StringName = &""
var planet: Planet
var direction := Vector3.UP
var facing := 0.0
var city_seed := 0

var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim
var city_plan: MeepCityPlan
var roads: MeepRoads
var structures: MeepStructures
var boundary: MeepBoundaryWall


func configure(host: Planet, id: StringName,
		at_direction: Vector3, at_facing: float, seed: int) -> void:
	planet = host
	blueprint_id = id
	direction = at_direction.normalized()
	facing = at_facing
	city_seed = seed
	name = "BlueprintCityVisual_%s" % id


func apply_projection(projection: Dictionary) -> void:
	if planet == null or planet.shape == null or projection.is_empty():
		return
	_clear_visuals()
	site = MeepSite.new(direction, planet.shape.radius, facing,
		MeepColony.MAX_CLAIM_RADIUS)
	var ground_value: Variant = projection.get("ground", {})
	if not ground_value is Dictionary:
		return
	grid = MeepCityProjection.grid_from_ground(
		site, ground_value as Dictionary)
	if grid == null:
		return
	grid.bind_region_masks(
		projection.get("owner_mask", PackedByteArray()),
		projection.get("setback_mask", PackedByteArray()), 0)
	claim = MeepClaim.new()
	claim.build(grid, Vector2.ZERO,
		float(projection.get(
			"claim_radius", MeepClaim.DEFAULT_RADIUS)))
	city_plan = MeepCityPlan.new()
	var plan_value: Variant = projection.get("city_plan", {})
	if plan_value is Dictionary:
		city_plan.apply_snapshot(plan_value as Dictionary)
	city_plan.configure(grid, claim, city_seed, null, null,
		MeepColony.MAX_CLAIM_RADIUS)
	city_plan.reflow_region_clip()
	_apply_plan_masks()
	claim.build(grid, Vector2.ZERO,
		float(projection.get(
			"claim_radius", MeepClaim.DEFAULT_RADIUS)))

	roads = MeepRoads.new()
	roads.configure(site, grid, claim, planet.shape, planet,
		city_seed, true, false, false)
	roads.set_centre_exclusion_radius(
		MeepColony.SHIP_NAVIGATION_RADIUS)
	add_child(roads)
	roads.apply_snapshot(projection.get(
		"roads", PackedInt32Array()))
	roads.apply_width_snapshot(projection.get(
		"road_widths", PackedInt32Array()))
	roads.apply_surface_snapshot(projection.get(
		"road_surfaces", PackedInt32Array()))

	structures = MeepStructures.new()
	structures.configure(site, grid, claim, planet.shape, planet,
		null, roads, true, false)
	add_child(structures)
	structures.apply_snapshot(projection.get(
		"structures", PackedInt32Array()))
	structures.apply_progress(projection.get(
		"raised", PackedFloat32Array()))
	structures.apply_form_snapshot(
		projection.get("structure_forms", PackedInt32Array()),
		projection.get("structure_upgrades", PackedFloat32Array()))
	structures.draw()
	roads.draw(0)

	boundary = MeepBoundaryWall.new()
	boundary.name = "BlueprintBoundary"
	boundary.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(boundary)
	boundary.raise(site, claim, planet.shape, planet.finest_spacing())


func _process(delta: float) -> void:
	if roads == null or site == null or planet == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var local_eye := planet.to_local(camera.global_position)
	if local_eye.length_squared() < 1.0:
		return
	roads.update_lights(delta,
		site.to_local(local_eye.normalized()))


func _apply_plan_masks() -> void:
	if city_plan == null or grid == null or claim == null:
		return
	var parks := city_plan.park_mask()
	var lots := city_plan.planned_lot_mask()
	for index in grid.cells * grid.cells:
		var now := int(grid.flags[index]) & ~(
			MeepGrid.FLAG_PARK | MeepGrid.FLAG_PLANNED_LOT)
		if index < parks.size() and parks[index] != 0:
			now |= MeepGrid.FLAG_PARK
		if index < lots.size() and lots[index] != 0:
			now |= MeepGrid.FLAG_PLANNED_LOT
		grid.flags[index] = now
	grid.revision += 1
	claim.bind_permit_mask(
		city_plan.permit_mask(), city_plan.permit_revision())


func _clear_visuals() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	roads = null
	structures = null
	boundary = null
	grid = null
	claim = null
	city_plan = null


func has_gameplay_collision() -> bool:
	if roads != null and roads.find_child(
			"RoadCollision", true, false) != null:
		return true
	if structures != null and structures.find_children(
			"*", "CollisionObject3D", true, false).size() > 0:
		return true
	return false
