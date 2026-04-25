--!strict
-- RampJumpPath.luau
-- Shared centerline/profile helper for RampJump geometry and verifier guidance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local RuntimeTuning = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("RuntimeTuning"))

local RampJumpPath = {}

RampJumpPath.BLEND_SEGMENTS = 16
RampJumpPath.FLAT_SAMPLE_SPACING = 3
RampJumpPath.RAMP_SAMPLE_SPACING = 2

local VALID_PROFILE_MODES = {
	linear_blend = true,
	curved_lift = true,
}

local function resolveProfileMode(requestedMode: string?): string
	if type(requestedMode) == "string" and VALID_PROFILE_MODES[requestedMode] then
		return requestedMode
	end

	local rawAttr = workspace:GetAttribute("AutoTrack_RampJumpProfileMode")
	if type(rawAttr) == "string" and VALID_PROFILE_MODES[rawAttr] then
		return rawAttr
	end
	if type(rawAttr) == "number" then
		return if rawAttr >= 0.5 then "curved_lift" else "linear_blend"
	end

	local fallback = RuntimeTuning.stringAttr("AutoTrack_RampJumpProfileMode", Constants.RAMPJUMP_PROFILE_MODE)
	if VALID_PROFILE_MODES[fallback] then
		return fallback
	end
	return "linear_blend"
end

local function runoutAllocation(totalHorizontal: number): (number, number)
	local remaining = math.max(0, Constants.STRAIGHT_LENGTH - totalHorizontal)
	local entryMin = math.max(0, Constants.RAMPJUMP_ENTRY_RUNOUT_MIN)
	local exitMin = math.max(0, Constants.RAMPJUMP_EXIT_RUNOUT_MIN)

	if remaining <= 0 then
		return 0, 0
	end

	if remaining >= entryMin + exitMin then
		local extra = remaining - entryMin - exitMin
		local entryRunout = entryMin + extra * 0.35
		local exitRunout = remaining - entryRunout
		return entryRunout, exitRunout
	end

	local entryRunout = remaining * 0.4
	return entryRunout, remaining - entryRunout
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

local function curvedLiftHeight(t: number, rampHeight: number, rampLength: number, slope: number): number
	local lipSlopeFactor = math.max(1, Constants.RAMPJUMP_CURVED_LIFT_LIP_SLOPE_FACTOR)
	local lipSlope = slope * lipSlopeFactor
	local a = (lipSlope * rampLength) - (2 * rampHeight)
	local b = (3 * rampHeight) - (lipSlope * rampLength)
	return (a * t * t * t) + (b * t * t)
end

function RampJumpPath.buildProfile(
	rampAngle: number,
	rampLength: number,
	gapLength: number,
	landingLength: number,
	profileMode: string?
)
	local mode = resolveProfileMode(profileMode)
	local slope = math.tan(math.rad(rampAngle))
	local totalHorizontal = rampLength + gapLength + landingLength
	local entryRunout, exitRunout = runoutAllocation(totalHorizontal)
	local startOffset = entryRunout
	local blendLength = math.min(blendLengthFor(rampLength), rampLength)
	local blendEndZ = startOffset + blendLength
	local lipZ = startOffset + rampLength
	local blendEndHeight = slope * blendLength * blendHeightFactor(1)
	local rampHeight = slope * rampLength
	local landingStartZ = lipZ + gapLength
	local landingEndZ = landingStartZ + landingLength

	local rampPoints = { Vector3.new(0, 0, 0) }
	if startOffset > 0 then
		appendFlatSamples(rampPoints, 0, startOffset)
	end

	if mode == "curved_lift" then
		local steps = math.max(8, math.ceil(rampLength / RampJumpPath.RAMP_SAMPLE_SPACING))
		for index = 1, steps do
			local t = index / steps
			local z = startOffset + rampLength * t
			local y = curvedLiftHeight(t, rampHeight, rampLength, slope)
			table.insert(rampPoints, Vector3.new(0, y, z))
		end
	else
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
		profile_mode = mode,
		startOffset = startOffset,
		entryRunout = entryRunout,
		exitRunout = exitRunout,
		blendLength = blendLength,
		blendEndZ = if mode == "curved_lift" then startOffset else blendEndZ,
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
