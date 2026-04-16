-- PadBuilder.luau
-- Places ingress/egress pad geometry for a sector.
-- prd_plan.md §5, Phase 4
--
-- Pad values: "None" | "Boost" | "Brake"
-- Fixed magnitudes from Constants — no arbitrary numeric strengths.
-- No stacking.

local Types = require(script.Parent.Parent.common.Types)
local Constants = require(script.Parent.Parent.common.Constants)

type Pads = Types.Pads

local PadBuilder = {}

-- Place (or remove) the ingress and egress pads for a sector.
-- padAreaStart: CFrame where the ingress pad should be positioned
-- padAreaEnd:   CFrame where the egress pad should be positioned
function PadBuilder.applyPads(pads: Pads, ingressFrame: CFrame, egressFrame: CFrame)
	-- TODO: Phase 4 — for each pad, either remove any existing pad part or
	-- create a new colored trigger part with the appropriate tag.
	error("PadBuilder.applyPads: not yet implemented")
end

return PadBuilder
