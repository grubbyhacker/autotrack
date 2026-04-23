local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local EnduranceMemory = require(script.Parent.EnduranceMemory)
local JobRunner = require(script.Parent.JobRunner)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local OrchestratorPromptBuilder = require(script.Parent.Parent.Agent.OrchestratorPromptBuilder)
local PromptBuilder = require(script.Parent.Parent.Agent.PromptBuilder)
local UIState = require(script.Parent.UIState)

type MemoryEntry = Types.MemoryEntry

local TestPhase20 = {}

local function makeStoredNote(author: string, scope: string, note: string, sourceRef: string): MemoryEntry
	return {
		entry_id = author .. "-" .. scope .. "-" .. sourceRef,
		author = author,
		scope = scope,
		note = note,
		confidence = "medium",
		source_type = "observed_result",
		source_ref = sourceRef,
		timestamp = 100,
	}
end

local function makeMemory()
	local memory = EnduranceMemory.new()
	EnduranceMemory.append(
		memory,
		"shared",
		makeStoredNote("orchestrator", "shared", "Prefer stable exits when budget headroom drops.", "shared-1")
	)
	EnduranceMemory.append(
		memory,
		"proposal",
		makeStoredNote("proposal", "proposal", "Shorter landings have been unstable in sector 7.", "proposal-1")
	)
	EnduranceMemory.append(
		memory,
		"repair",
		makeStoredNote("repair", "repair", "Boost before lengthening a stalled ramp.", "repair-1")
	)
	return memory
end

local function makeDesignIntent()
	return {
		sector_id = 7,
		mechanic = "RampJump",
		params_hint = "extreme tall",
		rationale = "raise spectacle without repeating stale failures",
		target_score_band = "extreme",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "replace_if_gain",
		desired_feel = "big airtime but still recoverable",
		constraints = {
			"preserve downstream stability",
			"avoid overspending slowdown budget",
		},
	}
end

local function makeContext(memory)
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
		memory = EnduranceMemory.clone(memory),
	}
end

local function makeRequest(memory)
	return JobRunner._buildEnduranceRequest(makeDesignIntent(), "internal memory artifact", "phase20-req", memory)
end

local function makeState()
	return {
		sector_id = 7,
		mechanic = "RampJump",
		params = {
			ramp_angle = 10,
			ramp_length = 24,
			gap_length = 10,
			landing_length = 18,
		},
		pads = { ingress = "Brake10", egress = "None" },
		version = 0,
	}
end

local function makeResult(success: boolean)
	return {
		success = success,
		failure = if success then nil else { type = "local_execution_failure", sector_id = 7, detail = "no_progress" },
		metrics = {
			entry_speed = 45,
			exit_speed = if success then 38 else 0,
			target_progress = if success then 1 else 0.4,
			target_entered = true,
			target_exited = success,
			target_reacquired = success,
			target_airtime_distance = if success then 11 else 4,
			target_vertical_displacement = if success then 5 else 6,
			target_apex_min_speed = if success then 22 else 12,
			lap_time = 31,
			slowdown_ratio = if success then 1.08 else 1.15,
		},
		score = if success
			then {
				total = 22,
				air = 7,
				lateral = 2,
				near_miss = 4,
				time_cost = 1,
				budget_used = 0.35,
				over_budget = false,
			}
			else nil,
	}
end

local function makePacket(request)
	return {
		request = request,
		sector_state = makeState(),
		attempt_index = 1,
		last_action = nil,
		run_result = makeResult(false),
		diagnostics = {
			failure_sector = 7,
			hints = { "boost first", "avoid lengthening the ramp" },
		},
		legal_actions = {
			numeric_levers = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
			pads = { "ingress", "egress" },
		},
		design_intent = request.design_intent,
		memory_context = request.memory_context,
	}
end

