-- JobRunner.luau
-- Top-level CI job runner.  Drives the full propose → verify → repair → commit/revert loop.
-- prd_plan.md §7, Phase 6
--
-- Entry point: JobRunner.submit(rawText)
-- There is exactly one global job lock — concurrent submissions are rejected immediately.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorRollback = require(script.Parent.Parent.Track.SectorRollback)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local AttemptRunner = require(script.Parent.AttemptRunner)
local JobStateMachine = require(script.Parent.JobStateMachine)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local UIState = require(script.Parent.UIState)
local CommandRouter = require(script.Parent.CommandRouter)
local CameraDemo = require(script.Parent.CameraDemo)
local TuneMode = require(script.Parent.TuneMode)
local ChallengeRunner = require(script.Parent.ChallengeRunner)
local HotfixAgent = require(script.Parent.HotfixAgent)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local EnduranceMemory = require(script.Parent.EnduranceMemory)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)

type CIJob = Types.CIJob
type Request = Types.Request
type DesignIntent = Types.DesignIntent
type ChallengeUpContext = Types.ChallengeUpContext
type MemoryEntry = Types.MemoryEntry
type RunMemory = Types.RunMemory
type SectorState = Types.SectorState
type RunResult = Types.RunResult
type VerificationStage = "lap" | "isolated" | "commit_lap"
type VerificationProfileResult = {
	result: RunResult,
	hints: { string },
	updated_state: SectorState,
	verification_stage: VerificationStage,
	run_scope: "lap" | "isolated_sector",
	isolated_passes_required: number?,
	isolated_passes_completed: number?,
}

local JobRunner = {}
local _lastJob: CIJob? = nil
local _idCounter = 0
local _pendingRequest: string? = nil
local _allowEnduranceInternalSubmit = false
local pauseForUI
local pauseOnFailure

local function nextId(prefix: string): string
	_idCounter += 1
	return string.format("%s-%03d", prefix, _idCounter)
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

local function truncateText(value: string, maxLen: number): string
	if #value <= maxLen then
		return value
	end
	return string.sub(value, 1, maxLen)
end

