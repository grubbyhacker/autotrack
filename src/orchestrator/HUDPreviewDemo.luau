local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local UIState = require(script.Parent.UIState)

local HUDPreviewDemo = {}

local _activeKind: string? = nil
local _snapshot = nil

local HUD_DEMO_ATTRS = {
	"phase",
	"phase_label",
	"busy",
	"request_text",
	"target_sector_id",
	"target_mechanic",
	"request_summary",
	"attempt_current",
	"attempt_max",
	"explanation",
	"repair_action_text",
	"final_status",
	"error_text",
	"llm_enabled",
	"llm_model",
	"shared_memory_depth",
	"proposal_memory_depth",
	"repair_memory_depth",
	"shared_memory_1",
	"shared_memory_2",
	"proposal_memory_1",
	"repair_memory_1",
	"log_1",
	"log_2",
	"log_3",
	"log_4",
	"log_5",
	"log_6",
	"log_7",
	"log_8",
	"endurance_mode_active",
	"endurance_hotfix_active",
	"endurance_hotfix_sector",
	"endurance_terminal",
	"endurance_lap_count",
	"endurance_attempt_budget_used",
	"endurance_attempt_budget_total",
}

local function captureSnapshot()
	local folder = UIState.getStateFolder()
	local snapshot = {}
	for _, attr in ipairs(HUD_DEMO_ATTRS) do
		snapshot[attr] = folder:GetAttribute(attr)
	end
	return snapshot
end

local function restoreSnapshot()
	if _snapshot == nil then
		_activeKind = nil
		return
	end

	local folder = UIState.getStateFolder()
	for _, attr in ipairs(HUD_DEMO_ATTRS) do
		folder:SetAttribute(attr, _snapshot[attr])
	end

	_snapshot = nil
	_activeKind = nil
end

function HUDPreviewDemo.isActive(): boolean
	return _activeKind ~= nil
end

function HUDPreviewDemo.activeKind(): string?
	return _activeKind
end

function HUDPreviewDemo.toggle(kind: string): (boolean, string?)
	local folder = UIState.getStateFolder()

	if _activeKind == kind then
		restoreSnapshot()
		return true, nil
	end

	if _activeKind ~= nil then
		restoreSnapshot()
	end

	_snapshot = captureSnapshot()
	_activeKind = kind

	if kind == "repair" then
		folder:SetAttribute("phase", "ApplyRepair")
		folder:SetAttribute("phase_label", "Applying repair...")
		folder:SetAttribute("busy", false)
		folder:SetAttribute("request_text", "repair the jump in sector 3")
		folder:SetAttribute("target_sector_id", 3)
		folder:SetAttribute("target_mechanic", "RampJump")
		folder:SetAttribute("request_summary", "Sector 3 · RampJump")
		folder:SetAttribute("attempt_current", 2)
		folder:SetAttribute("attempt_max", Constants.MAX_REPAIR_ATTEMPTS)
		folder:SetAttribute("explanation", "Entry speed bled off before takeoff, so the repair adds an ingress boost to carry momentum up the ramp")
		folder:SetAttribute("repair_action_text", "Entry boost")
		folder:SetAttribute("final_status", "")
		folder:SetAttribute("error_text", "")
		folder:SetAttribute("log_1", "Initial proposal accepted")
		folder:SetAttribute("log_2", "Failure: no_progress in sector 3")
		folder:SetAttribute("log_3", "Metrics: progress=0.31 entered=true exited=false")
		folder:SetAttribute("log_4", "Hints: boost first | avoid lengthening the ramp")
		folder:SetAttribute("log_5", "Attempt 1: shortened ramp length")
		folder:SetAttribute("log_6", "Attempt 2: added ingress boost after uphill speed bleed")
		folder:SetAttribute("log_7", "Action: ingress Boost25")
		folder:SetAttribute("log_8", "Awaiting next full-lap verification")
		return true, nil
	end

	if kind == "llmerror" then
		folder:SetAttribute("phase", "ApplyRepair")
		folder:SetAttribute("phase_label", "Repair backend stalled")
		folder:SetAttribute("busy", false)
		folder:SetAttribute("request_text", "repair the jump in sector 3")
		folder:SetAttribute("target_sector_id", 3)
		folder:SetAttribute("target_mechanic", "RampJump")
		folder:SetAttribute("request_summary", "Sector 3 · RampJump")
		folder:SetAttribute("attempt_current", 0)
		folder:SetAttribute("attempt_max", Constants.MAX_REPAIR_ATTEMPTS)
		folder:SetAttribute("explanation", "")
		folder:SetAttribute("repair_action_text", "")
		folder:SetAttribute("final_status", "")
		folder:SetAttribute("llm_enabled", true)
		folder:SetAttribute("llm_model", "google/gemma-3-4b-it")
		folder:SetAttribute("error_text", "LLM error: OpenRouter HTTP 429: rate limit exceeded for google/gemma-3-4b-it; retry after 22s")
		folder:SetAttribute("log_1", "Attempt 1: ENTRY BOOST10")
		folder:SetAttribute("log_2", "Attempt 2: LANDING LENGTH 18")
		folder:SetAttribute("log_3", "Target exited but reacquire failed at sector 3")
		folder:SetAttribute("log_4", "Requesting LLM repair from Gemma 3 4B")
		folder:SetAttribute("log_5", "LLM error: OpenRouter HTTP 429")
		folder:SetAttribute("log_6", "Model retry window reported as 22s")
		folder:SetAttribute("log_7", "Repair loop paused pending operator retry")
		folder:SetAttribute("log_8", "")
		return true, nil
	end

	if kind == "ui-hotfix" then
		folder:SetAttribute("phase", "EnduranceLoop")
		folder:SetAttribute("phase_label", "Endurance Mode")
		folder:SetAttribute("busy", false)
		folder:SetAttribute("request_text", "")
		folder:SetAttribute("request_summary", "")
		folder:SetAttribute("attempt_current", 0)
		folder:SetAttribute("attempt_max", 0)
		folder:SetAttribute("explanation", "")
		folder:SetAttribute("repair_action_text", "")
		folder:SetAttribute("final_status", "")
		folder:SetAttribute("error_text", "")
		folder:SetAttribute("endurance_mode_active", true)
		folder:SetAttribute("endurance_hotfix_active", true)
		folder:SetAttribute("endurance_hotfix_sector", 6)
		folder:SetAttribute("endurance_terminal", false)
		folder:SetAttribute("endurance_lap_count", 9)
		folder:SetAttribute("endurance_attempt_budget_used", 3)
		folder:SetAttribute("endurance_attempt_budget_total", Constants.ENDURANCE_ATTEMPT_BUDGET)
		folder:SetAttribute("log_1", "Endurance lap 9 failed in sector 6")
		folder:SetAttribute("log_2", "Failure persisted on retry")
		folder:SetAttribute("log_3", "Escalating to live hotfix")
		folder:SetAttribute("log_4", "Committed sector 6 reverted")
		folder:SetAttribute("log_5", "Hotfix agent preparing repair")
		folder:SetAttribute("log_6", "")
		folder:SetAttribute("log_7", "")
		folder:SetAttribute("log_8", "")
		return true, nil
	end

	restoreSnapshot()
	return false, "unknown HUD demo"
end

return HUDPreviewDemo
