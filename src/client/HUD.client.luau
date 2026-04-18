local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AutoTrackUI = ReplicatedStorage:WaitForChild("AutoTrackUI")
local StatusPanel = require(AutoTrackUI:WaitForChild("StatusPanel"))
local StatsPanel = require(AutoTrackUI:WaitForChild("StatsPanel"))

local stateFolder = ReplicatedStorage:WaitForChild("AutoTrackUIState")
local submitEvent = ReplicatedStorage:WaitForChild("AutoTrack_SubmitRequest")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

StatusPanel.mount(playerGui, function(text: string)
	submitEvent:FireServer(text)
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
	"final_status",
	"failure_banner_text",
	"failure_banner_visible",
	"log_1",
	"log_2",
	"log_3",
	"log_4",
}

for _, attributeName in ipairs(observedAttributes) do
	stateFolder:GetAttributeChangedSignal(attributeName):Connect(render)
end

render()
