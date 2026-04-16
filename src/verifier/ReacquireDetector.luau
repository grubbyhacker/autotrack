-- ReacquireDetector.luau
-- Detects whether the verifier car has reacquired the track surface
-- after becoming airborne or laterally displaced.
-- prd_plan.md §6.3, §11.2, §11.4, Phase 3

local Constants = require(script.Parent.Parent.common.Constants)

local ReacquireDetector = {}

-- Returns true if the car is currently in contact with the track surface.
-- position: car root position
-- trackSurface: a function (Vector3) → number giving the surface height at XZ
function ReacquireDetector.isGrounded(position: Vector3, trackSurface: (Vector3) -> number): boolean
	-- TODO: Phase 3 — raycast downward from car position; compare hit distance
	-- against a grounded threshold.
	error("ReacquireDetector.isGrounded: not yet implemented")
end

-- Accumulates distance traveled since last becoming airborne.
-- Returns the total distance covered since liftoff (for min_air_distance checks).
function ReacquireDetector.airDistanceSince(liftoffPosition: Vector3, currentPosition: Vector3): number
	return (currentPosition - liftoffPosition).Magnitude
end

return ReacquireDetector
