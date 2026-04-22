local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local CornerPath = require(script.Parent.CornerPath)

local TrackVisuals = {}

local CELL_WIDTH = (Constants.CORNER_RADIUS * 2) + Constants.TRACK_WIDTH
local SHELL_THICKNESS = 1.2
local SHELL_DROP = 0.35
local ROAD_SURFACE_THICKNESS = 0.04
local ROAD_SURFACE_LIFT = Constants.TRACK_THICKNESS * 0.5 - ROAD_SURFACE_THICKNESS * 0.5 + 0.005
local LINE_THICKNESS = 0.06
local LINE_LIFT = Constants.TRACK_THICKNESS * 0.5 + 0.16
local EDGE_LINE_OFFSET = Constants.TRACK_WIDTH * 0.5 - 0.25
local PATH_RIBBON_OVERLAP = 0.16
local PATH_UNDERLAY_OVERLAP = 0.38
local PATH_EDGE_OVERLAP = 0.08
local PATH_UNDERLAY_EXTRA_WIDTH = 0.12
local PATH_UNDERLAY_EXTRA_THICKNESS = 0.01
local PATH_UNDERLAY_LIFT_OFFSET = -0.015
local CORNER_VISUAL_ARC_SAMPLES = 81
local CORNER_VISUAL_SHOULDER_SAMPLE_SPACING = 1

local BASE_COLOR = Color3.fromRGB(122, 130, 138)
local ROAD_COLOR = Color3.fromRGB(42, 43, 47)
local LINE_COLOR = Color3.fromRGB(240, 238, 227)
local CURB_RED = Color3.fromRGB(181, 54, 48)
local STRIPE_WHITE = Color3.fromRGB(242, 239, 232)
local SUPPORT_COLOR = Color3.fromRGB(106, 96, 83)
local ARROW_COLOR = Color3.fromRGB(255, 196, 64)

local LABEL_GREEN = Color3.fromRGB(100, 255, 160)
local LABEL_GLOW_BG = Color3.fromRGB(8, 36, 18)

local COLLISION_FOLDER = "Collision"
local VISUAL_FOLDER = "Visual"
local PADS_FOLDER = "Pads"
local ANCHOR_NAME = "Anchor"
local FOUNDATION_FOLDER = "Foundation"

local function sectorFolderById(sectorId)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(string.format("Sector_%02d", sectorId))
	assert(folder and folder:IsA("Folder"), "TrackVisuals: sector folder missing: " .. tostring(sectorId))
	return folder
end

local function folderOrSector(sectorOrFolder, name)
	local folder = if type(sectorOrFolder) == "number"
		then sectorFolderById(sectorOrFolder)
		else sectorOrFolder
	local child = folder:FindFirstChild(name)
	assert(child and child:IsA("Folder"), string.format("TrackVisuals: missing folder %s under %s", name, folder.Name))
	return child
end

local function addSectorLabel(anchor: Part, sectorId: number, _sectorKind: string)
	local existing = anchor:FindFirstChildWhichIsA("BillboardGui")
	if existing then existing:Destroy() end
	local existingParticle = anchor:FindFirstChildOfClass("ParticleEmitter")
	if existingParticle then existingParticle:Destroy() end

	local gui = Instance.new("BillboardGui")
	gui.Name = "SectorLabel"
	gui.Size = UDim2.new(0, 64, 0, 30)
	gui.StudsOffset = Vector3.new(0, 24, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = anchor

	local bg = Instance.new("Frame")
	bg.BackgroundColor3 = LABEL_GLOW_BG
	bg.BackgroundTransparency = 0.72
	bg.BorderSizePixel = 0
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.Parent = gui
	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 10)
	bgCorner.Parent = bg
	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = LABEL_GREEN
	bgStroke.Transparency = 0.5
	bgStroke.Thickness = 1.5
	bgStroke.Parent = bg

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Text = "S" .. tostring(sectorId)
	label.TextColor3 = LABEL_GREEN
	label.TextSize = 17
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = bg
end

local function ensureFolder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function clearFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
end

local function makeAdornmentPart(parent, name, size, cframe, color, material, transparency)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material
	part.Color = color
	part.Transparency = transparency or 0
	part.Parent = parent
	return part
end

local function roadSurfaceCenter(entryFrame, exitFrame)
	return entryFrame.Position:Lerp(exitFrame.Position, 0.5) + Vector3.new(0, ROAD_SURFACE_LIFT, 0)
