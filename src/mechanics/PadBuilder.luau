-- PadBuilder.luau
-- Places ingress/egress pad geometry for a sector.
-- prd_plan.md §5, Phase 4
--
-- Pad values: "None" | "Boost" | "Brake"
-- Fixed magnitudes from Constants — no arbitrary numeric strengths.
-- No stacking.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type Pads = Types.Pads

local PadBuilder = {}

local function getSectorFolder(sector_id: number): Folder
	local name = string.format("Sector_%02d", sector_id)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(name)
	assert(folder, "getSectorFolder: not found: " .. name)
	return folder :: Folder
end

-- Place (or remove) the ingress and egress pads for a sector.
-- padAreaStart: CFrame where the ingress pad should be positioned
-- padAreaEnd:   CFrame where the egress pad should be positioned
function PadBuilder.applyPads(pads: Pads, ingressFrame: CFrame, egressFrame: CFrame, sector_id: number)
	local folder = getSectorFolder(sector_id)

	for _, child in ipairs(folder:GetChildren()) do
		if child.Name == "IngressPad" or child.Name == "EgressPad" then
			child:Destroy()
		end
	end

	local padSize = Vector3.new(Constants.TRACK_WIDTH, 0.2, 4)
	local yOff = Constants.TRACK_THICKNESS * 0.5 + 0.1

	local function makePadPart(name: string, padValue: Types.PadValue, frame: CFrame)
		if padValue == "None" then
			return
		end

		local pad = Instance.new("Part")
		pad.Name = name
		pad.Size = padSize
		pad.CFrame = frame * CFrame.new(0, yOff, 0)
		pad.Anchored = true
		pad.CanCollide = false
		pad.Transparency = 0.5
		pad.TopSurface = Enum.SurfaceType.Smooth
		pad.BottomSurface = Enum.SurfaceType.Smooth
		pad.Material = Enum.Material.Neon
		pad.BrickColor = if padValue == "Boost"
			then BrickColor.new("Bright green")
			else BrickColor.new("Bright red")
		pad:SetAttribute("PadType", padValue)
		pad.Parent = folder
	end

	makePadPart("IngressPad", pads.ingress, ingressFrame)
	makePadPart("EgressPad", pads.egress, egressFrame)
end

return PadBuilder
