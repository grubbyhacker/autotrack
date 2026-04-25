-- TestPhase14.luau
-- Regression coverage for the tuned phase-14 reliability envelope.
-- Focus:
--   1. named golden obstacle profiles remain traversable under AttemptRunner
--   2. heuristic "add a jump to sector 2" converges to a committed RampJump
--   3. LLM repair partial-state responses are merged instead of failing on missing fields

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local TestSession = require(script.Parent.TestSession)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local MinimalOrchestrator = require(script.Parent.MinimalOrchestrator)
local MinimalProposer = require(script.Parent.MinimalProposer)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local AttemptRunner = require(script.Parent.AttemptRunner)
local ContinuousLapRunner = require(script.Parent.ContinuousLapRunner)
local EnduranceMemory = require(script.Parent.EnduranceMemory)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local RuntimeContext = require(script.Parent.RuntimeContext)
local CameraDemo = require(script.Parent.CameraDemo)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local JobRunner = require(script.Parent.JobRunner)
local Tracer = require(script.Parent.Tracer)

type SectorState = Types.SectorState
type OrchestratorContext = Types.OrchestratorContext

local TestPhase14 = {}
local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }
-- Golden obstacle profiles:
-- | Profile | Why it exists |
-- | RampJump sector 2 | Small but credible launch that clears the current airtime floor without tumbling; guards the basic jump JobRunner path. |
-- | Chicane sector 3 | Tightest currently reliable S-bend inside the real sector-length budget; guards against over-easing the shape into something trivial. |
-- | CrestDip sector 3 | Standalone crest profile that survives without upstream conditioning; guards the solo CrestDip envelope used by the downstream pair test. |
local GOLDEN_CHICANE_SECTOR3 = {
	amplitude = 5,
	transition_length = 26,
	corridor_width = 18,
	ingress = "Brake25",
	egress = "Brake10",
}
local CRESTDIP_SEARCH_HEIGHTS = { 3, 4, 5, 6 }
local CRESTDIP_SEARCH_LENGTHS = { 30, 32, 34, 36, 38, 40 }
local CRESTDIP_SEARCH_PADS = { "Brake50", "Brake25", "None" }
local CRESTDIP_SEARCH_EGRESS_PADS = { "None", "Brake10", "Brake25" }

local function makeState(sectorId: number, mechanic, params, ingress, egress): SectorState
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params or {},
		pads = {
			ingress = ingress or "None",
			egress = egress or "None",
		},
		version = 0,
	}
end

local function getSectorMeta(sectorId: number)
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector, sectors
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function applyState(state: SectorState)
	local sector = getSectorMeta(state.sector_id)
	SectorApplier.apply(state, sector.entry, sector.exit)
end

local function resetEditableSectors()
	for _, sectorId in ipairs(EDITABLE_SECTORS) do
		local flatState = makeState(sectorId, nil, {}, "None", "None")
		applyState(flatState)
		SectorRegistry.commit(flatState)
	end
	task.wait(0.1)
end

local function runAttemptState(state: SectorState): (Types.RunResult, { string }, SectorState)
	local targetSector = getSectorMeta(state.sector_id)
	return AttemptRunner.run({
		workingState = state,
		action = nil,
		targetSectorId = state.sector_id,
		entryFrame = targetSector.entry,
		exitFrame = targetSector.exit,
		sectors = RuntimeContext.getSectors(),
		car = RuntimeContext.getCar(),
		canonicalStart = RuntimeContext.getCanonicalStart(),
		onSectorChange = nil,
	})
end

local function resultSummary(result: Types.RunResult): string
	local failureType = result.failure and result.failure.type or "nil"
	local failureDetail = result.failure and result.failure.detail or "nil"
	return string.format(
		"%s / %s entry=%.1f exit=%.1f progress=%.2f airborne=%s air=%.1f reacquired=%s slowdown=%.2f",
		tostring(failureType),
		tostring(failureDetail),
		result.metrics.entry_speed or 0,
		result.metrics.exit_speed or 0,
		result.metrics.target_progress or 0,
		tostring(result.metrics.target_airborne == true),
		result.metrics.target_air_distance or 0,
		tostring(result.metrics.target_reacquired == true),
		result.metrics.slowdown_ratio or 0
	)
end

