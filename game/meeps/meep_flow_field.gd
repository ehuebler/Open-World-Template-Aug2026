class_name MeepFlowField
extends RefCounted

## Every route to one place at once: a cost field over a [MeepGrid] plus, in each
## cell, the single step that gets closer to the target.
##
## A colony is many walkers and few destinations. Pathing each Meep separately
## would solve the same problem once per Meep and then again every time one of them
## was nudged off its line; solving it once per destination costs a single pass over
## sixteen thousand cells, after which a Meep's entire navigation is one array read
## per step. Two hundred Meeps walking to the same building share one field.
##
## It is also what makes roads work later without touching this file. The field
## takes its per-cell price from [method MeepGrid.cost_at], so a road priced well
## below dirt bends every town route onto the network by itself —
## and a Meep that has no quick way anywhere is exactly a Meep standing on a cell
## this field could not reach cheaply, which is the signal the roads pass needs.
##
## Held against a grid revision rather than a timestamp. Ground gets recut by
## craters and built on by Meeps; a field that outlived either would route people
## into a hole with complete confidence.

## Distance for a cell the fill never got to. Not INT32_MAX, so that adding a step
## to it cannot overflow.
const UNREACHABLE := 0x3FFFFFFF
## The largest possible edge price: a diagonal step onto a planned lot at maximum
## hazard. Dial's circular queue needs one bucket per value (plus zero) to preserve
## Dijkstra ordering without the allocation and sift cost of heap relaxations.
const MAX_EDGE_COST := 2212
const COST_BUCKETS := MAX_EDGE_COST + 1

## The eight steps, in the order the flow bytes index them from one.
const STEPS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
	Vector2i(0, -1),
	Vector2i(1, -1),
]

var grid: MeepGrid
var target := Vector2i.ZERO
## Grid revision this was built against. See [method stale].
var revision := -1
## Cost to reach [member target] from each cell.
var distance := PackedInt32Array()
## Which of [constant STEPS] to take, plus one. Zero is the target itself or a cell
## with no route out.
var flow := PackedByteArray()
## Cells the fill reached, for reporting how much of a town a place serves.
var reached := 0


