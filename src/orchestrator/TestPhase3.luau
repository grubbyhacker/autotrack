--!strict

-- TestPhase3.luau
-- Verifies the Phase 3 semi-rail controller, real metrics, and reacquire detection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local ReacquireDetector = require(script.Parent.Parent.Verifier.ReacquireDetector)
local FailureDetector = require(script.Parent.Parent.Verifier.FailureDetector)

local TestPhase3 = {}

local function buildRayParams(car: BasePart): RaycastParams
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { car }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	return rayParams
end

local function runFlatLap()
	local sectors = TrackGenerator.generate()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, nil)
end

function TestPhase3.run()
	local result = runFlatLap()
	T.expect(
		"semirail_flat_lap_completes",
		result.success == true,
		"lap failed: " .. tostring(result.failure and result.failure.type)
	)

	T.expect("metrics_lap_time_positive", result.metrics.lap_time > 0, "lap_time=" .. tostring(result.metrics.lap_time))

	T.expect(
		"metrics_entry_speed_captured",
		result.metrics.entry_speed > 0,
		"entry_speed=" .. tostring(result.metrics.entry_speed)
	)

	local settledCar = VerifierCar.getPart()
	T.expect(
		"lap_end_linear_velocity_settled",
		settledCar.AssemblyLinearVelocity.Magnitude <= 0.1,
		string.format("final linear speed %.3f should be near zero", settledCar.AssemblyLinearVelocity.Magnitude)
	)
	T.expect(
		"lap_end_angular_velocity_settled",
		settledCar.AssemblyAngularVelocity.Magnitude <= 0.1,
		string.format("final angular speed %.3f should be near zero", settledCar.AssemblyAngularVelocity.Magnitude)
	)

	local carMass = VerifierCar.getPart():GetMass()
	T.expect(
		"verifiercar_mass_not_toy_light",
		carMass >= 700,
		string.format("expected verifier mass >= 700, got %.2f", carMass)
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
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	local ok, offTrackResult = pcall(function()
		return VerifierController.runLap(offTrackCar, waypoints, waypointSectors, sectorKinds, nil)
	end)
	T.expect(
		"failure_off_track_detected",
		ok and offTrackResult.success == false and offTrackResult.failure ~= nil,
		"expected runLap failure for grounded off-track start"
	)

	FailureDetector.reset()
	local overturnedFailure = nil
	for _, elapsed in ipairs({ 0, 0.4, 0.8, 1.0 }) do
		overturnedFailure =
			FailureDetector.check(elapsed, 3, Vector3.new(0, 3, 0), Vector3.new(0, 3, 0), true, 0, 0, -1, 1)
		if overturnedFailure then
			break
		end
	end
	T.expect(
		"failure_overturned_car_detected",
		overturnedFailure ~= nil and overturnedFailure.type == "local_execution_failure",
		tostring(overturnedFailure and overturnedFailure.type)
	)

	FailureDetector.reset()
	local slidingOverturnedFailure = nil
	for _, elapsed in ipairs({ 0, 0.4, 0.8, 1.0 }) do
		slidingOverturnedFailure = FailureDetector.check(
			elapsed,
			3,
			Vector3.new(elapsed * 12, 3, 0),
			Vector3.new(elapsed * 12, 3, 0),
			false,
			Constants.CAR_TARGET_SPEED,
			0.2,
			-1,
			1
		)
		if slidingOverturnedFailure then
			break
		end
	end
	T.expect(
		"failure_sliding_overturned_car_detected",
		slidingOverturnedFailure ~= nil and slidingOverturnedFailure.type == "local_execution_failure",
		tostring(slidingOverturnedFailure and slidingOverturnedFailure.type)
	)

	FailureDetector.reset()
	local airborneSomersaultFailure = nil
	for _, elapsed in ipairs({ 0, 0.15, 0.35, 0.5 }) do
		airborneSomersaultFailure = FailureDetector.check(
			elapsed,
			3,
			Vector3.new(elapsed * 20, 12, 0),
			Vector3.new(elapsed * 20, 12, 0),
			true,
			Constants.CAR_TARGET_SPEED,
			3.5,
			-1,
			0.2
		)
		if airborneSomersaultFailure then
			break
		end
	end
	T.expect(
		"failure_airborne_somersault_detected",
		airborneSomersaultFailure ~= nil and airborneSomersaultFailure.type == "local_execution_failure",
		tostring(airborneSomersaultFailure and airborneSomersaultFailure.type)
	)

	FailureDetector.reset()
	local tumbleFailure = nil
	for _, elapsed in ipairs({ 0, 0.1, 0.22, 0.35 }) do
		tumbleFailure = FailureDetector.check(
			elapsed,
			3,
			Vector3.new(elapsed * 20, 12, 0),
			Vector3.new(elapsed * 20, 12, 0),
			true,
			Constants.CAR_TARGET_SPEED,
			Constants.TUMBLE_ANGULAR_SPEED_THRESHOLD + 2,
			0.05,
			-0.4
		)
		if tumbleFailure then
			break
		end
	end
	T.expect(
		"failure_tumble_detected",
		tumbleFailure ~= nil and tumbleFailure.detail == "tumble",
		tostring(tumbleFailure and tumbleFailure.detail)
	)

	FailureDetector.reset()
	local spinoutFailure = nil
	for _, elapsed in ipairs({ 0, 0.2, 0.4, 0.6, 0.8, 1.0 }) do
		spinoutFailure = FailureDetector.check(
			elapsed,
			2,
			Vector3.new(elapsed * 10, 3, 0),
			Vector3.new(elapsed * 10, 3, 0),
			false,
			Constants.CAR_TARGET_SPEED,
			Constants.SPIN_ANGULAR_SPEED_THRESHOLD + 1.5,
			1,
			0.2
		)
		if spinoutFailure then
			break
		end
	end
	T.expect(
		"failure_spinout_detected",
		spinoutFailure ~= nil and spinoutFailure.detail == "spinout",
		tostring(spinoutFailure and spinoutFailure.detail)
	)

	FailureDetector.reset()
	local sideRolledFailure = nil
	for _, elapsed in ipairs({ 0, 0.2, 0.4, 0.6 }) do
		sideRolledFailure = FailureDetector.check(
			elapsed,
			2,
			Vector3.new(elapsed * 10, 3, 0),
			Vector3.new(elapsed * 10, 3, 0),
			false,
			Constants.CAR_TARGET_SPEED,
			0.2,
			0.0,
			1
		)
		if sideRolledFailure then
			break
		end
	end
	T.expect(
		"failure_side_rolled_car_detected",
		sideRolledFailure ~= nil and sideRolledFailure.type == "local_execution_failure",
		tostring(sideRolledFailure and sideRolledFailure.type)
	)

	FailureDetector.reset()
	local backwardFacingFailure = nil
	for _, elapsed in ipairs({ 0, 0.2, 0.4, 0.6, 0.8 }) do
		backwardFacingFailure = FailureDetector.check(
			elapsed,
			2,
			Vector3.new(elapsed * 10, 3, 0),
			Vector3.new(elapsed * 10, 3, 0),
			false,
			Constants.CAR_TARGET_SPEED,
			0.2,
			1,
			-1
		)
		if backwardFacingFailure then
			break
		end
	end
	T.expect(
		"failure_backward_facing_car_detected",
		backwardFacingFailure ~= nil and backwardFacingFailure.type == "local_execution_failure",
		tostring(backwardFacingFailure and backwardFacingFailure.type)
	)

	VerifierCar.reset(TrackGenerator.canonicalStart())
end

return TestPhase3
