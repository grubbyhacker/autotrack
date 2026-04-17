-- SectorSerializer.luau
-- Converts SectorState ↔ a stable table representation suitable for
-- snapshotting, diffing, and logging.
-- prd_plan.md §15.2, Phase 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type SectorState = Types.SectorState

local SectorSerializer = {}

-- Deep-copy a SectorState (used before mutation so rollback has a clean snapshot).
function SectorSerializer.clone(state: SectorState): SectorState
	local params = {}
	for k, v in pairs(state.params) do params[k] = v end
	return {
		sector_id = state.sector_id,
		mechanic  = state.mechanic,
		params    = params,
		pads      = { ingress = state.pads.ingress, egress = state.pads.egress },
		version   = state.version,
	}
end

-- Serialise to a plain table (for logging / LLM context).
function SectorSerializer.toTable(state: SectorState): { [string]: any }
	local params = {}
	for k, v in pairs(state.params) do params[k] = v end
	return {
		sector_id = state.sector_id,
		mechanic  = state.mechanic,
		params    = params,
		pads      = { ingress = state.pads.ingress, egress = state.pads.egress },
		version   = state.version,
	}
end

return SectorSerializer
