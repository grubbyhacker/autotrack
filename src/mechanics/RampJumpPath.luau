-- RampJumpPath.luau
-- Shared centerline/profile helper for RampJump geometry and verifier guidance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local RampJumpPath = {}

RampJumpPath.BLEND_SEGMENTS = 16
RampJumpPath.FLAT_SAMPLE_SPACING = 3
RampJumpPath.RAMP_SAMPLE_SPACING = 2

local function startOffsetFor(totalHorizontal: number): number
	return math.max(0, (Constants.STRAIGHT_LENGTH - totalHorizontal) * 0.5)
end

local function blendLengthFor(rampLength: number): number
	return math.min(math.max(12, rampLength * 0.9), math.max(12, rampLength - 2))
end

local function blendHeightFactor(t: number): number
	-- Cubic blend: starts flat (slope 0), reaches full ramp slope at the end,
	-- and preserves the authored ramp height across the blended section.
	return t * t * (2 - t)
end

local function appendFlatSamples(points: { Vector3 }, startZ: number, endZ: number)
	local distance = endZ - startZ
	if distance <= 0 then
		return
	end
	local steps = math.max(1, math.ceil(distance / RampJumpPath.FLAT_SAMPLE_SPACING))
	for index = 1, steps do
		local z = startZ + distance * (index / steps)
		table.insert(points, Vector3.new(0, 0, z))
	end
end

local function appendRampSamples(points: { Vector3 }, startZ: number, endZ: number, slope: number, startHeight: number)
	local distance = endZ - startZ
	if distance <= 0 then
		return
	end
	local steps = math.max(1, math.ceil(distance / RampJumpPath.RAMP_SAMPLE_SPACING))
	for index = 1, steps do
		local z = startZ + distance * (index / steps)
		table.insert(points, Vector3.new(0, startHeight + slope * (z - startZ), z))
	end
end

function RampJumpPath.buildProfile(rampAngle: number, rampLength: number, gapLength: number, landingLength: number)
	local slope = math.tan(math.rad(rampAngle))
	local totalHorizontal = rampLength + gapLength + landingLength
	local startOffset = startOffsetFor(totalHorizontal)
	local blendLength = math.min(blendLengthFor(rampLength), rampLength)
	local blendEndZ = startOffset + blendLength
	local lipZ = startOffset + rampLength
	local blendEndHeight = slope * blendLength * blendHeightFactor(1)
	local rampHeight = blendEndHeight + slope * math.max(0, lipZ - blendEndZ)
	local landingStartZ = lipZ + gapLength
	local landingEndZ = landingStartZ + landingLength

	local rampPoints = { Vector3.new(0, 0, 0) }
	if startOffset > 0 then
		appendFlatSamples(rampPoints, 0, startOffset)
	end

	for index = 1, RampJumpPath.BLEND_SEGMENTS do
		local t = index / RampJumpPath.BLEND_SEGMENTS
		local z = startOffset + blendLength * t
		local y = slope * blendLength * blendHeightFactor(t)
		table.insert(rampPoints, Vector3.new(0, y, z))
	end

	appendRampSamples(rampPoints, blendEndZ, lipZ, slope, blendEndHeight)
	if math.abs(rampPoints[#rampPoints].Z - lipZ) > 1e-4 then
		table.insert(rampPoints, Vector3.new(0, rampHeight, lipZ))
	end

	local landingPoints = { Vector3.new(0, 0, landingStartZ) }
	appendFlatSamples(landingPoints, landingStartZ, landingEndZ)
	if landingEndZ < Constants.STRAIGHT_LENGTH then
		appendFlatSamples(landingPoints, landingEndZ, Constants.STRAIGHT_LENGTH)
	end

	local guidePoints = {}
	for _, point in ipairs(rampPoints) do
		table.insert(guidePoints, point)
	end
	for _, point in ipairs(landingPoints) do
		table.insert(guidePoints, point)
	end

	return {
		startOffset = startOffset,
		blendLength = blendLength,
		blendEndZ = blendEndZ,
		lipZ = lipZ,
		rampHeight = rampHeight,
		landingStartZ = landingStartZ,
		landingEndZ = landingEndZ,
		rampPoints = rampPoints,
		landingPoints = landingPoints,
		guidePoints = guidePoints,
	}
end

return RampJumpPath
