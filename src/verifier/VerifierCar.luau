-- VerifierCar.luau
-- Owns the single verifier car BasePart in the Workspace.
-- prd_plan.md §6.2, Phase 1 baseline slice

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService    = game:GetService("PhysicsService")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

-- Register the verifier car collision group.
-- Guard with pcall: re-requiring this module in the same session would error on duplicate group names.
pcall(function()
	PhysicsService:RegisterCollisionGroup("VerifierCar")
end)

local VerifierCar = {}

local _part: BasePart? = nil

local BODY_RED = Color3.fromRGB(178, 30, 30)
local BODY_DARK = Color3.fromRGB(35, 35, 37)
local ACCENT = Color3.fromRGB(230, 226, 214)
local TIRE = Color3.fromRGB(18, 18, 19)

local function weldVisual(root: BasePart, name: string, size: Vector3, localCFrame: CFrame, color: Color3, shape: Enum.PartType?): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = root.CFrame * localCFrame
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color
	if shape then
		part.Shape = shape
	end
	part.Parent = root

	local weld = Instance.new("WeldConstraint")
	weld.Name = name .. "_Weld"
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part

	return part
end

local function buildVisualShell(root: BasePart)
	local floor = weldVisual(root, "BodyFloor", Vector3.new(2.8, 0.5, 6.2), CFrame.new(0, -0.2, 0), BODY_RED)
	weldVisual(root, "Nose", Vector3.new(1.2, 0.45, 2.8), CFrame.new(0, -0.1, -2.7), BODY_RED)
	weldVisual(root, "NoseTip", Vector3.new(0.55, 0.35, 1.2), CFrame.new(0, -0.08, -4.2), ACCENT)
	weldVisual(root, "Cockpit", Vector3.new(1.5, 0.8, 1.8), CFrame.new(0, 0.35, -0.1), BODY_DARK)
	weldVisual(root, "EngineCover", Vector3.new(1.7, 0.75, 2.2), CFrame.new(0, 0.25, 1.55), BODY_RED)
	weldVisual(root, "FrontWing", Vector3.new(3.8, 0.14, 0.8), CFrame.new(0, -0.18, -4.55), ACCENT)
	weldVisual(root, "RearWingMain", Vector3.new(3.2, 0.16, 0.7), CFrame.new(0, 0.75, 3.25), ACCENT)
	weldVisual(root, "RearWingStrut", Vector3.new(0.35, 0.95, 0.35), CFrame.new(0, 0.2, 3.05), BODY_DARK)
	weldVisual(root, "Intake", Vector3.new(0.55, 0.55, 0.6), CFrame.new(0, 0.9, 1.3), ACCENT)

	for _, side in ipairs({ -1, 1 }) do
		weldVisual(root, if side < 0 then "SidePod_L" else "SidePod_R", Vector3.new(0.7, 0.45, 2.2), CFrame.new(side * 1.1, -0.05, 1.05), BODY_RED)
		weldVisual(root, if side < 0 then "WheelFront_L" else "WheelFront_R", Vector3.new(1.05, 1.05, 0.7), CFrame.new(side * 1.75, -0.45, -2.55) * CFrame.Angles(0, 0, math.rad(90)), TIRE, Enum.PartType.Cylinder)
		weldVisual(root, if side < 0 then "WheelRear_L" else "WheelRear_R", Vector3.new(1.2, 1.2, 0.8), CFrame.new(side * 1.75, -0.42, 2.25) * CFrame.Angles(0, 0, math.rad(90)), TIRE, Enum.PartType.Cylinder)
	end

	floor.Color = BODY_RED
end

function VerifierCar.spawn(startCFrame: CFrame): BasePart
	if _part then
		VerifierCar.destroy()
	end

	local part = Instance.new("Part")
	part.Name = "VerifierCar"
	part.Size = Vector3.new(Constants.CAR_WIDTH, Constants.CAR_HEIGHT, Constants.CAR_LENGTH)
	part.Anchored = false
	part.CanCollide = true
	part.CollisionGroup = "VerifierCar"
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = 1
	part.CustomPhysicalProperties = PhysicalProperties.new(1, 0.5, 0)
	part.CFrame = startCFrame
	part.Parent = workspace
	buildVisualShell(part)

	_part = part
	return part
end

function VerifierCar.reset(startCFrame: CFrame)
	local part = VerifierCar.getPart()
	part.Anchored = false
	part.CFrame = startCFrame
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

function VerifierCar.freeze()
	local part = VerifierCar.getPart()
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Anchored = true
end

function VerifierCar.thaw()
	local part = VerifierCar.getPart()
	part.Anchored = false
end

function VerifierCar.destroy()
	if _part then
		_part:Destroy()
		_part = nil
	end
end

function VerifierCar.getPart(): BasePart
	assert(_part, "VerifierCar not spawned")
	return _part
end

return VerifierCar
