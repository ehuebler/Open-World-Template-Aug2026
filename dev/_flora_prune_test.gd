extends Node

## Regression for the second long-session hitch in the 2026-08-18 captures.
##
## Pruning a five-digit harvest ledger used to happen in one 20-second sweep. This
## fixture proves the work is bounded per call while preserving reachable targets and
## permanent broken-plant entries.

const TARGETS := 4096

var _failures := 0


func _ready() -> void:
	var field := GroundCover.new()
	var reachable_cell := Vector3i(9, 9, 9)
	field._tiles[reachable_cell] = GroundCover.Tile.new()
	var reachable_key := Vector3i(999999, 1, 1)
	field._harvest_targets[reachable_key] = PackedInt32Array([
		reachable_cell.x, reachable_cell.y, reachable_cell.z, 0, 0])
	for index in TARGETS:
		var cell := Vector3i(index, -17, 23)
		field._harvest_targets[Vector3i(index, 4000, -4000)] \
			= PackedInt32Array([cell.x, cell.y, cell.z, 0, index])

	var damaged_cell := Vector3i(-4, -5, -6)
	field._instance_damage[damaged_cell] = {
		0: {
			0: GroundCover.BROKEN,
			1: 0.5,
		},
	}
	var before := field._harvest_targets.size()
	var began := Time.get_ticks_usec()
	field._forget_unreachable_ledgers()
	var first_ms := float(Time.get_ticks_usec() - began) / 1000.0
	var removed_first := before - field._harvest_targets.size()
	_expect(removed_first > 0 \
		and removed_first <= GroundCover.FORGET_TARGETS_PER_STEP \
		and field._forget_active,
		"the first prune call removes only its bounded target slice")

	var calls := 1
	while field._forget_active and calls < TARGETS:
		field._forget_unreachable_ledgers()
		calls += 1
	var damage := field._instance_damage.get(damaged_cell, {}) as Dictionary
	var instances := damage.get(0, {}) as Dictionary
	_expect(not field._forget_active
		and field._harvest_targets.size() == 1
		and field._harvest_targets.has(reachable_key),
		"incremental pruning eventually keeps only reachable harvest targets")
	_expect(float(instances.get(0, 0.0)) == GroundCover.BROKEN
		and not instances.has(1),
		"pruning preserves permanent breaks and discards stale cosmetic damage")
	_expect(first_ms < 40.0,
		"one ledger-prune slice costs %.2f ms, below the spike threshold"
		% first_ms)
	print("flora_prune_test: first slice %.2f ms across %d targets; %d calls total"
		% [first_ms, TARGETS, calls])
	print("flora_prune_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	field.free()
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(passed: bool, message: String) -> void:
	if passed:
		print("flora_prune_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("flora_prune_test: FAIL  %s" % message)
