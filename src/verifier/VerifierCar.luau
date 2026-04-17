-- VerifierCar.luau
-- Owns the single verifier car BasePart in the Workspace.
-- prd_plan.md §6.2, Phase 1 baseline slice

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

-- Isolate the car from the player character so the character cannot ride the car.
-- Guard with pcall: re-requiring this module in the same session would error on duplicate group names.
pcall(function()
	PhysicsService:RegisterCollisionGroup("VerifierCar")
	PhysicsService:RegisterCollisionGroup("PlayerCharacter")
	PhysicsService:CollisionGroupSetCollidable("VerifierCar", "PlayerCharacter", false)
end)

local function applyCharacterGroup(character: Model)
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CollisionGroup = "PlayerCharacter"
		end
	end
	character.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			desc.CollisionGroup = "PlayerCharacter"
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	if player.Character then applyCharacterGroup(player.Character) end
	player.CharacterAdded:Connect(applyCharacterGroup)
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
