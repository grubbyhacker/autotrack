local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local CornerPath = {}

local function cubicBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u = 1 - t
	return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
end

local function appendLinearSamples(points: { Vector3 }, startPoint: Vector3, endPoint: Vector3, sampleSpacing: number?)
	local distance = (endPoint - startPoint).Magnitude
	if distance <= 0 then
		return
	end

	local spacing = math.max(2, sampleSpacing or Constants.CORNER_SHOULDER_SAMPLE_SPACING)
	local steps = math.max(1, math.ceil(distance / spacing))
	for index = 1, steps do
		table.insert(points, startPoint:Lerp(endPoint, index / steps))
	end
end

function CornerPath.buildWorldCenterlinePoints(
	entryFrame: CFrame,
	exitFrame: CFrame,
	entryShoulderLength: number?,
	exitShoulderLength: number?,
	curveSamplesOverride: number?,
	shoulderSampleSpacingOverride: number?
): { Vector3 }
	local entryShoulder = entryShoulderLength or Constants.CORNER_CORNER_SHOULDER_LENGTH
	local exitShoulder = exitShoulderLength or Constants.CORNER_EDITABLE_SHOULDER_LENGTH
	local handle = Constants.CORNER_CURVE_HANDLE_LENGTH
	local curveSamples = math.max(curveSamplesOverride or Constants.CORNER_ARC_SAMPLES, 5)
	local shoulderSampleSpacing = shoulderSampleSpacingOverride or Constants.CORNER_SHOULDER_SAMPLE_SPACING

	local entryPoint = entryFrame.Position
	local exitPoint = exitFrame.Position
	local entryShoulderEnd = entryPoint + entryFrame.LookVector * entryShoulder
	local exitShoulderStart = exitPoint - exitFrame.LookVector * exitShoulder
	local control1 = entryShoulderEnd + entryFrame.LookVector * handle
	local control2 = exitShoulderStart - exitFrame.LookVector * handle

	local points = { entryPoint }
	appendLinearSamples(points, entryPoint, entryShoulderEnd, shoulderSampleSpacing)
	for index = 1, curveSamples - 2 do
		local t = index / (curveSamples - 1)
		table.insert(points, cubicBezier(entryShoulderEnd, control1, control2, exitShoulderStart, t))
	end
	table.insert(points, exitShoulderStart)
	appendLinearSamples(points, exitShoulderStart, exitPoint, shoulderSampleSpacing)
	return points
end

return CornerPath
