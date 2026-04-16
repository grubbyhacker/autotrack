-- VerifierCar.luau
-- Owns the single verifier car Model in the Workspace.
-- prd_plan.md §6.2, Phase 3
--
-- Responsibilities:
--   - spawn the car at the canonical start CFrame
--   - expose the car's root part for physics queries
--   - reset the car to canonical start state between runs
--
-- The car model itself is placed via MCP; this module holds a reference
-- and provides a typed API over it.

local VerifierCar = {}

local _car: Model? = nil
local _rootPart: BasePart? = nil

-- Called once at startup.  car is the Model placed by MCP.
function VerifierCar.init(car: Model)
	_car = car
	_rootPart = car.PrimaryPart
	assert(_rootPart, "VerifierCar.init: car has no PrimaryPart")
end

-- Reset car to a given CFrame with zero velocity.
function VerifierCar.resetTo(cf: CFrame)
	assert(_car and _rootPart, "VerifierCar not initialised")
	-- TODO: Phase 3 — zero out all VectorForce/BodyVelocity, set PrimaryPart CFrame
	error("VerifierCar.resetTo: not yet implemented")
end

-- Returns the current root CFrame.
function VerifierCar.getCFrame(): CFrame
	assert(_rootPart, "VerifierCar not initialised")
	return _rootPart.CFrame
end

-- Returns the current velocity vector.
function VerifierCar.getVelocity(): Vector3
	assert(_rootPart, "VerifierCar not initialised")
	return _rootPart.AssemblyLinearVelocity
end

return VerifierCar
