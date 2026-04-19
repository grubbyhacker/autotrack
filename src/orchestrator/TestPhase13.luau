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

	-- 9: error shim → error string returned, no crash
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
