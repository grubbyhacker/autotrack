local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local T = require(script.Parent.TestUtils)
local JobRunner = require(script.Parent.JobRunner)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local OrchestratorPromptBuilder = require(script.Parent.Parent.Agent.OrchestratorPromptBuilder)
local PromptBuilder = require(script.Parent.Parent.Agent.PromptBuilder)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)

local TestPhase19 = {}

local function makeDesignIntent(sectorId: number, mechanic: string, paramsHint: string)
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params_hint = paramsHint,
		rationale = "lift track spectacle without repeating stale failures",
		target_score_band = "extreme",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "replace_if_gain",
		desired_feel = "big airtime but still recoverable",
		constraints = {
			"preserve downstream stability",
			"prefer ingress braking over egress braking",
		},
	}
end

local function makeOrchestratorContext()
	return {
		editable_sectors = { 2, 3, 4, 7, 8, 9 },
		sector_states = {
			[2] = { mechanic = nil, params = {}, score = 0 },
			[3] = { mechanic = "Chicane", params = { amplitude = 8 }, score = 12 },
			[4] = { mechanic = nil, params = {}, score = 0 },
			[7] = { mechanic = nil, params = {}, score = 0 },
			[8] = { mechanic = nil, params = {}, score = 0 },
			[9] = { mechanic = nil, params = {}, score = 0 },
		},
		budget = { used = 0.2, over_budget = false },
		attempt_budget = { used = 1, total = 8 },
		last_result = nil,
		attempt_history = {},
		sector_attempt_counts = {},
		mechanic_repeat_pressure = {},
		track_intent = {
			target_total_score = 12,
			target_budget_used = 0.2,
			diversity_pressure = {},
		},
	}
end

local function makeRequest(designIntent)
	local request = JobRunner._buildEnduranceRequest(
		designIntent,
		"internal intent artifact",
		"phase19-req"
	)
	return request
end

local function makePacket(request)
	return {
		request = request,
		sector_state = {
			sector_id = request.parsed.sector_id,
			mechanic = request.parsed.mechanic,
			params = {
				ramp_angle = 10,
				ramp_length = 24,
				gap_length = 10,
				landing_length = 18,
			},
			pads = { ingress = "Brake10", egress = "None" },
			version = 0,
		},
		attempt_index = 1,
		last_action = nil,
		run_result = {
			success = false,
			failure = { type = "local_execution_failure", sector_id = request.parsed.sector_id, detail = "no_progress" },
			metrics = {
				entry_speed = 45,
				exit_speed = 0,
				target_progress = 0.4,
				target_entered = true,
				target_exited = false,
				target_reacquired = false,
				target_airtime_distance = 4,
				target_vertical_displacement = 6,
				target_apex_min_speed = 12,
				lap_time = 31,
				slowdown_ratio = 1.15,
			},
		},
		diagnostics = {
			failure_sector = request.parsed.sector_id,
			hints = { "boost first", "avoid lengthening the ramp" },
		},
		legal_actions = {
			numeric_levers = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
			pads = { "ingress", "egress" },
		},
		design_intent = request.design_intent,
	}
end

