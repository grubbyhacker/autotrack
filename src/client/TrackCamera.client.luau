-- Dynamic camera that blends between a chase view and an elevated outside-track
-- obstacle view based on the live sector state published by the server.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local stateFolder = ReplicatedStorage:WaitForChild("AutoTrackUIState")

local camera: Camera? = nil
local car: BasePart? = nil
local cameraBlendAlpha = 0
local activeSideSectorId: number? = nil

local function sectorAttr(sectorId: number, suffix: string): string
	return string.format("sector_%d_%s", sectorId, suffix)
end

local function alphaFromSharpness(sharpness: number, dt: number): number
	return 1 - math.exp(-sharpness * dt)
end

local function getSectorCenter(sectorId: number): Vector3?
	local x = stateFolder:GetAttribute(sectorAttr(sectorId, "center_x"))
	local y = stateFolder:GetAttribute(sectorAttr(sectorId, "center_y"))
	local z = stateFolder:GetAttribute(sectorAttr(sectorId, "center_z"))
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function getTrackCenter(): Vector3?
	local sum = Vector3.zero
	local count = 0
	for sectorId = 1, 10 do
		local center = getSectorCenter(sectorId)
		if center then
			sum += center
			count += 1
		end
	end
	if count == 0 then
		return nil
	end
	return sum / count
end

local function normalizeSectorId(sectorId: number): number
	if sectorId < 1 then
		return 10
	end
	if sectorId > 10 then
		return 1
	end
	return sectorId
end

local function getSectorMechanic(sectorId: number): string
	return stateFolder:GetAttribute(sectorAttr(sectorId, "mechanic")) or ""
end

local function getPrerollProgress(currentCar: BasePart, currentSectorId: number, focusSectorId: number): number
	if currentSectorId == focusSectorId then
		return 1
	end

	local currentCenter = getSectorCenter(currentSectorId)
	local focusCenter = getSectorCenter(focusSectorId)
	if not currentCenter or not focusCenter then
		return 0
	end

	local axis = focusCenter - currentCenter
	local axisLengthSquared = axis:Dot(axis)
	if axisLengthSquared <= 0.001 then
		return 0
	end

	local projected = math.clamp((currentCar.Position - currentCenter):Dot(axis) / axisLengthSquared, 0, 1)
	local startProgress = Constants.CAMERA_PREROLL_START_PROGRESS
	local fullProgress = Constants.CAMERA_PREROLL_FULL_PROGRESS
	if projected <= startProgress then
		return 0
	end
	if projected >= fullProgress then
		return 1
	end
	local normalized = math.clamp((projected - startProgress) / math.max(fullProgress - startProgress, 0.001), 0, 1)
	return math.pow(normalized, Constants.CAMERA_PREROLL_CURVE_POWER)
end

local function getObstacleFocusSector(currentCar: BasePart, currentSectorId: number): (number?, number)
	for offset = 0, Constants.CAMERA_OBSTACLE_PREROLL_SECTORS do
		local sectorId = normalizeSectorId(currentSectorId + offset)
		if getSectorMechanic(sectorId) ~= "" then
			return sectorId, getPrerollProgress(currentCar, currentSectorId, sectorId)
		end
	end
	return nil, 0
end

local function computeFallbackView(): CFrame
	local track = Workspace:FindFirstChild("Track")
	if track and track:IsA("Folder") then
		local minBound = nil
		local maxBound = nil
		for _, descendant in ipairs(track:GetDescendants()) do
			if descendant:IsA("BasePart") then
				local halfSize = descendant.Size * 0.5
				local partMin = descendant.Position - halfSize
				local partMax = descendant.Position + halfSize
				if minBound == nil then
					minBound = partMin
					maxBound = partMax
				else
					minBound = Vector3.new(
						math.min(minBound.X, partMin.X),
						math.min(minBound.Y, partMin.Y),
						math.min(minBound.Z, partMin.Z)
					)
					maxBound = Vector3.new(
						math.max(maxBound.X, partMax.X),
						math.max(maxBound.Y, partMax.Y),
						math.max(maxBound.Z, partMax.Z)
					)
				end
			end
		end
		if minBound ~= nil and maxBound ~= nil then
			local center = (minBound + maxBound) * 0.5
			local boundsSize = maxBound - minBound
			local fallbackOffset = Vector3.new(0, math.max(boundsSize.Y + 60, 80), -(boundsSize.Z * 0.7 + 120))
			return CFrame.lookAt(center + fallbackOffset, center)
		end
	end
	return CFrame.lookAt(Vector3.new(0, 80, -140), Vector3.zero)
end

local function resolveCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function resolveCar(): BasePart?
	local candidate = Workspace:FindFirstChild("VerifierCar")
	if candidate and candidate:IsA("BasePart") then
		car = candidate
		return candidate
	end
	car = nil
	return nil
end

