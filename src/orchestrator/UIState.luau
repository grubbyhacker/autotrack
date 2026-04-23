local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local FailureMarker = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("FailureMarker"))
local SuccessMarker = require(ReplicatedStorage:WaitForChild("AutoTrackUI"):WaitForChild("SuccessMarker"))

local UIState = {}

local STATE_FOLDER_NAME = "AutoTrackUIState"
local SUBMIT_EVENT_NAME = "AutoTrack_SubmitRequest"
local LOG_LINES = 8

local _stateFolder: Folder? = nil
local _submitEvent: RemoteEvent? = nil
local _logs = table.create(LOG_LINES, "")

local function defaultOrchestratorAttributes()
	return {
		orchestrator_objective_total = 0,
		orchestrator_budget_target = 0,
		orchestrator_budget_headroom = 1,
		orchestrator_decision_index = 0,
		orchestrator_last_decision = "",
		orchestrator_last_rationale = "",
		orchestrator_memory_depth = 0,
		orchestrator_repeat_penalties = "",
		orchestrator_failure_signature = "",
		orchestrator_reliability_index = 0,
		orchestrator_track_intent = "",
		shared_memory_depth = 0,
		proposal_memory_depth = 0,
		repair_memory_depth = 0,
		shared_memory_1 = "",
		shared_memory_2 = "",
		proposal_memory_1 = "",
		repair_memory_1 = "",
		orchestrator_ledger_1 = "",
		orchestrator_ledger_2 = "",
		orchestrator_ledger_3 = "",
	}
end

local function defaultTuneAttributes()
	return {
		tune_mode_active = false,
		tune_sector_id = 0,
		tune_mechanic = "",
		tune_pass_count = 0,
		tune_last_result = "",
		tune_last_failure = "",
		tune_param_summary = "",
		tune_attr_summary = "",
		tune_bounds_summary = "",
		tune_active_target_speed = 0,
		tune_best_score = 0,
		tune_auto_run = false,
		tune_run_in_flight = false,
		tune_candidate_version = 0,
		tune_last_run_id = 0,
		tune_last_pass_json = "",
		tune_best_pass_json = "",
		tune_last_batch_json = "",
		tune_best_batch_json = "",
		tune_history_json = "",
		tune_history_1 = "",
		tune_history_2 = "",
		tune_history_3 = "",
		tune_history_4 = "",
		tune_baseline_snapshot = "",
		tune_last_compare_json = "",
		tune_promotion_snapshot = "",
	}
end

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
	for index = 1, LOG_LINES do
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
	_logs = table.create(LOG_LINES, "")
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
		committed_lap_time = -1,
		last_run_scope = "",
		slowdown_ratio = 1,
		committed_slowdown_ratio = 1,
		current_speed = 0,
		current_target_speed = 0,
		current_commanded_speed = 0,
		current_heading_deg = 0,
		current_pitch_deg = 0,
		current_sector_id = 0,
		current_sector_kind = "",
		final_status = "",
		error_text = "",
		llm_warning_text = "",
		failure_banner_text = "",
		failure_banner_visible = false,
		last_score_sector = 0,
		last_score_total = 0,
		last_score_air = 0,
		last_score_lateral = 0,
		last_score_near_miss = 0,
		last_score_time_cost = 0,
		last_score_budget_used = 0,
		last_score_over_budget = false,
		track_score_total = 0,
		track_score_count = 0,
		track_budget_used = 0,
		track_budget_headroom = 1,
		track_over_budget = false,
		llm_enabled = false,
		llm_model = "heuristic",
		camera_override_enabled = false,
		camera_override_pos_x = 0,
		camera_override_pos_y = 0,
		camera_override_pos_z = 0,
		camera_override_focus_x = 0,
		camera_override_focus_y = 0,
		camera_override_focus_z = 0,
		camera_override_fov = 70,
		endurance_mode_active = false,
		endurance_hotfix_active = false,
		endurance_hotfix_sector = 0,
		endurance_terminal = false,
		endurance_lap_count = 0,
		endurance_attempt_budget_used = 0,
		endurance_attempt_budget_total = 0,
		build_stamp = "",
		controller_profile = "",
	})
	setAttributes(defaultOrchestratorAttributes())
	setAttributes(defaultTuneAttributes())
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
		values[sectorAttr(sector.id, "committed_score")] = -1
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

function UIState.setCameraOverride(position: Vector3, focus: Vector3, fieldOfView: number?)
	setAttributes({
		camera_override_enabled = true,
		camera_override_pos_x = position.X,
		camera_override_pos_y = position.Y,
		camera_override_pos_z = position.Z,
		camera_override_focus_x = focus.X,
		camera_override_focus_y = focus.Y,
		camera_override_focus_z = focus.Z,
		camera_override_fov = fieldOfView or 70,
	})
end

function UIState.clearCameraOverride()
	setAttributes({
		camera_override_enabled = false,
	})
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

