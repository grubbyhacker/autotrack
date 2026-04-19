local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AutoTrackUI = ReplicatedStorage:WaitForChild("AutoTrackUI")
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local StatusPanel = require(AutoTrackUI:WaitForChild("StatusPanel"))
local StatsPanel = require(AutoTrackUI:WaitForChild("StatsPanel"))

local stateFolder = ReplicatedStorage:WaitForChild("AutoTrackUIState")
local submitEvent = ReplicatedStorage:WaitForChild("AutoTrack_SubmitRequest")
local setBaselineEvent = ReplicatedStorage:WaitForChild("AutoTrack_SetBaseline")
local setLLMConfigEvent = ReplicatedStorage:WaitForChild("AutoTrack_SetLLMConfig")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

StatusPanel.mount(playerGui, function(text: string)
	submitEvent:FireServer(text)
end)

local hud = require(AutoTrackUI:WaitForChild("HUDRegistry")).get()

hud.setBaselineButton.Active = true
hud.setBaselineButton.AutoButtonColor = true

hud.setBaselineButton.MouseButton1Click:Connect(function()
	setBaselineEvent:FireServer()
end)

-- LLM controls
local AMBER_COLOR = Color3.fromRGB(255, 191, 94)
local AMBER_SOFT_COLOR = Color3.fromRGB(255, 219, 158)
local STEEL_COLOR = Color3.fromRGB(35, 40, 46)
local MUTED_COLOR = Color3.fromRGB(168, 163, 154)
local TEXT_COLOR = Color3.fromRGB(234, 231, 225)

local function renderLLMControls()
	local enabled = stateFolder:GetAttribute("llm_enabled") == true
	local modelId = stateFolder:GetAttribute("llm_model") or "heuristic"

	-- Find display name for the current model
	local displayName = "Heuristic"
	for _, m in ipairs(LLMConfig.MODELS) do
		if m.id == modelId then
			displayName = m.displayName
			break
		end
	end

	hud.llmToggleButton.Text = if enabled then "LLM ON" else "LLM OFF"
	hud.llmToggleButton.TextColor3 = if enabled then AMBER_SOFT_COLOR else MUTED_COLOR
	hud.llmToggleButton.BackgroundColor3 = if enabled then AMBER_COLOR else STEEL_COLOR
	hud.llmModelLabel.Text = "MODEL  " .. displayName
	hud.llmModelLabel.TextColor3 = if enabled then TEXT_COLOR else MUTED_COLOR
end

hud.llmToggleButton.MouseButton1Click:Connect(function()
	local currentEnabled = stateFolder:GetAttribute("llm_enabled") == true
	local currentModel = stateFolder:GetAttribute("llm_model") or "heuristic"
	setLLMConfigEvent:FireServer({ enabled = not currentEnabled, model = currentModel })
end)

hud.llmPrevButton.MouseButton1Click:Connect(function()
	local currentModel = stateFolder:GetAttribute("llm_model") or "heuristic"
	local idx = 1
	for i, m in ipairs(LLMConfig.MODELS) do
		if m.id == currentModel then idx = i; break end
	end
	local count = #LLMConfig.MODELS
	local newIdx = ((idx - 2) % count) + 1
	local newModel = LLMConfig.MODELS[newIdx].id
	local enabled = stateFolder:GetAttribute("llm_enabled") == true
	setLLMConfigEvent:FireServer({ enabled = enabled, model = newModel })
end)

hud.llmNextButton.MouseButton1Click:Connect(function()
	local currentModel = stateFolder:GetAttribute("llm_model") or "heuristic"
	local idx = 1
	for i, m in ipairs(LLMConfig.MODELS) do
		if m.id == currentModel then idx = i; break end
	end
	local count = #LLMConfig.MODELS
	local newIdx = (idx % count) + 1
	local newModel = LLMConfig.MODELS[newIdx].id
	local enabled = stateFolder:GetAttribute("llm_enabled") == true
	setLLMConfigEvent:FireServer({ enabled = enabled, model = newModel })
end)

-- Overview button — writes overview_mode attribute; TrackCamera reads it
local _overviewActive = false

hud.overviewButton.MouseButton1Click:Connect(function()
	_overviewActive = not _overviewActive
	stateFolder:SetAttribute("overview_mode", _overviewActive)
	hud.overviewButton.Text = if _overviewActive then "↩ Chase" else "Overview"
end)

local function render()
	StatusPanel.setPhase(stateFolder:GetAttribute("phase_label") or "Ready for request")
	StatusPanel.setRequestSummary(
		stateFolder:GetAttribute("request_summary") or "",
		stateFolder:GetAttribute("request_text") or ""
	)
	StatusPanel.setAttempt(
		stateFolder:GetAttribute("attempt_current") or 0,
		stateFolder:GetAttribute("attempt_max") or 0
	)
	StatusPanel.setExplanation(stateFolder:GetAttribute("explanation") or "")
	StatusPanel.setRepairAction(stateFolder:GetAttribute("repair_action_text") or "")
	StatusPanel.setError(
		stateFolder:GetAttribute("error_text") or "",
		stateFolder:GetAttribute("final_status") or ""
	)
	StatusPanel.setFailureBanner(
		stateFolder:GetAttribute("failure_banner_text") or "",
		stateFolder:GetAttribute("failure_banner_visible") == true
	)
	StatusPanel.setBusy(stateFolder:GetAttribute("busy") == true)
	StatusPanel.setLogLines({
		stateFolder:GetAttribute("log_1") or "",
		stateFolder:GetAttribute("log_2") or "",
		stateFolder:GetAttribute("log_3") or "",
		stateFolder:GetAttribute("log_4") or "",
	})

	StatsPanel.setBaseline(stateFolder:GetAttribute("baseline_lap_time") or -1)
	StatsPanel.setLastLapTime(stateFolder:GetAttribute("last_lap_time") or -1)
	StatsPanel.setSlowdown(stateFolder:GetAttribute("slowdown_ratio") or 1)
	StatsPanel.setCurrentSpeed(stateFolder:GetAttribute("current_speed") or 0)
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
	"busy",
	"baseline_lap_time",
	"last_lap_time",
	"slowdown_ratio",
	"current_speed",
	"current_heading_deg",
	"current_pitch_deg",
	"final_status",
	"failure_banner_text",
	"failure_banner_visible",
	"log_1",
	"log_2",
	"log_3",
	"log_4",
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
}

for _, attributeName in ipairs(observedAttributes) do
	stateFolder:GetAttributeChangedSignal(attributeName):Connect(render)
end

render()
