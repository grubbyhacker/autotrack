-- TestPhase13.luau
-- Phase 13: Real LLM integration tests.
-- Unit tests run with LLM disabled (heuristic). Integration test opts in
-- to a live LLM call via AutoTrack_LLMEnabled=true workspace attribute.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local T = require(script.Parent.TestUtils)
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local RuntimeContext = require(script.Parent.RuntimeContext)
local JobRunner = require(script.Parent.JobRunner)
local UIState = require(script.Parent.UIState)

local TestPhase13 = {}

local function savedConfig()
	return { enabled = LLMConfig.get().enabled, modelId = LLMConfig.get().modelId }
end

local function restoreConfig(saved)
	LLMConfig.setEnabled(saved.enabled)
	LLMConfig.setModel(saved.modelId)
	LLMAdapter.useMockProvider()
end

local function makeRequest(sectorId: number, mechanic: string)
	local raw = string.format("add a %s in sector %d", string.lower(mechanic), sectorId)
	local request, err = RequestParser.parse(raw, "test-req")
	assert(request ~= nil, "parse failed: " .. tostring(err))
	return request
end

local function makeState(sectorId, mechanic, params)
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params or {},
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function fakePacket(request, state, attemptIndex)
	return {
		request = request,
		sector_state = state,
		attempt_index = attemptIndex or 0,
		last_action = nil,
		run_result = {
			success = false,
			failure = { type = "local_execution_failure", sector_id = state.sector_id, detail = "off_track" },
			metrics = { lap_time = 30, slowdown_ratio = 1 },
		},
		diagnostics = { failure_sector = state.sector_id, hints = {} },
		legal_actions = { numeric_levers = { "amplitude" }, pads = {} },
	}
end

-- ── unit tests ───────────────────────────────────────────────────────────────

