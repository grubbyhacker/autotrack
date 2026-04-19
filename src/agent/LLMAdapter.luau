-- LLMAdapter.luau
-- Narrow boundary between the CI orchestrator and the language model.
-- prd_plan.md §17 Phase 7, extended Phase 13
--
-- All LLM calls go through here. Reads LLMConfig on every call so model
-- changes take effect immediately without requiring a restart.
--
-- propose(request)          → (SectorState?, error?)
-- repair(packet, history)   → (AgentAction?, SectorState?, explanation?, error?)
--   heuristic path: (action, nil, explanation, nil)
--   LLM path:       (nil, newSectorState, explanation, nil)
--   error:          (nil, nil, nil, errorString)

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
local PromptBuilder = require(script.Parent.PromptBuilder)
local ActionValidator = require(script.Parent.ActionValidator)
local MinimalProposer = require(script.Parent.Parent.Orchestrator.MinimalProposer)

type Request = Types.Request
type SectorState = Types.SectorState
type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket
type AttemptRecord = Types.AttemptRecord

local LLMAdapter = {}

local _providerName = "mock"
local _lastExchange = nil

-- Optional injected provider used by tests (overrides LLMConfig routing).
local _injectedProvider = nil
local _injectedProviderName = nil

local function decodeResponse(raw, kind: string)
	if type(raw) == "table" then
		return raw
	end
	if type(raw) ~= "string" then
		error(kind .. " backend response must be a table or JSON string")
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok then
		error(kind .. " backend response was not valid JSON: " .. tostring(decoded))
	end
	return decoded
end

local function shortenExplanation(explanation): string?
	if type(explanation) ~= "string" then return nil end
	local trimmed = string.match(explanation, "^%s*(.-)%s*$") or ""
	if trimmed == "" or #trimmed > 120 then return nil end
	return trimmed
end

local function mockProvider()
	return {
		propose = function(payload)
			local state, err = MinimalProposer.initial(payload.request)
			if not state then error(err) end
			return HttpService:JSONEncode(state)
		end,
		repair = function(payload)
			local action, explanation, err = MinimalProposer.repair(payload.packet)
			if not action then error(err) end
			return HttpService:JSONEncode({ action = action, explanation = explanation })
		end,
	}
end

-- Select the active provider based on current LLMConfig (or injected test provider).
local function activeProvider()
	if _injectedProvider then
		return _injectedProvider, _injectedProviderName or "injected"
	end
	local cfg = LLMConfig.get()
	if not cfg.enabled or cfg.isHeuristic then
		return mockProvider(), "mock"
	end
	local OpenRouterProvider = require(script.Parent.OpenRouterProvider)
	return OpenRouterProvider(cfg.modelId), cfg.modelId
end

-- ── Test injection API ───────────────────────────────────────────────────────

-- Inject a test provider that overrides LLMConfig routing.
-- Pass nil to clear and restore normal routing.
function LLMAdapter.setProvider(name: string, provider)
	assert(type(name) == "string" and name ~= "", "setProvider: name required")
	if provider == nil then
		_injectedProvider = nil
		_injectedProviderName = nil
		return
	end
	assert(type(provider) == "table", "setProvider: provider table required")
	assert(type(provider.propose) == "function", "setProvider: provider.propose missing")
	assert(type(provider.repair) == "function", "setProvider: provider.repair missing")
	_injectedProvider = provider
	_injectedProviderName = name
end

function LLMAdapter.useMockProvider()
	_injectedProvider = nil
	_injectedProviderName = nil
end

function LLMAdapter.getProviderName(): string
	if _injectedProvider then
		return _injectedProviderName or "injected"
	end
	local cfg = LLMConfig.get()
	if not cfg.enabled or cfg.isHeuristic then
		return "mock"
	end
	return cfg.modelId
end

function LLMAdapter.getLastExchange()
	return _lastExchange
end

-- ── propose ─────────────────────────────────────────────────────────────────