end

local function addEdgeLines(parent, usableWidth, usableLength)
	if usableWidth < 2 or usableLength < 8 then
		return
	end

	local xOffset = math.max(0.4, usableWidth * 0.5 - 0.25)
	for _, x in ipairs({ -xOffset, xOffset }) do
		makeAdornmentPart(
			parent,
			if x < 0 then "EdgeLine_L" else "EdgeLine_R",
			Vector3.new(0.18, LINE_THICKNESS, math.max(usableLength - 2, 2)),
			parent.CFrame * CFrame.new(x, parent.Size.Y * 0.5 + 0.08, 0),
			LINE_COLOR,
			Enum.Material.SmoothPlastic
		)
	end
end

local function addCenterDashes(parent, usableLength)
	if usableLength < 18 then
		return
	end

	local dashLength = 7
	local gap = 10
	local z = -usableLength * 0.5 + 12
	while z < usableLength * 0.5 - 6 do
		makeAdornmentPart(
			parent,
			string.format("CenterDash_%d", math.floor((z + usableLength * 0.5) * 10)),
			Vector3.new(0.22, LINE_THICKNESS, dashLength),
			parent.CFrame * CFrame.new(0, parent.Size.Y * 0.5 + 0.08, z),
			LINE_COLOR,
			Enum.Material.SmoothPlastic
		)
		z += dashLength + gap
	end
end

local function addArcRibbon(
	parent,
	namePrefix,
	arcCenter,
	entryPos,
	exitPos,
	radius,
	width,
	thickness,
	yOffset,
	color,
	material,
	segmentCount
)
	local up = Vector3.new(0, 1, 0)
	local dirToEntry = (entryPos - arcCenter).Unit
	local dirToExit = (exitPos - arcCenter).Unit
	local startAngle = math.atan2(dirToEntry.Z, dirToEntry.X)
	local endAngle = math.atan2(dirToExit.Z, dirToExit.X)
	local delta = endAngle - startAngle
	if delta <= -math.pi then
		delta += 2 * math.pi
	elseif delta > math.pi then
		delta -= 2 * math.pi
	end

	for index = 1, segmentCount do
		local t0 = (index - 1) / segmentCount
		local t1 = index / segmentCount
		local a0 = startAngle + delta * t0
		local a1 = startAngle + delta * t1
		local p0 = arcCenter + Vector3.new(math.cos(a0), 0, math.sin(a0)) * radius
		local p1 = arcCenter + Vector3.new(math.cos(a1), 0, math.sin(a1)) * radius
		local chord = p1 - p0
		local length = math.max(chord.Magnitude + 0.45, 1)
		local mid = p0:Lerp(p1, 0.5) + up * yOffset
		local tangent = chord.Magnitude > 0 and chord.Unit or (p1 - arcCenter).Unit:Cross(up)
		makeAdornmentPart(
			parent,
			string.format("%s_%02d", namePrefix, index),
			Vector3.new(width, thickness, length),
			CFrame.lookAt(mid, mid + tangent),
			color,
			material
		)
	end
end

local function tangentAt(points, firstIndex: number, secondIndex: number): Vector3
	local p0 = points[firstIndex]
	local p1 = points[secondIndex]
	local delta = p1 - p0
	if delta.Magnitude <= 0.001 then
		return Vector3.zAxis
	end
	return delta.Unit
end

local function joinExtension(width: number, previousTangent: Vector3, currentTangent: Vector3): number
	local dot = math.clamp(previousTangent:Dot(currentTangent), -1, 1)
	local angle = math.acos(dot)
	if angle <= 0.001 then
		return 0
	end

	-- Extend enough to cover the inner-edge wedge at a heading change, but cap
	-- the join so very sharp local samples do not create visible self-overlap.
	local extension = (width * 0.5) * math.tan(angle * 0.5)
	return math.clamp(extension, 0, width * 0.35)
end