function UIState.setLLMWarning(text: string)
	setAttributes({
		llm_warning_text = text or "",
	})
end

function UIState.clearLLMWarning()
	UIState.setLLMWarning("")
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
	_logs = table.create(LOG_LINES, "")
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
	UIState.clearLLMWarning()
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

function UIState.rejectRequest(rawText: string, reason: string, warningText: string?)
	local label = if string.find(reason, "busy", 1, true) ~= nil then "Track busy" else "Request rejected"
	UIState.setBusy(false)
	UIState.setRequestContext(rawText, 0, "")
	UIState.setPhase("RejectRequest", label)
	UIState.setError(reason)
	UIState.setLLMWarning(warningText or "")
	UIState.setAttempt(0, Constants.MAX_REPAIR_ATTEMPTS)
	UIState.clearExplanation()
	UIState.clearRepairAction()
	setAttributes({
		final_status = "",
	})
	UIState.hideFailureBanner()
	UIState.appendLog(label .. ": " .. reason)
end

function UIState.publishAttemptResult(result, runScope: string?)
	setAttributes({
		last_lap_time = result.metrics.lap_time,
		last_run_scope = runScope or "lap",
		slowdown_ratio = result.metrics.slowdown_ratio,
	})
end

function UIState.publishCommittedLap(result)
	if result == nil or result.metrics == nil then
		return
	end
	setAttributes({
		committed_lap_time = result.metrics.lap_time or -1,
		committed_slowdown_ratio = result.metrics.slowdown_ratio or 1,
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
		[sectorAttr(sectorId, "committed_score")] = score.total,
	})
end

function UIState.publishTrackScore(total: number, sectorCount: number, budgetUsed: number, budgetHeadroom: number, overBudget: boolean)
	setAttributes({
		track_score_total = total or 0,
		track_score_count = sectorCount or 0,
		track_budget_used = budgetUsed or 0,
		track_budget_headroom = budgetHeadroom or 0,
		track_over_budget = overBudget == true,
	})
end

function UIState.resetTrackScore()
	UIState.publishTrackScore(0, 0, 0, 1, false)
end

function UIState.setLLMConfig(enabled: boolean, modelId: string)
	setAttributes({
		llm_enabled = enabled == true,
		llm_model = modelId or "heuristic",
	})
end

function UIState.setBaselineLapTime(seconds: number)
	setAttributes({
		baseline_lap_time = seconds,
	})
end

function UIState.setLastLapTime(seconds: number)
	setAttributes({
		last_lap_time = seconds,
		last_run_scope = "lap",
		slowdown_ratio = 1,
	})
end

function UIState.setCurrentSpeed(speed: number)
	setAttributes({
		current_speed = speed,
	})
end

function UIState.setSpeedTargets(targetSpeed: number, commandedSpeed: number)
	setAttributes({
		current_target_speed = targetSpeed or 0,
		current_commanded_speed = commandedSpeed or 0,
	})
end

function UIState.setCarAttitude(headingDeg: number, pitchDeg: number)
	setAttributes({
		current_heading_deg = headingDeg,
		current_pitch_deg = pitchDeg,
	})
end

function UIState.setCurrentSector(sectorId: number)
	setAttributes({
		current_sector_id = sectorId,
	})
end

function UIState.setCurrentSectorKind(kind: string)
	setAttributes({
		current_sector_kind = kind or "",
	})
end

