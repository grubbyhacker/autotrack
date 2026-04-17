-- TrackGenerator.luau
-- Generates the rectangular track topology at runtime.
-- prd_plan.md §2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

export type SectorKind = "Straight" | "Corner"

export type SectorDescriptor = {
	id: number,
	kind: SectorKind,
	entry: CFrame,
	exit: CFrame,
	partGroup: Folder?,
}

type SectorDescriptorInternal = SectorDescriptor & {
	center: Vector3,
	size: Vector3,
}

local TrackGenerator = {}

local CORNER_SPAN = (Constants.CORNER_RADIUS * 2) + Constants.TRACK_WIDTH
local TRACK_Y = Constants.TRACK_THICKNESS * 0.5
local CAR_RIDE_Y = Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5
local TOP_ROW_Z = 0
local BOTTOM_ROW_Z = CORNER_SPAN

local function edgeCFrame(center: Vector3, edgeOffset: Vector3, lookVector: Vector3): CFrame
	local position = center + edgeOffset
	return CFrame.lookAt(position, position + lookVector)
end

local function buildColumnCenters(cols: number): { number }
	local centers = table.create(cols)
	local cursor = 0

	centers[1] = cursor
	cursor += (CORNER_SPAN * 0.5) + (Constants.STRAIGHT_LENGTH * 0.5)

	for column = 2, cols - 1 do
		centers[column] = cursor
		cursor += Constants.STRAIGHT_LENGTH
	end

	centers[cols] = cursor - (Constants.STRAIGHT_LENGTH * 0.5) + (CORNER_SPAN * 0.5)
	return centers
end

local function straightSector(id: number, center: Vector3, lookVector: Vector3): SectorDescriptorInternal
	local halfTravel = Constants.STRAIGHT_LENGTH * 0.5
	local edgeOffset = lookVector * halfTravel

	return {
		id = id,
		kind = "Straight",
		entry = edgeCFrame(center, -edgeOffset, lookVector),
		exit = edgeCFrame(center, edgeOffset, lookVector),
		partGroup = nil,
		center = center,
		size = Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, Constants.STRAIGHT_LENGTH),
	}
end

local function cornerSector(
	id: number,
	center: Vector3,
	entryOffset: Vector3,
	entryLook: Vector3,
	exitOffset: Vector3,
	exitLook: Vector3
): SectorDescriptorInternal
	return {
		id = id,
		kind = "Corner",
		entry = edgeCFrame(center, entryOffset, entryLook),
		exit = edgeCFrame(center, exitOffset, exitLook),
		partGroup = nil,
		center = center,
		size = Vector3.new(CORNER_SPAN, Constants.TRACK_THICKNESS, CORNER_SPAN),
	}
end

