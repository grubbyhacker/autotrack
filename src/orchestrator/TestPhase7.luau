local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local T = require(script.Parent.TestUtils)
local PromptBuilder = require(script.Parent.Parent.Agent.PromptBuilder)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local JobRunner = require(script.Parent.JobRunner)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

local TestPhase7 = {}

local function makeRequest()
	return {
		request_id = "phase7-request",
		raw_text = "add a wide chicane in sector 4",
		parsed = {
			sector_id = 4,
			mechanic = "Chicane",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = { "wide" },
		timestamp = os.time(),
	}
end

local function makePacket()
	return {
		request = makeRequest(),
		sector_state = {
			sector_id = 4,
			mechanic = "Chicane",
			params = {
				amplitude = 8,
				transition_length = 15,
				corridor_width = 14,
			},
			pads = {
				ingress = "None",
				egress = "None",
			},
			version = 0,
		},
		attempt_index = 0,
		last_action = nil,
		run_result = {
			success = false,
			failure = {
				type = "mechanic_integrity_failure",
				sector_id = 4,
			},
			metrics = {
				entry_speed = 40,
				exit_speed = 30,
				airborne = false,
				air_distance = 0,
				lateral_error = 5,
				vertical_displacement = 0,
				reacquired = true,
				lap_time = 25,
				slowdown_ratio = 1,
			},
		},
		diagnostics = {
			failure_sector = 4,
			hints = { "lateral displacement too small" },
		},
		legal_actions = {
			numeric_levers = { "amplitude", "transition_length", "corridor_width" },
			pads = { "ingress", "egress" },
		},
	}
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

function TestPhase7.runUnit()
	LLMAdapter.useMockProvider()

	local request = makeRequest()
	local packet = makePacket()

	local systemPrompt = PromptBuilder.systemPrompt()
	T.expect("prompt_system_mentions_json", string.find(systemPrompt, "JSON", 1, true) ~= nil, systemPrompt)

	local initialPrompt = PromptBuilder.initialProposal(request)
	T.expect(
		"prompt_initial_includes_request_context",
		string.find(initialPrompt, "Target sector: 4", 1, true) ~= nil
			and string.find(initialPrompt, "Chicane", 1, true) ~= nil
			and string.find(initialPrompt, "wide", 1, true) ~= nil,
		initialPrompt
	)

	local repairPrompt = PromptBuilder.repairStep(packet)
	T.expect(
		"prompt_repair_includes_diagnostics",
		string.find(repairPrompt, "Repair request.", 1, true) ~= nil
			and string.find(repairPrompt, "lateral displacement too small", 1, true) ~= nil,
		repairPrompt
	)

	local state, proposalErr = LLMAdapter.propose(request)
	T.expect(
		"llmadapter_mock_propose_valid",
		state ~= nil and proposalErr == nil and state.mechanic == "Chicane" and state.sector_id == 4,
		tostring(proposalErr)
	)

	local action, explanation, repairErr = LLMAdapter.repair(packet)
	T.expect(
		"llmadapter_mock_repair_valid",
		action ~= nil and explanation ~= nil and repairErr == nil,
		tostring(repairErr)
	)

	LLMAdapter.setProvider("bad-sector", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 3,
				mechanic = "Chicane",
				params = { amplitude = 8, transition_length = 15, corridor_width = 14 },
				pads = { ingress = "None", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "amplitude", value = 10 },
				explanation = "increase amplitude",
			})
		end,
	})
	local _, sectorMismatchErr = LLMAdapter.propose(request)
	T.expect("llmadapter_rejects_sector_mismatch",
		sectorMismatchErr == "invalid proposal: sector_id mismatch",
		tostring(sectorMismatchErr)
	)

	LLMAdapter.setProvider("bad-mechanic", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 4,
				mechanic = "RampJump",
				params = { ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
				pads = { ingress = "None", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "amplitude", value = 10 },
				explanation = "increase amplitude",
			})
		end,
	})
	local _, mechanicMismatchErr = LLMAdapter.propose(request)
	T.expect("llmadapter_rejects_mechanic_mismatch",
		mechanicMismatchErr == "invalid proposal: mechanic mismatch",
		tostring(mechanicMismatchErr)
	)

	LLMAdapter.setProvider("bad-repair", {
		propose = function()
			return HttpService:JSONEncode(state)
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "ramp_angle", value = 10 },
				explanation = "bad action",
			})
		end,
	})
	local _, _, invalidRepairErr = LLMAdapter.repair(packet)
	T.expect("llmadapter_rejects_invalid_repair_action",
		string.find(tostring(invalidRepairErr), "invalid repair", 1, true) ~= nil,
		tostring(invalidRepairErr)
	)

	LLMAdapter.setProvider("bad-explanation", {
		propose = function()
			return HttpService:JSONEncode(state)
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "amplitude", value = 10 },
				explanation = string.rep("x", 121),
			})
		end,
	})
	local _, _, explanationErr = LLMAdapter.repair(packet)
	T.expect("llmadapter_rejects_long_explanation",
		explanationErr == "invalid repair: explanation must be short non-empty text",
		tostring(explanationErr)
	)

	LLMAdapter.setProvider("custom", {
		propose = function(payload)
			return HttpService:JSONEncode({
				sector_id = payload.request.parsed.sector_id,
				mechanic = payload.request.parsed.mechanic,
				params = { amplitude = 9, transition_length = 15, corridor_width = 16 },
				pads = { ingress = "None", egress = "Brake" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "amplitude", value = 11 },
				explanation = "increase amplitude",
			})
		end,
	})
	local customState, customErr = LLMAdapter.propose(request)
	T.expect("llmadapter_accepts_custom_provider",
		customState ~= nil and customErr == nil and LLMAdapter.getProviderName() == "custom",
		tostring(customErr)
	)

	local exchange = LLMAdapter.getLastExchange()
	T.expect("llmadapter_records_last_exchange",
		exchange ~= nil and exchange.provider == "custom" and exchange.kind == "propose",
		tostring(exchange and exchange.provider)
	)

	LLMAdapter.useMockProvider()
end

function TestPhase7.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase7_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase7_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	local proposeCount = 0
	local repairCount = 0
	LLMAdapter.setProvider("integration-stub", {
		propose = function(payload)
			proposeCount += 1
			return HttpService:JSONEncode({
				sector_id = payload.request.parsed.sector_id,
				mechanic = payload.request.parsed.mechanic,
				params = {
					amplitude = 9,
					transition_length = 15,
					corridor_width = 16,
				},
				pads = {
					ingress = "None",
					egress = "Brake",
				},
				version = SectorRegistry.getCommitted(payload.request.parsed.sector_id).version,
			})
		end,
		repair = function()
			repairCount += 1
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "amplitude", value = 11 },
				explanation = "increase amplitude",
			})
		end,
	})

	local ok, reason = JobRunner.submit("add a chicane in sector 4")
	local state = SectorRegistry.getCommitted(4)
	T.expect("phase7_jobrunner_uses_adapter_provider",
		ok == true
			and reason == nil
			and proposeCount == 1
			and repairCount == 0
			and state ~= nil
			and state.mechanic == "Chicane"
			and state.version == 1,
		tostring(reason)
	)

	LLMAdapter.useMockProvider()
end

function TestPhase7.run()
	TestPhase7.runUnit()
	TestPhase7.runIntegration()
end

return TestPhase7
