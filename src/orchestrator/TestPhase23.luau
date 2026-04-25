--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local PromptBuilder = require(script.Parent.Parent.Agent.PromptBuilder)
local OrchestratorPromptBuilder = require(script.Parent.Parent.Agent.OrchestratorPromptBuilder)
local EnduranceObjective = require(script.Parent.EnduranceObjective)
local JobRunner = require(script.Parent.JobRunner)
local MinimalProposer = require(script.Parent.MinimalProposer)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TestFactories = require(script.Parent.TestFactories)
local TuneMode = require(script.Parent.TuneMode)
local UIState = require(script.Parent.UIState)
local T = require(script.Parent.TestUtils)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorAttempt = Types.OrchestratorAttempt
type OrchestratorDecision = Types.OrchestratorDecision
type OrchestratorSectorSnapshot = Types.OrchestratorSectorSnapshot
type DesignIntent = Types.DesignIntent
type FailurePacket = Types.FailurePacket
type JsonObject = Types.JsonObject
type Request = Types.Request
type RunResult = Types.RunResult
type SectorState = Types.SectorState

local TestPhase23 = {}

local function waitUntil(predicate: () -> boolean, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait(0.1)
	end
	return predicate()
end

local function ensureReady(): boolean
	local ready = waitUntil(function()
		return RuntimeContext.isReady()
	end, 30)
	T.expect("phase23_runtime_context_ready", ready, "runtime context not ready")
	return ready
end

local function cleanup()
	if TuneMode.isActive() then
		TuneMode.stop()
		waitUntil(function()
			return not TuneMode.isActive()
		end, 5)
	end
	workspace:SetAttribute("AutoTrack_CarTargetSpeed", nil)
	UIState.publishReady()
end

local function decodeJsonObject(value: string): JsonObject?
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(value)
	end)
	if ok and type(decoded) == "table" then
		return decoded :: JsonObject
	end
	return nil
end

local function objectField(object: JsonObject, name: string): JsonObject?
	local value = object[name]
	if type(value) == "table" then
		return value :: JsonObject
	end
	return nil
end

local function numberField(object: JsonObject, name: string): number?
	local value = object[name]
	if type(value) == "number" then
		return value
	end
	return nil
end

local function stringField(object: JsonObject, name: string): string?
	local value = object[name]
	if type(value) == "string" then
		return value
	end
	return nil
end

local function getStringAttribute(instance: Instance, name: string): string
	local value = instance:GetAttribute(name)
	if type(value) == "string" then
		return value
	end
	return ""
end

local function getNumberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return 0
end

local function decodeTuneBaselineSnapshot(value: string): (number?, number?, string?, string?)
	local decoded = decodeJsonObject(value)
	if decoded == nil then
		return nil, nil, nil, nil
	end
	local params = objectField(decoded, "params")
	local pads = objectField(decoded, "pads")
	if params == nil or pads == nil then
		return nil, nil, nil, nil
	end
	return numberField(params, "ramp_angle"),
		numberField(params, "gap_length"),
		stringField(pads, "ingress"),
		stringField(pads, "egress")
end

local function comparePayloadHasExpectedShape(value: string): boolean
	local decoded = decodeJsonObject(value)
	if decoded == nil then
		return false
	end
	local baseline = objectField(decoded, "baseline")
	local candidate = objectField(decoded, "candidate")
	local summary = objectField(decoded, "summary")
	local candidateAggregate = candidate and objectField(candidate, "aggregate") or nil
	return baseline ~= nil
		and candidate ~= nil
		and summary ~= nil
		and stringField(baseline, "label") == "production_baseline"
		and string.find(tostring(stringField(candidate, "label") or ""), "candidate_v", 1, true) ~= nil
		and candidateAggregate ~= nil
		and numberField(candidateAggregate, "average_challenge_total") ~= nil
end

local function promotionSnapshotHasExpectedShape(value: string, expectedCandidateVersion: number): boolean
	local decoded = decodeJsonObject(value)
	if decoded == nil then
		return false
	end
	return objectField(decoded, "compare") ~= nil
		and objectField(decoded, "state") ~= nil
		and objectField(decoded, "attrs") ~= nil
		and numberField(decoded, "candidate_version") == expectedCandidateVersion
end

