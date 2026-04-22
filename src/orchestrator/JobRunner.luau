-- JobRunner.luau
-- Top-level CI job runner.  Drives the full propose → verify → repair → commit/revert loop.
-- prd_plan.md §7, Phase 6
--
-- Entry point: JobRunner.submit(rawText)
-- There is exactly one global job lock — concurrent submissions are rejected immediately.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRollback = require(script.Parent.Parent.Track.SectorRollback)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local AttemptRunner = require(script.Parent.AttemptRunner)
local JobStateMachine = require(script.Parent.JobStateMachine)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local UIState = require(script.Parent.UIState)
local CameraDemo = require(script.Parent.CameraDemo)
local ChallengeRunner = require(script.Parent.ChallengeRunner)
local MaximizerAgent = require(script.Parent.MaximizerAgent)
local HotfixAgent = require(script.Parent.HotfixAgent)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local TestDispatcher = require(script.Parent.TestDispatcher)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)

type CIJob = Types.CIJob
type Request = Types.Request
type DesignIntent = Types.DesignIntent

local JobRunner = {}
local _lastJob: CIJob? = nil
local _idCounter = 0
local _pendingRequest: string? = nil
local _extremeDemoActive = false
local _extremePriorStates = {}
local _allowEnduranceInternalSubmit = false
local _hudDemoActive: string? = nil
local _hudDemoSnapshot = nil
local HOTFIX_DEMO_REQUEST = "add a chicane in sector 7"
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
	"log_1",
	"log_2",
	"log_3",
	"log_4",
	"log_5",
	"log_6",
	"log_7",
	"log_8",
}

local function nextId(prefix: string): string
	_idCounter += 1
	return string.format("%s-%03d", prefix, _idCounter)
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

local function cloneState(state)
	local params = {}
	for key, value in pairs(state.params) do
		params[key] = value
	end
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = params,
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function cloneDesignIntent(intent: DesignIntent): DesignIntent
	local constraints = {}
	for _, constraint in ipairs(intent.constraints or {}) do
		table.insert(constraints, constraint)
	end
	return {
		sector_id = intent.sector_id,
		mechanic = intent.mechanic,
		params_hint = intent.params_hint,
		rationale = intent.rationale,
		target_score_band = intent.target_score_band,
		target_budget_tolerance = intent.target_budget_tolerance,
		target_reliability = intent.target_reliability,
		spectacle_priority = intent.spectacle_priority,
		novelty_priority = intent.novelty_priority,
		replacement_intent = intent.replacement_intent,
		desired_feel = intent.desired_feel,
		constraints = constraints,
	}
end

local DESIGN_INTENT_QUALIFIER_WORDS = {
	really = true,
	tall = true,
	long = true,
	short = true,
	steep = true,
	gentle = true,
	tight = true,
	wide = true,
	narrow = true,
	shallow = true,
	deep = true,
	extreme = true,
}

local DESIGN_INTENT_REPLACEMENT_INTENTS = {
	open_slot_preferred = true,
	replace_if_gain = true,
	preserve_good_sector = true,
}

local DESIGN_INTENT_SCORE_BANDS = {
	low = true,
	medium = true,
	high = true,
	extreme = true,
}

local DESIGN_INTENT_TOLERANCES = {
	low = true,
	medium = true,
	high = true,
}

local DESIGN_INTENT_RELIABILITY = {
	conservative = true,
	balanced = true,
	risky = true,
}

local DESIGN_INTENT_PRIORITIES = {
	low = true,
	medium = true,
	high = true,
}

local EDITABLE_INTENT_SECTORS = {
	[2] = true,
	[3] = true,
	[4] = true,
	[7] = true,
	[8] = true,
	[9] = true,
}

local function extractIntentQualifiers(paramsHint: string?): { string }
	local qualifiers = {}
	local seen = {}
	for word in string.gmatch(string.lower(paramsHint or ""), "[%a%-]+") do
		if DESIGN_INTENT_QUALIFIER_WORDS[word] and not seen[word] then
			seen[word] = true
			table.insert(qualifiers, word)
		end
	end
	return qualifiers
end

local function validateDesignIntent(intent): (boolean, string?)
	if type(intent) ~= "table" then
		return false, "design intent missing"
	end
	if type(intent.sector_id) ~= "number" then
		return false, "design intent sector_id missing"
	end
	if not EDITABLE_INTENT_SECTORS[intent.sector_id] then
		return false, "design intent sector_id must be an editable straight"
	end
	if intent.mechanic ~= "RampJump" and intent.mechanic ~= "Chicane" and intent.mechanic ~= "CrestDip" then
		return false, "design intent mechanic missing or unsupported"
	end
	if type(intent.params_hint) ~= "string" then
		return false, "design intent params_hint missing"
	end
	if type(intent.rationale) ~= "string" or intent.rationale == "" then
		return false, "design intent rationale missing"
	end
	if type(intent.desired_feel) ~= "string" or intent.desired_feel == "" then
		return false, "design intent desired_feel missing"
	end
	if not DESIGN_INTENT_SCORE_BANDS[intent.target_score_band] then
		return false, "design intent target_score_band invalid"
	end
	if not DESIGN_INTENT_TOLERANCES[intent.target_budget_tolerance] then
		return false, "design intent target_budget_tolerance invalid"
	end
	if not DESIGN_INTENT_RELIABILITY[intent.target_reliability] then
		return false, "design intent target_reliability invalid"
	end
	if not DESIGN_INTENT_PRIORITIES[intent.spectacle_priority] then
		return false, "design intent spectacle_priority invalid"
	end
	if not DESIGN_INTENT_PRIORITIES[intent.novelty_priority] then
		return false, "design intent novelty_priority invalid"
	end
	if not DESIGN_INTENT_REPLACEMENT_INTENTS[intent.replacement_intent] then
		return false, "design intent replacement_intent invalid"
	end
	if type(intent.constraints) ~= "table" or #intent.constraints == 0 then
		return false, "design intent constraints missing"
	end
	return true, nil