function TestPhase13.runUnit()
	local saved = savedConfig()

	-- 1–3: LLMConfig defaults and mutations
	LLMConfig.setEnabled(false)
	LLMConfig.setModel("heuristic")
	local cfg = LLMConfig.get()
	T.expect("config_defaults_disabled", not cfg.enabled)
	T.expect("config_defaults_model_heuristic", cfg.modelId == "heuristic")
	T.expect("config_defaults_isHeuristic", cfg.isHeuristic == true)

	LLMConfig.setEnabled(true)
	LLMConfig.setModel("google/gemma-3-4b-it")
	cfg = LLMConfig.get()
	T.expect("config_set_enabled", cfg.enabled == true)
	T.expect("config_set_model", cfg.modelId == "google/gemma-3-4b-it")
	T.expect("config_set_displayname", cfg.displayName == "Gemma 3 4B")

	-- 4: setModel with unknown ID is a no-op
	LLMConfig.setModel("no-such/model")
	T.expect("config_invalid_model_noop", LLMConfig.get().modelId == "google/gemma-3-4b-it")

	-- 5–6: adapter provider name routing
	LLMConfig.setEnabled(false)
	T.expect("adapter_mock_when_disabled", LLMAdapter.getProviderName() == "mock")

	LLMConfig.setEnabled(true)
	LLMConfig.setModel("heuristic")
	T.expect("adapter_mock_for_heuristic_model", LLMAdapter.getProviderName() == "mock")

	LLMConfig.setEnabled(true)
	LLMConfig.setModel("qwen/qwen-turbo")
	T.expect("adapter_llm_name_when_enabled", LLMAdapter.getProviderName() == "qwen/qwen-turbo")

	restoreConfig(saved)

	-- 7: cycleModel wraps at boundaries
	LLMConfig.setModel("heuristic")
	LLMConfig.cycleModel(-1)
	T.expect("cycle_back_wraps_to_last", LLMConfig.get().modelId == LLMConfig.MODELS[#LLMConfig.MODELS].id)
	LLMConfig.setModel("heuristic")
	LLMConfig.cycleModel(1)
	T.expect("cycle_forward_to_second", LLMConfig.get().modelId == LLMConfig.MODELS[2].id)
	restoreConfig(saved)

	-- 8: injected shim returning newState → (nil, SectorState, explanation, nil)
	local shimState = makeState(3, "Chicane", { amplitude = 6, transition_length = 15, corridor_width = 14 })
	local shim = {
		propose = function(_)
			return HttpService:JSONEncode(makeState(3, "Chicane", { amplitude = 5, transition_length = 15, corridor_width = 14 }))
		end,
		repair = function(_)
			return HttpService:JSONEncode({ newState = shimState, explanation = "adjusted amplitude" })
		end,
	}
	LLMAdapter.setProvider("test-shim", shim)
	T.expect("injected_provider_name", LLMAdapter.getProviderName() == "test-shim")

	local request = makeRequest(3, "Chicane")
	local state = makeState(3, "Chicane", { amplitude = 5, transition_length = 15, corridor_width = 14 })
	local packet = fakePacket(request, state, 1)
	local action, newState, explanation, err = LLMAdapter.repair(packet, {})
	T.expect("llm_repair_action_nil", action == nil)
	T.expect("llm_repair_newstate_present", newState ~= nil and newState.mechanic == "Chicane")
	T.expect("llm_repair_explanation_present", type(explanation) == "string" and #explanation > 0)
	T.expect("llm_repair_no_error", err == nil)
	LLMAdapter.useMockProvider()

	-- 9: sector_id mismatch on propose → rejected (moved from TestPhase7)
	LLMAdapter.setProvider("bad-sector", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 2,
				mechanic = "Chicane",
				params = { amplitude = 8, transition_length = 15, corridor_width = 14 },
				pads = { ingress = "None", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({ action = { type = "SetNumericLever", lever = "amplitude", value = 10 }, explanation = "x" })
		end,
	})
	local _, sectorMismatchErr = LLMAdapter.propose(makeRequest(3, "Chicane"))
	T.expect("llmadapter_rejects_sector_mismatch",
		sectorMismatchErr == "invalid proposal: sector_id mismatch",
		tostring(sectorMismatchErr))
	LLMAdapter.useMockProvider()

	-- 10: mechanic mismatch on propose → rejected
	LLMAdapter.setProvider("bad-mechanic", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 3,
				mechanic = "RampJump",
				params = { ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
				pads = { ingress = "None", egress = "None" },
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({ action = { type = "SetNumericLever", lever = "amplitude", value = 10 }, explanation = "x" })
		end,
	})
	local _, mechanicMismatchErr = LLMAdapter.propose(makeRequest(3, "Chicane"))
	T.expect("llmadapter_rejects_mechanic_mismatch",
		mechanicMismatchErr == "invalid proposal: mechanic mismatch",
		tostring(mechanicMismatchErr))
	LLMAdapter.useMockProvider()

	-- 11: invalid repair action lever for mechanic → rejected
	local validChicaneState = makeState(3, "Chicane", { amplitude = 8, transition_length = 15, corridor_width = 14 })
	local validChicanePropose = {
		propose = function()
			return HttpService:JSONEncode(validChicaneState)
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetNumericLever", lever = "ramp_angle", value = 10 },
				explanation = "wrong lever",
			})
		end,
	}
	LLMAdapter.setProvider("bad-repair", validChicanePropose)
	local repairRequest = makeRequest(3, "Chicane")
	local repairPacket = fakePacket(repairRequest, validChicaneState, 0)
	repairPacket.legal_actions.numeric_levers = { "amplitude", "transition_length", "corridor_width" }
	local _, _, _, invalidRepairErr = LLMAdapter.repair(repairPacket, {})
	T.expect("llmadapter_rejects_invalid_repair_action",
		string.find(tostring(invalidRepairErr), "invalid repair", 1, true) ~= nil,
		tostring(invalidRepairErr))
	LLMAdapter.useMockProvider()

	-- 12: last exchange is recorded after propose
	LLMAdapter.setProvider("exchange-recorder", {
		propose = function()
			return HttpService:JSONEncode(makeState(3, "Chicane", { amplitude = 9, transition_length = 15, corridor_width = 16 }))
		end,
		repair = function()
			return HttpService:JSONEncode({ action = { type = "SetNumericLever", lever = "amplitude", value = 11 }, explanation = "x" })
		end,
	})
	LLMAdapter.propose(makeRequest(3, "Chicane"))
	local exchange = LLMAdapter.getLastExchange()
	T.expect("llmadapter_records_last_exchange",
		exchange ~= nil and exchange.provider == "exchange-recorder" and exchange.kind == "propose",
		tostring(exchange and exchange.provider))
	LLMAdapter.useMockProvider()

	-- 13: partial initial proposal state is merged with request-shaped defaults
	LLMAdapter.setProvider("partial-propose", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 3,
				mechanic = "CrestDip",
				params = { height_or_depth = 11, sector_length = 26 },
				pads = { ingress = "Brake10" },
			})
		end,
		repair = function()
			return HttpService:JSONEncode({ action = { type = "SetNumericLever", lever = "amplitude", value = 11 }, explanation = "x" })
		end,
	})
	local partialProposed, partialProposeErr = LLMAdapter.propose(makeRequest(3, "CrestDip"))
	T.expect("llmadapter_merges_partial_initial_proposal",
		partialProposeErr == nil
			and partialProposed ~= nil
			and type(partialProposed.params.height_or_depth) == "number"
			and type(partialProposed.params.sector_length) == "number"
			and type(partialProposed.params.radius) == "number"
			and partialProposed.pads.ingress == "Brake10"
			and partialProposed.pads.egress == "None"
			and partialProposed.params.height_or_depth >= 4
			and partialProposed.params.sector_length >= 20,
		tostring(partialProposeErr or HttpService:JSONEncode(partialProposed or {})))
	LLMAdapter.useMockProvider()

	-- 14: Boost50 is a valid pad value (phase 14 wiring check)
	do
		local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
		local ActionValidator = require(script.Parent.Parent.Agent.ActionValidator)
		T.expect("boost50_is_valid_pad_value",
			PadValueUtils.isValid("Boost50") and PadValueUtils.isValid("Brake50"),
			"expected Boost50 and Brake50 to be valid pad values")

		local boost50Action = { type = "SetPad", pad = "ingress", value = "Boost50" }
		local actionOk, actionErr = ActionValidator.validateAction(boost50Action, "RampJump")
		T.expect("boost50_passes_action_validator",
			actionOk == true,
			"expected Boost50 to pass ActionValidator: " .. tostring(actionErr))

		local stateWithBoost50 = makeState(3, "RampJump", { ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 })
		stateWithBoost50.pads.ingress = "Boost50"
		local stateOk, stateErr = ActionValidator.validateSectorState(stateWithBoost50)
		T.expect("boost50_passes_state_validator",
			stateOk == true,
			"expected Boost50 state to pass validateSectorState: " .. tostring(stateErr))
	end

	-- 14: error shim → error string returned, no crash
	local errorShim = {
		propose = function(_) error("simulated API failure") end,
		repair = function(_) error("simulated API failure") end,
	}
	LLMAdapter.setProvider("error-shim", errorShim)
	local _, propErr = LLMAdapter.propose(makeRequest(3, "Chicane"))
	T.expect("llm_propose_error_string", type(propErr) == "string" and propErr ~= "")
	local _, _, _, repErr = LLMAdapter.repair(fakePacket(request, state, 0), {})
	T.expect("llm_repair_error_string", type(repErr) == "string" and repErr ~= "")
	LLMAdapter.useMockProvider()

	restoreConfig(saved)