function UIState.setRuntimeIdentity(buildStamp: string, controllerProfile: string)
	setAttributes({
		build_stamp = buildStamp or "",
		controller_profile = controllerProfile or "",
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
	UIState.setAttempt(0, Constants.MAX_REPAIR_ATTEMPTS)
	setAttributes({
		final_status = "committed",
	})
	UIState.hideFailure()
	UIState.hideFailureBanner()
	SuccessMarker.flash(collectSectorParts(sectorMeta))
end

function UIState.publishRevert()
	UIState.setBusy(false)
	if ensureStateFolder():GetAttribute("endurance_hotfix_active") ~= true then
		UIState.setPhase("Revert", "Reverted")
	end
	UIState.setAttempt(0, Constants.MAX_REPAIR_ATTEMPTS)
	setAttributes({
		final_status = "reverted",
	})
	UIState.hideFailure()
	UIState.hideFailureBanner()
	SuccessMarker.clear()
end

function UIState.setEnduranceActive(active: boolean, attemptBudgetTotal: number?)
	setAttributes({
		endurance_mode_active = active == true,
		endurance_terminal = false,
		endurance_hotfix_active = false,
		endurance_hotfix_sector = 0,
		endurance_lap_count = 0,
		endurance_attempt_budget_used = 0,
		endurance_attempt_budget_total = attemptBudgetTotal or 0,
		llm_warning_text = "",
	})
end

function UIState.setEnduranceLapCount(count: number)
	setAttributes({ endurance_lap_count = count })
end

function UIState.setEnduranceAttemptBudget(used: number, total: number)
	setAttributes({
		endurance_attempt_budget_used = used,
		endurance_attempt_budget_total = total,
	})
end

function UIState.setOrchestratorTelemetry(payload)
	local ledgerLines = payload and payload.ledger_lines or {}
	local sharedMemoryLines = payload and payload.shared_memory_lines or {}
	local proposalMemoryLines = payload and payload.proposal_memory_lines or {}
	local repairMemoryLines = payload and payload.repair_memory_lines or {}
	setAttributes({
		orchestrator_objective_total = payload and payload.objective_total or 0,
		orchestrator_budget_target = payload and payload.budget_target or 0,
		orchestrator_budget_headroom = payload and payload.budget_headroom or 1,
		orchestrator_decision_index = payload and payload.decision_index or 0,
		orchestrator_last_decision = payload and payload.last_decision or "",
		orchestrator_last_rationale = payload and payload.last_rationale or "",
		orchestrator_memory_depth = payload and payload.memory_depth or 0,
		orchestrator_repeat_penalties = payload and payload.repeat_penalties or "",
		orchestrator_failure_signature = payload and payload.failure_signature or "",
		orchestrator_reliability_index = payload and payload.reliability_index or 0,
		orchestrator_track_intent = payload and payload.track_intent or "",
		shared_memory_depth = payload and payload.shared_memory_depth or 0,
		proposal_memory_depth = payload and payload.proposal_memory_depth or 0,
		repair_memory_depth = payload and payload.repair_memory_depth or 0,
		shared_memory_1 = sharedMemoryLines[1] or "",
		shared_memory_2 = sharedMemoryLines[2] or "",
		proposal_memory_1 = proposalMemoryLines[1] or "",
		repair_memory_1 = repairMemoryLines[1] or "",
		orchestrator_ledger_1 = ledgerLines[1] or "",
		orchestrator_ledger_2 = ledgerLines[2] or "",
		orchestrator_ledger_3 = ledgerLines[3] or "",
	})
end

function UIState.clearOrchestratorTelemetry()
	setAttributes(defaultOrchestratorAttributes())
end

function UIState.setTuneTelemetry(payload)
	setAttributes({
		tune_mode_active = payload and payload.active == true,
		tune_sector_id = payload and payload.sector_id or 0,
		tune_mechanic = payload and payload.mechanic or "",
		tune_pass_count = payload and payload.pass_count or 0,
		tune_last_result = payload and payload.last_result or "",
		tune_last_failure = payload and payload.last_failure or "",
		tune_param_summary = payload and payload.param_summary or "",
		tune_attr_summary = payload and payload.attr_summary or "",
		tune_bounds_summary = payload and payload.bounds_summary or "",
		tune_active_target_speed = payload and payload.active_target_speed or 0,
		tune_best_score = payload and payload.best_score or 0,
		tune_auto_run = payload and payload.auto_run == true,
		tune_run_in_flight = payload and payload.run_in_flight == true,
		tune_candidate_version = payload and payload.candidate_version or 0,
		tune_last_run_id = payload and payload.last_run_id or 0,
		tune_last_pass_json = payload and payload.last_pass_json or "",
		tune_best_pass_json = payload and payload.best_pass_json or "",
		tune_last_batch_json = payload and payload.last_batch_json or "",
		tune_best_batch_json = payload and payload.best_batch_json or "",
		tune_history_json = payload and payload.history_json or "",
		tune_history_1 = payload and payload.history_1 or "",
		tune_history_2 = payload and payload.history_2 or "",
		tune_history_3 = payload and payload.history_3 or "",
		tune_history_4 = payload and payload.history_4 or "",
		tune_baseline_snapshot = payload and payload.baseline_snapshot or "",
		tune_last_compare_json = payload and payload.last_compare_json or "",
		tune_promotion_snapshot = payload and payload.promotion_snapshot or "",
	})
end

function UIState.clearTuneTelemetry()
	setAttributes(defaultTuneAttributes())
end

function UIState.setHotfixActive(active: boolean, sectorId: number?)
	local values = {
		endurance_hotfix_active = active == true,
		endurance_hotfix_sector = sectorId or 0,
	}
	if active == true then
		values.final_status = ""
	end
	setAttributes(values)
end

function UIState.setEnduranceTerminal(sectorId: number?)
	setAttributes({
		endurance_terminal = true,
		endurance_hotfix_active = false,
		endurance_hotfix_sector = sectorId or 0,
		busy = false,
	})
	UIState.setAttempt(0, Constants.HOTFIX_MAX_ATTEMPTS)
end

function UIState.publishReady()
	UIState.setBusy(false)
	UIState.setPhase("Idle", "Ready for request")
	UIState.clearError()
	UIState.clearLLMWarning()
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
	UIState.clearOrchestratorTelemetry()
	UIState.clearTuneTelemetry()
end

return UIState
