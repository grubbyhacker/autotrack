local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))

local CrestDipTuner = {}

local HEIGHT_BOUNDS = LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth
local LENGTH_BOUNDS = LevelMappings.LEVER_BOUNDS.CrestDip.sector_length
local MIN_RUNOUT = 20
local MAX_PEAK_SLOPE = 0.56
local TARGET_PEAK_SLOPE = 0.52

local function clampInt(value: number, minValue: number, maxValue: number): number
	return math.clamp(math.round(value), minValue, maxValue)
end

local function crestRunout(sectorLength: number): number
	return math.max(0, (Constants.STRAIGHT_LENGTH - sectorLength) * 0.5)
end

local function peakSlope(height: number, sectorLength: number): number
	return math.pi * math.abs(height) / math.max(sectorLength, 1)
end

local function curvature(height: number, sectorLength: number): number
	return math.abs(height) / math.max(sectorLength * sectorLength, 1)
end

local function fitsEnvelope(height: number, sectorLength: number): boolean
	if crestRunout(sectorLength) < MIN_RUNOUT then
		return false
	end
	if peakSlope(height, sectorLength) > MAX_PEAK_SLOPE then
		return false
	end
	if curvature(height, sectorLength) < Constants.CRESTDIP_MIN_CURVATURE then
		return false
	end
	return true
end

local function candidateScore(
	height: number,
	sectorLength: number,
	desiredHeight: number,
	desiredLength: number
): number
	local heightRange = math.max(1, HEIGHT_BOUNDS.max - HEIGHT_BOUNDS.min)
	local lengthRange = math.max(1, LENGTH_BOUNDS.max - LENGTH_BOUNDS.min)
	local heightDistance = math.abs(height - desiredHeight) / heightRange
	local lengthDistance = math.abs(sectorLength - desiredLength) / lengthRange
	local slopeBonus = math.min(peakSlope(height, sectorLength) / TARGET_PEAK_SLOPE, 1.1)
	local curvatureBonus = math.min(curvature(height, sectorLength) / Constants.CRESTDIP_MIN_CURVATURE, 1.25)

	-- Prefer the closest valid state, then bias slightly toward a stronger-but-still-drivable crest.
	return -(heightDistance * 0.7 + lengthDistance * 0.9) + slopeBonus * 0.08 + curvatureBonus * 0.04
end

local function normalizedBound(bounds, fallbackMin: number, fallbackMax: number)
	local minValue = fallbackMin
	local maxValue = fallbackMax
	if type(bounds) == "table" then
		if type(bounds.min) == "number" then
			minValue = math.max(fallbackMin, bounds.min)
		end
		if type(bounds.max) == "number" then
			maxValue = math.min(fallbackMax, bounds.max)
		end
	end
	if minValue > maxValue then
		return fallbackMin, fallbackMax
	end
	return minValue, maxValue
end

local function tuneWithinBounds(
	desiredHeight: number,
	desiredLength: number,
	heightMin: number,
	heightMax: number,
	lengthMin: number,
	lengthMax: number
): (number?, number?)
	local bestHeight = nil
	local bestLength = nil
	local bestScore = -math.huge

	for candidateLength = lengthMin, lengthMax do
		for candidateHeight = heightMin, heightMax do
			if fitsEnvelope(candidateHeight, candidateLength) then
				local score = candidateScore(candidateHeight, candidateLength, desiredHeight, desiredLength)
				if score > bestScore then
					bestScore = score
					bestHeight = candidateHeight
					bestLength = candidateLength
				end
			end
		end
	end

	return bestHeight, bestLength
end

function CrestDipTuner.tune(height: number, sectorLength: number, bounds): (number, number)
	local desiredHeight = clampInt(height, HEIGHT_BOUNDS.min, HEIGHT_BOUNDS.max)
	local desiredLength = clampInt(sectorLength, LENGTH_BOUNDS.min, LENGTH_BOUNDS.max)
	local hasMinHeight = type(bounds) == "table" and type(bounds.minHeight) == "number"
	local hasMaxHeight = type(bounds) == "table" and type(bounds.maxHeight) == "number"
	local hasMinLength = type(bounds) == "table" and type(bounds.minLength) == "number"
	local hasMaxLength = type(bounds) == "table" and type(bounds.maxLength) == "number"
	local heightMin, heightMax = normalizedBound(bounds and {
		min = bounds.minHeight,
		max = bounds.maxHeight,
	}, HEIGHT_BOUNDS.min, HEIGHT_BOUNDS.max)
	local lengthMin, lengthMax = normalizedBound(bounds and {
		min = bounds.minLength,
		max = bounds.maxLength,
	}, LENGTH_BOUNDS.min, LENGTH_BOUNDS.max)
	local searches = {
		{ heightMin = heightMin, heightMax = heightMax, lengthMin = lengthMin, lengthMax = lengthMax },
	}
	if (hasMinHeight or hasMaxHeight) and (hasMinLength or hasMaxLength) then
		table.insert(searches, {
			heightMin = heightMin,
			heightMax = heightMax,
			lengthMin = LENGTH_BOUNDS.min,
			lengthMax = LENGTH_BOUNDS.max,
		})
		table.insert(searches, {
			heightMin = HEIGHT_BOUNDS.min,
			heightMax = HEIGHT_BOUNDS.max,
			lengthMin = lengthMin,
			lengthMax = lengthMax,
		})
	end
	table.insert(searches, {
		heightMin = HEIGHT_BOUNDS.min,
		heightMax = HEIGHT_BOUNDS.max,
		lengthMin = LENGTH_BOUNDS.min,
		lengthMax = LENGTH_BOUNDS.max,
	})

	local bestHeight, bestLength = nil, nil
	for _, search in ipairs(searches) do
		bestHeight, bestLength = tuneWithinBounds(
			desiredHeight,
			desiredLength,
			search.heightMin,
			search.heightMax,
			search.lengthMin,
			search.lengthMax
		)
		if bestHeight ~= nil and bestLength ~= nil then
			break
		end
	end

	return bestHeight or desiredHeight, bestLength or desiredLength
end

function CrestDipTuner.peakSlope(height: number, sectorLength: number): number
	return peakSlope(height, sectorLength)
end

function CrestDipTuner.runout(sectorLength: number): number
	return crestRunout(sectorLength)
end

return CrestDipTuner
