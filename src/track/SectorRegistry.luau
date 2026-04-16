-- SectorRegistry.luau
-- Maintains the live committed state of all editable straight sectors.
-- prd_plan.md §17 Phase 2
--
-- "Main" state = last committed SectorState per sector_id.
-- On session start all sectors begin as flat (no mechanic, no pads).
-- Jobs mutate a working copy; commit/revert update or restore Main.

local Types = require(script.Parent.Parent.common.Types)

type SectorState = Types.SectorState

local SectorRegistry = {}
SectorRegistry.__index = SectorRegistry

-- Internal state
local _committed: { [number]: SectorState } = {}
local _straightCount: number = 0

-- Called once by the orchestrator after TrackGenerator runs.
function SectorRegistry.init(straightCount: number)
	_straightCount = straightCount
	_committed = {}
	-- TODO: Phase 1 — populate with flat baseline SectorState entries
end

-- Returns the committed state for a sector, or nil if sector_id is out of range.
function SectorRegistry.getCommitted(sector_id: number): SectorState?
	return _committed[sector_id]
end

-- Commits a new state for a sector (called on job success).
function SectorRegistry.commit(state: SectorState)
	assert(state.sector_id >= 1 and state.sector_id <= _straightCount,
		"commit: sector_id out of range")
	_committed[state.sector_id] = state
end

-- Returns the total number of editable straight sectors.
function SectorRegistry.count(): number
	return _straightCount
end

return SectorRegistry
