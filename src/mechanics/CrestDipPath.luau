-- CrestDipPath.luau
-- Shared centerline helper for CrestDip geometry and verifier guidance.
-- Mirrors the sampling used by CrestDipBuilder so the drive line matches the rendered surface.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local CrestDipPath = {}

CrestDipPath.CURVE_SEGMENTS = 6

-- Returns local-space Vector3 waypoints:
--   x = 0 (no lateral motion)
--   y = cosine vertical profile  y = h/2 * (1 - cos(2π t))
--   z = longitudinal distance along the sector
-- A final waypoint at (0, 0, STRAIGHT_LENGTH) covers the flat ExitFlat runout
-- when sector_length < STRAIGHT_LENGTH so the lap path reaches the sector exit.
function CrestDipPath.buildLocalCenterlinePoints(heightOrDepth: number, sectorLength: number): { Vector3 }
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - sectorLength) * 0.5)
	local points: { Vector3 } = {}
	if startOffset > 0 then
		table.insert(points, Vector3.new(0, 0, 0))
	end
	for index = 0, CrestDipPath.CURVE_SEGMENTS do
		local t = index / CrestDipPath.CURVE_SEGMENTS
		local y = heightOrDepth * 0.5 * (1 - math.cos(2 * math.pi * t))
		local z = startOffset + sectorLength * t
		table.insert(points, Vector3.new(0, y, z))
	end
	if points[#points].Z < Constants.STRAIGHT_LENGTH then
		table.insert(points, Vector3.new(0, 0, Constants.STRAIGHT_LENGTH))
	end

	return points
end

return CrestDipPath
