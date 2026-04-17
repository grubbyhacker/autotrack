-- SectorApplier.luau
-- Materialises a SectorState into live geometry via MCP.
-- All geometry changes to the Workspace go through here.
-- prd_plan.md §17 Phase 2, §16.2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type SectorState = Types.SectorState

local SectorApplier = {}

local function destroyBaseline(sector_id: number)
	local folderName = string.format("Sector_%02d", sector_id)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(folderName)
	assert(folder, "SectorApplier.destroyBaseline: folder not found: " .. folderName)
	local baseline = folder:FindFirstChild(string.format("Sector_%02d_Straight", sector_id))
	if baseline then
		baseline:Destroy()
	end
end

-- Clear all mechanic geometry for a sector, leaving only the flat baseline part.
function SectorApplier.clear(sector_id: number)
	local folderName = string.format("Sector_%02d", sector_id)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(folderName)
	assert(folder, "SectorApplier.clear: folder not found: " .. folderName)
	local baseline = string.format("Sector_%02d_Straight", sector_id)
	for _, child in ipairs(folder:GetChildren()) do
		if child.Name ~= baseline then
			child:Destroy()
		end
	end
	print("[TRACE] clear sector=" .. sector_id)
end

-- Apply a SectorState to the live Workspace.
-- Tears down existing geometry for that sector then rebuilds from state.
-- Called both for the initial working proposal and for each repair step.
function SectorApplier.apply(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	SectorApplier.clear(state.sector_id)
	-- Lazy-require builders — they error until Phase 4.
	local Mechanics = script.Parent.Parent.Mechanics
	if state.mechanic == nil then
		require(Mechanics.PadBuilder).applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
		print(string.format("[TRACE] apply sector=%d mechanic=flat", state.sector_id))
		return
	elseif state.mechanic == "RampJump" then
		destroyBaseline(state.sector_id)
		require(Mechanics.RampJumpBuilder).build(state, entryFrame, exitFrame)
	elseif state.mechanic == "Chicane" then
		destroyBaseline(state.sector_id)
		require(Mechanics.ChicaneBuilder).build(state, entryFrame, exitFrame)
	elseif state.mechanic == "CrestDip" then
		destroyBaseline(state.sector_id)
		require(Mechanics.CrestDipBuilder).build(state, entryFrame, exitFrame)
	else
		error("unknown mechanic: " .. state.mechanic)
	end
	require(Mechanics.PadBuilder).applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
	print(string.format("[TRACE] apply sector=%d mechanic=%s", state.sector_id, state.mechanic))
end

return SectorApplier