function TestPhase20.run()
	local memory = makeMemory()
	local request = makeRequest(memory)
	local packet = makePacket(request)

	local orchestrationMessages = OrchestratorPromptBuilder.messages(makeContext(memory))
	T.expect(
		"phase20_orchestrator_prompt_includes_shared_and_local_memory",
		string.find(orchestrationMessages[2].content, "Relevant memory:", 1, true) ~= nil
			and string.find(
					orchestrationMessages[2].content,
					"Prefer stable exits when budget headroom drops.",
					1,
					true
				)
				~= nil,
		orchestrationMessages[2].content
	)

	local proposeMessages = PromptBuilder.proposeMessages(request, request.design_intent)
	T.expect(
		"phase20_propose_prompt_includes_shared_and_proposal_memory",
		string.find(proposeMessages[2].content, "Relevant memory:", 1, true) ~= nil
			and string.find(proposeMessages[2].content, "Shorter landings have been unstable in sector 7.", 1, true)
				~= nil,
		proposeMessages[2].content
	)

	local repairMessages = PromptBuilder.repairMessages(request, {}, packet, request.design_intent)
	local repairTail = repairMessages[#repairMessages].content
	T.expect(
		"phase20_repair_prompt_includes_shared_and_repair_memory",
		string.find(repairTail, "Relevant memory:", 1, true) ~= nil
			and string.find(repairTail, "Boost before lengthening a stalled ramp.", 1, true) ~= nil,
		repairTail
	)

	LLMAdapter.setProvider("phase20-notes", {
		propose = function()
			return HttpService:JSONEncode({
				state = makeState(),
				memory_note = {
					author = "proposal",
					scope = "proposal",
					note = "Wide landings are preserving recovery better than long gaps.",
					confidence = "medium",
					source_type = "inferred_pattern",
					source_ref = "proposal-phase20",
				},
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
				memory_note = {
					author = "repair",
					scope = "repair",
					note = "Entry boost fixed the uphill stall without flattening the jump.",
					confidence = "high",
					source_type = "observed_result",
					source_ref = "repair-phase20",
				},
			})
		end,
		orchestrate = function()
			local decision = makeDesignIntent()
			decision.memory_note = {
				author = "orchestrator",
				scope = "orchestrator",
				note = "Sector 7 still has room for spectacle if recovery stays readable.",
				confidence = "medium",
				source_type = "explicit_policy",
				source_ref = "decision-1",
			}
			return HttpService:JSONEncode(decision)
		end,
	})

	local decision, decisionNote, decisionErr = LLMAdapter.orchestrate(makeContext(memory))
	T.expect(
		"phase20_orchestrate_accepts_optional_memory_note",
		decisionErr == nil
			and decision ~= nil
			and decisionNote ~= nil
			and decisionNote.scope == "orchestrator"
			and decisionNote.author == "orchestrator",
		tostring(decisionErr or HttpService:JSONEncode(decisionNote or {}))
	)

	local proposedState, proposalNote, proposalErr = LLMAdapter.propose(request, request.design_intent)
	T.expect(
		"phase20_propose_accepts_optional_memory_note",
		proposalErr == nil
			and proposedState ~= nil
			and proposalNote ~= nil
			and proposalNote.scope == "proposal"
			and proposalNote.author == "proposal",
		tostring(proposalErr or HttpService:JSONEncode(proposalNote or {}))
	)

	local _, repairedState, _, repairNote, repairErr = LLMAdapter.repair(packet, {}, request.design_intent)
	T.expect(
		"phase20_repair_accepts_optional_memory_note",
		repairErr == nil
			and repairedState ~= nil
			and repairNote ~= nil
			and repairNote.scope == "repair"
			and repairNote.author == "repair",
		tostring(repairErr or HttpService:JSONEncode(repairNote or {}))
	)

	LLMAdapter.setProvider("phase20-bad-scope", {
		propose = function()
			return HttpService:JSONEncode({
				state = makeState(),
				memory_note = {
					author = "proposal",
					scope = "shared",
					note = "bad shared write",
					confidence = "medium",
					source_type = "inferred_pattern",
					source_ref = "bad-proposal",
				},
			})
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			return HttpService:JSONEncode(makeDesignIntent())
		end,
	})
	local _, _, badScopeErr = LLMAdapter.propose(request, request.design_intent)
	T.expect("phase20_normalizes_invalid_memory_scope_for_role", badScopeErr == nil, tostring(badScopeErr))

	LLMAdapter.setProvider("phase20-long-note", {
		propose = function()
			return HttpService:JSONEncode({
				state = makeState(),
				memory_note = {
					author = "proposal",
					scope = "proposal",
					note = string.rep("x", 121),
					confidence = "medium",
					source_type = "inferred_pattern",
					source_ref = "too-long",
				},
			})
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			return HttpService:JSONEncode(makeDesignIntent())
		end,
	})
	local _, longProposalNote, longErr = LLMAdapter.propose(request, request.design_intent)
	T.expect(
		"phase20_truncates_oversized_memory_note",
		longErr == nil and longProposalNote ~= nil and #longProposalNote.note == 120,
		tostring(longErr or HttpService:JSONEncode(longProposalNote or {}))
	)

	LLMAdapter.setProvider("phase20-empty-note", {
		propose = function()
			return HttpService:JSONEncode({
				state = makeState(),
				memory_note = {
					author = "proposal",
					scope = "proposal",
					note = "   ",
					confidence = "medium",
					source_type = "inferred_pattern",
					source_ref = "empty-note",
				},
			})
		end,
		repair = function()
			return "{}"
		end,
		orchestrate = function()
			return HttpService:JSONEncode(makeDesignIntent())
		end,
	})
	local emptyNoteState, emptyProposalNote, emptyNoteErr = LLMAdapter.propose(request, request.design_intent)
	T.expect(
		"phase20_ignores_empty_memory_note",
		emptyNoteErr == nil and emptyNoteState ~= nil and emptyProposalNote == nil,
		tostring(emptyNoteErr or HttpService:JSONEncode(emptyProposalNote or {}))
	)

	local sourceMemory = makeMemory()
	local clonedRequest = JobRunner._buildEnduranceRequest(makeDesignIntent(), "memory", "phase20-clone", sourceMemory)
	EnduranceMemory.append(
		sourceMemory,
		"proposal",
		makeStoredNote("proposal", "proposal", "new source note", "proposal-2")
	)
	T.expect(
		"phase20_endurance_request_carries_memory_context",
		clonedRequest.memory_context ~= nil
			and (clonedRequest.memory_context.proposal[1] and clonedRequest.memory_context.proposal[1].note)
				== "Shorter landings have been unstable in sector 7.",
		HttpService:JSONEncode(clonedRequest.memory_context or {})
	)

	local packetFromEvaluator =
		LapEvaluator.buildFailurePacket(request, makeState(), 1, nil, makeResult(false), 7, { "boost first" }, nil)
	T.expect(
		"phase20_failure_packet_carries_memory_context",
		packetFromEvaluator.memory_context ~= nil
			and packetFromEvaluator.memory_context.shared[1] ~= nil
			and packetFromEvaluator.memory_context.shared[1].note
				== "Prefer stable exits when budget headroom drops.",
		HttpService:JSONEncode(packetFromEvaluator.memory_context or {})
	)

	local notebook = EnduranceMemory.new()
	for index = 1, 7 do
		EnduranceMemory.append(
			notebook,
			"proposal",
			makeStoredNote("proposal", "proposal", "proposal note " .. index, "p" .. index)
		)
	end
	T.expect(
		"phase20_role_local_memory_appends_newest_first",
		notebook.proposal[1] ~= nil and notebook.proposal[1].note == "proposal note 7",
		HttpService:JSONEncode(notebook.proposal)
	)
	T.expect(
		"phase20_role_local_memory_ring_buffer_drops_oldest",
		#notebook.proposal == 6 and notebook.proposal[6].note == "proposal note 2",
		HttpService:JSONEncode(notebook.proposal)
	)

	local sharedNotebook = EnduranceMemory.new()
	local sharedEntry =
		makeStoredNote("orchestrator", "shared", "Keep sector 7 recoverable under budget pressure.", "shared-a")
	local firstShared = EnduranceMemory.appendSharedIfFresh(sharedNotebook, sharedEntry)
	local secondShared = EnduranceMemory.appendSharedIfFresh(sharedNotebook, sharedEntry)
	T.expect(
		"phase20_shared_memory_skips_exact_duplicate_lessons",
		firstShared == true and secondShared == false and #sharedNotebook.shared == 1,
		HttpService:JSONEncode(sharedNotebook.shared)
	)

	local orchestratorContexts = {}
	local submittedMemory = nil
	local jobs = {
		{
			request = makeRequest(makeMemory()),
			working_state = makeState(),
			final_status = "committed",
			proposal_memory_note = makeStoredNote(
				"proposal",
				"proposal",
				"Landing length helped recovery.",
				"job-proposal"
			),
			attempts = {
				{
					attempt_index = 0,
					action = nil,
					proposed_state = makeState(),
					result = makeResult(true),
					hints = {},
					memory_note = makeStoredNote(
						"repair",
						"repair",
						"Boost10 preserved momentum without overspeeding the exit.",
						"job-repair"
					),
				},
			},
		},
	}
	local lastJobIndex = 0

	local runOk, runErr = OrchestratorAgent.run({
		submitDesignIntent = function(_, _, memoryContext)
			submittedMemory = memoryContext
			lastJobIndex = 1
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
					return makeDesignIntent(),
						makeStoredNote(
							"orchestrator",
							"orchestrator",
							"Sector 7 can still take a readable jump.",
							"orch-note"
						),
						nil
				end
				return { action = "begin_loop", rationale = "track balanced enough" }, nil, nil
			end,
			setPhase = function() end,
			setAttemptBudget = function() end,
			appendLog = function() end,
			trace = function() end,
			setOrchestratorTelemetry = function() end,
			startContinuousLoop = function()
				return true, nil
			end,
		},
	})
	T.expect(
		"phase20_shared_memory_promotion_requires_final_outcome",
		runOk == true
			and runErr == nil
			and submittedMemory ~= nil
			and #submittedMemory.shared == 0
			and #orchestratorContexts >= 2
			and #orchestratorContexts[2].memory.shared == 1
			and #orchestratorContexts[2].memory.proposal == 1
			and #orchestratorContexts[2].memory.repair == 1,
		HttpService:JSONEncode({
			submitted = submittedMemory,
			next_context = orchestratorContexts[2] and orchestratorContexts[2].memory or nil,
		})
	)

	local fallbackSubmits = {}
	local fallbackLogs = {}
	local fallbackWarnings = {}
	local fallbackLoopStarted = false
	local fallbackJobs = {
		{
			request = makeRequest(EnduranceMemory.new()),
			working_state = makeState(),
			final_status = "committed",
			proposal_memory_note = nil,
			attempts = {
				{
					attempt_index = 0,
					action = nil,
					proposed_state = makeState(),
					result = makeResult(true),
					hints = {},
					memory_note = nil,
				},
			},
		},
	}
	local fallbackJobIndex = 0

	local fallbackOk, fallbackErr = OrchestratorAgent.run({
		submitDesignIntent = function(intent, rawText, memoryContext)
			table.insert(fallbackSubmits, {
				intent = intent,
				rawText = rawText,
				memory = memoryContext,
			})
			fallbackJobIndex = 1
			return true, nil
		end,
		getLastJob = function()
			return fallbackJobs[fallbackJobIndex]
		end,
		isCameraDemoActive = function()
			return false
		end,
		deps = {
			ensureBaseline = function()
				return true, nil
			end,
			orchestrate = function(_context)
				if #fallbackLogs == 0 then
					return nil, nil, "invalid orchestrate response: sector_id must be an editable sector"
				end
				return { action = "begin_loop", rationale = "fallback done" }, nil, nil
			end,
			setPhase = function() end,
			setAttemptBudget = function() end,
			setLLMWarning = function(text)
				table.insert(fallbackWarnings, text)
			end,
			appendLog = function(line)
				table.insert(fallbackLogs, line)
			end,
			trace = function() end,
			setOrchestratorTelemetry = function() end,
			startContinuousLoop = function()
				fallbackLoopStarted = true
				return true, nil
			end,
		},
	})
	T.expect(
		"phase20_invalid_orchestrate_response_falls_back_to_minimal_orchestrator",
		fallbackOk == true
			and fallbackErr == nil
			and fallbackLoopStarted == true
			and #fallbackSubmits == 1
			and fallbackSubmits[1].intent ~= nil
			and fallbackSubmits[1].intent.sector_id == 2
			and fallbackWarnings[1] == ""
			and fallbackWarnings[2] == "Orchestrator response invalid; using deterministic fallback"
			and string.find(fallbackLogs[1] or "", "deterministic fallback", 1, true) ~= nil,
		HttpService:JSONEncode({
			submits = fallbackSubmits,
			logs = fallbackLogs,
			warnings = fallbackWarnings,
		})
	)

	local prematureSubmits = {}
	local prematureWarnings = {}
	local prematureLogs = {}
	local prematureLoopStarted = false
	local prematureJobs = {
		{
			request = makeRequest(EnduranceMemory.new()),
			working_state = makeState(),
			final_status = "committed",
			proposal_memory_note = nil,
			attempts = {
				{
					attempt_index = 0,
					action = nil,
					proposed_state = makeState(),
					result = makeResult(true),
					hints = {},
					memory_note = nil,
				},
			},
		},
	}
	local prematureJobIndex = 0
	local prematureOrchestrateCalls = 0

	local prematureOk, prematureErr = OrchestratorAgent.run({
		submitDesignIntent = function(intent, rawText, memoryContext)
			table.insert(prematureSubmits, {
				intent = intent,
				rawText = rawText,
				memory = memoryContext,
			})
			prematureJobIndex = 1
			return true, nil
		end,
		getLastJob = function()
			return prematureJobs[prematureJobIndex]
		end,
		isCameraDemoActive = function()
			return false
		end,
		deps = {
			ensureBaseline = function()
				return true, nil
			end,
			orchestrate = function()
				prematureOrchestrateCalls += 1
				if prematureOrchestrateCalls == 1 then
					return { action = "begin_loop", rationale = "track ready immediately" }, nil, nil
				end
				return { action = "begin_loop", rationale = "track ready after first build" }, nil, nil
			end,
			setPhase = function() end,
			setAttemptBudget = function() end,
			setLLMWarning = function(text)
				table.insert(prematureWarnings, text)
			end,
			appendLog = function(line)
				table.insert(prematureLogs, line)
			end,
			trace = function() end,
			setOrchestratorTelemetry = function() end,
			startContinuousLoop = function()
				prematureLoopStarted = true
				return true, nil
			end,
		},
	})
	T.expect(
		"phase20_premature_begin_loop_falls_back_to_candidate",
		prematureOk == true
			and prematureErr == nil
			and prematureLoopStarted == true
			and #prematureSubmits == 1
			and prematureSubmits[1].intent ~= nil
			and prematureSubmits[1].intent.action == nil
			and prematureSubmits[1].intent.sector_id == 2
			and prematureWarnings[1] == ""
			and prematureWarnings[2] == "Orchestrator chose track ready before any build; using deterministic fallback"
			and string.find(prematureLogs[1] or "", "before any build", 1, true) ~= nil,
		HttpService:JSONEncode({
			submits = prematureSubmits,
			warnings = prematureWarnings,
			logs = prematureLogs,
			calls = prematureOrchestrateCalls,
		})
	)

	LLMTraceJournal.clearForTests()
	LLMTraceJournal.beginRun({
		owner = "phase20_test",
		mode = "unit",
	})
	LLMAdapter.setProvider("phase20-trace", {
		propose = function()
			return HttpService:JSONEncode({
				state = makeState(),
				memory_note = {
					author = "proposal",
					scope = "proposal",
					note = "Trace proposal note",
					confidence = "medium",
					source_type = "inferred_pattern",
					source_ref = "trace-proposal",
				},
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = makeState(),
				explanation = "trace repair",
				memory_note = {
					author = "repair",
					scope = "repair",
					note = "Trace repair note",
					confidence = "medium",
					source_type = "observed_result",
					source_ref = "trace-repair",
				},
			})
		end,
		orchestrate = function()
			local traceDecision = makeDesignIntent()
			traceDecision.memory_note = {
				author = "orchestrator",
				scope = "orchestrator",
				note = "Trace orchestration note",
				confidence = "medium",
				source_type = "explicit_policy",
				source_ref = "trace-orchestrate",
			}
			return HttpService:JSONEncode(traceDecision)
		end,
	})
	local _, _, traceOrchestrateErr = LLMAdapter.orchestrate(makeContext(memory))
	local _, _, traceProposeErr = LLMAdapter.propose(request, request.design_intent)
	local _, _, _, _, traceRepairErr = LLMAdapter.repair(packet, {}, request.design_intent)
	T.expect(
		"phase20_trace_seed_calls_succeeded",
		traceOrchestrateErr == nil and traceProposeErr == nil and traceRepairErr == nil,
		tostring(traceOrchestrateErr or traceProposeErr or traceRepairErr)
	)
	LLMTraceJournal.finishRun({ outcome = "phase20_trace_seed" })
	local exported = LLMTraceJournal.exportLatestRun() or {}
	local sawPromptMemory = false
	local sawResponseMemory = false
	for _, event in ipairs(exported.events or {}) do
		if event.direction == "prompt" and event.payload and event.payload.memory_context then
			sawPromptMemory = true
		end
		if
			event.direction == "response"
			and event.payload
			and event.payload.decoded_response
			and event.payload.decoded_response.memory_note
		then
			sawResponseMemory = true
		end
	end
	T.expect(
		"phase20_trace_records_memory_context_and_notes",
		sawPromptMemory and sawResponseMemory,
		HttpService:JSONEncode(exported)
	)

	UIState.init(-1)
	local stateFolder = UIState.getStateFolder()
	local proposalWarning = JobRunner._invalidAgentResponseWarning("invalid proposal: sector_id mismatch")
	local repairWarning =
		JobRunner._invalidAgentResponseWarning("invalid repair: explanation must be short non-empty text")
	T.expect(
		"phase20_formats_invalid_agent_response_warnings",
		proposalWarning == "Proposal response invalid: sector_id mismatch"
			and repairWarning == "Repair response invalid: explanation must be short non-empty text",
		HttpService:JSONEncode({
			proposal = proposalWarning,
			repair = repairWarning,
		})
	)

	UIState.rejectRequest("bad request", "invalid proposal: sector_id mismatch", proposalWarning)
	T.expect(
		"phase20_reject_request_surfaces_agent_warning",
		(stateFolder:GetAttribute("error_text") or "") == "invalid proposal: sector_id mismatch"
			and (stateFolder:GetAttribute("llm_warning_text") or "")
				== "Proposal response invalid: sector_id mismatch",
		HttpService:JSONEncode({
			error = stateFolder:GetAttribute("error_text"),
			warning = stateFolder:GetAttribute("llm_warning_text"),
		})
	)

	UIState.publishReady()
	T.expect(
		"phase20_hud_defaults_include_memory_fields",
		(stateFolder:GetAttribute("shared_memory_depth") or -1) == 0
			and (stateFolder:GetAttribute("proposal_memory_depth") or -1) == 0
			and (stateFolder:GetAttribute("repair_memory_depth") or -1) == 0
			and (stateFolder:GetAttribute("shared_memory_1") or "x") == ""
			and (stateFolder:GetAttribute("llm_warning_text") or "x") == "",
		"missing phase20 HUD defaults"
	)

	UIState.setOrchestratorTelemetry({
		shared_memory_depth = 2,
		proposal_memory_depth = 1,
		repair_memory_depth = 1,
		shared_memory_lines = { "Shared lesson A", "Shared lesson B" },
		proposal_memory_lines = { "Proposal lesson" },
		repair_memory_lines = { "Repair lesson" },
	})
	T.expect(
		"phase20_hud_state_surfaces_compact_memory_summary",
		(stateFolder:GetAttribute("shared_memory_depth") or 0) == 2
			and (stateFolder:GetAttribute("shared_memory_1") or "") == "Shared lesson A"
			and (stateFolder:GetAttribute("proposal_memory_1") or "") == "Proposal lesson"
			and (stateFolder:GetAttribute("repair_memory_1") or "") == "Repair lesson",
		"phase20 HUD telemetry missing memory attrs"
	)

	LLMTraceJournal.clearForTests()
	LLMAdapter.useMockProvider()
end

return TestPhase20
