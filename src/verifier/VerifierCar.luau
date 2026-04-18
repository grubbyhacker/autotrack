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
	part.BrickColor = BrickColor.new("Bright red")
	part.CustomPhysicalProperties = PhysicalProperties.new(1, 0.5, 0)
	part.CFrame = startCFrame
	part.Parent = workspace

	_part = part
	return part
end

function VerifierCar.reset(startCFrame: CFrame)
	local part = VerifierCar.getPart()
	part.CFrame = startCFrame
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
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