local function summaryText(state: SectorState?): string
	if state == nil or state.mechanic == nil then
		return "flat"
	end
	local parts: { string } = {}
	for _, lever in ipairs(LevelMappings.NUMERIC_LEVERS[state.mechanic] or {}) do
		local value = state.params[lever]
		if type(value) == "number" then
			table.insert(parts, string.format("%s=%s", lever, tostring(value)))
		end
	end
	table.insert(parts, string.format("ingress=%s", state.pads.ingress))
	table.insert(parts, string.format("egress=%s", state.pads.egress))
	return table.concat(parts, " | ")
end

local function makeContext(): OrchestratorContext
	local sectorStates: { [number]: OrchestratorSectorSnapshot } = {
		[2] = { mechanic = "RampJump", params = {}, score = 24 },
		[3] = { mechanic = nil, params = {}, score = 0 },
		[4] = { mechanic = nil, params = {}, score = 0 },
		[7] = { mechanic = "Chicane", params = {}, score = 18 },
		[8] = { mechanic = "CrestDip", params = {}, score = 20 },
		[9] = { mechanic = nil, params = {}, score = 0 },
	}
	local attemptHistory: { OrchestratorAttempt } = {
		{
			sector_id = 2,
			mechanic = "RampJump",
			params_hint = "safe long",
			normalized_signature = "s2|RampJump|safe long",
			outcome = "reverted",
			score = 0,
			slowdown_ratio = 1.05,
			failure_signature = "no_progress@s2|RampJump|safe long",
			repair_iterations = 3,
			decision_index = 1,
			timestamp = 1,
		},
	}
	return TestFactories.orchestratorContext({
		sector_states = sectorStates,
		budget = { used = 0.32, over_budget = false },
		attempt_budget = { used = 2, total = Constants.ENDURANCE_ATTEMPT_BUDGET },
		last_result = nil,
		attempt_history = attemptHistory,
		sector_attempt_counts = { [2] = 2 },
		mechanic_repeat_pressure = {
			["s2|RampJump|safe long"] = 2,
		},
		track_intent = {
			target_total_score = 62,
			target_budget_used = 0.32,
			diversity_pressure = {
				["s2|RampJump|safe long"] = 2,
			},
		},
		memory = TestFactories.emptyMemory(),
	})
end

local function testProductionBaselineReset()
	cleanup()
	local stateFolder = UIState.getStateFolder()

	local startOk, startErr = JobRunner.submit("/tune rampjump")
	local started = waitUntil(function()
		return TuneMode.isActive() and stateFolder:GetAttribute("tune_mode_active") == true
	end, 5)
	T.expect("phase23_tune_rampjump_starts", startOk == true and startErr == nil and started, tostring(startErr))

	local expectedBaseline, baselineErr = MinimalProposer.productionBaseline(3, "RampJump", {})
	local baselineSnapshotText = getStringAttribute(stateFolder, "tune_baseline_snapshot")
	local baselineRampAngle, baselineGapLength, baselineIngress, baselineEgress =
		decodeTuneBaselineSnapshot(baselineSnapshotText)
	T.expect(
		"phase23_production_baseline_snapshot_matches_proposer_baseline",
		expectedBaseline ~= nil
			and baselineErr == nil
			and baselineRampAngle == expectedBaseline.params.ramp_angle
			and baselineGapLength == expectedBaseline.params.gap_length
			and baselineIngress == expectedBaseline.pads.ingress
			and baselineEgress == expectedBaseline.pads.egress
			and expectedBaseline.pads.ingress == "None"
			and expectedBaseline.pads.egress == "None",
		HttpService:JSONEncode({
			expected = expectedBaseline,
			baseline = baselineSnapshotText,
		})
	)

	local setLeverOk, setLeverErr = JobRunner.submit("/tune set gap_length 8")
	T.expect("phase23_tune_set_gap_length_accepted", setLeverOk == true and setLeverErr == nil, tostring(setLeverErr))
	local setPadOk, setPadErr = JobRunner.submit("/tune pad ingress Boost25")
	T.expect("phase23_tune_set_pad_accepted", setPadOk == true and setPadErr == nil, tostring(setPadErr))
	local setAttrOk, setAttrErr = JobRunner.submit("/tune attr car_target_speed 140")
	T.expect("phase23_tune_set_attr_accepted", setAttrOk == true and setAttrErr == nil, tostring(setAttrErr))

	local resetOk, resetErr = JobRunner.submit("/tune reset")
	T.expect("phase23_tune_reset_accepted", resetOk == true and resetErr == nil, tostring(resetErr))
	T.expect(
		"phase23_tune_reset_restores_production_baseline",
		expectedBaseline ~= nil
			and getStringAttribute(stateFolder, "tune_param_summary") == summaryText(expectedBaseline)
			and getStringAttribute(stateFolder, "tune_attr_summary") == ""
			and getNumberAttribute(stateFolder, "tune_active_target_speed") == 0
			and workspace:GetAttribute("AutoTrack_CarTargetSpeed") == nil,
		HttpService:JSONEncode({
			summary = stateFolder:GetAttribute("tune_param_summary"),
			expected = expectedBaseline and summaryText(expectedBaseline) or "",
			attr_summary = stateFolder:GetAttribute("tune_attr_summary"),
			speed = workspace:GetAttribute("AutoTrack_CarTargetSpeed"),
		})
	)

	local stopOk, stopErr = JobRunner.submit("/tune stop")
	T.expect("phase23_tune_stop_after_reset_accepted", stopOk == true and stopErr == nil, tostring(stopErr))
	waitUntil(function()
		return not TuneMode.isActive()
	end, 5)
