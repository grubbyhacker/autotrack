-- ChicaneIntegrity.luau
-- Evaluates whether a completed run satisfies Chicane mechanic integrity.
-- prd_plan.md §11.3, §15.7, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ChicanePath = require(script.Parent.Parent.Mechanics.ChicanePath)

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local ChicaneIntegrity = {}

function ChicaneIntegrity.preflight(
	state: SectorState
): (boolean, { string })
	local hints: { string } = {}
	local p = state.params

	-- Geometry-based checks (evaluable without runtime path telemetry)
	if (p.amplitude or 0) < Constants.CHICANE_MIN_LATERAL_DISPLACEMENT then
		table.insert(hints, "amplitude below minimum lateral displacement")
	end
	if (p.amplitude or 0) > Constants.TRACK_WIDTH * 0.5 then
		table.insert(hints, "amplitude exceeds track half-width")
	end

	local transitionLength = p.transition_length or 0
	if transitionLength <= 0 then
		table.insert(hints, "transition_length must be positive")
	elseif (p.amplitude or 0) / transitionLength < Constants.CHICANE_MIN_CURVATURE then
		table.insert(hints, "effective curvature below minimum")
	end

	local totalLength = ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + 3 * transitionLength
	if totalLength > Constants.STRAIGHT_LENGTH then
		table.insert(hints, "geometry exceeds sector length")
	end

	return #hints == 0, hints
end

function ChicaneIntegrity.evaluateRuntime(
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local leftOffset = metrics.target_left_offset or 0
	local rightOffset = metrics.target_right_offset or 0
	local bandChanges = metrics.target_lateral_band_changes or 0
	local peakBodyDistance = metrics.target_peak_body_distance or 0
	local minRuntimeExcursion = (Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5)
		+ Constants.CHICANE_COMFORT_LATERAL_MARGIN
	local maxBodyDistance = Constants.FRONT_BODY_CONTAINMENT_DISTANCE - Constants.CHICANE_COMFORT_BODY_MARGIN

	if leftOffset < minRuntimeExcursion or rightOffset < minRuntimeExcursion then
		table.insert(hints, "runtime lateral excursion too small")
	end

	if bandChanges < Constants.CHICANE_MIN_ALTERNATIONS then
		table.insert(hints, "runtime lateral alternation too small")
	end
	if peakBodyDistance > maxBodyDistance then
		table.insert(hints, "body containment margin too small inside chicane")
	end

	return #hints == 0, hints
end

function ChicaneIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local preflightOk, preflightHints = ChicaneIntegrity.preflight(state)
	local runtimeOk, runtimeHints = ChicaneIntegrity.evaluateRuntime(metrics)

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

return ChicaneIntegrity
