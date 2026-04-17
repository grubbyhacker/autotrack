-- ChicaneIntegrity.luau
-- Evaluates whether a completed run satisfies Chicane mechanic integrity.
-- prd_plan.md §11.3, §15.7, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local ChicaneIntegrity = {}

function ChicaneIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local p = state.params

	-- Geometry-based checks (evaluable without runtime path telemetry)
	if (p.amplitude or 0) < Constants.CHICANE_MIN_LATERAL_DISPLACEMENT then
		table.insert(hints, "amplitude below minimum lateral displacement")
	end

	local transitionLength = p.transition_length or 0
	if transitionLength <= 0 then
		table.insert(hints, "transition_length must be positive")
	elseif (p.amplitude or 0) / transitionLength < Constants.CHICANE_MIN_CURVATURE then
		table.insert(hints, "effective curvature below minimum")
	end

	-- TODO: Phase 5 — add runtime alternation and speed-management checks
	-- once the metric collector tracks lateral path data through the sector.

	return #hints == 0, hints
end

return ChicaneIntegrity
