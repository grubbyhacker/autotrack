-- TestPhase3.luau
-- Verifies the Phase 3 semi-rail controller, real metrics, and reacquire detection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local ReacquireDetector = require(script.Parent.Parent.Verifier.ReacquireDetector)

local TestPhase3 = {}

local function buildRayParams(car: BasePart): RaycastParams
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { car }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	return rayParams
end

local function runFlatLap()
	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors = TrackGenerator.getLapPath(sectors)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	return VerifierController.runLap(car, waypoints, waypointSectors, nil, nil)
end

function TestPhase3.run()
	local result = runFlatLap()
	T.expect(
		"semirail_flat_lap_completes",
		result.success == true,
		"lap failed: " .. tostring(result.failure and result.failure.type)
	)

	T.expect(
		"metrics_lap_time_positive",
		result.metrics.lap_time > 0,
		"lap_time=" .. tostring(result.metrics.lap_time)
	)

	T.expect(
		"metrics_entry_speed_captured",
		result.metrics.entry_speed > 0,
		"entry_speed=" .. tostring(result.metrics.entry_speed)
	)

	VerifierCar.reset(TrackGenerator.canonicalStart())
	local groundedCar = VerifierCar.getPart()
	T.expect(
		"reacquire_grounded_on_track",
		ReacquireDetector.isGrounded(groundedCar.Position, buildRayParams(groundedCar)) == true,
		"car not grounded on flat track"
	)

	VerifierCar.reset(TrackGenerator.canonicalStart() * CFrame.new(0, 20, 0))
	local airborneCar = VerifierCar.getPart()
	T.expect(
		"reacquire_airborne_above_track",
		ReacquireDetector.isGrounded(airborneCar.Position, buildRayParams(airborneCar)) == false,
		"car incorrectly grounded 20 studs above track"
	)
	VerifierCar.reset(TrackGenerator.canonicalStart())

	local offTrackStart = TrackGenerator.canonicalStart() * CFrame.new(Constants.TRACK_WIDTH * 3, 0, 0)
	VerifierCar.reset(offTrackStart)
	local offTrackCar = VerifierCar.getPart()
	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors = TrackGenerator.getLapPath(sectors)
	local ok, offTrackResult = pcall(function()
		return VerifierController.runLap(offTrackCar, waypoints, waypointSectors, nil)
	end)
	T.expect(
		"failure_off_track_detected",
		ok and offTrackResult.success == false and offTrackResult.failure ~= nil,
		"expected runLap failure for grounded off-track start"
	)

	VerifierCar.reset(TrackGenerator.canonicalStart())
end

return TestPhase3
