-- CrestDipIntegrity.luau
-- Evaluates whether a completed run satisfies CrestDip mechanic integrity.
-- prd_plan.md §11.4, §15.7, Phase 5

local Types = require(script.Parent.Parent.common.Types)
local Constants = require(script.Parent.Parent.common.Constants)

type RunMetrics = Types.RunMetrics
type SectorState = Types.SectorState

local CrestDipIntegrity = {}

function CrestDipIntegrity.evaluate(
	state: SectorState,
	metrics: RunMetrics
): (boolean, { string })
	local hints: { string } = {}
	local p = state.params

	if math.abs(p.height_or_depth or 0) < Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT then
		table.insert(hints, "vertical displacement below minimum")
	end

	if metrics.vertical_displacement < Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT then
		table.insert(hints, "runtime vertical displacement too small")
	end

	if not metrics.reacquired then
		table.insert(hints, "car did not reacquire semi-rail before sector exit")
	end

	return #hints == 0, hints
end

return CrestDipIntegrity
