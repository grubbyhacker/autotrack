-- RampJumpIntegrity.luau
-- Evaluates whether a completed run satisfies RampJump mechanic integrity.
-- prd_plan.md §11.2, §15.7, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local RampJumpIntegrity = {}

-- Returns true if integrity is satisfied, plus a table of hints if not.
function RampJumpIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}

	if (state.params.gap_length or 0) < Constants.RAMPJUMP_MIN_GAP then
		table.insert(hints, "gap_length below minimum (" .. Constants.RAMPJUMP_MIN_GAP .. ")")
	end

	if not metrics.airborne then
		table.insert(hints, "verifier never became airborne")
	end

	if metrics.air_distance < Constants.RAMPJUMP_MIN_AIR_DISTANCE then
		table.insert(hints, "air distance too short (got " .. metrics.air_distance .. ")")
	end

	if not metrics.reacquired then
		table.insert(hints, "semi-rail reacquisition failed after landing")
	end

	-- TODO: Phase 5 — add landing_zone_hit check once zone tracking is in place

	return #hints == 0, hints
end

return RampJumpIntegrity