local function buildSectors(rows: number, cols: number): { SectorDescriptorInternal }
	assert(rows == 2, "TrackGenerator.generate currently supports exactly 2 rows")
	assert(cols == 5, "TrackGenerator.generate currently supports the Phase 1 2x5 layout")

	local xCenters = buildColumnCenters(cols)

	local sectors: { SectorDescriptorInternal } = {
		cornerSector(
			1,
			Vector3.new(xCenters[1], TRACK_Y, TOP_ROW_Z),
			Vector3.new(0, 0, CORNER_SPAN * 0.5),
			Vector3.new(0, 0, -1),
			Vector3.new(CORNER_SPAN * 0.5, 0, 0),
			Vector3.new(1, 0, 0)
		),
		straightSector(2, Vector3.new(xCenters[2], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		straightSector(3, Vector3.new(xCenters[3], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		straightSector(4, Vector3.new(xCenters[4], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		cornerSector(
			5,
			Vector3.new(xCenters[5], TRACK_Y, TOP_ROW_Z),
			Vector3.new(-CORNER_SPAN * 0.5, 0, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(0, 0, CORNER_SPAN * 0.5),
			Vector3.new(0, 0, 1)
		),
		cornerSector(
			6,
			Vector3.new(xCenters[5], TRACK_Y, BOTTOM_ROW_Z),
			Vector3.new(0, 0, -CORNER_SPAN * 0.5),
			Vector3.new(0, 0, 1),
			Vector3.new(-CORNER_SPAN * 0.5, 0, 0),
			Vector3.new(-1, 0, 0)
		),
		straightSector(7, Vector3.new(xCenters[4], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		straightSector(8, Vector3.new(xCenters[3], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		straightSector(9, Vector3.new(xCenters[2], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		cornerSector(
			10,
			Vector3.new(xCenters[1], TRACK_Y, BOTTOM_ROW_Z),
			Vector3.new(CORNER_SPAN * 0.5, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(0, 0, -CORNER_SPAN * 0.5),
			Vector3.new(0, 0, -1)
		),
	}

	assert(#sectors == 10, "TrackGenerator.generate: expected exactly 10 sectors")

	for index, sector in ipairs(sectors) do
		local nextSector = sectors[index % #sectors + 1]
		assert(
			(sector.exit.Position - nextSector.entry.Position).Magnitude < 0.001,
			string.format("TrackGenerator.generate: sector %d exit does not mate with sector %d entry", sector.id, nextSector.id)
		)
	end

	return sectors
end

local function buildLapWaypoint(position: Vector3, forward: Vector3): CFrame
	return CFrame.lookAt(position, position + forward)
end

function TrackGenerator.generate(rows: number?, cols: number?): { SectorDescriptor }
	rows = rows or Constants.TRACK_ROWS
	cols = cols or Constants.TRACK_COLS
	return buildSectors(rows, cols)
end

function TrackGenerator.canonicalStart(): CFrame
	local sectors = buildSectors(Constants.TRACK_ROWS, Constants.TRACK_COLS)
	local entry = sectors[1].entry
	return CFrame.new(entry.Position + Vector3.new(0, CAR_RIDE_Y - TRACK_Y, 0)) * (entry - entry.Position)
end

function TrackGenerator.getLapWaypoints(sectors: { SectorDescriptor }): { CFrame }
	local waypoints = {}

	local function ridePos(p: Vector3): Vector3
		return Vector3.new(p.X, CAR_RIDE_Y, p.Z)
	end

	for _, rawSector in ipairs(sectors) do
		local sector = rawSector :: SectorDescriptorInternal

		if sector.kind == "Corner" then
			local entryPosition = sector.entry.Position
			local exitPosition = sector.exit.Position
			local arcDirection = (sector.entry.LookVector + sector.exit.LookVector)
			local arcMidpoint = sector.center + arcDirection.Unit * Constants.CORNER_RADIUS

			table.insert(waypoints, buildLapWaypoint(ridePos(entryPosition), sector.entry.LookVector))
			table.insert(waypoints, buildLapWaypoint(ridePos(arcMidpoint), (exitPosition - entryPosition).Unit))
			table.insert(waypoints, buildLapWaypoint(ridePos(exitPosition), sector.exit.LookVector))
		else
			local midpoint = sector.entry.Position:Lerp(sector.exit.Position, 0.5)
			table.insert(waypoints, buildLapWaypoint(ridePos(midpoint), sector.entry.LookVector))
			table.insert(waypoints, buildLapWaypoint(ridePos(sector.exit.Position), sector.exit.LookVector))
		end
	end

	table.insert(waypoints, buildLapWaypoint(ridePos(sectors[1].entry.Position), sectors[1].entry.LookVector))
	return waypoints
end

function TrackGenerator.buildParts(sectors: { SectorDescriptor }): Folder
	local existingTrack = workspace:FindFirstChild("Track")
	if existingTrack then
		existingTrack:Destroy()
	end

	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "Track"
	trackFolder.Parent = workspace

	for _, rawSector in ipairs(sectors) do
		local sector = rawSector :: SectorDescriptorInternal

		local partFolder = Instance.new("Folder")
		partFolder.Name = string.format("Sector_%02d", sector.id)
		partFolder.Parent = trackFolder

		local part = Instance.new("Part")
		part.Name = string.format("Sector_%02d_%s", sector.id, sector.kind)
		part.Anchored = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = Enum.Material.SmoothPlastic
		part.Size = sector.size
		part.CFrame = CFrame.lookAt(sector.center, sector.center + sector.exit.LookVector)
		part:SetAttribute("SectorId", sector.id)
		part:SetAttribute("SectorKind", sector.kind)

		if sector.kind == "Straight" then
			part.BrickColor = BrickColor.new("Dark stone grey")
		else
			part.BrickColor = BrickColor.new("Medium stone grey")
		end

		part.Parent = partFolder
		sector.partGroup = partFolder
	end

	return trackFolder
end

return TrackGenerator
