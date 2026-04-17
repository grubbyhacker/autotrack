-- VerifierController.luau
-- Phase 1 waypoint follower for the verifier car.
-- This is intentionally simpler than the Phase 3 semi-rail controller.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local FailureDetector = require(script.Parent.FailureDetector)
local MetricCollector = require(script.Parent.MetricCollector)
local ReacquireDetector = require(script.Parent.ReacquireDetector)

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

local function cleanup(attachment: Attachment, linearVelocity: LinearVelocity, alignOrientation: AlignOrientation)
	attachment:Destroy()
	linearVelocity:Destroy()
	alignOrientation:Destroy()
end

local function getPadSpeedDelta(currentSectorId: number?): number
	if not currentSectorId then
		return 0
	end

	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(string.format("Sector_%02d", currentSectorId))
	if not folder then
		return 0
	end

	local car = workspace:FindFirstChild("VerifierCar")
	if not car or not car:IsA("BasePart") then
		return 0
	end

	for _, padName in ipairs({ "IngressPad", "EgressPad" }) do
		local pad = folder:FindFirstChild(padName)
		if pad and pad:IsA("BasePart") then
			local localPoint = pad.CFrame:PointToObjectSpace(car.Position)
			if math.abs(localPoint.X) <= pad.Size.X * 0.5
				and math.abs(localPoint.Y) <= math.max(pad.Size.Y, Constants.CAR_HEIGHT) * 0.5
				and math.abs(localPoint.Z) <= pad.Size.Z * 0.5 then
				local padType = pad:GetAttribute("PadType")
				if padType == "Boost" then
					return Constants.BOOST_SPEED_DELTA
				elseif padType == "Brake" then
					return Constants.BRAKE_SPEED_DELTA
				end
			end
		end
	end

	return 0
end

function VerifierController.runLap(
	car: BasePart,
	waypoints: { CFrame },
	waypointSectors: { number }?,
	sectorKinds: { [number]: string }?,
	onSectorChange: ((id: number, entering: boolean) -> ())?,
	targetSectorId: number?
): RunResult
	assert(#waypoints >= 2, "VerifierController.runLap: expected at least two waypoints")

	local currentSectorId: number? = nil
	local handleSectorChange = onSectorChange
	if waypointSectors then
		assert(#waypointSectors == #waypoints, "VerifierController.runLap: waypoint sector map mismatch")
		currentSectorId = (waypointSectors :: { number })[1]

		handleSectorChange = function(id: number, entering: boolean)
			local speed = car.AssemblyLinearVelocity.Magnitude
			if entering then
				MetricCollector.onSectorEntry(id, speed)
			else
				MetricCollector.onSectorExit(id, speed)
			end
			if onSectorChange then
				onSectorChange(id, entering)
			end
		end

		handleSectorChange(currentSectorId :: number, true)
	end

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
	alignOrientation.Responsiveness = 5
	alignOrientation.RigidityEnabled = false
	alignOrientation.Parent = car

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { car }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	MetricCollector.reset(car.Position.Y)
	FailureDetector.reset()
	local baselineLapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime") or 30

	local startTime = os.clock()
	local waypointIndex = 1
	local completed = false

	while not completed do
		local now = os.clock()
		local elapsed = now - startTime

		local carPosition = car.Position
		local targetPosition = waypoints[waypointIndex].Position
		local toTarget = targetPosition - carPosition
		local distanceToTarget = toTarget.Magnitude

		if distanceToTarget <= 10 then
			waypointIndex += 1
			if waypointIndex > #waypoints then
				if waypointSectors and handleSectorChange and currentSectorId then
					handleSectorChange(currentSectorId, false)
				end
				completed = true
				break
			end
			if waypointSectors and handleSectorChange then
				local newSectorId = (waypointSectors :: { number })[waypointIndex]
				if newSectorId ~= currentSectorId then
					handleSectorChange(currentSectorId :: number, false)
					currentSectorId = newSectorId
					handleSectorChange(currentSectorId :: number, true)
				end
			end
			targetPosition = waypoints[waypointIndex].Position
			toTarget = targetPosition - carPosition
			distanceToTarget = toTarget.Magnitude
		end

		local segmentStart = waypoints[math.max(waypointIndex - 1, 1)].Position
		local segmentEnd = targetPosition
		local projectedPoint = projectPointToSegment(carPosition, segmentStart, segmentEnd)
		local moveDirection = distanceToTarget > 0 and toTarget.Unit or waypoints[waypointIndex].LookVector
		local segmentDirection = (segmentEnd - segmentStart).Magnitude > 0
			and (segmentEnd - segmentStart).Unit
			or moveDirection
		local lookAheadIndex = math.min(waypointIndex + Constants.WAYPOINT_LOOKAHEAD, #waypoints)
		local lookTarget = waypoints[lookAheadIndex].Position
		local lookDirection = (lookTarget - carPosition).Magnitude > 0
			and (lookTarget - carPosition).Unit
			or moveDirection
		local isAirborne = not ReacquireDetector.isGrounded(carPosition, rayParams)
		local speed = car.AssemblyLinearVelocity.Magnitude
		local lateralOffset = projectedPoint - carPosition
		local lateralError = lateralOffset.Magnitude

		MetricCollector.record(speed, carPosition, isAirborne, lateralError)

		local isCorner = sectorKinds and currentSectorId and sectorKinds[currentSectorId] == "Corner"
		local speedFactor = isCorner and Constants.CORNER_SPEED_FACTOR or 1
		local targetSpeed = math.max(5, Constants.CAR_TARGET_SPEED * speedFactor + getPadSpeedDelta(currentSectorId))
		local vectorVelocity = moveDirection * targetSpeed
		if not isAirborne and lateralError > 1 then
			local lateralNudge = lateralOffset.Unit * math.min(lateralError, Constants.CAR_MAX_LATERAL_CORRECTION)
			vectorVelocity += lateralNudge
		end

		linearVelocity.VectorVelocity = vectorVelocity

		if isAirborne then
			alignOrientation.MaxTorque = 0
		else
			alignOrientation.MaxTorque = 10000
			alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, segmentDirection)
		end

		local failure = FailureDetector.check(
			elapsed,
			currentSectorId or 1,
			carPosition,
			projectedPoint,
			isAirborne,
			speed
		)
		if failure then
			local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
			cleanup(attachment, linearVelocity, alignOrientation)
			return {
				success = false,
				failure = failure,
				metrics = metrics,
			}
		end

		RunService.Heartbeat:Wait()
	end

	local lapTime = os.clock() - startTime
	local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, lapTime, baselineLapTime)
	cleanup(attachment, linearVelocity, alignOrientation)

	return {
		success = true,
		failure = nil,
		metrics = metrics,
	}
end

return VerifierController
