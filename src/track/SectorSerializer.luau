-- SectorSerializer.luau
-- Converts SectorState ↔ a stable table representation suitable for
-- snapshotting, diffing, and logging.
-- prd_plan.md §15.2, Phase 2

local Types = require(script.Parent.Parent.common.Types)

type SectorState = Types.SectorState

local SectorSerializer = {}

-- Deep-copy a SectorState (used before mutation so rollback has a clean snapshot).
function SectorSerializer.clone(state: SectorState): SectorState
	-- TODO: Phase 2
	error("SectorSerializer.clone: not yet implemented")
end

-- Serialise to a plain table (for logging / LLM context).
function SectorSerializer.toTable(state: SectorState): { [string]: any }
	-- TODO: Phase 2
	error("SectorSerializer.toTable: not yet implemented")
end

return SectorSerializer
