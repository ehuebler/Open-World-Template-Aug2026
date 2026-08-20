extends Node

## Headless checks for fauna data, deterministic colony populations, procedural
## visuals, skeletal clip playback, grazing, bounding flight, provoked strafing,
## the spit projectile, contact damage, body-slap damage, and combat health.
##
##     godot --headless --path . dev/_fauna_test.tscn

const POPULATIONS := preload("res://game/fauna/fauna_populations.tscn")
const PORCUPINE := preload(
	"res://game/fauna/species/lumaquill_porcupine.tres")
const SLINKY := preload("res://game/fauna/species/prism_coil_slinky.tres")
const ALPACA := preload(
	"res://game/fauna/species/aurora_fleece_alpaca.tres")
const RHINO := preload("res://game/fauna/species/cinder_plate_rhino.tres")
const PLAYER := preload("res://game/player/player.tscn")
const COLONY_DIRECTION := Vector3(-0.2881049, -0.1121179, 0.9510127)

var _failures := 0


class TestWorld extends GameWorld:
	func _ready() -> void:
		pass


class TestCycle extends CelestialCycle:
	func _ready() -> void:
		set_process(false)


class TestPlanet extends Planet:
	var test_viewer := Vector3.ZERO

	func _ready() -> void:
		if shape == null:
			shape = PlanetShape.new()
		shape.prepare()
		set_process(false)
		set_physics_process(false)

	func viewer_position() -> Vector3:
		return test_viewer

	func finest_spacing() -> float:
		return 1.5


class TestSpawner extends FaunaSpawner:
	func _ready() -> void:
		pass