local function cloneState(state)
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = table.clone(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function isEnduranceVerificationProfileEnabled(request: Request): boolean
	return request.origin == "endurance"
end

local function runVerificationProfile(args): VerificationProfileResult
	local runAttempt = args.runAttempt
	local onStageStart = args.onStageStart
	local onStageResult = args.onStageResult
	local useIsolatedProfile = args.use_isolated_profile == true
	local isolatedPassesRequired = math.max(1, Constants.ENDURANCE_ISOLATED_PASSES or 3)

	local workingState = cloneState(args.working_state)
	local nextAction = args.action

	if useIsolatedProfile then
		for passIndex = 1, isolatedPassesRequired do
			if onStageStart then
				onStageStart("isolated", passIndex, isolatedPassesRequired)
			end
			local result, hints, updatedState = runAttempt("isolated_sector", workingState, nextAction)
			workingState = cloneState(updatedState)
			nextAction = nil

			if onStageResult then
				onStageResult("isolated", "isolated_sector", passIndex, isolatedPassesRequired, result, hints)
			end

			if not result.success then
				return {
					result = result,
					hints = hints,
					updated_state = workingState,
					verification_stage = "isolated",
					run_scope = "isolated_sector",
					isolated_passes_required = isolatedPassesRequired,
					isolated_passes_completed = passIndex,
				}
			end
		end
	end

	local lapStage: VerificationStage = if useIsolatedProfile then "commit_lap" else "lap"
	if onStageStart then
		onStageStart(lapStage, 1, 1)
	end

	local result, hints, updatedState = runAttempt("full_lap", workingState, nextAction)
	workingState = cloneState(updatedState)

	if onStageResult then
		onStageResult(lapStage, "lap", 1, 1, result, hints)
	end

	return {
		result = result,
		hints = hints,
		updated_state = workingState,
		verification_stage = lapStage,
		run_scope = "lap",
		isolated_passes_required = if useIsolatedProfile then isolatedPassesRequired else nil,
		isolated_passes_completed = if useIsolatedProfile then isolatedPassesRequired else nil,
	}
end

local function cloneMemory(memory: RunMemory?): RunMemory?
	if memory == nil then
		return nil
	end
	return EnduranceMemory.clone(memory)
end

local function ensureRequestMemory(request: Request): RunMemory?
	if request.origin ~= "endurance" then
		return request.memory_context
	end
	if request.memory_context == nil then
		request.memory_context = EnduranceMemory.new()
	end
	return request.memory_context
end

local function appendRequestMemory(request: Request, scopeName: string, note: MemoryEntry?)
	if note == nil then
		return
	end
	local memory = ensureRequestMemory(request)
	if memory == nil then
		return
	end
	EnduranceMemory.append(memory, scopeName, note)
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

local function buildEnduranceRequest(
	requestId: string,
	rawText: string,
	designIntent: DesignIntent,
	memoryContext: RunMemory?
): Request
	return ContractBuilders.enduranceMechanicRequest({
		request_id = requestId,
		raw_text = trim(rawText),
		qualifiers = extractIntentQualifiers(designIntent.params_hint),
		design_intent = designIntent,
		memory_context = cloneMemory(memoryContext),
		timestamp = os.time(),
	})
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

local ENDURANCE_CHALLENGE_UP_SCORE_FLOORS = {
	low = 4.0,
	medium = 6.0,
	high = 8.5,
	extreme = 10.5,
}

local RAMPJUMP_REPAIR_SCORE_FLOORS = {
	low = Constants.RAMPJUMP_REPAIR_SCORE_FLOOR_MEDIUM,
	medium = Constants.RAMPJUMP_REPAIR_SCORE_FLOOR_MEDIUM,
	high = Constants.RAMPJUMP_REPAIR_SCORE_FLOOR_HIGH,
	extreme = Constants.RAMPJUMP_REPAIR_SCORE_FLOOR_EXTREME,
}

local function challengeUpScoreFloor(intent: DesignIntent?): number
	if intent == nil then
		return ENDURANCE_CHALLENGE_UP_SCORE_FLOORS.medium
	end
	return ENDURANCE_CHALLENGE_UP_SCORE_FLOORS[intent.target_score_band] or ENDURANCE_CHALLENGE_UP_SCORE_FLOORS.medium
end

local function scoreBandForRequest(request: Request): string
	local intent = request.design_intent
	if intent ~= nil and DESIGN_INTENT_SCORE_BANDS[intent.target_score_band] then
		return intent.target_score_band
	end
	for _, qualifier in ipairs(request.qualifiers or {}) do
		if qualifier == "extreme" then
			return "extreme"
		end
	end
	return "medium"
end

local function rampJumpRepairScoreFloorForRequest(request: Request): number
	return RAMPJUMP_REPAIR_SCORE_FLOORS[scoreBandForRequest(request)] or Constants.RAMPJUMP_REPAIR_SCORE_FLOOR_MEDIUM
end

local function evaluateRampJumpRepairScoreRetention(
	request: Request,
	attemptIndex: number,
	priorBestSuccessfulScore: number?,
	result
): (boolean, number, string?)
	if attemptIndex <= 0 then
		return true, 0, nil
	end
	if result == nil or result.score == nil then
		return true, 0, nil
	end
	local currentScore = result.score.total or 0
	local floor = rampJumpRepairScoreFloorForRequest(request)
	local retentionTarget = (priorBestSuccessfulScore or 0) * Constants.RAMPJUMP_REPAIR_SCORE_RETENTION
	local requiredScore = math.max(floor, retentionTarget)
	if currentScore >= requiredScore then
		return true, requiredScore, nil
	end
	return false,
		requiredScore,
		string.format("RampJump retained %.1f but requires %.1f to avoid neutral repair", currentScore, requiredScore)
end

local function budgetHeadroom(result): number
	if result == nil or result.score == nil then
		return 0
	end
	return math.max(0, 1 - (result.score.budget_used or 0))
end

local function buildChallengeUpReason(intent: DesignIntent, result, scoreFloor: number): string
	return string.format(
		"clean pass scored %.1f with %.0f%% budget headroom, below the %s target floor of %.1f",
		result.score.total or 0,
		budgetHeadroom(result) * 100,
		tostring(intent.target_score_band),
		scoreFloor
	)
end

local function isHighEnergyRampJumpState(state): boolean
	if state == nil or state.mechanic ~= "RampJump" then
		return false
	end
	local bounds = LevelMappings.LEVER_BOUNDS.RampJump
	local params = state.params or {}
	local angle = params.ramp_angle or 0
	local rampLength = params.ramp_length or 0
	local gapLength = params.gap_length or 0
	local ingressDelta = PadValueUtils.speedDelta(tostring(state.pads and state.pads.ingress or "None"))
	local highAngle = angle >= (bounds.ramp_angle.max - 2)
	local highRampLength = rampLength >= (bounds.ramp_length.max - 8)
	local highGap = gapLength >= (bounds.gap_length.max - 6)
	local highIngressBoost = ingressDelta >= 25
	return highAngle and highRampLength and highGap and highIngressBoost
end

local function shouldRunChallengeUp(
	request,
	result,
	enduranceBuildActiveOverride: boolean?,
	commitAttemptIndex: number?,
	committedState
): (boolean, string?, string?)
	if result == nil or result.score == nil then
		return false, "no_score", nil
	end
	local enduranceBuildActive = if enduranceBuildActiveOverride ~= nil
		then enduranceBuildActiveOverride
		else OrchestratorAgent.isActive()
	local designIntent = request.design_intent
	if request.origin == "endurance" or enduranceBuildActive then
		if designIntent == nil then
			return false, "no_design_intent", nil
		end
		if result.score.over_budget then
			return false, "over_budget", nil
		end
		if designIntent.target_reliability == "conservative" then
			return false, "conservative_target", nil
		end
		if designIntent.mechanic == "RampJump" or (committedState and committedState.mechanic == "RampJump") then
			if (commitAttemptIndex or 0) > 0 then
				return false, "rampjump_repaired_success", nil
			end
			if isHighEnergyRampJumpState(committedState) then
				return false, "rampjump_already_high_energy", nil
			end
		end
		local headroom = budgetHeadroom(result)
		if headroom < Constants.ENDURANCE_CHALLENGE_UP_MIN_HEADROOM then
			return false, "low_budget_headroom", nil
		end
		local scoreFloor = challengeUpScoreFloor(designIntent)
		local undershotIntent = (result.score.total or 0) < scoreFloor
		local strongPushIntent = designIntent.target_reliability == "risky"
			or designIntent.target_score_band == "high"
			or designIntent.target_score_band == "extreme"
			or designIntent.spectacle_priority == "high"
		if designIntent.target_reliability == "risky" then
			return true, nil, "proposal_do_over"
		end
		if undershotIntent then
			return true, nil, "proposal_do_over"
		end
		if strongPushIntent and headroom >= Constants.ENDURANCE_CHALLENGE_UP_HIGH_HEADROOM then
			return true, nil, "proposal_do_over"
		end
		return false, "already_aggressive_enough", nil
	end

	for _, q in ipairs(request.qualifiers) do
		if q == "extreme" then
			return true, nil, "deterministic_escalation"
		end
	end
	return false, "not_extreme", nil
end

local function shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return result.failure ~= nil and result.failure.sector_id ~= targetSectorId and result.metrics.target_exited ~= true
end

local function attemptLimitForResult(result, targetSectorId: number): number
	if
		result.failure ~= nil
		and result.failure.sector_id == targetSectorId
		and (result.metrics.target_progress or 0) >= 0.5
	then
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

local function invalidAgentResponseWarning(errText: string?): string?
	local message = trim(tostring(errText or ""))
	if message == "" then
		return nil
	end

	local label = nil
	local detail = nil
	if string.sub(message, 1, #"invalid proposal: ") == "invalid proposal: " then
		label = "Proposal"
		detail = string.sub(message, #"invalid proposal: " + 1)
	elseif string.sub(message, 1, #"invalid initial proposal: ") == "invalid initial proposal: " then
		label = "Proposal"
		detail = string.sub(message, #"invalid initial proposal: " + 1)
	elseif string.sub(message, 1, #"invalid repair: ") == "invalid repair: " then
		label = "Repair"
		detail = string.sub(message, #"invalid repair: " + 1)
	elseif message == "invalid orchestrate response" then
		label = "Orchestrator"
		detail = "schema invalid"
	elseif string.sub(message, 1, #"invalid orchestrate response: ") == "invalid orchestrate response: " then
		label = "Orchestrator"
		detail = string.sub(message, #"invalid orchestrate response: " + 1)
	end

	if label == nil then
		return nil
	end
	if detail == nil or detail == "" then
		return string.format("%s response invalid", label)
	end
	return truncateText(string.format("%s response invalid: %s", label, detail), 120)
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

local function publishScoreSummary(targetSectorId: number, score)
	if score == nil then
		return
	end
	UIState.publishScore(targetSectorId, score)
	UIState.appendLog(
		string.format(
			"Score %.1f (air %.1f lat %.1f near %.1f cost %.1f budget %.0f%%%s)",
			score.total,
			score.air,
			score.lateral,
			score.near_miss,
			score.time_cost,
			score.budget_used * 100,
			if score.over_budget then " OVER" else ""
		)
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

local function runProposalChallengeUp(args): (any?, any?, string?)
	local request = args.request
	local job = args.job
	local targetSectorId = args.targetSectorId
	local targetSector = args.targetSector
	local baselineResult = args.baselineResult
	local designIntent = request.design_intent
	if designIntent == nil or baselineResult == nil or baselineResult.score == nil then
		return nil, nil, "missing challenge-up context"
	end

	local challengeContext: ChallengeUpContext = {
		baseline_state = cloneState(job.working_state),
		baseline_result = baselineResult,
		budget_headroom = budgetHeadroom(baselineResult),
		target_score_floor = challengeUpScoreFloor(designIntent),
		reason = buildChallengeUpReason(designIntent, baselineResult, challengeUpScoreFloor(designIntent)),
		max_additional_repairs = Constants.ENDURANCE_CHALLENGE_UP_MAX_REPAIRS,
	}

	local challengeState, proposalNote, challengeErr =
		LLMAdapter.challengeUp(request, job.working_state, baselineResult, designIntent, challengeContext)
	if not challengeState then
		return nil, nil, tostring(challengeErr)
	end

	job.challenge_up_proposal_note = proposalNote
	job.challenge_up_attempts = {}
	appendRequestMemory(request, "proposal", proposalNote)
	UIState.appendLog("Challenge-up do-over: " .. challengeContext.reason)
	UIState.appendLog("Challenge proposal: " .. compactStateDetails(challengeState))
	if proposalNote ~= nil then
		UIState.appendLog("Challenge note: " .. proposalNote.note)
	end
	pauseForUI()

	local workingState = cloneState(challengeState)
	local lastAction = nil
	local nextAction = nil
	local attemptIndex = 0
	local useIsolatedProfile = isEnduranceVerificationProfileEnabled(request)

	while true do
		local proposedState = cloneState(workingState)
		local verification = runVerificationProfile({
			use_isolated_profile = useIsolatedProfile,
			working_state = workingState,
			action = nextAction,
			runAttempt = function(mode: string, stateForRun, actionForRun)
				local runArgs = {
					workingState = stateForRun,
					action = actionForRun,
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
				}
				if mode == "isolated_sector" then
					runArgs.mode = "isolated_sector"
				end
				return AttemptRunner.run(runArgs)
			end,
			onStageStart = function(stage: VerificationStage, passIndex: number, passTotal: number)
				if stage == "isolated" then
					UIState.setPhase(
						"ChallengeUpIsolated",
						string.format("Challenge-up isolated check %d/%d...", passIndex, passTotal)
					)
				elseif stage == "commit_lap" then
					UIState.setPhase("ChallengeUpCommitLap", "Challenge-up commit lap...")
				else
					UIState.setPhase("ChallengeUpRunVerification", "Challenge-up verification...")
				end
				Tracer.log(
					string.format(
						"challenge_up_stage index=%d target_sector=%d stage=%s pass=%d/%d",
						attemptIndex,
						targetSectorId,
						stage,
						passIndex,
						passTotal
					)
				)
			end,
			onStageResult = function(
				_stage: VerificationStage,
				runScope: "lap" | "isolated_sector",
				_passIndex: number,
				_passTotal: number,
				stageResult,
				_stageHints
			)
				UIState.publishAttemptResult(stageResult, runScope)
			end,
		})
		local result = verification.result
		local hints = verification.hints
		workingState = cloneState(verification.updated_state)
		table.insert(job.challenge_up_attempts, {
			attempt_index = attemptIndex,
			action = nextAction,
			proposed_state = proposedState,
			result = result,
			hints = hints,
			memory_note = nil,
			verification_stage = verification.verification_stage,
			run_scope = verification.run_scope,
			isolated_passes_required = verification.isolated_passes_required,
			isolated_passes_completed = verification.isolated_passes_completed,
		})
		Tracer.log(
			string.format(
				"challenge_up_attempt index=%d target_sector=%d stage=%s run_scope=%s isolated=%s/%s success=%s failure_type=%s failure_sector=%s failure_detail=%s target_progress=%.2f score=%s",
				attemptIndex,
				targetSectorId,
				verification.verification_stage,
				verification.run_scope,
				tostring(verification.isolated_passes_completed or "-"),
				tostring(verification.isolated_passes_required or "-"),
				boolString(result.success),
				tostring(result.failure and result.failure.type or "none"),
				tostring(result.failure and result.failure.sector_id or "-"),
				failureDetail(result),
				result.metrics.target_progress or 0,
				tostring(result.score and result.score.total or "-")
			)
		)

		if result.success then
			if result.score == nil then
				return nil, nil, "challenge-up returned success without score"
			end
			if result.score.over_budget then
				return nil, nil, "challenge-up over budget"
			end
			if result.score.total < (baselineResult.score.total or 0) + Constants.MIN_ESCALATION_DELTA then
				return nil, nil, "challenge-up produced insufficient improvement"
			end
			return workingState, result, nil
		end

		UIState.showFailure(result)
		pauseOnFailure(result)
		UIState.appendLog(
			string.format(
				"Challenge-up failed: %s in sector %d",
				tostring(result.failure and result.failure.type or "unknown"),
				result.failure and result.failure.sector_id or targetSectorId
			)
		)
		if #hints > 0 then
			UIState.appendLog("Challenge hints: " .. table.concat(hints, " | "))
		end

		if shouldRevertPreTargetFailure(result, targetSectorId) then
			return nil, nil, "challenge-up failed before exiting target sector"
		end
		if attemptIndex >= Constants.ENDURANCE_CHALLENGE_UP_MAX_REPAIRS then
			return nil, nil, "challenge-up repair limit reached"
		end

		local failureSector = if result.failure then result.failure.sector_id else targetSectorId
		local packet = LapEvaluator.buildFailurePacket(
			request,
			workingState,
			attemptIndex,
			lastAction,
			result,
			failureSector,
			hints,
			downstreamDiagnostics(targetSectorId, failureSector)
		)
		local action, newState, explanation, repairMemoryNote, repairErr =
			LLMAdapter.repair(packet, job.challenge_up_attempts, packet.design_intent)
		if repairErr then
			return nil, nil, tostring(repairErr)
		end

		appendRequestMemory(request, "repair", repairMemoryNote)
		if #job.challenge_up_attempts > 0 then
			job.challenge_up_attempts[#job.challenge_up_attempts].memory_note = repairMemoryNote
		end

		attemptIndex += 1
		if newState then
			workingState = cloneState(newState)
			lastAction = nil
			nextAction = nil
			UIState.setRepairAction("CHALLENGE-UP: full state revision")
			UIState.setExplanation(explanation or "")
			UIState.appendLog(
				string.format("Challenge repair %d (LLM): %s", attemptIndex, explanation or "revised state")
			)
			UIState.appendLog("Challenge revised: " .. compactStateDetails(workingState))
		elseif action then
			lastAction = action
			nextAction = action
			UIState.setRepairAction(repairActionLabel(action))
			UIState.setExplanation(explanation or "")
			UIState.appendLog(string.format("Challenge repair %d: %s", attemptIndex, explanation or "repair"))
			UIState.appendLog("Challenge action: " .. repairActionLabel(action))
		else
			return nil, nil, "challenge-up repair returned no action"
		end
		if repairMemoryNote ~= nil then
			UIState.appendLog("Challenge repair note: " .. repairMemoryNote.note)
		end
		pauseForUI()
	end
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

pauseForUI = function()
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

pauseOnFailure = function(result)
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

local function spawnEnduranceRun(): (boolean, string?)
	task.spawn(function()
		OrchestratorAgent.run({
			submitDesignIntent = function(designIntent, text: string, memoryContext: RunMemory?)
				_allowEnduranceInternalSubmit = true
				local callOk, submitOk, submitReason =
					pcall(JobRunner.submitEnduranceDesignIntent, designIntent, text, memoryContext)
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

-- Submit a plain-text request.  Returns false + reason if rejected without running.
function JobRunner.submit(rawText: string, requestOverride: Request?): (boolean, string?)
	local sm = JobStateMachine.new()
	local requestId = nextId("req")
	local traceOwnedByThisJob = false
	local request = requestOverride

	if requestOverride == nil then
		local handled, routedOk, routedReason = CommandRouter.route(rawText, {
			startEndurance = JobRunner.startEndurance,
		})
		if handled then
			return routedOk, routedReason
		end
	end

	if requestOverride == nil and TuneMode.isActive() then
		UIState.rejectRequest(rawText, "tune mode is running; use /tune stop to exit it")
		return false, "tune mode is running; use /tune stop to exit it"
	end

	if CameraDemo.isActive() then
		local reason = string.format(
			"demo '%s' is running; use /demo %s to toggle it off",
			CameraDemo.activePreset(),
			CameraDemo.activePreset()
		)
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

	ensureRequestMemory(request)

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

		Tracer.log(
			string.format(
				"job_start id=%s sector=%d mechanic=%s",
				request.request_id,
				targetSectorId,
				requestSummary(request.parsed)
			)
		)
		UIState.beginJob(request)
		UIState.setPhase("AcquireTrack", "Preparing job")
		UIState.appendLog(string.format("Queued %s for sector %d", requestSummary(request.parsed), targetSectorId))
		pauseForUI()

		sm:transition("GenerateInitialProposal")
		UIState.setPhase("GenerateInitialProposal", "Generating proposal...")
		local initialState, proposalMemoryNote, proposalErr = LLMAdapter.propose(request, request.design_intent)
		if not initialState then
			local errText = tostring(proposalErr)
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, errText, invalidAgentResponseWarning(errText))
			return false, proposalErr
		end

		local validState, validationErr = ActionValidator.validateSectorState(initialState)
		if not validState then
			local errText = "invalid initial proposal: " .. tostring(validationErr)
			sm:transition("RejectRequest")
			sm:transition("Idle")
			UIState.rejectRequest(rawText, errText, invalidAgentResponseWarning(errText))
			return false, errText
		end
		UIState.appendLog("Initial proposal accepted")
		UIState.appendLog("Proposal: " .. compactStateDetails(initialState))
		appendRequestMemory(request, "proposal", proposalMemoryNote)
		if proposalMemoryNote ~= nil then
			UIState.appendLog("Proposal note: " .. proposalMemoryNote.note)
		end
		Tracer.log(string.format("proposal sector=%d state=%s", targetSectorId, compactStateDetails(initialState)))

		local job: CIJob = {
			job_id = request.request_id,
			request = request,
			initial_state = cloneState(initialState),
			working_state = cloneState(initialState),
			attempts = {},
			proposal_memory_note = proposalMemoryNote,
			challenge_up_proposal_note = nil,
			challenge_up_attempts = nil,
			final_result = nil,
			final_status = "reverted",
		}

		local nextAction = nil
		local attemptIndex = 0
		local lastAction = nil
		local rampJumpPeakSuccessfulScore: number? = nil
		local upstreamFailCount = 0
		local upstreamFailSectorId: number? = nil
		local useIsolatedProfile = isEnduranceVerificationProfileEnabled(request)

		while true do
			sm:transition("ApplyWorkingSector")
			UIState.setPhase("ApplyWorkingSector", "Applying sector...")
			UIState.setAttempt(attemptIndex, Constants.MAX_REPAIR_ATTEMPTS)
			pauseForUI()
			sm:transition("RunVerification")
			UIState.setPhase("RunVerification", "Running simulation...")
			Tracer.log(
				string.format(
					"attempt index=%d sector=%d mechanic=%s",
					attemptIndex,
					targetSectorId,
					stateSummary(job.working_state)
				)
			)

			local proposedState = cloneState(job.working_state)
			local verification = runVerificationProfile({
				use_isolated_profile = useIsolatedProfile,
				working_state = job.working_state,
				action = nextAction,
				runAttempt = function(mode: string, stateForRun, actionForRun)
					local runArgs = {
						workingState = stateForRun,
						action = actionForRun,
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
					}
					if mode == "isolated_sector" then
						runArgs.mode = "isolated_sector"
					end
					return AttemptRunner.run(runArgs)
				end,
				onStageStart = function(stage: VerificationStage, passIndex: number, passTotal: number)
					if stage == "isolated" then
						UIState.setPhase(
							"RunVerificationIsolated",
							string.format("Running isolated check %d/%d...", passIndex, passTotal)
						)
					elseif stage == "commit_lap" then
						UIState.setPhase("RunVerificationCommitLap", "Running commit lap...")
					else
						UIState.setPhase("RunVerification", "Running simulation...")
					end
					Tracer.log(
						string.format(
							"attempt_stage index=%d target_sector=%d stage=%s pass=%d/%d",
							attemptIndex,
							targetSectorId,
							stage,
							passIndex,
							passTotal
						)
					)
				end,
				onStageResult = function(
					_stage: VerificationStage,
					runScope: "lap" | "isolated_sector",
					_passIndex: number,
					_passTotal: number,
					stageResult,
					_stageHints
				)
					UIState.publishAttemptResult(stageResult, runScope)
				end,
			})

			local result = verification.result
			local hints = verification.hints
			job.working_state = cloneState(verification.updated_state)
			table.insert(job.attempts, {
				attempt_index = attemptIndex,
				action = nextAction,
				proposed_state = proposedState,
				result = result,
				hints = hints,
				memory_note = nil,
				verification_stage = verification.verification_stage,
				run_scope = verification.run_scope,
				isolated_passes_required = verification.isolated_passes_required,
				isolated_passes_completed = verification.isolated_passes_completed,
			})
			Tracer.log(
				string.format(
					"attempt_result index=%d target_sector=%d stage=%s run_scope=%s isolated=%s/%s success=%s failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f score=%s",
					attemptIndex,
					targetSectorId,
					verification.verification_stage,
					verification.run_scope,
					tostring(verification.isolated_passes_completed or "-"),
					tostring(verification.isolated_passes_required or "-"),
					boolString(result.success),
					tostring(result.failure and result.failure.type or "none"),
					tostring(result.failure and result.failure.sector_id or "-"),
					failureDetail(result),
					boolString(result.metrics.target_entered == true),
					boolString(result.metrics.target_exited == true),
					result.metrics.target_progress or 0,
					tostring(result.score and result.score.total or "-")
				)
			)

			if result.success and result.score ~= nil and job.working_state.mechanic == "RampJump" then
				local priorBestScore = rampJumpPeakSuccessfulScore
				local gatePassed, requiredScore, gateHint =
					evaluateRampJumpRepairScoreRetention(request, attemptIndex, priorBestScore, result)
				rampJumpPeakSuccessfulScore = if priorBestScore == nil
					then (result.score.total or 0)
					else math.max(priorBestScore, result.score.total or 0)
				if not gatePassed then
					result.success = false
					result.failure = {
						type = "mechanic_integrity_failure",
						sector_id = targetSectorId,
						detail = "rampjump_score_retention",
					}
					table.insert(hints, gateHint or "rampjump score retention gate failed")
					UIState.appendLog(
						gateHint or string.format("RampJump score retention failed (required %.1f)", requiredScore)
					)
					Tracer.log(
						string.format(
							"rampjump_retention_gate_fail sector=%d attempt=%d score=%.2f required=%.2f prior_best=%s",
							targetSectorId,
							attemptIndex,
							result.score.total or 0,
							requiredScore,
							tostring(priorBestScore or "-")
						)
					)
				end
			end

			sm:transition("EvaluateResult")
			if result.success then
				sm:transition("Commit")
				job.working_state.version = priorCommitted.version + 1
				SectorRegistry.commit(job.working_state)
				UIState.setSectorMechanic(targetSectorId, job.working_state.mechanic)
				job.final_status = "committed"
				job.final_result = result
				UIState.setPhase("Commit", "Committed")
				UIState.appendLog(
					string.format("Committed %s v%d", stateSummary(job.working_state), job.working_state.version)
				)
				publishScoreSummary(targetSectorId, result.score)
				pauseForUI()

				-- Baseline commit stands first. Any challenge-up branch only supersedes it
				-- if the follow-up proposal validates cleanly and beats the baseline score.
				local wantsChallengeUp, challengeSkipReason, challengeStrategy =
					shouldRunChallengeUp(request, result, nil, attemptIndex, job.working_state)
				if wantsChallengeUp then
					UIState.setPhase("ChallengeUp", "Challenging up...")
					if challengeStrategy == "proposal_do_over" then
						local bestState, bestResult, challengeErr = runProposalChallengeUp({
							request = request,
							job = job,
							targetSectorId = targetSectorId,
							targetSector = targetSector,
							baselineResult = result,
						})
						if bestState ~= nil and bestResult ~= nil and bestResult.score ~= nil then
							bestState.version = job.working_state.version + 1
							SectorRegistry.commit(bestState)
							UIState.setSectorMechanic(targetSectorId, bestState.mechanic)
							job.working_state = cloneState(bestState)
							job.final_result = bestResult
							publishScoreSummary(targetSectorId, bestResult.score)
							UIState.appendLog(
								string.format(
									"Challenge-up superseded baseline → score %.1f (was %.1f)",
									bestResult.score.total,
									result.score and result.score.total or 0
								)
							)
							Tracer.log(
								string.format(
									"challenge_up_proposal sector=%d score=%.2f->%.2f",
									targetSectorId,
									result.score and result.score.total or 0,
									bestResult.score.total
								)
							)
						else
							UIState.appendLog(
								"Challenge-up kept baseline: " .. tostring(challengeErr or "no improvement")
							)
							Tracer.log(
								string.format(
									"challenge_up_proposal_skip sector=%d reason=%s",
									targetSectorId,
									tostring(challengeErr or "no improvement")
								)
							)
						end
					else
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
								if entering then
									UIState.setCurrentSector(id)
								end
							end,
							onRound = function(round, attempt, improved, roundReason)
								if attempt then
									UIState.appendLog(
										string.format(
											"Escalate r%d %s %s→%s %s%s",
											round,
											attempt.lever,
											tostring(attempt.from),
											tostring(attempt.to),
											if improved then "ACCEPT" else "REJECT",
											roundReason and (" (" .. roundReason .. ")") or ""
										)
									)
								elseif roundReason then
									UIState.appendLog("Escalate stopped: " .. roundReason)
								end
							end,
						})
						if bestResult and bestResult.score and bestResult ~= result then
							bestState.version = job.working_state.version + 1
							SectorRegistry.commit(bestState)
							UIState.setSectorMechanic(targetSectorId, bestState.mechanic)
							job.working_state = cloneState(bestState)
							job.final_result = bestResult
							publishScoreSummary(targetSectorId, bestResult.score)
							UIState.appendLog(
								string.format(
									"Escalated in %d rounds → score %.1f (was %.1f)",
									rounds,
									bestResult.score.total,
									result.score.total
								)
							)
							Tracer.log(
								string.format(
									"challenge_up sector=%d rounds=%d score=%.2f->%.2f",
									targetSectorId,
									rounds,
									result.score.total,
									bestResult.score.total
								)
							)
						else
							UIState.appendLog(
								string.format("Escalate produced no net improvement in %d rounds", rounds)
							)
						end
					end
					pauseForUI()
				else
					Tracer.log(
						string.format(
							"challenge_up_skip sector=%d reason=%s strategy=%s qualifiers=%s",
							targetSectorId,
							tostring(challengeSkipReason or "unknown"),
							tostring(challengeStrategy or "-"),
							qualifiersSummary(request.qualifiers)
						)
					)
				end

				UIState.publishCommittedLap(job.final_result)
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
			UIState.appendLog(
				string.format(
					"Failure: %s in sector %d",
					tostring(result.failure and result.failure.type or "unknown"),
					result.failure and result.failure.sector_id or targetSectorId
				)
			)
			UIState.appendLog("Metrics: " .. metricsSummary(result.metrics))
			if #hints > 0 then
				UIState.appendLog("Hints: " .. table.concat(hints, " | "))
			end
			Tracer.log(
				string.format(
					"failure_analysis target_sector=%d failure_type=%s failure_sector=%s failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f hints=%s",
					targetSectorId,
					tostring(result.failure and result.failure.type or "unknown"),
					tostring(result.failure and result.failure.sector_id or "-"),
					failureDetail(result),
					boolString(result.metrics.target_entered == true),
					boolString(result.metrics.target_exited == true),
					result.metrics.target_progress or 0,
					hintsSummary(hints)
				)
			)
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
					UIState.appendLog(
						string.format("Upstream failure in committed sector %d — retrying lap", failingSector)
					)
					Tracer.log(
						string.format("upstream_retry sector=%d failure_sector=%d", targetSectorId, failingSector)
					)
					sm:transition("ApplyRepair")
					nextAction = nil
					continue
				end

				-- Second consecutive failure at same committed sector: revert + queue + hotfix
				UIState.appendLog(
					string.format("Upstream failure confirmed in sector %d — entering hotfix mode", failingSector)
				)
				UIState.setHotfixActive(true, failingSector)
				UIState.setPhase("HotfixMode", string.format("HOTFIX MODE — Sector %d", failingSector))
				Tracer.log(string.format("hotfix_trigger sector=%d failure_sector=%d", targetSectorId, failingSector))
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
					HotfixAgent.run(capturedFailSector, capturedFailResult, function()
						return _pendingRequest
					end, function()
						_pendingRequest = nil
					end, function(text)
						JobRunner.submit(text)
					end)
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
				finishRevert(
					job,
					targetSector,
					string.format("revert sector=%d attempts=%d", targetSectorId, #job.attempts)
				)
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
				UIState.appendLog(
					string.format(
						"Downstream sector %d: %s",
						packet.diagnostics.downstream_sector_state.sector_id,
						tostring(packet.diagnostics.downstream_sector_state.mechanic)
					)
				)
			end

			sm:transition("ApplyRepair")
			UIState.setPhase("ApplyRepair", "Applying repair...")
			local action, newState, explanation, repairMemoryNote, repairErr =
				LLMAdapter.repair(packet, job.attempts, packet.design_intent)
			if repairErr then
				local errText = tostring(repairErr)
				local warningText = invalidAgentResponseWarning(errText)
				UIState.setLLMWarning(warningText or "")
				UIState.setError("LLM error: " .. errText)
				UIState.appendLog("LLM error: " .. errText)
				Tracer.log("llm_error attempt=" .. attemptIndex .. " err=" .. errText)
				sm:transition("Revert")
				finishRevert(job, targetSector, "revert reason=llm_error")
				sm:transition("Idle")
				return true, nil
			end

			if newState then
				-- LLM returned a full revised SectorState (no delta action)
				job.working_state = cloneState(newState)
				appendRequestMemory(request, "repair", repairMemoryNote)
				if #job.attempts > 0 then
					job.attempts[#job.attempts].memory_note = repairMemoryNote
				end
				lastAction = nil
				nextAction = nil
				attemptIndex += 1
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction("LLM: full state revision")
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d (LLM): %s", attemptIndex, explanation or "revised state"))
				if repairMemoryNote ~= nil then
					UIState.appendLog("Repair note: " .. repairMemoryNote.note)
				end
				UIState.appendLog("Revised: " .. compactStateDetails(job.working_state))
				pauseForUI()
				Tracer.log(
					string.format(
						"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s path=llm_full_state explanation=%s",
						attemptIndex,
						targetSectorId,
						failureSector,
						failureDetail(result),
						explanation or "-"
					)
				)
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
				appendRequestMemory(request, "repair", repairMemoryNote)
				if #job.attempts > 0 then
					job.attempts[#job.attempts].memory_note = repairMemoryNote
				end
				attemptIndex += 1
				UIState.setAttempt(attemptIndex, attemptLimitForResult(result, targetSectorId))
				UIState.setRepairAction(repairActionLabel(action))
				UIState.setExplanation(explanation or "")
				UIState.appendLog(string.format("Attempt %d: %s", attemptIndex, explanation or "repair"))
				if repairMemoryNote ~= nil then
					UIState.appendLog("Repair note: " .. repairMemoryNote.note)
				end
				UIState.appendLog("Action: " .. repairActionLabel(action))
				pauseForUI()
				Tracer.log(
					string.format(
						"repair attempt=%d target_sector=%d failure_sector=%d failure_detail=%s target_entered=%s target_exited=%s target_progress=%.2f action=%s explanation=%s",
						attemptIndex,
						targetSectorId,
						failureSector,
						failureDetail(result),
						boolString(result.metrics.target_entered == true),
						boolString(result.metrics.target_exited == true),
						result.metrics.target_progress or 0,
						actionSummary(action),
						explanation or "repair"
					)
				)
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
			local targetSector = RuntimeContext.isReady() and RuntimeContext.getSectorById(request.parsed.sector_id)
				or nil
			if
				targetSector
				and _lastJob
				and _lastJob.job_id == request.request_id
				and _lastJob.final_status == "reverted"
			then
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

function JobRunner.submitEnduranceDesignIntent(
	designIntent: DesignIntent,
	rawText: string,
	memoryContext: RunMemory?
): (boolean, string?)
	local validIntent, intentErr = validateDesignIntent(designIntent)
	if not validIntent then
		UIState.rejectRequest(rawText, tostring(intentErr))
		return false, intentErr
	end
	local request = buildEnduranceRequest(nextId("req"), rawText, designIntent, memoryContext)
	return JobRunner.submit(rawText, request)
end

function JobRunner.startEndurance(): (boolean, string?)
	if OrchestratorAgent.isActive() then
		return false, "endurance mode already running"
	end
	if CameraDemo.isActive() then
		return false, string.format("demo '%s' is running; stop it before /demo endurance", CameraDemo.activePreset())
	end
	if TuneMode.isActive() then
		return false, "tune mode is running; use /tune stop to exit it"
	end
	if JobLock.isHeld() or HotfixAgent.isActive() then
		return false, "track is busy; try again shortly"
	end
	return spawnEnduranceRun()
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

function JobRunner._shouldRunChallengeUp(
	request,
	result,
	enduranceBuildActiveOverride: boolean?,
	commitAttemptIndex: number?,
	committedState
)
	return shouldRunChallengeUp(request, result, enduranceBuildActiveOverride, commitAttemptIndex, committedState)
end

function JobRunner._shouldRevertPreTargetFailure(result, targetSectorId: number): boolean
	return shouldRevertPreTargetFailure(result, targetSectorId)
end

function JobRunner._attemptLimitForResult(result, targetSectorId: number): number
	return attemptLimitForResult(result, targetSectorId)
end

function JobRunner._buildEnduranceRequest(
	designIntent: DesignIntent,
	rawText: string,
	requestId: string?,
	memoryContext: RunMemory?
): Request
	return buildEnduranceRequest(requestId or nextId("req"), rawText, designIntent, memoryContext)
end

function JobRunner._invalidAgentResponseWarning(errText: string?): string?
	return invalidAgentResponseWarning(errText)
end

function JobRunner._runVerificationProfile(args)
	return runVerificationProfile(args)
end

function JobRunner._evaluateRampJumpRepairScoreRetention(
	request: Request,
	attemptIndex: number,
	priorBestSuccessfulScore: number?,
	result
)
	return evaluateRampJumpRepairScoreRetention(request, attemptIndex, priorBestSuccessfulScore, result)
end

return JobRunner
