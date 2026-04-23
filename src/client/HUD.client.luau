local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AutoTrackUI = ReplicatedStorage:WaitForChild("AutoTrackUI")
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local StatusPanel = require(AutoTrackUI:WaitForChild("StatusPanel"))
local StatsPanel = require(AutoTrackUI:WaitForChild("StatsPanel"))

local RUNTIME_BOOT_TIMEOUT = 30

local stateFolder = ReplicatedStorage:WaitForChild("AutoTrackUIState", RUNTIME_BOOT_TIMEOUT)
assert(stateFolder ~= nil and stateFolder:IsA("Folder"), "HUD: AutoTrackUIState missing after boot timeout")

local submitEvent = ReplicatedStorage:WaitForChild("AutoTrack_SubmitRequest", RUNTIME_BOOT_TIMEOUT)
assert(submitEvent ~= nil and submitEvent:IsA("RemoteEvent"), "HUD: AutoTrack_SubmitRequest missing after boot timeout")
local setLLMConfigEvent = ReplicatedStorage:FindFirstChild("AutoTrack_SetLLMConfig")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

StatusPanel.mount(playerGui, function(text: string)
	submitEvent:FireServer(text)
end)

local hud = require(AutoTrackUI:WaitForChild("HUDRegistry")).get()
local setBaselineEvent = ReplicatedStorage:FindFirstChild("AutoTrack_SetBaseline")
local baselineClickConnection = nil
local llmControlsReady = setLLMConfigEvent ~= nil
local renderLLMControls

local function percentString(value: number): string
	return ("%d%%"):format(math.floor((value or 0) * 100 + 0.5))
end

local function sectorAttr(sectorId: number, suffix: string): string
	return string.format("sector_%d_%s", sectorId, suffix)
end

local function compactLine(prefix: string, text: string): string
	if text == nil or text == "" then
		return prefix .. " -"
	end
	return prefix .. " " .. text
end

local function resolveSectorScoreLabel(sectorId: number): TextLabel?
	local track = Workspace:FindFirstChild("Track")
	if not (track and track:IsA("Folder")) then
		return nil
	end
	local sectorFolder = track:FindFirstChild(string.format("Sector_%02d", sectorId))
	if not (sectorFolder and sectorFolder:IsA("Folder")) then
		return nil
	end
	local anchor = sectorFolder:FindFirstChild("Anchor")
	if not (anchor and anchor:IsA("BasePart")) then
		return nil
	end
	local billboard = anchor:FindFirstChild("SectorLabel")
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end
	local scoreLabel = billboard:FindFirstChild("SectorScoreLabel", true)
	if scoreLabel and scoreLabel:IsA("TextLabel") then
		return scoreLabel
	end
	return nil
end

local function renderSectorScoreAnnotations()
	local overviewActive = stateFolder:GetAttribute("overview_mode") == true
	for sectorId = 1, 10 do
		local scoreLabel = resolveSectorScoreLabel(sectorId)
		if scoreLabel ~= nil then
			local committedScore = stateFolder:GetAttribute(sectorAttr(sectorId, "committed_score"))
			local showScore = overviewActive and type(committedScore) == "number" and committedScore >= 0
			scoreLabel.Visible = showScore
			scoreLabel.Text = if showScore then string.format("%.1f", committedScore) else ""
		end
	end
end

local function buildMemorySummary(): string
	local sharedDepth = stateFolder:GetAttribute("shared_memory_depth") or 0
	local proposalDepth = stateFolder:GetAttribute("proposal_memory_depth") or 0
	local repairDepth = stateFolder:GetAttribute("repair_memory_depth") or 0
	local shared1 = stateFolder:GetAttribute("shared_memory_1") or ""
	local shared2 = stateFolder:GetAttribute("shared_memory_2") or ""
	local proposal1 = stateFolder:GetAttribute("proposal_memory_1") or ""
	local repair1 = stateFolder:GetAttribute("repair_memory_1") or ""

	if sharedDepth == 0 and proposalDepth == 0 and repairDepth == 0 then
		return ""
	end

	local lines = {
		string.format("S%d P%d R%d", sharedDepth, proposalDepth, repairDepth),
		compactLine("Shared", shared1),
	}
	if shared2 ~= "" then
		table.insert(lines, compactLine("Shared", shared2))
	end
	table.insert(lines, compactLine("Prop", proposal1))
	table.insert(lines, compactLine("Fix", repair1))
	return table.concat(lines, "\n")
end

