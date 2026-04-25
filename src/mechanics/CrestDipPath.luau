--!strict

-- CrestDipPath.luau
-- Shared centerline helper for CrestDip geometry and verifier guidance.
-- Mirrors the sampling used by CrestDipBuilder so the drive line matches the rendered surface.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local CrestDipPath = {}

CrestDipPath.CURVE_SEGMENTS = 18
CrestDipPath.FLAT_SAMPLE_SPACING = 6

local function startOffsetFor(sectorLength: number): number
	return math.max(0, (Constants.STRAIGHT_LENGTH - sectorLength) * 0.5)
end

local function sampleHeight(heightOrDepth: number, t: number): number
	return heightOrDepth * 0.5 * (1 - math.cos(2 * math.pi * t))
end

local function appendFlatSamples(points: { Vector3 }, startZ: number, endZ: number)
	local distance = endZ - startZ
	if distance <= 0 then
		return
	end
	local steps = math.max(1, math.ceil(distance / CrestDipPath.FLAT_SAMPLE_SPACING))
	for index = 1, steps do
		local z = startZ + distance * (index / steps)
		table.insert(points, Vector3.new(0, 0, z))
	end
end

-- Returns local-space Vector3 waypoints:
--   x = 0 (no lateral motion)
--   y = cosine vertical profile  y = h/2 * (1 - cos(2π t))
--   z = longitudinal distance along the sector
-- A final waypoint at (0, 0, STRAIGHT_LENGTH) covers the flat ExitFlat runout
-- when sector_length < STRAIGHT_LENGTH so the lap path reaches the sector exit.
function CrestDipPath.buildLocalCenterlinePoints(heightOrDepth: number, sectorLength: number): { Vector3 }
	local startOffset = startOffsetFor(sectorLength)
	local endZ = startOffset + sectorLength
	local points: { Vector3 } = { Vector3.new(0, 0, 0) }

	if startOffset > 0 then
		appendFlatSamples(points, 0, startOffset)
	end

	for index = 1, CrestDipPath.CURVE_SEGMENTS - 1 do
		local t = index / CrestDipPath.CURVE_SEGMENTS
		local y = sampleHeight(heightOrDepth, t)
		local z = startOffset + sectorLength * t
		table.insert(points, Vector3.new(0, y, z))
	end

	table.insert(points, Vector3.new(0, 0, endZ))
	if endZ < Constants.STRAIGHT_LENGTH then
		appendFlatSamples(points, endZ, Constants.STRAIGHT_LENGTH)
	end

	return points
end

return CrestDipPath
