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
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local TrackVisuals = require(script.Parent.Parent.Track.TrackVisuals)

type Pads = Types.Pads

local PadBuilder = {}

-- Place (or remove) the ingress and egress pads for a sector.
-- padAreaStart: CFrame where the ingress pad should be positioned
-- padAreaEnd:   CFrame where the egress pad should be positioned
function PadBuilder.applyPads(pads: Pads, ingressFrame: CFrame, egressFrame: CFrame, sector_id: number)
	local folder = TrackVisuals.getPadsFolder(sector_id)

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
		local normalized = PadValueUtils.normalize(padValue)
		local kind = PadValueUtils.kind(normalized)
		pad.BrickColor = if kind == "Boost"
			then BrickColor.new("Bright green")
			else BrickColor.new("Bright red")
		pad:SetAttribute("PadType", normalized)
		pad:SetAttribute("PadKind", kind)
		pad:SetAttribute("PadDelta", PadValueUtils.amount(normalized))
		pad.Parent = folder
	end

	makePadPart("IngressPad", pads.ingress, ingressFrame)
	makePadPart("EgressPad", pads.egress, egressFrame)
end

return PadBuilder
