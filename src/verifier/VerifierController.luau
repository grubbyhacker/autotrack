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
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)

type RunResult = Types.RunResult

local VerifierController = {}
local TRAIL_POINT_SPACING = 5
local MAX_TRAIL_POINTS = 8

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

local function getActivePad(currentSectorId: number?): (string?, string?, string?)
	if not currentSectorId then
		return nil, nil, nil
	end

	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(string.format("Sector_%02d", currentSectorId))
	if not folder then
		return nil, nil, nil
	end

	local car = workspace:FindFirstChild("VerifierCar")
	if not car or not car:IsA("BasePart") then
		return nil, nil, nil
	end

	for _, padName in ipairs({ "IngressPad", "EgressPad" }) do
		local pad = folder:FindFirstChild(padName)
		if pad and pad:IsA("BasePart") then
			local localPoint = pad.CFrame:PointToObjectSpace(car.Position)
			if math.abs(localPoint.X) <= pad.Size.X * 0.5
				and math.abs(localPoint.Y) <= math.max(pad.Size.Y, Constants.CAR_HEIGHT) * 0.5
				and math.abs(localPoint.Z) <= pad.Size.Z * 0.5 then
				local padType = pad:GetAttribute("PadType")
				return string.format("%d:%s", currentSectorId, padName), padType, padName
			end
		end
	end

	return nil, nil, nil
end