function TestPhase19.run()
	local designIntent = makeDesignIntent(7, "RampJump", "extreme tall")
	local request = makeRequest(designIntent)
	local packet = makePacket(request)

	local orchestrationMessages = OrchestratorPromptBuilder.messages(makeOrchestratorContext())
	T.expect(
		"phase19_orchestrator_prompt_requests_full_design_intent",
		string.find(orchestrationMessages[1].content, "DesignIntent schema", 1, true) ~= nil
			and string.find(orchestrationMessages[1].content, "target_score_band", 1, true) ~= nil
			and string.find(orchestrationMessages[1].content, "desired_feel", 1, true) ~= nil
			and string.find(orchestrationMessages[1].content, "constraints", 1, true) ~= nil,
		orchestrationMessages[1].content
	)

	local proposeMessages = PromptBuilder.proposeMessages(request, designIntent)
	T.expect(
		"phase19_propose_messages_include_design_intent",
		string.find(proposeMessages[2].content, "Shared design intent:", 1, true) ~= nil
			and string.find(proposeMessages[2].content, "\"desired_feel\":\"big airtime but still recoverable\"", 1, true) ~= nil
			and string.find(proposeMessages[2].content, "\"target_score_band\":\"extreme\"", 1, true) ~= nil,
		proposeMessages[2].content
	)
	T.expect(
		"phase19_prompt_content_omits_string_roundtrip_dependency",
		string.find(proposeMessages[2].content, "Implement the shared design intent faithfully", 1, true) ~= nil,
		proposeMessages[2].content
	)

	local repairMessages = PromptBuilder.repairMessages(request, {}, packet, designIntent)
	local repairTail = repairMessages[#repairMessages].content
	T.expect(
		"phase19_repair_messages_include_same_design_intent",
		string.find(repairTail, "Shared design intent:", 1, true) ~= nil
			and string.find(repairTail, "\"replacement_intent\":\"replace_if_gain\"", 1, true) ~= nil,
		repairTail
	)
	T.expect(
		"phase19_repair_messages_preserve_constraints_language",
		string.find(repairTail, "Intent constraints:", 1, true) ~= nil
			and string.find(repairTail, "prefer ingress braking over egress braking", 1, true) ~= nil,
		repairTail
	)

	local structured = JobRunner._buildEnduranceRequest(designIntent, "not parseable as a player request", "phase19-intent")
	T.expect(
		"phase19_endurance_submit_bypasses_request_roundtrip",
		structured.origin == "endurance"
			and structured.design_intent ~= nil
			and structured.parsed.mechanic == "RampJump"
			and structured.parsed.sector_id == 7
			and structured.qualifiers[1] == "extreme",
		HttpService:JSONEncode(structured)
	)

	local playerRequest, playerErr = RequestParser.parse("add a jump in sector 7", "phase19-player")
	T.expect(
		"phase19_player_text_path_unchanged",
		playerErr == nil
			and playerRequest ~= nil
			and playerRequest.origin == "player"
			and playerRequest.design_intent == nil,
		tostring(playerErr)
	)

	LLMAdapter.setProvider("phase19-good", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 7,
				mechanic = "RampJump",
				params = {
					ramp_angle = 9,
					ramp_length = 24,
					gap_length = 6,
					landing_length = 24,
				},
				pads = { ingress = "Brake10", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					sector_id = 7,
					mechanic = "RampJump",
					params = {
						ramp_angle = 8,
						ramp_length = 22,
						gap_length = 5,
						landing_length = 26,
					},
					pads = { ingress = "Boost10", egress = "None" },
					version = 1,
				},
				explanation = "softened takeoff while preserving the jump",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode(designIntent)
		end,
	})

	local decision, _, decisionErr = LLMAdapter.orchestrate(makeOrchestratorContext())
	T.expect(
		"phase19_orchestrate_returns_design_intent",
		decisionErr == nil
			and decision ~= nil
			and decision.desired_feel == designIntent.desired_feel
			and decision.replacement_intent == designIntent.replacement_intent
			and decision.constraints[1] == designIntent.constraints[1],
		tostring(decisionErr or HttpService:JSONEncode(decision or {}))
	)

	LLMAdapter.setProvider("phase19-long-rationale", {
		propose = function()
			return "{}"
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			local verbose = makeDesignIntent(7, "RampJump", "extreme tall really long dramatic jump request with extra descriptive words")
			verbose.rationale = string.rep("This is a deliberately verbose rationale sentence that should be truncated safely. ", 4)
			verbose.desired_feel = string.rep("big airtime but still recoverable and readable to the player ", 4)
			verbose.constraints = {
				string.rep("preserve downstream stability and avoid overspending the slowdown budget ", 3),
				string.rep("prefer ingress braking over egress braking when softening this feature ", 3),
			}
			return HttpService:JSONEncode(verbose)
		end,
	})
	local longDecision, _, longDecisionErr = LLMAdapter.orchestrate(makeOrchestratorContext())
	T.expect(
		"phase19_orchestrate_truncates_long_text_fields",
		longDecisionErr == nil
			and longDecision ~= nil
			and #longDecision.rationale <= 120
			and #longDecision.desired_feel <= 120
			and #longDecision.params_hint <= 96
			and #longDecision.constraints[1] <= 96,
		tostring(longDecisionErr or HttpService:JSONEncode(longDecision or {}))
	)

	LLMAdapter.setProvider("phase19-good", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 7,
				mechanic = "RampJump",
				params = {
					ramp_angle = 9,
					ramp_length = 24,
					gap_length = 6,
					landing_length = 24,
				},
				pads = { ingress = "Brake10", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					sector_id = 7,
					mechanic = "RampJump",
					params = {
						ramp_angle = 8,
						ramp_length = 22,
						gap_length = 5,
						landing_length = 26,
					},
					pads = { ingress = "Boost10", egress = "None" },
					version = 1,
				},
				explanation = "softened takeoff while preserving the jump",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode(designIntent)
		end,
	})

	local _, _, _, _, repairErr = LLMAdapter.repair(packet, {}, designIntent)
	T.expect(
		"phase19_repair_accepts_design_intent_context",
		repairErr == nil,
		tostring(repairErr)
	)

	LLMAdapter.setProvider("phase19-bad-intent", {
		propose = function()
			return "{}"
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			local bad = makeDesignIntent(7, "RampJump", "extreme tall")
			bad.target_score_band = "absurd"
			return HttpService:JSONEncode(bad)
		end,
	})
	local _, _, invalidErr = LLMAdapter.orchestrate(makeOrchestratorContext())
	T.expect(
		"phase19_invalid_design_intent_rejected",
		type(invalidErr) == "string" and string.find(invalidErr, "target_score_band", 1, true) ~= nil,
		tostring(invalidErr)
	)

	LLMAdapter.setProvider("phase19-begin-loop", {
		propose = function()
			return "{}"
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			return HttpService:JSONEncode({ action = "begin_loop", rationale = "track is balanced enough" })
		end,
	})
	local beginLoopDecision, _, beginLoopErr = LLMAdapter.orchestrate(makeOrchestratorContext())
	T.expect(
		"phase19_begin_loop_supported",
		beginLoopErr == nil and beginLoopDecision ~= nil and beginLoopDecision.action == "begin_loop",
		tostring(beginLoopErr)
	)

	LLMTraceJournal.clearForTests()
	LLMTraceJournal.beginRun({
		owner = "phase19_test",
		mode = "unit",
	})

	LLMAdapter.setProvider("phase19-trace", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 7,
				mechanic = "RampJump",
				params = {
					ramp_angle = 9,
					ramp_length = 24,
					gap_length = 6,
					landing_length = 24,
				},
				pads = { ingress = "Brake10", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					sector_id = 7,
					mechanic = "RampJump",
					params = {
						ramp_angle = 8,
						ramp_length = 22,
						gap_length = 5,
						landing_length = 26,
					},
					pads = { ingress = "Boost10", egress = "None" },
					version = 1,
				},
				explanation = "softened takeoff while preserving the jump",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode(designIntent)
		end,
	})

	local _, _, traceOrchestrateErr = LLMAdapter.orchestrate(makeOrchestratorContext())
	local _, _, traceProposeErr = LLMAdapter.propose(request, designIntent)
	local _, _, _, _, traceRepairErr = LLMAdapter.repair(packet, {}, designIntent)
	T.expect(
		"phase19_trace_seed_calls_succeeded",
		traceOrchestrateErr == nil and traceProposeErr == nil and traceRepairErr == nil,
		tostring(traceOrchestrateErr or traceProposeErr or traceRepairErr)
	)

	LLMTraceJournal.finishRun({
		outcome = "phase19_trace_seed",
	})
	local exported = LLMTraceJournal.exportLatestRun() or {}
	local sawOrchestrateIntent = false
	local sawProposeIntent = false
	local sawRepairIntent = false
	for _, event in ipairs(exported.events or {}) do
		if event.direction == "prompt" and event.kind == "orchestrate" and event.payload and event.payload.messages then
			local decoded = HttpService:JSONEncode(event.payload.messages)
			if string.find(decoded, "target_score_band", 1, true) ~= nil then
				sawOrchestrateIntent = true
			end
		end
		if event.direction == "prompt" and event.kind == "propose" and event.payload and event.payload.design_intent then
			sawProposeIntent = event.payload.design_intent.desired_feel == designIntent.desired_feel
		end
		if event.direction == "prompt" and event.kind == "repair" and event.payload and event.payload.design_intent then
			sawRepairIntent = event.payload.design_intent.constraints[1] == designIntent.constraints[1]
		end
	end
	T.expect(
		"phase19_trace_records_design_intent_for_all_roles",
		sawOrchestrateIntent and sawProposeIntent and sawRepairIntent,
		HttpService:JSONEncode(exported)
	)

	LLMTraceJournal.clearForTests()
	LLMAdapter.useMockProvider()
end

return TestPhase19