local function getCameraBasis(currentCar: BasePart)
	local carForward = currentCar.CFrame.LookVector
	local horizontalForward = Vector3.new(carForward.X, 0, carForward.Z)
	if horizontalForward.Magnitude <= 0.001 then
		horizontalForward = Vector3.new(1, 0, 0)
	else
		horizontalForward = horizontalForward.Unit
	end

	local lateralAxis = Vector3.yAxis:Cross(horizontalForward)
	if lateralAxis.Magnitude <= 0.001 then
		lateralAxis = Vector3.new(0, 0, 1)
	else
		lateralAxis = lateralAxis.Unit
	end

	return horizontalForward, lateralAxis
end

local function getChasePose(currentCar: BasePart): (Vector3, Vector3)
	local horizontalForward = getCameraBasis(currentCar)
	local position = currentCar.Position
		+ Vector3.yAxis * Constants.CAMERA_CHASE_HEIGHT
		- horizontalForward * Constants.CAMERA_CHASE_DISTANCE
	local focus = currentCar.Position + Vector3.yAxis * Constants.CAMERA_FOCUS_HEIGHT
	return position, focus
end

local function getSidePose(currentCar: BasePart, sectorId: number, sideInfluence: number): (Vector3, Vector3)
	local sectorCenter = getSectorCenter(sectorId)
	local trackCenter = getTrackCenter()
	local anchorBase = sectorCenter or currentCar.Position
	local horizontalForward, lateralAxis = getCameraBasis(currentCar)

	local outward = lateralAxis
	if sectorCenter and trackCenter then
		local toTrack = Vector3.new(trackCenter.X - sectorCenter.X, 0, trackCenter.Z - sectorCenter.Z)
		if toTrack.Magnitude > 0.001 and outward:Dot(toTrack.Unit) > 0 then
			outward = -outward
		end
	end

	local focusPoint = currentCar.Position
		+ Vector3.yAxis * Constants.CAMERA_FOCUS_HEIGHT
		+ horizontalForward * Constants.CAMERA_FOCUS_LEAD

	local chasePosition = currentCar.Position
		+ Vector3.yAxis * Constants.CAMERA_CHASE_HEIGHT
		- horizontalForward * (Constants.CAMERA_CHASE_DISTANCE + Constants.CAMERA_PREROLL_BACK_DISTANCE * sideInfluence)
	local sideTargetPosition = anchorBase
		+ outward * Constants.CAMERA_SIDE_OFFSET
		+ Vector3.yAxis * Constants.CAMERA_SIDE_HEIGHT
		- horizontalForward * Constants.CAMERA_SIDE_BACK_OFFSET
	local cameraPosition = chasePosition:Lerp(sideTargetPosition, sideInfluence)

	return cameraPosition, focusPoint
end

local function applyFallbackView()
	local currentCamera = resolveCamera()
	if not currentCamera then
		return
	end
	currentCamera.CameraType = Enum.CameraType.Scriptable
	currentCamera.CameraSubject = nil
	currentCamera.CFrame = computeFallbackView()
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	resolveCamera()
end)

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "VerifierCar" and child:IsA("BasePart") then
		car = child
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child == car then
		car = nil
	end
end)

resolveCamera()
resolveCar()
applyFallbackView()

RunService.RenderStepped:Connect(function(dt)
	local currentCamera = resolveCamera()
	if not currentCamera then
		return
	end

	local currentCar = resolveCar()
	currentCamera.CameraType = Enum.CameraType.Scriptable
	currentCamera.CameraSubject = nil

	if not currentCar or not currentCar.Parent then
		cameraBlendAlpha = 0
		activeSideSectorId = nil
		currentCamera.CFrame = computeFallbackView()
		return
	end

	local currentSectorId = stateFolder:GetAttribute("current_sector_id") or 0
	local desiredSideInfluence = 0
	local chasePosition, chaseFocus = getChasePose(currentCar)
	local sidePosition, sideFocus = chasePosition, chaseFocus
	if type(currentSectorId) == "number" and currentSectorId > 0 then
		local focusSectorId, prerollProgress = getObstacleFocusSector(currentCar, currentSectorId)
		if focusSectorId then
			activeSideSectorId = focusSectorId
			desiredSideInfluence = if currentSectorId == focusSectorId then 1 else prerollProgress
			sidePosition, sideFocus = getSidePose(currentCar, focusSectorId, desiredSideInfluence)
		end
	end

	local alphaSharpness = if desiredSideInfluence > cameraBlendAlpha + 0.001
		then Constants.CAMERA_ALPHA_ENTER_SHARPNESS
		else Constants.CAMERA_ALPHA_EXIT_SHARPNESS
	cameraBlendAlpha = cameraBlendAlpha + (desiredSideInfluence - cameraBlendAlpha) * alphaFromSharpness(alphaSharpness, dt)

	if desiredSideInfluence <= 0 and activeSideSectorId then
		sidePosition, sideFocus = getSidePose(currentCar, activeSideSectorId, cameraBlendAlpha)
	end

	if cameraBlendAlpha <= 0.01 and desiredSideInfluence <= 0 then
		cameraBlendAlpha = 0
		activeSideSectorId = nil
	end

	local renderedPosition = chasePosition:Lerp(sidePosition, cameraBlendAlpha)
	local renderedFocus = chaseFocus:Lerp(sideFocus, cameraBlendAlpha)
	currentCamera.CFrame = CFrame.lookAt(renderedPosition, renderedFocus)
end)
