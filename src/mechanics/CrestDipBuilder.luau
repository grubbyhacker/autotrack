-- CrestDipBuilder.luau
-- Builds CrestDip (vertical crest or dip) geometry from a SectorState.
-- prd_plan.md §4.3, Phase 4
--
-- height_or_depth > 0 → crest (rises above baseline)
-- height_or_depth < 0 → dip  (drops below baseline)

local Types = require(script.Parent.Parent.common.Types)

type SectorState = Types.SectorState

local CrestDipBuilder = {}

function CrestDipBuilder.build(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	local p = state.params
	assert(p.height_or_depth, "CrestDipBuilder: missing height_or_depth")
	assert(p.radius,          "CrestDipBuilder: missing radius")
	assert(p.sector_length,   "CrestDipBuilder: missing sector_length")

	-- TODO: Phase 4
	error("CrestDipBuilder.build: not yet implemented")
end

return CrestDipBuilder
