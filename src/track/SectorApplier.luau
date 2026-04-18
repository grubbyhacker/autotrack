-- SectorApplier.luau
-- Materialises a SectorState into live geometry via MCP.
-- All geometry changes to the Workspace go through here.
-- prd_plan.md §17 Phase 2, §16.2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local UIState = require(script.Parent.Parent.Orchestrator.UIState)

type SectorState = Types.SectorState

local SectorApplier = {}

local function getSectorFolder(sector_id: number): Folder
	local folderName = string.format("Sector_%02d", sector_id)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(folderName)
	assert(folder and folder:IsA("Folder"), "SectorApplier.getSectorFolder: folder not found: " .. folderName)
	return folder
end

local function ensureBaselinePart(sector_id: number, entryFrame: CFrame, exitFrame: CFrame): BasePart
	local folder = getSectorFolder(sector_id)
	local baselineName = string.format("Sector_%02d_Straight", sector_id)
	local existing = folder:FindFirstChild(baselineName)
	if existing and existing:IsA("BasePart") then
		return existing
	end

	local center = entryFrame.Position:Lerp(exitFrame.Position, 0.5)
	local part = Instance.new("Part")
	part.Name = baselineName
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	part.Size = Vector3.new(16, 2, (exitFrame.Position - entryFrame.Position).Magnitude)
	part.CFrame = CFrame.lookAt(center, center + exitFrame.LookVector)
	part.BrickColor = BrickColor.new("Dark stone grey")
	part:SetAttribute("SectorId", sector_id)
	part:SetAttribute("SectorKind", "Straight")
	part.Parent = folder
	return part
end

local function destroyBaseline(sector_id: number)
	local folder = getSectorFolder(sector_id)
	local baseline = folder:FindFirstChild(string.format("Sector_%02d_Straight", sector_id))
	if baseline then
		baseline:Destroy()
	end
end

-- Clear all mechanic geometry for a sector, leaving only the flat baseline part.
function SectorApplier.clear(sector_id: number)
	local folder = getSectorFolder(sector_id)
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
		ensureBaselinePart(state.sector_id, entryFrame, exitFrame)
		UIState.setSectorMechanic(state.sector_id, nil)
		require(Mechanics.PadBuilder).applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
		print(string.format("[TRACE] apply sector=%d mechanic=flat", state.sector_id))
		return
	end

	local builder
	if state.mechanic == "RampJump" then
		builder = require(Mechanics.RampJumpBuilder)
	elseif state.mechanic == "Chicane" then
		builder = require(Mechanics.ChicaneBuilder)
	elseif state.mechanic == "CrestDip" then
		builder = require(Mechanics.CrestDipBuilder)
	else
		error("unknown mechanic: " .. state.mechanic)
	end

	local ok, err = xpcall(function()
		builder.build(state, entryFrame, exitFrame)
		require(Mechanics.PadBuilder).applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
	end, debug.traceback)
	if not ok then
		-- Builder/pad failures must leave a visible drivable baseline rather than
		-- an empty sector. Clear any partial artifacts and rethrow.
		SectorApplier.clear(state.sector_id)
		ensureBaselinePart(state.sector_id, entryFrame, exitFrame)
		UIState.setSectorMechanic(state.sector_id, nil)
		error(err)
	end

	destroyBaseline(state.sector_id)
	UIState.setSectorMechanic(state.sector_id, state.mechanic)
	print(string.format("[TRACE] apply sector=%d mechanic=%s", state.sector_id, state.mechanic))
end

return SectorApplier
