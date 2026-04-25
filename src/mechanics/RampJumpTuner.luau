--!strict

-- RampJumpTuner.luau
-- Shared RampJump normalizer with mode-aware envelopes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type SectorParams = Types.SectorParams

type LeverBound = {
	min: number,
	max: number,
}

type TuneOptions = {
	postCorner: boolean?,
	preferGentle: boolean?,
	mode: string?,
}

type RampJumpTunerModule = {
	tune: (params: SectorParams, options: TuneOptions?) -> SectorParams,
}

local RampJumpTuner: RampJumpTunerModule = {} :: RampJumpTunerModule

local function clampRound(value: number, bound: LeverBound): number
	return math.clamp(math.round(value), bound.min, bound.max)
end

function RampJumpTuner.tune(params: SectorParams, options: TuneOptions?): SectorParams
	local tuneOptions: TuneOptions = options or {}
	local bounds = LevelMappings.LEVER_BOUNDS.RampJump
	local defaults = LevelMappings.DEFAULTS.RampJump
	local defaultRampAngle = assert(defaults.ramp_angle, "RampJumpTuner: default ramp_angle missing")
	local defaultRampLength = assert(defaults.ramp_length, "RampJumpTuner: default ramp_length missing")
	local defaultGapLength = assert(defaults.gap_length, "RampJumpTuner: default gap_length missing")
	local defaultLandingLength = assert(defaults.landing_length, "RampJumpTuner: default landing_length missing")
	local postCorner = tuneOptions.postCorner == true
	local mode = tostring(tuneOptions.mode or "")
	if mode == "" then
		mode = if tuneOptions.preferGentle == true then "repair" else "opening"
	end
	if mode ~= "opening" and mode ~= "challenge_up" and mode ~= "repair" then
		mode = "opening"
	end

	local tuned = {
		ramp_angle = clampRound(params.ramp_angle or defaultRampAngle, bounds.ramp_angle),
		ramp_length = clampRound(params.ramp_length or defaultRampLength, bounds.ramp_length),
		gap_length = clampRound(params.gap_length or defaultGapLength, bounds.gap_length),
		landing_length = clampRound(params.landing_length or defaultLandingLength, bounds.landing_length),
	}

	local minRampAngle: number
	local minGapLength: number
	local minRampLength: number
	local minLandingLength: number
	local maxLandingLength: number
	local gapLandingFactor: number
	local gapLandingBase: number

	if mode == "challenge_up" then
		minRampAngle = if postCorner then 9 else 12
		minGapLength = if postCorner then 4 else 8
		minRampLength = if postCorner then 28 else 34
		minLandingLength = 18
		maxLandingLength = if postCorner then 56 else 60
		gapLandingFactor = 1.3
		gapLandingBase = 8
	elseif mode == "repair" then
		minRampAngle = if postCorner then 6 else 7
		minGapLength = if postCorner then 2 else 4
		minRampLength = 22
		minLandingLength = 18
		maxLandingLength = if postCorner then 60 else 64
		gapLandingFactor = 1.5
		gapLandingBase = 10
	else
		minRampAngle = if postCorner then 7 else 9
		minGapLength = if postCorner then 3 else 6
		minRampLength = if postCorner then 24 else 30
		minLandingLength = if postCorner then 20 else 18
		maxLandingLength = if postCorner then 58 else 62
		gapLandingFactor = 1.6
		gapLandingBase = 12
	end

	tuned.ramp_angle = math.max(tuned.ramp_angle, minRampAngle)
	tuned.gap_length = math.max(tuned.gap_length, minGapLength)
	tuned.ramp_length = math.max(tuned.ramp_length, minRampLength)
	tuned.landing_length = math.max(tuned.landing_length, minLandingLength)
	tuned.landing_length = math.min(tuned.landing_length, math.min(bounds.landing_length.max, maxLandingLength))

	local landingFloorFromGap =
		math.min(bounds.landing_length.max, math.floor(tuned.gap_length * gapLandingFactor + gapLandingBase))
	tuned.landing_length = math.max(tuned.landing_length, landingFloorFromGap)

	if tuned.ramp_angle >= 16 then
		tuned.ramp_length = math.max(tuned.ramp_length, 26)
	elseif tuned.ramp_angle >= 14 then
		tuned.ramp_length = math.max(tuned.ramp_length, 24)
	end

	if tuned.ramp_length < 24 then
		tuned.ramp_angle = math.min(tuned.ramp_angle, if mode == "challenge_up" then 16 else 14)
	end

	local total = tuned.ramp_length + tuned.gap_length + tuned.landing_length
	if total > Constants.STRAIGHT_LENGTH then
		local overflow = total - Constants.STRAIGHT_LENGTH
		local landingSlack = math.max(0, tuned.landing_length - minLandingLength)
		local landingTrim = math.min(overflow, landingSlack)
		tuned.landing_length = tuned.landing_length - landingTrim
		total = total - landingTrim
	end
	if total > Constants.STRAIGHT_LENGTH then
		local overflow = total - Constants.STRAIGHT_LENGTH
		local gapSlack = math.max(0, tuned.gap_length - minGapLength)
		local gapTrim = math.min(overflow, gapSlack)
		tuned.gap_length = tuned.gap_length - gapTrim
		total = total - gapTrim
	end
	if total > Constants.STRAIGHT_LENGTH then
		local overflow = total - Constants.STRAIGHT_LENGTH
		local rampSlack = math.max(0, tuned.ramp_length - minRampLength)
		local rampTrim = math.min(overflow, rampSlack)
		tuned.ramp_length = tuned.ramp_length - rampTrim
	end

	return tuned
end

return RampJumpTuner
