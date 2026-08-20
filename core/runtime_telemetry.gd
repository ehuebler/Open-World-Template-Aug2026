extends Node

## Always-on, low-overhead performance flight recorder.
##
## The last thirty seconds live in memory whether the Admin page is open or not.
## Per-frame engine numbers use a fixed packed-array ring, so recording a frame
## allocates nothing and never shifts an Array. Wider world state is sampled four
## times a second: terrain queues, Meep residency and population, flora streaming,
## fauna, bosses, combat activity, lights, particles, and network/session shape.
##
## Every frame is divided into three measured parts that add up to it: the
## scripted process step, the scripted physics steps, and the time outside both,
## which is itself split at the four boundaries the engine will admit to — the
## deferred queue, the delete queue, the draw, and the wait. Each quarter-second
## then states how much of
## the scripted half the traced subsystem rows actually explain, and counts the
## nodes running a callback by script. A capture therefore answers "what is
## taking the time" even when the answer is something nobody has instrumented
## yet, which is the failure mode of a recorder that only knows its own labels.
##
## [method export_last_window] writes the whole joined timeline as one JSON file.
## It is deliberately self-describing so a player can attach that one file to a bug
## report without also having to remember their graphics settings or explain what
## each column means.

const WINDOW_SECONDS := 30.0
const WINDOW_USEC := int(WINDOW_SECONDS * 1000000.0)
## Thirty seconds at more than 500 FPS. A fixed ceiling keeps the hot path fixed
## even if a menu or loading screen runs uncapped.
const FRAME_CAPACITY := 16384
const COARSE_INTERVAL_USEC := 250000
const INVENTORY_INTERVAL_USEC := 1000000
const COARSE_CAPACITY := 160
const EVENT_CAPACITY := 512
const SPIKE_MS := 40.0
const HOT_ACTIVITY_USEC := 4000
const HOT_ACTIVITY_COOLDOWN_USEC := 500000
const EXPORT_DIR := "user://performance_logs"

const FRAME_FIELDS := [
	"frame_ms",
	"fps",
	"script_process_ms",
	"script_physics_ms",
	"process_untraced_ms",
	"physics_untraced_ms",
	"engine_ms",
	"deferred_ms",
	"scene_flush_ms",
	"render_draw_ms",
	"engine_gap_ms",
	"gpu_ms",
	"render_cpu_ms",
	"process_peak_ms",
	"physics_peak_ms",
	"draw_calls",
	"render_objects",
	"primitives",
	"active_bodies",
	"collision_pairs",
	"physics_islands",
	"node_count",
	"object_count",
	"orphan_nodes",
	"static_memory_mb",
	"video_memory_mb",
	"texture_memory_mb",
	"buffer_memory_mb",
	"physics_steps",
]
const FRAME_UNITS := [
	"ms", "fps", "ms", "ms", "ms", "ms", "ms", "ms", "ms", "ms", "ms", "ms",
	"ms", "ms", "ms", "count", "count", "count", "count", "count", "count",
	"count", "count", "count", "MiB", "MiB", "MiB", "MiB", "count",
]
const FRAME_STRIDE := 29

const F_FRAME_MS := 0
const F_FPS := 1
const F_SCRIPT_PROCESS_MS := 2
const F_SCRIPT_PHYSICS_MS := 3
const F_PROCESS_UNTRACED_MS := 4
const F_PHYSICS_UNTRACED_MS := 5
const F_ENGINE_MS := 6
const F_DEFERRED_MS := 7
const F_SCENE_FLUSH_MS := 8
const F_RENDER_DRAW_MS := 9
const F_ENGINE_GAP_MS := 10
const F_GPU_MS := 11
const F_RENDER_CPU_MS := 12
const F_PROCESS_PEAK_MS := 13
const F_PHYSICS_PEAK_MS := 14
const F_DRAW_CALLS := 15
const F_RENDER_OBJECTS := 16
const F_PRIMITIVES := 17
const F_ACTIVE_BODIES := 18
const F_COLLISION_PAIRS := 19
const F_PHYSICS_ISLANDS := 20
const F_NODE_COUNT := 21
const F_OBJECT_COUNT := 22
const F_ORPHAN_NODES := 23
const F_STATIC_MEMORY_MB := 24
const F_VIDEO_MEMORY_MB := 25
const F_TEXTURE_MEMORY_MB := 26
const F_BUFFER_MEMORY_MB := 27
const F_PHYSICS_STEPS := 28
const MIB := 1048576.0
## How many script classes the once-a-second census keeps. Enough to name every
## repeated processing node in a busy world without turning the export into a
## directory of the scene.
const CENSUS_ROWS := 24
## Traced rows carried by a frame-spike event. Nested roll-ups — a whole physics
## step, a whole simulation pass — necessarily rank above the stage inside them
## that actually burst, so the list has to be deep enough to reach past them.
const SPIKE_TRACE_ROWS := 8


## Stamps the wall clock at the two ends of one step's ordinary node callbacks.
##
## Godot's own TIME_PROCESS and TIME_PHYSICS_PROCESS monitors are the worst step
## seen during the previous whole second, republished once a second. That is a
## useful peak and a misleading per-frame column: it cannot be added to anything,
## it repeats itself for sixty frames, and a frame it describes may be long gone.
## A pair of sentinels at the extreme ends of the priority order measures what
## actually happened in this frame, which is the number a subsystem total can be
## subtracted from.
class StepBracket extends Node:
	var opening := false
	var physics := false
	var partner: StepBracket
	var opened_usec := 0
	## When the closing sentinel last ran, which is the moment the step's scripted
	## work finished and the engine's own work after it began.
	var closed_usec := 0
	var spent_usec := 0
	## Set by the opening sentinel once a step has begun, cleared by the recorder
	## when it reads the frame. It tells a second physics step of the same frame
	## apart from the first one, whose predecessor belongs to the frame before.
	var stepped := false
	## Time between one step's last callback and the next step's first, summed over
	## the extra steps of a frame. Only the opening sentinel gathers it.
	var between_usec := 0
	## Steps this sentinel has opened since the recorder last read it.
	##
	## The engine runs the physics step more than once in a frame to catch up on a
	## frame that overran, up to [member Engine.max_physics_steps_per_frame]. Without
	## this the frame after a hitch reports several times its own scripted cost with
	## nothing to say why, which reads as a subsystem that suddenly got eight times
	## more expensive rather than as the same work done eight times.
	var steps := 0

	func _init(is_opening: bool, is_physics: bool) -> void:
		opening = is_opening
		physics = is_physics
		process_mode = Node.PROCESS_MODE_ALWAYS
		set_process(not is_physics)
		set_physics_process(is_physics)
		# The extremes of the order, so that every ordinary node sits between the
		# two. Nothing in the game sets a priority anywhere near this.
		var edge := -1000000 if is_opening else 1000000
		if is_physics:
			process_physics_priority = edge
		else:
			process_priority = edge

	func _process(_delta: float) -> void:
		_mark()

	func _physics_process(_delta: float) -> void:
		_mark()

	func _mark() -> void:
		var now := Time.get_ticks_usec()
		if opening:
			if stepped and partner != null and partner.closed_usec > 0:
				between_usec += maxi(now - partner.closed_usec, 0)
			stepped = true
			steps += 1
			opened_usec = now
			return
		closed_usec = now
		if partner != null and partner.opened_usec > 0:
			spent_usec += maxi(closed_usec - partner.opened_usec, 0)

	## Reads the time gathered since the previous read and starts again.
	func take() -> int:
		var spent := spent_usec
		spent_usec = 0
		return spent

	func take_between() -> int:
		var between := between_usec
		between_usec = 0
		stepped = false
		return between

	func take_steps() -> int:
		var counted := steps
		steps = 0
		return counted


