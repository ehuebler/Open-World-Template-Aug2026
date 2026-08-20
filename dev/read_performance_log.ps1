# Reads one exported flight-recorder window and prints what it blames.
#
# The admin panel shows the same window live; this is for after the fact, when the JSON
# has already been exported and the question is which row grew. Activity rows are kept
# per quarter-second snapshot in the file, so they are added up here: total time over
# the window, the worst single call anywhere in it, and the amount of work the row was
# given — plants cut, cells measured — because a slow row cannot be read without
# knowing how much it was asked to do.
#
#   powershell -File dev/read_performance_log.ps1 [-Path <exported.json>] [-Top 40]
#
# With no path it reads the newest export in the user data folder.

param(
	[string]$Path = "",
	[int]$Top = 40
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Path)) {
	$folder = Join-Path $env:APPDATA "Godot\app_userdata\My Strange Planet\performance_logs"
	$newest = Get-ChildItem -Path $folder -Filter "performance_*.json" |
		Sort-Object LastWriteTime -Descending |
		Select-Object -First 1
	if ($null -eq $newest) {
		throw "no exported performance logs in $folder"
	}
	$Path = $newest.FullName
}

$log = Get-Content -Raw -Path $Path | ConvertFrom-Json
$summary = $log.summary
$frames = [math]::Max([int]$summary.samples, 1)

Write-Output ("== {0}   {1}" -f (Split-Path $Path -Leaf), $log.captured_at)
Write-Output ("{0} frames  mean {1:N1} FPS  1% low {2:N1} FPS  p95 {3:N2} ms  p99 {4:N2} ms  worst {5:N2} ms  spikes {6}" -f `
	$summary.samples, $summary.mean_fps, $summary.one_percent_low_fps, `
	$summary.p95_ms, $summary.p99_ms, $summary.worst_ms, $summary.spike_frames)

# The budget is reported per quarter-second snapshot, already divided by that
# interval's frames. Averaging those is the same thing the admin panel shows.
$budget = @{}
$counted = 0
foreach ($snapshot in $log.snapshots) {
	if ($null -eq $snapshot.frame_budget -or $null -eq $snapshot.frame_budget.per_frame_ms) {
		continue
	}
	$counted += 1
	foreach ($field in $snapshot.frame_budget.per_frame_ms.PSObject.Properties) {
		$budget[$field.Name] = [double]$budget[$field.Name] + [double]$field.Value
	}
}
if ($counted -gt 0) {
	Write-Output ""
	Write-Output "-- frame budget, mean ms/frame --"
	foreach ($name in ($budget.Keys | Sort-Object { -[double]$budget[$_] })) {
		Write-Output ("  {0,-26} {1,8:N3}" -f $name, ([double]$budget[$name] / $counted))
	}
}

$tally = @{}
foreach ($snapshot in $log.snapshots) {
	foreach ($row in $snapshot.activity) {
		$key = "{0}/{1}" -f $row.category, $row.label
		if (-not $tally.ContainsKey($key)) {
			$tally[$key] = [pscustomobject]@{
				Row = $key; TotalMs = 0.0; WorstMs = 0.0; Calls = 0; Amount = 0.0
			}
		}
		$kept = $tally[$key]
		$kept.TotalMs += [double]$row.total_ms
		$kept.WorstMs = [math]::Max($kept.WorstMs, [double]$row.max_ms)
		$kept.Calls += [int]$row.calls
		$kept.Amount += [double]$row.amount
	}
}
$ranked = $tally.Values

Write-Output ""
Write-Output "-- rows, by sustained cost --"
Write-Output ("  {0,-40} {1,9} {2,10} {3,9} {4,8} {5,14}" -f `
	"row", "ms/frame", "total ms", "worst ms", "calls", "amount")
foreach ($row in ($ranked | Sort-Object TotalMs -Descending | Select-Object -First $Top)) {
	Write-Output ("  {0,-40} {1,9:N3} {2,10:N0} {3,9:N2} {4,8:N0} {5,14:N0}" -f `
		$row.Row, ($row.TotalMs / $frames), $row.TotalMs, $row.WorstMs, $row.Calls, $row.Amount)
}

Write-Output ""
Write-Output "-- rows, by worst single call --"
Write-Output ("  {0,-40} {1,9} {2,9} {3,8} {4,14}" -f `
	"row", "worst ms", "ms/frame", "calls", "amount")
foreach ($row in ($ranked | Sort-Object WorstMs -Descending | Select-Object -First $Top)) {
	Write-Output ("  {0,-40} {1,9:N2} {2,9:N3} {3,8:N0} {4,14:N0}" -f `
		$row.Row, $row.WorstMs, ($row.TotalMs / $frames), $row.Calls, $row.Amount)
}

$worst = $log.frames | Sort-Object -Property @{ Expression = { [double]$_.frame_ms } } -Descending |
	Select-Object -First 10
Write-Output ""
Write-Output "-- worst 10 frames --"
Write-Output ("  {0,8} {1,8} {2,8} {3,8} {4,5} {5,7} {6,7} {7,7} {8,7} {9,7}" -f `
	"t", "frame", "script", "physics", "steps", "defer", "flush", "draw", "gap", "gpu")
foreach ($frame in $worst) {
	Write-Output ("  {0,8:N2} {1,8:N2} {2,8:N2} {3,8:N2} {4,5:N0} {5,7:N2} {6,7:N2} {7,7:N2} {8,7:N2} {9,7:N2}" -f `
		[double]$frame.t, [double]$frame.frame_ms, [double]$frame.script_process_ms, `
		[double]$frame.script_physics_ms, [double]$frame.physics_steps, [double]$frame.deferred_ms, `
		[double]$frame.scene_flush_ms, [double]$frame.render_draw_ms, `
		[double]$frame.engine_gap_ms, [double]$frame.gpu_ms)
}

$spikes = $log.events | Where-Object { $_.kind -eq "frame_spike" }
if ($null -ne $spikes -and @($spikes).Count -gt 0) {
	Write-Output ""
	Write-Output "-- frame spikes --"
	foreach ($spike in $spikes) {
		$detail = $spike.details
		Write-Output ("  {0,7:N2} s  {1,6:N1} ms over {2} frame(s)  script {3:N1} + physics {4:N1} ({5} step) + defer {6:N1} + draw {7:N1}" -f `
			[double]$spike.t, [double]$detail.worst_ms, $detail.frames, `
			[double]$detail.worst_script_process_ms, [double]$detail.worst_script_physics_ms, `
			$detail.worst_physics_steps, `
			[double]$detail.worst_deferred_ms, [double]$detail.worst_render_draw_ms)
		foreach ($blamed in @($detail.traced) | Select-Object -First 6) {
			if ($null -eq $blamed) { continue }
			Write-Output ("            {0,-38} {1,8:N2} ms  worst {2,7:N2} ms  x{3}" -f `
				("{0}/{1}" -f $blamed.category, $blamed.label),
				[double]$blamed.total_ms, [double]$blamed.max_ms, $blamed.calls)
		}
	}
}
