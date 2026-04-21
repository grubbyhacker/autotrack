-- ChicanePath.luau
-- Shared centerline helper for chicane geometry and verifier guidance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local ChicanePath = {}

ChicanePath.TURN_SEGMENTS = 4
ChicanePath.ENTRY_STRAIGHT = 20
ChicanePath.EXIT_STRAIGHT = 20

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

function ChicanePath.buildLocalCenterlinePoints(amplitude: number, transitionLength: number, turnSegmentsOverride: number?): { Vector3 }
	local totalLength = ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + 3 * transitionLength
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - totalLength) * 0.5)
	local turnSegments = math.max(turnSegmentsOverride or ChicanePath.TURN_SEGMENTS, 1)
	local points = { Vector3.new(0, 0, 0) }
	if startOffset > 0 then
		table.insert(points, Vector3.new(0, 0, startOffset))
	end
	table.insert(points, Vector3.new(0, 0, startOffset + ChicanePath.ENTRY_STRAIGHT))

	local function appendTurn(startX: number, endX: number, startZ: number)
		for index = 1, turnSegments do
			local t = index / turnSegments
			local eased = smoothstep(t)
			table.insert(points, Vector3.new(
				startX + (endX - startX) * eased,
				0,
				startZ + transitionLength * t
			))
		end
	end

	appendTurn(0, amplitude, startOffset + ChicanePath.ENTRY_STRAIGHT)
	appendTurn(amplitude, -amplitude, startOffset + ChicanePath.ENTRY_STRAIGHT + transitionLength)
	appendTurn(-amplitude, 0, startOffset + ChicanePath.ENTRY_STRAIGHT + transitionLength * 2)
	table.insert(points, Vector3.new(
		0,
		0,
		startOffset + ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + transitionLength * 3
	))
	if points[#points].Z < Constants.STRAIGHT_LENGTH then
		table.insert(points, Vector3.new(0, 0, Constants.STRAIGHT_LENGTH))
	end

	return points
end

return ChicanePath
