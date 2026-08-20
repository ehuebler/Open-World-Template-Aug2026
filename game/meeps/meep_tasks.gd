class_name MeepTasks
extends RefCounted

## The colony's job board: what wants doing, where, and how many Meeps it will take.
##
## Meeps do not decide what to do by looking around them. Ten Meeps each choosing
## the nearest tree independently is ten Meeps at one tree, and the fix for that —
## asking what everyone else picked — is what turns a cheap decision into an
## expensive one. So work is posted once, claimed by name, and a job that already
## has its crew is not offered again.
##
## Only wandering is posted in this build. The rest of the kinds exist because the
## shape of the board is the part worth getting right early: a cloner, a road and a
## building are all "somewhere to stand, for a while, with some number of others,
## having spent something", and every one of those words is already here.

## Kinds of work. Order is not priority; [member Job.priority] is.
enum Kind {
	## Nothing to do. Never posted — it is what a Meep reports when the board had
	## nothing for it.
	IDLE,
	## Stroll somewhere inside the claim. The fallback, so a colony with no work is
	## a colony of Meeps milling about rather than statues.
	WANDER,
	## Reserved: use the cloner and come back as two.
	CLONE,
	## Reserved: lay a stretch of road.
	ROAD,
	## Reserved: raise a building.
	BUILD,
	## Reserved: fell a tree or a bush and carry it home.
	MINE,
	## Append-only: add a safe vertical floor to an existing residence.
	UPGRADE,
	## Append-only regional infrastructure shared by two neighbouring cities.
	SHARED_WALL,
}


## One piece of work. A class rather than a dictionary because the board is walked
## every time a Meep needs something and typed field reads are a good deal cheaper
## than string lookups.
class Job extends RefCounted:
	var id := 0
	## Qualified because an inner class does not share the outer one's scope.
	var kind: MeepTasks.Kind = MeepTasks.Kind.IDLE
	## Where the work is, as a cell on the colony's grid.
	var at := Vector2i.ZERO
	## Higher is chosen first, all else equal.
	var priority := 1.0
	## How many Meeps can work it at once. The cloner's five is the reason this is
	## not one.
	var worker_cap := 1
	## How many are on it now.
	var workers := 0
	## A posted job may close its door while its current crew finishes or leaves. The
	## cloner uses this when the bank drops below one use: deleting the job while
	## Meeps are inside would also delete the only reference that lets them come out.
	var enabled := true
	## Job seconds of work left. Zero completes on arrival.
	var remaining := 0.0
	## Resources held back from the colony's bank when this was posted. Kept on the
	## job so that cancelling it gives them back and finishing it spends them.
	var reserved := 0.0
	## What the work is about, by index: which structure is being raised or used.
	## Negative for work that is about a place rather than a thing.
	var subject := -1
	## Where the work is in the world, for jobs whose target is not a cell in a town
	## but a particular thing standing somewhere — a tree, so far.
	var spot := Vector3.ZERO
	## Biomass finishing this pays into the bank.
	var payout := 0.0

	func open() -> bool:
		return enabled and workers < worker_cap


var _jobs: Dictionary = {}
var _next_id := 1
var _kind_jobs: Array[PackedInt32Array] = []
var _revision := 0


func _init() -> void:
	_ensure_kind_index()


func _ensure_kind_index() -> void:
	while _kind_jobs.size() < Kind.size():
		_kind_jobs.push_back(PackedInt32Array())


## Posts work and returns its id, or zero if the board refused it.
func post(kind: Kind, at: Vector2i, priority := 1.0, worker_cap := 1,
		seconds := 0.0, reserved := 0.0) -> int:
	if kind == Kind.IDLE:
		return 0
	var job := Job.new()
	job.id = _next_id
	_next_id += 1
	job.kind = kind
	job.at = at
	job.priority = priority
	job.worker_cap = maxi(worker_cap, 1)
	job.remaining = maxf(seconds, 0.0)
	job.reserved = maxf(reserved, 0.0)
	_jobs[job.id] = job
	_ensure_kind_index()
	_kind_jobs[kind].push_back(job.id)
	_revision += 1
	return job.id


## Every job of a kind, for a colony reviewing what it has already asked for.
func all_of(kind: Kind) -> Array[Job]:
	var found: Array[Job] = []
	for entry_variant: Variant in _jobs.values():
		var entry := entry_variant as Job
		if entry != null and entry.kind == kind:
			found.push_back(entry)
	return found


## Whether any job is about a given thing. Cheaper than the caller keeping its own
## ledger of what has been posted, and it cannot fall out of step with the board.
func any_about(kind: Kind, subject: int) -> bool:
	for entry_variant: Variant in _jobs.values():
		var entry := entry_variant as Job
		if entry != null and entry.kind == kind and entry.subject == subject:
			return true
	return false


func job(id: int) -> Job:
	return _jobs.get(id) as Job


func count() -> int:
	return _jobs.size()


func count_of(kind: Kind) -> int:
	var found := 0
	for entry_variant: Variant in _jobs.values():
		var entry := entry_variant as Job
		if entry != null and entry.kind == kind:
			found += 1
	return found


