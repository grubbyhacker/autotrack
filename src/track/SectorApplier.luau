-- SectorApplier.luau
-- Materialises a SectorState into live geometry via MCP.
-- All geometry changes to the Workspace go through here.
-- prd_plan.md §17 Phase 2, §16.2
--
-- NOTE: This module calls the appropriate mechanic builder (RampJumpBuilder etc.)
-- and issues MCP commands to update physical parts in the Workspace.
-- It does NOT create Luau scripts in Studio — those live in /src.

local Types = require(script.Parent.Parent.common.Types)

type SectorState = Types.SectorState

local SectorApplier = {}

-- Apply a SectorState to the live Workspace.
-- Tears down existing geometry for that sector then rebuilds from state.
-- Called both for the initial working proposal and for each repair step.
function SectorApplier.apply(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	-- TODO: Phase 2/4 — dispatch to the appropriate mechanic builder,
	-- then apply pads via PadBuilder.
	error("SectorApplier.apply: not yet implemented")
end

-- Clear all geometry for a sector, leaving only the flat baseline surface.
function SectorApplier.clear(sector_id: number)
	-- TODO: Phase 2
	error("SectorApplier.clear: not yet implemented")
end

return SectorApplier
