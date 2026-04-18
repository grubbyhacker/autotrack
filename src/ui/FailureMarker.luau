-- FailureMarker.luau
-- Visual marker placed at the failure point during analysis/repair phases.
-- prd_plan.md §13.3, Phase 8
--
-- Placed via MCP at the car's final position on failure.
-- Remains visible during all analysis and repair attempts.
-- Cleared on commit, revert, or new job start.

local FailureMarker = {}

local ROOT_NAME = "AutoTrackUIWorld"
local MARKER_NAME = "FailureMarker"

local function ensureRoot(): Folder
	local root = workspace:FindFirstChild(ROOT_NAME)
	if root and root:IsA("Folder") then
		return root
	end
	root = Instance.new("Folder")
	root.Name = ROOT_NAME
	root.Parent = workspace
	return root
end

function FailureMarker.show(position: Vector3, trajectoryTail: { Vector3 }?)
	FailureMarker.hide()

	local root = ensureRoot()
	local folder = Instance.new("Folder")
	folder.Name = MARKER_NAME
	folder.Parent = root

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.Shape = Enum.PartType.Ball
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(214, 91, 73)
	core.Transparency = 0.1
	core.Size = Vector3.new(2.8, 2.8, 2.8)
	core.Position = position + Vector3.new(0, 1.5, 0)
	core.Parent = folder

	local ring = Instance.new("SelectionSphere")
	ring.SurfaceTransparency = 0.35
	ring.Color3 = Color3.fromRGB(255, 191, 94)
	ring.Adornee = core
	ring.Parent = folder

	for index, point in ipairs(trajectoryTail or {}) do
		local dot = Instance.new("Part")
		dot.Name = ("Tail_%02d"):format(index)
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.CanTouch = false
		dot.Shape = Enum.PartType.Ball
		dot.Material = Enum.Material.Neon
		dot.Color = Color3.fromRGB(255, 191, 94)
		dot.Transparency = math.clamp(0.2 + (index / math.max(#trajectoryTail, 1)) * 0.5, 0.2, 0.8)
		dot.Size = Vector3.new(0.8, 0.8, 0.8)
		dot.Position = point + Vector3.new(0, 0.6, 0)
		dot.Parent = folder
	end
end

function FailureMarker.hide()
	local root = workspace:FindFirstChild(ROOT_NAME)
	if not root then
		return
	end
	local marker = root:FindFirstChild(MARKER_NAME)
	if marker then
		marker:Destroy()
	end
end

return FailureMarker
