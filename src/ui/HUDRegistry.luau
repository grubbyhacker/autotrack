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
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.Parent = parent
	if props.ZIndex then
		box.ZIndex = props.ZIndex
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

	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoTrackHUD"
	gui.IgnoreGuiInset = false
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	local topStrip = createFrame(gui, {
		Size = UDim2.new(1, -40, 0, 74),
		Position = UDim2.new(0, 20, 0, 12),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.08,
	})
	addCorner(topStrip, 16)
	addStroke(topStrip, AMBER, 0.6)

	local phaseLabel = createLabel(topStrip, {
		Position = UDim2.new(0, 22, 0, 12),
		Size = UDim2.new(0.55, 0, 0, 26),
		Text = "Ready for request",
		TextColor3 = TEXT,
		TextSize = 24,
		Font = Enum.Font.GothamBold,
	})

	local requestLabel = createLabel(topStrip, {
		Position = UDim2.new(0, 22, 0, 42),
		Size = UDim2.new(1, -236, 0, 18),
		Text = "Awaiting command",
		TextColor3 = MUTED,
		TextSize = 14,
		Font = Enum.Font.Code,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local attemptLabel = createLabel(topStrip, {
		Position = UDim2.new(1, -178, 0, 14),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(0, 156, 0, 18),
		Text = "ATTEMPT 0/5",
		TextColor3 = AMBER_SOFT,
		TextSize = 14,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local errorLabel = createLabel(topStrip, {
		Position = UDim2.new(1, -178, 0, 38),
		Size = UDim2.new(0, 156, 0, 22),
		Text = "",
		TextColor3 = DANGER,
		TextSize = 14,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local rightRail = createFrame(gui, {
		Size = UDim2.new(0, 188, 0, 290),
		Position = UDim2.new(1, -20, 0, 110),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.05,
	})
	addCorner(rightRail, 18)
	addStroke(rightRail, STEEL_LIGHT, 0.35)

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
	addStroke(failureBanner, DANGER, 0.15)

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

	local railTitle = createLabel(rightRail, {
		Position = UDim2.new(0, 20, 0, 14),
		Size = UDim2.new(1, -40, 0, 22),
		Text = "SESSION TELEMETRY",
		TextColor3 = AMBER_SOFT,
		TextSize = 14,
		Font = Enum.Font.Code,
	})

	local baselineLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 20, 0, 54),
		Size = UDim2.new(1, -40, 0, 46),
		Text = "Baseline\n--",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamMedium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local lastLapLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 20, 0, 110),
		Size = UDim2.new(1, -40, 0, 46),
		Text = "Last Lap\n--",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamMedium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local slowdownLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 20, 0, 166),
		Size = UDim2.new(1, -40, 0, 46),
		Text = "Slowdown\n+0%",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamMedium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local scoreLabel = createLabel(rightRail, {
		Position = UDim2.new(0, 20, 0, 222),
		Size = UDim2.new(1, -40, 0, 46),
		Text = "Score\n--",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamMedium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local logContainer = createFrame(gui, {
		Position = UDim2.new(0, 20, 0, 110),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(0, 188, 0, 252),
		BackgroundColor3 = PANEL_SOFT,
		BackgroundTransparency = 0.05,
	})
	logContainer.ClipsDescendants = true
	addCorner(logContainer, 18)
	addStroke(logContainer, STEEL_LIGHT, 0.35)

	local logTitle = createLabel(logContainer, {
		Position = UDim2.new(0, 20, 0, 14),
		Size = UDim2.new(1, -40, 0, 22),
		Text = "LIVE TELEMETRY",
		TextColor3 = AMBER_SOFT,
		TextSize = 14,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local currentSpeedLabel = createLabel(logContainer, {
		Position = UDim2.new(0, 20, 0, 54),
		Size = UDim2.new(1, -40, 0, 42),
		Text = "Current Speed\n0.0",
		TextColor3 = TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local recentLoopLabel = createLabel(logContainer, {
		Position = UDim2.new(0, 20, 0, 108),
		Size = UDim2.new(1, -40, 0, 18),
		Text = "RECENT LOOP",
		TextColor3 = AMBER_SOFT,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local logLabels = {}
	for index = 1, 4 do
		logLabels[index] = createLabel(logContainer, {
			Position = UDim2.new(0, 20, 0, 118 + index * 28),
			Size = UDim2.new(1, -40, 0, 24),
			Text = "",
			TextColor3 = MUTED,
			TextSize = 12,
			Font = Enum.Font.Code,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ClipsDescendants = true,
		})
	end

	local bottomDock = createFrame(gui, {
		Size = UDim2.new(1, -40, 0, 132),
		Position = UDim2.new(0, 20, 1, -20),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.06,
	})
	addCorner(bottomDock, 20)
	addStroke(bottomDock, STEEL_LIGHT, 0.3)

	local promptLabel = createLabel(bottomDock, {
		Position = UDim2.new(0, 20, 0, 14),
		Size = UDim2.new(1, -170, 0, 20),
		Text = "COMMAND INPUT",
		TextColor3 = AMBER_SOFT,
		TextSize = 14,
		Font = Enum.Font.Code,
	})

	local explanationLabel = createLabel(bottomDock, {
		Position = UDim2.new(0, 20, 0, 32),
		Size = UDim2.new(1, -40, 0, 18),
		Text = "No repair explanation yet",
		TextColor3 = MUTED,
		TextSize = 14,
		Font = Enum.Font.GothamMedium,
	})

	local actionLabel = createLabel(bottomDock, {
		Position = UDim2.new(0, 20, 0, 50),
		Size = UDim2.new(1, -40, 0, 18),
		Text = "",
		TextColor3 = AMBER_SOFT,
		TextSize = 13,
		Font = Enum.Font.Code,
	})

	local inputBox = createTextBox(bottomDock, {
		Position = UDim2.new(0, 20, 0, 74),
		Size = UDim2.new(1, -170, 0, 38),
		PlaceholderText = "Try: Add a chicane in sector 3",
		TextSize = 17,
	})
	addCorner(inputBox, 12)
	addStroke(inputBox, STEEL_LIGHT, 0.25)

	local submitButton = createButton(bottomDock, {
		Position = UDim2.new(1, -20, 0, 74),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.new(0, 120, 0, 38),
		Text = "Submit",
		TextColor3 = PANEL,
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		BackgroundColor3 = AMBER,
	})
	addCorner(submitButton, 12)

	local examplesLabel = createLabel(bottomDock, {
		Position = UDim2.new(0, 20, 0, 102),
		Size = UDim2.new(1, -170, 0, 20),
		Text = "Examples: Add a jump in sector 4   |   Add a wide chicane in sector 3",
		TextColor3 = MUTED,
		TextSize = 12,
		Font = Enum.Font.Code,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

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
		phaseLabel = phaseLabel,
		requestLabel = requestLabel,
		attemptLabel = attemptLabel,
		errorLabel = errorLabel,
		explanationLabel = explanationLabel,
		actionLabel = actionLabel,
		inputBox = inputBox,
		submitButton = submitButton,
		baselineLabel = baselineLabel,
		lastLapLabel = lastLapLabel,
		slowdownLabel = slowdownLabel,
		scoreLabel = scoreLabel,
		currentSpeedLabel = currentSpeedLabel,
		recentLoopLabel = recentLoopLabel,
		logContainer = logContainer,
		logLabels = logLabels,
		failureBanner = failureBanner,
		failureBannerLabel = failureBannerLabel,
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
