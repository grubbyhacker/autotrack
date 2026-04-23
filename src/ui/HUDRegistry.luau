local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local HUDRegistry = {}

local _refs = nil

local AMBER = Color3.fromRGB(255, 191, 94)
local AMBER_SOFT = Color3.fromRGB(255, 219, 158)
local STEEL = Color3.fromRGB(35, 40, 46)
local STEEL_LIGHT = Color3.fromRGB(68, 76, 86)
local PANEL = Color3.fromRGB(18, 21, 25)
local PANEL_SOFT = Color3.fromRGB(25, 29, 34)
local DANGER = Color3.fromRGB(214, 91, 73)
local SUCCESS = Color3.fromRGB(115, 199, 143)
local TEXT = Color3.fromRGB(234, 231, 225)
local MUTED = Color3.fromRGB(168, 163, 154)
local LEFT_RAIL_WIDTH = 282
local LEFT_RAIL_MARGIN = 20
local LEFT_RAIL_GAP = 20
local RIGHT_RAIL_WIDTH = 176
local LLM_DOCK_WIDTH = 320
local BOTTOM_DOCK_HEIGHT = 78
local BOTTOM_DOCK_GAP = 16
local TOP_STATUS_RIGHT_RESERVE = 300
local TOP_STATUS_MIN_LEFT = 196
local TOP_STATUS_CHROME_CLEARANCE = 196
local REPAIR_CALLOUT_RIGHT_MARGIN = 20
local WARNING_RIGHT_MARGIN = 20

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, transparency: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency
	stroke.Parent = parent
end

