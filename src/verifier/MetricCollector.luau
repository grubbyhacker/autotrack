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
local _lastClock = 0
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
-- Phase 11 telemetry: time-based hang tracking, peak lateral acceleration,
-- target-sector minimum speed. These feed ChallengeScore.compute.
local _airStartClock = 0
local _targetAirStartClock = 0
local _hangTime = 0           -- longest continuous airborne duration (seconds), lap-global
local _targetHangTime = 0     -- same, restricted to target sector
local _peakLateralG = 0       -- estimated peak lateral acceleration (studs/s²)
local _lastLateralVelocity: Vector3? = nil
local _lastForwardHeading: Vector3? = nil
local _targetMinSpeed = math.huge

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
	_lastClock = os.clock()
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
	_airStartClock = 0
	_targetAirStartClock = 0
	_hangTime = 0
	_targetHangTime = 0
	_peakLateralG = 0
	_lastLateralVelocity = nil
	_lastForwardHeading = nil
	_targetMinSpeed = math.huge
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

	local now = os.clock()
	local dt = now - _lastClock

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

	-- Peak lateral acceleration estimate (ground frames only). We approximate
	-- acceleration magnitude as |Δvelocity| / dt between consecutive ground
	-- samples. At near-constant forward speed this is dominated by the
	-- lateral component, which is what ChallengeScore.lateral cares about.
	-- Airborne frames are excluded because gravity/landing dominates them.
	if not isAirborne and _hasLastPosition and dt > 0 then
		local velocity = (position - _lastPosition) / dt
		if _lastLateralVelocity ~= nil then
			local accel = (velocity - _lastLateralVelocity).Magnitude / dt
			if accel > _peakLateralG then _peakLateralG = accel end
		end
		_lastLateralVelocity = velocity
	elseif isAirborne then
		_lastLateralVelocity = nil
	end

	if isAirborne and not _airborne then
		_airborne = true
		_everAirborne = true
		_currentAirSegment = 0
		_airStartClock = now
	elseif not isAirborne and _airborne then
		_airborne = false
		_everReacquired = true
		if _currentAirSegment > _maxAirSegment then
			_maxAirSegment = _currentAirSegment
		end
		_currentAirSegment = 0
		local segment = now - _airStartClock
		if segment > _hangTime then _hangTime = segment end
	end

	if _insideTargetSector then
		if speed < _targetMinSpeed then _targetMinSpeed = speed end

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
			_targetAirStartClock = now
		elseif not isAirborne and _targetAirborne then
			_targetAirborne = false
			_targetEverReacquired = true
			if _targetCurrentAirSegment > _targetMaxAirSegment then
				_targetMaxAirSegment = _targetCurrentAirSegment
			end
			_targetCurrentAirSegment = 0
			local segment = now - _targetAirStartClock
			if segment > _targetHangTime then _targetHangTime = segment end
		end
	end

	_lastPosition = position
	_hasLastPosition = true
	_lastClock = now
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

	-- Flush any still-open airborne segment into the hang-time maxima. Runs
	-- that terminate airborne (over-cap airtime preflight, downstream bail)
	-- otherwise lose the open segment's duration.
	local now = os.clock()
	if _airborne then
		local segment = now - _airStartClock
		if segment > _hangTime then _hangTime = segment end
	end
	if _targetAirborne then
		local segment = now - _targetAirStartClock
		if segment > _targetHangTime then _targetHangTime = segment end
	end

	local reacquired = if _everAirborne then _everReacquired else true
	-- target-local hang time preferred; fall back to lap-global if the target
	-- sector never went airborne (e.g. Chicane evaluations).
	local hangTime = if _targetHangTime > 0 then _targetHangTime else _hangTime
	local targetMinSpeed = if _targetMinSpeed == math.huge then 0 else _targetMinSpeed

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
		hang_time = hangTime,
		peak_lateral_g = _peakLateralG,
		target_min_speed = targetMinSpeed,
	}
end

return MetricCollector