## Fills the field. Safe on a worker thread: it reads the grid's bytes and writes
## only its own arrays.
##
## Dijkstra rather than a plain breadth-first flood, because the whole point is that
## cells cost different amounts — a hazard is crossable but dear, and a road will be
## cheap. Diagonal steps cost their true length so a field does not prefer
## staircases to straight lines.
func build(for_grid: MeepGrid, to: Vector2i) -> void:
	grid = for_grid
	target = to
	reached = 0
	if grid == null:
		return
	var total := grid.cells * grid.cells
	distance.resize(total)
	flow.resize(total)
	distance.fill(UNREACHABLE)
	flow.fill(0)
	revision = grid.revision
	if not grid.inside(target):
		return
	# Passability is consulted for every outgoing edge and both shoulders of every
	# diagonal. Flatten it once from the grid's packed arrays instead of making up
	# to ten GDScript method calls for every cell the fill reaches.
	var passable := PackedByteArray()
	passable.resize(total)
	for at in total:
		var bits := int(grid.flags[at])
		passable[at] = 1 if (
			(grid.terrain[at] == MeepGrid.Terrain.PASSABLE
				or (bits & MeepGrid.FLAG_SURFACE) != 0)
			and (bits & (MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_SHIP)) == 0
		) else 0
	var start := grid.index(target)
	if passable[start] == 0:
		return
	distance[start] = 0

	# Cell prices are small bounded integers (2/10 on today's road and dirt).
	# A circular Dial queue therefore visits the same Dijkstra ordering in O(E+V)
	# without allocating duplicate heap entries. Each cell owns one intrusive
	# queue link; a shorter relaxation removes and reinserts that link in O(1).
	var bucket_heads := PackedInt32Array()
	bucket_heads.resize(COST_BUCKETS)
	bucket_heads.fill(-1)
	var queue_next := PackedInt32Array()
	var queue_previous := PackedInt32Array()
	var queued_bucket := PackedInt32Array()
	queue_next.resize(total)
	queue_previous.resize(total)
	queued_bucket.resize(total)
	queue_next.fill(-1)
	queue_previous.fill(-1)
	queued_bucket.fill(-1)
	bucket_heads[0] = start
	queued_bucket[start] = 0
	var queued := 1
	var current_cost := 0
	var side := grid.cells
	while queued > 0:
		var bucket := current_cost % COST_BUCKETS
		while bucket_heads[bucket] < 0:
			current_cost += 1
			bucket = current_cost % COST_BUCKETS
		var at := bucket_heads[bucket]
		var following := queue_next[at]
		bucket_heads[bucket] = following
		if following >= 0:
			queue_previous[following] = -1
		queue_next[at] = -1
		queue_previous[at] = -1
		queued_bucket[at] = -1
		queued -= 1
		var cost := distance[at]
		current_cost = cost
		reached += 1
		var x := at % side
		var y := at / side
		for step in STEPS.size():
			var offset := STEPS[step]
			var next_x := x + offset.x
			var next_y := y + offset.y
			if next_x < 0 or next_y < 0 \
					or next_x >= side or next_y >= side:
				continue
			var index := next_y * side + next_x
			if passable[index] == 0:
				continue
			var diagonal := offset.x != 0 and offset.y != 0
			# No squeezing between two corners: a Meep is wider than a point, and
			# a diagonal through the lip of a crevasse is a fall.
			if diagonal and (
					passable[y * side + next_x] == 0
					or passable[next_y * side + x] == 0):
				continue
			var bits := int(grid.flags[index])
			var price := MeepGrid.ROAD_COST \
				if (bits & MeepGrid.FLAG_ROAD) != 0 \
				else MeepGrid.STEP_COST
			if (bits & MeepGrid.FLAG_ROAD) == 0 \
					and (bits & MeepGrid.FLAG_PLANNED_LOT) != 0:
				price += MeepGrid.PLANNED_LOT_COST
			price += int(grid.hazard[index]) * MeepGrid.HAZARD_COST
			if diagonal:
				price = price * MeepGrid.DIAGONAL_COST / MeepGrid.STEP_COST
			var next_cost := cost + price
			if next_cost >= distance[index]:
				continue
			var old_bucket := queued_bucket[index]
			if old_bucket >= 0:
				var previous := queue_previous[index]
				var after := queue_next[index]
				if previous >= 0:
					queue_next[previous] = after
				else:
					bucket_heads[old_bucket] = after
				if after >= 0:
					queue_previous[after] = previous
			else:
				queued += 1
			distance[index] = next_cost
			# The field is filled outward from the target, so the way home from
			# this neighbour is back the way the fill arrived.
			flow[index] = _opposite(step) + 1
			var next_bucket := next_cost % COST_BUCKETS
			var old_head := bucket_heads[next_bucket]
			queue_previous[index] = -1
			queue_next[index] = old_head
			if old_head >= 0:
				queue_previous[old_head] = index
			bucket_heads[next_bucket] = index
			queued_bucket[index] = next_bucket


## Whether the ground has changed since this was filled.
func stale() -> bool:
	return grid == null or grid.revision != revision


func reachable(cell: Vector2i) -> bool:
	if grid == null or not grid.inside(cell):
		return false
	return distance[grid.index(cell)] < UNREACHABLE


func distance_at(cell: Vector2i) -> int:
	if grid == null or not grid.inside(cell):
		return UNREACHABLE
	return distance[grid.index(cell)]


## The step to take from here, or [constant Vector2i.ZERO] at the target and
## anywhere with no route to it.
func step_at(cell: Vector2i) -> Vector2i:
	if grid == null or not grid.inside(cell):
		return Vector2i.ZERO
	var index := flow[grid.index(cell)]
	return STEPS[index - 1] if index > 0 else Vector2i.ZERO


func _opposite(step: int) -> int:
	return (step + 4) % STEPS.size()


func _push(heap: PackedInt64Array, cost: int, at: int) -> void:
	heap.push_back((cost << 20) | at)
	var child := heap.size() - 1
	while child > 0:
		var parent := (child - 1) / 2
		if heap[parent] <= heap[child]:
			break
		var swap := heap[parent]
		heap[parent] = heap[child]
		heap[child] = swap
		child = parent


func _pop(heap: PackedInt64Array) -> int:
	var top := heap[0]
	var last := heap[heap.size() - 1]
	heap.resize(heap.size() - 1)
	if heap.is_empty():
		return top
	heap[0] = last
	var parent := 0
	while true:
		var left := parent * 2 + 1
		if left >= heap.size():
			break
		var smallest := left
		var right := left + 1
		if right < heap.size() and heap[right] < heap[left]:
			smallest = right
		if heap[parent] <= heap[smallest]:
			break
		var swap := heap[parent]
		heap[parent] = heap[smallest]
		heap[smallest] = swap
		parent = smallest
	return top
