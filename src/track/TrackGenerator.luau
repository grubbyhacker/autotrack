-- TrackGenerator.luau
-- Generates the rectangular track topology at runtime.
-- prd_plan.md §2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ChicanePath = require(
	game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("ChicanePath")
)
local CrestDipPath = require(
	game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("CrestDipPath")
)
local RampJumpPath = require(
	game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("RampJumpPath")
)
local CornerPath = require(script.Parent.CornerPath)
local TrackVisuals = require(script.Parent.TrackVisuals)

local TrackGenerator = {}

local CORNER_CORE_SPAN = (Constants.CORNER_RADIUS * 2) + Constants.TRACK_WIDTH
local CORNER_SPAN_X = CORNER_CORE_SPAN
	+ math.max(0, Constants.CORNER_EDITABLE_SHOULDER_LENGTH - Constants.CORNER_CORNER_SHOULDER_LENGTH) * 2
local CORNER_SPAN_Z = CORNER_CORE_SPAN
local TRACK_Y = Constants.TRACK_THICKNESS * 0.5
local CAR_RIDE_Y = Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5
local TOP_ROW_Z = 0
local BOTTOM_ROW_Z = CORNER_SPAN_Z

local function edgeCFrame(center, edgeOffset, lookVector)
	local position = center + edgeOffset
	return CFrame.lookAt(position, position + lookVector)
end

local function buildColumnCenters(cols)
	local centers = table.create(cols)
	local cursor = 0

	centers[1] = cursor
	cursor += (CORNER_SPAN_X * 0.5) + (Constants.STRAIGHT_LENGTH * 0.5)

	for column = 2, cols - 1 do
		centers[column] = cursor
		cursor += Constants.STRAIGHT_LENGTH
	end

	centers[cols] = cursor - (Constants.STRAIGHT_LENGTH * 0.5) + (CORNER_SPAN_X * 0.5)
	return centers
end

local function straightSector(id, center, lookVector)
	local halfTravel = Constants.STRAIGHT_LENGTH * 0.5
	local edgeOffset = lookVector * halfTravel

	return {
		id = id,
		kind = "Straight",
		entry = edgeCFrame(center, -edgeOffset, lookVector),
		exit = edgeCFrame(center, edgeOffset, lookVector),
		partGroup = nil,
		cellCFrame = CFrame.lookAt(center, center + lookVector),
		cellSize = Vector3.new(CORNER_CORE_SPAN, Constants.TRACK_THICKNESS, Constants.STRAIGHT_LENGTH),
		center = center,
		size = Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, Constants.STRAIGHT_LENGTH),
	}
end

local function cornerSector(
	id,
	center,
	entryOffset,
	entryLook,
	exitOffset,
	exitLook,
	cellSize,
	entryShoulderLength,
	exitShoulderLength
)
	local cellCFrame = CFrame.lookAt(center, center + exitLook)
	return {
		id = id,
		kind = "Corner",
		entry = edgeCFrame(center, entryOffset, entryLook),
		exit = edgeCFrame(center, exitOffset, exitLook),
		partGroup = nil,
		cellCFrame = cellCFrame,
		cellSize = cellSize,
		center = center,
		size = cellSize,
		entryShoulderLength = entryShoulderLength,
		exitShoulderLength = exitShoulderLength,
	}
end

