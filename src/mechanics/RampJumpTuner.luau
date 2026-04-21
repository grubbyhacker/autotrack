-- RampJumpTuner.luau
-- Shared conservative tuner for RampJump playability.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))

local RampJumpTuner = {}

local function clampRound(value: number, bound): number
	return math.clamp(math.round(value), bound.min, bound.max)
end

function RampJumpTuner.tune(params, options)
	options = options or {}
	local bounds = LevelMappings.LEVER_BOUNDS.RampJump
	local defaults = LevelMappings.DEFAULTS.RampJump

	local tuned = {
		ramp_angle = clampRound(params.ramp_angle or defaults.ramp_angle, bounds.ramp_angle),
		ramp_length = clampRound(params.ramp_length or defaults.ramp_length, bounds.ramp_length),
		gap_length = clampRound(params.gap_length or defaults.gap_length, bounds.gap_length),
		landing_length = clampRound(params.landing_length or defaults.landing_length, bounds.landing_length),
	}

	tuned.ramp_angle = math.min(tuned.ramp_angle, 10)
	tuned.gap_length = math.min(tuned.gap_length, 6)

	if options.preferGentle then
		tuned.ramp_angle = math.min(tuned.ramp_angle, 5)
		tuned.gap_length = math.min(tuned.gap_length, 3)
	end

	if options.postCorner then
		tuned.ramp_angle = math.min(tuned.ramp_angle, 4)
		tuned.gap_length = math.min(tuned.gap_length, 2)
	end

	local minimumRampLength = if options.postCorner or options.preferGentle then 22 else 20
	local minimumLandingLength = 32
	if options.preferGentle then
		minimumLandingLength = 34
	end
	if options.postCorner then
		minimumLandingLength = 36
	end

	tuned.ramp_length = math.max(tuned.ramp_length, minimumRampLength)
	tuned.landing_length = math.max(tuned.landing_length, minimumLandingLength)

	if tuned.ramp_length < 24 then
		tuned.ramp_angle = math.min(tuned.ramp_angle, 6)
	elseif tuned.ramp_length < 28 then
		tuned.ramp_angle = math.min(tuned.ramp_angle, 10)
	else
		tuned.ramp_angle = math.min(tuned.ramp_angle, 12)
	end

	tuned.landing_length = math.max(
		tuned.landing_length,
		math.min(bounds.landing_length.max, tuned.gap_length * 3 + 24)
	)

	return tuned
end

return RampJumpTuner