local function addPathRibbon(parent, namePrefix, points, width, thickness, yOffset, color, material, overlap, dynamicJoinCoverage: boolean?)
	local joinOverlap = overlap or PATH_RIBBON_OVERLAP
	for index = 2, #points do
		local p0 = points[index - 1]
		local p1 = points[index]
		local chord = p1 - p0
		local tangent = chord.Magnitude > 0 and chord.Unit or Vector3.zAxis
		local startExtension = joinOverlap * 0.5
		local endExtension = joinOverlap * 0.5
		if dynamicJoinCoverage == true then
			local previousTangent = if index > 2
				then tangentAt(points, index - 2, index - 1)
				else tangent
			local nextTangent = if index < #points
				then tangentAt(points, index - 1, index)
				else tangent
			startExtension += joinExtension(width, previousTangent, tangent)
			endExtension += joinExtension(width, tangent, nextTangent)
		end
		local length = math.max(chord.Magnitude + startExtension + endExtension, 0.8)
		local centerPoint = p0:Lerp(p1, 0.5) + tangent * ((endExtension - startExtension) * 0.5)
		local mid = centerPoint + Vector3.new(0, yOffset, 0)
		makeAdornmentPart(
			parent,
			string.format("%s_%02d", namePrefix, index - 1),
			Vector3.new(width, thickness, length),
			CFrame.lookAt(mid, mid + tangent),
			color,
			material
		)
	end
end

local function turnAngleAt(points, index: number): number
	if index <= 1 or index >= #points then
		return 0
	end

	local previousTangent = tangentAt(points, index - 1, index)
	local nextTangent = tangentAt(points, index, index + 1)
	local dot = math.clamp(previousTangent:Dot(nextTangent), -1, 1)
	return math.acos(dot)
end

local function makeFlatCylinderCFrame(position: Vector3, tangent: Vector3): CFrame
	local axisX = Vector3.yAxis
	local axisZ = tangent
	if axisZ.Magnitude <= 0.001 or math.abs(axisZ:Dot(axisX)) >= 0.999 then
		axisZ = Vector3.zAxis
	else
		axisZ = axisZ.Unit
	end
	local axisY = axisZ:Cross(axisX)
	if axisY.Magnitude <= 0.001 then
		axisY = Vector3.xAxis
	else
		axisY = axisY.Unit
	end
	return CFrame.fromMatrix(position, axisX, axisY, axisZ)
end

local function addPathRoundJoinCaps(parent, namePrefix, points, width, thickness, yOffset, color, material)
	for index = 2, #points - 1 do
		local turnAngle = turnAngleAt(points, index)
		if turnAngle > 0.01 then
			local previousTangent = tangentAt(points, index - 1, index)
			local nextTangent = tangentAt(points, index, index + 1)
			local blendTangent = previousTangent + nextTangent
			if blendTangent.Magnitude <= 0.001 then
				blendTangent = nextTangent
			end

			local joinPart = makeAdornmentPart(
				parent,
				string.format("%s_%02d", namePrefix, index - 1),
				Vector3.new(thickness, width, width),
				makeFlatCylinderCFrame(points[index] + Vector3.new(0, yOffset, 0), blendTangent),
				color,
				material
			)
			joinPart.Shape = Enum.PartType.Cylinder
		end
	end
end

local addPathEdgeLines

function TrackVisuals.renderPathSurface(
	visualFolder,
	points,
	width,
	showEdgeLines: boolean?,
	showUnderlay: boolean?,
	surfaceOverlapOverride: number?,
	underlayOverlapOverride: number?,
	surfaceLiftOffsetOverride: number?,
	underlayLiftOffsetOverride: number?,
	dynamicJoinCoverage: boolean?,
	roundJoinCaps: boolean?
)
	local surfaceOverlap = surfaceOverlapOverride or PATH_RIBBON_OVERLAP
	local underlayOverlap = underlayOverlapOverride or PATH_UNDERLAY_OVERLAP
	local surfaceLift = ROAD_SURFACE_LIFT + (surfaceLiftOffsetOverride or 0)
	local underlayLift = ROAD_SURFACE_LIFT + PATH_UNDERLAY_LIFT_OFFSET + (underlayLiftOffsetOverride or 0)
	if showUnderlay ~= false then
		addPathRibbon(
			visualFolder,
			"RoadSurfaceUnderlay",
			points,
			width + PATH_UNDERLAY_EXTRA_WIDTH,
			ROAD_SURFACE_THICKNESS + PATH_UNDERLAY_EXTRA_THICKNESS,
			underlayLift,
			ROAD_COLOR,
			Enum.Material.SmoothPlastic,
			underlayOverlap,
			dynamicJoinCoverage
		)
	end
	addPathRibbon(
		visualFolder,
		"RoadSurface",
		points,
		width,
		ROAD_SURFACE_THICKNESS,
		surfaceLift,
		ROAD_COLOR,
		Enum.Material.SmoothPlastic,
		surfaceOverlap,
		dynamicJoinCoverage
	)
	if roundJoinCaps == true then
		addPathRoundJoinCaps(
			visualFolder,
			"RoadSurfaceJoin",
			points,
			width,
			ROAD_SURFACE_THICKNESS,
			surfaceLift,
			ROAD_COLOR,
			Enum.Material.SmoothPlastic
		)
	end
	if showEdgeLines ~= false then
		addPathEdgeLines(visualFolder, points, width)
	end
