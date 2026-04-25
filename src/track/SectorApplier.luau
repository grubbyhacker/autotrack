--!strict

-- SectorApplier.luau
-- Materialises a SectorState into live geometry via MCP.
-- All geometry changes to the Workspace go through here.
-- prd_plan.md §17 Phase 2, §16.2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local UIState = require(script.Parent.Parent.Orchestrator.UIState)
local TrackVisuals = require(script.Parent.TrackVisuals)

type SectorState = Types.SectorState

local SectorApplier = {}

local function getSectorFolder(sector_id: number): Folder
	return TrackVisuals.getSectorFolder(sector_id)
end

local function getNumberAttribute(instance: Instance, name: string, defaultValue: number): number
	local value = instance:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return defaultValue
end

local function getSectorCellCFrameAndSize(folder: Folder): (CFrame, Vector3)
	local anchor = folder:FindFirstChild("Anchor")
	assert(anchor and anchor:IsA("BasePart"), "SectorApplier: missing sector Anchor")
	local size = Vector3.new(
		getNumberAttribute(anchor, "CellSizeX", 1),
		getNumberAttribute(anchor, "CellSizeY", 1),
		getNumberAttribute(anchor, "CellSizeZ", 1)
	)
	return anchor.CFrame, size
end

local function ensureBaselinePart(sector_id: number, entryFrame: CFrame, exitFrame: CFrame): BasePart
	local folder = getSectorFolder(sector_id)
	local collisionFolder = TrackVisuals.getCollisionFolder(folder)
	local visualFolder = TrackVisuals.getVisualFolder(folder)
	local baselineName = string.format("Sector_%02d_Straight", sector_id)
	local existing = collisionFolder:FindFirstChild(baselineName)
	if existing and existing:IsA("BasePart") then
		local cellCFrame, cellSize = getSectorCellCFrameAndSize(folder)
		TrackVisuals.renderStraightFlatVisuals(visualFolder, cellCFrame, cellSize, entryFrame, exitFrame)
		return existing
	end

	local center = entryFrame.Position:Lerp(exitFrame.Position, 0.5)
	local part = TrackVisuals.makeCollisionPart(
		collisionFolder,
		baselineName,
		Vector3.new(16, 2, (exitFrame.Position - entryFrame.Position).Magnitude),
		CFrame.lookAt(center, center + exitFrame.LookVector),
		sector_id,
		"Straight"
	)
	local cellCFrame, cellSize = getSectorCellCFrameAndSize(folder)
	TrackVisuals.renderStraightFlatVisuals(visualFolder, cellCFrame, cellSize, entryFrame, exitFrame)
	return part
end

local function destroyBaseline(sector_id: number)
	local baseline = TrackVisuals.getCollisionFolder(sector_id)
		:FindFirstChild(string.format("Sector_%02d_Straight", sector_id))
	if baseline then
		baseline:Destroy()
	end
	TrackVisuals.clearSectorPresentation(sector_id)
end

-- Clear all mechanic geometry for a sector, leaving only the flat baseline part.
function SectorApplier.clear(sector_id: number)
	local collisionFolder = TrackVisuals.getCollisionFolder(sector_id)
	local visualFolder = TrackVisuals.getVisualFolder(sector_id)
	local baseline = string.format("Sector_%02d_Straight", sector_id)
	local hasBaseline = collisionFolder:FindFirstChild(baseline) ~= nil
	for _, child in ipairs(collisionFolder:GetChildren()) do
		if child.Name ~= baseline then
			child:Destroy()
		end
	end
	if not hasBaseline then
		TrackVisuals.clearSectorPresentation(sector_id)
	elseif #visualFolder:GetChildren() == 0 then
		local folder = getSectorFolder(sector_id)
		local cellCFrame, cellSize = getSectorCellCFrameAndSize(folder)
		local baselinePart = collisionFolder:FindFirstChild(baseline)
		assert(baselinePart and baselinePart:IsA("BasePart"), "SectorApplier.clear: baseline part missing")
		local halfLength = baselinePart.Size.Z * 0.5
		local entry = baselinePart.CFrame * CFrame.new(0, 0, -halfLength)
		local exit = baselinePart.CFrame * CFrame.new(0, 0, halfLength)
		TrackVisuals.renderStraightFlatVisuals(visualFolder, cellCFrame, cellSize, entry, exit)
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

	destroyBaseline(state.sector_id)

	local ok, err = xpcall(function()
		local folder = getSectorFolder(state.sector_id)
		local cellCFrame, cellSize = getSectorCellCFrameAndSize(folder)
		TrackVisuals.renderStraightMechanicShell(TrackVisuals.getVisualFolder(folder), cellCFrame, cellSize)
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

	UIState.setSectorMechanic(state.sector_id, state.mechanic)
	print(string.format("[TRACE] apply sector=%d mechanic=%s", state.sector_id, state.mechanic))
end

return SectorApplier
