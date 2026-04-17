-- MetricCollector.luau
-- Accumulates per-run telemetry and produces a RunMetrics table.
-- prd_plan.md §15.4, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type RunMetrics = Types.RunMetrics

local MetricCollector = {}

local _maxLateralError = 0
local _maxVerticalDisplacement = 0
local _baselineY = 0
local _airborne = false
local _everAirborne = false
local _airDistance = 0
local _everReacquired = false
local _lastPosition = Vector3.zero
local _hasLastPosition = false
local _sectorEntrySpeed: { [number]: number } = {}
local _sectorExitSpeed: { [number]: number } = {}

-- Start collecting metrics for a new run.
function MetricCollector.reset(baselineY: number)
	_maxLateralError = 0
	_maxVerticalDisplacement = 0
	_baselineY = baselineY
	_airborne = false
	_everAirborne = false
	_airDistance = 0
	_everReacquired = false
	_lastPosition = Vector3.zero
	_hasLastPosition = false
	_sectorEntrySpeed = {}
	_sectorExitSpeed = {}
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
	_maxLateralError = math.max(_maxLateralError, math.abs(lateralError))
	_maxVerticalDisplacement = math.max(_maxVerticalDisplacement, math.abs(position.Y - _baselineY))

	if _airborne and _hasLastPosition then
		_airDistance += (position - _lastPosition).Magnitude
	end

	if isAirborne and not _airborne then
		_airborne = true
		_everAirborne = true
	elseif not isAirborne and _airborne then
		_airborne = false
		_everReacquired = true
	end

	_lastPosition = position
	_hasLastPosition = true
end

-- Mark sector entry (called when the car crosses a sector boundary).
function MetricCollector.onSectorEntry(sector_id: number, speed: number)
	_sectorEntrySpeed[sector_id] = speed
end

-- Mark sector exit.
function MetricCollector.onSectorExit(sector_id: number, speed: number)
	_sectorExitSpeed[sector_id] = speed
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
	local reacquired = if _everAirborne then _everReacquired else true

	return {
		entry_speed = _sectorEntrySpeed[targetSector] or 0,
		exit_speed = _sectorExitSpeed[targetSector] or 0,
		airborne = _everAirborne,
		air_distance = _airDistance,
		lateral_error = _maxLateralError,
		vertical_displacement = _maxVerticalDisplacement,
		reacquired = reacquired,
		lap_time = lapTime,
		slowdown_ratio = lapTime / math.max(baselineLapTime, 0.001),
	}
end

return MetricCollector
