-- MetricCollector.luau
-- Accumulates per-run telemetry and produces a RunMetrics table.
-- prd_plan.md §15.4, Phase 5

local Types = require(script.Parent.Parent.common.Types)

type RunMetrics = Types.RunMetrics

local MetricCollector = {}

-- Start collecting metrics for a new run.
function MetricCollector.reset()
	-- TODO: Phase 5 — clear all accumulators
end

-- Record a single frame's telemetry.
-- speed: car speed at this moment
-- position: car world position
-- isAirborne: whether the car is off the ground
-- lateralError: signed distance from track centerline
function MetricCollector.record(
	speed: number,
	position: Vector3,
	isAirborne: boolean,
	lateralError: number
)
	-- TODO: Phase 5
end

-- Mark sector entry (called when the car crosses a sector boundary).
function MetricCollector.onSectorEntry(sector_id: number, speed: number)
	-- TODO: Phase 5
end

-- Mark sector exit.
function MetricCollector.onSectorExit(sector_id: number, speed: number)
	-- TODO: Phase 5
end

-- Produce the final RunMetrics from accumulated data.
-- targetSector: the sector being evaluated (for entry/exit speed selection)
-- lapTime: total lap time in seconds
-- baselineLapTime: baseline lap time for slowdown_ratio
function MetricCollector.finalise(
	targetSector: number,
	lapTime: number,
	baselineLapTime: number
): RunMetrics
	-- TODO: Phase 5
	error("MetricCollector.finalise: not yet implemented")
end

return MetricCollector
