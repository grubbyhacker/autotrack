local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local RampJumpPath = require(script.Parent.Parent.Mechanics.RampJumpPath)

type SectorState = Types.SectorState

local TestPhase15 = {}

local TARGET_SECTOR_ID = 4

local function makeState(params: Types.SectorParams): SectorState
	return {
		sector_id = TARGET_SECTOR_ID,
		mechanic = "RampJump",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function getSectorMeta(sectorId: number)
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector, sectors
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function getCollisionParts(sectorId: number): { BasePart }
	local track = workspace:FindFirstChild("Track")
	assert(track, "Track folder missing")
	local sectorFolder = track:FindFirstChild(string.format("Sector_%02d", sectorId))
	assert(sectorFolder and sectorFolder:IsA("Folder"), "sector folder missing")
	local collisionFolder = sectorFolder:FindFirstChild("Collision")
	assert(collisionFolder and collisionFolder:IsA("Folder"), "collision folder missing")
	local parts = {}
	for _, child in ipairs(collisionFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

local function flatState(): SectorState
	return {
		sector_id = TARGET_SECTOR_ID,
		mechanic = nil,
		params = {},
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function segmentLocalEndpoints(entryFrame: CFrame, part: BasePart): (Vector3, Vector3)
	local function toTrackLocal(worldPoint: Vector3): Vector3
		local localPoint = entryFrame:PointToObjectSpace(worldPoint)
		return Vector3.new(localPoint.X, localPoint.Y, -localPoint.Z)
	end

	local a = toTrackLocal(part.CFrame:PointToWorldSpace(Vector3.new(0, 0, -part.Size.Z * 0.5)))
	local b = toTrackLocal(part.CFrame:PointToWorldSpace(Vector3.new(0, 0, part.Size.Z * 0.5)))
	if a.Z <= b.Z then
		return a, b
	end
	return b, a
end

local function segmentAngleDegrees(part: BasePart): number
	return math.deg(math.asin(math.clamp(math.abs(part.CFrame.LookVector.Y), 0, 1)))
end

function TestPhase15.run()
	local sector = getSectorMeta(TARGET_SECTOR_ID)
	local state = makeState({
		ramp_angle = 60,
		ramp_length = 36,
		gap_length = 8,
		landing_length = 18,
	})
	local profile = RampJumpPath.buildProfile(
		state.params.ramp_angle,
		state.params.ramp_length,
		state.params.gap_length,
		state.params.landing_length
	)

	SectorApplier.apply(state, sector.entry, sector.exit)

	local ok, err = xpcall(function()
		local rawParts = getCollisionParts(TARGET_SECTOR_ID)
		local segments = {}
		for _, part in ipairs(rawParts) do
			local startLocal, endLocal = segmentLocalEndpoints(sector.entry, part)
			table.insert(segments, {
				part = part,
				startLocal = startLocal,
				endLocal = endLocal,
				angle = segmentAngleDegrees(part),
			})
		end
		table.sort(segments, function(a, b)
			return a.startLocal.Z < b.startLocal.Z
		end)

		local slopedAngles = {}
		local continuityOk = true
		local continuityErrors = {}
		local largestGap = 0
		local firstFlatStartOk = #segments > 0
			and math.abs(segments[1].startLocal.Z) <= 0.25
			and math.abs(segments[1].startLocal.Y) <= 0.25
			and math.abs(segments[1].endLocal.Y) <= 0.25

		for index, segment in ipairs(segments) do
			if segment.angle > 1 and segment.startLocal.Z < profile.lipZ + 0.5 then
				table.insert(slopedAngles, segment.angle)
			end
			if index > 1 then
				local gap = segment.startLocal.Z - segments[index - 1].endLocal.Z
				if gap > largestGap then
					largestGap = gap
				end
				local isIntentionalGap = segments[index - 1].endLocal.Z <= profile.lipZ + 0.75
					and segment.startLocal.Z >= profile.landingStartZ - 0.75
				if not isIntentionalGap and math.abs(gap) > 0.6 then
					continuityOk = false
					table.insert(continuityErrors, string.format("%.2f between %s and %s", gap, segments[index - 1].part.Name, segment.part.Name))
				end
			end
		end

		local firstSlopedAngle = slopedAngles[1] or 0
		local maxSlopedAngle = 0
		for _, angle in ipairs(slopedAngles) do
			maxSlopedAngle = math.max(maxSlopedAngle, angle)
		end
		local lastSegment = segments[#segments]

		T.expect(
			"phase15_rampjump_builds_segmented_climb",
			#slopedAngles >= 3,
			string.format("expected multiple sloped segments, got %d", #slopedAngles)
		)
		T.expect(
			"phase15_rampjump_starts_flat",
			firstFlatStartOk,
			#segments > 0 and string.format(
				"first segment start=(%.2f, %.2f) endY=%.2f",
				segments[1].startLocal.Z,
				segments[1].startLocal.Y,
				segments[1].endLocal.Y
			) or "no segments built"
		)
		T.expect(
			"phase15_rampjump_blends_into_full_angle",
			firstSlopedAngle > 1
				and maxSlopedAngle > firstSlopedAngle + 20
				and firstSlopedAngle < maxSlopedAngle * 0.35
				and maxSlopedAngle >= state.params.ramp_angle - 4
				and maxSlopedAngle <= state.params.ramp_angle + 10,
			string.format(
				"firstSloped=%.2f maxSloped=%.2f target=%d",
				firstSlopedAngle,
				maxSlopedAngle,
				state.params.ramp_angle
			)
		)
		T.expect(
			"phase15_rampjump_preserves_only_designed_gap",
			largestGap >= state.params.gap_length - 1.0 and continuityOk,
			string.format("largestGap=%.2f continuity=%s %s", largestGap, tostring(continuityOk), table.concat(continuityErrors, "; "))
		)
		T.expect(
			"phase15_rampjump_runout_reaches_sector_exit",
			lastSegment ~= nil
				and math.abs(lastSegment.endLocal.Z - Constants.STRAIGHT_LENGTH) <= 0.5
				and math.abs(lastSegment.endLocal.Y) <= 0.25,
			lastSegment and string.format("lastEnd=(%.2f, %.2f)", lastSegment.endLocal.Z, lastSegment.endLocal.Y) or "no segments built"
		)

		local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
		local waypoints, waypointSectorIds = TrackGenerator.getLapPath(sectors, { [TARGET_SECTOR_ID] = state })
		local sectorWaypoints = {}
		for index, waypoint in ipairs(waypoints) do
			if waypointSectorIds[index] == TARGET_SECTOR_ID then
				table.insert(sectorWaypoints, waypoint)
			end
		end

		local maxWaypointY = -math.huge
		local liftedWaypointCount = 0
		for _, waypoint in ipairs(sectorWaypoints) do
			maxWaypointY = math.max(maxWaypointY, waypoint.Position.Y)
			if waypoint.Position.Y > Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5 + 0.5 then
				liftedWaypointCount += 1
			end
		end
		local firstWaypoint = sectorWaypoints[1]
		local lastWaypoint = sectorWaypoints[#sectorWaypoints]
		local lastLocal = nil
		if lastWaypoint ~= nil then
			local rawLastLocal = sector.entry:PointToObjectSpace(lastWaypoint.Position)
			lastLocal = Vector3.new(rawLastLocal.X, rawLastLocal.Y, -rawLastLocal.Z)
		end

		T.expect(
			"phase15_rampjump_waypoints_follow_vertical_profile",
			#sectorWaypoints >= 6
				and firstWaypoint ~= nil
				and lastWaypoint ~= nil
				and math.abs(firstWaypoint.Position.Y - (Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5)) <= 0.25
				and maxWaypointY > Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5 + 2
				and liftedWaypointCount >= 3
				and math.abs(lastWaypoint.Position.Y - (Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5)) <= 0.25
				and lastLocal ~= nil
				and math.abs(lastLocal.Z - Constants.STRAIGHT_LENGTH) <= 0.5,
			string.format(
				"count=%d maxY=%.2f lifted=%d lastLocalZ=%s",
				#sectorWaypoints,
				maxWaypointY,
				liftedWaypointCount,
				tostring(lastLocal and string.format("%.2f", lastLocal.Z) or "nil")
			)
		)
	end, debug.traceback)

	SectorApplier.apply(flatState(), sector.entry, sector.exit)
	if not ok then
		error(err)
	end
end

return TestPhase15
