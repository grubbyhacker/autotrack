-- RampJumpIntegrity.luau
-- Evaluates whether a completed run satisfies RampJump mechanic integrity.
-- prd_plan.md §11.2, §15.7, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local RampJumpIntegrity = {}

function RampJumpIntegrity.preflight(
	state: SectorState
): (boolean, { string })
	local hints: { string } = {}

	if (state.params.gap_length or 0) < Constants.RAMPJUMP_MIN_GAP then
		table.insert(hints, "gap_length below minimum (" .. Constants.RAMPJUMP_MIN_GAP .. ")")
	end

	return #hints == 0, hints
end

function RampJumpIntegrity.evaluateRuntime(
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local reacquired = if metrics.target_reacquired ~= nil then metrics.target_reacquired else metrics.reacquired
	local reacquireDistance = metrics.target_reacquire_distance
	if reacquireDistance == nil then
		reacquireDistance = if metrics.target_airtime_distance ~= nil
			then metrics.target_airtime_distance
			else metrics.airtime_distance
	end
	local verticalDisplacement = if metrics.target_vertical_displacement ~= nil
		then metrics.target_vertical_displacement
		else metrics.vertical_displacement
	local exitAngularSpeed = metrics.target_exit_angular_speed or 0
	local exitVerticalSpeed = metrics.target_exit_vertical_speed or 0
	local minVerticalDisplacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT
		+ Constants.RAMPJUMP_COMFORT_VERTICAL_MARGIN
	local maxReacquireDistance = math.max(0, Constants.RAMPJUMP_REACQUIRE_MAX - Constants.RAMPJUMP_COMFORT_REACQUIRE_MARGIN)

	if type(verticalDisplacement) ~= "number" then
		table.insert(hints, "vertical displacement missing")
	elseif verticalDisplacement < minVerticalDisplacement then
		table.insert(hints, "vertical displacement too small (got " .. verticalDisplacement .. ")")
	end

	if not reacquired then
		table.insert(hints, "semi-rail reacquisition failed after landing")
	end
	if type(reacquireDistance) == "number" and reacquireDistance > maxReacquireDistance then
		table.insert(hints, "reacquire margin too small after landing")
	end
	if exitAngularSpeed > Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED then
		table.insert(hints, "exit angular speed too high after landing")
	end
	if exitVerticalSpeed > Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED then
		table.insert(hints, "exit vertical speed too high after landing")
	end

	-- TODO: Phase 5 — add landing_zone_hit check once zone tracking is in place

	return #hints == 0, hints
end

-- Returns true if integrity is satisfied, plus a table of hints if not.
function RampJumpIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local preflightOk, preflightHints = RampJumpIntegrity.preflight(state)
	local runtimeOk, runtimeHints = RampJumpIntegrity.evaluateRuntime(metrics)

	if not preflightOk then
		for _, hint in ipairs(preflightHints) do
			table.insert(hints, hint)
		end
	end
	if not runtimeOk then
		for _, hint in ipairs(runtimeHints) do
			table.insert(hints, hint)
		end
	end

	return #hints == 0, hints
end

return RampJumpIntegrity