## Takes a place on a job. False if it filled up between being offered and being
## claimed, which is the normal outcome of two Meeps deciding in the same tick.
func claim(id: int) -> bool:
	var entry := job(id)
	if entry == null or not entry.open():
		return false
	entry.workers += 1
	return true


func release(id: int) -> void:
	var entry := job(id)
	if entry != null:
		entry.workers = maxi(entry.workers - 1, 0)


## Removes a job. Its crew are not told; they find out by asking the board for
## their job and being handed nothing, which is also what happens to a Meep whose
## work was cancelled from under it.
func finish(id: int) -> void:
	var entry := job(id)
	if entry != null:
		_ensure_kind_index()
		_kind_jobs[entry.kind].erase(id)
	_jobs.erase(id)
	_revision += 1


func clear() -> void:
	_jobs.clear()
	_kind_jobs.clear()
	_ensure_kind_index()
	_revision += 1


func snapshot() -> Dictionary:
	var rows: Array = []
	var ids := _jobs.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var entry := job(int(id_variant))
		if entry == null:
			continue
		rows.append({
			"id": entry.id,
			"kind": int(entry.kind),
			"at": entry.at,
			"priority": entry.priority,
			"worker_cap": entry.worker_cap,
			"workers": entry.workers,
			"enabled": entry.enabled,
			"remaining": entry.remaining,
			"reserved": entry.reserved,
			"subject": entry.subject,
			"spot": entry.spot,
			"payout": entry.payout,
		})
	return {
		"next_id": _next_id,
		"jobs": rows,
	}


func apply_snapshot(state: Dictionary) -> void:
	_jobs.clear()
	_kind_jobs.clear()
	_ensure_kind_index()
	_next_id = 1
	var rows_value: Variant = state.get("jobs", [])
	if not rows_value is Array:
		return
	for row_value: Variant in rows_value:
		if not row_value is Dictionary:
			continue
		var row := row_value as Dictionary
		var id := maxi(int(row.get("id", 0)), 0)
		var kind := clampi(
			int(row.get("kind", Kind.IDLE)), Kind.IDLE, Kind.SHARED_WALL)
		if id <= 0 or kind == Kind.IDLE or _jobs.has(id):
			continue
		var entry := Job.new()
		entry.id = id
		entry.kind = kind as Kind
		var at_value: Variant = row.get("at", Vector2i.ZERO)
		entry.at = at_value as Vector2i \
			if at_value is Vector2i else Vector2i.ZERO
		entry.priority = float(row.get("priority", 1.0))
		if not is_finite(entry.priority):
			entry.priority = 1.0
		entry.worker_cap = maxi(int(row.get("worker_cap", 1)), 1)
		entry.workers = clampi(
			int(row.get("workers", 0)), 0, entry.worker_cap)
		entry.enabled = bool(row.get("enabled", true))
		entry.remaining = maxf(float(row.get("remaining", 0.0)), 0.0)
		entry.reserved = maxf(float(row.get("reserved", 0.0)), 0.0)
		entry.subject = int(row.get("subject", -1))
		var spot_value: Variant = row.get("spot", Vector3.ZERO)
		entry.spot = spot_value as Vector3 \
			if spot_value is Vector3 and (spot_value as Vector3).is_finite() \
			else Vector3.ZERO
		entry.payout = maxf(float(row.get("payout", 0.0)), 0.0)
		_jobs[id] = entry
		_kind_jobs[entry.kind].push_back(id)
		_next_id = maxi(_next_id, id + 1)
	_next_id = maxi(_next_id, int(state.get("next_id", _next_id)))
	_revision += 1


## Progresses a job by one Meep's contribution, and reports whether that finished
## it.
func work(id: int, seconds: float) -> bool:
	var entry := job(id)
	if entry == null:
		return false
	entry.remaining -= seconds
	return entry.remaining <= 0.0


## The best open job for a Meep standing at [param from].
##
## Scored rather than sorted: nearest-first alone sends the whole colony to one
## corner, and priority alone ignores that half of them are on the other side of
## town. The seed is what stops identical Meeps making identical choices — without
## it, ties break the same way every tick and crews arrive in lockstep.
func best_for(from: Vector2i, cell_size: float, seed := 0) -> int:
	var every_kind: Array[int] = []
	for kind in range(Kind.WANDER, Kind.size()):
		every_kind.push_back(kind)
	return best_for_kinds(from, cell_size, seed, every_kind)


## Role-filtered lookup walks only the indexed queues that role may perform.
func best_for_kinds(from: Vector2i, cell_size: float, seed: int,
		kinds: Array[int]) -> int:
	var best := 0
	var best_score := -INF
	var jitter := float(absi(seed) % 1000) / 1000.0
	_ensure_kind_index()
	for kind in kinds:
		if kind <= Kind.IDLE or kind >= _kind_jobs.size():
			continue
		for id in _kind_jobs[kind]:
			var entry := job(id)
			if entry == null or not entry.open():
				continue
			var away := Vector2(entry.at - from).length() * cell_size
			# Distance in metres against priority in units of the same, so a job worth
			# twice as much is worth walking a hundred metres further for.
			var score := entry.priority * 100.0 - away + jitter * 12.0
			if score > best_score:
				best_score = score
				best = entry.id
	return best


func revision() -> int:
	return _revision
