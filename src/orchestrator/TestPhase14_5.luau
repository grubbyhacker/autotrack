local HttpService = game:GetService("HttpService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local TestUtils = require(script.Parent.TestUtils)
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local EnduranceObjective = require(script.Parent.EnduranceObjective)
local MinimalOrchestrator = require(script.Parent.MinimalOrchestrator)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local UIState = require(script.Parent.UIState)

type OrchestratorContext = Types.OrchestratorContext

local T = TestUtils
local TestPhase14_5 = {}

local function makeContext(): OrchestratorContext
	return {
		editable_sectors = { 2, 3, 4, 7, 8, 9 },
		sector_states = {
			[2] = { mechanic = nil, params = {}, score = 0 },
			[3] = { mechanic = nil, params = {}, score = 0 },
			[4] = { mechanic = nil, params = {}, score = 0 },
			[7] = { mechanic = nil, params = {}, score = 0 },
			[8] = { mechanic = nil, params = {}, score = 0 },
			[9] = { mechanic = nil, params = {}, score = 0 },
		},
		budget = { used = 0.2, over_budget = false },
		attempt_budget = { used = 0, total = Constants.ENDURANCE_ATTEMPT_BUDGET },
		last_result = nil,
		attempt_history = {},
		sector_attempt_counts = {},
		mechanic_repeat_pressure = {},
		track_intent = {
			target_total_score = 0,
			target_budget_used = 0.2,
			diversity_pressure = {},
		},
	}
end

function TestPhase14_5.runUnit()
	local repeatedDecision = {
		sector_id = 2,
		mechanic = "RampJump",
		params_hint = "extreme tall",
	}
	local alternateDecision = {
		sector_id = 3,
		mechanic = "CrestDip",
		params_hint = "extreme deep",
	}

	local objectiveContext = makeContext()
	objectiveContext.attempt_history = {
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
	objectiveContext.sector_attempt_counts = { [2] = 3 }
	objectiveContext.mechanic_repeat_pressure = {
		[EnduranceObjective.signature(repeatedDecision)] = 3,
	}
	objectiveContext.track_intent.diversity_pressure = {
		[EnduranceObjective.signature(repeatedDecision)] = 3,
	}

	local repeatedScore = select(1, EnduranceObjective.evaluateCandidate(objectiveContext, repeatedDecision))
	local alternateScore = select(1, EnduranceObjective.evaluateCandidate(objectiveContext, alternateDecision))
	T.expect(
		"phase14_5_objective_skips_repeated_failed_signature",
		EnduranceObjective.shouldAvoidRepeat(objectiveContext, repeatedDecision) == true and alternateScore.total > repeatedScore.total,
		HttpService:JSONEncode({
			repeated = repeatedScore,
			alternate = alternateScore,
		})
	)

	local fallbackDecision = MinimalOrchestrator.decide(objectiveContext)
	T.expect(
		"phase14_5_minimal_orchestrator_uses_context_fallback_without_nondeterminism",
		fallbackDecision.action == nil and fallbackDecision.sector_id == 3 and fallbackDecision.mechanic == "CrestDip",
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

	local orchestratorContexts = {}
	local telemetryPayloads = {}
	local orchestratorSubmits = {}
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
		submit = function(rawText: string)
			table.insert(orchestratorSubmits, rawText)
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
			orchestrate = function(context)
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
			setOrchestratorTelemetry = function(payload)
				table.insert(telemetryPayloads, payload)
			end,
			startContinuousLoop = function()
				loopStarted = true
				return true, nil
			end,
		},
	})

	T.expect(
		"phase14_5_orchestrator_runs_until_begin_loop_with_history",
		runOk == true and runErr == nil and loopStarted == true and orchestratorSubmits[1] == "add an extreme tall jump in sector 2",
		tostring(runErr)
	)
	T.expect(
		"phase14_5_orchestrator_buildContext_includes_history",
		#orchestratorContexts >= 2
			and #orchestratorContexts[2].attempt_history >= 1
			and (orchestratorContexts[2].sector_attempt_counts[2] or 0) == 1
			and (orchestratorContexts[2].mechanic_repeat_pressure[EnduranceObjective.signature(repeatedDecision)] or 0) == 1
			and orchestratorContexts[2].track_intent ~= nil
			and math.abs((orchestratorContexts[2].track_intent.target_budget_used or 0) - math.clamp((1.3 - 1) / Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO, 0, 1)) < 0.001,
		HttpService:JSONEncode(orchestratorContexts[2] or {})
	)
	T.expect(
		"phase14_5_orchestrator_telemetry_captures_failure_signature",
		#telemetryPayloads >= 2
			and type(telemetryPayloads[#telemetryPayloads].failure_signature) == "string"
			and string.find(telemetryPayloads[#telemetryPayloads].failure_signature, "no_progress", 1, true) ~= nil,
		HttpService:JSONEncode(telemetryPayloads[#telemetryPayloads] or {})
	)
end

function TestPhase14_5.run()
	TestPhase14_5.runUnit()
end

return TestPhase14_5