end

-- ── integration test (opt-in) ────────────────────────────────────────────────

function TestPhase13.runIntegration()
	local llmEnabled = workspace:GetAttribute("AutoTrack_LLMEnabled") == true
	if not llmEnabled then
		T.pass("llm_integration_skipped_no_flag")
		print("[Phase13] Integration test skipped: set AutoTrack_LLMEnabled=true to enable")
		return
	end

	assert(RuntimeContext.isReady(), "runtime context not ready for integration test")

	local saved = savedConfig()
	local llmModel = workspace:GetAttribute("AutoTrack_LLMModel") or "google/gemma-3-4b-it"
	LLMConfig.setEnabled(true)
	LLMConfig.setModel(llmModel)

	print(string.format("[Phase13] Integration test running with model: %s", LLMConfig.get().displayName))

	local ok, jobErr = pcall(function()
		local success, reason = JobRunner.submit("add a chicane in sector 3")
		T.expect("llm_integration_job_accepted", success == true, tostring(reason))

		local job = JobRunner.getLastJob()
		T.expect("llm_integration_job_exists", job ~= nil)
		if job then
			if job.final_status == "committed" then
				local valid, verr = ActionValidator.validateSectorState(job.working_state)
				T.expect("llm_integration_committed_state_valid", valid, tostring(verr))
				T.expect("llm_integration_mechanic_chicane", job.working_state.mechanic == "Chicane")
				print(string.format("[Phase13] LLM committed Chicane amplitude=%s", tostring(job.working_state.params.amplitude)))
			else
				local stateFolder = UIState.getStateFolder()
				local errText = stateFolder:GetAttribute("error_text") or ""
				T.expect("llm_integration_revert_has_context", errText ~= "" or #job.attempts > 0,
					"reverted with no attempts logged")
				print(string.format("[Phase13] LLM reverted after %d attempts", #job.attempts))
			end
		end
	end)

	restoreConfig(saved)

	if not ok then
		T.fail("llm_integration_unexpected_error", tostring(jobErr))
	end
end

function TestPhase13.run()
	TestPhase13.runUnit()
	TestPhase13.runIntegration()
end

return TestPhase13
