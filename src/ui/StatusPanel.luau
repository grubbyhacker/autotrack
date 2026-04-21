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

function StatusPanel.setEndurance(
	active: boolean,
	terminal: boolean,
	lapCount: number,
	used: number,
	total: number,
	hotfixActive: boolean?,
	objectiveText: string?
)
	local hud = refs()
	if terminal then
		hud.enduranceLabel.Text = "ENDURANCE TERMINAL"
		hud.enduranceLabel.TextColor3 = hud.colors.danger
	elseif active then
		hud.enduranceLabel.Text = ("ENDURANCE %d/%d  |  LAP %d"):format(used or 0, total or 0, lapCount or 0)
		if objectiveText ~= nil and objectiveText ~= "" then
			hud.enduranceLabel.Text ..= "  |  " .. objectiveText
		end
		hud.enduranceLabel.TextColor3 = if hotfixActive then hud.colors.danger else hud.colors.amberSoft
	else
		hud.enduranceLabel.Text = ""
	end

	hud.topLeftStroke.Color = if hotfixActive == true or terminal then hud.colors.danger else hud.colors.amber
end

function StatusPanel.setRuntimeIdentity(buildStamp: string, controllerProfile: string)
	local hud = refs()
	if buildStamp == "" and controllerProfile == "" then
		hud.buildLabel.Text = ""
	else
		hud.buildLabel.Text = string.format("%s  |  %s", buildStamp, controllerProfile)
	end
end

function StatusPanel.setExplanation(text: string)
	local hud = refs()
	if text == "" then
		hud.reasoningLabel.Text = "No repair explanation yet"
		hud.reasoningLabel.TextColor3 = hud.colors.muted
	else
		hud.reasoningLabel.Text = text
		hud.reasoningLabel.TextColor3 = hud.colors.text
	end
end

function StatusPanel.setRepairAction(text: string)
	local hud = refs()
	if text == "" then
		hud.reasoningActionLabel.Text = ""
	else
		hud.reasoningActionLabel.Text = "→ " .. text
	end
end

function StatusPanel.setError(text: string, finalStatus: string, hotfixActive: boolean?)
	local hud = refs()
	if text ~= "" then
		hud.errorLabel.Text = text
		hud.errorLabel.TextColor3 = hud.colors.danger
	elseif hotfixActive == true then
		hud.errorLabel.Text = "Hotfix escalation in progress"
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
		hud.failureBanner.BackgroundTransparency = 0.58
		hud.failureBannerLabel.TextTransparency = 0.05
		hud.tweenFlash(hud.failureBanner, { BackgroundTransparency = 0.46 })
		hud.tweenFlash(hud.failureBannerLabel, { TextTransparency = 0.02 })
	end
end

function StatusPanel.setHotfixBanner(text: string, isVisible: boolean)
	local hud = refs()
	hud.hotfixBanner.Visible = isVisible
	hud.hotfixBannerLabel.Text = if isVisible then text else ""
	if isVisible then
		hud.hotfixBanner.BackgroundTransparency = 0.16
		hud.hotfixBannerLabel.TextTransparency = 0
		hud.tweenFlash(hud.hotfixBanner, { BackgroundTransparency = 0.04 })
		hud.tweenFlash(hud.hotfixBannerLabel, { TextTransparency = 0 })
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
	StatusPanel.setRepairAction("")
end

return StatusPanel
