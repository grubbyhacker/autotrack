-- TestPhase2.luau
-- Verifies Phase 2 deliverables: SectorSerializer, SectorApplier, SectorRollback,
-- and sector entry/exit trace output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local SectorSerializer = require(script.Parent.Parent.Track.SectorSerializer)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRollback = require(script.Parent.Parent.Track.SectorRollback)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local Tracer = require(script.Parent.Tracer)
local T = require(script.Parent.TestUtils)

local TestPhase2 = {}

type SectorState = Types.SectorState

local function makeFlatState(sector_id: number): SectorState
	return {
		sector_id = sector_id,
		mechanic = nil,
		params = {},
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function getSector2Frames()
	local sectors = TrackGenerator.generate()
	for _, s in ipairs(sectors) do
		if s.id == 2 then
			return s.entry, s.exit
		end
	end
	error("sector 2 not found")
end

function TestPhase2.run()
	-- serializer_clone_independent
	local orig: SectorState = {
		sector_id = 2,
		mechanic = nil,
		params = { ramp_angle = 30 },
		pads = { ingress = "None", egress = "None" },
		version = 1,
	}
	local cloned = SectorSerializer.clone(orig)
	cloned.params.ramp_angle = 999
	T.expect("serializer_clone_independent", orig.params.ramp_angle == 30, "mutating clone.params affected original")

	-- serializer_clone_fields
	T.expect(
		"serializer_clone_fields",
		cloned.sector_id == 2 and cloned.mechanic == nil and cloned.version == 1,
		"cloned fields incorrect"
	)

	-- serializer_to_table_fields
	local tbl = SectorSerializer.toTable(orig)
	T.expect(
		"serializer_to_table_fields",
		tbl.sector_id == 2 and tbl.mechanic == nil and tbl.version == 1 and tbl.params ~= nil and tbl.pads ~= nil,
		"toTable missing required fields"
	)

	-- applier_clear_leaves_baseline
	local entry2, exit2 = getSector2Frames()
	SectorApplier.clear(2)
	local track = workspace:FindFirstChild("Track")
	local folder2 = track and track:FindFirstChild("Sector_02")
	local collisionFolder = folder2 and folder2:FindFirstChild("Collision")
	local visualFolder = folder2 and folder2:FindFirstChild("Visual")
	local childCount = collisionFolder and collisionFolder:IsA("Folder") and #collisionFolder:GetChildren() or -1
	local visualCount = visualFolder and visualFolder:IsA("Folder") and #visualFolder:GetChildren() or -1
	T.expect(
		"applier_clear_leaves_baseline",
		folder2 ~= nil and childCount == 1 and visualCount >= 1,
		string.format("Sector_02 collision=%d visual=%d after clear", childCount, visualCount)
	)

	-- applier_apply_flat_noop
	SectorApplier.apply(makeFlatState(2), entry2, exit2)
	local afterCount = collisionFolder and collisionFolder:IsA("Folder") and #collisionFolder:GetChildren() or -1
	T.expect(
		"applier_apply_flat_noop",
		folder2 ~= nil and afterCount == 1,
		string.format("Sector_02 collision has %d children after flat apply (expected 1)", afterCount)
	)

	-- rollback_restores_state
	local committed = SectorRegistry.getCommitted(2)
	if committed then
		local snapshot = SectorSerializer.clone(committed)
		SectorApplier.apply(makeFlatState(2), entry2, exit2)
		SectorRollback.revert(2, entry2, exit2)
		local reverted = SectorRegistry.getCommitted(2)
		T.expect(
			"rollback_restores_state",
			reverted ~= nil
				and reverted.sector_id == snapshot.sector_id
				and reverted.mechanic == snapshot.mechanic
				and reverted.version == snapshot.version,
			"committed state changed after revert"
		)
	else
		T.fail("rollback_restores_state", "no committed state for sector 2")
	end

	-- trace tests — inspect the in-memory log from the boot lap
	local log = Tracer.getLog()
	local function hasTrace(pattern: string): boolean
		for _, line in ipairs(log) do
			if string.find(line, pattern, 1, true) then
				return true
			end
		end
		return false
	end

	T.expect("trace_lap_start", hasTrace("lap_start"), "lap_start not found in trace log")
	T.expect("trace_sector_enter", hasTrace("sector_enter 2"), "sector_enter 2 not found in trace log")
	T.expect("trace_lap_complete", hasTrace("lap_complete"), "lap_complete not found in trace log")
end

return TestPhase2