end

local function testCompareAndPromote()
	cleanup()
	local stateFolder = UIState.getStateFolder()

	local startOk, startErr = JobRunner.submit("/tune chicane")
	local started = waitUntil(function()
		return TuneMode.isActive() and stateFolder:GetAttribute("tune_mode_active") == true
	end, 5)
	T.expect("phase23_tune_chicane_starts", startOk == true and startErr == nil and started, tostring(startErr))

	T.expect(
		"phase23_tune_set_amplitude_accepted",
		select(1, JobRunner.submit("/tune set amplitude 8")) == true,
		"set amplitude failed"
	)
	T.expect(
		"phase23_tune_set_transition_accepted",
		select(1, JobRunner.submit("/tune set transition_length 8")) == true,
		"set transition failed"
	)
	T.expect(
		"phase23_tune_set_corridor_accepted",
		select(1, JobRunner.submit("/tune set corridor_width 10")) == true,
		"set corridor failed"
	)
	T.expect(
		"phase23_tune_set_speed_attr_accepted",
		select(1, JobRunner.submit("/tune attr car_target_speed 116")) == true,
		"set speed attr failed"
	)

	local compareOk, compareErr = JobRunner.submit("/tune compare 2")
	T.expect("phase23_tune_compare_accepted", compareOk == true and compareErr == nil, tostring(compareErr))
	local compareDone = waitUntil(function()
		return stateFolder:GetAttribute("tune_run_in_flight") == false
			and getStringAttribute(stateFolder, "tune_last_compare_json") ~= ""
	end, 20)
	local comparePayloadText = getStringAttribute(stateFolder, "tune_last_compare_json")
	T.expect(
		"phase23_tune_compare_publishes_baseline_and_candidate_summary",
		compareDone and comparePayloadHasExpectedShape(comparePayloadText),
		comparePayloadText
	)

	local promoteOk, promoteErr = JobRunner.submit("/tune promote")
	T.expect("phase23_tune_promote_accepted", promoteOk == true and promoteErr == nil, tostring(promoteErr))
	local promotionSnapshotText = getStringAttribute(stateFolder, "tune_promotion_snapshot")
	T.expect(
		"phase23_tune_promote_publishes_explicit_snapshot",
		promotionSnapshotHasExpectedShape(
			promotionSnapshotText,
			getNumberAttribute(stateFolder, "tune_candidate_version")
		),
		promotionSnapshotText
	)

	local stopOk, stopErr = JobRunner.submit("/tune stop")
	T.expect("phase23_tune_stop_after_compare_accepted", stopOk == true and stopErr == nil, tostring(stopErr))
	waitUntil(function()
		return not TuneMode.isActive()
	end, 5)
end