## Stamps the moment the process step is over, after every node including this
## recorder has run.
##
## What the engine does next is not nothing: the scene tree deletes everything
## queued during the step, and a subtree freed by a city or a chunk is paid for
## here rather than where it was asked for. Without this sentinel that cost is
## indistinguishable from waiting for the display.
class StepEnd extends Node:
	var ended_usec := 0

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 2000000

	func _process(_delta: float) -> void:
		ended_usec = Time.get_ticks_usec()

var _frame_times := PackedInt64Array()
var _frame_values := PackedFloat32Array()
var _frame_head := 0
var _frame_count := 0
var _previous_frame_usec := 0
var _coarse_left_usec := 0
var _inventory_left_usec := 0
var _coarse: Array[Dictionary] = []
var _events: Array[Dictionary] = []
## Category to label to calls, time, maximum and amount since the last coarse
## sample. Nested StringName keys avoid formatting and allocating a combined String
## for every Meep stage — this recorder runs inside the hot path it measures.
var _activity: Dictionary = {}
## What this frame's two scripted steps have owned up to, in microseconds. Only a
## whole [method Node._process] or [method Node._physics_process] body reports here,
## so the two never double-count the stages nested inside them and the remainder is
## genuinely uninstrumented code. See [method record_process_step].
var _frame_process_attributed_usec := 0
var _frame_physics_attributed_usec := 0
var _hot_activity_at: Dictionary = {}
var _scene_inventory: Dictionary = {}
var _active_world_cache: Node
var _deep_enabled := true
var _last_export := ""
var _spike_open := false
var _spike_started_usec := 0
var _spike_frames := 0
var _spike_worst_ms := 0.0
var _spike_worst_process_ms := 0.0
var _spike_worst_physics_ms := 0.0
var _spike_worst_process_untraced_ms := 0.0
var _spike_worst_physics_untraced_ms := 0.0
var _spike_worst_physics_steps := 0
var _spike_worst_render_draw_ms := 0.0
var _spike_worst_deferred_ms := 0.0
var _spike_worst_scene_flush_ms := 0.0
var _spike_worst_engine_gap_ms := 0.0
var _pre_draw_usec := 0
var _post_draw_usec := 0
var _step_end: StepEnd
var _paused_last_frame := false
var _process_opener: StepBracket
var _physics_opener: StepBracket
var _physics_closer: StepBracket
var _recorder_usec := 0
## Running totals for the frame budget attached to the next coarse sample. A
## quarter-second of frames is the unit that can be compared against a
## quarter-second of subsystem rows.
var _interval_frames := 0
var _interval_wall_usec := 0.0
var _interval_process_usec := 0.0
var _interval_physics_usec := 0.0
var _interval_process_untraced_usec := 0.0
var _interval_physics_untraced_usec := 0.0
var _interval_engine_usec := 0.0
var _interval_deferred_usec := 0.0
var _interval_scene_flush_usec := 0.0
var _interval_render_draw_usec := 0.0
var _interval_engine_gap_usec := 0.0
var _interval_gpu_usec := 0.0
var _interval_recorder_usec := 0
## Physics steps run over the interval's frames. See [member StepBracket.steps].
var _interval_physics_steps := 0
var _fauna_spawners: Array[Node] = []
var _aerial_swarms: Array[Node] = []


func _init() -> void:
	name = "RuntimeTelemetry"
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Run after every ordinary gameplay node, so that the wall clock read here has
	# the whole scripted process step behind it.
	process_priority = 1000000
	_frame_times.resize(FRAME_CAPACITY)
	_frame_values.resize(FRAME_CAPACITY * FRAME_STRIDE)


func _ready() -> void:
	_previous_frame_usec = Time.get_ticks_usec()
	_coarse_left_usec = _previous_frame_usec
	_inventory_left_usec = _previous_frame_usec
	_process_opener = StepBracket.new(true, false)
	_physics_opener = StepBracket.new(true, true)
	_physics_closer = StepBracket.new(false, true)
	_physics_closer.partner = _physics_opener
	_physics_opener.partner = _physics_closer
	_step_end = StepEnd.new()
	add_child(_process_opener)
	add_child(_physics_opener)
	add_child(_physics_closer)
	add_child(_step_end)
	RenderingServer.frame_pre_draw.connect(_mark_draw_began)
	RenderingServer.frame_post_draw.connect(_mark_draw_ended)
	var viewport := get_viewport()
	if viewport != null:
		RenderingServer.viewport_set_measure_render_time(
			viewport.get_viewport_rid(), true)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	# A single-player menu pauses the world. Do not let thirty seconds spent reading
	# this very panel overwrite the thirty seconds of gameplay the player opened it
	# to inspect. Multiplayer never pauses the tree, so its graph remains live.
	if get_tree().paused:
		if not _paused_last_frame:
			# Drain the partial activity interval once. Without this, the attack or
			# Meep stage immediately before Tab could be the one row not represented.
			_collect_coarse(_history_now())
		_paused_last_frame = true
		_previous_frame_usec = now
		# Drop the paused frame's step clocks rather than letting them accumulate
		# into whichever frame the player unpauses on.
		_physics_closer.take()
		_physics_opener.take_between()
		_physics_opener.take_steps()
		_frame_process_attributed_usec = 0
		_frame_physics_attributed_usec = 0
		return
	_paused_last_frame = false
	# The recorder is itself a scripted process cost. Its previous frame is added
	# here rather than dropped, so that the columns sum to the frame.
	var process_usec := _drain_step_clocks(now) + _recorder_usec
	var physics_usec := _physics_closer.take()
	# The recorder's own frame is instrumented by definition, so it belongs on the
	# named side of the split rather than swelling the unexplained remainder.
	var process_untraced_usec := _untraced_usec(
		process_usec, _frame_process_attributed_usec + _recorder_usec)
	var physics_untraced_usec := _untraced_usec(
		physics_usec, _frame_physics_attributed_usec)
	_frame_process_attributed_usec = 0
	_frame_physics_attributed_usec = 0
	var physics_steps := _physics_opener.take_steps()
	if _previous_frame_usec > 0:
		_store_frame(now, float(now - _previous_frame_usec) / 1000.0,
			process_usec, physics_usec, _engine_shape(physics_usec),
			process_untraced_usec, physics_untraced_usec, physics_steps)
	_previous_frame_usec = now
	if now >= _inventory_left_usec:
		_inventory_left_usec = now + INVENTORY_INTERVAL_USEC
		_scene_inventory = _collect_scene_inventory(_active_world())
	if now >= _coarse_left_usec:
		_coarse_left_usec = now + COARSE_INTERVAL_USEC
		_collect_coarse(now)
	_recorder_usec = Time.get_ticks_usec() - now
	_interval_recorder_usec += _recorder_usec


## The renderer's own bracket around the frame it draws, which the server offers as
## a pair of signals.
func _mark_draw_began() -> void:
	_pre_draw_usec = Time.get_ticks_usec()


func _mark_draw_ended() -> void:
	_post_draw_usec = Time.get_ticks_usec()