local function createFrame(parent: Instance, props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = props.BackgroundColor3 or PANEL
	frame.BackgroundTransparency = props.BackgroundTransparency or 0
	frame.BorderSizePixel = 0
	frame.Size = props.Size
	frame.Position = props.Position
	frame.AnchorPoint = props.AnchorPoint or Vector2.zero
	frame.Parent = parent
	if props.ZIndex then
		frame.ZIndex = props.ZIndex
	end
	return frame
end

local function createLabel(parent: Instance, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = props.Size
	label.Position = props.Position
	label.AnchorPoint = props.AnchorPoint or Vector2.zero
	label.Text = props.Text or ""
	label.TextColor3 = props.TextColor3 or TEXT
	label.TextTransparency = props.TextTransparency or 0
	label.TextSize = props.TextSize or 16
	label.Font = props.Font or Enum.Font.Gotham
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.RichText = props.RichText == true
	label.TextWrapped = props.TextWrapped == true
	label.TextTruncate = props.TextTruncate or Enum.TextTruncate.None
	label.ClipsDescendants = props.ClipsDescendants == true
	label.Parent = parent
	if props.ZIndex then
		label.ZIndex = props.ZIndex
	end
	return label
end

local function createButton(parent: Instance, props)
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = props.BackgroundColor3 or PANEL_SOFT
	button.BackgroundTransparency = props.BackgroundTransparency or 0
	button.BorderSizePixel = 0
	button.Size = props.Size
	button.Position = props.Position
	button.AnchorPoint = props.AnchorPoint or Vector2.zero
	button.Text = props.Text or ""
	button.TextColor3 = props.TextColor3 or TEXT
	button.TextSize = props.TextSize or 15
	button.Font = props.Font or Enum.Font.GothamMedium
	button.AutoButtonColor = true
	button.Parent = parent
	if props.ZIndex then
		button.ZIndex = props.ZIndex
	end
	return button
end

local function createTextBox(parent: Instance, props)
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = props.BackgroundColor3 or PANEL
	box.BorderSizePixel = 0
	box.Size = props.Size
	box.Position = props.Position
	box.AnchorPoint = props.AnchorPoint or Vector2.zero
	box.PlaceholderText = props.PlaceholderText or ""
	box.PlaceholderColor3 = MUTED
	box.Text = props.Text or ""
	box.TextColor3 = TEXT
	box.TextSize = props.TextSize or 16
	box.Font = props.Font or Enum.Font.Code
	box.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	box.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	box.TextWrapped = props.TextWrapped == true
	box.TextTruncate = props.TextTruncate or Enum.TextTruncate.None
	box.MultiLine = props.MultiLine == true
	box.ClearTextOnFocus = if props.ClearTextOnFocus ~= nil then props.ClearTextOnFocus else true
	box.TextEditable = if props.TextEditable ~= nil then props.TextEditable else true
	box.Parent = parent
	if props.ZIndex then
		box.ZIndex = props.ZIndex
	end
	if props.AutomaticSize then
		box.AutomaticSize = props.AutomaticSize
	end
	return box
end

local function tweenFlash(instance: Instance, propertyTable)
	local tween = TweenService:Create(instance, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), propertyTable)
	tween:Play()
end

function HUDRegistry.mount(playerGui: PlayerGui, onSubmit: (string) -> ())
	if _refs and _refs.gui and _refs.gui.Parent == playerGui then
		return _refs
	end

	local existing = playerGui:FindFirstChild("AutoTrackHUD")
	if existing then
		existing:Destroy()
	end
	local existingOverlay = playerGui:FindFirstChild("AutoTrackHUDOverlay")
	if existingOverlay then
		existingOverlay:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoTrackHUD"
	gui.IgnoreGuiInset = false
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	local overlayGui = Instance.new("ScreenGui")
	overlayGui.Name = "AutoTrackHUDOverlay"
	overlayGui.IgnoreGuiInset = true
	overlayGui.ResetOnSpawn = false
	overlayGui.DisplayOrder = 11
	overlayGui.Parent = playerGui

	local topLeftInset = select(1, GuiService:GetGuiInset())
	local statusLeft = math.max(TOP_STATUS_MIN_LEFT, math.floor(topLeftInset.X + TOP_STATUS_CHROME_CLEARANCE))

	-- TOP RIBBON — phase, request summary, repair detail
	local topLeft = createFrame(overlayGui, {
		Size = UDim2.new(1, -(statusLeft + TOP_STATUS_RIGHT_RESERVE), 0, 42),
		Position = UDim2.new(0, statusLeft, 0, 8),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.08,
		ZIndex = 32,
	})
	topLeft.ClipsDescendants = true
	addCorner(topLeft, 16)
	local topLeftStroke = Instance.new("UIStroke")
	topLeftStroke.Color = AMBER
	topLeftStroke.Transparency = 0.25
	topLeftStroke.Parent = topLeft

	local phaseLabel = createLabel(topLeft, {
		Position = UDim2.new(0, 14, 0, 0),
		Size = UDim2.new(0, 210, 1, 0),
		Text = "Ready for request",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 33,
	})

	local requestLabel = createLabel(topLeft, {
		Position = UDim2.new(0, 230, 0, 0),
		Size = UDim2.new(1, -244, 1, 0),
		Text = "",
		TextColor3 = MUTED,
		TextSize = 14,
		Font = Enum.Font.Code,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 33,
	})

	local reasoningLabel = createLabel(topLeft, {
		Position = UDim2.new(0, 14, 0, 25),
		Size = UDim2.new(1, -28, 0, 15),
		Text = "",
		TextColor3 = MUTED,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = false,
		ZIndex = 33,
	})

	local reasoningActionLabel = createLabel(topLeft, {
		Position = UDim2.new(0, 14, 0, 25),
		Size = UDim2.new(1, -28, 0, 15),
		Text = "",
		TextColor3 = MUTED,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = false,
		ZIndex = 33,
	})

	local repairCallout = createFrame(overlayGui, {
		Size = UDim2.new(1, -(statusLeft + REPAIR_CALLOUT_RIGHT_MARGIN), 0, 44),
		Position = UDim2.new(0, statusLeft, 0, 60),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.22,
		ZIndex = 34,
	})
	repairCallout.Visible = false
	addCorner(repairCallout, 14)
	addStroke(repairCallout, AMBER, 0.28)

	local repairCalloutLabel = createLabel(repairCallout, {
		Position = UDim2.new(0, 16, 0, 0),
		Size = UDim2.new(1, -32, 1, 0),
		Text = "",
		TextColor3 = TEXT,
		TextTransparency = 0,
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 35,
	})

	-- TOP EDGE — repair mode banner
	local repairBanner = createFrame(overlayGui, {
		Size = UDim2.new(0, 260, 0, 42),
		Position = UDim2.new(1, -12, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.08,
		ZIndex = 35,
	})
	repairBanner.Visible = false
	addCorner(repairBanner, 14)
	addStroke(repairBanner, AMBER, 0.18)

	local repairLabel = createLabel(repairBanner, {
		Position = UDim2.new(0, 14, 0, 0),
		Size = UDim2.new(1, -28, 1, 0),
		Text = "REPAIR MODE  |  ATTEMPT 1/7",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = 36,
	})

	local enduranceBadge = createFrame(gui, {
		Position = UDim2.new(0, 20, 0, 6),
		Size = UDim2.new(0, 148, 0, 22),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.1,
	})
	enduranceBadge.Visible = false
	addCorner(enduranceBadge, 10)
	addStroke(enduranceBadge, AMBER, 0.18)

	local enduranceBadgeLabel = createLabel(enduranceBadge, {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0.5, 0, 0.5, -1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = "Endurance Mode",
		TextColor3 = AMBER_SOFT,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	local hotfixBadge = createFrame(gui, {
		Position = UDim2.new(0, 20, 0, 32),
		Size = UDim2.new(0, 148, 0, 22),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.06,
	})
	hotfixBadge.Visible = false
	addCorner(hotfixBadge, 10)
	addStroke(hotfixBadge, DANGER, 0.12)

	local hotfixBadgeLabel = createLabel(hotfixBadge, {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0.5, 0, 0.5, -1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = "Hotfix Mode",
		TextColor3 = DANGER,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	-- FAILURE BANNER — centered overlay
	local failureBanner = createFrame(gui, {
		Size = UDim2.new(0, 520, 0, 104),
		Position = UDim2.new(0.5, 0, 0.5, -44),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.18,
		ZIndex = 30,
	})
	failureBanner.Visible = false
	addCorner(failureBanner, 18)
	addStroke(failureBanner, DANGER, 0.1)

	local failureBannerLabel = createLabel(failureBanner, {
		Size = UDim2.new(1, -32, 1, -20),
		Position = UDim2.new(0, 16, 0, 10),
		Text = "",
		TextColor3 = DANGER,
		TextSize = 32,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
		ZIndex = 31,
	})

	local hotfixBanner = createFrame(overlayGui, {
		Size = UDim2.new(0, 1, 0, 1),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = DANGER,
		BackgroundTransparency = 1,
		ZIndex = 1,
	})
	hotfixBanner.Visible = false

	local hotfixBannerLabel = createLabel(hotfixBanner, {
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		Text = "",
		TextColor3 = DANGER,
		TextSize = 1,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = false,
		ZIndex = 41,
	})

	-- LEFT RAIL — live telemetry + event log
	local logContainer = createFrame(gui, {
		Position = UDim2.new(0, 20, 0, 60),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(0, 148, 0, 112),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.12,
	})
	logContainer.ClipsDescendants = true
	addCorner(logContainer, 18)
	addStroke(logContainer, STEEL_LIGHT, 0.25)

	local logTitle = createLabel(logContainer, {
		Position = UDim2.new(0, 14, 0, 8),
		Size = UDim2.new(0, 90, 0, 18),
		Text = "Live",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local speedLabel = createLabel(logContainer, {
		Position = UDim2.new(0, 14, 0, 36),
		Size = UDim2.new(0, 56, 0, 20),
		Text = "Speed",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local speedValueLabel = createLabel(logContainer, {
		Position = UDim2.new(1, -14, 0, 36),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 62, 0, 20),
		Text = "0.0",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local headingLabel = createLabel(logContainer, {
		Position = UDim2.new(0, 14, 0, 56),
		Size = UDim2.new(0, 56, 0, 20),
		Text = "Heading",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local headingValueLabel = createLabel(logContainer, {
		Position = UDim2.new(1, -14, 0, 56),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 62, 0, 20),
		Text = "N   0°",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local pitchLabel = createLabel(logContainer, {
		Position = UDim2.new(0, 14, 0, 76),
		Size = UDim2.new(0, 56, 0, 20),
		Text = "Pitch",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local pitchValueLabel = createLabel(logContainer, {
		Position = UDim2.new(1, -14, 0, 76),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 62, 0, 20),
		Text = "+0°",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local logOverlay = createFrame(overlayGui, {
		Position = UDim2.new(0, 20, 0, 64),
		Size = UDim2.new(1, -40, 0, 220),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.04,
		ZIndex = 42,
	})
	logOverlay.Visible = false
	addCorner(logOverlay, 18)
	addStroke(logOverlay, STEEL_LIGHT, 0.12)

	local logOverlayTitle = createLabel(logOverlay, {
		Position = UDim2.new(0, 16, 0, 10),
		Size = UDim2.new(0, 120, 0, 18),
		Text = "Event Log",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
		ZIndex = 43,
	})

	local logOverlayHint = createLabel(logOverlay, {
		Position = UDim2.new(1, -54, 0, 10),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 220, 0, 18),
		Text = "Select text to copy",
		TextColor3 = MUTED,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 43,
	})

	local logCloseButton = createButton(logOverlay, {
		Position = UDim2.new(1, -16, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 30, 0, 22),
		Text = "X",
		TextColor3 = AMBER_SOFT,
		TextSize = 11,
		Font = Enum.Font.Code,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
		ZIndex = 43,
	})
	addCorner(logCloseButton, 8)
	addStroke(logCloseButton, AMBER_SOFT, 0.48)

	local logScroll = Instance.new("ScrollingFrame")
	logScroll.Name = "LogScroll"
	logScroll.Position = UDim2.new(0, 12, 0, 36)
	logScroll.Size = UDim2.new(1, -24, 1, -48)
	logScroll.BackgroundColor3 = PANEL_SOFT
	logScroll.BackgroundTransparency = 0.08
	logScroll.BorderSizePixel = 0
	logScroll.ScrollBarThickness = 8
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	logScroll.ZIndex = 43
	logScroll.Parent = logOverlay
	addCorner(logScroll, 12)

	local logTextBox = createTextBox(logScroll, {
		Position = UDim2.new(0, 8, 0, 8),
		Size = UDim2.new(1, -16, 0, 0),
		Text = "",
		TextColor3 = TEXT,
		TextSize = 13,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextEditable = true,
		ClearTextOnFocus = false,
		MultiLine = true,
		TextWrapped = false,
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 44,
	})

	-- RIGHT RAIL — session telemetry + set baseline + overview
	local rightRail = createFrame(gui, {
		Size = UDim2.new(0, RIGHT_RAIL_WIDTH, 0, 152),
		Position = UDim2.new(1, -20, 0, 60),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.12,
	})
	addCorner(rightRail, 18)
	addStroke(rightRail, STEEL_LIGHT, 0.25)

	createLabel(rightRail, {
		Position = UDim2.new(0, 14, 0, 10),
		Size = UDim2.new(0, 90, 0, 18),
		Text = "Session",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
	})

	local baselineLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 14, 0, 34),
		Size = UDim2.new(0, 68, 0, 18),
		Text = "Base --",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
	})

	local lastLapLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 14, 0, 54),
		Size = UDim2.new(1, -28, 0, 18),
		Text = "Last --",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
	})

	local slowdownLabel = createLabel(rightRail, {
		Position = UDim2.new(1, -14, 0, 34),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 56, 0, 18),
		Text = "% --",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local scoreLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 14, 0, 80),
		Size = UDim2.new(1, -28, 0, 56),
		Text = "Track  --\nBudget --",
		TextColor3 = TEXT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local memoryPanel = createFrame(gui, {
		Size = UDim2.new(0, RIGHT_RAIL_WIDTH, 0, 104),
		Position = UDim2.new(1, -20, 0, 220),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.12,
	})
	memoryPanel.Visible = false
	addCorner(memoryPanel, 18)
	addStroke(memoryPanel, STEEL_LIGHT, 0.25)

	createLabel(memoryPanel, {
		Position = UDim2.new(0, 14, 0, 10),
		Size = UDim2.new(0, 120, 0, 18),
		Text = "Memory",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
	})

	local memoryLabel = createLabel(memoryPanel, {
		Position = UDim2.new(0, 14, 0, 32),
		Size = UDim2.new(1, -28, 1, -44),
		Text = "",
		TextColor3 = TEXT,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
	})

	local setBaselineButton = createButton(rightRail, {
		Position = UDim2.new(1, -70, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 24, 0, 24),
		Text = "S",
		TextColor3 = AMBER_SOFT,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
	})
	addCorner(setBaselineButton, 8)
	addStroke(setBaselineButton, AMBER, 0.55)

	local logButton = createButton(rightRail, {
		Position = UDim2.new(1, -42, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 24, 0, 24),
		Text = "L",
		TextColor3 = AMBER_SOFT,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
	})
	addCorner(logButton, 8)
	addStroke(logButton, AMBER_SOFT, 0.48)

	local overviewButton = createButton(rightRail, {
		Position = UDim2.new(1, -14, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 24, 0, 24),
		Text = "O",
		TextColor3 = AMBER_SOFT,
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
	})
	addCorner(overviewButton, 8)
	addStroke(overviewButton, AMBER_SOFT, 0.48)

	-- BOTTOM LEFT — input panel
	local bottomDock = createFrame(gui, {
		Size = UDim2.new(1, -(LLM_DOCK_WIDTH + 216), 0, BOTTOM_DOCK_HEIGHT),
		Position = UDim2.new(0, LEFT_RAIL_MARGIN, 1, -20),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.12,
	})
	addCorner(bottomDock, 20)
	addStroke(bottomDock, STEEL_LIGHT, 0.25)

	createLabel(bottomDock, {
		Position = UDim2.new(0, 20, 0, 10),
		Size = UDim2.new(1, -40, 0, 16),
		Text = "INPUT",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
	})

	local inputBox = createTextBox(bottomDock, {
		Position = UDim2.new(0, 20, 0, 30),
		Size = UDim2.new(1, -128, 0, 34),
		PlaceholderText = "Try: Add a chicane in sector 3",
		TextSize = 16,
	})
	addCorner(inputBox, 10)
	addStroke(inputBox, STEEL_LIGHT, 0.25)

	local submitButton = createButton(bottomDock, {
		Position = UDim2.new(1, -20, 0, 30),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 72, 0, 34),
		Text = "Submit",
		TextColor3 = PANEL,
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		BackgroundColor3 = AMBER,
	})
	addCorner(submitButton, 10)

	-- BOTTOM RIGHT — LLM selector
	local llmWarning = createFrame(overlayGui, {
		Size = UDim2.new(1, -(statusLeft + WARNING_RIGHT_MARGIN), 0, 58),
		Position = UDim2.new(0, statusLeft, 0, 112),
		AnchorPoint = Vector2.new(0, 0),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.06,
		ZIndex = 36,
	})
	llmWarning.Visible = false
	addCorner(llmWarning, 14)
	addStroke(llmWarning, AMBER, 0.18)

	local llmWarningIcon = createFrame(llmWarning, {
		Size = UDim2.new(0, 18, 0, 18),
		Position = UDim2.new(0, 14, 0, 14),
		AnchorPoint = Vector2.new(0, 0),
		BackgroundColor3 = AMBER,
		BackgroundTransparency = 0,
		ZIndex = 37,
	})
	addCorner(llmWarningIcon, 9)

	local llmWarningIconLabel = createLabel(llmWarningIcon, {
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		Text = "!",
		TextColor3 = PANEL,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 38,
	})

	local llmWarningLabel = createLabel(llmWarning, {
		Position = UDim2.new(0, 42, 0, 8),
		Size = UDim2.new(1, -56, 1, -16),
		Text = "",
		TextColor3 = AMBER_SOFT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 37,
	})

	local llmDock = createFrame(gui, {
		Size = UDim2.new(0, LLM_DOCK_WIDTH, 0, BOTTOM_DOCK_HEIGHT),
		Position = UDim2.new(1, -20, 1, -20),
		AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.12,
	})
	addCorner(llmDock, 20)
	addStroke(llmDock, STEEL_LIGHT, 0.25)

	createLabel(llmDock, {
		Position = UDim2.new(0, 20, 0, 10),
		Size = UDim2.new(0, 60, 0, 16),
		Text = "LLM",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
	})

	local llmModelLabel = createLabel(llmDock, {
		Position = UDim2.new(0, 20, 0, 30),
		Size = UDim2.new(1, -104, 0, 34),
		Text = "Model  Heuristic",
		TextColor3 = TEXT,
		TextSize = 13,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local llmPrevButton = createButton(llmDock, {
		Position = UDim2.new(1, -52, 0, 33),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 28, 0, 28),
		Text = "◀",
		TextSize = 14,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
	})
	addCorner(llmPrevButton, 8)

	local llmNextButton = createButton(llmDock, {
		Position = UDim2.new(1, -20, 0, 33),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 28, 0, 28),
		Text = "▶",
		TextSize = 14,
		BackgroundColor3 = STEEL,
		BackgroundTransparency = 0.3,
	})
	addCorner(llmNextButton, 8)

	local function submitCurrentText()
		local text = inputBox.Text
		if text == "" then
			return
		end
		onSubmit(text)
	end

	submitButton.MouseButton1Click:Connect(submitCurrentText)
	inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submitCurrentText()
		end
	end)

	_refs = {
		gui = gui,
		overlayGui = overlayGui,
		llmWarning = llmWarning,
		llmWarningLabel = llmWarningLabel,
		llmDock = llmDock,
		llmModelLabel = llmModelLabel,
		llmPrevButton = llmPrevButton,
		llmNextButton = llmNextButton,
		phaseLabel = phaseLabel,
		requestLabel = requestLabel,
		repairCallout = repairCallout,
		repairCalloutLabel = repairCalloutLabel,
		repairBanner = repairBanner,
		repairLabel = repairLabel,
		enduranceBadge = enduranceBadge,
		enduranceBadgeLabel = enduranceBadgeLabel,
		hotfixBadge = hotfixBadge,
		hotfixBadgeLabel = hotfixBadgeLabel,
		reasoningLabel = reasoningLabel,
		reasoningActionLabel = reasoningActionLabel,
		inputBox = inputBox,
		submitButton = submitButton,
		baselineLabel = baselineLabel,
		lastLapLabel = lastLapLabel,
		slowdownLabel = slowdownLabel,
		scoreLabel = scoreLabel,
		memoryPanel = memoryPanel,
		memoryLabel = memoryLabel,
		speedLabel = speedLabel,
		speedValueLabel = speedValueLabel,
		headingLabel = headingLabel,
		headingValueLabel = headingValueLabel,
		pitchLabel = pitchLabel,
		pitchValueLabel = pitchValueLabel,
		logContainer = logContainer,
		logButton = logButton,
		logOverlay = logOverlay,
		logCloseButton = logCloseButton,
		logScroll = logScroll,
		logTextBox = logTextBox,
		overviewButton = overviewButton,
		setBaselineButton = setBaselineButton,
		topLeftStroke = topLeftStroke,
		failureBanner = failureBanner,
		failureBannerLabel = failureBannerLabel,
		hotfixBanner = hotfixBanner,
		hotfixBannerLabel = hotfixBannerLabel,
		colors = {
			amber = AMBER,
			amberSoft = AMBER_SOFT,
			steel = STEEL,
			steelLight = STEEL_LIGHT,
			danger = DANGER,
			success = SUCCESS,
			text = TEXT,
			muted = MUTED,
		},
		tweenFlash = tweenFlash,
	}

	return _refs
end

function HUDRegistry.get()
	assert(_refs ~= nil, "HUDRegistry not mounted")
	return _refs
end

return HUDRegistry
