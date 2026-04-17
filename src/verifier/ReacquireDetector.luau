-- ReacquireDetector.luau
-- Detects whether the verifier car has reacquired the track surface
-- after becoming airborne or laterally displaced.
-- prd_plan.md §6.3, §11.2, §11.4, Phase 3

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local ReacquireDetector = {}

local GROUNDED_THRESHOLD = Constants.CAR_HEIGHT * 0.5 + Constants.TRACK_THICKNESS + 1.5

-- Returns true if the car is currently in contact with the track surface.
function ReacquireDetector.isGrounded(position: Vector3, raycastParams: RaycastParams): boolean
	local result = workspace:Raycast(position, Vector3.new(0, -GROUNDED_THRESHOLD, 0), raycastParams)
	return result ~= nil
end

-- Accumulates distance traveled since last becoming airborne.
-- Returns the total distance covered since liftoff (for min_air_distance checks).
function ReacquireDetector.airDistanceSince(liftoffPosition: Vector3, currentPosition: Vector3): number
	return (currentPosition - liftoffPosition).Magnitude
end

return ReacquireDetector
