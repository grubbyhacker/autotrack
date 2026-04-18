-- FailureDetector.luau
-- Watches for definitive run failures and terminates the run immediately.
-- prd_plan.md §6.5, §12, Phase 3
--
-- Failure classes:
--   mechanic_integrity_failure  — mechanic-specific integrity check failed
--   local_execution_failure     — car could not traverse the edited sector
--   downstream_failure          — car failed in a sector other than the edited one
--   system_failure              — timeout or unexpected runtime error

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type FailureInfo = Types.FailureInfo

local FailureDetector = {}
local _stallStartTime: number? = nil
local _noProgressStartTime: number? = nil
local _noProgressStartPosition: Vector3? = nil
local _overturnStartTime: number? = nil
local _invalidAttitudeStartTime: number? = nil
local _backwardStartTime: number? = nil

function FailureDetector.reset()
	_stallStartTime = nil
	_noProgressStartTime = nil
	_noProgressStartPosition = nil
	_overturnStartTime = nil
	_invalidAttitudeStartTime = nil
	_backwardStartTime = nil
end

-- Called each frame during a run.
-- Returns a FailureInfo if a definitive failure is detected, else nil.
-- elapsed: seconds since run start
-- currentSector: which sector the car is currently in (1-based straight index)
function FailureDetector.check(
	elapsed: number,
	currentSector: number,
	carPosition: Vector3,
	trackCenterlinePoint: Vector3,
	isAirborne: boolean,
	speed: number,
	angularSpeed: number,
	upDot: number,
	forwardDot: number?
): FailureInfo?
	if elapsed >= Constants.LAP_TIMEOUT then
		return { type = "system_failure", sector_id = currentSector, detail = "lap_timeout" }
	end

	if carPosition.Y < -50 then
		return { type = "local_execution_failure", sector_id = currentSector, detail = "fell_below_kill_plane" }
	end

	if not isAirborne and (carPosition - trackCenterlinePoint).Magnitude > Constants.TRACK_WIDTH * 1.5 then
		return { type = "local_execution_failure", sector_id = currentSector, detail = "off_track" }
	end

	if upDot <= Constants.OVERTURN_UP_DOT_THRESHOLD then
		if _overturnStartTime == nil then
			_overturnStartTime = elapsed
		else
			local threshold = if isAirborne
				then Constants.AIRBORNE_OVERTURN_TIME_THRESHOLD
				else Constants.OVERTURN_TIME_THRESHOLD
			if elapsed - _overturnStartTime >= threshold then
				return { type = "local_execution_failure", sector_id = currentSector, detail = "overturn" }
			end
		end
	else
		_overturnStartTime = nil
	end

	if not isAirborne and upDot <= Constants.INVALID_ATTITUDE_UP_DOT_THRESHOLD then
		if _invalidAttitudeStartTime == nil then
			_invalidAttitudeStartTime = elapsed
		elseif elapsed - _invalidAttitudeStartTime >= Constants.INVALID_ATTITUDE_TIME_THRESHOLD then
			return { type = "local_execution_failure", sector_id = currentSector, detail = "invalid_attitude" }
		end
	else
		_invalidAttitudeStartTime = nil
	end

	local facingDot = forwardDot or 1
	if not isAirborne and facingDot <= Constants.BACKWARD_FACING_DOT_THRESHOLD then
		if _backwardStartTime == nil then
			_backwardStartTime = elapsed
		elseif elapsed - _backwardStartTime >= Constants.BACKWARD_FACING_TIME_THRESHOLD then
			return { type = "local_execution_failure", sector_id = currentSector, detail = "backward_facing" }
		end
	else
		_backwardStartTime = nil
	end

	if speed <= Constants.STALL_SPEED_THRESHOLD and angularSpeed <= Constants.CRASH_ANGULAR_SPEED_THRESHOLD then
		if _noProgressStartTime == nil or _noProgressStartPosition == nil then
			_noProgressStartTime = elapsed
			_noProgressStartPosition = carPosition
		elseif (carPosition - _noProgressStartPosition).Magnitude <= Constants.NO_PROGRESS_DISTANCE_THRESHOLD
			and elapsed - _noProgressStartTime >= Constants.NO_PROGRESS_TIME_THRESHOLD then
			return { type = "local_execution_failure", sector_id = currentSector, detail = "no_progress" }
		elseif (carPosition - _noProgressStartPosition).Magnitude > Constants.NO_PROGRESS_DISTANCE_THRESHOLD then
			_noProgressStartTime = elapsed
			_noProgressStartPosition = carPosition
		end
	else
		_noProgressStartTime = nil
		_noProgressStartPosition = nil
	end

	if not isAirborne and speed <= Constants.STALL_SPEED_THRESHOLD then
		if _stallStartTime == nil then
			_stallStartTime = elapsed
		elseif elapsed - _stallStartTime >= Constants.STALL_TIME_THRESHOLD then
			return { type = "local_execution_failure", sector_id = currentSector, detail = "stall" }
		end
	else
		_stallStartTime = nil
	end

	return nil
end

return FailureDetector
