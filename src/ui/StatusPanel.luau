local TweenService = game:GetService("TweenService")

local HUDRegistry = require(script.Parent.HUDRegistry)

local StatusPanel = {}
local _detailState = {
	explanation = "",
	action = "",
}
local _repairCalloutRevision = 0

local function refs()
	return HUDRegistry.get()
end

local function tween(instance: Instance, duration: number, propertyTable)
	local animation = TweenService:Create(
		instance,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		propertyTable
	)
	animation:Play()
	return animation
end

local function renderDetailLine()
	local hud = refs()
	local actionText = _detailState.action or ""
	local explanationText = _detailState.explanation or ""
	local calloutText = if explanationText ~= "" then explanationText else actionText
	local currentlyVisible = hud.repairCallout.Visible == true and hud.repairCalloutLabel.Text ~= ""

	hud.reasoningLabel.Text = ""
	hud.reasoningLabel.Visible = false

	if calloutText == "" and not currentlyVisible then
		return
	end

	if calloutText ~= "" and currentlyVisible and hud.repairCalloutLabel.Text == calloutText then
		return
	end

	_repairCalloutRevision += 1
	local revision = _repairCalloutRevision

	if calloutText == "" then
		hud.repairCallout.Visible = false
		hud.repairCalloutLabel.Text = ""
		return
	end

	local updated = hud.repairCallout.Visible == true and hud.repairCalloutLabel.Text ~= ""
	hud.repairCallout.Visible = true
	hud.repairCallout.BackgroundTransparency = 0.22
	hud.repairCalloutLabel.TextTransparency = 0
	hud.repairCalloutLabel.Text = calloutText
	tween(hud.repairCallout, 0.16, { BackgroundTransparency = 0.1 })
	tween(hud.repairCalloutLabel, 0.16, { TextTransparency = 0 })

	task.delay(if updated then 4.0 else 10.0, function()
		if revision ~= _repairCalloutRevision then
			return
		end
		local fadeDuration = if updated then 0.45 else 1.15
		tween(hud.repairCallout, fadeDuration, { BackgroundTransparency = 1 })
		tween(hud.repairCalloutLabel, fadeDuration, { TextTransparency = 1 })
		task.delay(fadeDuration, function()
			if revision ~= _repairCalloutRevision then
				return
			end
			hud.repairCallout.Visible = false
			hud.repairCalloutLabel.Text = ""
		end)
	end)
end

function StatusPanel.mount(playerGui: PlayerGui, onSubmit: (string) -> ())
	return HUDRegistry.mount(playerGui, onSubmit)
end

function StatusPanel.setPhase(phase: string)
	local hud = refs()
	hud.phaseLabel.Text = phase
	hud.tweenFlash(hud.phaseLabel, { TextTransparency = 0 })
end

function StatusPanel.setRequestSummary(summary: string, rawText: string)
	local hud = refs()
	if summary ~= "" then
		hud.requestLabel.Text = summary
	else
		hud.requestLabel.Text = rawText or ""
	end
end

function StatusPanel.setAttempt(current: number, max: number)
	local hud = refs()
	local showRepair = current ~= nil and max ~= nil and current > 0 and max > 0
	hud.repairBanner.Visible = showRepair
	if showRepair then
		hud.repairLabel.Text = ("REPAIR MODE  |  ATTEMPT %d/%d"):format(current, max)
		hud.tweenFlash(hud.repairLabel, { TextTransparency = 0 })
	end
end

function StatusPanel.setEndurance(
	active: boolean,
	terminal: boolean,
	_lapCount: number,
	_used: number,
	_total: number,
	hotfixActive: boolean?,
	_objectiveText: string?
)
	local hud = refs()
	hud.enduranceBadge.Visible = active == true
	hud.topLeftStroke.Color = if hotfixActive == true or terminal then hud.colors.danger else hud.colors.amber
end

