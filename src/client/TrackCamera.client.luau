-- Trailing chase camera that follows the VerifierCar around the track.
-- Runs on the client; sets CameraType to Scriptable for the duration of the lap.
local RunService = game:GetService("RunService")

local OFFSET = Vector3.new(0, 20, 45) -- above and behind in car-local space (+Z = behind)

local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable

local car = workspace:WaitForChild("VerifierCar", 30)
if not car then return end

RunService.RenderStepped:Connect(function()
	if not car.Parent then return end
	local cf = car.CFrame
	camera.CFrame = CFrame.lookAt(cf:PointToWorldSpace(OFFSET), cf.Position)
end)
