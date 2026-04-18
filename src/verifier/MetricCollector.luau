-- MetricCollector.luau
-- Accumulates per-run telemetry and produces a RunMetrics table.
-- prd_plan.md §15.4, Phase 5; airtime_distance added in Phase 9

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type RunMetrics = Types.RunMetrics

local MetricCollector = {}

local _maxLateralError = 0
local _maxVerticalDisplacement = 0
local _baselineY = 0
local _airborne = false
local _everAirborne = false
local _airDistance = 0
local _currentAirSegment = 0
local _maxAirSegment = 0
local _everReacquired = false
local _lastPosition = Vector3.zero
local _hasLastPosition = false
local _sectorEntrySpeed: { [number]: number } = {}
local _sectorExitSpeed: { [number]: number } = {}
local _targetSector = 0
local _insideTargetSector = false
local _targetEverAirborne = false
local _targetAirborne = false
local _targetAirDistance = 0
local _targetCurrentAirSegment = 0
local _targetMaxAirSegment = 0
local _targetEverReacquired = false
local _targetMaxVerticalDisplacement = 0
local _targetLeftOffset = 0
local _targetRightOffset = 0
local _targetLateralBand = 0
local _targetLateralBandChanges = 0

-- Start collecting metrics for a new run.
function MetricCollector.reset(baselineY: number, targetSector: number?)
	_maxLateralError = 0
	_maxVerticalDisplacement = 0
	_baselineY = baselineY
	_airborne = false
	_everAirborne = false
	_airDistance = 0
	_currentAirSegment = 0
	_maxAirSegment = 0
	_everReacquired = false
	_lastPosition = Vector3.zero
	_hasLastPosition = false
	_sectorEntrySpeed = {}
	_sectorExitSpeed = {}
	_targetSector = targetSector or 0
	_insideTargetSector = false
	_targetEverAirborne = false
	_targetAirborne = false
	_targetAirDistance = 0
	_targetCurrentAirSegment = 0
	_targetMaxAirSegment = 0
	_targetEverReacquired = false
	_targetMaxVerticalDisplacement = 0
	_targetLeftOffset = 0
	_targetRightOffset = 0
	_targetLateralBand = 0
	_targetLateralBandChanges = 0
end

-- Record a single frame's telemetry.
function MetricCollector.record(
	speed: number,
	position: Vector3,
	isAirborne: boolean,
	lateralError: number,
	targetLocalX: number?
)
	_maxLateralError = math.max(_maxLateralError, math.abs(lateralError))
	_maxVerticalDisplacement = math.max(_maxVerticalDisplacement, math.abs(position.Y - _baselineY))

	if _airborne and _hasLastPosition then
		local step = (position - _lastPosition).Magnitude
		_airDistance += step
		_currentAirSegment += step
	end

	if _insideTargetSector and _targetAirborne and _hasLastPosition then
		local step = (position - _lastPosition).Magnitude
		_targetAirDistance += step
		_targetCurrentAirSegment += step
	end

	if isAirborne and not _airborne then
		_airborne = true
		_everAirborne = true
		_currentAirSegment = 0
	elseif not isAirborne and _airborne then
		_airborne = false
		_everReacquired = true
		if _currentAirSegment > _maxAirSegment then
			_maxAirSegment = _currentAirSegment
		end
		_currentAirSegment = 0
	end

	if _insideTargetSector then
		_targetMaxVerticalDisplacement = math.max(
			_targetMaxVerticalDisplacement,
			math.abs(position.Y - _baselineY)
		)

		if targetLocalX ~= nil then
			if targetLocalX < 0 then
				_targetLeftOffset = math.max(_targetLeftOffset, -targetLocalX)
			elseif targetLocalX > 0 then
				_targetRightOffset = math.max(_targetRightOffset, targetLocalX)
			end

			local band = 0
			if targetLocalX <= -Constants.CHICANE_LATERAL_BAND_THRESHOLD then
				band = -1
			elseif targetLocalX >= Constants.CHICANE_LATERAL_BAND_THRESHOLD then
				band = 1
			end

			if band ~= _targetLateralBand then
				_targetLateralBandChanges += 1
				_targetLateralBand = band
			end
		end

		if isAirborne and not _targetAirborne then
			_targetAirborne = true
			_targetEverAirborne = true
			_targetCurrentAirSegment = 0
		elseif not isAirborne and _targetAirborne then
			_targetAirborne = false
			_targetEverReacquired = true
			if _targetCurrentAirSegment > _targetMaxAirSegment then
				_targetMaxAirSegment = _targetCurrentAirSegment
			end
			_targetCurrentAirSegment = 0
		end
	end

	_lastPosition = position
	_hasLastPosition = true
end

-- Mark sector entry.
function MetricCollector.onSectorEntry(sector_id: number, speed: number)
	_sectorEntrySpeed[sector_id] = speed
	if sector_id == _targetSector then
		_insideTargetSector = true
	end
end

-- Mark sector exit.
function MetricCollector.onSectorExit(sector_id: number, speed: number)
	_sectorExitSpeed[sector_id] = speed
	if sector_id == _targetSector then
		if _targetAirborne and _targetCurrentAirSegment > _targetMaxAirSegment then
			_targetMaxAirSegment = _targetCurrentAirSegment
		end
		_insideTargetSector = false
	end
end

function MetricCollector.getTargetMetrics()
	local targetMaxAirSegment = _targetMaxAirSegment
	if _targetAirborne and _targetCurrentAirSegment > targetMaxAirSegment then
		targetMaxAirSegment = _targetCurrentAirSegment
	end

	local targetReacquired = if _targetEverAirborne then _targetEverReacquired else true

	return {
		airborne = _targetEverAirborne,
		air_distance = _targetAirDistance,
		vertical_displacement = _targetMaxVerticalDisplacement,
		reacquired = targetReacquired,
		airtime_distance = targetMaxAirSegment,
		left_offset = _targetLeftOffset,
		right_offset = _targetRightOffset,
		lateral_band_changes = _targetLateralBandChanges,
		in_target_sector = _insideTargetSector,
	}
end

-- Produce the final RunMetrics from accumulated data.
function MetricCollector.finalise(
	targetSector: number,
	lapTime: number,
	baselineLapTime: number
): RunMetrics
	if _airborne and _currentAirSegment > _maxAirSegment then
		_maxAirSegment = _currentAirSegment
	end

	local reacquired = if _everAirborne then _everReacquired else true

	return {
		entry_speed = _sectorEntrySpeed[targetSector] or 0,
		exit_speed = _sectorExitSpeed[targetSector] or 0,
		airborne = _everAirborne,
		air_distance = _airDistance,
		lateral_error = _maxLateralError,
		vertical_displacement = _maxVerticalDisplacement,
		reacquired = reacquired,
		airtime_distance = _maxAirSegment,
		target_airborne = _targetEverAirborne,
		target_air_distance = _targetAirDistance,
		target_vertical_displacement = _targetMaxVerticalDisplacement,
		target_reacquired = if _targetEverAirborne then _targetEverReacquired else true,
		target_airtime_distance = if _targetAirborne and _targetCurrentAirSegment > _targetMaxAirSegment
			then _targetCurrentAirSegment
			else _targetMaxAirSegment,
		target_left_offset = _targetLeftOffset,
		target_right_offset = _targetRightOffset,
		target_lateral_band_changes = _targetLateralBandChanges,
		lap_time = lapTime,
		slowdown_ratio = lapTime / math.max(baselineLapTime, 0.001),
	}
end

return MetricCollector
