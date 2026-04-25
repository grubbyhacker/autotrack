--!strict

-- SectorRegistry.luau
-- Maintains the live committed state of all editable straight sectors.
-- prd_plan.md §17 Phase 2
--
-- "Main" state = last committed SectorState per sector_id.
-- On session start all sectors begin as flat (no mechanic, no pads).
-- Jobs mutate a working copy; commit/revert update or restore Main.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type SectorState = Types.SectorState

local SectorRegistry = {}

-- Internal state
local _committed: { [number]: SectorState } = {}
local _straightCount: number = 0
local _straightSectorIds: { number } = { 2, 3, 4, 7, 8, 9 }

-- Called once by the orchestrator after TrackGenerator runs.
function SectorRegistry.init(straightCount: number)
	assert(straightCount == #_straightSectorIds, "SectorRegistry.init: unexpected straightCount")
	_straightCount = straightCount
	_committed = {}

	for _, sectorId in ipairs(_straightSectorIds) do
		_committed[sectorId] = {
			sector_id = sectorId,
			mechanic = nil,
			params = {},
			pads = {
				ingress = "None",
				egress = "None",
			},
			version = 0,
		}
	end
end

-- Returns the committed state for a sector, or nil if sector_id is out of range.
function SectorRegistry.getCommitted(sector_id: number): SectorState?
	return _committed[sector_id]
end

function SectorRegistry.get(sector_id: number): SectorState?
	return SectorRegistry.getCommitted(sector_id)
end

function SectorRegistry.getStraights(): { SectorState }
	local states: { SectorState } = {}

	for _, sectorId in ipairs(_straightSectorIds) do
		local state = _committed[sectorId]
		if state then
			table.insert(states, state)
		end
	end

	return states
end

-- Commits a new state for a sector (called on job success).
function SectorRegistry.commit(state: SectorState)
	assert(_committed[state.sector_id] ~= nil, "commit: sector_id is not an editable straight")
	_committed[state.sector_id] = state
end

-- Returns the total number of editable straight sectors.
function SectorRegistry.count(): number
	return _straightCount
end

return SectorRegistry