function VerifierController.runLap(
	car: BasePart,
	waypoints: { CFrame },
	waypointSectors: { number }?,
	sectorKinds: { [number]: string }?,
	onSectorChange: ((id: number, entering: boolean) -> ())?,
	targetSectorId: number?,
	targetState,
	targetEntryFrame: CFrame?
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
	alignOrientation.MaxTorque = Constants.CAR_ORIENTATION_MAX_TORQUE
	alignOrientation.Responsiveness = Constants.CAR_ORIENTATION_RESPONSIVENESS
	alignOrientation.RigidityEnabled = false
	alignOrientation.Parent = car

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { car }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	MetricCollector.reset(car.Position.Y, targetSectorId)
	FailureDetector.reset()
	local baselineLapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime") or 30

	local startTime = os.clock()
	local waypointIndex = 1
	local completed = false
	local recentTrail = { car.Position }
	local lastTrailPoint = car.Position
	local persistentTargetSpeed = Constants.CAR_TARGET_SPEED
	local activePadToken = nil
	local padEffectSectorHopsRemaining = 0

	local function recordTrail(position: Vector3)
		if (position - lastTrailPoint).Magnitude < TRAIL_POINT_SPACING then
			return
		end
		table.insert(recentTrail, position)
		lastTrailPoint = position
		while #recentTrail > MAX_TRAIL_POINTS do
			table.remove(recentTrail, 1)
		end
	end

	local function evaluateTargetSectorRuntime(elapsed: number, carPosition: Vector3)
		if currentSectorId ~= targetSectorId or not targetState then
			return nil
		end

		local targetMetrics = MetricCollector.getTargetMetrics()
		local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
		local runtimeOk, runtimeHints

		if targetState.mechanic == "CrestDip" then
			runtimeOk, runtimeHints = CrestDipIntegrity.evaluateRuntime({
				target_airborne = targetMetrics.airborne,
				target_air_distance = targetMetrics.air_distance,
				target_vertical_displacement = targetMetrics.vertical_displacement,
				target_reacquired = targetMetrics.reacquired,
				target_airtime_distance = targetMetrics.airtime_distance,
			})
		elseif targetState.mechanic == "RampJump" then
			runtimeOk, runtimeHints = RampJumpIntegrity.evaluateRuntime({
				target_airborne = targetMetrics.airborne,
				target_air_distance = targetMetrics.air_distance,
				target_reacquired = targetMetrics.reacquired,
			})
		elseif targetState.mechanic == "Chicane" then
			runtimeOk, runtimeHints = ChicaneIntegrity.evaluateRuntime({
				target_left_offset = targetMetrics.left_offset,
				target_right_offset = targetMetrics.right_offset,
				target_lateral_band_changes = targetMetrics.lateral_band_changes,
			})
		else
			return nil
		end

		if runtimeOk then
			return nil
		end

		return {
			success = false,
			failure = { type = "mechanic_integrity_failure", sector_id = targetSectorId or currentSectorId or 1 },
			metrics = metrics,
			integrity_hints = runtimeHints,
			failure_position = carPosition,
			final_position = carPosition,
			trajectory_tail = recentTrail,
		}
	end

	while not completed do
		local now = os.clock()
		local elapsed = now - startTime

		local carPosition = car.Position
		local carCFrame = car.CFrame
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
					local runtimeResult = evaluateTargetSectorRuntime(elapsed, carPosition)
					if runtimeResult then
						cleanup(attachment, linearVelocity, alignOrientation)
						return runtimeResult
					end
					if padEffectSectorHopsRemaining > 0 then
						padEffectSectorHopsRemaining -= 1
						if padEffectSectorHopsRemaining <= 0 then
							persistentTargetSpeed = Constants.CAR_TARGET_SPEED
						end
					end
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
		local orientationLookAheadIndex = math.min(waypointIndex + Constants.ORIENTATION_LOOKAHEAD, #waypoints)
		local orientationTarget = waypoints[orientationLookAheadIndex].Position
		local anticipatedDirection = (orientationTarget - carPosition).Magnitude > 0
			and (orientationTarget - carPosition).Unit
			or lookDirection
		local orientationDirection = (segmentDirection * (1 - Constants.ORIENTATION_BLEND)
			+ anticipatedDirection * Constants.ORIENTATION_BLEND)
		if orientationDirection.Magnitude <= 0 then
			orientationDirection = segmentDirection
		else
			orientationDirection = orientationDirection.Unit
		end
		local isAirborne = not ReacquireDetector.isGrounded(carPosition, rayParams)
		local speed = car.AssemblyLinearVelocity.Magnitude
		local angularSpeed = car.AssemblyAngularVelocity.Magnitude
		local upDot = carCFrame.UpVector:Dot(Vector3.yAxis)
		local lateralOffset = projectedPoint - carPosition
		local lateralError = lateralOffset.Magnitude
		local targetLocalX = nil
		if currentSectorId == targetSectorId and targetEntryFrame ~= nil then
			targetLocalX = targetEntryFrame:PointToObjectSpace(carPosition).X
		end

		recordTrail(carPosition)
		MetricCollector.record(speed, carPosition, isAirborne, lateralError, targetLocalX)

		if currentSectorId == targetSectorId and targetState and targetState.mechanic == "CrestDip" then
			local targetMetrics = MetricCollector.getTargetMetrics()
			if targetMetrics.in_target_sector
				and targetMetrics.airborne
				and targetMetrics.airtime_distance > Constants.CRESTDIP_MAX_AIRTIME_DISTANCE then
				local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
				cleanup(attachment, linearVelocity, alignOrientation)
				return {
					success = false,
					failure = { type = "mechanic_integrity_failure", sector_id = targetSectorId or currentSectorId or 1 },
					metrics = metrics,
					integrity_hints = { "airborne too long after liftoff" },
					failure_position = carPosition,
					final_position = carPosition,
					trajectory_tail = recentTrail,
				}
			end
		end

		local padToken, padType, padName = getActivePad(currentSectorId)
		if padToken ~= nil then
			if padToken ~= activePadToken then
				if padType == "Boost" then
					persistentTargetSpeed = Constants.CAR_TARGET_SPEED + Constants.BOOST_SPEED_DELTA
				elseif padType == "Brake" then
					persistentTargetSpeed = math.max(5, Constants.CAR_TARGET_SPEED + Constants.BRAKE_SPEED_DELTA)
				else
					persistentTargetSpeed = Constants.CAR_TARGET_SPEED
				end
				car.AssemblyLinearVelocity = moveDirection * persistentTargetSpeed
				if padName == "EgressPad" then
					padEffectSectorHopsRemaining = 2
				else
					padEffectSectorHopsRemaining = 1
				end
			end
			activePadToken = padToken
		else
			activePadToken = nil
		end

		local isCorner = sectorKinds and currentSectorId and sectorKinds[currentSectorId] == "Corner"
		local targetSpeed = persistentTargetSpeed
		if isCorner then
			targetSpeed = math.min(targetSpeed, Constants.CAR_TARGET_SPEED * Constants.CORNER_SPEED_FACTOR)
		end
		targetSpeed = math.max(5, targetSpeed)
		local vectorVelocity = moveDirection * targetSpeed
		if not isAirborne and lateralError > 1 then
			local lateralNudge = lateralOffset.Unit * math.min(lateralError, Constants.CAR_MAX_LATERAL_CORRECTION)
			vectorVelocity += lateralNudge
		end

		linearVelocity.VectorVelocity = vectorVelocity

		if isAirborne then
			alignOrientation.MaxTorque = 0
		else
			alignOrientation.MaxTorque = Constants.CAR_ORIENTATION_MAX_TORQUE
			alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, orientationDirection)
		end

		local failure = FailureDetector.check(
			elapsed,
			currentSectorId or 1,
			carPosition,
			projectedPoint,
			isAirborne,
			speed,
			angularSpeed,
			upDot
		)
		if failure then
			local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
			cleanup(attachment, linearVelocity, alignOrientation)
			return {
				success = false,
				failure = failure,
				metrics = metrics,
				failure_position = carPosition,
				final_position = carPosition,
				trajectory_tail = recentTrail,
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
		failure_position = nil,
		final_position = car.Position,
		trajectory_tail = recentTrail,
	}
end

return VerifierController
