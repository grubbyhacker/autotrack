local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local MinimalOrchestrator = require(script.Parent.MinimalOrchestrator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local EnduranceObjective = require(script.Parent.EnduranceObjective)
local EnduranceMemory = require(script.Parent.EnduranceMemory)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local UIState = require(script.Parent.UIState)
local ContinuousLapRunner = require(script.Parent.ContinuousLapRunner)
local Tracer = require(script.Parent.Tracer)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision
type MemoryEntry = Types.MemoryEntry
type RunMemory = Types.RunMemory

local OrchestratorAgent = {}

local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }
local QUALIFIER_WORDS = {
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
local MECHANIC_WORDS = {
	RampJump = "jump",
	Chicane = "chicane",
	CrestDip = "crest",
}

local _active = false
local MAX_ORCHESTRATOR_HISTORY = 8

local function truncateText(value: string, maxLen: number): string
	if #value <= maxLen then
		return value
	end
	return string.sub(value, 1, maxLen)
end

local function defaultEnsureBaseline(): (boolean, string?)
	if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
		return true, nil
	end
	if not JobLock.tryAcquire() then
		return false, "track busy while recording baseline"
	end

	UIState.setPhase("BootBaseline", "Recording baseline lap...")
	UIState.appendLog("Baseline lap started on demand")
	Tracer.log("lap_start")

	local sectors = RuntimeContext.getSectors()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	local car = RuntimeContext.getCar()
	VerifierCar.reset(RuntimeContext.getCanonicalStart())

	local ok, result = pcall(function()
		return VerifierController.runLap(
			car,
			waypoints,
			waypointSectors,
			sectorKinds,
			function(id: number, entering: boolean)
				if entering then
					UIState.setCurrentSector(id)
				end
			end
		)
	end)
	JobLock.release()

	if not ok then
		return false, tostring(result)
	end
	if not result.success then
		return false, "baseline lap failed"
	end

	local lapTime = result.metrics.lap_time
	workspace:SetAttribute("AutoTrack_BaselineLapDone", true)
	workspace:SetAttribute("AutoTrack_BaselineLapTime", lapTime)
	UIState.setBaselineLapTime(lapTime)
	RuntimeContext.setBaselineLapTime(lapTime)
	UIState.appendLog(string.format("Baseline lap complete: %.2fs", lapTime))
	Tracer.log(string.format("lap_complete %.2f", lapTime))
	return true, nil
end

local function defaultDeps()
	return {
		ensureBaseline = defaultEnsureBaseline,
		orchestrate = function(context: OrchestratorContext)
			return LLMAdapter.orchestrate(context)
		end,
		setPhase = function(phase: string, label: string)
			UIState.setPhase(phase, label)
		end,
		setAttemptBudget = function(used: number, total: number)
			UIState.setEnduranceAttemptBudget(used, total)
		end,
		setLLMWarning = function(text: string)
			UIState.setLLMWarning(text)
		end,
		appendLog = function(line: string)
			UIState.appendLog(line)
		end,
		trace = function(line: string)
			Tracer.log(line)
		end,
		startContinuousLoop = function(initialLapCount: number)
			return ContinuousLapRunner.run({
				initialLapCount = initialLapCount,
			})
		end,
		setOrchestratorTelemetry = function(payload)
			UIState.setOrchestratorTelemetry(payload)
		end,
	}
end

local function budgetUsedFromSlowdown(slowdownRatio: number): number
	if Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO <= 0 then
		return 0
	end
	return math.clamp(
		math.max(0, (slowdownRatio or 1) - 1) / Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO,
		0,
		1
	)
end

local function copyMap(source)
	local result = {}
	if type(source) ~= "table" then
		return result
	end
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function scoreTotal(scoresBySector): number
	local total = 0
	for _, score in pairs(scoresBySector) do
		total += score or 0
	end
	return total
end

local function buildTrackIntent(scoresBySector, slowdownRatio: number, repeatPressure)
	return {
		target_total_score = scoreTotal(scoresBySector),
		target_budget_used = budgetUsedFromSlowdown(slowdownRatio),
		diversity_pressure = copyMap(repeatPressure),
	}
end

local function buildContext(
	scoresBySector,
	slowdownRatio: number,
	attemptBudgetUsed: number,
	lastResult,
	attemptHistory,
	sectorAttemptCounts,
	repeatPressure,
	trackIntent,
	memory: RunMemory
): OrchestratorContext
	local sectorStates = {}
	for _, state in ipairs(SectorRegistry.getStraights()) do
		sectorStates[state.sector_id] = {
			mechanic = state.mechanic,
			params = state.params,
			score = scoresBySector[state.sector_id] or 0,
		}
	end

	return {
		editable_sectors = EDITABLE_SECTORS,
		sector_states = sectorStates,
		budget = {
			used = budgetUsedFromSlowdown(slowdownRatio),
			over_budget = (slowdownRatio or 1) > (1 + Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO),
		},
		attempt_budget = {
			used = attemptBudgetUsed,
			total = Constants.ENDURANCE_ATTEMPT_BUDGET,
		},
		last_result = lastResult,
		attempt_history = attemptHistory,
		sector_attempt_counts = sectorAttemptCounts,
		mechanic_repeat_pressure = repeatPressure,
		track_intent = trackIntent,
		memory = EnduranceMemory.clone(memory),
	}
end

local function hintQualifiers(paramsHint: string?): string
	if type(paramsHint) ~= "string" then
		return ""
	end

	local picked = {}
	local seen = {}
	for word in string.gmatch(string.lower(paramsHint), "[%a%-]+") do
		if QUALIFIER_WORDS[word] and not seen[word] then
			seen[word] = true
			table.insert(picked, word)
		end
	end
	return table.concat(picked, " ")
end

local function buildRequestText(decision: OrchestratorDecision): string
	local mechanicWord = MECHANIC_WORDS[decision.mechanic] or "jump"
	local qualifiers = hintQualifiers(decision.params_hint)
	if qualifiers ~= "" then
		return string.format("add an %s %s in sector %d", qualifiers, mechanicWord, decision.sector_id)
	end
	return string.format("add a %s in sector %d", mechanicWord, decision.sector_id)
end

local function buildFailureSignature(result, normalizedSignature: string?): string?
	if result == nil or result.failure == nil then
		return nil
	end
	local detail = tostring(result.failure.detail or result.failure.type or "failure")
	if normalizedSignature ~= nil and normalizedSignature ~= "" then
		return string.format("%s@%s", detail, normalizedSignature)
	end
	return detail
end

local function rebuildSectorAttemptCounts(history)
	local counts = {}
	for _, attempt in ipairs(history) do
		local sectorId = attempt.sector_id
		if type(sectorId) == "number" then
			counts[sectorId] = (counts[sectorId] or 0) + 1
		end
	end
	return counts
end

local function rebuildRepeatPressure(history)
	local pressure = {}
	for _, attempt in ipairs(history) do
		local signature = attempt.normalized_signature
		if type(signature) == "string" and signature ~= "" then
			pressure[signature] = (pressure[signature] or 0) + 1
		end
	end
	return pressure
end

local function formatDecisionSummary(decision: OrchestratorDecision): string
	if decision.action == "begin_loop" then
		return "TRACK READY"
	end

	local summary = string.format("S%d %s", decision.sector_id or 0, tostring(decision.mechanic or ""))
	local paramsHint = tostring(decision.params_hint or "")
	if paramsHint ~= "" then
		summary ..= " | " .. paramsHint
	end
	return summary
end

local function formatLedgerEntry(entry): string
	local sectorId = entry.sector_id or 0
	local mechanic = tostring(entry.mechanic or "Flat")
	local outcome = string.upper(tostring(entry.outcome or "unknown"))
	if entry.outcome == "committed" then
		return string.format("#%d S%d %s %s %.1f", entry.decision_index or 0, sectorId, mechanic, outcome, entry.score or 0)
	end
	local failure = tostring(entry.failure_signature or "no-failure-signature")
	return string.format("#%d S%d %s %s %s", entry.decision_index or 0, sectorId, mechanic, outcome, failure)
end

local function collectLedgerLines(history): { string }
	local lines = {}
	for index = 1, math.min(3, #history) do
		lines[index] = formatLedgerEntry(history[index])
	end
	return lines
end

local function summarizeRepeatPressure(repeatPressure): string
	local items = {}
	for signature, count in pairs(repeatPressure) do
		table.insert(items, { signature = signature, count = count })
	end
	table.sort(items, function(left, right)
		if left.count == right.count then
			return left.signature < right.signature
		end
		return left.count > right.count
	end)

	local parts = {}
	for index = 1, math.min(2, #items) do
		local item = items[index]
		table.insert(parts, string.format("%s x%d", item.signature, item.count))
	end
	return table.concat(parts, " | ")
end

local function hasAuthoredEditableMechanic(context: OrchestratorContext): boolean
	for _, sectorId in ipairs(context.editable_sectors or {}) do
		local snapshot = context.sector_states and context.sector_states[sectorId]
		if snapshot ~= nil and snapshot.mechanic ~= nil then
			return true
		end
	end
	return false
end

local function isPrematureBeginLoop(context: OrchestratorContext, attemptHistory, decision: OrchestratorDecision): boolean
	if decision == nil or decision.action ~= "begin_loop" then
		return false
	end
	if #attemptHistory > 0 then
		return false
	end
	return not hasAuthoredEditableMechanic(context)
end

local function appendAttemptHistory(history, entry)
	table.insert(history, 1, entry)
	while #history > MAX_ORCHESTRATOR_HISTORY do
		table.remove(history)
	end
end

local function appendRoleMemory(memory: RunMemory, scopeName: string, note: MemoryEntry?)
	if note == nil then
		return
	end
	EnduranceMemory.append(memory, scopeName, note)
end

local function appendJobMemory(memory: RunMemory, job)
	if job == nil then
		return
	end
	appendRoleMemory(memory, "proposal", job.proposal_memory_note)
	appendRoleMemory(memory, "proposal", job.challenge_up_proposal_note)
	for _, attempt in ipairs(job.attempts or {}) do
		appendRoleMemory(memory, "repair", attempt.memory_note)
	end
	for _, attempt in ipairs(job.challenge_up_attempts or {}) do
		appendRoleMemory(memory, "repair", attempt.memory_note)
	end
end

local function latestRepairNote(job): MemoryEntry?
	if job == nil then
		return nil
	end
	for index = #(job.challenge_up_attempts or {}), 1, -1 do
		local note = job.challenge_up_attempts[index].memory_note
		if note ~= nil then
			return note
		end
	end
	for index = #job.attempts, 1, -1 do
		local note = job.attempts[index].memory_note
		if note ~= nil then
			return note
		end
	end
	return nil
end

local function buildSharedLesson(decision: OrchestratorDecision, job, result, decisionIndex: number): MemoryEntry?
	if job == nil or result == nil or decision.action == "begin_loop" then
		return nil
	end

	local sectorId = decision.sector_id or 0
	local mechanic = tostring(decision.mechanic or (job.working_state and job.working_state.mechanic) or "Unknown")
	local localNote = latestRepairNote(job) or job.challenge_up_proposal_note or job.proposal_memory_note
	local noteText
	local sourceType = "observed_result"

	if job.final_status == "committed" then
		if localNote ~= nil then
			noteText = string.format("Sector %d %s committed: %s", sectorId, mechanic, localNote.note)
			sourceType = localNote.source_type
		else
			noteText = string.format("Sector %d %s committed with stable lap behavior.", sectorId, mechanic)
		end
	else
		local failureDetail = tostring(result.failure and (result.failure.detail or result.failure.type) or "reverted")
		if result.failure and result.failure.type == "downstream_failure" then
			sourceType = "downstream_warning"
		end
		if localNote ~= nil then
			noteText = string.format("Sector %d %s failed (%s): %s", sectorId, mechanic, failureDetail, localNote.note)
		else
			noteText = string.format("Sector %d %s failed (%s); prefer a safer variant next time.", sectorId, mechanic, failureDetail)
		end
	end

	return {
		entry_id = EnduranceMemory.nextEntryId("orchestrator"),
		author = "orchestrator",
		scope = "shared",
		note = truncateText(noteText, 120),
		confidence = "medium",
		source_type = sourceType,
		source_ref = string.format("decision:%d", decisionIndex),
		timestamp = DateTime.now().UnixTimestampMillis,
	}
end

local function memoryTelemetry(memory: RunMemory)
	local sharedNotes = EnduranceMemory.latestNotes(memory, "shared", 2)
	local proposalNotes = EnduranceMemory.latestNotes(memory, "proposal", 1)
	local repairNotes = EnduranceMemory.latestNotes(memory, "repair", 1)
	return {
		shared_memory_depth = EnduranceMemory.depth(memory, "shared"),
		proposal_memory_depth = EnduranceMemory.depth(memory, "proposal"),
		repair_memory_depth = EnduranceMemory.depth(memory, "repair"),
		shared_memory_lines = sharedNotes,
		proposal_memory_lines = proposalNotes,
		repair_memory_lines = repairNotes,
	}
end

local function withMemoryTelemetry(payload, memory: RunMemory)
	local merged = {}
	for key, value in pairs(payload) do
		merged[key] = value
	end
	for key, value in pairs(memoryTelemetry(memory)) do
		merged[key] = value
	end
	return merged
end

local function fallbackOrchestrate(context: OrchestratorContext, orchestrateErr: string?): (OrchestratorDecision, string)
	local fallbackDecision = MinimalOrchestrator.decide(context)
	local reason = tostring(orchestrateErr or "unknown orchestrate error")
	local fallbackReason = "LLM orchestration failed; using deterministic fallback"
	if string.find(reason, "invalid orchestrate response", 1, true) ~= nil then
		fallbackReason = "LLM orchestration returned invalid JSON; using deterministic fallback"
	end
	if fallbackDecision.action == "begin_loop" then
		fallbackDecision.rationale = "fallback: track ready after invalid orchestration response"
	else
		fallbackDecision.rationale = fallbackDecision.rationale or "fallback deterministic orchestration"
	end
	return fallbackDecision, fallbackReason .. ": " .. reason
end

local function buildHistoryEntry(decision: OrchestratorDecision, job, result, decisionIndex: number)
	local normalizedSignature = EnduranceObjective.signature(decision)
	return {
		sector_id = decision.sector_id or (job and job.request and job.request.parsed and job.request.parsed.sector_id) or 0,
		mechanic = decision.mechanic or (job and job.working_state and job.working_state.mechanic) or nil,
		params_hint = decision.params_hint or "",
		normalized_signature = normalizedSignature,
		outcome = job and job.final_status or "unknown",
		score = result and result.score and result.score.total or nil,
		slowdown_ratio = result and result.metrics and result.metrics.slowdown_ratio or nil,
		failure_signature = buildFailureSignature(result, normalizedSignature),
		repair_iterations = math.max(0, ((job and #job.attempts) or 1) - 1),
		decision_index = decisionIndex,
		timestamp = DateTime.now().UnixTimestampMillis,
	}
end

function OrchestratorAgent.isActive(): boolean
	return _active
end

function OrchestratorAgent.run(args): (boolean, string?)
	if _active then
		return false, "endurance mode already running"
	end
	if args.isCameraDemoActive and args.isCameraDemoActive() then
		return false, "camera demo running; toggle it off before /demo endurance"
	end
	assert(RuntimeContext.isReady(), "orchestrator requires runtime context")
	local deps = (args and args.deps) or defaultDeps()

	_active = true
	local traceRunId = LLMTraceJournal.beginRun({
		owner = "orchestrator_agent",
		mode = "endurance",
	})
	UIState.setEnduranceActive(true, Constants.ENDURANCE_ATTEMPT_BUDGET)
	UIState.setEnduranceAttemptBudget(0, Constants.ENDURANCE_ATTEMPT_BUDGET)
	UIState.setEnduranceLapCount(0)
	UIState.setBusy(true)
	UIState.appendLog("Endurance mode starting")
	Tracer.log("endurance_start")

	local ok, runOk, runReason = pcall(function()
		local baselineOk, baselineErr = deps.ensureBaseline()
		if not baselineOk then
			return false, baselineErr
		end

		local scoresBySector = {}
		local slowdownRatio = 1
		local attemptBudgetUsed = 0
		local lastResult = nil
		local attemptHistory = {}
		local sectorAttemptCounts = {}
		local repeatPressure = {}
		local trackIntent = buildTrackIntent(scoresBySector, slowdownRatio, repeatPressure)
		local runMemory = EnduranceMemory.new()

		while attemptBudgetUsed < Constants.ENDURANCE_ATTEMPT_BUDGET do
			local context = buildContext(
				scoresBySector,
				slowdownRatio,
				attemptBudgetUsed,
				lastResult,
				attemptHistory,
				sectorAttemptCounts,
				repeatPressure,
				trackIntent,
				runMemory
			)
			deps.setPhase(
				"EnduranceOrchestrate",
				string.format("Endurance Mode — Orchestrating (%d/%d)", attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			)
			deps.setAttemptBudget(attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			if deps.setLLMWarning then
				deps.setLLMWarning("")
			end

			local decision, decisionNote, orchestrateErr = deps.orchestrate(context)
			if not decision then
				decision, orchestrateErr = fallbackOrchestrate(context, orchestrateErr)
				decisionNote = nil
				deps.appendLog(orchestrateErr)
				deps.trace("endurance_orchestrate_fallback " .. orchestrateErr)
				if deps.setLLMWarning then
					deps.setLLMWarning("Orchestrator response invalid; using deterministic fallback")
				end
			elseif isPrematureBeginLoop(context, attemptHistory, decision) then
				local prematureReason = "LLM orchestration chose begin_loop before any build; using deterministic fallback"
				decision = MinimalOrchestrator.decide(context)
				decisionNote = nil
				deps.appendLog(prematureReason)
				deps.trace("endurance_orchestrate_fallback premature_begin_loop")
				if deps.setLLMWarning then
					deps.setLLMWarning("Orchestrator chose track ready before any build; using deterministic fallback")
				end
			end
			appendRoleMemory(runMemory, "orchestrator", decisionNote)
			local decisionIndex = #attemptHistory + 1
			local objectiveScore = nil
			local rationale = tostring(decision.rationale or "")
			if decision.action ~= "begin_loop" then
				objectiveScore, rationale = EnduranceObjective.evaluateCandidate(context, decision)
				if decision.rationale ~= nil and decision.rationale ~= "" then
					rationale = decision.rationale
				end
			end
			if decision.action == "begin_loop" then
				if deps.setOrchestratorTelemetry then
					deps.setOrchestratorTelemetry(withMemoryTelemetry({
						objective_total = scoreTotal(scoresBySector),
						budget_target = trackIntent.target_budget_used,
						budget_headroom = math.max(0, 1 - budgetUsedFromSlowdown(slowdownRatio)),
						decision_index = decisionIndex,
						last_decision = formatDecisionSummary(decision),
						last_rationale = if rationale ~= "" then rationale else "track balanced; continuous loop armed",
						memory_depth = #attemptHistory,
						repeat_penalties = summarizeRepeatPressure(repeatPressure),
						failure_signature = if #attemptHistory > 0 then (attemptHistory[1].failure_signature or "") else "",
						reliability_index = 1,
						ledger_lines = collectLedgerLines(attemptHistory),
						track_intent = string.format(
							"track %.1f | budget %.0f%%",
							trackIntent.target_total_score or 0,
							(trackIntent.target_budget_used or 0) * 100
						),
					}, runMemory))
				end
				deps.appendLog("Orchestrator: track ready")
				deps.trace("endurance_begin_loop")
				break
			end

			if deps.setOrchestratorTelemetry then
				deps.setOrchestratorTelemetry(withMemoryTelemetry({
					objective_total = objectiveScore and objectiveScore.total or 0,
					budget_target = trackIntent.target_budget_used,
					budget_headroom = math.max(0, 1 - budgetUsedFromSlowdown(slowdownRatio)),
					decision_index = decisionIndex,
					last_decision = formatDecisionSummary(decision),
					last_rationale = rationale,
					memory_depth = #attemptHistory,
					repeat_penalties = summarizeRepeatPressure(repeatPressure),
					failure_signature = "",
					reliability_index = objectiveScore and objectiveScore.reliability_index or 0,
					ledger_lines = collectLedgerLines(attemptHistory),
					track_intent = string.format(
						"track %.1f | budget %.0f%%",
						trackIntent.target_total_score or 0,
						(trackIntent.target_budget_used or 0) * 100
					),
				}, runMemory))
			end

			attemptBudgetUsed += 1
			deps.setAttemptBudget(attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			local requestText = buildRequestText(decision)
			deps.appendLog(string.format("Endurance %d/%d: %s", attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET, requestText))
			deps.trace(string.format(
				"endurance_decision sector=%d mechanic=%s hint=%s used=%d",
				decision.sector_id or 0,
				tostring(decision.mechanic),
				tostring(decision.params_hint or "-"),
				attemptBudgetUsed
			))

			local submitOk, submitReason
			if args.submitDesignIntent ~= nil then
				submitOk, submitReason = args.submitDesignIntent(decision, requestText, EnduranceMemory.clone(runMemory))
			else
				submitOk, submitReason = args.submit(requestText)
			end
			local job = args.getLastJob()
			if not submitOk then
				return false, submitReason
			end

			if job and job.request and job.request.parsed then
				local sectorId = job.request.parsed.sector_id
				local success = job.final_status == "committed"
				local latestAttempt = job.attempts[#job.attempts]
				local result = job.final_result or (latestAttempt and latestAttempt.result or nil)
				if result and result.metrics and result.metrics.slowdown_ratio then
					slowdownRatio = result.metrics.slowdown_ratio
				end
				if success and result and result.score then
					scoresBySector[sectorId] = result.score.total
				end
				lastResult = {
					sector_id = sectorId,
					success = success,
					score = success and (scoresBySector[sectorId] or 0) or 0,
					failure_reason = if success or not result or not result.failure then nil else tostring(result.failure.detail or result.failure.type),
				}
				local historyEntry = buildHistoryEntry(decision, job, result, decisionIndex)
				appendAttemptHistory(attemptHistory, historyEntry)
				appendJobMemory(runMemory, job)
				local sharedLesson = buildSharedLesson(decision, job, result, decisionIndex)
				if sharedLesson ~= nil then
					EnduranceMemory.appendSharedIfFresh(runMemory, sharedLesson)
				end
				sectorAttemptCounts = rebuildSectorAttemptCounts(attemptHistory)
				repeatPressure = rebuildRepeatPressure(attemptHistory)
				trackIntent = buildTrackIntent(scoresBySector, slowdownRatio, repeatPressure)
				if deps.setOrchestratorTelemetry then
					deps.setOrchestratorTelemetry(withMemoryTelemetry({
						objective_total = success and (historyEntry.score or 0) or (objectiveScore and objectiveScore.total or 0),
						budget_target = trackIntent.target_budget_used,
						budget_headroom = math.max(0, 1 - budgetUsedFromSlowdown(slowdownRatio)),
						decision_index = decisionIndex,
						last_decision = formatDecisionSummary(decision),
						last_rationale = rationale,
						memory_depth = #attemptHistory,
						repeat_penalties = summarizeRepeatPressure(repeatPressure),
						failure_signature = historyEntry.failure_signature or "",
						reliability_index = objectiveScore and objectiveScore.reliability_index or 0,
						ledger_lines = collectLedgerLines(attemptHistory),
						track_intent = string.format(
							"track %.1f | budget %.0f%%",
							trackIntent.target_total_score or 0,
							(trackIntent.target_budget_used or 0) * 100
						),
					}, runMemory))
				end
			end

			UIState.setBusy(true)
		end

		deps.setPhase("EnduranceLoop", "Endurance Mode — Continuous Build (lap 1)")
		deps.appendLog("Continuous loop armed")
		return deps.startContinuousLoop(0)
	end)

	UIState.setBusy(false)
	_active = false

	if not ok then
		LLMTraceJournal.finishRun({
			outcome = "system_failure",
			run_id = traceRunId,
			error = tostring(runOk),
		})
		UIState.setError("endurance failure: " .. tostring(runOk))
		Tracer.log("endurance_error " .. tostring(runOk))
		return false, tostring(runOk)
	end

	LLMTraceJournal.finishRun({
		outcome = if runOk == true then "completed" else "failed",
		run_id = traceRunId,
		error = if runOk == true then nil else tostring(runReason),
	})
	if runOk ~= true then
		UIState.setError("endurance failure: " .. tostring(runReason))
		Tracer.log("endurance_error " .. tostring(runReason))
	end

	return runOk, runReason
end

return OrchestratorAgent