local function makeOrchestratorContext(args): OrchestratorContext
	return {
		editable_sectors = { 2, 3, 4, 7, 8, 9 },
		sector_states = args.sector_states,
		budget = args.budget,
		attempt_budget = args.attempt_budget,
		last_result = args.last_result,
		attempt_history = nil,
		sector_attempt_counts = nil,
		mechanic_repeat_pressure = nil,
		track_intent = nil,
		memory = EnduranceMemory.new(),
	}
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 60
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function summariseAttempts(job)
	if not job or not job.attempts then
		return "no_job"
	end

	local parts = {}
	for _, attempt in ipairs(job.attempts) do
		local result = attempt.result or {}
		local failure = result.failure or {}
		local action = attempt.action
		local actionLabel = "initial"
		if action then
			if action.type == "SetNumericLever" then
				actionLabel = string.format("%s=%s", tostring(action.lever), tostring(action.value))
			elseif action.type == "SetPad" then
				actionLabel = string.format("%s=%s", tostring(action.pad), tostring(action.value))
			else
				actionLabel = tostring(action.type)
			end
		end
		table.insert(
			parts,
			string.format(
				"%d:%s/%s/%s progress=%.2f hints=%s action=%s",
				attempt.attempt_index,
				tostring(result.success),
				tostring(failure.type),
				tostring(failure.detail),
				(result.metrics and result.metrics.target_progress) or 0,
				(attempt.hints and #attempt.hints > 0) and table.concat(attempt.hints, "&") or "-",
				actionLabel
			)
		)
	end

	return table.concat(parts, " || ")
end

local function submitWithRetries(rawText: string, sectorId: number, expectedMechanic: string?, maxRuns: number)
	local logs = {}
	local lastOk, lastReason, lastJob, lastState = nil, nil, nil, nil

	for run = 1, math.max(1, maxRuns) do
		local ok, reason = JobRunner.submit(rawText)
		local job = JobRunner.getLastJob()
		local state = SectorRegistry.getCommitted(sectorId)
		table.insert(
			logs,
			string.format(
				"run%d ok=%s reason=%s final=%s mechanic=%s attempts=%s",
				run,
				tostring(ok),
				tostring(reason),
				tostring(job and job.final_status),
				tostring(state and state.mechanic),
				summariseAttempts(job)
			)
		)

		lastOk, lastReason, lastJob, lastState = ok, reason, job, state
		if
			ok == true
			and reason == nil
			and job ~= nil
			and job.final_status == "committed"
			and state ~= nil
			and (expectedMechanic == nil or state.mechanic == expectedMechanic)
		then
			return true, ok, reason, job, state, table.concat(logs, " || ")
		end
	end

	return false, lastOk, lastReason, lastJob, lastState, table.concat(logs, " || ")
end

local function debugLine(line: string)
	local tagged = "[DEBUG] " .. line
	print(tagged)
	TestSession.appendLine(tagged)
end

local function debugValue(value): string
	if value == nil then
		return "nil"
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if ok then
		return encoded
	end
	return tostring(value)
end

local function makeRequest(rawText: string)
	local request, err = RequestParser.parse(rawText, "phase14-req")
	assert(request ~= nil, "request parse failed: " .. tostring(err))
	return request
end

local function makeCrestCandidate(
	sectorId: number,
	height: number,
	sectorLength: number,
	ingress: string,
	egress: string?
): SectorState
	return makeState(sectorId, "CrestDip", {
		height_or_depth = height,
		radius = LevelMappings.DEFAULTS.CrestDip.radius,
		sector_length = sectorLength,
	}, ingress, egress or "None")
end

local function crestCandidateLabel(state: SectorState): string
	return string.format(
		"sector=%d h=%d L=%d ingress=%s egress=%s",
		state.sector_id,
		state.params.height_or_depth or -1,
		state.params.sector_length or -1,
		state.pads.ingress,
		state.pads.egress
	)
end

local function findPassingCrestCandidate(sectorId: number, egressPads: { string }?): (SectorState?, string)
	local attempts = {}
	local egressValues = egressPads or { "None" }
	for _, ingress in ipairs(CRESTDIP_SEARCH_PADS) do
		for _, egress in ipairs(egressValues) do
			for _, height in ipairs(CRESTDIP_SEARCH_HEIGHTS) do
				for _, sectorLength in ipairs(CRESTDIP_SEARCH_LENGTHS) do
					local candidate = makeCrestCandidate(sectorId, height, sectorLength, ingress, egress)
					local result = select(1, runAttemptState(candidate))
					local line = string.format(
						"[SEARCH] CrestDip %s => %s",
						crestCandidateLabel(candidate),
						resultSummary(result)
					)
					print(line)
					table.insert(attempts, line)
					if result.success then
						return candidate, table.concat(attempts, "\n")
					end
				end
			end
		end
	end
	return nil, table.concat(attempts, "\n")
end

local function fakePacket(request, state, attemptIndex)
	return {
		request = request,
		sector_state = state,
		attempt_index = attemptIndex or 0,
		last_action = nil,
		run_result = {
			success = false,
			failure = { type = "local_execution_failure", sector_id = state.sector_id, detail = "tumble" },
			metrics = {
				entry_speed = 120,
				exit_speed = 0,
				airborne = true,
				air_distance = 0,
				lateral_error = 0,
				vertical_displacement = 0,
				reacquired = false,
				airtime_distance = 0,
				target_airborne = true,
				target_air_distance = 0,
				target_vertical_displacement = 0,
				target_reacquired = false,
				target_airtime_distance = 0,
				target_left_offset = 0,
				target_right_offset = 0,
				target_lateral_band_changes = 0,
				target_entered = true,
				target_exited = false,
				target_progress = 0.15,
				lap_time = 30,
				slowdown_ratio = 1.1,
			},
		},
		diagnostics = { failure_sector = state.sector_id, hints = { "tumble" } },
		legal_actions = {
			numeric_levers = { "ramp_angle", "ramp_length", "gap_length", "landing_length" },
			pads = { "ingress", "egress" },
		},
	}
end

local function fakeResult(success: boolean, failureSector: number?, detail: string?): Types.RunResult
	return {
		success = success,
		failure = if success
			then nil
			else {
				type = "local_execution_failure",
				sector_id = failureSector or 0,
				detail = detail or "tumble",
			},
		metrics = {
			entry_speed = 100,
			exit_speed = if success then 90 else 0,
			airborne = false,
			air_distance = 0,
			lateral_error = 0,
			vertical_displacement = 0,
			reacquired = true,
			airtime_distance = 0,
			target_airborne = false,
			target_air_distance = 0,
			target_vertical_displacement = 0,
			target_reacquired = true,
			target_airtime_distance = 0,
			target_left_offset = 0,
			target_right_offset = 0,
			target_lateral_band_changes = 0,
			target_entered = true,
			target_exited = success,
			target_progress = if success then 1 else 0.25,
			lap_time = 24,
			slowdown_ratio = 1.05,
		},
	}
end

function TestPhase14.runUnit()
	local request = makeRequest("add a jump to sector 2")
	local currentState = makeState(2, "RampJump", {
		ramp_angle = 10,
		ramp_length = 22,
		gap_length = 6,
		landing_length = 30,
	}, "None", "None")

	LLMAdapter.setProvider("partial-repair-state", {
		propose = function()
			return HttpService:JSONEncode(currentState)
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					params = {
						ramp_angle = 8,
						landing_length = 28,
					},
					pads = {
						ingress = "Brake10",
					},
				},
				explanation = "trimmed entry speed and lengthened landing",
			})
		end,
	})

	local action, newState, explanation, _, err = LLMAdapter.repair(fakePacket(request, currentState, 0), {})
	T.expect("phase14_partial_repair_state_action_nil", action == nil, tostring(action and action.type))
	T.expect("phase14_partial_repair_state_no_error", err == nil, tostring(err))
	T.expect(
		"phase14_partial_repair_state_merged",
		newState ~= nil
			and newState.sector_id == 2
			and newState.mechanic == "RampJump"
			and newState.params.ramp_angle == 8
			and newState.params.ramp_length == currentState.params.ramp_length
			and newState.params.gap_length == currentState.params.gap_length
			and newState.params.landing_length >= currentState.params.landing_length
			and newState.params.landing_length <= currentState.params.landing_length + 6
			and newState.pads.ingress == "Brake10"
			and newState.pads.egress == currentState.pads.egress,
		HttpService:JSONEncode(newState or {})
	)
	T.expect(
		"phase14_partial_repair_state_explanation",
		type(explanation) == "string" and explanation ~= "",
		tostring(explanation)
	)

	LLMAdapter.useMockProvider()

	LLMAdapter.setProvider("aggressive-crestdip-propose", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 3,
				mechanic = "CrestDip",
				params = {
					height_or_depth = 9,
					radius = 20,
					sector_length = 37,
				},
				pads = {
					ingress = "Brake10",
					egress = "None",
				},
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = ContractBuilders.setPad("ingress", "Brake50"),
				explanation = "stub",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode({ action = "begin_loop" })
		end,
	})
	local normalizedProposal, _, normalizedProposalErr = LLMAdapter.propose(makeRequest("add a crest in sector 3"))
	T.expect(
		"phase14_plain_crestdip_proposal_normalized",
		normalizedProposalErr == nil
			and normalizedProposal ~= nil
			and normalizedProposal.mechanic == "CrestDip"
			and normalizedProposal.params.height_or_depth == 5
			and normalizedProposal.params.sector_length == 30
			and normalizedProposal.pads.ingress == "Brake50",
		tostring(normalizedProposalErr or HttpService:JSONEncode(normalizedProposal or {}))
	)
	LLMAdapter.useMockProvider()

	local crestState = makeState(3, "CrestDip", {
		height_or_depth = 6,
		radius = 20,
		sector_length = 40,
	}, "Brake25", "None")

	LLMAdapter.setProvider("crestdip-repair-state", {
		propose = function()
			return HttpService:JSONEncode(crestState)
		end,
		repair = function()
			return HttpService:JSONEncode({
				newState = {
					params = {
						height_or_depth = 4,
						sector_length = 40,
					},
				},
				explanation = "softened the crest",
			})
		end,
	})

	local _, repairedCrestState, _, _, crestErr =
		LLMAdapter.repair(fakePacket(makeRequest("add a crest in sector 3"), crestState, 1), {})
	T.expect("phase14_partial_crestdip_repair_state_no_error", crestErr == nil, tostring(crestErr))
	T.expect(
		"phase14_partial_crestdip_repair_state_tuned",
		repairedCrestState ~= nil
			and repairedCrestState.mechanic == "CrestDip"
			and repairedCrestState.params.height_or_depth >= Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
			and repairedCrestState.params.sector_length < 40
			and repairedCrestState.params.radius == 20,
		HttpService:JSONEncode(repairedCrestState or {})
	)

	LLMAdapter.useMockProvider()

	local orchestrateProvider = {
		propose = function()
			return "{}"
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = ContractBuilders.setPad("ingress", "Brake10"),
				explanation = "stub",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode({
				sector_id = 8,
				mechanic = "Chicane",
				params_hint = "extreme wide",
				rationale = "spread spectacle across the back straight",
				target_score_band = "high",
				target_budget_tolerance = "medium",
				target_reliability = "balanced",
				spectacle_priority = "high",
				novelty_priority = "medium",
				replacement_intent = "open_slot_preferred",
				desired_feel = "broad visible weave with stable exits",
				constraints = {
					"preserve downstream stability",
					"stay within endurance budget",
				},
			})
		end,
	}
	LLMAdapter.setProvider("orchestrate-test", orchestrateProvider)
	local decision, _, orchestrateErr = LLMAdapter.orchestrate(makeOrchestratorContext({
		sector_states = {
			[2] = { mechanic = "RampJump", params = {}, score = 4 },
			[3] = { mechanic = nil, params = {}, score = 0 },
			[4] = { mechanic = nil, params = {}, score = 0 },
			[7] = { mechanic = nil, params = {}, score = 0 },
			[8] = { mechanic = nil, params = {}, score = 0 },
			[9] = { mechanic = nil, params = {}, score = 0 },
		},
		budget = { used = 0.25, over_budget = false },
		attempt_budget = { used = 1, total = 12 },
		last_result = nil,
	}))
	T.expect(
		"phase14_orchestrate_decodes_decision",
		orchestrateErr == nil and decision ~= nil and decision.sector_id == 8 and decision.mechanic == "Chicane",
		tostring(orchestrateErr or HttpService:JSONEncode(decision or {}))
	)
	LLMAdapter.useMockProvider()

	local minimalDecision = MinimalOrchestrator.decide(makeOrchestratorContext({
		sector_states = {
			[2] = { mechanic = "RampJump", params = {}, score = 10 },
			[3] = { mechanic = "CrestDip", params = {}, score = 8 },
			[4] = { mechanic = "Chicane", params = {}, score = 9 },
			[7] = { mechanic = nil, params = {}, score = 0 },
			[8] = { mechanic = nil, params = {}, score = 0 },
			[9] = { mechanic = nil, params = {}, score = 0 },
		},
		budget = { used = 0.2, over_budget = false },
		attempt_budget = { used = 3, total = 12 },
		last_result = { sector_id = 4, success = true, score = 9 },
	}))
	T.expect(
		"phase14_minimal_orchestrator_targets_first_unfilled_sector",
		minimalDecision.action == "submit_request"
			and minimalDecision.sector_id == 7
			and minimalDecision.mechanic == "RampJump",
		HttpService:JSONEncode(minimalDecision)
	)
	T.expect(
		"phase14_minimal_orchestrator_begins_loop_when_over_budget",
		MinimalOrchestrator.decide(makeOrchestratorContext({
			sector_states = {
				[2] = { mechanic = "RampJump", params = {}, score = 10 },
				[3] = { mechanic = "CrestDip", params = {}, score = 8 },
				[4] = { mechanic = "Chicane", params = {}, score = 9 },
				[7] = { mechanic = "RampJump", params = {}, score = 9 },
				[8] = { mechanic = "Chicane", params = {}, score = 9 },
				[9] = { mechanic = "CrestDip", params = {}, score = 9 },
			},
			budget = { used = 1, over_budget = true },
			attempt_budget = { used = 6, total = 12 },
			last_result = nil,
		})).action == "begin_loop",
		"expected over-budget heuristic to stop filling sectors"
	)

	local downstreamRepair = MinimalProposer.repair({
		request = makeRequest("add a crest in sector 2"),
		sector_state = makeState(2, "CrestDip", {
			height_or_depth = 6,
			radius = 24,
			sector_length = 30,
		}, "None", "Brake10"),
		attempt_index = 1,
		last_action = nil,
		run_result = {
			success = false,
			failure = { type = "downstream_failure", sector_id = 3, detail = "no_progress" },
			metrics = {
				entry_speed = 100,
				exit_speed = 58,
				airborne = false,
				air_distance = 0,
				lateral_error = 0,
				vertical_displacement = 6,
				reacquired = true,
				airtime_distance = 0,
				target_airborne = false,
				target_air_distance = 0,
				target_vertical_displacement = 6,
				target_reacquired = true,
				target_airtime_distance = 0,
				target_left_offset = 0,
				target_right_offset = 0,
				target_lateral_band_changes = 0,
				target_entered = true,
				target_exited = true,
				target_progress = 1,
				target_apex_min_speed = 30,
				lap_time = 26,
				slowdown_ratio = 1.08,
			},
		},
		diagnostics = {
			failure_sector = 3,
			hints = { "target sector exit speed too low for downstream" },
			downstream_sector_state = makeState(3, "RampJump", {
				ramp_angle = 9,
				ramp_length = 18,
				gap_length = 6,
				landing_length = 26,
			}, "None", "Brake10"),
		},
		legal_actions = {
			numeric_levers = { "height_or_depth", "radius", "sector_length" },
			pads = { "ingress", "egress" },
		},
	})
	T.expect(
		"phase14_crestdip_downstream_repair_prefers_carrying_speed",
		downstreamRepair ~= nil
			and downstreamRepair.type == "SetPad"
			and downstreamRepair.pad == "ingress"
			and downstreamRepair.value == "Boost10",
		HttpService:JSONEncode(downstreamRepair)
	)

	local retryClearedLapCounts = {}
	local retrySequence = {
		fakeResult(false, 3, "tumble"),
		fakeResult(true, nil, nil),
	}
	local retryIndex = 0
	local retryOk, retryErr = ContinuousLapRunner.run({
		maxCleanLaps = 1,
		deps = {
			tryAcquire = function()
				return true
			end,
			release = function() end,
			wait = function() end,
			runLap = function()
				retryIndex += 1
				return retrySequence[retryIndex]
			end,
			setPhase = function() end,
			appendLog = function() end,
			publishAttemptResult = function() end,
			setLapCount = function(count: number)
				table.insert(retryClearedLapCounts, count)
			end,
			isTerminal = function()
				return false
			end,
			hotfixRun = function()
				error("retry-cleared sequence should not enter hotfix")
			end,
			trace = function() end,
		},
	})
	T.expect("phase14_continuous_retry_success_returns_ok", retryOk == true and retryErr == nil, tostring(retryErr))
	T.expect(
		"phase14_continuous_retry_success_counts_clean_lap",
		retryClearedLapCounts[#retryClearedLapCounts] == 1,
		tostring(retryClearedLapCounts[#retryClearedLapCounts])
	)

	local hotfixSectors = {}
	local hotfixSequence = {
		fakeResult(false, 3, "upstream"),
		fakeResult(false, 7, "downstream"),
		fakeResult(true, nil, nil),
	}
	local hotfixIndex = 0
	local hotfixOk, hotfixErr = ContinuousLapRunner.run({
		maxCleanLaps = 1,
		deps = {
			tryAcquire = function()
				return true
			end,
			release = function() end,
			wait = function() end,
			runLap = function()
				hotfixIndex += 1
				return hotfixSequence[hotfixIndex]
			end,
			setPhase = function() end,
			appendLog = function() end,
			publishAttemptResult = function() end,
			setLapCount = function() end,
			isTerminal = function()
				return false
			end,
			hotfixRun = function(sectorId: number)
				table.insert(hotfixSectors, sectorId)
				return true
			end,
			trace = function() end,
		},
	})
	T.expect("phase14_continuous_hotfix_returns_ok", hotfixOk == true and hotfixErr == nil, tostring(hotfixErr))
	T.expect("phase14_continuous_hotfix_uses_retry_failure_sector", hotfixSectors[1] == 7, tostring(hotfixSectors[1]))
	T.expect(
		"phase14_continuous_hotfix_sector_helper_prefers_retry",
		ContinuousLapRunner._resolveHotfixSector(fakeResult(false, 3, "a"), fakeResult(false, 9, "b")) == 9,
		tostring(ContinuousLapRunner._resolveHotfixSector(fakeResult(false, 3, "a"), fakeResult(false, 9, "b")))
	)

	resetEditableSectors()
	local rampitupStartOk, rampitupStartErr = CameraDemo.start({
		preset = "rampitup",
		loop = true,
		runVerifier = false,
	})
	T.expect(
		"phase14_rampitup_demo_starts",
		rampitupStartOk == true
			and rampitupStartErr == nil
			and CameraDemo.isActive()
			and CameraDemo.activePreset() == "rampitup",
		tostring(rampitupStartErr)
	)

	local demoSector3 = SectorRegistry.getCommitted(3)
	local demoSector8 = SectorRegistry.getCommitted(8)
	T.expect(
		"phase14_rampitup_demo_applies_ramps",
		demoSector3 ~= nil
			and demoSector8 ~= nil
			and demoSector3.mechanic == "RampJump"
			and demoSector8.mechanic == "RampJump"
			and demoSector3.params.ramp_angle == 4
			and demoSector8.params.ramp_angle == 3
			and demoSector3.params.ramp_length == 24
			and demoSector8.params.ramp_length == 26
			and demoSector3.params.gap_length == 2
			and demoSector8.params.gap_length == 2
			and demoSector3.params.landing_length == 36
			and demoSector8.params.landing_length == 40
			and demoSector3.pads.ingress == "Brake50"
			and demoSector3.pads.egress == "Brake25"
			and demoSector8.pads.ingress == "Brake50"
			and demoSector8.pads.egress == "Brake25",
		HttpService:JSONEncode({
			sector3 = demoSector3,
			sector8 = demoSector8,
		})
	)

	local rampitupStopOk, rampitupStopErr = CameraDemo.stop()
	T.expect(
		"phase14_rampitup_demo_stops",
		rampitupStopOk == true and rampitupStopErr == nil and not CameraDemo.isActive(),
		tostring(rampitupStopErr)
	)

	local restoredSector3 = SectorRegistry.getCommitted(3)
	local restoredSector8 = SectorRegistry.getCommitted(8)
	T.expect(
		"phase14_rampitup_demo_restores_track",
		restoredSector3 ~= nil
			and restoredSector8 ~= nil
			and restoredSector3.mechanic == nil
			and restoredSector8.mechanic == nil
			and restoredSector3.pads.ingress == "None"
			and restoredSector3.pads.egress == "None"
			and restoredSector8.pads.ingress == "None"
			and restoredSector8.pads.egress == "None",
		HttpService:JSONEncode({
			sector3 = restoredSector3,
			sector8 = restoredSector8,
		})
	)

	local orchestratorSubmits = {}
	local orchestratorContexts = {}
	local orchestratorBudgetUpdates = {}
	local loopStarted = false
	local loopInitialLapCount = nil
	local orchestratorRunOk, orchestratorRunErr = OrchestratorAgent.run({
		submit = function(text: string)
			table.insert(orchestratorSubmits, text)
			return true, nil
		end,
		getLastJob = function()
			return {
				request = {
					parsed = {
						sector_id = 2,
					},
				},
				final_status = "committed",
				final_result = {
					success = true,
					metrics = {
						slowdown_ratio = 1.12,
					},
					score = {
						total = 14,
					},
				},
				attempts = {
					{
						result = {
							success = true,
							metrics = {
								slowdown_ratio = 1.12,
							},
							score = {
								total = 14,
							},
						},
					},
				},
			}
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
					return {
						sector_id = 2,
						mechanic = "RampJump",
						params_hint = "extreme tall",
					},
						nil
				end
				return { action = "begin_loop" }, nil
			end,
			setPhase = function() end,
			setAttemptBudget = function(used: number, total: number)
				table.insert(orchestratorBudgetUpdates, string.format("%d/%d", used, total))
			end,
			appendLog = function() end,
			trace = function() end,
			startContinuousLoop = function(initialLapCount: number)
				loopStarted = true
				loopInitialLapCount = initialLapCount
				return true, nil
			end,
		},
	})
	T.expect(
		"phase14_orchestrator_run_returns_ok",
		orchestratorRunOk == true and orchestratorRunErr == nil,
		tostring(orchestratorRunErr)
	)
	T.expect(
		"phase14_orchestrator_submits_hint_request",
		orchestratorSubmits[1] == "add an extreme tall jump in sector 2",
		tostring(orchestratorSubmits[1])
	)
	T.expect(
		"phase14_orchestrator_feeds_last_result_into_next_context",
		#orchestratorContexts >= 2
			and orchestratorContexts[2].last_result ~= nil
			and orchestratorContexts[2].last_result.sector_id == 2
			and orchestratorContexts[2].last_result.success == true
			and orchestratorContexts[2].last_result.score == 14
			and math.abs(
					orchestratorContexts[2].budget.used
						- math.clamp((1.12 - 1) / Constants.ENDURANCE_LAP_TIME_BUDGET_RATIO, 0, 1)
				)
				< 0.001,
		HttpService:JSONEncode(orchestratorContexts[2] or {})
	)
	T.expect(
		"phase14_orchestrator_starts_continuous_loop",
		loopStarted == true and loopInitialLapCount == 0,
		string.format("started=%s lap_count=%s", tostring(loopStarted), tostring(loopInitialLapCount))
	)
	T.expect(
		"phase14_orchestrator_updates_attempt_budget",
		orchestratorBudgetUpdates[1] == "0/12" and orchestratorBudgetUpdates[2] == "1/12",
		table.concat(orchestratorBudgetUpdates, ",")
	)

	local cameraBlockedOk, cameraBlockedErr = OrchestratorAgent.run({
		submit = function()
			error("camera gate should reject before submit")
		end,
		getLastJob = function()
			return nil
		end,
		isCameraDemoActive = function()
			return true
		end,
	})
	T.expect(
		"phase14_orchestrator_rejects_camera_demo_session",
		cameraBlockedOk == false and string.find(tostring(cameraBlockedErr), "camera demo", 1, true) ~= nil,
		tostring(cameraBlockedErr)
	)
end

function TestPhase14.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase14_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase14_baseline_ready", "baseline lap did not complete before tuning regression")
		return
	end

	resetEditableSectors()
	local jumpCommitted, jumpOk, jumpReason, jumpJob, jumpState, jumpRuns =
		submitWithRetries("add a jump to sector 2", 2, "RampJump", 3)
	T.expect(
		"phase14_golden_rampjump_sector2_succeeds",
		jumpCommitted == true
			and jumpOk == true
			and jumpReason == nil
			and jumpJob ~= nil
			and jumpState ~= nil
			and jumpState.mechanic == "RampJump",
		string.format(
			"ok=%s reason=%s final=%s mechanic=%s runs=%s",
			tostring(jumpOk),
			tostring(jumpReason),
			tostring(jumpJob and jumpJob.final_status),
			tostring(jumpState and jumpState.mechanic),
			jumpRuns
		)
	)
	resetEditableSectors()

	local chicaneState = makeState(3, "Chicane", {
		amplitude = GOLDEN_CHICANE_SECTOR3.amplitude,
		transition_length = GOLDEN_CHICANE_SECTOR3.transition_length,
		corridor_width = GOLDEN_CHICANE_SECTOR3.corridor_width,
	}, GOLDEN_CHICANE_SECTOR3.ingress, GOLDEN_CHICANE_SECTOR3.egress)
	local chicaneLap = select(1, runAttemptState(chicaneState))
	T.expect(
		"phase14_golden_chicane_sector3_succeeds",
		chicaneLap.success == true,
		"chicane lap failed: " .. resultSummary(chicaneLap)
	)
	resetEditableSectors()

	local crestCommitted, crestOk, crestReason, crestJob, crestState, crestRuns =
		submitWithRetries("add a crest in sector 3", 3, "CrestDip", 5)
	T.expect(
		"phase14_golden_crestdip_sector3_succeeds",
		crestCommitted == true
			and crestOk == true
			and crestReason == nil
			and crestJob ~= nil
			and crestState ~= nil
			and crestState.mechanic == "CrestDip",
		string.format(
			"ok=%s reason=%s final=%s mechanic=%s runs=%s",
			tostring(crestOk),
			tostring(crestReason),
			tostring(crestJob and crestJob.final_status),
			tostring(crestState and crestState.mechanic),
			crestRuns
		)
	)
	local sector2Committed, sector2Ok, sector2Reason, sector2Job, sector2State, sector2Runs =
		submitWithRetries("add a crest in sector 2", 2, "CrestDip", 5)
	T.expect(
		"phase14_crestdip_sector2_then_sector3_has_no_downstream_failure",
		crestCommitted == true
			and crestOk == true
			and crestReason == nil
			and crestJob ~= nil
			and crestState ~= nil
			and crestState.mechanic == "CrestDip"
			and sector2Committed == true
			and sector2Ok == true
			and sector2Reason == nil
			and sector2Job ~= nil
			and sector2State ~= nil
			and sector2State.mechanic == "CrestDip",
		string.format(
			"sector3 ok=%s reason=%s final=%s mechanic=%s runs=%s :: sector2 ok=%s reason=%s final=%s mechanic=%s runs=%s",
			tostring(crestOk),
			tostring(crestReason),
			tostring(crestJob and crestJob.final_status),
			tostring(crestState and crestState.mechanic),
			crestRuns,
			tostring(sector2Ok),
			tostring(sector2Reason),
			tostring(sector2Job and sector2Job.final_status),
			tostring(sector2State and sector2State.mechanic),
			sector2Runs
		)
	)
	resetEditableSectors()
end

function TestPhase14.runCrestDipSearch()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase14_crestdip_search_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase14_crestdip_search_baseline_ready", "baseline lap did not complete before search")
		return
	end

	resetEditableSectors()
	local sector3State, sector3Trace = findPassingCrestCandidate(3)
	T.expect(
		"phase14_crestdip_search_sector3_found",
		sector3State ~= nil,
		sector3Trace ~= "" and sector3Trace or "no passing sector-3 crest"
	)
	if sector3State == nil then
		return
	end

	applyState(sector3State)
	SectorRegistry.commit(sector3State)
	local sector3WinnerLine = "[SEARCH] sector3 winner " .. crestCandidateLabel(sector3State)
	print(sector3WinnerLine)
	TestSession.appendLine(sector3WinnerLine)

	local sector2State, sector2Trace = findPassingCrestCandidate(2, CRESTDIP_SEARCH_EGRESS_PADS)
	T.expect(
		"phase14_crestdip_search_sector2_pair_found",
		sector2State ~= nil,
		string.format(
			"sector3=%s\n%s",
			crestCandidateLabel(sector3State),
			sector2Trace ~= "" and sector2Trace or "no paired sector-2 crest"
		)
	)
	if sector2State ~= nil then
		local sector2WinnerLine = "[SEARCH] sector2 winner " .. crestCandidateLabel(sector2State)
		print(sector2WinnerLine)
		TestSession.appendLine(sector2WinnerLine)
	end
end

function TestPhase14.runCrestDipPair()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase14_crestdip_pair_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase14_crestdip_pair_baseline_ready", "baseline lap did not complete before crest pair test")
		return
	end

	resetEditableSectors()
	local sector3Committed, sector3Ok, sector3Reason, sector3Job, sector3State, sector3Runs =
		submitWithRetries("add a crest in sector 3", 3, "CrestDip", 5)
	local sector2Committed, sector2Ok, sector2Reason, sector2Job, sector2State, sector2Runs =
		submitWithRetries("add a crest in sector 2", 2, "CrestDip", 5)

	T.expect(
		"phase14_crestdip_pair_llm_path_commits_both",
		sector3Committed == true
			and sector3Ok == true
			and sector3Reason == nil
			and sector3Job ~= nil
			and sector3State ~= nil
			and sector3State.mechanic == "CrestDip"
			and sector2Committed == true
			and sector2Ok == true
			and sector2Reason == nil
			and sector2Job ~= nil
			and sector2State ~= nil
			and sector2State.mechanic == "CrestDip",
		string.format(
			"sector3 ok=%s reason=%s final=%s mechanic=%s runs=%s :: sector2 ok=%s reason=%s final=%s mechanic=%s runs=%s",
			tostring(sector3Ok),
			tostring(sector3Reason),
			tostring(sector3Job and sector3Job.final_status),
			tostring(sector3State and sector3State.mechanic),
			sector3Runs,
			tostring(sector2Ok),
			tostring(sector2Reason),
			tostring(sector2Job and sector2Job.final_status),
			tostring(sector2State and sector2State.mechanic),
			sector2Runs
		)
	)

	resetEditableSectors()
end

function TestPhase14.runSector2Debug()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase14_sector2_debug_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase14_sector2_debug_baseline_ready", "baseline lap did not complete before sector2 debug run")
		return
	end

	local prevDebugEnabled = workspace:GetAttribute("AutoTrack_SectorDebugEnabled")
	local prevDebugTarget = workspace:GetAttribute("AutoTrack_SectorDebugTarget")
	local prevDebugMax = workspace:GetAttribute("AutoTrack_SectorDebugProgressMax")
	local prevDebugStep = workspace:GetAttribute("AutoTrack_SectorDebugProgressStep")

	resetEditableSectors()
	Tracer.clear()

	workspace:SetAttribute("AutoTrack_SectorDebugEnabled", true)
	workspace:SetAttribute("AutoTrack_SectorDebugTarget", 2)
	workspace:SetAttribute("AutoTrack_SectorDebugProgressMax", 0.12)
	workspace:SetAttribute("AutoTrack_SectorDebugProgressStep", 0.005)

	local submitOk, submitReason = JobRunner.submit("add a jump to sector 2")
	local job = JobRunner.getLastJob()
	local committed = SectorRegistry.getCommitted(2)

	debugLine(string.format("submit_ok=%s reason=%s", tostring(submitOk), tostring(submitReason)))
	debugLine("initial_state=" .. debugValue(job and job.initial_state))
	debugLine("final_status=" .. tostring(job and job.final_status))
	debugLine("committed_state=" .. debugValue(committed))
	debugLine("attempts=" .. summariseAttempts(job))

	local debugTraceCount = 0
	for _, line in ipairs(Tracer.getLog()) do
		if
			string.find(line, "proposal sector=2", 1, true) ~= nil
			or string.find(line, "attempt_result", 1, true) ~= nil
			or string.find(line, "repair attempt=", 1, true) ~= nil
			or string.find(line, "sector_debug sector=2", 1, true) ~= nil
			or string.find(line, "sector_debug_failure sector=2", 1, true) ~= nil
		then
			debugLine(line)
			debugTraceCount += 1
		end
		if debugTraceCount >= 120 then
			break
		end
	end
	debugLine(string.format("trace_lines_emitted=%d", debugTraceCount))

	T.expect(
		"phase14_sector2_debug_submit_completed",
		submitOk == true and submitReason == nil and job ~= nil,
		string.format("submit_ok=%s reason=%s job=%s", tostring(submitOk), tostring(submitReason), tostring(job ~= nil))
	)

	workspace:SetAttribute("AutoTrack_SectorDebugEnabled", prevDebugEnabled)
	workspace:SetAttribute("AutoTrack_SectorDebugTarget", prevDebugTarget)
	workspace:SetAttribute("AutoTrack_SectorDebugProgressMax", prevDebugMax)
	workspace:SetAttribute("AutoTrack_SectorDebugProgressStep", prevDebugStep)
	resetEditableSectors()
end

function TestPhase14.run()
	TestPhase14.runUnit()
	TestPhase14.runIntegration()
end

return TestPhase14