end

local function offsetPathPoints(points, lateralOffset)
	local offsetPoints = table.create(#points)
	for index, point in ipairs(points) do
		local prevPoint = points[math.max(index - 1, 1)]
		local nextPoint = points[math.min(index + 1, #points)]
		local tangent = nextPoint - prevPoint
		if tangent.Magnitude <= 0.001 then
			tangent = Vector3.xAxis
		else
			tangent = tangent.Unit
		end
		local lateral = tangent:Cross(Vector3.yAxis)
		if lateral.Magnitude <= 0.001 then
			lateral = Vector3.zAxis
		else
			lateral = lateral.Unit
		end
		offsetPoints[index] = point + lateral * lateralOffset
	end
	return offsetPoints
end

addPathEdgeLines = function(parent, points, usableWidth)
	if usableWidth < 2 or #points < 2 then
		return
	end

	for sideIndex, offset in ipairs({ -EDGE_LINE_OFFSET, EDGE_LINE_OFFSET }) do
		addPathRibbon(
			parent,
			if sideIndex == 1 then "EdgeLine_L" else "EdgeLine_R",
			offsetPathPoints(points, offset),
			0.18,
			LINE_THICKNESS,
			LINE_LIFT,
			LINE_COLOR,
			Enum.Material.SmoothPlastic,
			PATH_EDGE_OVERLAP
		)
	end
end

function TrackVisuals.getSectorFolder(sectorId)
	return sectorFolderById(sectorId)
end

function TrackVisuals.getCollisionFolder(sectorOrFolder)
	return folderOrSector(sectorOrFolder, COLLISION_FOLDER)
end

function TrackVisuals.getVisualFolder(sectorOrFolder)
	return folderOrSector(sectorOrFolder, VISUAL_FOLDER)
end

function TrackVisuals.getPadsFolder(sectorOrFolder)
	return folderOrSector(sectorOrFolder, PADS_FOLDER)
end

function TrackVisuals.ensureSectorStructure(sectorFolder, sectorId, sectorKind, cellCFrame, cellSize)
	sectorFolder:SetAttribute("SectorId", sectorId)
	sectorFolder:SetAttribute("SectorKind", sectorKind)

	local anchor = sectorFolder:FindFirstChild(ANCHOR_NAME)
	if not (anchor and anchor:IsA("Part")) then
		anchor = Instance.new("Part")
		anchor.Name = ANCHOR_NAME
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Parent = sectorFolder
	end
	anchor.CFrame = cellCFrame
	anchor:SetAttribute("SectorId", sectorId)
	anchor:SetAttribute("SectorKind", sectorKind)
	anchor:SetAttribute("CellSizeX", cellSize.X)
	anchor:SetAttribute("CellSizeY", cellSize.Y)
	anchor:SetAttribute("CellSizeZ", cellSize.Z)

	ensureFolder(sectorFolder, COLLISION_FOLDER)
	ensureFolder(sectorFolder, VISUAL_FOLDER)
	ensureFolder(sectorFolder, PADS_FOLDER)

	addSectorLabel(anchor, sectorId, sectorKind)
end

function TrackVisuals.clearSectorPresentation(sectorId)
	clearFolder(TrackVisuals.getCollisionFolder(sectorId))
	clearFolder(TrackVisuals.getVisualFolder(sectorId))
end

function TrackVisuals.makeCollisionPart(parent, name, size, cframe, sectorId, sectorKind)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.Transparency = 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	part:SetAttribute("SectorId", sectorId)
	part:SetAttribute("SectorKind", sectorKind)
	part.Parent = parent
	return part
end

function TrackVisuals.renderTrackFoundation(trackFolder, sectors)
	local foundationFolder = ensureFolder(trackFolder, FOUNDATION_FOLDER)
	clearFolder(foundationFolder)

	local sectorById = {}
	for _, sector in ipairs(sectors) do
		sectorById[sector.id] = sector
	end

	local topLeft = sectorById[1]
	local topRight = sectorById[5]
	local bottomRight = sectorById[6]
	local bottomLeft = sectorById[10]
	assert(topLeft and topRight and bottomRight and bottomLeft, "TrackVisuals.renderTrackFoundation: missing perimeter sectors")

	local rowSpanX = (topRight.center.X - topLeft.center.X) + CELL_WIDTH
	local columnSpanZ = (bottomLeft.center.Z - topLeft.center.Z) + CELL_WIDTH
	local foundationY = topLeft.center.Y - SHELL_DROP
	local rowCenterX = (topLeft.center.X + topRight.center.X) * 0.5
	local columnCenterZ = (topLeft.center.Z + bottomLeft.center.Z) * 0.5

	makeAdornmentPart(
		foundationFolder,
		"TopFoundation",
		Vector3.new(rowSpanX, SHELL_THICKNESS, CELL_WIDTH),
		CFrame.new(rowCenterX, foundationY, topLeft.center.Z),
		BASE_COLOR,
		Enum.Material.Concrete
	)
	makeAdornmentPart(
		foundationFolder,
		"BottomFoundation",
		Vector3.new(rowSpanX, SHELL_THICKNESS, CELL_WIDTH),
		CFrame.new(rowCenterX, foundationY, bottomLeft.center.Z),
		BASE_COLOR,
		Enum.Material.Concrete
	)
	makeAdornmentPart(
		foundationFolder,
		"LeftFoundation",
		Vector3.new(CELL_WIDTH, SHELL_THICKNESS, columnSpanZ),
		CFrame.new(topLeft.center.X, foundationY, columnCenterZ),
		BASE_COLOR,
		Enum.Material.Concrete
	)
	makeAdornmentPart(
		foundationFolder,
		"RightFoundation",
		Vector3.new(CELL_WIDTH, SHELL_THICKNESS, columnSpanZ),
		CFrame.new(topRight.center.X, foundationY, columnCenterZ),
		BASE_COLOR,
		Enum.Material.Concrete
	)
end

function TrackVisuals.renderCellShell(visualFolder, cellCFrame, cellSize, name)
	return
end

function TrackVisuals.renderStraightFlatVisuals(visualFolder, cellCFrame, cellSize, entryFrame, exitFrame)
	clearFolder(visualFolder)

	local center = roadSurfaceCenter(entryFrame, exitFrame)
	local road = makeAdornmentPart(
		visualFolder,
		"RoadSurface",
		Vector3.new(Constants.TRACK_WIDTH, ROAD_SURFACE_THICKNESS, (exitFrame.Position - entryFrame.Position).Magnitude),
		CFrame.lookAt(center, center + exitFrame.LookVector),
		ROAD_COLOR,
		Enum.Material.SmoothPlastic
	)
	addEdgeLines(road, road.Size.X, road.Size.Z)
	addCenterDashes(road, road.Size.Z)
end

function TrackVisuals.renderCornerFlatVisuals(visualFolder, cellCFrame, cellSize, entryFrame, exitFrame)
	clearFolder(visualFolder)
	local points = CornerPath.buildWorldCenterlinePoints(
		entryFrame,
		exitFrame,
		visualFolder.Parent:GetAttribute("CornerEntryShoulderLength"),
		visualFolder.Parent:GetAttribute("CornerExitShoulderLength"),
		CORNER_VISUAL_ARC_SAMPLES,
		CORNER_VISUAL_SHOULDER_SAMPLE_SPACING
	)
	TrackVisuals.renderPathSurface(visualFolder, points, Constants.TRACK_WIDTH)
end

function TrackVisuals.renderStraightMechanicShell(visualFolder, cellCFrame, cellSize, name)
	clearFolder(visualFolder)
end

function TrackVisuals.styleRoadPiece(part)
	part.Material = Enum.Material.SmoothPlastic
	part.Color = ROAD_COLOR
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	addEdgeLines(part, part.Size.X, part.Size.Z)
end

function TrackVisuals.addAlternatingStripes(part, stripeLength)
	if stripeLength <= 0 or part.Size.Z < stripeLength then
		return
	end

	local bandWidth = math.max(math.min(Constants.CAR_WIDTH * 0.22, part.Size.X * 0.22), 0.6)
	local bandOffset = math.max(part.Size.X * 0.5 - bandWidth * 0.7, bandWidth * 0.6)
	local topY = part.Size.Y * 0.5 + 0.09
	local startZ = -part.Size.Z * 0.5 + stripeLength * 0.5
	local index = 1
	local z = startZ

	while z <= part.Size.Z * 0.5 - stripeLength * 0.5 do
		for sideIndex, x in ipairs({ -bandOffset, bandOffset }) do
			makeAdornmentPart(
				part,
				string.format("Stripe_%02d_%d", index, sideIndex),
				Vector3.new(bandWidth, 0.05, stripeLength),
				part.CFrame * CFrame.new(x, topY, z),
				if index % 2 == 1 then CURB_RED else STRIPE_WHITE,
				Enum.Material.SmoothPlastic
			)
		end
		index += 1
		z += stripeLength
	end
end

function TrackVisuals.addRampSupports(hostPart, rampHeight)
	local supportCount = 3
	local roadHalfWidth = math.max(hostPart.Size.X * 0.5 - 1.25, 1)
	local groundY = Constants.TRACK_THICKNESS

	for _, x in ipairs({ -roadHalfWidth, roadHalfWidth }) do
		for index = 1, supportCount do
			local t = index / (supportCount + 1)
			local localZ = -hostPart.Size.Z * 0.5 + hostPart.Size.Z * t
			local undersideWorld = hostPart.CFrame:PointToWorldSpace(Vector3.new(x, -hostPart.Size.Y * 0.5, localZ))
			local height = undersideWorld.Y - groundY
			if height > 0.8 then
				makeAdornmentPart(
					hostPart,
					string.format("RampSupport_%d_%d", if x < 0 then 0 else 1, index),
					Vector3.new(1, height, 1),
					CFrame.new(undersideWorld.X, groundY + height * 0.5, undersideWorld.Z),
					SUPPORT_COLOR,
					Enum.Material.Concrete
				)
			end
		end
	end

	if rampHeight > 1 then
		local braceLength = math.max(hostPart.Size.Z * 0.55, 4)
		makeAdornmentPart(
			hostPart,
			"RampCenterBrace",
			Vector3.new(1.2, 1.2, braceLength),
			hostPart.CFrame * CFrame.new(0, -hostPart.Size.Y * 0.3, 0),
			SUPPORT_COLOR,
			Enum.Material.Metal
		)
	end
end

function TrackVisuals.addRampArrow(hostPart)
	local topY = hostPart.Size.Y * 0.5 + 0.1
	local chevronCount = 4
	local chevronWidth = math.min(hostPart.Size.X * 0.42, 5.8)
	local chevronLength = math.max(hostPart.Size.Z * 0.12, 1.6)
	local chevronThickness = 0.08
	local barThickness = math.max(chevronWidth * 0.12, 0.32)
	local startZ = -hostPart.Size.Z * 0.22
	local spacing = math.max(hostPart.Size.Z * 0.16, 2.2)

	for index = 1, chevronCount do
		local centerZ = startZ + (index - 1) * spacing
		for sideIndex, xSign in ipairs({ -1, 1 }) do
			makeAdornmentPart(
				hostPart,
				string.format("RampChevron_%d_%d", index, sideIndex),
				Vector3.new(barThickness, chevronThickness, chevronLength),
				hostPart.CFrame
					* CFrame.new(xSign * chevronWidth * 0.22, topY, centerZ)
					* CFrame.Angles(0, math.rad(45 * xSign), 0),
				ARROW_COLOR,
				Enum.Material.Neon
			)
		end
	end
end

function TrackVisuals.addCurbs(part)
	if part.Size.X < 4 or part.Size.Z < 4 then
		return
	end

	local curbWidth = 0.55
	local curbHeight = 0.12
	local xOffset = part.Size.X * 0.5 - curbWidth * 0.5
	for index, x in ipairs({ -xOffset, xOffset }) do
		makeAdornmentPart(
			part,
			if index == 1 then "Curb_L" else "Curb_R",
			Vector3.new(curbWidth, curbHeight, math.max(part.Size.Z - 1.5, 2)),
			part.CFrame * CFrame.new(x, part.Size.Y * 0.5 + 0.08, 0),
			CURB_RED,
			Enum.Material.SmoothPlastic
		)
	end
end

function TrackVisuals.getCellWidth()
	return CELL_WIDTH
end

return TrackVisuals