## Where the frame went outside the two scripted steps, in microseconds.
##
## An iteration runs the physics steps, then the deferred queue, then the process
## step, then the delete queue, then the draw, then hands the machine back to the
## operating system. This recorder sits inside the process step, so the draw stamps
## it reads belong to the previous iteration — which is exactly the span it is
## closing. Naming these pieces is the difference between "the engine took two
## hundred milliseconds" and knowing whether a deferred call ran long, a subtree
## was freed, a mesh was uploaded, or a monitor was waited on.
func _engine_shape(script_physics_usec: int) -> Array:
	var opened := _process_opener.opened_usec if _process_opener != null else 0
	# Between the last physics callback and the first process callback the engine
	# steps the physics solver and flushes the deferred queue. Deferred calls are
	# game code, but they are not inside either step, so nothing else would see
	# them: a call_deferred that runs long looks exactly like a stalled machine.
	var deferred_usec := (
		_physics_opener.take_between() if _physics_opener != null else 0)
	var closed := _physics_closer.closed_usec if _physics_closer != null else 0
	if closed > _post_draw_usec and opened > closed:
		deferred_usec += opened - closed
	var ended := _step_end.ended_usec if _step_end != null else 0
	var flush_usec := 0
	if ended > 0 and _pre_draw_usec > ended:
		flush_usec = _pre_draw_usec - ended
	var draw_usec := 0
	if _post_draw_usec > _pre_draw_usec:
		draw_usec = _post_draw_usec - _pre_draw_usec
	# Whatever is left of the span from the end of the draw to this frame's first
	# scripted callback: operating-system events, the physics server's own queries,
	# and any wait for the display.
	var gap_usec := 0
	if _post_draw_usec > 0 and opened > _post_draw_usec:
		gap_usec = maxi(
			opened - _post_draw_usec - script_physics_usec - deferred_usec, 0)
	return [deferred_usec, flush_usec, draw_usec, gap_usec]


## One piece of [method _engine_shape], in milliseconds, never claiming more of the
## frame than is left for it.
func _shaped_ms(shape: Array, index: int, room: float) -> float:
	if index >= shape.size():
		return 0.0
	return clampf(float(shape[index]) / 1000.0, 0.0, maxf(room, 0.0))


## What a scripted step spent that no whole-callback row claimed.
##
## Zero while deep tracing is off, when nothing is reporting and the whole step
## would otherwise read as unexplained.
func _untraced_usec(step_usec: int, attributed_usec: int) -> int:
	if not _deep_enabled:
		return 0
	return maxi(step_usec - attributed_usec, 0)


## Closes the process bracket and returns what the ordinary nodes spent.
func _drain_step_clocks(now: int) -> int:
	if _process_opener == null or _process_opener.opened_usec <= 0:
		return 0
	return maxi(now - _process_opener.opened_usec, 0)


