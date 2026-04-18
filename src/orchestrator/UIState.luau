local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local FailureMarker = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("FailureMarker"))
local SuccessMarker = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("SuccessMarker"))

local UIState = {}

local STATE_FOLDER_NAME = "AutoTrackUIState"
local SUBMIT_EVENT_NAME = "AutoTrack_SubmitRequest"

local _stateFolder: Folder? = nil
local _submitEvent: RemoteEvent? = nil
local _logs = { "", "", "", "" }

local function sectorAttr(sectorId: number, suffix: string): string
	return string.format("sector_%d_%s", sectorId, suffix)
end

local function ensureStateFolder(): Folder
	if _stateFolder and _stateFolder.Parent then
		return _stateFolder
	end

	local folder = ReplicatedStorage:FindFirstChild(STATE_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		_stateFolder = folder
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = STATE_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	_stateFolder = folder
	return folder
end

local function ensureSubmitEvent(): RemoteEvent
	if _submitEvent and _submitEvent.Parent then
		return _submitEvent
	end

	local existing = ReplicatedStorage:FindFirstChild(SUBMIT_EVENT_NAME)
	if existing and existing:IsA("RemoteEvent") then
		_submitEvent = existing
		return existing
	end

	local event = Instance.new("RemoteEvent")
	event.Name = SUBMIT_EVENT_NAME
	event.Parent = ReplicatedStorage
	_submitEvent = event
	return event
end

local function setAttributes(values)
	local folder = ensureStateFolder()
	for key, value in pairs(values) do
		folder:SetAttribute(key, value)
	end
end

local function setLogs()
	local folder = ensureStateFolder()
	for index = 1, 4 do
		folder:SetAttribute(("log_%d"):format(index), _logs[index] or "")
	end
end

local function formatRequestSummary(sectorId: number?, mechanic: string?): string
	if not sectorId or not mechanic or mechanic == "" then
		return ""
	end
	return ("Sector %d · %s"):format(sectorId, mechanic)
end

function UIState.init(baselineLapTime: number)
	ensureStateFolder()
	ensureSubmitEvent()
	_logs = { "", "", "", "" }
	setAttributes({
		phase = "Idle",
		phase_label = "Ready for request",
		busy = false,
		request_text = "",
		target_sector_id = 0,
		target_mechanic = "",
		request_summary = "",
		attempt_current = 0,
		attempt_max = Constants.MAX_REPAIR_ATTEMPTS,
		explanation = "",
		repair_action_text = "",
		baseline_lap_time = baselineLapTime,
		last_lap_time = -1,
		slowdown_ratio = 1,
		current_speed = 0,
		current_sector_id = 0,
		final_status = "",
		error_text = "",
		failure_banner_text = "",
		failure_banner_visible = false,
	})
	setLogs()
	FailureMarker.hide()
	SuccessMarker.clear()
end

function UIState.initTrackCamera(sectors)
	local values = {}
	for _, sector in ipairs(sectors) do
		local center = sector.entry.Position:Lerp(sector.exit.Position, 0.5)
		values[sectorAttr(sector.id, "kind")] = sector.kind
		values[sectorAttr(sector.id, "mechanic")] = ""
		values[sectorAttr(sector.id, "center_x")] = center.X
		values[sectorAttr(sector.id, "center_y")] = center.Y
		values[sectorAttr(sector.id, "center_z")] = center.Z
	end
	setAttributes(values)
end

function UIState.getSubmitEvent(): RemoteEvent
	return ensureSubmitEvent()
end

function UIState.getStateFolder(): Folder
	return ensureStateFolder()
end

function UIState.setPhase(phase: string, label: string)
	setAttributes({
		phase = phase,
		phase_label = label,
	})
end

function UIState.setBusy(isBusy: boolean)
	setAttributes({
		busy = isBusy,
	})
end

function UIState.setRequestContext(rawText: string, sectorId: number, mechanic: string)
	setAttributes({
		request_text = rawText,
		target_sector_id = sectorId,
		target_mechanic = mechanic,
		request_summary = formatRequestSummary(sectorId, mechanic),
	})
end

function UIState.setAttempt(current: number, maxAttempts: number)
	setAttributes({
		attempt_current = current,
		attempt_max = maxAttempts,
	})
end

function UIState.setExplanation(text: string)
	setAttributes({
		explanation = text or "",
	})
end

function UIState.setRepairAction(text: string)
	setAttributes({
		repair_action_text = text or "",
	})
end

function UIState.clearExplanation()
	UIState.setExplanation("")
end

function UIState.clearRepairAction()
	UIState.setRepairAction("")
end

function UIState.setError(text: string)
	setAttributes({
		error_text = text or "",
	})
end

function UIState.clearError()
	UIState.setError("")
end

function UIState.showFailureBanner(text: string)
	setAttributes({
		failure_banner_text = text or "",
		failure_banner_visible = text ~= nil and text ~= "",
	})
end

function UIState.hideFailureBanner()
	setAttributes({
		failure_banner_text = "",
		failure_banner_visible = false,
	})
end

function UIState.resetLogs()
	_logs = { "", "", "", "" }
	setLogs()
end

function UIState.appendLog(line: string)
	table.remove(_logs, 1)
	table.insert(_logs, line)
	setLogs()
end

function UIState.beginJob(request)
	UIState.resetLogs()
	UIState.clearError()
	UIState.clearExplanation()
	UIState.clearRepairAction()
	UIState.setBusy(true)
	UIState.setRequestContext(request.raw_text, request.parsed.sector_id, request.parsed.mechanic)
	UIState.setAttempt(0, Constants.MAX_REPAIR_ATTEMPTS)
	setAttributes({
		final_status = "",
	})
	UIState.hideFailureBanner()
	FailureMarker.hide()
	SuccessMarker.clear()
end

function UIState.rejectRequest(rawText: string, reason: string)
	local label = if string.find(reason, "busy", 1, true) ~= nil then "Track busy" else "Request rejected"
	UIState.setBusy(false)
	UIState.setRequestContext(rawText, 0, "")
	UIState.setPhase("RejectRequest", label)
	UIState.setError(reason)
	UIState.setAttempt(0, Constants.MAX_REPAIR_ATTEMPTS)
	UIState.clearExplanation()
	UIState.clearRepairAction()
	setAttributes({
		final_status = "",
	})
	UIState.hideFailureBanner()
	UIState.appendLog(label .. ": " .. reason)
end

function UIState.publishAttemptResult(result)
	setAttributes({
		last_lap_time = result.metrics.lap_time,
		slowdown_ratio = result.metrics.slowdown_ratio,
	})
end

-- Phase 11: publish a ChallengeScore. Called from JobRunner on successful
-- commit so HUD observers can show the per-sector score.
function UIState.publishScore(sectorId: number, score)
	if score == nil then return end
	setAttributes({
		last_score_sector = sectorId,
		last_score_total = score.total,
		last_score_air = score.air,
		last_score_lateral = score.lateral,
		last_score_near_miss = score.near_miss,
		last_score_time_cost = score.time_cost,
		last_score_budget_used = score.budget_used,
		last_score_over_budget = score.over_budget,
	})
end

function UIState.setBaselineLapTime(seconds: number)
	setAttributes({
		baseline_lap_time = seconds,
	})
end

function UIState.setCurrentSpeed(speed: number)
	setAttributes({
		current_speed = speed,
	})
end

function UIState.setCurrentSector(sectorId: number)
	setAttributes({
		current_sector_id = sectorId,
	})
end

function UIState.setSectorMechanic(sectorId: number, mechanic: string?)
	setAttributes({
		[sectorAttr(sectorId, "mechanic")] = mechanic or "",
	})
end

function UIState.showFailure(result)
	local markerPosition = result.failure_position or result.final_position
	if markerPosition then
		FailureMarker.show(markerPosition, result.trajectory_tail)
	end
end

function UIState.hideFailure()
	FailureMarker.hide()
end

local function collectSectorParts(sectorMeta): { Instance }
	local parts = {}
	local partGroup = sectorMeta and sectorMeta.partGroup
	if not partGroup then
		return parts
	end
	for _, descendant in ipairs(partGroup:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

function UIState.publishCommit(sectorMeta)
	UIState.setBusy(false)
	UIState.setPhase("Commit", "Committed")
	setAttributes({
		final_status = "committed",
	})
	UIState.hideFailure()
	UIState.hideFailureBanner()
	SuccessMarker.flash(collectSectorParts(sectorMeta))
end

function UIState.publishRevert()
	UIState.setBusy(false)
	UIState.setPhase("Revert", "Reverted")
	setAttributes({
		final_status = "reverted",
	})
	UIState.hideFailure()
	UIState.hideFailureBanner()
	SuccessMarker.clear()
end

function UIState.publishReady()
	UIState.setBusy(false)
	UIState.setPhase("Idle", "Ready for request")
	UIState.clearError()
	UIState.clearExplanation()
	UIState.clearRepairAction()
	UIState.hideFailure()
	UIState.hideFailureBanner()
	SuccessMarker.clear()
	setAttributes({
		final_status = "",
		request_text = "",
		target_sector_id = 0,
		target_mechanic = "",
		request_summary = "",
		attempt_current = 0,
		current_sector_id = 0,
	})
end

return UIState