function StatusPanel.setMemorySummary(active: boolean, summaryText: string)
	local hud = refs()
	hud.memoryPanel.Visible = active == true and summaryText ~= ""
	hud.memoryLabel.Text = if active == true then summaryText else ""
end

function StatusPanel.setRuntimeIdentity(_buildStamp: string, _controllerProfile: string)
	return
end

function StatusPanel.setExplanation(text: string)
	if _detailState.explanation == (text or "") then
		return
	end
	_detailState.explanation = text or ""
	renderDetailLine()
end

function StatusPanel.setRepairAction(text: string)
	local nextAction = if text ~= "" then "→ " .. text else ""
	if _detailState.action == nextAction then
		return
	end
	_detailState.action = nextAction
	renderDetailLine()
end

function StatusPanel.setError(text: string, _finalStatus: string, _hotfixActive: boolean?, warningText: string?)
	local hud = refs()
	local isLLMError = text ~= "" and string.find(text, "LLM error:", 1, true) == 1
	local warning = warningText or ""

	hud.llmWarning.Visible = isLLMError or warning ~= ""
	if isLLMError or warning ~= "" then
		local displayText = warning
		if displayText == "" then
			displayText = string.gsub(text, "^LLM error:%s*", "")
			if displayText == "" then
				displayText = text
			end
		end
		hud.llmWarningLabel.Text = displayText
		hud.tweenFlash(hud.llmWarning, { BackgroundTransparency = 0.02 })
	else
		hud.llmWarningLabel.Text = ""
	end
end

function StatusPanel.setBusy(isBusy: boolean)
	local hud = refs()
	hud.submitButton.Active = not isBusy
	hud.submitButton.AutoButtonColor = not isBusy
	hud.submitButton.Text = if isBusy then "Running" else "Submit"
	hud.submitButton.BackgroundColor3 = if isBusy then hud.colors.steelLight else hud.colors.amber
	hud.submitButton.TextColor3 = if isBusy then hud.colors.text else Color3.fromRGB(18, 21, 25)
	hud.inputBox.TextEditable = not isBusy
end

function StatusPanel.setFailureBanner(text: string, isVisible: boolean)
	local hud = refs()
	hud.failureBanner.Visible = isVisible
	hud.failureBannerLabel.Text = if isVisible then text else ""
	if isVisible then
		hud.failureBanner.BackgroundTransparency = 0.58
		hud.failureBannerLabel.TextTransparency = 0.05
		hud.tweenFlash(hud.failureBanner, { BackgroundTransparency = 0.46 })
		hud.tweenFlash(hud.failureBannerLabel, { TextTransparency = 0.02 })
	end
end

function StatusPanel.setHotfixBanner(_text: string, isVisible: boolean)
	local hud = refs()
	hud.hotfixBadge.Visible = isVisible
	hud.hotfixBanner.Visible = false
	hud.hotfixBannerLabel.Text = ""
	if isVisible then
		hud.hotfixBadge.BackgroundTransparency = 0.06
		hud.hotfixBadgeLabel.TextTransparency = 0
		hud.tweenFlash(hud.hotfixBadge, { BackgroundTransparency = 0.02 })
		hud.tweenFlash(hud.hotfixBadgeLabel, { TextTransparency = 0 })
	end
end

function StatusPanel.setLogLines(lines: { string })
	local hud = refs()
	local lastIndex = 0
	for index, line in ipairs(lines) do
		if line ~= nil and line ~= "" then
			lastIndex = index
		end
	end

	local visibleLines = {}
	for index = 1, lastIndex do
		table.insert(visibleLines, lines[index] or "")
	end

	hud.logTextBox.Text = table.concat(visibleLines, "\n")
	local overflowY = math.max(0, hud.logTextBox.TextBounds.Y - hud.logScroll.AbsoluteWindowSize.Y)
	hud.logScroll.CanvasPosition = Vector2.new(0, overflowY)
end

function StatusPanel.clearExplanation()
	StatusPanel.setExplanation("")
	StatusPanel.setRepairAction("")
end

return StatusPanel