local function buildSectors(rows, cols)
	assert(rows == 2, "TrackGenerator.generate currently supports exactly 2 rows")
	assert(cols == 5, "TrackGenerator.generate currently supports the Phase 1 2x5 layout")

	local xCenters = buildColumnCenters(cols)

	local sectors = {
		cornerSector(
			1,
			Vector3.new(xCenters[1], TRACK_Y, TOP_ROW_Z),
			Vector3.new(0, 0, CORNER_SPAN_Z * 0.5),
			Vector3.new(0, 0, -1),
			Vector3.new(CORNER_SPAN_X * 0.5, 0, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(CORNER_SPAN_X, Constants.TRACK_THICKNESS, CORNER_SPAN_Z),
			Constants.CORNER_CORNER_SHOULDER_LENGTH,
			Constants.CORNER_EDITABLE_SHOULDER_LENGTH
		),
		straightSector(2, Vector3.new(xCenters[2], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		straightSector(3, Vector3.new(xCenters[3], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		straightSector(4, Vector3.new(xCenters[4], TRACK_Y, TOP_ROW_Z), Vector3.new(1, 0, 0)),
		cornerSector(
			5,
			Vector3.new(xCenters[5], TRACK_Y, TOP_ROW_Z),
			Vector3.new(-CORNER_SPAN_X * 0.5, 0, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(0, 0, CORNER_SPAN_Z * 0.5),
			Vector3.new(0, 0, 1),
			Vector3.new(CORNER_SPAN_X, Constants.TRACK_THICKNESS, CORNER_SPAN_Z),
			Constants.CORNER_EDITABLE_SHOULDER_LENGTH,
			Constants.CORNER_CORNER_SHOULDER_LENGTH
		),
		cornerSector(
			6,
			Vector3.new(xCenters[5], TRACK_Y, BOTTOM_ROW_Z),
			Vector3.new(0, 0, -CORNER_SPAN_Z * 0.5),
			Vector3.new(0, 0, 1),
			Vector3.new(-CORNER_SPAN_X * 0.5, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(CORNER_SPAN_X, Constants.TRACK_THICKNESS, CORNER_SPAN_Z),
			Constants.CORNER_CORNER_SHOULDER_LENGTH,
			Constants.CORNER_EDITABLE_SHOULDER_LENGTH
		),
		straightSector(7, Vector3.new(xCenters[4], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		straightSector(8, Vector3.new(xCenters[3], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		straightSector(9, Vector3.new(xCenters[2], TRACK_Y, BOTTOM_ROW_Z), Vector3.new(-1, 0, 0)),
		cornerSector(
			10,
			Vector3.new(xCenters[1], TRACK_Y, BOTTOM_ROW_Z),
			Vector3.new(CORNER_SPAN_X * 0.5, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(0, 0, -CORNER_SPAN_Z * 0.5),
			Vector3.new(0, 0, -1),
			Vector3.new(CORNER_SPAN_X, Constants.TRACK_THICKNESS, CORNER_SPAN_Z),
			Constants.CORNER_EDITABLE_SHOULDER_LENGTH,
			Constants.CORNER_CORNER_SHOULDER_LENGTH
		),
	}

	assert(#sectors == 10, "TrackGenerator.generate: expected exactly 10 sectors")

	for index, sector in ipairs(sectors) do
		local nextSector = sectors[index % #sectors + 1]
		assert(
			(sector.exit.Position - nextSector.entry.Position).Magnitude < 0.001,
			string.format(
				"TrackGenerator.generate: sector %d exit does not mate with sector %d entry",
				sector.id,
				nextSector.id
			)
		)
	end

	return sectors
end

local function buildLapWaypoint(position, forward)
	return CFrame.lookAt(position, position + forward)
end

local function worldPoint(entryFrame, point)
	return entryFrame.Position
		+ entryFrame.RightVector * point.X
		+ entryFrame.UpVector * point.Y
		+ entryFrame.LookVector * point.Z
end

local function buildStraightWaypoints(waypoints, waypointSectorIds, sector, overrideState)
	local function ridePos(p)
		return Vector3.new(p.X, CAR_RIDE_Y, p.Z)
	end

	local function ridePosY(p, liftY)
		return Vector3.new(p.X, CAR_RIDE_Y + liftY, p.Z)
	end

	local function appendStraightGuideWaypoints()
		local spacing = math.max(8, Constants.STRAIGHT_GUIDE_SPACING)
		local guideCount = math.max(1, math.floor(Constants.STRAIGHT_LENGTH / spacing))
		for index = 1, guideCount do
			local z = math.min(Constants.STRAIGHT_LENGTH, index * spacing)
			local point = sector.entry.Position + sector.entry.LookVector * z
			table.insert(waypoints, buildLapWaypoint(ridePos(point), sector.entry.LookVector))
			table.insert(waypointSectorIds, sector.id)
			if z >= Constants.STRAIGHT_LENGTH then
				break
			end
		end

		if guideCount * spacing < Constants.STRAIGHT_LENGTH then
			table.insert(waypoints, buildLapWaypoint(ridePos(sector.exit.Position), sector.exit.LookVector))
			table.insert(waypointSectorIds, sector.id)
		end
	end

	if overrideState and overrideState.mechanic == "RampJump" then
		local params = overrideState.params
		assert(params.ramp_angle, "TrackGenerator.buildStraightWaypoints: rampjump ramp_angle missing")
		assert(params.ramp_length, "TrackGenerator.buildStraightWaypoints: rampjump ramp_length missing")
		assert(params.gap_length, "TrackGenerator.buildStraightWaypoints: rampjump gap_length missing")
		assert(params.landing_length, "TrackGenerator.buildStraightWaypoints: rampjump landing_length missing")

		local profile =
			RampJumpPath.buildProfile(params.ramp_angle, params.ramp_length, params.gap_length, params.landing_length)
		for index = 2, #profile.guidePoints do
			local currentLocal = profile.guidePoints[index]
			local previousLocal = profile.guidePoints[index - 1]
			local current = worldPoint(sector.entry, currentLocal)
			local previous = worldPoint(sector.entry, previousLocal)
			local forward = (current - previous).Magnitude > 0 and (current - previous).Unit or sector.exit.LookVector
			table.insert(waypoints, buildLapWaypoint(ridePosY(current, currentLocal.Y), forward))
			table.insert(waypointSectorIds, sector.id)
		end
	elseif overrideState and overrideState.mechanic == "Chicane" then
		local params = overrideState.params
		assert(params.amplitude, "TrackGenerator.buildStraightWaypoints: chicane amplitude missing")
		assert(params.transition_length, "TrackGenerator.buildStraightWaypoints: chicane transition_length missing")

		local points = ChicanePath.buildLocalCenterlinePoints(params.amplitude, params.transition_length)
		for index = 2, #points do
			local current = worldPoint(sector.entry, points[index])
			local previous = worldPoint(sector.entry, points[index - 1])
			local forward = (current - previous).Magnitude > 0 and (current - previous).Unit or sector.exit.LookVector
			table.insert(waypoints, buildLapWaypoint(ridePos(current), forward))
			table.insert(waypointSectorIds, sector.id)
		end

		if points[#points].Z < Constants.STRAIGHT_LENGTH then
			table.insert(waypoints, buildLapWaypoint(ridePos(sector.exit.Position), sector.exit.LookVector))
			table.insert(waypointSectorIds, sector.id)
		end
	elseif overrideState and overrideState.mechanic == "CrestDip" then
		local params = overrideState.params
		assert(params.height_or_depth, "TrackGenerator.buildStraightWaypoints: crestdip height_or_depth missing")
		assert(params.sector_length, "TrackGenerator.buildStraightWaypoints: crestdip sector_length missing")

		local points = CrestDipPath.buildLocalCenterlinePoints(params.height_or_depth, params.sector_length)
		for index = 2, #points do
			local currentLocal = points[index]
			local previousLocal = points[index - 1]
			local current = worldPoint(sector.entry, currentLocal)
			local previous = worldPoint(sector.entry, previousLocal)
			local forward = (current - previous).Magnitude > 0 and (current - previous).Unit or sector.exit.LookVector
			table.insert(waypoints, buildLapWaypoint(ridePosY(current, currentLocal.Y), forward))
			table.insert(waypointSectorIds, sector.id)
		end
	else
		appendStraightGuideWaypoints()
	end
end

local function appendSectorWaypoints(waypoints, waypointSectorIds, sectorKinds, sector, overrideState)
	local function ridePos(p)
		return Vector3.new(p.X, CAR_RIDE_Y, p.Z)
	end

	sectorKinds[sector.id] = sector.kind

	if sector.kind == "Corner" then
		local points = CornerPath.buildWorldCenterlinePoints(
			sector.entry,
			sector.exit,
			sector.entryShoulderLength,
			sector.exitShoulderLength
		)
		for index = 1, #points do
			local current = points[index]
			local previous = points[math.max(index - 1, 1)]
			local forward = (current - previous).Magnitude > 0 and (current - previous).Unit or sector.entry.LookVector
			table.insert(waypoints, buildLapWaypoint(ridePos(current), forward))
			table.insert(waypointSectorIds, sector.id)
		end
	else
		buildStraightWaypoints(waypoints, waypointSectorIds, sector, overrideState)
	end
end

function TrackGenerator.generate(rows, cols)
	rows = rows or Constants.TRACK_ROWS
	cols = cols or Constants.TRACK_COLS
	return buildSectors(rows, cols)
end

function TrackGenerator.canonicalStart()
	local sectors = buildSectors(Constants.TRACK_ROWS, Constants.TRACK_COLS)
	local entry = sectors[1].entry
	return CFrame.new(entry.Position + Vector3.new(0, CAR_RIDE_Y - TRACK_Y, 0)) * (entry - entry.Position)
end

function TrackGenerator.getLapPath(sectors, stateOverrides)
	local waypoints = {}
	local waypointSectorIds = {}
	local sectorKinds = {}
	local function ridePos(p)
		return Vector3.new(p.X, CAR_RIDE_Y, p.Z)
	end

	for _, rawSector in ipairs(sectors) do
		local sector = rawSector
		appendSectorWaypoints(
			waypoints,
			waypointSectorIds,
			sectorKinds,
			sector,
			stateOverrides and stateOverrides[sector.id] or nil
		)
	end

	table.insert(waypoints, buildLapWaypoint(ridePos(sectors[1].entry.Position), sectors[1].entry.LookVector))
	table.insert(waypointSectorIds, sectors[1].id)
	return waypoints, waypointSectorIds, sectorKinds
end

function TrackGenerator.getSectorPath(sector, overrideState)
	local waypoints = {}
	local waypointSectorIds = {}
	local sectorKinds = {}
	local function ridePos(p)
		return Vector3.new(p.X, CAR_RIDE_Y, p.Z)
	end

	sectorKinds[sector.id] = sector.kind
	table.insert(waypoints, buildLapWaypoint(ridePos(sector.entry.Position), sector.entry.LookVector))
	table.insert(waypointSectorIds, sector.id)
	if sector.kind == "Corner" then
		local points = CornerPath.buildWorldCenterlinePoints(
			sector.entry,
			sector.exit,
			sector.entryShoulderLength,
			sector.exitShoulderLength
		)
		for index = 2, #points do
			local current = points[index]
			local previous = points[index - 1]
			local forward = (current - previous).Magnitude > 0 and (current - previous).Unit or sector.entry.LookVector
			table.insert(waypoints, buildLapWaypoint(ridePos(current), forward))
			table.insert(waypointSectorIds, sector.id)
		end
	else
		buildStraightWaypoints(waypoints, waypointSectorIds, sector, overrideState)
	end
	return waypoints, waypointSectorIds, sectorKinds
end

function TrackGenerator.getLapWaypoints(sectors, stateOverrides)
	local waypoints = TrackGenerator.getLapPath(sectors, stateOverrides)
	return waypoints
end

function TrackGenerator.buildParts(sectors)
	local existingTrack = workspace:FindFirstChild("Track")
	if existingTrack then
		existingTrack:Destroy()
	end

	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "Track"
	trackFolder.Parent = workspace

	TrackVisuals.renderTrackFoundation(trackFolder, sectors)

	for _, rawSector in ipairs(sectors) do
		local sector = rawSector

		local sectorFolder = Instance.new("Folder")
		sectorFolder.Name = string.format("Sector_%02d", sector.id)
		sectorFolder.Parent = trackFolder
		if sector.kind == "Corner" then
			sectorFolder:SetAttribute("CornerEntryShoulderLength", sector.entryShoulderLength)
			sectorFolder:SetAttribute("CornerExitShoulderLength", sector.exitShoulderLength)
		end

		TrackVisuals.ensureSectorStructure(sectorFolder, sector.id, sector.kind, sector.cellCFrame, sector.cellSize)
		local collisionFolder = TrackVisuals.getCollisionFolder(sectorFolder)
		local visualFolder = TrackVisuals.getVisualFolder(sectorFolder)

		TrackVisuals.makeCollisionPart(
			collisionFolder,
			string.format("Sector_%02d_%s", sector.id, sector.kind),
			sector.size,
			CFrame.lookAt(sector.center, sector.center + sector.exit.LookVector),
			sector.id,
			sector.kind
		)

		if sector.kind == "Straight" then
			TrackVisuals.renderStraightFlatVisuals(
				visualFolder,
				sector.cellCFrame,
				sector.cellSize,
				sector.entry,
				sector.exit
			)
		else
			TrackVisuals.renderCornerFlatVisuals(
				visualFolder,
				sector.cellCFrame,
				sector.cellSize,
				sector.entry,
				sector.exit
			)
		end

		sector.partGroup = sectorFolder
	end

	return trackFolder
end

return TrackGenerator
