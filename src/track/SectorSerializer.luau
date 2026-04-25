--!strict
-- SectorSerializer.luau
-- Converts SectorState ↔ a stable table representation suitable for
-- snapshotting, diffing, and logging.
-- prd_plan.md §15.2, Phase 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type JsonObject = Types.JsonObject
type SectorState = Types.SectorState
type SectorParams = Types.SectorParams

local SectorSerializer = {}

local function paramsToJson(params: SectorParams): JsonObject
	return (table.clone(params) :: unknown) :: JsonObject
end

-- Deep-copy a SectorState (used before mutation so rollback has a clean snapshot).
function SectorSerializer.clone(state: SectorState): SectorState
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = table.clone(state.params),
		pads = { ingress = state.pads.ingress, egress = state.pads.egress },
		version = state.version,
	}
end

-- Serialise to a plain table (for logging / LLM context).
function SectorSerializer.toTable(state: SectorState): JsonObject
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = paramsToJson(state.params),
		pads = { ingress = state.pads.ingress, egress = state.pads.egress },
		version = state.version,
	}
end

return SectorSerializer
