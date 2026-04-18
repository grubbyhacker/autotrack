local HUDRegistry = require(script.Parent.HUDRegistry)

local StatusPanel = {}

local function refs()
	return HUDRegistry.get()
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
		hud.requestLabel.Text = ("%s  |  %s"):format(summary, rawText)
	else
		hud.requestLabel.Text = if rawText ~= "" then rawText else "Awaiting command"
	end
end

function StatusPanel.setAttempt(current: number, max: number)
	local hud = refs()
	hud.attemptLabel.Text = ("ATTEMPT %d/%d"):format(current, max)
end

function StatusPanel.setExplanation(text: string)
	local hud = refs()
	if text == "" then
		hud.explanationLabel.Text = "No repair explanation yet"
		hud.explanationLabel.TextColor3 = hud.colors.muted
	else
		hud.explanationLabel.Text = text
		hud.explanationLabel.TextColor3 = hud.colors.text
	end
end

function StatusPanel.setRepairAction(text: string)
	local hud = refs()
	if text == "" then
		hud.actionLabel.Text = ""
	else
		hud.actionLabel.Text = "REPAIR ACTION  " .. text
	end
end

function StatusPanel.setError(text: string, finalStatus: string)
	local hud = refs()
	if text ~= "" then
		hud.errorLabel.Text = text
		hud.errorLabel.TextColor3 = hud.colors.danger
	elseif finalStatus == "committed" then
		hud.errorLabel.Text = "Commit locked in"
		hud.errorLabel.TextColor3 = hud.colors.success
	elseif finalStatus == "reverted" then
		hud.errorLabel.Text = "Sector reverted"
		hud.errorLabel.TextColor3 = hud.colors.danger
	else
		hud.errorLabel.Text = ""
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
		hud.failureBanner.BackgroundTransparency = 0.18
		hud.failureBannerLabel.TextTransparency = 0
		hud.tweenFlash(hud.failureBanner, { BackgroundTransparency = 0.08 })
		hud.tweenFlash(hud.failureBannerLabel, { TextTransparency = 0 })
	end
end

function StatusPanel.setLogLines(lines: { string })
	local hud = refs()
	for index, label in ipairs(hud.logLabels) do
		label.Text = lines[index] or ""
	end
end

function StatusPanel.clearExplanation()
	StatusPanel.setExplanation("")
end

return StatusPanel
