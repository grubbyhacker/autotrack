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
	local airborne = if metrics.target_airborne ~= nil then metrics.target_airborne else metrics.airborne
	local airDistance = metrics.target_air_distance or metrics.air_distance
	local reacquired = if metrics.target_reacquired ~= nil then metrics.target_reacquired else metrics.reacquired

	if not airborne then
		table.insert(hints, "verifier never became airborne")
	end

	if airDistance < Constants.RAMPJUMP_MIN_AIR_DISTANCE then
		table.insert(hints, "air distance too short (got " .. airDistance .. ")")
	end

	if not reacquired then
		table.insert(hints, "semi-rail reacquisition failed after landing")
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
