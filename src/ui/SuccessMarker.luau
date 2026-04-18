-- SuccessMarker.luau
-- Brief highlight on the committed sector after a successful job.
-- prd_plan.md §13.4, Phase 8

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

local SuccessMarker = {}
local ROOT_NAME = "AutoTrackUIWorld"
local MARKER_NAME = "SuccessMarker"

-- Briefly highlight the committed sector, then fade out after UI_SUCCESS_DWELL seconds.
-- sectorParts: the Instances making up the sector geometry
function SuccessMarker.flash(sectorParts: { Instance })
	if #sectorParts == 0 then
		return
	end

	SuccessMarker.clear()

	local root = workspace:FindFirstChild(ROOT_NAME)
	if not root then
		root = Instance.new("Folder")
		root.Name = ROOT_NAME
		root.Parent = workspace
	end

	local container = Instance.new("Folder")
	container.Name = MARKER_NAME
	container.Parent = root

	for _, instance in ipairs(sectorParts) do
		if instance:IsA("BasePart") then
			local highlight = Instance.new("Highlight")
			highlight.Name = "SuccessHighlight"
			highlight.Adornee = instance
			highlight.FillColor = Color3.fromRGB(115, 199, 143)
			highlight.FillTransparency = 0.7
			highlight.OutlineColor = Color3.fromRGB(255, 219, 158)
			highlight.OutlineTransparency = 0.15
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Parent = container
		end
	end

	task.delay(Constants.UI_SUCCESS_DWELL, function()
		if container.Parent then
			container:Destroy()
		end
	end)
end

function SuccessMarker.clear()
	local root = workspace:FindFirstChild(ROOT_NAME)
	if not root then
		return
	end
	local marker = root:FindFirstChild(MARKER_NAME)
	if marker then
		marker:Destroy()
	end
end

return SuccessMarker