class TestPlayer extends CharacterBody3D:
	var peer_id := 1
	var damage_taken := 0.0

	func _ready() -> void:
		add_to_group(&"network_players")
		add_to_group(DamageHit.COMBATANT_GROUP)

	func combat_faction() -> int:
		return DamageHit.Faction.PLAYER

	func combat_peer_id() -> int:
		return peer_id

	func combat_position() -> Vector3:
		return global_position

	func combat_radius() -> float:
		return 0.4

	func is_dead() -> bool:
		return false

	func apply_damage(hit: DamageHit) -> float:
		var actual := maxf(hit.amount, 0.0)
		damage_taken += actual
		return actual


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var world := TestWorld.new()
	world.name = "TestWorld"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	world.add_child(spawn_points)
	var cycle := TestCycle.new()
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	add_child(world)
	var planet := TestPlanet.new()
	planet.name = "Planet"
	planet.shape = PlanetShape.new()
	world.add_child(planet)
	await get_tree().process_frame

	var direction := COLONY_DIRECTION.normalized()
	var colony := Node3D.new()
	colony.name = "ColonyShip"
	colony.position = planet.shape.surface_point(
		direction, planet.finest_spacing())
	planet.add_child(colony)
	planet.test_viewer = colony.position + direction * 4.0

	var spawner := POPULATIONS.instantiate() as FaunaSpawner
	planet.add_child(spawner)
	for _frame in 30:
		await get_tree().process_frame
		await get_tree().physics_frame

	_check_species_contracts()
	_expect(spawner != null, "population scene instantiates FaunaSpawner")
	if spawner != null:
		_check_population(spawner)
		await _check_population_lifecycle(spawner, planet)
		await _check_meep_attack_paths(spawner, planet)
		await _check_combat(spawner, planet)
		await _check_alpaca(spawner, planet)
		await _check_rhino(spawner, planet)
		await _check_rhino_den(spawner, planet)

	world.queue_free()
	await get_tree().process_frame
	print("fauna_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_species_contracts() -> void:
	_expect(PORCUPINE.validate().is_empty(),
		"porcupine resource satisfies runtime asset contract")
	_expect(SLINKY.validate().is_empty(),
		"slinky resource satisfies runtime asset contract")
	_expect(PORCUPINE.disposition == FaunaSpecies.Disposition.PASSIVE
		and PORCUPINE.attack_style == FaunaSpecies.AttackStyle.CONTACT,
		"porcupine is passive with contact quills")
	_expect(PORCUPINE.has_move(FaunaSpecies.Move.WALK)
		and PORCUPINE.has_move(FaunaSpecies.Move.RUN)
		and PORCUPINE.has_move(FaunaSpecies.Move.ATTACK),
		"porcupine exposes walk, run, and contact attack moves")
	_expect(PORCUPINE.enabled and PORCUPINE.quadruped_gait
		and PORCUPINE.body_rock_degrees > 0.0,
		"porcupine population has procedural legs and body rock")
	_expect(not SLINKY.enabled,
		"slinky definition remains catalogued but is disabled")
	_expect(PORCUPINE.paint_texture != null and SLINKY.paint_texture != null
		and ALPACA.paint_texture != null,
		"every species samples an external runtime color-paint PNG")
	_expect(PORCUPINE.night_emission_energy > 0.0
		and SLINKY.night_emission_energy > 0.0
		and ALPACA.night_emission_energy > 0.0,
		"every species has authored night emission")
	_expect(ALPACA.validate().is_empty(),
		"alpaca resource satisfies runtime asset contract")
	_expect(ALPACA.disposition == FaunaSpecies.Disposition.FRIENDLY
		and ALPACA.attack_style == FaunaSpecies.AttackStyle.SPIT
		and ALPACA.provoked_seconds > 0.0,
		"alpaca is friendly and only spits once it has been provoked")
	_expect(ALPACA.skeletal_clips and not ALPACA.quadruped_gait,
		"alpaca is posed by its skeleton rather than by the shader gait")
	_expect(ALPACA.graze and ALPACA.bound_when_fleeing,
		"alpaca grazes while idle and bounds away when crowded")
	_expect(not ALPACA.global_population and ALPACA.colony_count > 0,
		"alpaca is a colony-site test population only")
	_expect(RHINO.validate().is_empty(),
		"rhino resource satisfies runtime asset contract")
	_expect(RHINO.disposition == FaunaSpecies.Disposition.HOSTILE
		and RHINO.attack_style == FaunaSpecies.AttackStyle.HORN_CHARGE,
		"rhino is hostile and attacks by charging")
	_expect(RHINO.skeletal_clips and not RHINO.quadruped_gait
		and RHINO.charge_speed > RHINO.run_speed
		and RHINO.notice_range >= RHINO.charge_from,
		"rhino is skeletal, charges faster than it runs, and sees far enough")
	_expect(RHINO.settlement_edge and RHINO.edge_margin_near > 0.0
		and not RHINO.global_population,
		"rhino is a settlement-frontier population only")
	_expect(PORCUPINE.reproduces and ALPACA.reproduces and RHINO.reproduces
		and PORCUPINE.population_limit >= 2
		and ALPACA.newborn_scale < 1.0 and RHINO.growth_seconds > 0.0,
		"friendly, passive, and hostile fauna all share the reproduction contract")


func _check_population(spawner: FaunaSpawner) -> void:
	_expect(spawner.colony_actor_count()
		== PORCUPINE.colony_count + ALPACA.colony_count + RHINO.colony_count,
		"every catalogued colony creature spawns near Colony Ship")
	_expect(spawner.species_count("lumaquill_porcupine") >= 4,
		"porcupine colony population is live")
	_expect(spawner.species_count("aurora_fleece_alpaca")
		== ALPACA.colony_count,
		"alpaca herd is live at the colony site")
	_expect(spawner.species_count("cinder_plate_rhino")
		== RHINO.colony_count,
		"rhino herd is live on the settlement frontier")
	_expect(spawner.species_count("prism_coil_slinky") == 0,
		"disabled slinky population creates no actors")
	print("fauna_test: colony spawn %.2f ms, %d terrain checks" % [
		float(spawner.last_colony_micros()) / 1000.0,
		spawner.last_colony_placement_checks(),
	])
	spawner.call(&"_survey_global")
	print("fauna_test: global survey %.2f ms, %d terrain checks" % [
		float(spawner.last_survey_micros()) / 1000.0,
		spawner.last_survey_placement_checks(),
	])
	_expect(spawner.last_survey_placement_checks() <= 400,
		"global survey terrain work stays bounded")
	_expect(spawner.light_pool_size() == 7,
		"night glow uses its bounded physical-light pool")
	_expect(spawner.fauna_snapshot().size() == spawner.actor_count(),
		"fauna snapshot covers every live host actor")
	for mob_variant: Variant in get_tree().get_nodes_in_group(&"fauna_mobs"):
		var mob := mob_variant as FaunaMob
		if mob == null or not spawner.is_ancestor_of(mob):
			continue
		_expect(mob.find_children(
			"*", "MeshInstance3D", true, false).size() == 1,
			"%s has one runtime mesh" % mob.mob_id)


## An isolated hostile population proves the full replacement rule without
## changing the showcase herds used by the movement and combat checks below.
func _check_population_lifecycle(spawner: FaunaSpawner,
		planet: Planet) -> void:
	var template := _first_mob(spawner, "cinder_plate_rhino")
	_expect(template != null, "lifecycle fixture has an authored hostile transform")
	if template == null:
		return
	var definition := RHINO.duplicate(true) as FaunaSpecies
	definition.species_id = "test_breeding_rhino"
	definition.population_limit = 3
	definition.mate_search_range = 24.0
	definition.mate_distance = 2.15
	definition.mate_cooldown = 4.0
	definition.courtship_seconds = 0.8
	definition.newborn_scale = 0.4
	definition.growth_seconds = 2.0
	definition.prepare()

	var lifecycle := TestSpawner.new()
	lifecycle.name = "LifecycleSpawner"
	lifecycle.species = [definition]
	lifecycle.set(&"_planet", planet)
	var registry := lifecycle.get(&"_species_by_id") as Dictionary
	registry[definition.species_id] = definition
	planet.add_child(lifecycle)
	lifecycle.set_process(false)

	var first_record := _fauna_record(
		definition, "last_survivor", 901, template.global_transform)
	var second_transform := template.global_transform
	second_transform.origin = _surface_near(
		planet, template.global_position + _flat_forward(template, planet) * 4.0)
	var second_record := _fauna_record(
		definition, "doomed_partner", 902, second_transform)
	lifecycle.call(&"_spawn_authoritative", first_record, false)
	lifecycle.call(&"_spawn_authoritative", second_record, false)
	var survivor := lifecycle.actor("last_survivor")
	var doomed := lifecycle.actor("doomed_partner")
	survivor.set_physics_process(false)
	doomed.set_physics_process(false)

	var fatal := DamageHit.impact(doomed.combat_position(), 2.0, 10000.0)
	fatal.faction = DamageHit.Faction.PLAYER
	doomed.apply_damage(fatal)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(lifecycle.actor("doomed_partner") == null
		and lifecycle.is_permanently_dead("doomed_partner"),
		"a dead mob is retired and leaves a permanent population tombstone")
	lifecycle.call(&"_spawn_authoritative", second_record, false)
	_expect(lifecycle.actor("doomed_partner") == null,
		"streaming the dead mob's old area cannot respawn that individual")

	survivor.set(&"_mate_cooldown_left", 0.0)
	lifecycle.call(&"_survey_mating")
	_expect(not survivor.has_courtship_partner()
		and lifecycle.living_species_count(definition.species_id) == 1,
		"one remaining member of a species cannot reproduce")

	var partner_transform := survivor.global_transform
	var forward := _flat_forward(survivor, planet)
	partner_transform.origin = _surface_near(
		planet, survivor.global_position + forward * 6.0)
	var partner_record := _fauna_record(
		definition, "new_partner", 903, partner_transform)
	lifecycle.call(&"_spawn_authoritative", partner_record, false)
	var partner := lifecycle.actor("new_partner")
	partner.set_physics_process(false)
	survivor.set(&"_mate_cooldown_left", 0.0)
	partner.set(&"_mate_cooldown_left", 0.0)
	lifecycle.call(&"_survey_mating")
	_expect(survivor.is_courting_with(partner),
		"two available hostile adults decide to walk together and mate")

	var distance_before := survivor.global_position.distance_to(
		partner.global_position)
	survivor.call(&"_update_courtship", 0.2)
	partner.call(&"_update_courtship", 0.2)
	_expect(survivor.motion_state() == FaunaMob.MotionState.COURTSHIP
		and partner.motion_state() == FaunaMob.MotionState.COURTSHIP
		and survivor.global_position.distance_to(partner.global_position)
			< distance_before,
		"the chosen pair walks toward one another")
	forward = _flat_forward(survivor, planet)
	partner.global_position = _surface_near(
		planet, survivor.global_position + forward * definition.mate_distance)
	survivor.velocity = Vector3.ZERO
	partner.velocity = Vector3.ZERO
	for _step in 12:
		survivor.call(&"_update_courtship", 0.05)
		partner.call(&"_update_courtship", 0.05)
	var toward_partner := (partner.global_position
		- survivor.global_position).normalized()
	var face_a := -survivor.global_basis.z.dot(toward_partner)
	var face_b := -partner.global_basis.z.dot(-toward_partner)
	_expect(survivor.motion_state() == FaunaMob.MotionState.MATE
		and partner.motion_state() == FaunaMob.MotionState.MATE
		and face_a > 0.5 and face_b > 0.5,
		"the mating pair stops and looks face-to-face")

	for _step in 16:
		if lifecycle.living_species_count(definition.species_id) >= 3:
			break
		survivor.call(&"_update_courtship", 0.05)
		if partner.has_courtship_partner():
			partner.call(&"_update_courtship", 0.05)
	var baby: FaunaMob
	for id in lifecycle.actor_ids():
		if id.begins_with("b_%s_" % definition.species_id):
			baby = lifecycle.actor(id)
			break
	var hearts := lifecycle.find_children("*", "FaunaMatingHeart", true, false)
	_expect(baby != null and not hearts.is_empty(),
		"a heart rises and one newborn appears after courtship")
	if baby != null:
		baby.set_physics_process(false)
		var newborn_height := baby.instance_height()
		var newborn_health := baby.maximum_health()
		_expect(is_equal_approx(baby.growth_share(), definition.newborn_scale)
			and newborn_height < baby.adult_height() * 0.5,
			"the newborn starts as a visibly smaller member of its species")
		baby.call(&"_advance_growth", definition.growth_seconds + 0.1)
		_expect(baby.is_adult()
			and is_equal_approx(baby.instance_height(), baby.adult_height())
			and baby.maximum_health() > newborn_health,
			"the juvenile grows to regular adult size and vitality")
	var saved := lifecycle.sandbox_snapshot()
	var dead_ids: Array = saved.get("dead", []) as Array
	_expect(dead_ids.has("doomed_partner")
		and int(saved.get("birth_sequence", 0)) >= 1,
		"death tombstones and newborn ids persist in fauna save state")

	lifecycle.queue_free()
	await get_tree().process_frame


## Each ordinary fauna attack family is driven through the same host combat path
## used in play, against real data-oriented Meep rows rather than a test double.
func _check_meep_attack_paths(spawner: FaunaSpawner, planet: Planet) -> void:
	var rhino_template := _first_mob(spawner, "cinder_plate_rhino")
	var porcupine_template := _first_mob(spawner, "lumaquill_porcupine")
	var alpaca_template := _first_mob(spawner, "aurora_fleece_alpaca")
	_expect(rhino_template != null and porcupine_template != null
		and alpaca_template != null,
		"fauna attack fixtures have live authored transforms")
	if rhino_template == null or porcupine_template == null \
			or alpaca_template == null:
		return

	# No player is present here. The normal think pass must discover one concrete
	# row inside the aggregate colony, keep it through the windup, and finish the
	# same charge path used against a player without the harness naming the row.
	var hunter := _attack_fixture(
		planet, RHINO, rhino_template.global_transform, "meep_hunter_fixture", 700)
	var hunter_forward := _flat_forward(hunter, planet)
	var prey_surface := _surface_near(
		planet, hunter.global_position + hunter_forward * 12.0)
	var prey_colony := _combat_colony(
		planet, [prey_surface], "AutonomousMeepTarget", 800)
	hunter.set(&"_think_left", 0.0)
	hunter.call(&"_update_behaviour", 0.2)
	var chose_meep: bool = hunter.motion_state() == FaunaMob.MotionState.PAW \
		and hunter.get(&"_target_actor") == prey_colony \
		and int(hunter.get(&"_target_row")) == 0 \
		and int(hunter.get(&"_target_peer")) == 0
	_expect(chose_meep,
		"a hostile rhino autonomously chooses an individual Meep when no player is near")
	hunter.call(&"_update_paw", RHINO.attack_windup + 0.05)
	var charged_meep: bool = \
		hunter.motion_state() == FaunaMob.MotionState.CHARGE
	for _step in 80:
		if hunter.motion_state() != FaunaMob.MotionState.CHARGE \
				or prey_colony.meep_health(0) <= 0.0:
			break
		hunter.call(&"_update_charge", 0.05)
	_expect(charged_meep and prey_colony.meep_health(0) <= 0.0,
		"the autonomous horn charge follows and attacks its chosen Meep")
	prey_colony.queue_free()
	hunter.queue_free()
	await get_tree().process_frame

	var horn := _attack_fixture(
		planet, RHINO, rhino_template.global_transform, "meep_horn_fixture", 701)
	var horn_forward := _flat_forward(horn, planet)
	var horn_surface := _surface_near(
		planet, horn.global_position + horn_forward * 1.2)
	var horn_colony := _combat_colony(
		planet, [horn_surface], "HornTarget", 801)
	var horn_before := horn_colony.meep_health(0)
	var horn_connected := bool(horn.call(&"_try_horn_damage"))
	_expect(horn_connected and horn_colony.meep_health(0) < horn_before
		and horn_colony.meep_state(0) == MeepColony.State.DEAD,
		"horn charge dispatch reaches and can kill an intersecting Meep row")
	horn_colony.queue_free()
	horn.queue_free()
	await get_tree().process_frame

	var slap := _attack_fixture(
		planet, SLINKY, rhino_template.global_transform, "meep_slap_fixture", 702)
	var slap_forward := _flat_forward(slap, planet)
	var slap_surface := _surface_near(
		planet, slap.global_position + slap_forward * 1.2)
	var slap_colony := _combat_colony(
		planet, [slap_surface], "SlapTarget", 802)
	var slap_before := slap_colony.meep_health(0)
	slap.call(&"_apply_body_slap")
	_expect(is_equal_approx(
		slap_before - slap_colony.meep_health(0), SLINKY.attack_damage)
		and slap_colony.meep_state(0) == MeepColony.State.FLEE,
		"body-slap combatant dispatch hurts one intersecting Meep into FLEE")
	slap_colony.queue_free()
	slap.queue_free()
	await get_tree().process_frame

	var contact := _attack_fixture(planet, PORCUPINE,
		porcupine_template.global_transform, "meep_contact_fixture", 703)
	var contact_surface := _surface_near(planet, contact.global_position)
	var contact_colony := _combat_colony(
		planet, [contact_surface], "ContactTarget", 803)
	var contact_query := contact_colony.combat_target_within(
		contact.combat_position(),
		contact.combat_radius() + maxf(PORCUPINE.attack_range, 0.05))
	var contact_before := contact_colony.meep_health(0)
	contact.call(&"_try_contact_damage")
	_expect(int(contact_query.get("row", -1)) == 0
		and is_equal_approx(contact_before - contact_colony.meep_health(0),
			PORCUPINE.attack_damage),
		"contact query finds the visible Meep touched by physical quills")
	contact_colony.queue_free()
	contact.queue_free()
	await get_tree().process_frame

	var spitter := _attack_fixture(
		planet, ALPACA, alpaca_template.global_transform, "meep_spit_fixture", 704)
	var spit_up := planet.up_at(spitter.global_position)
	var spit_forward := _flat_forward(spitter, planet)
	var spit_surface := _surface_near(planet, spitter.global_position)
	var spit_from := spit_surface + spit_up * (
		MeepStats.new().body_height * 0.5 + MeepColony.FLOOR_CLEARANCE)
	var near_surface := _surface_near(
		planet, spit_surface + spit_forward * 2.0)
	var far_surface := _surface_near(
		planet, spit_surface + spit_forward * 4.0)
	var spit_colony := _combat_colony(
		planet, [near_surface, far_surface], "SpitTargets", 804)
	spitter.call(&"_spawn_spit", spit_from, spit_forward * ALPACA.spit_speed)
	var balls := planet.find_children("*", "FaunaSpit", false, false)
	_expect(balls.size() == 1,
		"the Meep spit fixture launches one ordinary fauna projectile")
	if not balls.is_empty():
		var ball := balls[0] as FaunaSpit
		ball.set_physics_process(false)
		var swept: Dictionary = ball.call(&"_combatant_along",
			spit_from, spit_from + spit_forward * 6.0)
		var near_before := spit_colony.meep_health(0)
		var far_before := spit_colony.meep_health(1)
		if not swept.is_empty():
			ball.global_position = swept.get("point", spit_from) as Vector3
			ball.call(&"_strike", swept)
		_expect(swept.get("target") == spit_colony
			and int(swept.get("row", -1)) == 0
			and is_equal_approx(
				near_before - spit_colony.meep_health(0), ALPACA.attack_damage)
			and is_equal_approx(spit_colony.meep_health(1), far_before),
			"spit stops at the nearest actual Meep row and applies exactly once")
		if is_instance_valid(ball):
			ball.queue_free()
	spit_colony.queue_free()
	spitter.queue_free()
	await get_tree().process_frame


func _check_combat(spawner: FaunaSpawner, planet: Planet) -> void:
	var porcupine := _first_mob(spawner, "lumaquill_porcupine")
	_expect(porcupine != null, "porcupine colony exposes live actors")
	if porcupine == null:
		return
	porcupine.set_physics_process(false)
	var motion_pivot := porcupine.get_node_or_null(
		"Visuals/MotionPivot") as Node3D
	var meshes := porcupine.find_children(
		"*", "MeshInstance3D", true, false)
	var mesh_instance := meshes[0] as MeshInstance3D \
		if not meshes.is_empty() else null
	var gait_material := mesh_instance.material_override as ShaderMaterial \
		if mesh_instance != null else null
	var starting_transform := porcupine.global_transform
	porcupine.set(&"_gait_phase", 0.0)
	porcupine.set(&"_gait_blend", 0.0)
	porcupine.set(&"_last_visual_position", porcupine.global_position)
	porcupine.call(&"_set_motion_state", FaunaMob.MotionState.WALK)
	porcupine.global_position += -porcupine.global_basis.z \
		* porcupine.instance_height() * PORCUPINE.gait_stride_share * 0.25
	porcupine.call(&"_animate_visual", 0.1)
	_expect(gait_material != null
		and bool(gait_material.get_shader_parameter(&"quadruped_gait"))
		and float(gait_material.get_shader_parameter(&"gait_amount")) > 0.5,
		"porcupine material animates its COLOR_0 leg mask")
	_expect(motion_pivot != null
		and absf(motion_pivot.rotation.x) > deg_to_rad(4.0),
		"porcupine rocks fore and aft while walking")
	porcupine.global_transform = starting_transform
	porcupine.call(&"_set_motion_state", FaunaMob.MotionState.IDLE)

	# A creature with no player near it must not be sweeping its capsule against
	# the world. Doing so costs tens of milliseconds per call against distant
	# terrain, which reads in play as the whole world freezing for a moment.
	porcupine.set(&"_player_gap", PORCUPINE.physics_within * 4.0)
	porcupine.call(&"_refresh_simulation_detail")
	_expect(not porcupine.is_physics_body(),
		"a creature far from every player walks the height field")
	porcupine.set(&"_player_gap", PORCUPINE.physics_within * 0.5)
	porcupine.call(&"_refresh_simulation_detail")
	_expect(porcupine.is_physics_body()
		and (porcupine.collision_mask & MeepBlockProxy.LAYER) != 0,
		"a creature beside a player is a full physics body that collides with Meeps")

	var before := porcupine.health()
	var player_hit := DamageHit.impact(
		porcupine.combat_position(), 1.0, 20.0)
	player_hit.faction = DamageHit.Faction.PLAYER
	var delivered := porcupine.apply_damage(player_hit)
	_expect(delivered > 0.0 and porcupine.health() < before,
		"player-faction combat damage reduces fauna health")

	var player := TestPlayer.new()
	player.name = "1"
	planet.add_child(player)
	await get_tree().process_frame

	var grapple_landing := porcupine.global_position
	var carried_to := porcupine.combat_position() + porcupine.global_basis.y * 5.0
	_expect(porcupine.begin_grapple(player) and porcupine.is_grappled()
		and not porcupine.can_be_lassoed()
		and not porcupine.can_be_captured(),
		"Grapple captures ordinary fauna and reserves it from other holds")
	porcupine.grapple_follow(carried_to, porcupine.global_basis.y)
	_expect(porcupine.combat_position().distance_to(carried_to) < 0.05,
		"grappled fauna follows the player's carry socket at species scale")
	porcupine.end_grapple(grapple_landing, porcupine.global_basis.y)
	_expect(porcupine.can_be_grappled() and not porcupine.is_grappled(),
		"Grapple slam returns fauna to the terrain and restores its AI")

	_expect(porcupine.begin_lasso(player) and porcupine.is_lassoed()
		and porcupine.lasso_mass() < 1.0,
		"Lasso captures fauna with species-scale swing mass")
	porcupine.lasso_simulate(
		Vector3.RIGHT * 0.25, Vector3(11.0, 4.0, 0.0))
	porcupine.end_lasso(Vector3(13.0, 4.0, 0.0))
	_expect(porcupine.can_be_lassoed() and not porcupine.is_lassoed()
		and porcupine.velocity.length() > 12.0,
		"Lasso throw restores fauna AI and keeps release velocity")

	player.global_position = porcupine.combat_position()
	porcupine.call(&"_try_contact_damage")
	_expect(player.damage_taken >= PORCUPINE.attack_damage,
		"touching passive porcupine applies quill damage")
	player.queue_free()
	await get_tree().process_frame
	await _check_poke_ball(spawner, planet, porcupine)


func _check_poke_ball(spawner: FaunaSpawner, planet: Planet,
		mob: FaunaMob) -> void:
	var world := DamageHit.game_world_of(planet)
	var owner := PLAYER.instantiate() as OnlinePlayer
	owner.peer_id = multiplayer.get_unique_id()
	owner.defer_camera = true
	world.add_child(owner)
	owner.global_transform = mob.global_transform
	owner.set_process(false)
	owner.set_physics_process(false)
	await get_tree().process_frame
	owner._applying_loadout = true
	owner.ability_progress["poke_ball"] = 1
	owner.abilities.set_item(0, "poke_ball")

	var original := mob
	var captured_health := mob.health()
	var captured := spawner.capture_actor(mob.mob_id, owner.peer_id)
	owner._publish_poke_ball_state(
		mob.mob_id, mob.combat_display_name())
	_expect(captured and owner.poke_ball_loaded() and mob.is_captured()
		and spawner.actor(mob.mob_id) == original
		and is_equal_approx(mob.health(), captured_health),
		"Poké Ball stores the exact living fauna actor without resetting its health")

	var tangent := mob.global_basis.x.normalized()
	var thrown_release := mob.global_position + tangent * 4.0
	owner.resolve_poke_ball_impact(
		null, thrown_release, mob.global_basis.y, true)
	_expect(not owner.poke_ball_loaded() and not mob.is_captured()
		and spawner.actor(mob.mob_id) == original
		and is_equal_approx(mob.health(), captured_health)
		and mob.global_position.distance_to(thrown_release) < 1.0,
		"the next loaded throw releases that same creature where the ball lands")

	var caught_again := spawner.capture_actor(mob.mob_id, owner.peer_id)
	owner._publish_poke_ball_state(
		mob.mob_id, mob.combat_display_name())
	owner.abilities.set_item(0, "")
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(caught_again and not owner.poke_ball_loaded()
		and not mob.is_captured()
		and mob.global_position.distance_to(owner.global_position) < 4.0,
		"unequipping a loaded Poké Ball releases its creature beside the owner")
	owner.abilities.set_item(0, "poke_ball")
	var caught_before_departure := spawner.capture_actor(
		mob.mob_id, owner.peer_id)
	owner._publish_poke_ball_state(
		mob.mob_id, mob.combat_display_name())
	owner.release_poke_ball_on_departure()
	_expect(caught_before_departure and not owner.poke_ball_loaded()
		and not mob.is_captured(),
		"a departing owner cannot leave a captured creature hidden and pinned")
	owner._applying_loadout = false
	owner.queue_free()
	await get_tree().process_frame


## The alpaca is the first creature whose presentation comes from a skeleton and
## whose temperament changes when it is hurt, so each of those is driven here by
## hand: the clip it would play, the leap it flees in, the ring it holds once
## provoked, and the ball it throws from that ring actually landing on somebody.
func _check_alpaca(spawner: FaunaSpawner, planet: Planet) -> void:
	var alpaca := _first_mob(spawner, "aurora_fleece_alpaca")
	_expect(alpaca != null, "alpaca herd exposes live actors")
	if alpaca == null:
		return
	alpaca.set_physics_process(false)
	var animator := alpaca.find_child(
		"AnimationPlayer", true, false) as AnimationPlayer
	_expect(animator != null, "alpaca model carries baked animation clips")
	if animator != null:
		var missing := PackedStringArray()
		for clip in [ALPACA.clip_idle, ALPACA.clip_walk, ALPACA.clip_run,
				ALPACA.clip_graze, ALPACA.clip_bound, ALPACA.clip_strafe,
				ALPACA.clip_attack, ALPACA.clip_hit, ALPACA.clip_dead]:
			if not animator.has_animation(clip):
				missing.append(clip)
		_expect(missing.is_empty(),
			"alpaca GLB exports every clip the species asks for%s" % (
				"" if missing.is_empty()
				else " (missing %s)" % ", ".join(missing)))
		_expect(animator.get_animation(
			ALPACA.clip_walk).loop_mode == Animation.LOOP_LINEAR,
			"alpaca walk clip is bound as a looping gait")

	var meshes := alpaca.find_children("*", "MeshInstance3D", true, false)
	var mesh_instance := meshes[0] as MeshInstance3D \
		if not meshes.is_empty() else null
	var material := mesh_instance.material_override as ShaderMaterial \
		if mesh_instance != null else null
	_expect(material != null
		and not bool(material.get_shader_parameter(&"quadruped_gait")),
		"alpaca material leaves its vertices to the skeleton")

	# Grazing is rolled when a wander leg is chosen, so roll until it comes up
	# rather than reaching in and setting the timer the behaviour reads.
	for _attempt in 24:
		if float(alpaca.get(&"_graze_left")) > 0.0:
			break
		alpaca.call(&"_choose_wander_heading")
	_expect(float(alpaca.get(&"_graze_left")) > 0.0,
		"alpaca wander pauses turn into grazing")
	alpaca.call(&"_wander", 0.1)
	_expect(alpaca.motion_state() == FaunaMob.MotionState.GRAZE
		and alpaca.call(&"_clip_for_state") == ALPACA.clip_graze,
		"a grazing alpaca stands still with its head down")

	var player := TestPlayer.new()
	player.name = "1"
	planet.add_child(player)
	player.global_position = alpaca.combat_position() \
		- alpaca.global_basis.z * 3.0
	await get_tree().process_frame

	# Driven as a height-field walker so each step here is the same analytical
	# move every frame, rather than a capsule sweep outside the physics tick.
	alpaca.set(&"_player_gap", ALPACA.physics_within * 4.0)
	alpaca.call(&"_refresh_simulation_detail")
	alpaca.set(&"_think_left", 0.0)
	alpaca.call(&"_update_behaviour", 0.1)
	_expect(alpaca.motion_state() == FaunaMob.MotionState.FLEE
		and alpaca.call(&"_clip_for_state") == ALPACA.clip_bound,
		"a crowded alpaca bounds away instead of standing there")
	_expect(float(alpaca.get(&"_graze_left")) == 0.0,
		"fleeing interrupts a graze")

	var hit := DamageHit.impact(alpaca.combat_position(), 1.0, 5.0)
	hit.faction = DamageHit.Faction.PLAYER
	hit.set_source(player)
	alpaca.apply_damage(hit)
	_expect(float(alpaca.get(&"_provoked_left")) > 0.0,
		"hurting an alpaca provokes it")
	_expect(alpaca.call(&"_clip_for_state") == ALPACA.clip_hit,
		"a struck alpaca flinches")
	alpaca.set(&"_hit_show_left", 0.0)
	alpaca.set(&"_attack_cooldown_left", 0.0)
	var gap_before := alpaca.global_position.distance_to(
		player.global_position)
	for _step in 12:
		alpaca.set(&"_think_left", 0.0)
		alpaca.call(&"_update_behaviour", 0.1)
	_expect(alpaca.motion_state() == FaunaMob.MotionState.STRAFE,
		"a provoked alpaca circles whoever hurt it")
	var aim := -alpaca.global_basis.z.dot(
		(player.global_position - alpaca.global_position).normalized())
	_expect(aim > 0.5,
		"a strafing alpaca keeps its aim on its target (%.2f)" % aim)
	_expect(float(alpaca.get(&"_spit_windup_left")) > 0.0
		and alpaca.call(&"_clip_for_state") == ALPACA.clip_attack,
		"circling at close range starts a spit")
	var gap_after := alpaca.global_position.distance_to(player.global_position)
	_expect(gap_after > gap_before - 0.5
		and gap_after < ALPACA.strafe_radius + 2.0,
		"strafing opens out to its ring rather than charging or bolting")

	# The ball is thrown by hand at a target standing in its path, which is the
	# only way to prove the throw carries damage rather than merely existing.
	player.global_position = alpaca.combat_position() \
		- alpaca.global_basis.z * 4.0
	alpaca.call(&"_launch_spit")
	var balls := planet.find_children("*", "FaunaSpit", false, false)
	_expect(balls.size() == 1, "a spit puts exactly one ball in the air")
	if not balls.is_empty():
		var ball := balls[0] as Node3D
		# Flown on real physics frames rather than by calling its step by hand:
		# the ball queries the physics server, and those queries are only safe
		# from inside the tick that owns them.
		for _step in 40:
			if not is_instance_valid(ball) or player.damage_taken > 0.0:
				break
			await get_tree().physics_frame
		_expect(player.damage_taken >= ALPACA.attack_damage,
			"the spit ball damages the player it was thrown at")
		if is_instance_valid(ball):
			ball.queue_free()
	player.queue_free()
	await get_tree().process_frame


## The rhino is the first creature placed against the settlement's boundary
## rather than around the ship, and the first whose attack is a committed run
## rather than something thrown or touched. Both are driven by hand here: where
## the herd lands, and the paw-charge-gore sequence actually reaching a player.
func _check_rhino(spawner: FaunaSpawner, planet: Planet) -> void:
	var rhino := _first_mob(spawner, "cinder_plate_rhino")
	_expect(rhino != null, "rhino herd exposes live actors")
	if rhino == null:
		return
	rhino.set_physics_process(false)
	var animator := rhino.find_child(
		"AnimationPlayer", true, false) as AnimationPlayer
	_expect(animator != null, "rhino model carries baked animation clips")
	if animator != null:
		var missing := PackedStringArray()
		for clip in [RHINO.clip_idle, RHINO.clip_walk, RHINO.clip_run,
				RHINO.clip_windup, RHINO.clip_charge, RHINO.clip_attack,
				RHINO.clip_hit, RHINO.clip_dead]:
			if not animator.has_animation(clip):
				missing.append(clip)
		_expect(missing.is_empty(),
			"rhino GLB exports every clip the species asks for%s" % (
				"" if missing.is_empty()
				else " (missing %s)" % ", ".join(missing)))
		_expect(animator.get_animation(
			RHINO.clip_charge).loop_mode == Animation.LOOP_LINEAR,
			"rhino charge clip is bound as a looping gait")
		# This species bakes no circling clip, which is the case the clip
		# lookup has to survive rather than play something that is not there.
		rhino.set(&"_motion_state", FaunaMob.MotionState.STRAFE)
		rhino.call(&"_animate_clips", 0.0)
		_expect(animator.current_animation == RHINO.clip_idle,
			"a state this bake has no clip for falls back to standing")
		rhino.set(&"_motion_state", FaunaMob.MotionState.IDLE)

	# The frontier ring. No settlement has been founded in this harness, so the
	# distances measured here are against the nominal tier-zero cap, which is
	# the same fallback a fresh world uses before anybody releases settlers.
	var anchor := COLONY_DIRECTION.normalized()
	var axes := _tangent_axes(anchor)
	var nearest := INF
	var furthest := 0.0
	var bearings := PackedFloat32Array()
	for child_variant: Variant in spawner.get_children():
		var mob := child_variant as FaunaMob
		if mob == null or mob.species == null \
				or mob.species.species_id != "cinder_plate_rhino":
			continue
		var out := planet.to_local(mob.global_position).normalized()
		nearest = minf(nearest, anchor.angle_to(out) * planet.shape.radius)
		furthest = maxf(furthest, anchor.angle_to(out) * planet.shape.radius)
		bearings.append(atan2(out.dot(axes[1]), out.dot(axes[0])))
	_expect(nearest >= MeepClaim.DEFAULT_RADIUS + RHINO.edge_margin_near - 1.0,
		"no rhino stands inside the tier-zero boundary (%.1f m)" % nearest)
	_expect(furthest <= MeepClaim.DEFAULT_RADIUS + RHINO.edge_margin_far + 1.0,
		"the herd stays on the frontier rather than wandering off (%.1f m)"
			% furthest)
	var sorted := Array(bearings)
	sorted.sort()
	_expect(sorted.size() == RHINO.colony_count,
		"every frontier rhino found ground to stand on (%d of %d)"
			% [sorted.size(), RHINO.colony_count])
	# Spacing is measured as the widest gap anywhere around the ring: a herd that
	# surrounds the town leaves no open side, however far the ground under one
	# sector may have pushed a single animal along the frontier.
	var widest := 0.0
	for index in sorted.size():
		var gap: float = sorted[(index + 1) % sorted.size()] - sorted[index]
		widest = maxf(widest, fposmod(gap, TAU))
	_expect(widest < deg_to_rad(170.0),
		"the herd rings the settlement instead of clumping (%.0f deg open)"
			% rad_to_deg(widest))

	var player := TestPlayer.new()
	player.name = "1"
	planet.add_child(player)
	player.global_position = rhino.global_position \
		- rhino.global_basis.z * 12.0
	rhino.set_physics_process(true)
	await get_tree().physics_frame

	# From here the animal is left alone on real physics frames rather than
	# stepped by hand. The whole claim being tested is that nobody has to ask it
	# to attack, so driving the sequence from the test would prove nothing.
	var pawed := false
	var charged := false
	var closest := INF
	for _step in 300:
		await get_tree().physics_frame
		var state := rhino.motion_state()
		pawed = pawed or state == FaunaMob.MotionState.PAW
		charged = charged or state == FaunaMob.MotionState.CHARGE
		closest = minf(closest,
			rhino.global_position.distance_to(player.global_position))
		if player.damage_taken > 0.0:
			break
	_expect(pawed,
		"a rhino that sees a player at charging range paws the ground first")
	_expect(charged, "pawing commits to a charge on its own")
	_expect(closest < RHINO.attack_range + 1.5,
		"the charge closes the ground it committed to (%.1f m)" % closest)
	_expect(player.damage_taken >= RHINO.attack_damage,
		"the horn gores the player the charge was aimed at")
	_expect(rhino.motion_state() != FaunaMob.MotionState.CHARGE
		and float(rhino.get(&"_attack_cooldown_left")) > 0.0,
		"a charge that connects ends there rather than ploughing on")

	# Backing off: from under the player's feet there is no room to run a line,
	# and standing there waiting for one would just be a free hit.
	player.global_position = rhino.global_position \
		- rhino.global_basis.z * 2.0
	for _step in 40:
		await get_tree().physics_frame
	var crowded_before := rhino.global_position.distance_to(
		player.global_position)
	for _step in 60:
		await get_tree().physics_frame
	var facing := -rhino.global_basis.z.dot(
		(player.global_position - rhino.global_position).normalized())
	_expect(rhino.global_position.distance_to(player.global_position)
		> crowded_before and facing > 0.5,
		"a crowded rhino backs off horn-first instead of charging from zero")
	player.queue_free()
	await get_tree().process_frame


func _check_rhino_den(spawner: FaunaSpawner, planet: Planet) -> void:
	var den := spawner.rhino_den() as RhinoDen
	_expect(den != null, "one Cinder-Plate den is placed near the frontier herd")
	if den == null:
		return
	var sealed := den.find_child(
		"SealedEntrance", true, false) as CollisionShape3D
	_expect(sealed != null and sealed.shape is BoxShape3D \
		and not sealed.disabled,
		"the cave mouth is a solid facade rather than an enterable interior")
	print("fauna_test: den cliff %.1f deg, %d terrain checks" % [
		den.cliff_slope_degrees(), spawner.last_den_placement_checks()])
	_expect(den.cliff_slope_degrees() >= 12.0
		and spawner.last_den_placement_checks() <= 96,
		"the den selects a bounded, visibly sloped cliff search")
	var nearest_rhino := INF
	for child_variant: Variant in spawner.get_children():
		var mob := child_variant as FaunaMob
		if mob != null and mob.species != null \
				and mob.species.species_id == RHINO.species_id \
				and mob.mob_id.begins_with("c_"):
			nearest_rhino = minf(nearest_rhino,
				den.global_position.distance_to(mob.global_position))
	_expect(nearest_rhino <= 1250.0,
		"the cave remains near the existing frontier rhinos (%.0f m)"
			% nearest_rhino)

	var city_registry := MeepColonies.new()
	city_registry.name = &"MeepColonies"
	city_registry.planet = planet
	planet.add_child(city_registry)
	city_registry.set_process(false)
	var near_city := MeepCityLedger.new()
	near_city.site_id = &"near_city"
	near_city.direction = COLONY_DIRECTION.normalized()
	near_city.claim_radius = MeepClaim.DEFAULT_RADIUS + 12.0
	var far_city := MeepCityLedger.new()
	far_city.site_id = &"far_city"
	far_city.direction = -COLONY_DIRECTION.normalized()
	far_city.claim_radius = MeepClaim.DEFAULT_RADIUS
	var ledgers := city_registry.get(&"_ledgers") as Dictionary
	ledgers[near_city.site_id] = near_city
	ledgers[far_city.site_id] = far_city
	var nearest_city := city_registry.nearest_city(den.global_position)
	_expect(String(nearest_city.get("site", "")) == "near_city"
		and is_equal_approx(float(nearest_city.get("claim_radius", 0.0)),
			near_city.claim_radius),
		"migration considers the nearest resident or offscreen ledger city")

	var before := spawner.living_species_count(RHINO.species_id)
	_expect(spawner.spawn_rhino_from_den(den)
		and spawner.living_species_count(RHINO.species_id) == before + 1,
		"a live den produces one rhino under the species population limit")
	var migrant: FaunaMob
	for id in spawner.actor_ids():
		if id.begins_with("d_%s_" % RHINO.species_id):
			migrant = spawner.actor(id)
			break
	_expect(migrant != null and migrant.is_migrating()
		and migrant.migration_direction().dot(
			COLONY_DIRECTION.normalized()) > 0.999
		and migrant.migration_stop_radius() > MeepClaim.DEFAULT_RADIUS,
		"a den-born rhino receives the nearest city and its outer edge as a route")
	if migrant != null:
		migrant.set_physics_process(false)
		var before_route := planet.to_local(
			migrant.global_position).normalized().angle_to(
				COLONY_DIRECTION.normalized()) * planet.shape.radius
		for _step in 20:
			migrant.call(&"_migrate", 0.1)
		var after_route := planet.to_local(
			migrant.global_position).normalized().angle_to(
				COLONY_DIRECTION.normalized()) * planet.shape.radius
		_expect(after_route < before_route
			and migrant.motion_state() == FaunaMob.MotionState.WALK,
			"the den rhino migrates cityward at a walking gait")

	var fatal := DamageHit.impact(
		den.combat_position(), den.combat_radius(), 10000.0)
	fatal.faction = DamageHit.Faction.PLAYER
	var den_damage := DamageHit.apply_to_combatants(den, fatal)
	await get_tree().process_frame
	_expect(den_damage > 0.0 and den.is_destroyed() and sealed.disabled,
		"player attacks destroy the den and remove its sealed collision")
	var saved := spawner.sandbox_snapshot()
	var den_saved: Dictionary = saved.get("rhino_den", {})
	var den_state: Dictionary = den_saved.get("state", {})
	_expect(int(saved.get("den_spawn_sequence", 0)) >= 1
		and not bool(den_state.get("alive", true)),
		"den destruction and its stable spawn sequence persist in fauna saves")
	var population_after_break := spawner.living_species_count(RHINO.species_id)
	_expect(not spawner.spawn_rhino_from_den(den)
		and spawner.living_species_count(RHINO.species_id)
			== population_after_break,
		"a destroyed den cannot produce replacement rhinos")
	spawner.call(&"_apply_rhino_den_snapshot", den_saved)
	await get_tree().process_frame
	var restored := spawner.rhino_den() as RhinoDen
	_expect(restored != null and restored.is_destroyed(),
		"late-join and save snapshots restore the den as destroyed")
	city_registry.queue_free()


func _attack_fixture(planet: Planet, definition: FaunaSpecies,
		at: Transform3D, id: String, seed: int) -> FaunaMob:
	var mob := FaunaMob.new()
	mob.name = id
	mob.configure(definition, id, seed, at, Color.WHITE)
	planet.add_child(mob)
	mob.set_process(false)
	mob.set_physics_process(false)
	return mob


func _fauna_record(definition: FaunaSpecies, id: String, seed: int,
		transform: Transform3D, growth := 1.0) -> Dictionary:
	return {
		"id": id,
		"species_id": definition.species_id,
		"seed": seed,
		"transform": transform,
		"biome": Color.WHITE,
		"growth": growth,
	}


func _flat_forward(mob: Node3D, planet: Planet) -> Vector3:
	var up := planet.up_at(mob.global_position)
	var forward := -mob.global_basis.z
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.000001:
		forward = mob.global_basis.x - up * mob.global_basis.x.dot(up)
	return forward.normalized()


func _surface_near(planet: Planet, wanted: Vector3) -> Vector3:
	var local := planet.to_local(wanted)
	var direction := local.normalized() \
		if local.length_squared() > 1.0 else Vector3.UP
	return planet.to_global(
		planet.shape.surface_point(direction, planet.finest_spacing()))


func _combat_colony(planet: Planet, surfaces: Array[Vector3],
		shown_name: String, seed: int) -> MeepColony:
	var colony := MeepColony.new()
	colony.name = shown_name
	colony.stats = MeepStats.new()
	colony._planet = planet
	colony._shape = planet.shape
	colony.claim_radius = 16.0
	colony.founded_seed = seed
	var first_local := planet.to_local(surfaces[0])
	var anchor := first_local.normalized() \
		if first_local.length_squared() > 1.0 else Vector3.UP
	colony.site = MeepSite.new(
		anchor, planet.shape.radius, 0.0, MeepGrid.CELLS * MeepGrid.CELL * 0.5)
	colony._centre_height = planet.shape.elevation(
		anchor, planet.finest_spacing())
	planet.add_child(colony)
	colony.set_process(false)
	colony.set_physics_process(false)
	for index in surfaces.size():
		var direction := planet.to_local(surfaces[index]).normalized()
		var local := colony.site.to_local(direction)
		var row := int(colony.call(&"_add", local, seed + index * 31))
		colony._height[row] = planet.shape.elevation(
			direction, planet.finest_spacing())
		colony._detail[row] = MeepColony.Detail.HOT
	return colony


func _tangent_axes(up: Vector3) -> Array[Vector3]:
	var east := up.cross(Vector3.UP if absf(up.y) < 0.9 \
		else Vector3.RIGHT).normalized()
	return [east, up.cross(east).normalized()]


func _first_mob(spawner: FaunaSpawner, species_id: String) -> FaunaMob:
	for child_variant: Variant in spawner.get_children():
		var mob := child_variant as FaunaMob
		if mob != null and mob.species != null \
				and mob.species.species_id == species_id:
			return mob
	return null


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("fauna_test: PASS  ", message)
		return
	_failures += 1
	push_error("fauna_test: FAIL  %s" % message)
