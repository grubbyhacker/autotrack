-- ChicanePath.luau
-- Shared centerline helper for chicane geometry and verifier guidance.
-- The chicane is a single smooth wave: centerline -> +peak -> -peak -> centerline.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local ChicanePath = {}

ChicanePath.WAVE_SEGMENTS = 12
ChicanePath.VISUAL_SAMPLE_SPACING = 2
ChicanePath.ENTRY_STRAIGHT = 20
ChicanePath.EXIT_STRAIGHT = 20

function ChicanePath.waveLength(transitionLength: number): number
	return math.max(0, transitionLength) * 2
end

function ChicanePath.totalLength(transitionLength: number): number
	return ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + ChicanePath.waveLength(transitionLength)
end

function ChicanePath.maxTransitionLength(): number
	return math.floor((Constants.STRAIGHT_LENGTH - ChicanePath.ENTRY_STRAIGHT - ChicanePath.EXIT_STRAIGHT) * 0.5)
end

local function appendLinearSamples(points: { Vector3 }, startPoint: Vector3, endPoint: Vector3, sampleSpacing: number?)
	local distance = (endPoint - startPoint).Magnitude
	if distance <= 0 then
		return
	end

	local spacing = math.max(0.5, sampleSpacing or ChicanePath.VISUAL_SAMPLE_SPACING)
	local steps = math.max(1, math.ceil(distance / spacing))
	for index = 1, steps do
		table.insert(points, startPoint:Lerp(endPoint, index / steps))
	end
end

local function waveX(amplitude: number, waveLength: number, waveDistance: number): number
	if waveLength <= 0 then
		return 0
	end
	return amplitude * math.sin((waveDistance / waveLength) * math.pi * 2)
end

function ChicanePath.buildLocalCenterlinePoints(amplitude: number, transitionLength: number, waveSegmentsOverride: number?): { Vector3 }
	local totalLength = ChicanePath.totalLength(transitionLength)
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - totalLength) * 0.5)
	local waveSegments = math.max(waveSegmentsOverride or ChicanePath.WAVE_SEGMENTS, 2)
	local waveStartZ = startOffset + ChicanePath.ENTRY_STRAIGHT
	local waveLength = ChicanePath.waveLength(transitionLength)
	local waveEndZ = waveStartZ + waveLength
	local featureEndZ = waveEndZ + ChicanePath.EXIT_STRAIGHT
	local points = { Vector3.new(0, 0, 0) }
	if startOffset > 0 then
		table.insert(points, Vector3.new(0, 0, startOffset))
	end
	table.insert(points, Vector3.new(0, 0, waveStartZ))

	for index = 1, waveSegments do
		local t = index / waveSegments
		local wavePhase = t * math.pi * 2
		table.insert(points, Vector3.new(
			amplitude * math.sin(wavePhase),
			0,
			waveStartZ + waveLength * t
		))
	end

	table.insert(points, Vector3.new(0, 0, featureEndZ))
	if points[#points].Z < Constants.STRAIGHT_LENGTH then
		table.insert(points, Vector3.new(0, 0, Constants.STRAIGHT_LENGTH))
	end

	return points
end

function ChicanePath.buildLocalVisualCenterlinePoints(amplitude: number, transitionLength: number, sampleSpacingOverride: number?): { Vector3 }
	local totalLength = ChicanePath.totalLength(transitionLength)
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - totalLength) * 0.5)
	local spacing = math.max(0.5, sampleSpacingOverride or ChicanePath.VISUAL_SAMPLE_SPACING)
	local waveStartZ = startOffset + ChicanePath.ENTRY_STRAIGHT
	local waveLength = ChicanePath.waveLength(transitionLength)
	local waveEndZ = waveStartZ + waveLength
	local featureEndZ = waveEndZ + ChicanePath.EXIT_STRAIGHT

	local points = { Vector3.new(0, 0, 0) }
	if startOffset > 0 then
		appendLinearSamples(points, points[#points], Vector3.new(0, 0, startOffset), spacing)
	end
	appendLinearSamples(points, points[#points], Vector3.new(0, 0, waveStartZ), spacing)

	if waveLength > 0 then
		local waveSteps = math.max(2, math.ceil(waveLength / spacing))
		for index = 1, waveSteps do
			local t = index / waveSteps
			local waveDistance = waveLength * t
			table.insert(points, Vector3.new(
				waveX(amplitude, waveLength, waveDistance),
				0,
				waveStartZ + waveDistance
			))
		end
	end

	appendLinearSamples(points, points[#points], Vector3.new(0, 0, featureEndZ), spacing)
	if points[#points].Z < Constants.STRAIGHT_LENGTH then
		appendLinearSamples(points, points[#points], Vector3.new(0, 0, Constants.STRAIGHT_LENGTH), spacing)
	end

	return points
end

return ChicanePath
