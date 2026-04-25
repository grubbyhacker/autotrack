--!strict

local HttpService = game:GetService("HttpService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local TestUtils = require(script.Parent.TestUtils)
local EnduranceObjective = require(script.Parent.EnduranceObjective)
local MinimalOrchestrator = require(script.Parent.MinimalOrchestrator)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local TestFactories = require(script.Parent.TestFactories)
local UIState = require(script.Parent.UIState)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorAttempt = Types.OrchestratorAttempt
type OrchestratorDecision = Types.OrchestratorDecision
type OrchestratorSubmitDecision = Types.OrchestratorSubmitDecision

type OrchestratorSubmitCapture = {
	raw_text: string,
	intent: OrchestratorSubmitDecision?,
}

type OrchestratorTelemetry = {
	objective_total: number?,
	budget_target: number?,
	budget_headroom: number?,
	decision_index: number?,
	last_decision: string?,
	last_rationale: string?,
	memory_depth: number?,
	repeat_penalties: string?,
	failure_signature: string?,
	reliability_index: number?,
	ledger_lines: { string }?,
	track_intent: string?,
	shared_memory_depth: number?,
	proposal_memory_depth: number?,
	repair_memory_depth: number?,
	shared_memory_lines: { string }?,
	proposal_memory_lines: { string }?,
	repair_memory_lines: { string }?,
}

local T = TestUtils
local TestPhase14_5 = {}

local function makeContext(): OrchestratorContext
	return TestFactories.orchestratorContext()
end

local function withIntent(decision)
	return TestFactories.submitDecision(decision)
end

function TestPhase14_5.runUnit()
	local repeatedDecision = withIntent({
		sector_id = 2,
		mechanic = "RampJump",
		params_hint = "extreme tall",
	})
	local alternateDecision = withIntent({
		sector_id = 3,
		mechanic = "CrestDip",
		params_hint = "extreme deep",
	})

	local objectiveContext = makeContext()
	local attemptHistory: { OrchestratorAttempt } = {
		{
			sector_id = 2,
			mechanic = "RampJump",
			params_hint = "extreme tall",
			normalized_signature = EnduranceObjective.signature(repeatedDecision),
			outcome = "reverted",
			score = 0,
			slowdown_ratio = 1.2,
			failure_signature = "no_progress@" .. EnduranceObjective.signature(repeatedDecision),
			repair_iterations = 2,
			decision_index = 1,
			timestamp = 1,
		},
		{
			sector_id = 2,
			mechanic = "RampJump",
			params_hint = "extreme tall",
			normalized_signature = EnduranceObjective.signature(repeatedDecision),
			outcome = "reverted",
			score = 0,
			slowdown_ratio = 1.18,
			failure_signature = "no_progress@" .. EnduranceObjective.signature(repeatedDecision),
			repair_iterations = 2,
			decision_index = 2,
			timestamp = 2,
		},
		{
			sector_id = 2,
			mechanic = "RampJump",
			params_hint = "extreme tall",
			normalized_signature = EnduranceObjective.signature(repeatedDecision),
			outcome = "reverted",
			score = 0,
			slowdown_ratio = 1.15,
			failure_signature = "no_progress@" .. EnduranceObjective.signature(repeatedDecision),
			repair_iterations = 1,
			decision_index = 3,
			timestamp = 3,
		},
	}
	objectiveContext.attempt_history = attemptHistory
	objectiveContext.sector_attempt_counts = { [2] = 3 }
	objectiveContext.mechanic_repeat_pressure = {
		[EnduranceObjective.signature(repeatedDecision)] = 3,
	}
	local trackIntent = objectiveContext.track_intent
	assert(trackIntent ~= nil, "test context should include track intent")
	trackIntent.diversity_pressure = {
		[EnduranceObjective.signature(repeatedDecision)] = 3,
	}

	local repeatedScore = select(1, EnduranceObjective.evaluateCandidate(objectiveContext, repeatedDecision))
	local alternateScore = select(1, EnduranceObjective.evaluateCandidate(objectiveContext, alternateDecision))
	T.expect(
		"phase14_5_objective_skips_repeated_failed_signature",
		EnduranceObjective.shouldAvoidRepeat(objectiveContext, repeatedDecision) == true
			and alternateScore.total > repeatedScore.total,
		HttpService:JSONEncode({
			repeated = repeatedScore,
			alternate = alternateScore,
		})
	)

	local fallbackDecision = MinimalOrchestrator.decide(objectiveContext)
	T.expect(
		"phase14_5_minimal_orchestrator_uses_context_fallback_without_nondeterminism",
		fallbackDecision.action == "submit_request"
			and fallbackDecision.sector_id == 3
			and fallbackDecision.mechanic == "CrestDip",
		HttpService:JSONEncode(fallbackDecision)
	)

	UIState.init(-1)
	local stateFolder = UIState.getStateFolder()
	T.expect(
		"phase14_5_hud_state_defaults_include_orchestrator_objectives",
		(stateFolder:GetAttribute("orchestrator_objective_total") or -1) == 0
			and (stateFolder:GetAttribute("orchestrator_budget_headroom") or -1) == 1
			and (stateFolder:GetAttribute("orchestrator_last_decision") or "x") == ""
			and (stateFolder:GetAttribute("orchestrator_ledger_1") or "x") == "",
		"missing orchestrator default attrs"
	)

	local orchestratorContexts: { OrchestratorContext } = {}
	local telemetryPayloads: { OrchestratorTelemetry } = {}
	local orchestratorSubmits: { OrchestratorSubmitCapture } = {}
	local loopStarted = false

	local jobs = {
		{
			request = { parsed = { sector_id = 2 } },
			working_state = { mechanic = "RampJump" },
			final_status = "reverted",
			attempts = {
				{
					result = {
						metrics = { slowdown_ratio = 1.3 },
						score = { total = 0 },
						failure = { type = "local_execution_failure", detail = "no_progress" },
					},
				},
				{
					result = {
						metrics = { slowdown_ratio = 1.3 },
						score = { total = 0 },
						failure = { type = "local_execution_failure", detail = "no_progress" },
					},
				},
			},
		},
	}
	local lastJobIndex = 0

	local runOk, runErr = OrchestratorAgent.run({
		submitDesignIntent = function(intent, rawText: string)
			table.insert(orchestratorSubmits, { raw_text = rawText, intent = intent })
			lastJobIndex += 1
			return true, nil
		end,
		submit = function(rawText: string)
			table.insert(orchestratorSubmits, { raw_text = rawText, intent = nil })
			lastJobIndex += 1
			return true, nil
		end,
		getLastJob = function()
			return jobs[lastJobIndex]
		end,
		isCameraDemoActive = function()
			return false
		end,
		deps = {
			ensureBaseline = function()
				return true, nil
			end,
			orchestrate = function(context: OrchestratorContext): (OrchestratorDecision, string?)
				table.insert(orchestratorContexts, context)
				if #orchestratorContexts == 1 then
					return repeatedDecision, nil
				end
				return { action = "begin_loop", rationale = "history says stop repeating sector 2" }, nil
			end,
			setPhase = function() end,
			setAttemptBudget = function() end,
			appendLog = function() end,
			trace = function() end,
			setOrchestratorTelemetry = function(payload: OrchestratorTelemetry)
				table.insert(telemetryPayloads, payload)
			end,
			startContinuousLoop = function()
				loopStarted = true
				return true, nil
			end,
		},
	})

	local firstSubmit = orchestratorSubmits[1]
	local firstIntent = if firstSubmit ~= nil then firstSubmit.intent else nil
	T.expect(
		"phase14_5_orchestrator_runs_until_begin_loop_with_history",
		runOk == true
			and runErr == nil
			and loopStarted == true
			and firstSubmit ~= nil
			and firstSubmit.raw_text == "add an extreme tall jump in sector 2"
			and firstIntent ~= nil
			and firstIntent.desired_feel == repeatedDecision.desired_feel,
		tostring(runErr)
	)
	local secondContext = orchestratorContexts[2]
	local secondHistory = if secondContext ~= nil then secondContext.attempt_history else nil
	local secondCounts = if secondContext ~= nil then secondContext.sector_attempt_counts else nil
	local secondRepeat = if secondContext ~= nil then secondContext.mechanic_repeat_pressure else nil
	local secondTrackIntent = if secondContext ~= nil then secondContext.track_intent else nil
	local secondBudgetUsed = if secondContext ~= nil then secondContext.budget.used else 999
	local secondTargetBudgetUsed = if secondTrackIntent ~= nil then secondTrackIntent.target_budget_used else 999
	T.expect(
		"phase14_5_orchestrator_buildContext_includes_history",
		secondContext ~= nil
			and secondHistory ~= nil
			and #secondHistory >= 1
			and secondCounts ~= nil
			and (secondCounts[2] or 0) == 1
			and secondRepeat ~= nil
			and (secondRepeat[EnduranceObjective.signature(repeatedDecision)] or 0) == 1
			and secondTrackIntent ~= nil
			-- Phase 24 contract: endurance budget refresh comes from committed full-lap
			-- results only, so a reverted attempt keeps budget used unchanged.
			and math.abs(secondBudgetUsed) < 0.001
			and math.abs(secondTargetBudgetUsed) < 0.001,
		HttpService:JSONEncode(orchestratorContexts[2] or {})
	)
	local lastTelemetry = telemetryPayloads[#telemetryPayloads]
	local lastFailureSignature = if lastTelemetry ~= nil then lastTelemetry.failure_signature else nil
	T.expect(
		"phase14_5_orchestrator_telemetry_captures_failure_signature",
		#telemetryPayloads >= 2
			and lastFailureSignature ~= nil
			and string.find(lastFailureSignature, "no_progress", 1, true) ~= nil,
		HttpService:JSONEncode(lastTelemetry or {})
	)
	local lastDecision = if lastTelemetry ~= nil then lastTelemetry.last_decision else nil
	T.expect(
		"phase14_5_begin_loop_telemetry_uses_player_facing_copy",
		#telemetryPayloads >= 1 and lastDecision == "TRACK READY",
		HttpService:JSONEncode(lastTelemetry or {})
	)
end

function TestPhase14_5.run()
	TestPhase14_5.runUnit()
end

return TestPhase14_5
