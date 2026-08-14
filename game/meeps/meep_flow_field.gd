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
## takes its per-cell price from [method MeepGrid.cost_at], so the day a road is
## half the cost of dirt, every route in the town bends onto the roads by itself —
## and a Meep that has no quick way anywhere is exactly a Meep standing on a cell
## this field could not reach cheaply, which is the signal the roads pass needs.
##
## Held against a grid revision rather than a timestamp. Ground gets recut by
## craters and built on by Meeps; a field that outlived either would route people
## into a hole with complete confidence.

## Distance for a cell the fill never got to. Not INT32_MAX, so that adding a step
## to it cannot overflow.
const UNREACHABLE := 0x3FFFFFFF

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
	if not grid.passable(target):
		return
	var start := grid.index(target)
	distance[start] = 0
	# One packed integer per queue entry, cost in the high bits, so the heap sorts
	# on cost without a second array or a comparator call per sift.
	var heap := PackedInt64Array()
	_push(heap, 0, start)
	while not heap.is_empty():
		var entry := _pop(heap)
		var at := int(entry & 0xFFFFF)
		var cost := int(entry >> 20)
		# Left behind by an earlier, longer route to the same cell.
		if cost > distance[at]:
			continue
		reached += 1
		var cell := Vector2i(at % grid.cells, at / grid.cells)
		for step in STEPS.size():
			var offset := STEPS[step]
			var neighbour := cell + offset
			if not grid.passable(neighbour):
				continue
			var diagonal := offset.x != 0 and offset.y != 0
			# No squeezing between two corners: a Meep is wider than a point, and
			# a diagonal through the lip of a crevasse is a fall.
			if diagonal and (not grid.passable(cell + Vector2i(offset.x, 0)) \
					or not grid.passable(cell + Vector2i(0, offset.y))):
				continue
			var price := grid.cost_at(neighbour)
			if diagonal:
				price = price * MeepGrid.DIAGONAL_COST / MeepGrid.STEP_COST
			var next := cost + price
			var index := grid.index(neighbour)
			if next >= distance[index]:
				continue
			distance[index] = next
			# The field is filled outward from the target, so the way home from
			# this neighbour is back the way the fill arrived.
			flow[index] = _opposite(step) + 1
			_push(heap, next, index)


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
