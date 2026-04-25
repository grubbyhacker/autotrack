--!strict

-- SectorRollback.luau
-- Restores a sector to its last committed state after a failed job.
-- prd_plan.md §7.6, Phase 2

local SectorRegistry = require(script.Parent.SectorRegistry)
local SectorApplier = require(script.Parent.SectorApplier)

local SectorRollback = {}

-- Revert sector_id to its committed state.
-- Re-applies the committed geometry via SectorApplier.
function SectorRollback.revert(sector_id: number, entryFrame: CFrame, exitFrame: CFrame)
	local committed = SectorRegistry.getCommitted(sector_id)
	assert(committed, "SectorRollback.revert: no committed state for sector " .. sector_id)
	SectorApplier.apply(committed, entryFrame, exitFrame)
end

return SectorRollback