func _store_frame(now: int, frame_ms: float, script_process_usec := 0,
		script_physics_usec := 0, engine_shape: Array = [],
		process_untraced_usec := 0, physics_untraced_usec := 0,
		physics_steps := 0) -> void:
	var slot := _frame_head
	var at := slot * FRAME_STRIDE
	var viewport := get_viewport()
	var viewport_rid := viewport.get_viewport_rid() if viewport != null else RID()
	var script_process_ms := float(script_process_usec) / 1000.0
	var script_physics_ms := float(script_physics_usec) / 1000.0
	var engine_ms := maxf(
		frame_ms - script_process_ms - script_physics_ms, 0.0)
	# Whatever the frame spent outside the two steps, split at the boundaries the
	# engine will admit to: the ends of the physics steps, the end of the process
	# step, and the two ends of the draw. What is left over is the machine.
	var deferred_ms := _shaped_ms(engine_shape, 0, engine_ms)
	var flush_ms := _shaped_ms(engine_shape, 1, engine_ms - deferred_ms)
	var draw_ms := _shaped_ms(
		engine_shape, 2, engine_ms - deferred_ms - flush_ms)
	var gap_ms := _shaped_ms(
		engine_shape, 3, engine_ms - deferred_ms - flush_ms - draw_ms)
	_frame_times[slot] = now
	_frame_values[at + F_FRAME_MS] = frame_ms
	_frame_values[at + F_FPS] = 1000.0 / maxf(frame_ms, 0.001)
	var process_untraced_ms := minf(
		float(process_untraced_usec) / 1000.0, script_process_ms)
	var physics_untraced_ms := minf(
		float(physics_untraced_usec) / 1000.0, script_physics_ms)
	_frame_values[at + F_SCRIPT_PROCESS_MS] = script_process_ms
	_frame_values[at + F_SCRIPT_PHYSICS_MS] = script_physics_ms
	_frame_values[at + F_PROCESS_UNTRACED_MS] = process_untraced_ms
	_frame_values[at + F_PHYSICS_UNTRACED_MS] = physics_untraced_ms
	_frame_values[at + F_ENGINE_MS] = engine_ms
	_frame_values[at + F_DEFERRED_MS] = deferred_ms
	_frame_values[at + F_SCENE_FLUSH_MS] = flush_ms
	_frame_values[at + F_RENDER_DRAW_MS] = draw_ms
	_frame_values[at + F_ENGINE_GAP_MS] = gap_ms
	_frame_values[at + F_PROCESS_PEAK_MS] = (
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_frame_values[at + F_PHYSICS_PEAK_MS] = (
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_frame_values[at + F_PHYSICS_STEPS] = float(physics_steps)
	_interval_physics_steps += physics_steps
	_interval_frames += 1
	_interval_wall_usec += frame_ms * 1000.0
	_interval_process_usec += float(script_process_usec)
	_interval_physics_usec += float(script_physics_usec)
	_interval_process_untraced_usec += process_untraced_ms * 1000.0
	_interval_physics_untraced_usec += physics_untraced_ms * 1000.0
	_interval_engine_usec += engine_ms * 1000.0
	_interval_deferred_usec += deferred_ms * 1000.0
	_interval_scene_flush_usec += flush_ms * 1000.0
	_interval_render_draw_usec += draw_ms * 1000.0
	_interval_engine_gap_usec += gap_ms * 1000.0
	_frame_values[at + F_GPU_MS] = (
		RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		if viewport_rid.is_valid() else 0.0)
	_interval_gpu_usec += _frame_values[at + F_GPU_MS] * 1000.0
	_frame_values[at + F_RENDER_CPU_MS] = (
		RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		if viewport_rid.is_valid() else 0.0)
	_frame_values[at + F_DRAW_CALLS] = Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_frame_values[at + F_RENDER_OBJECTS] = Performance.get_monitor(
		Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	_frame_values[at + F_PRIMITIVES] = Performance.get_monitor(
		Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	_frame_values[at + F_ACTIVE_BODIES] = Performance.get_monitor(
		Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	_frame_values[at + F_COLLISION_PAIRS] = Performance.get_monitor(
		Performance.PHYSICS_3D_COLLISION_PAIRS)
	_frame_values[at + F_PHYSICS_ISLANDS] = Performance.get_monitor(
		Performance.PHYSICS_3D_ISLAND_COUNT)
	_frame_values[at + F_NODE_COUNT] = Performance.get_monitor(
		Performance.OBJECT_NODE_COUNT)
	_frame_values[at + F_OBJECT_COUNT] = Performance.get_monitor(
		Performance.OBJECT_COUNT)
	_frame_values[at + F_ORPHAN_NODES] = Performance.get_monitor(
		Performance.OBJECT_ORPHAN_NODE_COUNT)
	_frame_values[at + F_STATIC_MEMORY_MB] = Performance.get_monitor(
		Performance.MEMORY_STATIC) / MIB
	_frame_values[at + F_VIDEO_MEMORY_MB] = Performance.get_monitor(
		Performance.RENDER_VIDEO_MEM_USED) / MIB
	_frame_values[at + F_TEXTURE_MEMORY_MB] = Performance.get_monitor(
		Performance.RENDER_TEXTURE_MEM_USED) / MIB
	_frame_values[at + F_BUFFER_MEMORY_MB] = Performance.get_monitor(
		Performance.RENDER_BUFFER_MEM_USED) / MIB
	_frame_head = (_frame_head + 1) % FRAME_CAPACITY
	_frame_count = mini(_frame_count + 1, FRAME_CAPACITY)
	_track_spike(now, frame_ms, script_process_ms, script_physics_ms,
		deferred_ms, flush_ms, draw_ms, gap_ms,
		process_untraced_ms, physics_untraced_ms, physics_steps)


func _track_spike(now: int, frame_ms: float, script_process_ms: float,
		script_physics_ms: float, deferred_ms := 0.0, scene_flush_ms := 0.0,
		render_draw_ms := 0.0, engine_gap_ms := 0.0,
		process_untraced_ms := 0.0, physics_untraced_ms := 0.0,
		physics_steps := 0) -> void:
	if frame_ms >= SPIKE_MS:
		if not _spike_open:
			_spike_open = true
			_spike_started_usec = now
			_spike_frames = 0
			_spike_worst_ms = 0.0
			_spike_worst_process_ms = 0.0
			_spike_worst_physics_ms = 0.0
			_spike_worst_process_untraced_ms = 0.0
			_spike_worst_physics_untraced_ms = 0.0
			_spike_worst_deferred_ms = 0.0
			_spike_worst_scene_flush_ms = 0.0
			_spike_worst_render_draw_ms = 0.0
			_spike_worst_engine_gap_ms = 0.0
			_spike_worst_physics_steps = 0
		_spike_frames += 1
		if frame_ms > _spike_worst_ms:
			_spike_worst_ms = frame_ms
			_spike_worst_process_ms = script_process_ms
			_spike_worst_physics_ms = script_physics_ms
			_spike_worst_process_untraced_ms = process_untraced_ms
			_spike_worst_physics_untraced_ms = physics_untraced_ms
			_spike_worst_physics_steps = physics_steps
			_spike_worst_deferred_ms = deferred_ms
			_spike_worst_scene_flush_ms = scene_flush_ms
			_spike_worst_render_draw_ms = render_draw_ms
			_spike_worst_engine_gap_ms = engine_gap_ms
		return
	if not _spike_open:
		return
	_append_event(&"frame_spike", "Frame spike", _spike_details(now), now)
	_spike_open = false


## What the worst frame of a spike was doing, in the same three columns the frame
## ring uses, together with whichever traced subsystems have run since the last
## quarter-second rollup. A spike row that only says "132 ms" starts an
## investigation; one that also says the settlers were in it finishes one.
func _spike_details(now: int) -> Dictionary:
	var engine_ms := maxf(
		_spike_worst_ms - _spike_worst_process_ms - _spike_worst_physics_ms, 0.0)
	return {
		"duration_ms": float(now - _spike_started_usec) / 1000.0,
		"frames": _spike_frames,
		"worst_ms": _spike_worst_ms,
		"worst_fps": 1000.0 / maxf(_spike_worst_ms, 0.001),
		"worst_script_process_ms": _spike_worst_process_ms,
		"worst_script_physics_ms": _spike_worst_physics_ms,
		"worst_process_untraced_ms": _spike_worst_process_untraced_ms,
		"worst_physics_untraced_ms": _spike_worst_physics_untraced_ms,
		# A frame that ran the physics step several times to catch up reports the
		# sum of those steps, so the per-step cost is this many times smaller.
		"worst_physics_steps": _spike_worst_physics_steps,
		"worst_engine_ms": engine_ms,
		"worst_deferred_ms": _spike_worst_deferred_ms,
		"worst_scene_flush_ms": _spike_worst_scene_flush_ms,
		"worst_render_draw_ms": _spike_worst_render_draw_ms,
		"worst_engine_gap_ms": _spike_worst_engine_gap_ms,
		"traced": _hottest_activity(SPIKE_TRACE_ROWS),
	}


## The heaviest few rows accumulated so far this interval, without draining them.
##
## The worst call and the call count come along with the total because the three
## answers are different problems: one 120 ms pass, a thousand small ones, and a
## nested roll-up of both are told apart by nothing else in the record.
func _hottest_activity(rows: int) -> Array:
	var ranked: Array = []
	for category: Variant in _activity:
		var category_rows := _activity[category] as Dictionary
		for label: Variant in category_rows:
			var source := category_rows[label] as Dictionary
			ranked.append({
				"label": "%s/%s" % [category, label],
				"total_ms": float(source.get("total_usec", 0)) / 1000.0,
				"max_ms": float(source.get("max_usec", 0)) / 1000.0,
				"calls": int(source.get("calls", 0)),
			})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["total_ms"]) > float(b["total_ms"]))
	return ranked.slice(0, rows)


## Adds one timed subsystem operation to the next quarter-second rollup.
##
## Called from hot code only when [method deep_enabled] is true. The row is
## cumulative rather than one event per beam tick or settler stage, which keeps a
## sustained attack useful without filling the event ring with hundreds of copies.
func record_activity(category: StringName, label: StringName, elapsed_usec: int,
		amount := 0.0, calls := 1) -> void:
	if not _deep_enabled:
		return
	var category_value: Variant = _activity.get(category)
	var category_rows: Dictionary = (
		category_value if category_value is Dictionary else {})
	if not category_value is Dictionary:
		_activity[category] = category_rows
	var row_value: Variant = category_rows.get(label)
	var row: Dictionary = row_value if row_value is Dictionary else {}
	if not row_value is Dictionary:
		row = {
			"calls": 0,
			"total_usec": 0,
			"max_usec": 0,
			"amount": 0.0,
		}
		category_rows[label] = row
	row["calls"] = int(row["calls"]) + maxi(calls, 0)
	row["total_usec"] = int(row["total_usec"]) + maxi(elapsed_usec, 0)
	row["max_usec"] = maxi(int(row["max_usec"]), maxi(elapsed_usec, 0))
	row["amount"] = float(row["amount"]) + amount
	if elapsed_usec < HOT_ACTIVITY_USEC:
		return
	var now := Time.get_ticks_usec()
	var key := "%s/%s" % [category, label]
	if now - int(_hot_activity_at.get(key, 0)) < HOT_ACTIVITY_COOLDOWN_USEC:
		return
	_hot_activity_at[key] = now
	_append_event(&"subsystem_hotspot", key, {
		"elapsed_ms": float(elapsed_usec) / 1000.0,
		"amount": amount,
	}, now)


## Adds one timed subsystem operation that is a whole scripted process callback.
##
## Summing subsystem rows to check them against the step they ran in does not work,
## because the rows nest: a Meep colony's whole physics step, the simulation pass
## inside it and the walk stage inside that are all rows, so the total exceeds the
## step and the remainder clamps to nothing. That is the one number worth having,
## because it is the one that says an expensive callback has no label at all — a
## 57 ms physics frame was once invisible for exactly this reason. Only whole
## callback bodies report through these two, and they never overlap each other, so
## the step minus their sum is uninstrumented code and nothing else.
func record_process_step(category: StringName, label: StringName,
		elapsed_usec: int, amount := 0.0, calls := 1) -> void:
	if not _deep_enabled:
		return
	_frame_process_attributed_usec += maxi(elapsed_usec, 0)
	record_activity(category, label, elapsed_usec, amount, calls)


## As [method record_process_step], for a whole [method Node._physics_process].
func record_physics_step(category: StringName, label: StringName,
		elapsed_usec: int, amount := 0.0, calls := 1) -> void:
	if not _deep_enabled:
		return
	_frame_physics_attributed_usec += maxi(elapsed_usec, 0)
	record_activity(category, label, elapsed_usec, amount, calls)


func mark_event(kind: StringName, label: String,
		details: Dictionary = {}) -> void:
	_append_event(kind, label, details, Time.get_ticks_usec())


func _append_event(kind: StringName, label: String, details: Dictionary,
		at_usec: int) -> void:
	_events.append({
		"at_usec": at_usec,
		"kind": String(kind),
		"label": label,
		"details": _json_safe(details),
	})
	while _events.size() > EVENT_CAPACITY:
		_events.pop_front()


func _collect_coarse(now: int) -> void:
	var began := Time.get_ticks_usec()
	var world := _active_world()
	var clock := began
	var activity := _drain_activity()
	var phases := {"activity": _since(clock)}
	clock = Time.get_ticks_usec()
	var snapshot := {
		"at_usec": now,
		"paused": get_tree().paused,
		"time_scale": Engine.time_scale,
		# Shared rather than copied. The inventory is rebuilt whole once a second
		# and nothing writes into a published one, so four copies a second of a
		# thirty-entry census would be the recorder's own largest cost.
		"scene": _scene_inventory,
		"terrain": {},
		"meeps": {},
		"flora": {},
		"fauna": {},
		"aerial": _collect_aerial(),
		"bosses": _collect_bosses(world),
		"network": _network_snapshot(),
		"activity": activity,
	}
	phases["scene"] = _since(clock)
	if world != null:
		clock = Time.get_ticks_usec()
		var planet := world.find_child("Planet", true, false)
		if planet != null and planet.has_method(&"statistics"):
			var terrain := planet.call(&"statistics") as Dictionary
			var shape_value: Variant = planet.get("shape")
			if shape_value is PlanetShape:
				var planet_shape := shape_value as PlanetShape
				if planet_shape.scars != null:
					terrain["scars"] = planet_shape.scars.count()
			snapshot["terrain"] = _json_safe(terrain)
		phases["terrain"] = _since(clock)
		clock = Time.get_ticks_usec()
		if world.has_method(&"meep_colonies"):
			var colonies := world.call(&"meep_colonies") as Node
			if colonies != null and colonies.has_method(&"statistics"):
				snapshot["meeps"] = _json_safe(
					colonies.call(&"statistics") as Dictionary)
		phases["meeps"] = _since(clock)
		clock = Time.get_ticks_usec()
		snapshot["flora"] = _collect_flora(world)
		phases["flora"] = _since(clock)
		clock = Time.get_ticks_usec()
		snapshot["fauna"] = _collect_fauna()
		phases["fauna"] = _since(clock)
	snapshot["frame_budget"] = _frame_budget(activity)
	# Flora reports its streaming stages through a shared ledger rather than as
	# activity rows. They are measured time all the same, so the budget must not
	# call them unexplained.
	_credit_traced(snapshot["frame_budget"] as Dictionary,
		_phase_total_ms((snapshot["flora"] as Dictionary).get(
			"phase_ms", {}) as Dictionary))
	snapshot["telemetry_ms"] = (
		float(Time.get_ticks_usec() - began) / 1000.0)
	snapshot["telemetry_phase_ms"] = phases
	_coarse.append(snapshot)
	while _coarse.size() > COARSE_CAPACITY:
		_coarse.pop_front()


func _since(clock: int) -> float:
	return float(Time.get_ticks_usec() - clock) / 1000.0


## Where the wall clock of this quarter-second went.
##
## Subsystem rows can only be read against the time there was to spend. This
## divides the interval into the scripted process step, the scripted physics
## steps, and everything the engine did with no script running, then says how
## much of the scripted half the traced rows above actually account for.
## [code]untraced_script_ms[/code] is the number that says whether the next
## measurement should add instrumentation or start optimising. It is the sum of
## the two per-step remainders measured frame by frame, not the difference
## between the step and the row list: the rows nest, so that difference is always
## negative in a busy world and always reads as zero.
func _frame_budget(activity: Array) -> Dictionary:
	var frames := maxi(_interval_frames, 1)
	var traced_ms := 0.0
	for row_value: Variant in activity:
		traced_ms += float((row_value as Dictionary).get("total_ms", 0.0))
	var untraced_ms := (_interval_process_untraced_usec
		+ _interval_physics_untraced_usec) / 1000.0
	var budget := {
		"frames": _interval_frames,
		"wall_ms": _interval_wall_usec / 1000.0,
		"script_process_ms": _interval_process_usec / 1000.0,
		"script_physics_ms": _interval_physics_usec / 1000.0,
		"process_untraced_ms": _interval_process_untraced_usec / 1000.0,
		"physics_untraced_ms": _interval_physics_untraced_usec / 1000.0,
		"engine_ms": _interval_engine_usec / 1000.0,
		"deferred_ms": _interval_deferred_usec / 1000.0,
		"scene_flush_ms": _interval_scene_flush_usec / 1000.0,
		"render_draw_ms": _interval_render_draw_usec / 1000.0,
		"engine_gap_ms": _interval_engine_gap_usec / 1000.0,
		"gpu_ms": _interval_gpu_usec / 1000.0,
		"recorder_ms": float(_interval_recorder_usec) / 1000.0,
		"traced_ms": traced_ms,
		"untraced_script_ms": untraced_ms,
		# More than one per frame means the engine is catching up on a frame that
		# overran, and the scripted physics column is that many steps added together.
		"physics_steps_per_frame": float(_interval_physics_steps) / float(frames),
		"per_frame_ms": {
			"wall": _interval_wall_usec / 1000.0 / float(frames),
			"script_process": _interval_process_usec / 1000.0 / float(frames),
			"script_physics": _interval_physics_usec / 1000.0 / float(frames),
			"process_untraced": (
				_interval_process_untraced_usec / 1000.0 / float(frames)),
			"physics_untraced": (
				_interval_physics_untraced_usec / 1000.0 / float(frames)),
			"engine": _interval_engine_usec / 1000.0 / float(frames),
			"deferred": _interval_deferred_usec / 1000.0 / float(frames),
			"scene_flush": (
				_interval_scene_flush_usec / 1000.0 / float(frames)),
			"render_draw": (
				_interval_render_draw_usec / 1000.0 / float(frames)),
			"engine_gap": (
				_interval_engine_gap_usec / 1000.0 / float(frames)),
			"traced": traced_ms / float(frames),
			"untraced_script": untraced_ms / float(frames),
		},
	}
	_interval_frames = 0
	_interval_wall_usec = 0.0
	_interval_process_usec = 0.0
	_interval_physics_usec = 0.0
	_interval_process_untraced_usec = 0.0
	_interval_physics_untraced_usec = 0.0
	_interval_engine_usec = 0.0
	_interval_deferred_usec = 0.0
	_interval_scene_flush_usec = 0.0
	_interval_render_draw_usec = 0.0
	_interval_engine_gap_usec = 0.0
	_interval_gpu_usec = 0.0
	_interval_recorder_usec = 0
	_interval_physics_steps = 0
	return budget


func _phase_total_ms(phases: Dictionary) -> float:
	var total := 0.0
	for phase: Variant in phases:
		total += float(phases[phase])
	return total


## Adds time that was measured somewhere other than an activity row to the traced
## column. The unexplained column is measured per frame against whole callbacks and
## is not touched: these stages ran inside one, so they were never in it.
func _credit_traced(budget: Dictionary, traced_ms: float) -> void:
	if traced_ms <= 0.0:
		return
	var frames := maxf(float(budget.get("frames", 1)), 1.0)
	budget["traced_ms"] = float(budget.get("traced_ms", 0.0)) + traced_ms
	var per_frame := budget.get("per_frame_ms", {}) as Dictionary
	per_frame["traced"] = float(budget["traced_ms"]) / frames


func _drain_activity() -> Array:
	var rows: Array = []
	for category: Variant in _activity:
		var category_rows := _activity[category] as Dictionary
		for label: Variant in category_rows:
			var source := category_rows[label] as Dictionary
			rows.append({
				"category": String(category),
				"label": String(label),
				"calls": int(source.get("calls", 0)),
				"total_ms": float(source.get("total_usec", 0)) / 1000.0,
				"max_ms": float(source.get("max_usec", 0)) / 1000.0,
				"amount": float(source.get("amount", 0.0)),
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["total_ms"]) > float(b["total_ms"]))
	_activity.clear()
	return rows


func _collect_flora(world: Node) -> Dictionary:
	var totals := {
		"fields": 0,
		"tiles": 0,
		"pending_tiles": 0,
		"finished_tiles": 0,
		"wanted_tiles": 0,
		"survey_cells": 0,
		"survey_tasks": 0,
		"damage_cells": 0,
		"harvest_targets": 0,
		"prune_backlog": 0,
		"glow_lights": 0,
	}
	for field_variant: Variant in get_tree().get_nodes_in_group(
			&"flora_damage_fields"):
		var field := field_variant as Node
		if field == null or _world_of(field) != world:
			continue
		totals["fields"] = int(totals["fields"]) + 1
		if not field.has_method(&"statistics"):
			continue
		var stats := field.call(&"statistics") as Dictionary
		for key: String in totals:
			if key == "fields":
				continue
			if stats.has(key):
				totals[key] = int(totals[key]) + int(stats[key])
	# GroundCover's phase ledger is shared by every field. Read and clear it once
	# through the class; the individual field rows above would otherwise repeat it.
	if not GroundCover.phase_cost.is_empty():
		var phases := {}
		for phase: Variant in GroundCover.phase_cost:
			phases[String(phase)] = (
				float(GroundCover.phase_cost[phase]) / 1000.0)
		totals["phase_ms"] = phases
		GroundCover.phase_cost.clear()
	totals["budget"] = FloraBudget.statistics()
	return totals


## Spawner and swarm nodes come from the once-a-second census rather than from a
## typed [method Node.find_children] search. That search walks the entire world
## and tests every node, and it was being run twice for every quarter-second
## sample of a scene with several thousand nodes in it.
func _collect_fauna() -> Dictionary:
	var totals := {
		"spawners": 0,
		"actors": 0,
		"stream_cells": 0,
		"dead_ids": 0,
		"captured_ids": 0,
		"active_lights": 0,
		"last_survey_ms": 0.0,
		"last_survey_checks": 0,
	}
	for candidate: Node in _fauna_spawners:
		if not is_instance_valid(candidate) \
				or not candidate.has_method(&"statistics"):
			continue
		totals["spawners"] = int(totals["spawners"]) + 1
		var stats := candidate.call(&"statistics") as Dictionary
		for key: String in totals:
			if key == "spawners" or not stats.has(key):
				continue
			if totals[key] is float:
				totals[key] = float(totals[key]) + float(stats[key])
			else:
				totals[key] = int(totals[key]) + int(stats[key])
	totals["mobs_in_tree"] = int(_scene_inventory.get("fauna_mobs", 0))
	totals["rhino_dens"] = int(_scene_inventory.get("rhino_dens", 0))
	return totals


func _collect_aerial() -> Dictionary:
	var totals := {
		"fields": 0,
		"swarm": 0,
		"clusters": 0,
		"visible_insects": 0,
		"buffer_uploads": 0,
		"light_pool": 0,
		"lights_active": 0,
		"placement_cache": 0,
	}
	for candidate: Node in _aerial_swarms:
		if not is_instance_valid(candidate) \
				or not candidate.has_method(&"statistics"):
			continue
		totals["fields"] = int(totals["fields"]) + 1
		var stats := candidate.call(&"statistics") as Dictionary
		for key: String in totals:
			if key == "fields" or not stats.has(key):
				continue
			totals[key] = int(totals[key]) + int(stats[key])
	return totals


func _collect_bosses(world: Node) -> Array:
	var bosses: Array = []
	if world == null:
		return bosses
	for boss_variant: Variant in get_tree().get_nodes_in_group(&"bosses"):
		var boss := boss_variant as Node
		if boss == null or _world_of(boss) != world:
			continue
		var row := {
			"id": String(boss.call(&"boss_id")) \
				if boss.has_method(&"boss_id") else String(boss.name),
			"health": float(boss.call(&"health")) \
				if boss.has_method(&"health") else 0.0,
			"maximum_health": float(boss.call(&"maximum_health")) \
				if boss.has_method(&"maximum_health") else 0.0,
			"processing": boss.is_processing(),
			"physics_processing": boss.is_physics_processing(),
		}
		bosses.append(row)
	return bosses


func _network_snapshot() -> Dictionary:
	return {
		"session_state": int(NetworkManager.state),
		"players": NetworkManager.players.size(),
		"single_player": NetworkManager.is_single_player,
		"host": NetworkManager.is_host,
		"mode": String(NetworkManager.session_options.get("mode", "")),
		"voice_packets_sent": VoiceChat.packets_sent,
		"voice_transmitting": VoiceChat.transmitting,
		"peer_status": int(multiplayer.multiplayer_peer.get_connection_status()) \
			if multiplayer.has_multiplayer_peer() else -1,
	}


## One walk of the world, once a second, that answers everything the recorder
## would otherwise ask the tree for four times a second.
##
## The census is the important half. A frame budget can say that eleven
## milliseconds of scripted work is not accounted for by any traced subsystem;
## only a count of which classes are running [method Node._process] and
## [method Node._physics_process] says where to look for it.
func _collect_scene_inventory(world: Node) -> Dictionary:
	var result := {
		"nodes": 0,
		"visible_geometry": 0,
		"mesh_instances": 0,
		"multimeshes": 0,
		"multimesh_instances": 0,
		"lights": 0,
		"visible_lights": 0,
		"shadow_lights": 0,
		"particles": 0,
		"emitting_particles": 0,
		"decals": 0,
		"audio_players_3d": 0,
		"playing_audio_3d": 0,
		"processing_nodes": 0,
		"physics_processing_nodes": 0,
		"processing_census": [],
		"combatants": _count_group_in_world(&"combatants", world),
		"bosses": _count_group_in_world(&"bosses", world),
		"fauna_mobs": _count_group_in_world(&"fauna_mobs", world),
		"rhino_dens": _count_group_in_world(&"rhino_dens", world),
		"ability_walls": 0,
	}
	if world == null:
		_fauna_spawners.clear()
		_aerial_swarms.clear()
		return result
	if world.has_method(&"active_ability_wall_count"):
		result["ability_walls"] = int(world.call(&"active_ability_wall_count"))
	_fauna_spawners.clear()
	_aerial_swarms.clear()
	var census: Dictionary = {}
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		result["nodes"] = int(result["nodes"]) + 1
		for child: Node in node.get_children():
			stack.append(child)
		var runs := node.is_processing()
		var solves := node.is_physics_processing()
		if runs or solves:
			if runs:
				result["processing_nodes"] = int(result["processing_nodes"]) + 1
			if solves:
				result["physics_processing_nodes"] = int(
					result["physics_processing_nodes"]) + 1
			_census_add(census, node, runs, solves)
		if node is FaunaSpawner:
			_fauna_spawners.append(node)
		elif node is AerialSwarm:
			_aerial_swarms.append(node)
		if node is GeometryInstance3D and (node as GeometryInstance3D).visible:
			result["visible_geometry"] = int(result["visible_geometry"]) + 1
		if node is MeshInstance3D:
			result["mesh_instances"] = int(result["mesh_instances"]) + 1
		if node is MultiMeshInstance3D:
			var holder := node as MultiMeshInstance3D
			result["multimeshes"] = int(result["multimeshes"]) + 1
			if holder.multimesh != null:
				result["multimesh_instances"] = (
					int(result["multimesh_instances"])
					+ holder.multimesh.visible_instance_count)
		if node is Light3D:
			var light := node as Light3D
			result["lights"] = int(result["lights"]) + 1
			if light.visible and light.light_energy > 0.001:
				result["visible_lights"] = int(result["visible_lights"]) + 1
			if light.shadow_enabled:
				result["shadow_lights"] = int(result["shadow_lights"]) + 1
		if node is GPUParticles3D:
			result["particles"] = int(result["particles"]) + 1
			if (node as GPUParticles3D).emitting:
				result["emitting_particles"] = (
					int(result["emitting_particles"]) + 1)
		elif node is CPUParticles3D:
			result["particles"] = int(result["particles"]) + 1
			if (node as CPUParticles3D).emitting:
				result["emitting_particles"] = (
					int(result["emitting_particles"]) + 1)
		if node is Decal and (node as Decal).visible:
			result["decals"] = int(result["decals"]) + 1
		if node is AudioStreamPlayer3D:
			result["audio_players_3d"] = int(result["audio_players_3d"]) + 1
			if (node as AudioStreamPlayer3D).playing:
				result["playing_audio_3d"] = (
					int(result["playing_audio_3d"]) + 1)
	result["processing_census"] = _ranked_census(census)
	return result


func _census_add(census: Dictionary, node: Node, runs: bool,
		solves: bool) -> void:
	var key := _class_key(node)
	var row_value: Variant = census.get(key)
	var row: Dictionary = row_value if row_value is Dictionary else {
		"process": 0,
		"physics": 0,
	}
	if not row_value is Dictionary:
		census[key] = row
	if runs:
		row["process"] = int(row["process"]) + 1
	if solves:
		row["physics"] = int(row["physics"]) + 1


func _class_key(node: Node) -> String:
	var script_value: Variant = node.get_script()
	if script_value is Script:
		var script := script_value as Script
		var global := script.get_global_name()
		if global != &"":
			return String(global)
		var path := script.resource_path
		if not path.is_empty():
			return path.get_file().get_basename()
	return node.get_class()


func _ranked_census(census: Dictionary) -> Array:
	var rows: Array = []
	for key: Variant in census:
		var row := census[key] as Dictionary
		rows.append({
			"script": String(key),
			"process": int(row.get("process", 0)),
			"physics": int(row.get("physics", 0)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["process"]) + int(a["physics"]) \
			> int(b["process"]) + int(b["physics"]))
	return rows.slice(0, CENSUS_ROWS)


func _count_group_in_world(group: StringName, world: Node) -> int:
	if world == null:
		return 0
	var count := 0
	for value: Variant in get_tree().get_nodes_in_group(group):
		var node := value as Node
		if node != null and _world_of(node) == world:
			count += 1
	return count


func _active_world() -> Node:
	if is_instance_valid(_active_world_cache) \
			and _active_world_cache.is_inside_tree():
		return _active_world_cache
	var players := get_tree().get_nodes_in_group(&"network_players")
	if not players.is_empty():
		_active_world_cache = _world_of(players[0] as Node)
		if _active_world_cache != null:
			return _active_world_cache
	var current := get_tree().current_scene
	if current != null:
		_active_world_cache = _find_world_below(current)
	return _active_world_cache


func _find_world_below(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method(&"meep_colonies") and node.find_child(
			"Planet", true, false) != null:
		return node
	for child: Node in node.get_children():
		var found := _find_world_below(child)
		if found != null:
			return found
	return null


func _world_of(node: Node) -> Node:
	var walk := node
	while walk != null:
		if walk.has_method(&"meep_colonies") \
				and walk.find_child("Planet", true, false) != null:
			return walk
		walk = walk.get_parent()
	return null


## Points are `(second in the 30-second window, FPS)`, always ordered oldest first.
func fps_series() -> PackedVector2Array:
	var points := PackedVector2Array()
	var now := _history_now()
	var from := now - WINDOW_USEC
	for logical in _frame_count:
		var slot := _frame_slot(logical)
		var at_usec := int(_frame_times[slot])
		if at_usec < from:
			continue
		points.append(Vector2(
			float(at_usec - from) / 1000000.0,
			_frame_values[slot * FRAME_STRIDE + F_FPS]))
	return points


func summary() -> Dictionary:
	var now := _history_now()
	var from := now - WINDOW_USEC
	var ranked: Array[float] = []
	var total_ms := 0.0
	var worst_ms := 0.0
	var spikes := 0
	var current_ms := 0.0
	var first_usec := now
	var last_usec := now
	for logical in _frame_count:
		var slot := _frame_slot(logical)
		var at_usec := int(_frame_times[slot])
		if at_usec < from:
			continue
		var frame_ms := float(
			_frame_values[slot * FRAME_STRIDE + F_FRAME_MS])
		ranked.append(frame_ms)
		total_ms += frame_ms
		worst_ms = maxf(worst_ms, frame_ms)
		if frame_ms >= SPIKE_MS:
			spikes += 1
		if ranked.size() == 1:
			first_usec = at_usec
		last_usec = at_usec
		current_ms = frame_ms
	ranked.sort()
	var count := ranked.size()
	var mean_ms := total_ms / maxf(float(count), 1.0)
	return {
		"samples": count,
		"seconds": float(last_usec - first_usec) / 1000000.0 \
			if count > 1 else 0.0,
		"current_fps": 1000.0 / maxf(current_ms, 0.001) \
			if count > 0 else 0.0,
		"mean_fps": 1000.0 / maxf(mean_ms, 0.001) if count > 0 else 0.0,
		"one_percent_low_fps": 1000.0 / maxf(
			_percentile(ranked, 0.99), 0.001) if count > 0 else 0.0,
		"p95_ms": _percentile(ranked, 0.95),
		"p99_ms": _percentile(ranked, 0.99),
		"worst_ms": worst_ms,
		"spike_frames": spikes,
		"spike_threshold_ms": SPIKE_MS,
		"deep_tracing": _deep_enabled,
	}


func latest_snapshot() -> Dictionary:
	return _coarse.back().duplicate(true) if not _coarse.is_empty() else {}


func latest_frame() -> Dictionary:
	if _frame_count <= 0:
		return {}
	var slot := posmod(_frame_head - 1, FRAME_CAPACITY)
	var base := slot * FRAME_STRIDE
	var row := {}
	for field in FRAME_STRIDE:
		row[FRAME_FIELDS[field]] = float(_frame_values[base + field])
	return row


func recent_events() -> Array:
	var out: Array = []
	var now := _history_now()
	var from := now - WINDOW_USEC
	for source: Dictionary in _events:
		var at_usec := int(source.get("at_usec", 0))
		if at_usec < from:
			continue
		out.append({
			"seconds_ago": float(now - at_usec) / 1000000.0,
			"kind": String(source.get("kind", "")),
			"label": String(source.get("label", "")),
			"details": (source.get("details", {}) as Dictionary).duplicate(true),
		})
	if _spike_open and _spike_started_usec >= from:
		out.append({
			"seconds_ago": float(now - _spike_started_usec) / 1000000.0,
			"kind": "frame_spike",
			"label": "Frame spike still in progress",
			"details": _spike_details(now),
		})
	return out


func deep_enabled() -> bool:
	return _deep_enabled


func set_deep_enabled(enabled: bool) -> void:
	if _deep_enabled == enabled:
		return
	_deep_enabled = enabled
	_activity.clear()
	mark_event(&"telemetry", "Detailed tracing %s" % (
		"enabled" if enabled else "disabled"))


func last_export_path() -> String:
	return _last_export


func export_last_window() -> Dictionary:
	var now := _history_now()
	var from := now - WINDOW_USEC
	var frames: Array = []
	for logical in _frame_count:
		var slot := _frame_slot(logical)
		var at_usec := int(_frame_times[slot])
		if at_usec < from:
			continue
		var row := {"t": float(at_usec - from) / 1000000.0}
		var base := slot * FRAME_STRIDE
		for field in FRAME_STRIDE:
			row[FRAME_FIELDS[field]] = float(_frame_values[base + field])
		frames.append(row)
	var snapshots: Array = []
	for source: Dictionary in _coarse:
		var at_usec := int(source.get("at_usec", 0))
		if at_usec < from:
			continue
		var row := source.duplicate(true)
		row.erase("at_usec")
		row["t"] = float(at_usec - from) / 1000000.0
		snapshots.append(_json_safe(row))
	var events: Array = []
	for source: Dictionary in _events:
		var at_usec := int(source.get("at_usec", 0))
		if at_usec < from:
			continue
		events.append({
			"t": float(at_usec - from) / 1000000.0,
			"kind": String(source.get("kind", "")),
			"label": String(source.get("label", "")),
			"details": _json_safe(source.get("details", {})),
		})
	if _spike_open and _spike_started_usec >= from:
		events.append({
			"t": float(_spike_started_usec - from) / 1000000.0,
			"kind": "frame_spike",
			"label": "Frame spike still in progress",
			"details": _json_safe(_spike_details(now)),
		})
	var payload := {
		"schema": "my-strange-planet-performance-flight-recorder-v5",
		"captured_at": Time.get_datetime_string_from_system(false, true),
		"window_seconds": WINDOW_SECONDS,
		"spike_threshold_ms": SPIKE_MS,
		"frame_fields": FRAME_FIELDS,
		"frame_units": FRAME_UNITS,
		"summary": summary(),
		"environment": _environment(),
		"frames": frames,
		"snapshots": snapshots,
		"events": events,
		"notes": [
			"t is seconds from the start of the exported 30-second window.",
			"frames are per rendered frame; snapshots are quarter-second subsystem state.",
			"frame_ms = script_process_ms + script_physics_ms + engine_ms, all measured this frame.",
			"engine_ms is time outside the two scripted steps, and splits into deferred_ms + scene_flush_ms + render_draw_ms + engine_gap_ms.",
			"deferred_ms is between the last _physics_process callback and the first _process callback: the physics solver plus the deferred queue, so a long call_deferred lands here and nowhere else.",
			"scene_flush_ms is after the last _process callback and before the draw: the scene tree freeing everything queue_free'd during the step.",
			"render_draw_ms is between frame_pre_draw and frame_post_draw: uploads, pipelines, the draw list and the swap.",
			"engine_gap_ms is what is left of the span from the end of the draw to the next frame's first script: operating-system events, physics queries, and any wait.",
			"process_untraced_ms and physics_untraced_ms are the part of each scripted step no whole-callback row claimed: uninstrumented game code, and nothing else.",
			"process_peak_ms and physics_peak_ms are Godot's own monitors, which report the worst step of the previous whole second.",
			"snapshots[].frame_budget.untraced_script_ms is the two untraced remainders added together over the interval.",
			"snapshots[].scene.processing_census counts nodes by script running _process / _physics_process.",
			"activity rows are totals inside their snapshot interval; max_ms is the worst single call in it.",
			"events[].details.traced ranks the interval's activity rows, roll-ups included, so read max_ms and calls together.",
			"Attach this JSON file directly to a performance bug report.",
		],
	}
	var absolute_dir := ProjectSettings.globalize_path(EXPORT_DIR)
	var make_error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if make_error != OK:
		return {
			"ok": false,
			"message": "Could not create performance log folder (error %d)." \
				% make_error,
		}
	var clock := Time.get_datetime_dict_from_system()
	var filename := "performance_%04d-%02d-%02d_%02d-%02d-%02d.json" % [
		int(clock["year"]), int(clock["month"]), int(clock["day"]),
		int(clock["hour"]), int(clock["minute"]), int(clock["second"]),
	]
	var resource_path := "%s/%s" % [EXPORT_DIR, filename]
	var file := FileAccess.open(resource_path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"message": "Could not write performance log (error %d)." \
				% FileAccess.get_open_error(),
		}
	file.store_string(JSON.stringify(payload, "\t", true, false))
	file.close()
	_last_export = ProjectSettings.globalize_path(resource_path)
	mark_event(&"telemetry", "Exported performance log", {
		"path": _last_export,
		"frames": frames.size(),
		"snapshots": snapshots.size(),
	})
	return {
		"ok": true,
		"path": _last_export,
		"message": "Saved %d frames and %d subsystem samples." % [
			frames.size(), snapshots.size()],
	}


func open_export_folder() -> Error:
	var absolute := ProjectSettings.globalize_path(EXPORT_DIR)
	var make_error := DirAccess.make_dir_recursive_absolute(absolute)
	if make_error != OK:
		return make_error
	return OS.shell_open(absolute)


func clear_history() -> void:
	_frame_head = 0
	_frame_count = 0
	_coarse.clear()
	_events.clear()
	_activity.clear()
	_hot_activity_at.clear()
	_spike_open = false
	_interval_frames = 0
	_interval_wall_usec = 0.0
	_interval_process_usec = 0.0
	_interval_physics_usec = 0.0
	_interval_engine_usec = 0.0
	_interval_deferred_usec = 0.0
	_interval_scene_flush_usec = 0.0
	_interval_render_draw_usec = 0.0
	_interval_engine_gap_usec = 0.0
	_interval_gpu_usec = 0.0
	_interval_recorder_usec = 0
	_recorder_usec = 0
	if _physics_closer != null:
		_physics_closer.take()
	if _physics_opener != null:
		_physics_opener.take_between()
	_paused_last_frame = get_tree().paused
	_previous_frame_usec = Time.get_ticks_usec()
	mark_event(&"telemetry", "Performance history cleared")


func _environment() -> Dictionary:
	var root := get_tree().root
	var render_size := DisplayServer.window_get_size()
	if root != null and root.get_texture() != null:
		render_size = root.get_texture().get_size()
	return {
		"engine": Engine.get_version_info(),
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"processor": OS.get_processor_name(),
		"processor_count": OS.get_processor_count(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_vendor": RenderingServer.get_video_adapter_vendor(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"window_size": _vector2i_array(DisplayServer.window_get_size()),
		"render_size": _vector2i_array(render_size),
		"render_scale": root.scaling_3d_scale if root != null else 1.0,
		"msaa_3d": int(root.msaa_3d) if root != null else 0,
		"vsync_mode": int(DisplayServer.window_get_vsync_mode()),
		"max_fps": Engine.max_fps,
		"graphics": {
			"render_distance": SettingsManager.get_setting(
				&"graphics", &"render_distance", 1),
			"flora_range": SettingsManager.get_setting(
				&"graphics", &"flora_range", 2.0),
			"shadows": SettingsManager.get_setting(
				&"graphics", &"shadows", true),
			"glow": SettingsManager.get_setting(
				&"graphics", &"glow", true),
			"god_rays": SettingsManager.get_setting(
				&"graphics", &"god_rays", true),
		},
		"session": _network_snapshot(),
	}


func _frame_slot(logical: int) -> int:
	var oldest := posmod(_frame_head - _frame_count, FRAME_CAPACITY)
	return (oldest + logical) % FRAME_CAPACITY


func _history_now() -> int:
	if _frame_count > 0:
		var newest := posmod(_frame_head - 1, FRAME_CAPACITY)
		return int(_frame_times[newest])
	return Time.get_ticks_usec()


func _percentile(ranked: Array[float], share: float) -> float:
	if ranked.is_empty():
		return 0.0
	var index := clampi(
		ceili(clampf(share, 0.0, 1.0) * float(ranked.size())) - 1,
		0, ranked.size() - 1)
	return ranked[index]


func _vector2i_array(value: Vector2i) -> Array:
	return [value.x, value.y]


func _json_safe(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[String(key)] = _json_safe(value[key])
		return out
	if value is Array:
		var out: Array = []
		for entry: Variant in value:
			out.append(_json_safe(entry))
		return out
	if value is PackedStringArray:
		return Array(value)
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Color:
		return value.to_html(true)
	if value is StringName:
		return String(value)
	if value is Object:
		return str(value)
	return value