local function bindBaselineButton(remoteEvent)
	if baselineClickConnection then
		baselineClickConnection:Disconnect()
		baselineClickConnection = nil
	end

	if remoteEvent and remoteEvent:IsA("RemoteEvent") then
		hud.setBaselineButton.Active = true
		hud.setBaselineButton.AutoButtonColor = true
		hud.setBaselineButton.TextTransparency = 0
		baselineClickConnection = hud.setBaselineButton.MouseButton1Click:Connect(function()
			remoteEvent:FireServer()
		end)
	else
		hud.setBaselineButton.Active = false
		hud.setBaselineButton.AutoButtonColor = false
		hud.setBaselineButton.TextTransparency = 0.35
	end
end

bindBaselineButton(setBaselineEvent)
if setBaselineEvent == nil then
	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == "AutoTrack_SetBaseline" and child:IsA("RemoteEvent") then
			setBaselineEvent = child
			bindBaselineButton(setBaselineEvent)
		elseif child.Name == "AutoTrack_SetLLMConfig" and child:IsA("RemoteEvent") then
			setLLMConfigEvent = child
			llmControlsReady = true
			renderLLMControls()
		end
	end)
end

-- LLM controls
local AMBER_COLOR = Color3.fromRGB(255, 191, 94)
local AMBER_SOFT_COLOR = Color3.fromRGB(255, 219, 158)
local STEEL_COLOR = Color3.fromRGB(35, 40, 46)
local MUTED_COLOR = Color3.fromRGB(168, 163, 154)
local TEXT_COLOR = Color3.fromRGB(234, 231, 225)

function renderLLMControls()
	local enabled = stateFolder:GetAttribute("llm_enabled") == true
	local storedModelId = stateFolder:GetAttribute("llm_model") or "heuristic"
	local modelId = if enabled then storedModelId else "heuristic"

	-- Find display name for the current model
	local displayName = "Heuristic"
	for _, m in ipairs(LLMConfig.MODELS) do
		if m.id == modelId then
			displayName = m.displayName
			break
		end
	end

	hud.llmPrevButton.Active = llmControlsReady
	hud.llmPrevButton.AutoButtonColor = llmControlsReady
	hud.llmNextButton.Active = llmControlsReady
	hud.llmNextButton.AutoButtonColor = llmControlsReady
	hud.llmModelLabel.Text = "Model  " .. displayName
	hud.llmModelLabel.TextColor3 = if llmControlsReady then TEXT_COLOR else MUTED_COLOR
end

hud.llmPrevButton.MouseButton1Click:Connect(function()
	if not setLLMConfigEvent then
		return
	end
	local currentEnabled = stateFolder:GetAttribute("llm_enabled") == true
	local currentModel = if currentEnabled then (stateFolder:GetAttribute("llm_model") or "heuristic") else "heuristic"
	local idx = 1
	for i, m in ipairs(LLMConfig.MODELS) do
		if m.id == currentModel then idx = i; break end
	end
	local count = #LLMConfig.MODELS
	local newIdx = ((idx - 2) % count) + 1
	local newModel = LLMConfig.MODELS[newIdx].id
	setLLMConfigEvent:FireServer({ enabled = newModel ~= "heuristic", model = newModel })
end)

hud.llmNextButton.MouseButton1Click:Connect(function()
	if not setLLMConfigEvent then
		return
	end
	local currentEnabled = stateFolder:GetAttribute("llm_enabled") == true
	local currentModel = if currentEnabled then (stateFolder:GetAttribute("llm_model") or "heuristic") else "heuristic"
	local idx = 1
	for i, m in ipairs(LLMConfig.MODELS) do
		if m.id == currentModel then idx = i; break end
	end
	local count = #LLMConfig.MODELS
	local newIdx = (idx % count) + 1
	local newModel = LLMConfig.MODELS[newIdx].id
	setLLMConfigEvent:FireServer({ enabled = newModel ~= "heuristic", model = newModel })
end)

-- Overview button — writes overview_mode attribute; TrackCamera reads it
local _overviewActive = false
local _logOpen = false

local function renderLogToggle()
	hud.logOverlay.Visible = _logOpen
	hud.logButton.BackgroundColor3 = if _logOpen then AMBER_COLOR else STEEL_COLOR
	hud.logButton.TextColor3 = if _logOpen then Color3.fromRGB(18, 21, 25) else AMBER_SOFT_COLOR
end

local function syncHotfixPresentation()
	local hotfixActive = stateFolder:GetAttribute("endurance_hotfix_active") == true
	local hotfixSector = stateFolder:GetAttribute("endurance_hotfix_sector") or 0
	StatusPanel.setHotfixBanner(
		if hotfixActive then string.format("HOTFIX MODE  |  SECTOR %d  |  LIVE TRACK ESCALATION", hotfixSector) else "",
		hotfixActive
	)
end