end

local function buildEnduranceRequest(requestId: string, rawText: string, designIntent: DesignIntent): Request
	return {
		request_id = requestId,
		raw_text = trim(rawText),
		parsed = {
			sector_id = designIntent.sector_id,
			mechanic = designIntent.mechanic,
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = extractIntentQualifiers(designIntent.params_hint),
		origin = "endurance",
		design_intent = cloneDesignIntent(designIntent),
		timestamp = os.time(),
	}
end

local function actionSummary(action)
	if not action then
		return "initial"
	end
	if action.type == "SetNumericLever" then
		return string.format("%s=%s", action.lever, tostring(action.value))
	end
	return string.format("%s=%s", action.pad, action.value)
end

local function repairActionLabel(action): string
	if not action then
		return ""
	end
	if action.type == "SetPad" then
		local side = if action.pad == "ingress" then "ENTRY" else "EXIT"
		return string.format("%s %s", side, PadValueUtils.display(action.value))
	end

	local leverLabels = {
		ramp_angle = "RAMP ANGLE",
		ramp_length = "RAMP LENGTH",
		gap_length = "GAP LENGTH",
		landing_length = "LANDING LENGTH",
		amplitude = "AMPLITUDE",
		transition_length = "TRANSITION",
		corridor_width = "CORRIDOR",
		height_or_depth = "HEIGHT",
		radius = "RADIUS",
		sector_length = "FEATURE LENGTH",
	}
	return string.format("%s %s", leverLabels[action.lever] or string.upper(action.lever), tostring(action.value))
end

local function requestSummary(parsed): string
	if parsed.request_kind == "Pad" then
		return string.format("pad %s=%s", tostring(parsed.pad_side), tostring(parsed.pad_value))
	end
	return tostring(parsed.mechanic)
end

local function boolString(value): string
	return if value then "true" else "false"
end

local function qualifiersSummary(qualifiers): string
	if qualifiers == nil or #qualifiers == 0 then
		return "-"
	end
	return table.concat(qualifiers, ",")
end

local function failureDetail(result): string
	if result == nil or result.failure == nil or result.failure.detail == nil or result.failure.detail == "" then
		return "-"
	end
	return result.failure.detail
end

local function hintsSummary(hints): string
	if hints == nil or #hints == 0 then
		return "-"
	end
	return table.concat(hints, "|")
end

local function maximizeCampaignActive(): boolean
	return workspace:GetAttribute("AutoTrack_MaximizeCampaignActive") == true
end

local function shouldRunChallengeUp(request, result, enduranceBuildActiveOverride: boolean?): (boolean, string?)
	if result == nil or result.score == nil then
		return false, "no_score"
	end
	if maximizeCampaignActive() then
		return false, "maximize_campaign"
	end
	local enduranceBuildActive = if enduranceBuildActiveOverride ~= nil
		then enduranceBuildActiveOverride
		else OrchestratorAgent.isActive()
	if enduranceBuildActive then
		return false, "endurance_orchestrated"
	end

	for _, q in ipairs(request.qualifiers) do
		if q == "extreme" then
			return true, nil
		end
	end
	return false, "not_extreme"
end

local function shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return result.failure ~= nil
		and result.failure.sector_id ~= targetSectorId
		and result.metrics.target_exited ~= true
end

local function attemptLimitForResult(result, targetSectorId: number): number
	if result.failure ~= nil
		and result.failure.sector_id == targetSectorId
		and (result.metrics.target_progress or 0) >= 0.5 then
		return Constants.MAX_REPAIR_ATTEMPTS + Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS
	end
	return Constants.MAX_REPAIR_ATTEMPTS
end

local function stateSummary(state): string
	if state.mechanic ~= nil then
		return tostring(state.mechanic)
	end
	if state.pads.ingress ~= "None" or state.pads.egress ~= "None" then
		return string.format("pads ingress=%s egress=%s", state.pads.ingress, state.pads.egress)
	end
	return "flat"
end

local function compactStateDetails(state): string
	if state.mechanic == nil then
		return string.format("flat ingress=%s egress=%s", state.pads.ingress, state.pads.egress)
	end
	local parts = {}
	for _, lever in ipairs(LevelMappings.NUMERIC_LEVERS[state.mechanic] or {}) do
		local value = state.params[lever]
		if type(value) == "number" then
			table.insert(parts, string.format("%s=%s", lever, tostring(value)))
		end
	end
	table.insert(parts, string.format("ingress=%s", state.pads.ingress))
	table.insert(parts, string.format("egress=%s", state.pads.egress))
	return string.format("%s {%s}", tostring(state.mechanic), table.concat(parts, ", "))
end

local function metricsSummary(metrics): string
	return string.format(
		"entry=%.1f exit=%.1f progress=%.2f reacq=%s apex=%.1f air=%.1f slow=%.2f",
		metrics.entry_speed or 0,
		metrics.exit_speed or 0,
		metrics.target_progress or 0,
		boolString(metrics.target_reacquired == true),
		metrics.target_apex_min_speed or 0,
		metrics.target_airtime_distance or 0,
		metrics.slowdown_ratio or 0
	)
end

local function downstreamDiagnostics(targetSectorId: number, failureSector: number?)
	if failureSector == nil or failureSector == targetSectorId then
		return nil
	end
	local downstreamState = SectorRegistry.getCommitted(failureSector)
	if downstreamState == nil or downstreamState.mechanic == nil then
		return nil
	end
	return {
		downstream_sector_state = cloneState(downstreamState),
	}
end

local function finishRevert(job, targetSector, reason)
	SectorRollback.revert(job.request.parsed.sector_id, targetSector.entry, targetSector.exit)
	job.final_status = "reverted"
	Tracer.log(reason or string.format("revert sector=%d attempts=%d", job.request.parsed.sector_id, #job.attempts))
	Tracer.log(string.format("job_end id=%s status=reverted", job.job_id))
	UIState.appendLog("Reverted target sector")
	UIState.publishRevert()
	_lastJob = job
end

local function buildHotfixDemoState(priorVersion: number)
	return {
		sector_id = 3,
		mechanic = "RampJump",
		params = {
			ramp_angle = 60,
			ramp_length = 40,
			gap_length = 40,
			landing_length = 4,
		},
		pads = {
			ingress = "Boost50",
			egress = "None",
		},
		version = priorVersion + 1,
	}
end

local function pauseForUI()
	task.wait(Constants.UI_PHASE_DELAY)
end

local function failureBannerText(result): string
	local failureType = result and result.failure and result.failure.type or "system_failure"
	if failureType == "mechanic_integrity_failure" then
		return "INTEGRITY FAIL"
	elseif failureType == "local_execution_failure" then
		return "TRAVERSAL FAIL"
	elseif failureType == "downstream_failure" then
		return "DOWNSTREAM FAIL"
	end
	return "SYSTEM FAIL"
end

local function pauseOnFailure(result)
	UIState.showFailureBanner(failureBannerText(result))
	local ok = pcall(function()
		VerifierCar.freeze()
	end)
	task.wait(Constants.UI_FAILURE_DWELL)
	if ok then
		pcall(function()
			VerifierCar.thaw()
		end)
	end
	UIState.hideFailureBanner()
end

local function parseSlashCommand(normalized: string): (string?, string?)
	local command, rest = string.match(normalized, "^/([%a_]+)%s*(.-)%s*$")
	if not command then
		return nil, nil
	end
	return command, rest
end

local function activeDemoReason(targetCommand: string?): string
	local preset = CameraDemo.activePreset()
	if targetCommand and targetCommand ~= "" then
		return string.format("demo '%s' is running; stop it before %s", preset, targetCommand)
	end
	return string.format("demo '%s' is running; use /demo %s to toggle it off", preset, preset)
end

local function captureHUDDemoSnapshot()
	local folder = UIState.getStateFolder()
	local snapshot = {}
	for _, attr in ipairs(HUD_DEMO_ATTRS) do
		snapshot[attr] = folder:GetAttribute(attr)
	end
	return snapshot
end

local function restoreHUDDemo()
	if _hudDemoSnapshot == nil then
		_hudDemoActive = nil
		return
	end

	local folder = UIState.getStateFolder()
	for _, attr in ipairs(HUD_DEMO_ATTRS) do
		folder:SetAttribute(attr, _hudDemoSnapshot[attr])
	end
	_hudDemoSnapshot = nil
	_hudDemoActive = nil
end

local function applyHUDDemo(kind: string)
	local folder = UIState.getStateFolder()

	if _hudDemoActive == kind then
		restoreHUDDemo()
		return true, nil
	end

	if _hudDemoActive ~= nil then
		restoreHUDDemo()
	end

	_hudDemoSnapshot = captureHUDDemoSnapshot()
	_hudDemoActive = kind

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

	return false, "unknown HUD demo"
end

-- Submit a plain-text request.  Returns false + reason if rejected without running.
function JobRunner.submit(rawText: string, requestOverride: Request?): (boolean, string?)
	local sm = JobStateMachine.new()
	local requestId = nextId("req")
	local trimmed = trim(rawText)
	local lowered = string.lower(trimmed)
	local slashCommand, slashArg = nil, nil
	local traceOwnedByThisJob = false
	local request = requestOverride

	if requestOverride == nil then
		slashCommand, slashArg = parseSlashCommand(lowered)
	end

		if requestOverride == nil and slashCommand == "demo" then
			if slashArg == "repair" or slashArg == "llmerror" or slashArg == "ui-hotfix" then
				if CameraDemo.isActive() then
					local reason = activeDemoReason("/demo " .. slashArg)
					UIState.rejectRequest(rawText, reason)
					return false, reason
				end
				if JobLock.isHeld() or MaximizerAgent.isActive() or OrchestratorAgent.isActive() or HotfixAgent.isActive() then
					UIState.rejectRequest(rawText, "track is busy; try again shortly")
					return false, "track is busy; try again shortly"
				end
				return applyHUDDemo(slashArg)
			end

			if slashArg == "camera" or slashArg == "rampitup" then
				if CameraDemo.isActive() then
					if CameraDemo.activePreset() == slashArg then
					return CameraDemo.stop()
				end
				local activePreset = CameraDemo.activePreset()
				local reason = string.format("demo '%s' is running; stop it before /demo %s", activePreset, slashArg)
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			return CameraDemo.start({ preset = slashArg })
		end

		if slashArg == "crest" then
			if CameraDemo.isActive() then
				local reason = activeDemoReason("/demo crest")
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			return JobRunner.submit("add a crest in sector 3")
		end

		if slashArg == "maximize" then
			if CameraDemo.isActive() then
				local reason = activeDemoReason("/demo maximize")
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			if MaximizerAgent.isActive() then
				UIState.rejectRequest(rawText, "maximizer already running")
				return false, "maximizer already running"
			end
			task.spawn(function()
				MaximizerAgent.run({
					submit = JobRunner.submit,
					isBusy = JobRunner.isBusy,
					isCameraDemoActive = CameraDemo.isActive,
				})
			end)
			return true, nil
		end

		if slashArg == "endurance" then
			if CameraDemo.isActive() then
				local reason = activeDemoReason("/demo endurance")
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			if OrchestratorAgent.isActive() then
				UIState.rejectRequest(rawText, "endurance mode already running")
				return false, "endurance mode already running"
			end
			task.spawn(function()
				OrchestratorAgent.run({
					submitDesignIntent = function(designIntent, text: string)
						_allowEnduranceInternalSubmit = true
						local callOk, submitOk, submitReason = pcall(JobRunner.submitEnduranceDesignIntent, designIntent, text)
						_allowEnduranceInternalSubmit = false
						if not callOk then
							return false, tostring(submitOk)
						end
						return submitOk, submitReason
					end,
					submit = function(text: string)
						_allowEnduranceInternalSubmit = true
						local callOk, submitOk, submitReason = pcall(JobRunner.submit, text)
						_allowEnduranceInternalSubmit = false
						if not callOk then
							return false, tostring(submitOk)
						end
						return submitOk, submitReason
					end,
					getLastJob = JobRunner.getLastJob,
					isCameraDemoActive = CameraDemo.isActive,
				})
			end)
			return true, nil
		end

		if slashArg == "extreme" then
			if CameraDemo.isActive() then
				local reason = activeDemoReason("/demo extreme")
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			-- Toggle off: restore prior states
			if _extremeDemoActive then
				_extremeDemoActive = false
				if not JobLock.isHeld() then
					assert(JobLock.tryAcquire(), "JobLock busy restoring extreme demo")
					local extremeIds = { 2, 3, 7 }
					for _, id in ipairs(extremeIds) do
						local saved = _extremePriorStates[id]
						if saved then
							local restored = cloneState(saved)
							restored.version = saved.version + 2
							local sector = RuntimeContext.getSectorById(id)
							SectorApplier.apply(restored, sector.entry, sector.exit)
							SectorRegistry.commit(restored)
						end
					end
					_extremePriorStates = {}
					JobLock.release()
					UIState.publishReady()
					UIState.appendLog("Extreme demo off — prior track state restored")
					Tracer.log("extreme_demo_restored")
				else
					UIState.rejectRequest(rawText, "track is busy; try again shortly")
					_extremeDemoActive = true
					return false, "track is busy; try again shortly"
				end
				return true, nil
			end
			-- Toggle on: apply extreme geometry for inspection
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			assert(JobLock.tryAcquire(), "JobLock busy in /demo extreme")
			local extremeIds = { 2, 3, 7 }
			_extremePriorStates = {}
			for _, id in ipairs(extremeIds) do
				local committed = SectorRegistry.getCommitted(id)
				if committed then
					_extremePriorStates[id] = cloneState(committed)
				end
			end

			local function applyState(state)
				local sector = RuntimeContext.getSectorById(state.sector_id)
				SectorApplier.apply(state, sector.entry, sector.exit)
				SectorRegistry.commit(state)
			end

			local v2 = _extremePriorStates[2] and _extremePriorStates[2].version or 0
			local v3 = _extremePriorStates[3] and _extremePriorStates[3].version or 0
			local v7 = _extremePriorStates[7] and _extremePriorStates[7].version or 0

			applyState({
				sector_id = 2,
				mechanic = nil,
				params = {},
				pads = { ingress = "Boost50", egress = "None" },
				version = v2 + 1,
			})
			local rjDefaults = LevelMappings.DEFAULTS.RampJump
			applyState({
				sector_id = 3,
				mechanic = "RampJump",
				params = {
					ramp_angle = LevelMappings.LEVER_BOUNDS.RampJump.ramp_angle.max,
					ramp_length = rjDefaults.ramp_length,
					gap_length = LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max,
					landing_length = rjDefaults.landing_length,
				},
				pads = { ingress = "None", egress = "None" },
				version = v3 + 1,
			})
			local cdDefaults = LevelMappings.DEFAULTS.CrestDip
			applyState({
				sector_id = 7,
				mechanic = "CrestDip",
				params = {
					height_or_depth = LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max,
					radius = cdDefaults.radius,
					sector_length = cdDefaults.sector_length,
				},
				pads = { ingress = "None", egress = "None" },
				version = v7 + 1,
			})

			JobLock.release()
			_extremeDemoActive = true

			UIState.setPhase("ExtremeDemo", "Extreme demo active — inspect the track")
			UIState.appendLog(string.format(
				"Extreme demo ON: Sector 2 Boost50 ingress | Sector 3 RampJump angle=%d gap=%d | Sector 7 CrestDip height=%d",
				LevelMappings.LEVER_BOUNDS.RampJump.ramp_angle.max,
				LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max,
				LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth.max))
			UIState.setExplanation("Submit '/demo extreme' again to restore the track")
			Tracer.log("extreme_demo_applied")
			return true, nil
		end

		if slashArg == "hotfix" then
			if CameraDemo.isActive() then
				local reason = activeDemoReason("/demo hotfix")
				UIState.rejectRequest(rawText, reason)
				return false, reason
			end
			if JobLock.isHeld() then
				UIState.rejectRequest(rawText, "track is busy; try again shortly")
				return false, "track is busy; try again shortly"
			end
			task.spawn(function()
				-- Step 1: commit a working sector 4 (chicane) as our "in-flight job" target
				-- Step 2: sabotage sector 3 with an impossible ramp so upstream failures trigger
				assert(JobLock.tryAcquire(), "JobLock busy in /demo hotfix setup")

				local sector3 = RuntimeContext.getSectorById(3)
				local priorSector3 = SectorRegistry.getCommitted(3)
				local priorVersion = priorSector3 and priorSector3.version or 0

				-- Force a real upstream execution failure. The earlier short-ramp
				-- sabotage became survivable after the phase-14 controller changes.
				local badState = buildHotfixDemoState(priorVersion)
				SectorApplier.apply(badState, sector3.entry, sector3.exit)
				SectorRegistry.commit(badState)

				JobLock.release()

				UIState.setPhase("HotfixDemo", "Hotfix demo: sector 3 sabotaged — submitting job to trigger upstream failure")
				UIState.appendLog("Hotfix demo: planted catastrophic RampJump in sector 3 (Boost50 ingress, angle=60, ramp=40, gap=40, landing=4)")
				UIState.appendLog("Submitting '" .. HOTFIX_DEMO_REQUEST .. "' — watch for retry → hotfix sequence...")
				UIState.setExplanation("HotfixAgent will detect sector 3 failure and attempt emergency repair")
				Tracer.log("hotfix_demo_sabotage sector=3")

				-- Submit a later-sector job so the sector-3 crash is always treated
				-- as an upstream failure by the retry/hotfix pipeline.
				task.wait(0.5)
				JobRunner.submit(HOTFIX_DEMO_REQUEST)
			end)
			return true, nil
		end

			UIState.rejectRequest(rawText, "unknown demo; supported: /demo camera, /demo rampitup, /demo repair, /demo llmerror, /demo ui-hotfix, /demo crest, /demo maximize, /demo endurance, /demo extreme, /demo hotfix")
			return false, "unknown demo; supported: /demo camera, /demo rampitup, /demo repair, /demo llmerror, /demo ui-hotfix, /demo crest, /demo maximize, /demo endurance, /demo extreme, /demo hotfix"
		end

	if requestOverride == nil and slashCommand == "llm" then
		local subcmd, rest2 = string.match(slashArg, "^(%S+)%s*(.-)%s*$")
		if subcmd == "on" then
			LLMConfig.setEnabled(true)
			local cfg = LLMConfig.get()
			UIState.setLLMConfig(true, cfg.modelId)
			UIState.appendLog("LLM enabled: " .. cfg.displayName)
			return true, nil
		elseif subcmd == "off" then
			LLMConfig.setEnabled(false)
			UIState.setLLMConfig(false, LLMConfig.get().modelId)
			UIState.appendLog("LLM disabled (heuristic)")
			return true, nil
		elseif subcmd == "model" then
			local modelId = rest2 or ""
			LLMConfig.setModel(modelId)
			local cfg = LLMConfig.get()
			UIState.setLLMConfig(cfg.enabled, cfg.modelId)
			UIState.appendLog("LLM model: " .. cfg.displayName)
			return true, nil
		end
		UIState.rejectRequest(rawText, "usage: /llm on | /llm off | /llm model <id>")
		return false, "usage: /llm on | /llm off | /llm model <id>"
	end

	if requestOverride == nil and slashCommand == "test" then
		if slashArg == "" then
			UIState.rejectRequest(rawText, "test name missing; use /test <suite>")
			return false, "test name missing; use /test <suite>"
		end
		if CameraDemo.isActive() then
			local reason = activeDemoReason("/test")
			UIState.rejectRequest(rawText, reason)
			return false, reason
		end
		if JobLock.isHeld() then
			UIState.rejectRequest(rawText, "track is busy; try again shortly")
			return false, "track is busy; try again shortly"
		end

		UIState.setBusy(true)
		UIState.setPhase("RunTest", "Running server-side test...")
		UIState.appendLog("Running /test " .. slashArg)
		local snapshot = TestDispatcher.runSuite(slashArg)
		UIState.setBusy(false)
		if snapshot.status == "passed" then
			UIState.setPhase("RunTest", "Test passed")
			UIState.appendLog(string.format("Suite %s passed (%d pass)", slashArg, snapshot.pass_count))
			return true, nil
		end
		UIState.setPhase("RunTest", "Test failed")
		UIState.setError("test failed: " .. slashArg)
		UIState.appendLog(string.format(
			"Suite %s %s (%d fail, %d error)",
			slashArg,
			tostring(snapshot.status),
			snapshot.fail_count,
			snapshot.error_count
		))
		return false, "test failed: " .. slashArg
	end

	if CameraDemo.isActive() then
		local reason = activeDemoReason(nil)
		UIState.rejectRequest(rawText, reason)
		return false, reason
	end

	if OrchestratorAgent.isActive() and not _allowEnduranceInternalSubmit then
		UIState.rejectRequest(rawText, "endurance mode owns the session; restart or wait for it to finish")
		return false, "endurance mode owns the session; restart or wait for it to finish"
	end

	if JobLock.isHeld() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		UIState.rejectRequest(rawText, "track is busy; try again shortly")
		return false, "track is busy; try again shortly"
	end

	sm:transition("ParseRequest")
	if request == nil then
		local parseErr
		request, parseErr = RequestParser.parse(rawText, requestId)
		if not request then
			Tracer.log(string.format("job_reject reason=%s raw=%q", tostring(parseErr), rawText))
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, tostring(parseErr))
			return false, parseErr
		end
	end

	if not JobLock.tryAcquire() then
		Tracer.log(string.format("job_reject reason=busy raw=%q", rawText))
		sm:transition("RejectRequest")
		sm:transition("Idle")
		UIState.rejectRequest(rawText, "track is busy; try again shortly")
		return false, "track is busy; try again shortly"
	end

	if not _allowEnduranceInternalSubmit then
		LLMTraceJournal.beginRun({
			owner = "job_runner",
			mode = "single_job",
			job_id = request.request_id,
			request_id = request.request_id,
			raw_text = rawText,
			target_sector_id = request.parsed.sector_id,
			request_kind = request.parsed.request_kind,
			mechanic = request.parsed.mechanic,
			origin = request.origin,
			design_intent = request.design_intent,
		})
		traceOwnedByThisJob = true
	end

	local ok, resultOrErr, reason = pcall(function()
		assert(RuntimeContext.isReady(), "runtime context not ready")

		sm:transition("AcquireTrack")
		local targetSectorId = request.parsed.sector_id
		local targetSector = RuntimeContext.getSectorById(targetSectorId)
		local priorCommitted = SectorRegistry.getCommitted(targetSectorId)
		assert(priorCommitted ~= nil, "no committed sector state for " .. tostring(targetSectorId))

		Tracer.log(string.format(
			"job_start id=%s sector=%d mechanic=%s",
			request.request_id,
			targetSectorId,
			requestSummary(request.parsed)
		))
		UIState.beginJob(request)
		UIState.setPhase("AcquireTrack", "Preparing job")
		UIState.appendLog(string.format("Queued %s for sector %d", requestSummary(request.parsed), targetSectorId))
		pauseForUI()

		sm:transition("GenerateInitialProposal")
		UIState.setPhase("GenerateInitialProposal", "Generating proposal...")
		local initialState, proposalErr = LLMAdapter.propose(request, request.design_intent)
		if not initialState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, tostring(proposalErr))
			return false, proposalErr
		end

		local validState, validationErr = ActionValidator.validateSectorState(initialState)
		if not validState then
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, "invalid initial proposal: " .. tostring(validationErr))
			return false, "invalid initial proposal: " .. tostring(validationErr)
		end
		UIState.appendLog("Initial proposal accepted")
		UIState.appendLog("Proposal: " .. compactStateDetails(initialState))
		Tracer.log(string.format(
			"proposal sector=%d state=%s",
			targetSectorId,
			compactStateDetails(initialState)
		))

		local job: CIJob = {
			job_id = request.request_id,
			request = request,
			initial_state = cloneState(initialState),
			working_state = cloneState(initialState),
			attempts = {},
			final_status = "reverted",
		}

		local nextAction = nil
		local attemptIndex = 0
		local lastAction = nil
		local upstreamFailCount = 0
		local upstreamFailSectorId: number? = nil

		while true do
			sm:transition("ApplyWorkingSector")
			UIState.setPhase("ApplyWorkingSector", "Applying sector...")
			UIState.setAttempt(attemptIndex, Constants.MAX_REPAIR_ATTEMPTS)
			pauseForUI()
			sm:transition("RunVerification")
			UIState.setPhase("RunVerification", "Running simulation...")
			Tracer.log(string.format(
				"attempt index=%d sector=%d mechanic=%s",
				attemptIndex,
				targetSectorId,
				stateSummary(job.working_state)
			))

			local proposedState = cloneState(job.working_state)
			local result, hints, updatedState = AttemptRunner.run({
				workingState = job.working_state,
				action = nextAction,
				targetSectorId = targetSectorId,
				entryFrame = targetSector.entry,
				exitFrame = targetSector.exit,
				sectors = RuntimeContext.getSectors(),
				car = RuntimeContext.getCar(),
				canonicalStart = RuntimeContext.getCanonicalStart(),
				onSectorChange = function(id: number, entering: boolean)
					if entering then
						UIState.setCurrentSector(id)
					end
				end,
			})

			job.working_state = cloneState(updatedState)
			UIState.publishAttemptResult(result)
			table.insert(job.attempts, {
				attempt_index = attemptIndex,
				action = nextAction,
				proposed_state = proposedState,
				result = result,
				hints = hints,
			})
			Tracer.log(string.format(
				"attempt_result index=%d target_sector=%d success=%s failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f score=%s",
				attemptIndex,
				targetSectorId,
				boolString(result.success),
				tostring(result.failure and result.failure.type or "none"),
				tostring(result.failure and result.failure.sector_id or "-"),
				failureDetail(result),
				boolString(result.metrics.target_entered == true),
				boolString(result.metrics.target_exited == true),
				result.metrics.target_progress or 0,
				tostring(result.score and result.score.total or "-")
			))

			sm:transition("EvaluateResult")
			if result.success then
				sm:transition("Commit")
				job.working_state.version = priorCommitted.version + 1
				SectorRegistry.commit(job.working_state)
				UIState.setSectorMechanic(targetSectorId, job.working_state.mechanic)
				job.final_status = "committed"
				UIState.setPhase("Commit", "Committed")
				UIState.appendLog(string.format("Committed %s v%d", stateSummary(job.working_state), job.working_state.version))
				if result.score then
					UIState.publishScore(targetSectorId, result.score)
					UIState.appendLog(string.format(
						"Score %.1f (air %.1f lat %.1f near %.1f cost %.1f budget %.0f%%%s)",
						result.score.total,
						result.score.air,
						result.score.lateral,
						result.score.near_miss,
						result.score.time_cost,
						result.score.budget_used * 100,
						if result.score.over_budget then " OVER" else ""
					))
				end
				pauseForUI()

				-- Phase 11b Stage B: opt-in challenge-up via the "extreme"
				-- qualifier. We already committed the minimum-valid state, so
				-- a failure here just stops escalation — the commit stands.
				local wantsChallengeUp, challengeSkipReason = shouldRunChallengeUp(request, result)
				if wantsChallengeUp then
					UIState.setPhase("ChallengeUp", "Challenging up...")
					UIState.appendLog("Escalating for extreme qualifier")
					local bestState, bestResult, rounds = ChallengeRunner.runUp({
						baseState = job.working_state,
						baseResult = result,
						targetSectorId = targetSectorId,
						targetSector = targetSector,
						sectors = RuntimeContext.getSectors(),
						car = RuntimeContext.getCar(),
						canonicalStart = RuntimeContext.getCanonicalStart(),
						onSectorChange = function(id, entering)
							if entering then UIState.setCurrentSector(id) end
						end,
						onRound = function(round, attempt, improved, reason)
							if attempt then
								UIState.appendLog(string.format(
									"Escalate r%d %s %s→%s %s%s",
									round,
									attempt.lever,
									tostring(attempt.from),
									tostring(attempt.to),
									if improved then "ACCEPT" else "REJECT",
									reason and (" (" .. reason .. ")") or ""
								))
							elseif reason then
								UIState.appendLog("Escalate stopped: " .. reason)
							end
						end,
					})
					if bestResult and bestResult.score and bestResult ~= result then
						bestState.version = job.working_state.version + 1
						SectorRegistry.commit(bestState)
						UIState.setSectorMechanic(targetSectorId, bestState.mechanic)
						job.working_state = cloneState(bestState)
						UIState.publishScore(targetSectorId, bestResult.score)
						UIState.appendLog(string.format(
							"Escalated in %d rounds → score %.1f (was %.1f)",
							rounds, bestResult.score.total, result.score.total
						))
						Tracer.log(string.format(
							"challenge_up sector=%d rounds=%d score=%.2f->%.2f",
							targetSectorId, rounds, result.score.total, bestResult.score.total
						))
					else
						UIState.appendLog(string.format("Escalate produced no net improvement in %d rounds", rounds))
					end
					pauseForUI()
				else
					Tracer.log(string.format(
						"challenge_up_skip sector=%d reason=%s qualifiers=%s",
						targetSectorId,
						tostring(challengeSkipReason or "unknown"),
						qualifiersSummary(request.qualifiers)
					))
				end

				UIState.publishCommit(targetSector)
				Tracer.log(string.format("commit sector=%d version=%d", targetSectorId, job.working_state.version))
				Tracer.log(string.format("job_end id=%s status=committed", job.job_id))
				_lastJob = job
				sm:transition("Idle")
				return true, nil
			end

			sm:transition("AnalyzeFailure")
			UIState.setPhase("AnalyzeFailure", "Analyzing failure...")
			UIState.showFailure(result)
			pauseOnFailure(result)
			UIState.appendLog(string.format(
				"Failure: %s in sector %d",
				tostring(result.failure and result.failure.type or "unknown"),
				result.failure and result.failure.sector_id or targetSectorId
			))
			UIState.appendLog("Metrics: " .. metricsSummary(result.metrics))
			if #hints > 0 then
				UIState.appendLog("Hints: " .. table.concat(hints, " | "))
			end
			Tracer.log(string.format(
				"failure_analysis target_sector=%d failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f hints=%s",
				targetSectorId,
				tostring(result.failure and result.failure.type or "unknown"),
				tostring(result.failure and result.failure.sector_id or "-"),
				failureDetail(result),
				boolString(result.metrics.target_entered == true),
				boolString(result.metrics.target_exited == true),
				result.metrics.target_progress or 0,
				hintsSummary(hints)
			))
			pauseForUI()

			if shouldRevertPreTargetFailure(result, targetSectorId) then
				local failingSector = result.failure.sector_id
				if failingSector == upstreamFailSectorId then
					upstreamFailCount += 1
				else
					upstreamFailCount = 1
					upstreamFailSectorId = failingSector
				end

				if upstreamFailCount == 1 then
					-- First upstream failure: retry the same state once before deciding
					UIState.appendLog(string.format(
						"Upstream failure in committed sector %d — retrying lap",
						failingSector
					))
					Tracer.log(string.format(
						"upstream_retry sector=%d failure_sector=%d",
						targetSectorId, failingSector
					))
					sm:transition("ApplyRepair")
					nextAction = nil
					continue
				end

				-- Second consecutive failure at same committed sector: revert + queue + hotfix
				UIState.appendLog(string.format(
					"Upstream failure confirmed in sector %d — entering hotfix mode",
					failingSector
				))
				UIState.setHotfixActive(true, failingSector)
				UIState.setPhase("HotfixMode", string.format("HOTFIX MODE — Sector %d", failingSector))
				Tracer.log(string.format(
					"hotfix_trigger sector=%d failure_sector=%d",
					targetSectorId, failingSector
				))
				_pendingRequest = rawText
				finishRevert(
					job,
					targetSector,
					string.format(
						"revert sector=%d reason=upstream_hotfix failure_sector=%d",
						targetSectorId,
						failingSector
					)
				)
				local capturedFailResult = result
				local capturedFailSector = failingSector
				task.spawn(function()
					HotfixAgent.run(
						capturedFailSector,
						capturedFailResult,
						function() return _pendingRequest end,
						function() _pendingRequest = nil end,
						function(text) JobRunner.submit(text) end
					)
				end)
				sm:transition("Revert")
				sm:transition("Idle")
				return true, nil
			end

			upstreamFailCount = 0
			upstreamFailSectorId = nil

			local attemptLimit = attemptLimitForResult(result, targetSectorId)
			if attemptIndex >= attemptLimit then
				sm:transition("Revert")
				finishRevert(job, targetSector, string.format("revert sector=%d attempts=%d", targetSectorId, #job.attempts))
				sm:transition("Idle")
				return true, nil
			end

			local failureSector = if result.failure then result.failure.sector_id else targetSectorId
			local packet = LapEvaluator.buildFailurePacket(
				request,
				job.working_state,
				attemptIndex,
				lastAction,
				result,
				failureSector,
				hints,
				downstreamDiagnostics(targetSectorId, failureSector)
			)
			if packet.diagnostics.downstream_sector_state ~= nil then
				UIState.appendLog(string.format(
					"Downstream sector %d: %s",
					packet.diagnostics.downstream_sector_state.sector_id,
					tostring(packet.diagnostics.downstream_sector_state.mechanic)
				))
			end

			sm:transition("ApplyRepair")
			UIState.setPhase("ApplyRepair", "Applying repair...")
			local action, newState, explanation, repairErr = LLMAdapter.repair(packet, job.attempts, packet.design_intent)
			if repairErr then
				UIState.setError("LLM error: " .. repairErr)
				UIState.appendLog("LLM error: " .. repairErr)
				Tracer.log("llm_error attempt=" .. attemptIndex .. " err=" .. repairErr)
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=llm_error")
				sm:transition("Idle")
				return true, nil
			end

			if newState then
				-- LLM returned a full revised SectorState (no delta action)
				job.working_state = cloneState(newState)
				lastAction = nil
				nextAction = nil
				attemptIndex += 1
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction("LLM: full state revision")
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d (LLM): %s", attemptIndex, explanation or "revised state"))
				UIState.appendLog("Revised: " .. compactStateDetails(job.working_state))
				pauseForUI()
				Tracer.log(string.format(
					"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s path=llm_full_state explanation=%s",
					attemptIndex, targetSectorId, failureSector, failureDetail(result), explanation or "-"
				))
			elseif action then
				-- Heuristic returned a delta action
				local actionOk, actionErr = ActionValidator.validateAction(action, job.working_state.mechanic)
				if not actionOk then
					sm:transition("Revert")
					finishRevert(job, targetSector, "revert reason=" .. tostring(actionErr))
					sm:transition("Idle")
					return true, nil
				end
				lastAction = action
				nextAction = action
				attemptIndex += 1
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction(repairActionLabel(action))
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d: %s", attemptIndex, explanation or "repair"))
				UIState.appendLog("Action: " .. repairActionLabel(action))
				pauseForUI()
				Tracer.log(string.format(
					"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f action=%s explanation=%s",
					attemptIndex, targetSectorId, failureSector, failureDetail(result),
					boolString(result.metrics.target_entered == true),
					boolString(result.metrics.target_exited == true),
					result.metrics.target_progress or 0,
					actionSummary(action), explanation or "repair"
				))
			else
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=empty_repair")
				sm:transition("Idle")
				return true, nil
			end
		end
	end)

	JobLock.release()
	if traceOwnedByThisJob then
		local latestJob = _lastJob
		local summary = {
			outcome = if ok then if resultOrErr then "handled" else "rejected" else "system_failure",
			request_id = request.request_id,
			job_id = request.request_id,
			target_sector_id = request.parsed.sector_id,
			message = if ok and resultOrErr == false then tostring(reason or resultOrErr) else nil,
		}
		if ok and latestJob ~= nil and latestJob.job_id == request.request_id then
			summary.outcome = latestJob.final_status
			summary.final_status = latestJob.final_status
			summary.attempt_count = #latestJob.attempts
			summary.mechanic = latestJob.working_state and latestJob.working_state.mechanic or nil
		elseif not ok then
			summary.message = tostring(resultOrErr)
		elseif resultOrErr == false then
			summary.message = tostring(reason)
		end
		LLMTraceJournal.finishRun(summary)
	end
	if not ok then
		local err = tostring(resultOrErr)
		UIState.setBusy(false)
		UIState.setError("system failure: " .. err)
		if request then
			local targetSector = RuntimeContext.isReady() and RuntimeContext.getSectorById(request.parsed.sector_id) or nil
			if targetSector and _lastJob and _lastJob.job_id == request.request_id and _lastJob.final_status == "reverted" then
				return false, "system failure: " .. err
			end
			if targetSector then
				SectorRollback.revert(request.parsed.sector_id, targetSector.entry, targetSector.exit)
			end
		end
		return false, "system failure: " .. err
	end

	return resultOrErr, reason
end

function JobRunner.submitEnduranceDesignIntent(designIntent: DesignIntent, rawText: string): (boolean, string?)
	local validIntent, intentErr = validateDesignIntent(designIntent)
	if not validIntent then
		UIState.rejectRequest(rawText, tostring(intentErr))
		return false, intentErr
	end
	local request = buildEnduranceRequest(nextId("req"), rawText, designIntent)
	return JobRunner.submit(rawText, request)
end

-- Returns true if a job is currently running.
function JobRunner.isBusy(): boolean
	return JobLock.isHeld()
end

function JobRunner.getPendingRequest(): string?
	return _pendingRequest
end

function JobRunner.clearPendingRequest()
	_pendingRequest = nil
end

function JobRunner.getLastJob(): CIJob?
	return _lastJob
end

function JobRunner._shouldRunChallengeUp(request, result, enduranceBuildActiveOverride: boolean?)
	return shouldRunChallengeUp(request, result, enduranceBuildActiveOverride)
end

function JobRunner._shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return shouldRevertPreTargetFailure(result, targetSectorId)
end

function JobRunner._attemptLimitForResult(result, targetSectorId: number): number
	return attemptLimitForResult(result, targetSectorId)
end

function JobRunner._buildEnduranceRequest(designIntent: DesignIntent, rawText: string, requestId: string?): Request
	return buildEnduranceRequest(requestId or nextId("req"), rawText, designIntent)
end

return JobRunner
