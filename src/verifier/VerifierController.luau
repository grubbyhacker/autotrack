-- VerifierController.luau
-- Phase 1 waypoint follower for the verifier car.
-- This is intentionally simpler than the Phase 3 semi-rail controller.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type RunResult = Types.RunResult

local VerifierController = {}

local function projectPointToSegment(point: Vector3, startPoint: Vector3, endPoint: Vector3): (Vector3, number)
	local segment = endPoint - startPoint
	local lengthSquared = segment:Dot(segment)

	if lengthSquared == 0 then
		return startPoint, 0
	end

	local alpha = math.clamp((point - startPoint):Dot(segment) / lengthSquared, 0, 1)
	return startPoint + segment * alpha, alpha
end

local function buildPlaceholderMetrics(lapTime: number): Types.RunMetrics
	return {
		entry_speed = 0,
		exit_speed = 0,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 0,
		reacquired = true,
		lap_time = lapTime,
		slowdown_ratio = 1,
	}
end

local function buildFailure(sectorId: number, failureType: Types.FailureType, lapTime: number): RunResult
	return {
		success = false,
		failure = {
			type = failureType,
			sector_id = sectorId,
		},
		metrics = buildPlaceholderMetrics(lapTime),
	}
end

function VerifierController.runLap(car: BasePart, waypoints: { CFrame }): RunResult
	assert(#waypoints >= 2, "VerifierController.runLap: expected at least two waypoints")

	local attachment = Instance.new("Attachment")
	attachment.Name = "VerifierAttachment"
	attachment.Parent = car

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Attachment0 = attachment
	linearVelocity.ForceLimitsEnabled = true
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	linearVelocity.MaxForce = 10000
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = car

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.MaxTorque = 100000
	alignOrientation.Responsiveness = 20
	alignOrientation.RigidityEnabled = false
	alignOrientation.Parent = car

	local startTime = os.clock()
	local waypointIndex = 1
	local completed = false

	while not completed do
		local now = os.clock()
		local elapsed = now - startTime
		if elapsed >= Constants.LAP_TIMEOUT then
			attachment:Destroy()
			linearVelocity:Destroy()
			alignOrientation:Destroy()
			return buildFailure(math.min(waypointIndex, #waypoints), "system_failure", elapsed)
		end

		local carPosition = car.Position
		local targetPosition = waypoints[waypointIndex].Position
		local toTarget = targetPosition - carPosition
		local distanceToTarget = toTarget.Magnitude

		if distanceToTarget <= 10 then
			waypointIndex += 1
			if waypointIndex > #waypoints then
				completed = true
				break
			end
			targetPosition = waypoints[waypointIndex].Position
			toTarget = targetPosition - carPosition
			distanceToTarget = toTarget.Magnitude
		end

		local segmentStart = waypoints[math.max(waypointIndex - 1, 1)].Position
		local segmentEnd = targetPosition
		local projectedPoint = projectPointToSegment(carPosition, segmentStart, segmentEnd)
		local lateralDistance = (carPosition - projectedPoint).Magnitude
		if lateralDistance > Constants.TRACK_WIDTH then
			attachment:Destroy()
			linearVelocity:Destroy()
			alignOrientation:Destroy()
			return buildFailure(math.min(waypointIndex, #waypoints), "local_execution_failure", elapsed)
		end

		local moveDirection = distanceToTarget > 0 and toTarget.Unit or waypoints[waypointIndex].LookVector
		local lookAheadIndex = math.min(waypointIndex + Constants.WAYPOINT_LOOKAHEAD, #waypoints)
		local lookTarget = waypoints[lookAheadIndex].Position
		local lookDirection = (lookTarget - carPosition).Magnitude > 0
			and (lookTarget - carPosition).Unit
			or moveDirection

		linearVelocity.VectorVelocity = moveDirection * Constants.CAR_TARGET_SPEED
		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, lookDirection)

		RunService.Heartbeat:Wait()
	end

	local lapTime = os.clock() - startTime
	attachment:Destroy()
	linearVelocity:Destroy()
	alignOrientation:Destroy()

	return {
		success = true,
		failure = nil,
		metrics = buildPlaceholderMetrics(lapTime),
	}
end

return VerifierController
