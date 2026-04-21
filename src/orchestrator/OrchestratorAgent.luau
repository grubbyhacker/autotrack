local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local EnduranceObjective = require(script.Parent.EnduranceObjective)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local UIState = require(script.Parent.UIState)
local ContinuousLapRunner = require(script.Parent.ContinuousLapRunner)
local Tracer = require(script.Parent.Tracer)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision

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
	trackIntent
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
		return "BEGIN LOOP"
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

local function appendAttemptHistory(history, entry)
	table.insert(history, 1, entry)
	while #history > MAX_ORCHESTRATOR_HISTORY do
		table.remove(history)
	end
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

		while attemptBudgetUsed < Constants.ENDURANCE_ATTEMPT_BUDGET do
			local context = buildContext(
				scoresBySector,
				slowdownRatio,
				attemptBudgetUsed,
				lastResult,
				attemptHistory,
				sectorAttemptCounts,
				repeatPressure,
				trackIntent
			)
			deps.setPhase(
				"EnduranceOrchestrate",
				string.format("Endurance Mode — Orchestrating (%d/%d)", attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)
			)
			deps.setAttemptBudget(attemptBudgetUsed, Constants.ENDURANCE_ATTEMPT_BUDGET)

			local decision, orchestrateErr = deps.orchestrate(context)
			if not decision then
				return false, orchestrateErr
			end
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
					deps.setOrchestratorTelemetry({
						objective_total = scoreTotal(scoresBySector),
						budget_target = trackIntent.target_budget_used,
						budget_headroom = math.max(0, 1 - budgetUsedFromSlowdown(slowdownRatio)),
						decision_index = decisionIndex,
						last_decision = "BEGIN LOOP",
						last_rationale = if rationale ~= "" then rationale else "budget stable; start the live loop",
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
					})
				end
				deps.appendLog("Orchestrator: begin loop")
				deps.trace("endurance_begin_loop")
				break
			end

			if deps.setOrchestratorTelemetry then
				deps.setOrchestratorTelemetry({
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
				})
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

			local submitOk, submitReason = args.submit(requestText)
			local job = args.getLastJob()
			if not submitOk then
				return false, submitReason
			end

			if job and job.request and job.request.parsed then
				local sectorId = job.request.parsed.sector_id
				local success = job.final_status == "committed"
				local latestAttempt = job.attempts[#job.attempts]
				local result = latestAttempt and latestAttempt.result or nil
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
				sectorAttemptCounts = rebuildSectorAttemptCounts(attemptHistory)
				repeatPressure = rebuildRepeatPressure(attemptHistory)
				trackIntent = buildTrackIntent(scoresBySector, slowdownRatio, repeatPressure)
				if deps.setOrchestratorTelemetry then
					deps.setOrchestratorTelemetry({
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
					})
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
		UIState.setError("endurance failure: " .. tostring(runOk))
		Tracer.log("endurance_error " .. tostring(runOk))
		return false, tostring(runOk)
	end

	if runOk ~= true then
		UIState.setError("endurance failure: " .. tostring(runReason))
		Tracer.log("endurance_error " .. tostring(runReason))
	end

	return runOk, runReason
end

return OrchestratorAgent
