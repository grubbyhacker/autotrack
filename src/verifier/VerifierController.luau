-- VerifierController.luau
-- Semi-rail guidance for the verifier car.
-- prd_plan.md §6.3, §6.4, Phase 3
--
-- Control model:
--   - continuous forward-speed controller (not a one-time launch impulse)
--   - limited lateral correction toward the track centerline
--   - limited orientation correction toward the track heading
--
-- Intentionally allows meaningful failures from geometry, speed, or
-- poor reacquisition — guidance is NOT a pin.

local Constants = require(script.Parent.Parent.common.Constants)
local VerifierCar = require(script.Parent.VerifierCar)

local VerifierController = {}

local _running = false

-- Start the guidance loop.  centerlineProvider is a function (position: Vector3) →
-- (nearestPoint: Vector3, heading: Vector3) that the controller queries each frame.
function VerifierController.start(centerlineProvider: (Vector3) -> (Vector3, Vector3))
	_running = true
	-- TODO: Phase 3 — run on Heartbeat:
	--   1. sample current car position & velocity
	--   2. query centerlineProvider for nearest point + heading
	--   3. apply forward thrust toward TARGET_SPEED
	--   4. apply clamped lateral correction
	--   5. apply clamped orientation correction
	error("VerifierController.start: not yet implemented")
end

-- Stop the guidance loop (called on run end or failure).
function VerifierController.stop()
	_running = false
end

return VerifierController