function LLMAdapter.propose(request: Request): (SectorState?, string?)
	local provider, providerName = activeProvider()
	local systemPrompt = PromptBuilder.systemPrompt()
	local userPrompt = PromptBuilder.initialProposal(request)

	local ok, rawOrErr = pcall(function()
		return provider.propose({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			request = request,
		})
	end)
	if not ok then
		return nil, "proposal backend failure: " .. tostring(rawOrErr)
	end

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "proposal")
	end)
	if not decodeOk then
		return nil, tostring(decodedOrErr)
	end

	_lastExchange = {
		kind = "propose",
		provider = providerName,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	local state = decodedOrErr
	local valid, err = ActionValidator.validateSectorState(state)
	if not valid then
		return nil, "invalid proposal: " .. tostring(err)
	end
	if state.sector_id ~= request.parsed.sector_id then
		return nil, "invalid proposal: sector_id mismatch"
	end
	if request.parsed.request_kind == "Mechanic" and state.mechanic ~= request.parsed.mechanic then
		return nil, "invalid proposal: mechanic mismatch"
	end
	if request.parsed.request_kind == "Pad" then
		local side = request.parsed.pad_side
		local value = request.parsed.pad_value
		if side == nil or value == nil then
			return nil, "invalid proposal: pad request missing target"
		end
		if state.pads[side] ~= value then
			return nil, "invalid proposal: pad target mismatch"
		end
	end

	return state, nil
end

-- ── repair ───────────────────────────────────────────────────────────────────

-- Returns (AgentAction?, SectorState?, explanation?, error?)
--   heuristic path: (action, nil, explanation, nil)
--   LLM full-state path: (nil, newSectorState, explanation, nil)
--   error: (nil, nil, nil, errorString)
function LLMAdapter.repair(packet: FailurePacket, history: { AttemptRecord }?): (AgentAction?, SectorState?, string?, string?)
	local provider, providerName = activeProvider()

	-- Cap history to MAX_HISTORY_DEPTH
	local cappedHistory = {}
	if history then
		local depth = LLMConfig.MAX_HISTORY_DEPTH
		local start = math.max(1, #history - depth + 1)
		for i = start, #history do
			table.insert(cappedHistory, history[i])
		end
	end

	local systemPrompt = PromptBuilder.systemPrompt()
	local userPrompt = PromptBuilder.repairStep(packet)

	local ok, rawOrErr = pcall(function()
		return provider.repair({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			packet = packet,
			history = cappedHistory,
		})
	end)
	if not ok then
		return nil, nil, nil, "repair backend failure: " .. tostring(rawOrErr)
	end

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "repair")
	end)
	if not decodeOk then
		return nil, nil, nil, tostring(decodedOrErr)
	end

	_lastExchange = {
		kind = "repair",
		provider = providerName,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	-- Detect LLM full-state path: response has "newState" key
	local decoded = decodedOrErr
	if decoded.newState ~= nil then
		-- LLM returned a full SectorState replacement
		local newState = decoded.newState
		local explanation = shortenExplanation(decoded.explanation)
			or string.format("LLM revised (attempt %d)", packet.attempt_index + 1)

		local valid, verr = ActionValidator.validateSectorState(newState)
		if not valid then
			return nil, nil, nil, "invalid LLM repair state: " .. tostring(verr)
		end
		if newState.sector_id ~= packet.sector_state.sector_id then
			return nil, nil, nil, "LLM repair: sector_id mismatch"
		end
		if newState.mechanic ~= packet.sector_state.mechanic then
			return nil, nil, nil, "LLM repair: mechanic mismatch"
		end
		return nil, newState, explanation, nil
	end

	-- Heuristic / injected delta-action path
	local action = decoded.action
	local explanation = shortenExplanation(decoded.explanation)
	if action == nil then
		return nil, nil, nil, "invalid repair: missing action"
	end
	if explanation == nil then
		return nil, nil, nil, "invalid repair: explanation must be short non-empty text"
	end

	local valid, err = ActionValidator.validateAction(action, packet.sector_state.mechanic)
	if not valid then
		return nil, nil, nil, "invalid repair: " .. tostring(err)
	end

	return action, nil, explanation, nil
end

return LLMAdapter