hud.overviewButton.MouseButton1Click:Connect(function()
	_overviewActive = not _overviewActive
	stateFolder:SetAttribute("overview_mode", _overviewActive)
	hud.overviewButton.Text = "O"
end)

hud.logButton.MouseButton1Click:Connect(function()
	_logOpen = not _logOpen
	renderLogToggle()
end)

hud.logCloseButton.MouseButton1Click:Connect(function()
	_logOpen = false
	renderLogToggle()
end)

local function render()
	local hotfixActive = stateFolder:GetAttribute("endurance_hotfix_active") == true
	local attemptCurrent = stateFolder:GetAttribute("attempt_current") or 0

	StatusPanel.setPhase(stateFolder:GetAttribute("phase_label") or "Ready for request")
	StatusPanel.setRequestSummary(
		(stateFolder:GetAttribute("endurance_mode_active") == true and (stateFolder:GetAttribute("orchestrator_last_decision") or "") ~= "")
				and (stateFolder:GetAttribute("orchestrator_last_decision") or "")
			or (stateFolder:GetAttribute("request_summary") or ""),
		(stateFolder:GetAttribute("endurance_mode_active") == true and (stateFolder:GetAttribute("request_summary") or "") ~= "")
				and (stateFolder:GetAttribute("request_summary") or "")
			or (stateFolder:GetAttribute("request_text") or "")
	)
	StatusPanel.setAttempt(
		stateFolder:GetAttribute("attempt_current") or 0,
		stateFolder:GetAttribute("attempt_max") or 0
	)
	StatusPanel.setEndurance(
		stateFolder:GetAttribute("endurance_mode_active") == true,
		stateFolder:GetAttribute("endurance_terminal") == true,
		stateFolder:GetAttribute("endurance_lap_count") or 0,
		stateFolder:GetAttribute("endurance_attempt_budget_used") or 0,
		stateFolder:GetAttribute("endurance_attempt_budget_total") or 0,
		hotfixActive,
		(stateFolder:GetAttribute("endurance_mode_active") == true)
				and string.format(
					"OBJ %.2f  |  HDR %s",
					stateFolder:GetAttribute("orchestrator_objective_total") or 0,
					percentString(stateFolder:GetAttribute("orchestrator_budget_headroom") or 0)
				)
			or nil
	)
	StatusPanel.setMemorySummary(
		stateFolder:GetAttribute("endurance_mode_active") == true,
		buildMemorySummary()
	)
	StatusPanel.setRuntimeIdentity(
		stateFolder:GetAttribute("build_stamp") or "",
		stateFolder:GetAttribute("controller_profile") or ""
	)
	StatusPanel.setExplanation(
		(if attemptCurrent > 0 then (stateFolder:GetAttribute("explanation") or "") else "")
	)
	StatusPanel.setRepairAction(
		(if attemptCurrent > 0 then (stateFolder:GetAttribute("repair_action_text") or "") else "")
	)
	StatusPanel.setError(
		stateFolder:GetAttribute("error_text") or "",
		stateFolder:GetAttribute("final_status") or "",
		hotfixActive,
		stateFolder:GetAttribute("llm_warning_text") or ""
	)
	StatusPanel.setFailureBanner(
		stateFolder:GetAttribute("failure_banner_text") or "",
		stateFolder:GetAttribute("failure_banner_visible") == true
	)
	syncHotfixPresentation()
	StatusPanel.setBusy(stateFolder:GetAttribute("busy") == true)
	local logLines = {
		stateFolder:GetAttribute("log_1") or "",
		stateFolder:GetAttribute("log_2") or "",
		stateFolder:GetAttribute("log_3") or "",
		stateFolder:GetAttribute("log_4") or "",
		stateFolder:GetAttribute("log_5") or "",
		stateFolder:GetAttribute("log_6") or "",
		stateFolder:GetAttribute("log_7") or "",
		stateFolder:GetAttribute("log_8") or "",
	}
	if stateFolder:GetAttribute("endurance_mode_active") == true then
		local ledger3 = stateFolder:GetAttribute("orchestrator_ledger_3") or ""
		local ledger2 = stateFolder:GetAttribute("orchestrator_ledger_2") or ""
		local ledger1 = stateFolder:GetAttribute("orchestrator_ledger_1") or ""
		if ledger3 ~= "" then
			logLines[6] = ledger3
		end
		if ledger2 ~= "" then
			logLines[7] = ledger2
		end
		if ledger1 ~= "" then
			logLines[8] = ledger1
		end
	end
	StatusPanel.setLogLines(logLines)

	local baselineLapTime = stateFolder:GetAttribute("baseline_lap_time") or -1
	local committedLapTime = stateFolder:GetAttribute("committed_lap_time") or -1
	local committedSlowdown = nil
	if committedLapTime > 0 and baselineLapTime > 0 then
		committedSlowdown = committedLapTime / baselineLapTime
	elseif stateFolder:GetAttribute("committed_slowdown_ratio") ~= nil then
		committedSlowdown = stateFolder:GetAttribute("committed_slowdown_ratio")
	end
	if committedLapTime <= 0 then
		committedSlowdown = nil
	end

	StatsPanel.setBaseline(baselineLapTime)
	StatsPanel.setLastLapTime(committedLapTime)
	StatsPanel.setSlowdown(committedSlowdown)
	StatsPanel.setCurrentSpeed(
		stateFolder:GetAttribute("current_speed") or 0,
		stateFolder:GetAttribute("current_commanded_speed") or 0,
		stateFolder:GetAttribute("current_target_speed") or 0
	)
	StatsPanel.setHeading(stateFolder:GetAttribute("current_heading_deg") or 0)
	StatsPanel.setPitch(stateFolder:GetAttribute("current_pitch_deg") or 0)
	renderLLMControls()

	StatsPanel.setScore(
		stateFolder:GetAttribute("last_score_sector") or 0,
		stateFolder:GetAttribute("last_score_total") or 0,
		stateFolder:GetAttribute("last_score_air") or 0,
		stateFolder:GetAttribute("last_score_lateral") or 0,
		stateFolder:GetAttribute("last_score_near_miss") or 0,
		stateFolder:GetAttribute("last_score_time_cost") or 0,
		stateFolder:GetAttribute("last_score_over_budget") == true,
		stateFolder:GetAttribute("track_score_total") or 0,
		stateFolder:GetAttribute("track_score_count") or 0,
		stateFolder:GetAttribute("track_budget_used") or 0,
		stateFolder:GetAttribute("track_budget_headroom") or 1,
		stateFolder:GetAttribute("track_over_budget") == true
	)
	renderSectorScoreAnnotations()
