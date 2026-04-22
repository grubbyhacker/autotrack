-- VerifierController.luau
-- Phase 1 waypoint follower for the verifier car.
-- This is intentionally simpler than the Phase 3 semi-rail controller.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local FailureDetector = require(script.Parent.FailureDetector)
local MetricCollector = require(script.Parent.MetricCollector)
local ReacquireDetector = require(script.Parent.ReacquireDetector)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local Tracer = require(script.Parent.Parent.Orchestrator.Tracer)
local RuntimeContext = require(script.Parent.Parent.Orchestrator.RuntimeContext)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

type RunResult = Types.RunResult

local VerifierController = {}
local TRAIL_POINT_SPACING = 5
local MAX_TRAIL_POINTS = 8
local SECTOR_ENTRY_RIDE_OFFSET_Y = (Constants.TRACK_THICKNESS * 0.5) + (Constants.CAR_HEIGHT * 0.5)

local function moveTowards(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function flattenHorizontal(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function horizontalDirectionOrFallback(primary: Vector3, fallback: Vector3): Vector3
	local flattened = flattenHorizontal(primary)
	if flattened.Magnitude > 1e-4 then
		return flattened.Unit
	end

	local fallbackFlattened = flattenHorizontal(fallback)
	if fallbackFlattened.Magnitude > 1e-4 then
		return fallbackFlattened.Unit
	end

	return Vector3.zAxis
end

local function dampTowardsZero(value: number, maxDelta: number): number
	if value > 0 then
		return math.max(0, value - maxDelta)
	end
	return math.min(0, value + maxDelta)
end

local function runtimeNumberAttr(name: string, fallback: number): number
	local value = workspace:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return fallback
end

local function runtimeBoolAttr(name: string, fallback: boolean): boolean
	local value = workspace:GetAttribute(name)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function baseTargetSpeed(): number
	return math.max(5, runtimeNumberAttr("AutoTrack_CarTargetSpeed", Constants.CAR_TARGET_SPEED))
end

local function buildSectorWaypointRanges(waypointSectors: { number }?): { [number]: { first: number, last: number } }
	local ranges = {}
	if waypointSectors == nil then
		return ranges
	end

	-- The lap path closes by repeating sector 1's entry waypoint at the end.
	-- Ignore that duplicate so sector 1 progress reflects its first real visit.
	local limit = #waypointSectors
	if limit >= 2 and waypointSectors[limit] == waypointSectors[1] then
		limit -= 1
	end

	for index = 1, limit do
		local sectorId = waypointSectors[index]
		local existing = ranges[sectorId]
		if existing == nil then
			ranges[sectorId] = { first = index, last = index }
		else
			existing.last = index
		end
	end
	return ranges
end

VerifierController._buildSectorWaypointRanges = buildSectorWaypointRanges

local function sectorProgressForIndex(rangeInfo, waypointIndex: number, segmentAlpha: number): number
	if rangeInfo == nil then
		return 0
	end
	local span = math.max(rangeInfo.last - rangeInfo.first, 1)
	local numerator = math.clamp((waypointIndex - rangeInfo.first) + segmentAlpha, 0, span)
	return numerator / span
end

local function getCornerShoulderFractions(sectorId: number?): (number, number)
	if sectorId == nil then
		return Constants.CORNER_ENTRY_SHOULDER_FRACTION, Constants.CORNER_EXIT_SHOULDER_FRACTION
	end

	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(string.format("Sector_%02d", sectorId))
	if not folder then
		return Constants.CORNER_ENTRY_SHOULDER_FRACTION, Constants.CORNER_EXIT_SHOULDER_FRACTION
	end

	local entryLength = folder:GetAttribute("CornerEntryShoulderLength") or Constants.CORNER_CORNER_SHOULDER_LENGTH
	local exitLength = folder:GetAttribute("CornerExitShoulderLength") or Constants.CORNER_CORNER_SHOULDER_LENGTH
	local coreLength = math.pi * (Constants.CORNER_RADIUS + Constants.TRACK_WIDTH * 0.5) * 0.5
	local totalLength = math.max(1, entryLength + coreLength + exitLength)
	return math.clamp(entryLength / totalLength, 0.05, 0.75), math.clamp(exitLength / totalLength, 0.05, 0.75)
end

local function cornerProfileTarget(
	baseSpeed: number,
	progress: number,
	sectorId: number?,
	previousSectorIsCorner: boolean,
	nextSectorIsCorner: boolean
): number
	local cornerSpeed = math.min(baseSpeed, baseTargetSpeed() * Constants.CORNER_SPEED_FACTOR)
	if baseSpeed <= cornerSpeed then
		return baseSpeed
	end

	local entryFrac, exitFrac = getCornerShoulderFractions(sectorId)
	local entryBaseSpeed = if previousSectorIsCorner then cornerSpeed else baseSpeed
	local exitBaseSpeed = if nextSectorIsCorner then cornerSpeed else baseSpeed
	if progress <= entryFrac then
		return lerp(entryBaseSpeed, cornerSpeed, progress / entryFrac)
	end
	if progress >= 1 - exitFrac then
		return lerp(cornerSpeed, exitBaseSpeed, (progress - (1 - exitFrac)) / exitFrac)
	end
	return cornerSpeed
end

local function cornerSpeedRate(
	commandedSpeed: number,
	targetSpeed: number,
	progress: number,
	sectorId: number?,
	previousSectorIsCorner: boolean,
	nextSectorIsCorner: boolean
): number
	local entryFrac, exitFrac = getCornerShoulderFractions(sectorId)
	if targetSpeed < commandedSpeed and progress <= entryFrac and not previousSectorIsCorner then
		return Constants.CORNER_ENTRY_BRAKE_RATE
	end
	if targetSpeed > commandedSpeed and progress >= 1 - exitFrac and not nextSectorIsCorner then
		return Constants.CORNER_EXIT_ACCEL_RATE
	end
	if targetSpeed < commandedSpeed then
		return Constants.CAR_BRAKE_RATE
	end
	return Constants.CAR_ACCEL_RATE
end

local function resolveCornerExitAlignedTargetSpeed(
	isCorner: boolean,
	sectorId: number?,
	previousSectorIsCorner: boolean,
	nextSectorIsCorner: boolean,
	isAirborne: boolean,
	sectorProgress: number,
	forwardDot: number,
	targetSpeed: number,
	commandedSpeed: number
): number
	if isAirborne or targetSpeed <= commandedSpeed then
		return targetSpeed
	end

	local alignDot = math.clamp(
		runtimeNumberAttr("AutoTrack_CornerExitAccelAlignDot", Constants.CORNER_EXIT_ACCEL_ALIGN_DOT),
		-1,
		0.9999
	)
	if forwardDot >= alignDot then
		return targetSpeed
	end

	if isCorner then
		local _, exitFrac = getCornerShoulderFractions(sectorId)
		if not nextSectorIsCorner and sectorProgress >= 1 - exitFrac then
			return commandedSpeed
		end
		return targetSpeed
	end

	local straightWindow = math.clamp(
		runtimeNumberAttr("AutoTrack_PostCornerAccelStraightWindow", Constants.POST_CORNER_ACCEL_STRAIGHT_WINDOW),
		0,
		1
	)
	if previousSectorIsCorner and sectorProgress <= straightWindow then
		return commandedSpeed
	end

	return targetSpeed
end

VerifierController._resolveCornerExitAlignedTargetSpeed = resolveCornerExitAlignedTargetSpeed

local function adjacentCornerFlags(
	currentSectorId: number?,
	waypointIndex: number,
	waypointSectors: { number }?,
	sectorKinds: { [number]: string }?
): (boolean, boolean)
	if currentSectorId == nil or waypointSectors == nil or sectorKinds == nil then
		return false, false
	end

	local previousIsCorner = false
	for index = waypointIndex - 1, 1, -1 do
		local sectorId = waypointSectors[index]
		if sectorId ~= currentSectorId then
			previousIsCorner = sectorKinds[sectorId] == "Corner"
			break
		end
	end

	local nextIsCorner = false
	for index = waypointIndex + 1, #waypointSectors do
		local sectorId = waypointSectors[index]
		if sectorId ~= currentSectorId then
			nextIsCorner = sectorKinds[sectorId] == "Corner"
			break
		end
	end

	return previousIsCorner, nextIsCorner
end

local function isPostCornerEditableSector(sectorId: number?): boolean
	return sectorId == 2 or sectorId == 7
end

local function applySuspensionDamping(
	car: BasePart,
	controlDt: number,
	wasAirborne: boolean,
	isAirborne: boolean,
	isCorner: boolean,
	isRampJumpContext: boolean
)
	local linearVelocity = car.AssemblyLinearVelocity
	local angularVelocity = car.AssemblyAngularVelocity

	local landingMinDownSpeed = if isRampJumpContext
		then runtimeNumberAttr("AutoTrack_RampJumpLandingMinDownSpeed", Constants.RAMPJUMP_LANDING_MIN_DOWN_SPEED)
		else runtimeNumberAttr("AutoTrack_LandingMinDownSpeed", Constants.CAR_LANDING_MIN_DOWN_SPEED)
	local landingVerticalMultiplier = if isRampJumpContext
		then runtimeNumberAttr("AutoTrack_RampJumpLandingVerticalMultiplier", Constants.RAMPJUMP_LANDING_VERTICAL_MULTIPLIER)
		else runtimeNumberAttr("AutoTrack_LandingVerticalMultiplier", Constants.CAR_LANDING_VERTICAL_MULTIPLIER)
	local landingAngularMultiplier = if isRampJumpContext
		then runtimeNumberAttr("AutoTrack_RampJumpLandingAngularMultiplier", Constants.RAMPJUMP_LANDING_ANGULAR_MULTIPLIER)
		else runtimeNumberAttr("AutoTrack_LandingAngularMultiplier", Constants.CAR_LANDING_ANGULAR_MULTIPLIER)
	if wasAirborne and not isAirborne and linearVelocity.Y <= -landingMinDownSpeed then
		linearVelocity = Vector3.new(
			linearVelocity.X,
			linearVelocity.Y * landingVerticalMultiplier,
			linearVelocity.Z
		)
		angularVelocity = Vector3.new(
			angularVelocity.X * landingAngularMultiplier,
			angularVelocity.Y,
			angularVelocity.Z * landingAngularMultiplier
		)
	end

	local verticalDelta = runtimeNumberAttr(
		"AutoTrack_SuspensionVerticalDamping",
		Constants.CAR_SUSPENSION_VERTICAL_DAMPING
	) * controlDt
	local angularDelta = runtimeNumberAttr(
		"AutoTrack_SuspensionAngularDamping",
		Constants.CAR_SUSPENSION_ANGULAR_DAMPING
	) * controlDt
	local yawDamping = if isAirborne
		then (
			if isRampJumpContext
				then runtimeNumberAttr("AutoTrack_RampJumpAirborneYawDamping", Constants.RAMPJUMP_AIRBORNE_YAW_DAMPING)
				else runtimeNumberAttr("AutoTrack_AirborneYawDamping", Constants.CAR_AIRBORNE_YAW_DAMPING)
		)
		elseif isCorner
			then runtimeNumberAttr("AutoTrack_CornerYawDamping", Constants.CAR_CORNER_YAW_DAMPING)
			else runtimeNumberAttr("AutoTrack_StraightYawDamping", Constants.CAR_STRAIGHT_YAW_DAMPING)
	local yawDelta = yawDamping * controlDt
	local verticalVelocity = linearVelocity.Y
	if not isAirborne then
		verticalVelocity = dampTowardsZero(verticalVelocity, verticalDelta)
	end
	car.AssemblyLinearVelocity = Vector3.new(linearVelocity.X, verticalVelocity, linearVelocity.Z)
	car.AssemblyAngularVelocity = Vector3.new(
		dampTowardsZero(angularVelocity.X, angularDelta),
		dampTowardsZero(angularVelocity.Y, yawDelta),
		dampTowardsZero(angularVelocity.Z, angularDelta)
	)
end

local function sectorStateForContext(currentSectorId: number?, targetSectorId: number?, targetState)
	if currentSectorId == nil then
		return nil
	end
	if targetSectorId ~= nil and currentSectorId == targetSectorId and targetState ~= nil then
		return targetState
	end
	return SectorRegistry.getCommitted(currentSectorId)
end

local function resolveRampJumpAirborneGuidance(
	isAirborne: boolean,
	rampJumpContext: boolean,
	freezeEnabled: boolean,
	frozenDirection: Vector3?,
	desiredDirection: Vector3,
	carLookVector: Vector3,
	verticalSpeed: number,
	commandedSpeed: number,
	maxUpwardSpeed: number?
): (Vector3, Vector3?, Vector3?)
	if not isAirborne then
		return desiredDirection, nil, nil
	end
	if not rampJumpContext or not freezeEnabled then
		return desiredDirection, nil, frozenDirection
	end

	local lockedDirection = frozenDirection
	if lockedDirection == nil then
		lockedDirection = horizontalDirectionOrFallback(desiredDirection, carLookVector)
	end

	local cappedVerticalSpeed = if type(maxUpwardSpeed) == "number"
		then math.min(verticalSpeed, maxUpwardSpeed)
		else verticalSpeed

	return lockedDirection, Vector3.new(
		lockedDirection.X * commandedSpeed,
		cappedVerticalSpeed,
		lockedDirection.Z * commandedSpeed
	), lockedDirection
end

VerifierController._resolveRampJumpAirborneGuidance = resolveRampJumpAirborneGuidance

local function resolveStraightPinnedAngularVelocity(
	isCorner: boolean,
	pinEnabled: boolean,
	controlDt: number,
	angularVelocity: Vector3
): Vector3
	if isCorner or not pinEnabled then
		return angularVelocity
	end

	local yawDelta = runtimeNumberAttr(
		"AutoTrack_StraightPinYawDamping",
		Constants.STRAIGHT_PIN_YAW_DAMPING
	) * controlDt
	local rollDelta = runtimeNumberAttr(
		"AutoTrack_StraightPinRollDamping",
		Constants.STRAIGHT_PIN_ROLL_DAMPING
	) * controlDt
	local maxYawRate = math.max(0, runtimeNumberAttr(
		"AutoTrack_StraightPinMaxYawRate",
		Constants.STRAIGHT_PIN_MAX_YAW_RATE
	))
	local maxRollRate = math.max(0, runtimeNumberAttr(
		"AutoTrack_StraightPinMaxRollRate",
		Constants.STRAIGHT_PIN_MAX_ROLL_RATE
	))

	local pinned = Vector3.new(
		angularVelocity.X,
		dampTowardsZero(angularVelocity.Y, yawDelta),
		dampTowardsZero(angularVelocity.Z, rollDelta)
	)

	return Vector3.new(
		pinned.X,
		math.clamp(pinned.Y, -maxYawRate, maxYawRate),
		math.clamp(pinned.Z, -maxRollRate, maxRollRate)
	)
end

VerifierController._resolveStraightPinnedAngularVelocity = resolveStraightPinnedAngularVelocity

local function mechanicLeadInProgress(targetState): number
	if targetState == nil or targetState.mechanic == nil then
		return 0
	end

	if targetState.mechanic == "RampJump" then
		local params = targetState.params or {}
		local total = (params.ramp_length or 0) + (params.gap_length or 0) + (params.landing_length or 0)
		return math.clamp(math.max(0, (Constants.STRAIGHT_LENGTH - total) * 0.5) / Constants.STRAIGHT_LENGTH, 0, 1)
	end

	if targetState.mechanic == "CrestDip" then
		local params = targetState.params or {}
		return math.clamp(math.max(0, (Constants.STRAIGHT_LENGTH - (params.sector_length or 0)) * 0.5) / Constants.STRAIGHT_LENGTH, 0, 1)
	end

	return 0
end

local function hasPositiveIngressPad(state): boolean
	if state == nil or state.pads == nil then
		return false
	end
	return PadValueUtils.speedDelta(tostring(state.pads.ingress or "None")) > 0
end

local function mechanicEntryTarget(baseSpeed: number, progress: number, targetState, sectorId: number?): number
	local leadInProgress = mechanicLeadInProgress(targetState)
	local postCornerSector = isPostCornerEditableSector(sectorId)
	if leadInProgress <= 0 or progress >= leadInProgress or (hasPositiveIngressPad(targetState) and not postCornerSector) then
		return baseSpeed
	end

	local entryFactor = Constants.MECHANIC_ENTRY_SPEED_FACTOR
	local blendPower = 1
	if postCornerSector then
		entryFactor = runtimeNumberAttr(
			"AutoTrack_PostCornerMechanicEntrySpeedFactor",
			Constants.POST_CORNER_MECHANIC_ENTRY_SPEED_FACTOR
		)
		blendPower = runtimeNumberAttr(
			"AutoTrack_PostCornerEntryBlendPower",
			Constants.POST_CORNER_ENTRY_BLEND_POWER
		)
	end
	if targetState.mechanic == "CrestDip" then
		entryFactor = if postCornerSector
			then runtimeNumberAttr(
				"AutoTrack_PostCornerCrestDipEntrySpeedFactor",
				Constants.POST_CORNER_CRESTDIP_ENTRY_SPEED_FACTOR
			)
			else runtimeNumberAttr(
				"AutoTrack_CrestDipEntrySpeedFactor",
				Constants.CRESTDIP_ENTRY_SPEED_FACTOR
			)
		blendPower = runtimeNumberAttr("AutoTrack_CrestDipEntryBlendPower", Constants.CRESTDIP_ENTRY_BLEND_POWER)
	elseif targetState.mechanic == "RampJump" then
		entryFactor = if postCornerSector
			then runtimeNumberAttr(
				"AutoTrack_PostCornerRampJumpEntrySpeedFactor",
				Constants.POST_CORNER_RAMPJUMP_ENTRY_SPEED_FACTOR
			)
			else runtimeNumberAttr(
				"AutoTrack_RampJumpEntrySpeedFactor",
				Constants.RAMPJUMP_ENTRY_SPEED_FACTOR
			)
		blendPower = runtimeNumberAttr("AutoTrack_RampJumpEntryBlendPower", Constants.RAMPJUMP_ENTRY_BLEND_POWER)
	end

	local entryCap = math.min(baseSpeed, baseTargetSpeed() * entryFactor)
	local blend = math.clamp(progress / leadInProgress, 0, 1) ^ blendPower
	return lerp(entryCap, baseSpeed, blend)
end

local function sectorEntrySnapSpeedFactor(sectorKind: string?, sectorState, isolatedSectorMode: boolean?): number
	if sectorKind == "Corner" then
		return runtimeNumberAttr(
			"AutoTrack_SectorEntrySnapCornerSpeedFactor",
			Constants.SECTOR_ENTRY_SNAP_CORNER_SPEED_FACTOR
		)
	end
	if isolatedSectorMode then
		return runtimeNumberAttr(
			"AutoTrack_SectorEntrySnapStraightSpeedFactor",
			Constants.SECTOR_ENTRY_SNAP_STRAIGHT_SPEED_FACTOR
		)
	end
	if sectorState ~= nil and sectorState.mechanic == "RampJump" then
		return runtimeNumberAttr(
			"AutoTrack_SectorEntrySnapRampJumpSpeedFactor",
			Constants.SECTOR_ENTRY_SNAP_RAMPJUMP_SPEED_FACTOR
		)
	end
	if sectorState ~= nil and sectorState.mechanic == "CrestDip" then
		return runtimeNumberAttr(
			"AutoTrack_SectorEntrySnapCrestDipSpeedFactor",
			Constants.SECTOR_ENTRY_SNAP_CRESTDIP_SPEED_FACTOR
		)
	end
	if sectorState ~= nil and sectorState.mechanic == "Chicane" then
		return runtimeNumberAttr(
			"AutoTrack_SectorEntrySnapChicaneSpeedFactor",
			Constants.SECTOR_ENTRY_SNAP_CHICANE_SPEED_FACTOR
		)
	end
	return runtimeNumberAttr(
		"AutoTrack_SectorEntrySnapStraightSpeedFactor",
		Constants.SECTOR_ENTRY_SNAP_STRAIGHT_SPEED_FACTOR
	)
end

local function shouldSnapOnSectorEntry(previousSectorId: number?, sectorId: number, sectorKinds: { [number]: string }?): boolean
	if previousSectorId ~= nil
		and sectorKinds ~= nil
		and sectorKinds[previousSectorId] == "Corner"
		and sectorKinds[sectorId] == "Corner" then
		return false
	end
	return true
end

VerifierController._shouldSnapOnSectorEntry = shouldSnapOnSectorEntry

local function getExactSectorEntryFrame(sectorId: number): CFrame?
	if not RuntimeContext.isReady() then
		return nil
	end

	local ok, sector = pcall(function()
		return RuntimeContext.getSectorById(sectorId)
	end)
	if not ok or sector == nil or sector.entry == nil then
		return nil
	end

	local entryFrame = sector.entry
	return CFrame.new(entryFrame.Position + Vector3.new(0, SECTOR_ENTRY_RIDE_OFFSET_Y, 0))
		* (entryFrame - entryFrame.Position)
end

local function buildSectorEntrySnap(
	entryPosition: Vector3,
	referenceWaypoint: CFrame,
	sectorKind: string?,
	sectorState,
	exactEntryFrame: CFrame?,
	isolatedSectorMode: boolean?
)
	local snapOrigin = if exactEntryFrame ~= nil then exactEntryFrame.Position else entryPosition
	local sourceDirection = if exactEntryFrame ~= nil then exactEntryFrame.LookVector else referenceWaypoint.LookVector
	local direction = horizontalDirectionOrFallback(sourceDirection, referenceWaypoint.LookVector)
	local speed = math.max(5, baseTargetSpeed() * sectorEntrySnapSpeedFactor(sectorKind, sectorState, isolatedSectorMode))
	local snapCFrame = CFrame.lookAt(snapOrigin, snapOrigin + direction)
	return snapCFrame, direction * speed, speed, direction
end

VerifierController._buildSectorEntrySnap = buildSectorEntrySnap

local function projectPointToSegment(point: Vector3, startPoint: Vector3, endPoint: Vector3): (Vector3, number)
	local flatStart = flattenHorizontal(startPoint)
	local flatEnd = flattenHorizontal(endPoint)
	local flatPoint = flattenHorizontal(point)
	local segment = flatEnd - flatStart
	local lengthSquared = segment:Dot(segment)

	if lengthSquared == 0 then
		return Vector3.new(startPoint.X, point.Y, startPoint.Z), 0
	end

	local alpha = math.clamp((flatPoint - flatStart):Dot(segment) / lengthSquared, 0, 1)
	local projected = flatStart + segment * alpha
	return Vector3.new(projected.X, point.Y, projected.Z), alpha
end

local function signedLateralDistance(referencePoint: Vector3, trackPoint: Vector3, segmentDirection: Vector3): number
	local flatSegment = horizontalDirectionOrFallback(segmentDirection, Vector3.zAxis)
	return flatSegment:Cross(flattenHorizontal(referencePoint - trackPoint)).Y
end

local function cleanup(attachment: Attachment, linearVelocity: LinearVelocity, alignOrientation: AlignOrientation)
	attachment:Destroy()
	linearVelocity:Destroy()
	alignOrientation:Destroy()
end

local function settleCarAtLapEnd(car: BasePart, finalDirection: Vector3)
	local facing = horizontalDirectionOrFallback(finalDirection, car.CFrame.LookVector)
	car.AssemblyLinearVelocity = Vector3.zero
	car.AssemblyAngularVelocity = Vector3.zero
	car.CFrame = CFrame.lookAt(car.Position, car.Position + facing)
end

local function cloneNumberMap(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function finishFailure(
	attachment: Attachment,
	linearVelocity: LinearVelocity,
	alignOrientation: AlignOrientation,
	failure,
	metrics,
	carPosition: Vector3,
	recentTrail
)
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

local function getActivePad(currentSectorId: number?): (string?, string?, string?)
	if not currentSectorId then
		return nil, nil, nil
	end

	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(string.format("Sector_%02d", currentSectorId))
	if not folder then
		return nil, nil, nil
	end
	local padsFolder = folder:FindFirstChild("Pads")
	if not (padsFolder and padsFolder:IsA("Folder")) then
		return nil, nil, nil
	end

	local car = workspace:FindFirstChild("VerifierCar")
	if not car or not car:IsA("BasePart") then
		return nil, nil, nil
	end

	for _, padName in ipairs({ "IngressPad", "EgressPad" }) do
		local pad = padsFolder:FindFirstChild(padName)
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
	targetEntryFrame: CFrame?,
	runtimeOptions
): RunResult
	assert(#waypoints >= 2, "VerifierController.runLap: expected at least two waypoints")

	local currentSectorId: number? = nil
	local handleSectorChange = onSectorChange
	local firstSectorId: number? = nil
	if waypointSectors then
		assert(#waypointSectors == #waypoints, "VerifierController.runLap: waypoint sector map mismatch")
		currentSectorId = (waypointSectors :: { number })[1]
		firstSectorId = currentSectorId

		handleSectorChange = function(id: number, entering: boolean)
			local speed = car.AssemblyLinearVelocity.Magnitude
			local angularSpeed = car.AssemblyAngularVelocity.Magnitude
			local verticalSpeed = car.AssemblyLinearVelocity.Y
			if entering then
				MetricCollector.onSectorEntry(id, speed)
			else
				MetricCollector.onSectorExit(id, speed, angularSpeed, verticalSpeed)
			end
			if onSectorChange then
				onSectorChange(id, entering)
			end
		end
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "VerifierAttachment"
	attachment.Parent = car

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Attachment0 = attachment
	linearVelocity.ForceLimitsEnabled = true
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	linearVelocity.MaxForce = math.huge
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
	local sectorWaypointRanges = buildSectorWaypointRanges(waypointSectors)

	local startTime = os.clock()
	local waypointIndex = 1
	local completed = false
	local recentTrail = { car.Position }
	local lastTrailPoint = car.Position
	local lastWaypointAdvanceTime = startTime
	local lastControlTime = startTime
	local wasAirborne = false
	local persistentTargetSpeed = baseTargetSpeed()
	local commandedSpeed = baseTargetSpeed()
	local activePadToken = nil
	local padEffectSectorHopsRemaining = 0
	local sectorPeakCenterlineDistance: { [number]: number } = {}
	local sectorPeakSignedLateral: { [number]: number } = {}
	local sectorPeakProgress: { [number]: number } = {}
	local sectorPeakFrontDistance: { [number]: number } = {}
	local sectorPeakBodyDistance: { [number]: number } = {}
	local debugSectorEnabled = runtimeBoolAttr("AutoTrack_SectorDebugEnabled", false)
	local debugSectorTarget = runtimeNumberAttr("AutoTrack_SectorDebugTarget", targetSectorId or -1)
	local debugProgressMax = math.clamp(runtimeNumberAttr("AutoTrack_SectorDebugProgressMax", 0.2), 0.01, 1)
	local debugProgressStep = math.clamp(runtimeNumberAttr("AutoTrack_SectorDebugProgressStep", 0.02), 0.005, 0.2)
	local debugNextProgress = 0
	local rampJumpRecoveryDeadline = 0
	local airborneFrozenDirection = nil
	local postSnapSettleDeadline = 0
	local postSnapDirection = nil
	local isolatedSectorMode = type(runtimeOptions) == "table" and runtimeOptions.isolated_sector == true

	local function recordSectorPeak(
		sectorId: number?,
		centerlineDistance: number,
		signedLateral: number,
		progress: number,
		frontDistance: number,
		bodyDistance: number
	)
		if sectorId == nil then
			return
		end
		local previous = sectorPeakCenterlineDistance[sectorId]
		if previous == nil or centerlineDistance > previous then
			sectorPeakCenterlineDistance[sectorId] = centerlineDistance
			sectorPeakSignedLateral[sectorId] = signedLateral
			sectorPeakProgress[sectorId] = progress
		end
		local previousFront = sectorPeakFrontDistance[sectorId]
		if previousFront == nil or frontDistance > previousFront then
			sectorPeakFrontDistance[sectorId] = frontDistance
		end
		local previousBody = sectorPeakBodyDistance[sectorId]
		if previousBody == nil or bodyDistance > previousBody then
			sectorPeakBodyDistance[sectorId] = bodyDistance
		end
	end

	local function logSectorContainment(sectorId: number?)
		if sectorId == nil then
			return
		end
		Tracer.log(string.format(
			"sector_containment %d center=%.2f front=%.2f body=%.2f signed=%.2f progress=%.2f",
			sectorId,
			sectorPeakCenterlineDistance[sectorId] or 0,
			sectorPeakFrontDistance[sectorId] or 0,
			sectorPeakBodyDistance[sectorId] or 0,
			sectorPeakSignedLateral[sectorId] or 0,
			sectorPeakProgress[sectorId] or 0
		))
	end

	local function publishDebugState(targetSpeed: number, sectorKind: string?)
		car:SetAttribute("AutoTrack_TargetSpeed", targetSpeed)
		car:SetAttribute("AutoTrack_CommandedSpeed", commandedSpeed)
		car:SetAttribute("AutoTrack_CurrentSectorKind", sectorKind or "")
	end

	local function snapIntoSector(sectorId: number, waypointCursor: number): (number, Vector3)
		local sectorKind = if sectorKinds ~= nil then sectorKinds[sectorId] else nil
		local sectorState = sectorStateForContext(sectorId, targetSectorId, targetState)
		local entryIndex = math.max(1, waypointCursor - 1)
		local entryPosition = waypoints[entryIndex].Position
		local referenceWaypoint = waypoints[math.clamp(waypointCursor, 1, #waypoints)]
		local exactEntryFrame = getExactSectorEntryFrame(sectorId)
		local snapCFrame, snapVelocity, snapSpeed, snapDirection = buildSectorEntrySnap(
			entryPosition,
			referenceWaypoint,
			sectorKind,
			sectorState,
			exactEntryFrame,
			isolatedSectorMode
		)
		car.CFrame = snapCFrame
		car.AssemblyLinearVelocity = snapVelocity
		car.AssemblyAngularVelocity = Vector3.zero
		return snapSpeed, snapDirection
	end

	if currentSectorId ~= nil and sectorKinds and sectorKinds[currentSectorId] == "Corner" then
		commandedSpeed = baseTargetSpeed() * Constants.CORNER_SPEED_FACTOR
		publishDebugState(commandedSpeed, "Corner")
	else
		publishDebugState(baseTargetSpeed(), if currentSectorId ~= nil then "Straight" else "")
	end

	if currentSectorId ~= nil
		and handleSectorChange ~= nil
		and runtimeBoolAttr("AutoTrack_SectorEntrySnapEnabled", Constants.SECTOR_ENTRY_SNAP_ENABLED) then
		if shouldSnapOnSectorEntry(nil, currentSectorId, sectorKinds) then
			local snappedSpeed, snappedDirection = snapIntoSector(currentSectorId, 1)
			persistentTargetSpeed = snappedSpeed
			commandedSpeed = snappedSpeed
			activePadToken = nil
			padEffectSectorHopsRemaining = 0
			postSnapDirection = snappedDirection
			postSnapSettleDeadline = startTime + runtimeNumberAttr(
				"AutoTrack_SectorEntrySnapSettleTime",
				Constants.SECTOR_ENTRY_SNAP_SETTLE_TIME
			)
			recentTrail = { car.Position }
			lastTrailPoint = car.Position
			publishDebugState(snappedSpeed, if sectorKinds ~= nil then sectorKinds[currentSectorId] else "Straight")
		end
	end
	if currentSectorId ~= nil and handleSectorChange ~= nil then
		handleSectorChange(currentSectorId :: number, true)
	end

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
				target_reacquire_distance = targetMetrics.reacquire_distance,
				target_exit_angular_speed = targetMetrics.exit_angular_speed,
				target_exit_vertical_speed = targetMetrics.exit_vertical_speed,
			})
		elseif targetState.mechanic == "RampJump" then
			runtimeOk, runtimeHints = RampJumpIntegrity.evaluateRuntime({
				target_airborne = targetMetrics.airborne,
				target_air_distance = targetMetrics.air_distance,
				target_vertical_displacement = targetMetrics.vertical_displacement,
				target_reacquired = targetMetrics.reacquired,
				target_airtime_distance = targetMetrics.airtime_distance,
				target_reacquire_distance = targetMetrics.reacquire_distance,
				target_exit_angular_speed = targetMetrics.exit_angular_speed,
				target_exit_vertical_speed = targetMetrics.exit_vertical_speed,
			})
		elseif targetState.mechanic == "Chicane" then
			runtimeOk, runtimeHints = ChicaneIntegrity.evaluateRuntime({
				target_left_offset = targetMetrics.left_offset,
				target_right_offset = targetMetrics.right_offset,
				target_lateral_band_changes = targetMetrics.lateral_band_changes,
				target_peak_body_distance = targetMetrics.peak_body_distance,
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
		local controlDt = math.max(now - lastControlTime, 1 / 60)
		lastControlTime = now

		local carPosition = car.Position
		local carCFrame = car.CFrame
		local targetPosition = waypoints[waypointIndex].Position
		local toTarget = targetPosition - carPosition
		local distanceToTarget = toTarget.Magnitude

		local waypointAdvanceThreshold = 10
		if waypointSectors ~= nil and currentSectorId ~= nil then
			local nextSectorId = waypointSectors[math.min(waypointIndex + 1, #waypointSectors)]
			if nextSectorId ~= currentSectorId then
				waypointAdvanceThreshold = math.max(
					1,
					runtimeNumberAttr(
						"AutoTrack_SectorEntrySnapTransitionDistance",
						Constants.SECTOR_ENTRY_SNAP_TRANSITION_DISTANCE
					)
				)
			end
		end
		if distanceToTarget <= waypointAdvanceThreshold then
			waypointIndex += 1
			lastWaypointAdvanceTime = now
			if waypointIndex > #waypoints then
				if waypointSectors and handleSectorChange and currentSectorId then
					handleSectorChange(currentSectorId, false)
					logSectorContainment(currentSectorId)
				end
				completed = true
				break
			end
			if waypointSectors and handleSectorChange then
				local newSectorId = (waypointSectors :: { number })[waypointIndex]
				if newSectorId ~= currentSectorId then
					handleSectorChange(currentSectorId :: number, false)
					logSectorContainment(currentSectorId)
					local runtimeResult = evaluateTargetSectorRuntime(elapsed, carPosition)
					if runtimeResult then
						cleanup(attachment, linearVelocity, alignOrientation)
						runtimeResult.metrics.sector_peak_centerline_distance = cloneNumberMap(sectorPeakCenterlineDistance)
						runtimeResult.metrics.sector_peak_signed_lateral = cloneNumberMap(sectorPeakSignedLateral)
						runtimeResult.metrics.sector_peak_progress = cloneNumberMap(sectorPeakProgress)
						runtimeResult.metrics.sector_peak_front_distance = cloneNumberMap(sectorPeakFrontDistance)
						runtimeResult.metrics.sector_peak_body_distance = cloneNumberMap(sectorPeakBodyDistance)
						return runtimeResult
					end
					if currentSectorId == targetSectorId
						and targetState ~= nil
						and targetState.mechanic == "RampJump" then
						rampJumpRecoveryDeadline = now + runtimeNumberAttr(
							"AutoTrack_RampJumpRecoveryTime",
							Constants.RAMPJUMP_RECOVERY_TIME
						)
					end
					if padEffectSectorHopsRemaining > 0 then
						padEffectSectorHopsRemaining -= 1
						if padEffectSectorHopsRemaining <= 0 then
							persistentTargetSpeed = baseTargetSpeed()
						end
					end
					local previousSectorId = currentSectorId
					currentSectorId = newSectorId
					if runtimeBoolAttr("AutoTrack_SectorEntrySnapEnabled", Constants.SECTOR_ENTRY_SNAP_ENABLED)
						and shouldSnapOnSectorEntry(previousSectorId, currentSectorId, sectorKinds) then
						local snappedSpeed, snappedDirection = snapIntoSector(currentSectorId, waypointIndex)
						persistentTargetSpeed = snappedSpeed
						commandedSpeed = snappedSpeed
						activePadToken = nil
						padEffectSectorHopsRemaining = 0
						postSnapDirection = snappedDirection
						postSnapSettleDeadline = now + runtimeNumberAttr(
							"AutoTrack_SectorEntrySnapSettleTime",
							Constants.SECTOR_ENTRY_SNAP_SETTLE_TIME
						)
					else
						postSnapDirection = nil
						postSnapSettleDeadline = 0
					end
					handleSectorChange(currentSectorId :: number, true)
					publishDebugState(
						commandedSpeed,
						if sectorKinds ~= nil then sectorKinds[currentSectorId] else "Straight"
					)
				end
			end
			targetPosition = waypoints[waypointIndex].Position
			carPosition = car.Position
			carCFrame = car.CFrame
			toTarget = targetPosition - carPosition
			distanceToTarget = toTarget.Magnitude
		end

		local segmentStart = waypoints[math.max(waypointIndex - 1, 1)].Position
		local segmentEnd = targetPosition
		local projectedPoint, segmentAlpha = projectPointToSegment(carPosition, segmentStart, segmentEnd)
		local pathDirection = distanceToTarget > 0 and toTarget.Unit or waypoints[waypointIndex].LookVector
		if pathDirection.Magnitude <= 0 then
			pathDirection = waypoints[waypointIndex].LookVector
		end
		local moveDirection = horizontalDirectionOrFallback(pathDirection, waypoints[waypointIndex].LookVector)
		local segmentDirection = horizontalDirectionOrFallback(segmentEnd - segmentStart, moveDirection)
		local isCorner = sectorKinds and currentSectorId and sectorKinds[currentSectorId] == "Corner"
		local previousSectorIsCorner, nextSectorIsCorner = adjacentCornerFlags(
			currentSectorId,
			waypointIndex,
			waypointSectors,
			sectorKinds
		)
		local waypointLookahead = if isCorner then Constants.CORNER_WAYPOINT_LOOKAHEAD else Constants.WAYPOINT_LOOKAHEAD
		local orientationLookahead = if isCorner then Constants.CORNER_ORIENTATION_LOOKAHEAD else Constants.ORIENTATION_LOOKAHEAD
		local orientationBlend = if isCorner then Constants.CORNER_ORIENTATION_BLEND else Constants.ORIENTATION_BLEND
		local lookAheadIndex = math.min(waypointIndex + waypointLookahead, #waypoints)
		local lookTarget = waypoints[lookAheadIndex].Position
		local lookDirection = horizontalDirectionOrFallback(lookTarget - carPosition, moveDirection)
		local orientationLookAheadIndex = math.min(waypointIndex + orientationLookahead, #waypoints)
		local orientationTarget = waypoints[orientationLookAheadIndex].Position
		local anticipatedDirection = horizontalDirectionOrFallback(orientationTarget - carPosition, lookDirection)
		local orientationDirection = horizontalDirectionOrFallback(
			(segmentDirection * (1 - orientationBlend)) + (anticipatedDirection * orientationBlend),
			segmentDirection
		)
		local postSnapSettleActive = now < postSnapSettleDeadline and postSnapDirection ~= nil
		if postSnapSettleActive then
			moveDirection = postSnapDirection
			segmentDirection = postSnapDirection
			orientationDirection = postSnapDirection
		end
		local isAirborne = not ReacquireDetector.isGrounded(carPosition, rayParams)
		local currentSectorState = sectorStateForContext(currentSectorId, targetSectorId, targetState)
		local inAuthoredSector = currentSectorState ~= nil and currentSectorState.mechanic ~= nil
		local inRampJumpSector = currentSectorState ~= nil and currentSectorState.mechanic == "RampJump"
		local isTargetRampJump = currentSectorId == targetSectorId
			and targetState ~= nil
			and targetState.mechanic == "RampJump"
		local rampJumpRecoveryActive = currentSectorId ~= targetSectorId
			and targetState ~= nil
			and targetState.mechanic == "RampJump"
			and now < rampJumpRecoveryDeadline
		local rampJumpContext = inRampJumpSector or rampJumpRecoveryActive
		local straightOrientationPinEnabled = runtimeBoolAttr(
			"AutoTrack_StraightOrientationPinEnabled",
			Constants.STRAIGHT_ORIENTATION_PIN_ENABLED
		)
		applySuspensionDamping(car, controlDt, wasAirborne, isAirborne, isCorner == true, rampJumpContext == true)
		car.AssemblyAngularVelocity = resolveStraightPinnedAngularVelocity(
			isCorner == true,
			straightOrientationPinEnabled,
			controlDt,
			car.AssemblyAngularVelocity
		)
		local speed = car.AssemblyLinearVelocity.Magnitude
		local angularSpeed = car.AssemblyAngularVelocity.Magnitude
		if (currentSectorId == targetSectorId or inAuthoredSector or rampJumpContext)
			and runtimeBoolAttr(
				"AutoTrack_TargetSectorStabilityAssistEnabled",
				Constants.TARGET_SECTOR_STABILITY_ASSIST_ENABLED
			) then
			local maxAngularSpeed = math.max(0, runtimeNumberAttr(
				"AutoTrack_TargetSectorStabilityMaxAngularSpeed",
				Constants.TARGET_SECTOR_STABILITY_MAX_ANGULAR_SPEED
			))
			local maxVerticalSpeed = math.max(0, runtimeNumberAttr(
				"AutoTrack_TargetSectorStabilityMaxVerticalSpeed",
				Constants.TARGET_SECTOR_STABILITY_MAX_VERTICAL_SPEED
			))
			if isTargetRampJump or inRampJumpSector then
				maxAngularSpeed = math.max(0, runtimeNumberAttr(
					"AutoTrack_RampJumpTargetSectorStabilityMaxAngularSpeed",
					Constants.RAMPJUMP_TARGET_SECTOR_STABILITY_MAX_ANGULAR_SPEED
				))
				maxVerticalSpeed = math.max(0, runtimeNumberAttr(
					"AutoTrack_RampJumpTargetSectorStabilityMaxVerticalSpeed",
					Constants.RAMPJUMP_TARGET_SECTOR_STABILITY_MAX_VERTICAL_SPEED
				))
			elseif rampJumpRecoveryActive then
				maxAngularSpeed = math.max(0, runtimeNumberAttr(
					"AutoTrack_RampJumpRecoveryMaxAngularSpeed",
					Constants.RAMPJUMP_RECOVERY_MAX_ANGULAR_SPEED
				))
				maxVerticalSpeed = math.max(0, runtimeNumberAttr(
					"AutoTrack_RampJumpRecoveryMaxVerticalSpeed",
					Constants.RAMPJUMP_RECOVERY_MAX_VERTICAL_SPEED
				))
			end

			local angularVelocity = car.AssemblyAngularVelocity
			local angularMagnitude = angularVelocity.Magnitude
			if maxAngularSpeed > 0 and angularMagnitude > maxAngularSpeed and angularMagnitude > 1e-4 then
				car.AssemblyAngularVelocity = angularVelocity * (maxAngularSpeed / angularMagnitude)
			end

			local linearVelocity = car.AssemblyLinearVelocity
			if maxVerticalSpeed > 0 and math.abs(linearVelocity.Y) > maxVerticalSpeed then
				car.AssemblyLinearVelocity = Vector3.new(
					linearVelocity.X,
					math.clamp(linearVelocity.Y, -maxVerticalSpeed, maxVerticalSpeed),
					linearVelocity.Z
				)
			end

			speed = car.AssemblyLinearVelocity.Magnitude
			angularSpeed = car.AssemblyAngularVelocity.Magnitude
		end
		local upDot = carCFrame.UpVector:Dot(Vector3.yAxis)
		local forwardDot = horizontalDirectionOrFallback(carCFrame.LookVector, orientationDirection):Dot(orientationDirection)
		local rampJumpHeadingFreezeEnabled = runtimeBoolAttr(
			"AutoTrack_RampJumpAirborneHeadingFreezeEnabled",
			Constants.RAMPJUMP_AIRBORNE_HEADING_FREEZE_ENABLED
		)
		local rampJumpMaxUpwardSpeed = runtimeNumberAttr(
			"AutoTrack_RampJumpAirborneMaxUpwardSpeed",
			Constants.RAMPJUMP_AIRBORNE_MAX_UPWARD_SPEED
		)
		local forcedAirborneVectorVelocity
		orientationDirection, forcedAirborneVectorVelocity, airborneFrozenDirection = resolveRampJumpAirborneGuidance(
			isAirborne,
			rampJumpContext == true,
			rampJumpHeadingFreezeEnabled,
			airborneFrozenDirection,
			orientationDirection,
			carCFrame.LookVector,
			car.AssemblyLinearVelocity.Y,
			commandedSpeed,
			rampJumpMaxUpwardSpeed
		)
		if forcedAirborneVectorVelocity ~= nil then
			local ballisticVertical = car.AssemblyLinearVelocity.Y - (workspace.Gravity * controlDt)
			forcedAirborneVectorVelocity = Vector3.new(
				forcedAirborneVectorVelocity.X,
				math.min(ballisticVertical, rampJumpMaxUpwardSpeed),
				forcedAirborneVectorVelocity.Z
			)
		end
		forwardDot = horizontalDirectionOrFallback(carCFrame.LookVector, orientationDirection):Dot(orientationDirection)
		local lateralOffset = projectedPoint - carPosition
		local lateralError = lateralOffset.Magnitude
		local signedLateral = signedLateralDistance(carPosition, projectedPoint, segmentDirection)
		local frontPosition = carPosition + horizontalDirectionOrFallback(carCFrame.LookVector, orientationDirection) * (Constants.CAR_LENGTH * 0.5)
		local projectedFrontPoint = projectPointToSegment(frontPosition, segmentStart, segmentEnd)
		local frontSignedLateral = signedLateralDistance(frontPosition, projectedFrontPoint, segmentDirection)
		local frontDistance = math.abs(frontSignedLateral)
		local bodyDistance = math.max(lateralError, frontDistance)
		local sectorProgress = sectorProgressForIndex(
			currentSectorId and sectorWaypointRanges[currentSectorId] or nil,
			waypointIndex,
			segmentAlpha
		)
		recordSectorPeak(currentSectorId, lateralError, signedLateral, sectorProgress, frontDistance, bodyDistance)
		local targetLocalX = nil
		local targetLocalZ = nil
		if currentSectorId == targetSectorId and targetEntryFrame ~= nil then
			local targetLocalPoint = targetEntryFrame:PointToObjectSpace(carPosition)
			targetLocalX = targetLocalPoint.X
			targetLocalZ = targetLocalPoint.Z
		end

		recordTrail(carPosition)
		MetricCollector.record(
			speed,
			carPosition,
			isAirborne,
			lateralError,
			targetLocalX,
			targetLocalZ,
			if currentSectorId == targetSectorId then bodyDistance else nil
		)

		if now - lastWaypointAdvanceTime >= Constants.WAYPOINT_STALL_TIME_THRESHOLD then
			local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
			return finishFailure(
				attachment,
				linearVelocity,
				alignOrientation,
				{ type = "local_execution_failure", sector_id = currentSectorId or 1, detail = "no_progress" },
				metrics,
				carPosition,
				recentTrail
			)
		end

		if currentSectorId == targetSectorId and targetState and targetState.mechanic == "CrestDip" then
			local targetMetrics = MetricCollector.getTargetMetrics()
			if targetMetrics.in_target_sector
				and targetMetrics.airborne
				and targetMetrics.airtime_distance > Constants.CRESTDIP_MAX_AIRTIME_DISTANCE then
				local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
				local failureResult = finishFailure(
					attachment,
					linearVelocity,
					alignOrientation,
					{ type = "mechanic_integrity_failure", sector_id = targetSectorId or currentSectorId or 1 },
					metrics,
					carPosition,
					recentTrail
				)
				failureResult.integrity_hints = { "airborne too long after liftoff" }
				failureResult.metrics.sector_peak_centerline_distance = cloneNumberMap(sectorPeakCenterlineDistance)
				failureResult.metrics.sector_peak_signed_lateral = cloneNumberMap(sectorPeakSignedLateral)
				failureResult.metrics.sector_peak_progress = cloneNumberMap(sectorPeakProgress)
				failureResult.metrics.sector_peak_front_distance = cloneNumberMap(sectorPeakFrontDistance)
				failureResult.metrics.sector_peak_body_distance = cloneNumberMap(sectorPeakBodyDistance)
				return failureResult
			end
		end

		if not isAirborne and bodyDistance > runtimeNumberAttr(
			"AutoTrack_FrontBodyContainmentDistance",
			Constants.FRONT_BODY_CONTAINMENT_DISTANCE
		) then
			local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
			metrics.sector_peak_centerline_distance = cloneNumberMap(sectorPeakCenterlineDistance)
			metrics.sector_peak_signed_lateral = cloneNumberMap(sectorPeakSignedLateral)
			metrics.sector_peak_progress = cloneNumberMap(sectorPeakProgress)
			metrics.sector_peak_front_distance = cloneNumberMap(sectorPeakFrontDistance)
			metrics.sector_peak_body_distance = cloneNumberMap(sectorPeakBodyDistance)
			logSectorContainment(currentSectorId)
			return finishFailure(
				attachment,
				linearVelocity,
				alignOrientation,
				{ type = "local_execution_failure", sector_id = currentSectorId or 1, detail = "body_off_track" },
				metrics,
				carPosition,
				recentTrail
			)
		end

		local padToken, padType, padName = getActivePad(currentSectorId)
		if padToken ~= nil then
			if padToken ~= activePadToken then
				persistentTargetSpeed = math.max(5, baseTargetSpeed() + PadValueUtils.speedDelta(tostring(padType)))
				commandedSpeed = persistentTargetSpeed
				car.AssemblyLinearVelocity = pathDirection * persistentTargetSpeed
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

		local targetSpeed = persistentTargetSpeed
		if isCorner then
			local cornerProgress = sectorProgress
			if currentSectorId == firstSectorId then
				cornerProgress = math.max(cornerProgress, Constants.CORNER_ENTRY_SHOULDER_FRACTION)
			end
			targetSpeed = cornerProfileTarget(
				targetSpeed,
				cornerProgress,
				currentSectorId,
				previousSectorIsCorner,
				nextSectorIsCorner
			)
		elseif not isolatedSectorMode and currentSectorId == targetSectorId and targetState ~= nil then
			targetSpeed = mechanicEntryTarget(targetSpeed, sectorProgress, targetState, targetSectorId)
		elseif not isolatedSectorMode and currentSectorState ~= nil and currentSectorState.mechanic == "RampJump" then
			targetSpeed = mechanicEntryTarget(targetSpeed, sectorProgress, currentSectorState, currentSectorId)
		elseif rampJumpRecoveryActive then
			targetSpeed = math.min(
				targetSpeed,
				baseTargetSpeed() * runtimeNumberAttr(
					"AutoTrack_RampJumpRecoverySpeedFactor",
					Constants.RAMPJUMP_RECOVERY_SPEED_FACTOR
				)
			)
		end
		targetSpeed = resolveCornerExitAlignedTargetSpeed(
			isCorner == true,
			currentSectorId,
			previousSectorIsCorner,
			nextSectorIsCorner,
			isAirborne,
			sectorProgress,
			forwardDot,
			targetSpeed,
			commandedSpeed
		)
		targetSpeed = math.max(5, targetSpeed)
		local speedRate = if isCorner
			then cornerSpeedRate(
				commandedSpeed,
				targetSpeed,
				sectorProgress,
				currentSectorId,
				previousSectorIsCorner,
				nextSectorIsCorner
			)
			elseif targetSpeed < commandedSpeed
				then Constants.CAR_BRAKE_RATE
				else Constants.CAR_ACCEL_RATE
		commandedSpeed = moveTowards(commandedSpeed, targetSpeed, speedRate * controlDt)
		publishDebugState(targetSpeed, if isCorner then "Corner" else "Straight")
		if debugSectorEnabled
			and currentSectorId ~= nil
			and currentSectorId == debugSectorTarget
			and sectorProgress <= debugProgressMax
			and sectorProgress >= debugNextProgress then
			Tracer.log(string.format(
				"sector_debug sector=%d progress=%.3f speed=%.2f cmd=%.2f tgt=%.2f ang=%.2f facing=%.3f up=%.3f grounded=%s body=%.2f center=%.2f",
				currentSectorId,
				sectorProgress,
				speed,
				commandedSpeed,
				targetSpeed,
				angularSpeed,
				forwardDot,
				upDot,
				tostring(not isAirborne),
				bodyDistance,
				lateralError
			))
			debugNextProgress += debugProgressStep
		end
		local vectorVelocity = if forcedAirborneVectorVelocity ~= nil
			then forcedAirborneVectorVelocity
			else pathDirection * commandedSpeed
		if postSnapSettleActive then
			vectorVelocity = orientationDirection * commandedSpeed
		elseif not isAirborne and lateralError > 1 then
			local lateralNudge = lateralOffset.Unit * math.min(lateralError, Constants.CAR_MAX_LATERAL_CORRECTION)
			vectorVelocity += Vector3.new(lateralNudge.X, 0, lateralNudge.Z)
		end

		linearVelocity.VectorVelocity = vectorVelocity

		if straightOrientationPinEnabled and not isCorner then
			alignOrientation.MaxTorque = runtimeNumberAttr(
				"AutoTrack_StraightPinOrientationMaxTorque",
				Constants.STRAIGHT_PIN_ORIENTATION_MAX_TORQUE
			)
			alignOrientation.Responsiveness = runtimeNumberAttr(
				"AutoTrack_StraightPinOrientationResponsiveness",
				Constants.STRAIGHT_PIN_ORIENTATION_RESPONSIVENESS
			)
		elseif isAirborne then
			alignOrientation.MaxTorque = if rampJumpContext
				then runtimeNumberAttr(
					"AutoTrack_RampJumpAirborneOrientationMaxTorque",
					Constants.RAMPJUMP_AIRBORNE_ORIENTATION_MAX_TORQUE
				)
				else runtimeNumberAttr(
					"AutoTrack_AirborneOrientationMaxTorque",
					Constants.CAR_AIRBORNE_ORIENTATION_MAX_TORQUE
				)
			alignOrientation.Responsiveness = runtimeNumberAttr(
				"AutoTrack_StraightOrientationResponsiveness",
				Constants.CAR_STRAIGHT_ORIENTATION_RESPONSIVENESS
			)
		elseif isCorner then
			alignOrientation.MaxTorque = runtimeNumberAttr(
				"AutoTrack_CornerOrientationMaxTorque",
				Constants.CAR_CORNER_ORIENTATION_MAX_TORQUE
			)
			alignOrientation.Responsiveness = runtimeNumberAttr(
				"AutoTrack_CornerOrientationResponsiveness",
				Constants.CAR_CORNER_ORIENTATION_RESPONSIVENESS
			)
		else
			alignOrientation.MaxTorque = runtimeNumberAttr(
				"AutoTrack_StraightOrientationMaxTorque",
				Constants.CAR_STRAIGHT_ORIENTATION_MAX_TORQUE
			)
			alignOrientation.Responsiveness = runtimeNumberAttr(
				"AutoTrack_StraightOrientationResponsiveness",
				Constants.CAR_STRAIGHT_ORIENTATION_RESPONSIVENESS
			)
		end
		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, orientationDirection)

		local failure = FailureDetector.check(
			elapsed,
			currentSectorId or 1,
			carPosition,
			projectedPoint,
			isAirborne,
			speed,
			angularSpeed,
			upDot,
			forwardDot
		)
		if failure then
			if debugSectorEnabled
				and currentSectorId ~= nil
				and currentSectorId == debugSectorTarget then
				Tracer.log(string.format(
					"sector_debug_failure sector=%d type=%s detail=%s progress=%.3f speed=%.2f cmd=%.2f tgt=%.2f ang=%.2f facing=%.3f up=%.3f grounded=%s body=%.2f center=%.2f",
					currentSectorId,
					tostring(failure.type),
					tostring(failure.detail),
					sectorProgress,
					speed,
					commandedSpeed,
					targetSpeed,
					angularSpeed,
					forwardDot,
					upDot,
					tostring(not isAirborne),
					bodyDistance,
					lateralError
				))
			end
			local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, elapsed, baselineLapTime)
			metrics.sector_peak_centerline_distance = cloneNumberMap(sectorPeakCenterlineDistance)
			metrics.sector_peak_signed_lateral = cloneNumberMap(sectorPeakSignedLateral)
			metrics.sector_peak_progress = cloneNumberMap(sectorPeakProgress)
			metrics.sector_peak_front_distance = cloneNumberMap(sectorPeakFrontDistance)
			metrics.sector_peak_body_distance = cloneNumberMap(sectorPeakBodyDistance)
			logSectorContainment(currentSectorId)
			return finishFailure(
				attachment,
				linearVelocity,
				alignOrientation,
				failure,
				metrics,
				carPosition,
				recentTrail
			)
		end

		if rampJumpRecoveryActive
			and not isAirborne
			and upDot >= 0.92
			and angularSpeed <= 1.5
			and bodyDistance <= Constants.TRACK_WIDTH * 0.35 then
			rampJumpRecoveryDeadline = 0
		end
		if not isAirborne then
			airborneFrozenDirection = nil
		end
		if now >= postSnapSettleDeadline then
			postSnapDirection = nil
		end

		wasAirborne = isAirborne
		RunService.Heartbeat:Wait()
	end

	local lapTime = os.clock() - startTime
	local metrics = MetricCollector.finalise(targetSectorId or currentSectorId or 1, lapTime, baselineLapTime)
	metrics.sector_peak_centerline_distance = cloneNumberMap(sectorPeakCenterlineDistance)
	metrics.sector_peak_signed_lateral = cloneNumberMap(sectorPeakSignedLateral)
	metrics.sector_peak_progress = cloneNumberMap(sectorPeakProgress)
	metrics.sector_peak_front_distance = cloneNumberMap(sectorPeakFrontDistance)
	metrics.sector_peak_body_distance = cloneNumberMap(sectorPeakBodyDistance)
	settleCarAtLapEnd(car, waypoints[#waypoints].LookVector)
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