local function testPromptAndObjectiveShift()
	local designIntent: DesignIntent = {
		sector_id = 3,
		mechanic = "RampJump",
		params_hint = "tight fast",
		rationale = "push beyond a clean undershoot",
		target_score_band = "high",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "open_slot_preferred",
		desired_feel = "scoreable but recoverable",
		constraints = { "stay within endurance budget" },
	}
	local request: Request = {
		request_id = "phase23-proposal",
		raw_text = "add a jump in sector 3",
		parsed = {
			sector_id = 3,
			mechanic = "RampJump",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		origin = "endurance",
		design_intent = designIntent,
		memory_context = TestFactories.emptyMemory(),
		timestamp = 0,
	}
	local proposalMessages = PromptBuilder.proposeMessages(request, nil)
	local proposalSystem = proposalMessages[1].content
	local proposalUser = proposalMessages[2].content
	T.expect(
		"phase23_proposal_prompt_shifts_to_repairable_risk_language",
		string.find(proposalSystem, "scoreable, repairable risk", 1, true) ~= nil
			and string.find(proposalSystem, "low-risk, low-reward", 1, true) == nil,
		proposalSystem
	)
	T.expect(
		"phase23_proposal_prompt_uses_target_reliability_as_bias",
		string.find(proposalUser, "target_reliability as opening bias", 1, true) ~= nil,
		proposalUser
	)

	local challengeContext: Types.ChallengeUpContext = {
		baseline_state = {
			sector_id = 3,
			mechanic = "RampJump",
			params = {
				ramp_angle = 8,
				ramp_length = 24,
				gap_length = 4,
				landing_length = 30,
			},
			pads = {
				ingress = "Brake10",
				egress = "None",
			},
			version = 1,
		},
		baseline_result = {
			success = true,
			failure = nil,
			metrics = {
				entry_speed = 88,
				exit_speed = 64,
				airborne = true,
				air_distance = 12,
				lateral_error = 0,
				vertical_displacement = 6,
				reacquired = true,
				airtime_distance = 10,
				target_airborne = true,
				target_air_distance = 12,
				target_vertical_displacement = 6,
				target_reacquired = true,
				target_airtime_distance = 10,
				target_entered = true,
				target_exited = true,
				target_progress = 1,
				lap_time = 24,
				slowdown_ratio = 1.08,
				hang_time = 0.2,
				target_min_speed = 60,
				target_apex_min_speed = 58,
			},
			score = {
				total = 5.2,
				air = 2.5,
				lateral = 0,
				near_miss = 3.1,
				time_cost = 0.4,
				budget_used = 0.18,
				over_budget = false,
			},
		},
		budget_headroom = 0.82,
		target_score_floor = 8.5,
		reason = "clean pass scored 5.2 with 82% budget headroom, below the high target floor of 8.5",
		max_additional_repairs = 2,
	}
	local challengeMessages = PromptBuilder.challengeUpMessages(request, challengeContext, designIntent)
	local challengeUser = challengeMessages[2].content
	T.expect(
		"phase23_challenge_up_prompt_uses_hard_telemetry_and_do_over_language",
		string.find(challengeUser, "shot too low", 1, true) ~= nil
			and string.find(challengeUser, "Successful baseline score:", 1, true) ~= nil
			and string.find(challengeUser, "Budget headroom remaining:", 1, true) ~= nil
			and string.find(challengeUser, "This is not a repair request.", 1, true) ~= nil,
		challengeUser
	)

	local repairPacket: FailurePacket = {
		request = request,
		sector_state = {
			sector_id = 3,
			mechanic = "RampJump",
			params = {
				ramp_angle = 6,
				ramp_length = 28,
				gap_length = 4,
				landing_length = 30,
			},
			pads = {
				ingress = "Brake10",
				egress = "None",
			},
			version = 0,
		},
		attempt_index = 1,
		last_action = nil,
		run_result = {
			success = false,
			failure = {
				type = "local_execution_failure",
				sector_id = 3,
				detail = "no_progress",
			},
			metrics = {
				entry_speed = 30,
				exit_speed = 0,
				airborne = false,
				air_distance = 0,
				lateral_error = 0,
				vertical_displacement = 0,
				reacquired = false,
				airtime_distance = 0,
				lap_time = 0,
				slowdown_ratio = 1,
			},
			score = nil,
		},
		diagnostics = {
			failure_sector = 3,
			hints = { "no_progress" },
		},
		legal_actions = {
			numeric_levers = { "ramp_angle", "gap_length" },
			pads = { "ingress", "egress" },
		},
		design_intent = nil,
		memory_context = TestFactories.emptyMemory(),
	}
	local repairMessages = PromptBuilder.repairMessages(request, {}, repairPacket, nil)
	local repairSystem = repairMessages[1].content
	T.expect(
		"phase23_repair_prompt_preserves_challenge_language",
		string.find(repairSystem, "preserving scoreable challenge", 1, true) ~= nil
			and string.find(repairSystem, "low-risk", 1, true) == nil,
		repairSystem
	)

	local orchestratorMessages = OrchestratorPromptBuilder.messages(makeContext())
	local orchestratorSystem = orchestratorMessages[1].content
	T.expect(
		"phase23_orchestrator_prompt_targets_realized_score_gain",
		string.find(orchestratorSystem, "maximize realized committed score gain", 1, true) ~= nil
			and string.find(orchestratorSystem, "attempt_history committed outcomes as ground truth", 1, true) ~= nil
			and string.find(orchestratorSystem, "minimum-valid safe sectors", 1, true) ~= nil,
		orchestratorSystem
	)

	local conservativeRequest: Request = {
		request_id = "phase23-conservative",
		raw_text = "add a chicane in sector 3",
		parsed = {
			sector_id = 3,
			mechanic = "Chicane",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		origin = "endurance",
		design_intent = {
			sector_id = 3,
			mechanic = "Chicane",
			params_hint = "fast weave",
			rationale = "stable opener",
			target_score_band = "medium",
			target_budget_tolerance = "medium",
			target_reliability = "conservative",
			spectacle_priority = "medium",
			novelty_priority = "medium",
			replacement_intent = "open_slot_preferred",
			desired_feel = "stable opener",
			constraints = { "stay within endurance budget" },
		},
		memory_context = TestFactories.emptyMemory(),
		timestamp = 0,
	}
	local riskyRequest: Request = {
		request_id = "phase23-risky",
		raw_text = "add a chicane in sector 3",
		parsed = {
			sector_id = 3,
			mechanic = "Chicane",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		origin = "endurance",
		design_intent = {
			sector_id = 3,
			mechanic = "Chicane",
			params_hint = "fast weave",
			rationale = "spend headroom",
			target_score_band = "high",
			target_budget_tolerance = "high",
			target_reliability = "risky",
			spectacle_priority = "high",
			novelty_priority = "medium",
			replacement_intent = "open_slot_preferred",
			desired_feel = "scoreable but repairable",
			constraints = { "stay within endurance budget" },
		},
		memory_context = TestFactories.emptyMemory(),
		timestamp = 0,
	}
	local conservativeState = select(1, MinimalProposer.initial(conservativeRequest))
	local riskyState = select(1, MinimalProposer.initial(riskyRequest))
	T.expect(
		"phase23_target_reliability_biases_initial_proposal_template",
		conservativeState ~= nil
			and riskyState ~= nil
			and (riskyState.params.amplitude or 0) > (conservativeState.params.amplitude or 0)
			and (riskyState.params.transition_length or 0) < (conservativeState.params.transition_length or 0)
			and (riskyState.params.corridor_width or 0) <= (conservativeState.params.corridor_width or 0),
		HttpService:JSONEncode({
			conservative = conservativeState,
			risky = riskyState,
		})
	)

	local context = makeContext()
	local repeatedDecision: OrchestratorDecision = {
		action = "submit_request",
		sector_id = 2,
		mechanic = "RampJump",
		params_hint = "safe long",
		rationale = "repeat an old safe ramp",
		target_score_band = "medium",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "medium",
		novelty_priority = "low",
		replacement_intent = "preserve_good_sector",
		desired_feel = "safe repeat",
		constraints = { "stay stable" },
	}
	local upsideDecision: OrchestratorDecision = {
		action = "submit_request",
		sector_id = 3,
		mechanic = "Chicane",
		params_hint = "tight fast",
		rationale = "open slot with score upside",
		target_score_band = "high",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "open_slot_preferred",
		desired_feel = "scoreable but repairable",
		constraints = { "stay within endurance budget" },
	}

	local repeatedScore = select(1, EnduranceObjective.evaluateCandidate(context, repeatedDecision))
	local upsideScore = select(1, EnduranceObjective.evaluateCandidate(context, upsideDecision))
	T.expect(
		"phase23_endurance_objective_prefers_open_upside_candidate",
		upsideScore.total > repeatedScore.total and upsideScore.base_score_gain > repeatedScore.base_score_gain,
		HttpService:JSONEncode({
			repeated = repeatedScore,
			upside = upsideScore,
		})
	)

	local repairedSuccessContext = makeContext()
	local repairedSuccessAttempts: { OrchestratorAttempt } = {
		{
			sector_id = 3,
			mechanic = "Chicane",
			params_hint = "tight fast",
			normalized_signature = "s3|Chicane|tight fast",
			outcome = "committed",
			score = 18,
			slowdown_ratio = 1.08,
			failure_signature = nil,
			repair_iterations = 3,
			decision_index = 1,
			timestamp = 1,
		},
	}
	repairedSuccessContext.attempt_history = repairedSuccessAttempts
	repairedSuccessContext.sector_attempt_counts = { [3] = 1 }
	repairedSuccessContext.mechanic_repeat_pressure = {}

	local cleanSuccessContext = makeContext()
	local cleanSuccessAttempts: { OrchestratorAttempt } = {
		{
			sector_id = 3,
			mechanic = "Chicane",
			params_hint = "tight fast",
			normalized_signature = "s3|Chicane|tight fast",
			outcome = "committed",
			score = 18,
			slowdown_ratio = 1.08,
			failure_signature = nil,
			repair_iterations = 0,
			decision_index = 1,
			timestamp = 1,
		},
	}
	cleanSuccessContext.attempt_history = cleanSuccessAttempts
	cleanSuccessContext.sector_attempt_counts = { [3] = 1 }
	cleanSuccessContext.mechanic_repeat_pressure = {}

	local repairedSuccessScore = select(1, EnduranceObjective.evaluateCandidate(repairedSuccessContext, upsideDecision))
	local cleanSuccessScore = select(1, EnduranceObjective.evaluateCandidate(cleanSuccessContext, upsideDecision))
	T.expect(
		"phase23_successful_repairs_do_not_reduce_objective_score",
		math.abs((repairedSuccessScore.total or 0) - (cleanSuccessScore.total or 0)) < 1e-6
			and (repairedSuccessScore.repair_complexity_penalty or -1) == 0
			and (cleanSuccessScore.repair_complexity_penalty or -1) == 0,
		HttpService:JSONEncode({
			repaired = repairedSuccessScore,
			clean = cleanSuccessScore,
		})
	)

	local failureHeavyContext = makeContext()
	local failureHeavyAttempts: { OrchestratorAttempt } = {
		{
			sector_id = 3,
			mechanic = "Chicane",
			params_hint = "tight fast",
			normalized_signature = "s3|Chicane|different past miss",
			outcome = "reverted",
			score = 0,
			slowdown_ratio = 1.05,
			failure_signature = "spinout@s3|Chicane|different past miss",
			repair_iterations = 2,
			decision_index = 1,
			timestamp = 1,
		},
	}
	failureHeavyContext.attempt_history = failureHeavyAttempts
	failureHeavyContext.sector_attempt_counts = { [3] = 1 }
	failureHeavyContext.mechanic_repeat_pressure = {}

	local cleanHistoryContext = makeContext()
	cleanHistoryContext.attempt_history = {}
	cleanHistoryContext.sector_attempt_counts = {}
	cleanHistoryContext.mechanic_repeat_pressure = {}

	local failureHeavyScore = select(1, EnduranceObjective.evaluateCandidate(failureHeavyContext, upsideDecision))
	local cleanHistoryScore = select(1, EnduranceObjective.evaluateCandidate(cleanHistoryContext, upsideDecision))
	T.expect(
		"phase23_failure_history_reduces_realized_yield_and_reliability",
		(failureHeavyScore.total or 0) < (cleanHistoryScore.total or 0)
			and (failureHeavyScore.reliability_index or 0) < (cleanHistoryScore.reliability_index or 0),
		HttpService:JSONEncode({
			failure_heavy = failureHeavyScore,
			clean = cleanHistoryScore,
		})
	)

	local enduranceChallengeResult: RunResult = {
		success = true,
		metrics = {
			entry_speed = 88,
			exit_speed = 60,
			airborne = true,
			air_distance = 12,
			lateral_error = 0,
			vertical_displacement = 6,
			reacquired = true,
			airtime_distance = 10,
			target_entered = true,
			target_exited = true,
			target_progress = 1,
			lap_time = 24,
			slowdown_ratio = 1.08,
		},
		score = {
			total = 5.2,
			air = 2.5,
			lateral = 0,
			near_miss = 3.1,
			time_cost = 0.4,
			budget_used = 0.18,
			over_budget = false,
		},
	}
	local shouldRunChallengeUp, why, strategy = JobRunner._shouldRunChallengeUp(request, enduranceChallengeResult, true)
	T.expect(
		"phase23_endurance_challenge_up_reenabled_as_proposer_do_over",
		shouldRunChallengeUp == true and why == nil and strategy == "proposal_do_over",
		HttpService:JSONEncode({
			shouldRun = shouldRunChallengeUp,
			why = why,
			strategy = strategy,
		})
	)
end

function TestPhase23.run()
	if not ensureReady() then
		return
	end

	testProductionBaselineReset()
	testCompareAndPromote()
	testPromptAndObjectiveShift()
	cleanup()
end

return TestPhase23