end

local observedAttributes = {
	"phase_label",
	"request_summary",
	"request_text",
	"attempt_current",
	"attempt_max",
	"explanation",
	"repair_action_text",
	"error_text",
	"llm_warning_text",
	"busy",
	"baseline_lap_time",
	"last_lap_time",
	"committed_lap_time",
	"committed_slowdown_ratio",
	"slowdown_ratio",
	"overview_mode",
	"current_speed",
	"current_target_speed",
	"current_commanded_speed",
	"current_heading_deg",
	"current_pitch_deg",
	"current_sector_kind",
	"final_status",
	"failure_banner_text",
	"failure_banner_visible",
	"log_1",
	"log_2",
	"log_3",
	"log_4",
	"log_5",
	"log_6",
	"log_7",
	"log_8",
	"last_score_sector",
	"last_score_total",
	"last_score_air",
	"last_score_lateral",
	"last_score_near_miss",
	"last_score_time_cost",
	"last_score_over_budget",
	"track_score_total",
	"track_score_count",
	"track_budget_used",
	"track_budget_headroom",
	"track_over_budget",
	"llm_enabled",
	"llm_model",
	"endurance_mode_active",
	"endurance_hotfix_active",
	"endurance_hotfix_sector",
	"endurance_terminal",
	"endurance_lap_count",
	"endurance_attempt_budget_used",
	"endurance_attempt_budget_total",
	"build_stamp",
	"controller_profile",
	"orchestrator_objective_total",
	"orchestrator_budget_target",
	"orchestrator_budget_headroom",
	"orchestrator_decision_index",
	"orchestrator_last_decision",
	"orchestrator_last_rationale",
	"orchestrator_memory_depth",
	"orchestrator_repeat_penalties",
	"orchestrator_failure_signature",
	"orchestrator_reliability_index",
	"orchestrator_track_intent",
	"shared_memory_depth",
	"proposal_memory_depth",
	"repair_memory_depth",
	"shared_memory_1",
	"shared_memory_2",
	"proposal_memory_1",
	"repair_memory_1",
	"orchestrator_ledger_1",
	"orchestrator_ledger_2",
	"orchestrator_ledger_3",
}

for _, attributeName in ipairs(observedAttributes) do
	stateFolder:GetAttributeChangedSignal(attributeName):Connect(render)
end

for sectorId = 1, 10 do
	stateFolder:GetAttributeChangedSignal(sectorAttr(sectorId, "committed_score")):Connect(render)
end

stateFolder:GetAttributeChangedSignal("endurance_hotfix_active"):Connect(syncHotfixPresentation)
stateFolder:GetAttributeChangedSignal("endurance_hotfix_sector"):Connect(syncHotfixPresentation)

task.spawn(function()
	while true do
		task.wait(0.2)
		syncHotfixPresentation()
	end
end)

render()
renderLogToggle()
