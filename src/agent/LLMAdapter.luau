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
local OrchestratorPromptBuilder = require(script.Parent.OrchestratorPromptBuilder)
local PromptBuilder = require(script.Parent.PromptBuilder)
local ActionValidator = require(script.Parent.ActionValidator)
local MinimalProposer = require(script.Parent.Parent.Orchestrator.MinimalProposer)
local MinimalOrchestrator = require(script.Parent.Parent.Orchestrator.MinimalOrchestrator)
local CrestDipTuner = require(script.Parent.Parent.Mechanics.CrestDipTuner)
local RampJumpTuner = require(script.Parent.Parent.Mechanics.RampJumpTuner)

type Request = Types.Request
type SectorState = Types.SectorState
type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket
type AttemptRecord = Types.AttemptRecord
type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision

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

local function cloneTableShallow(source)
	local result = {}
	if type(source) ~= "table" then
		return result
	end
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function mergeRepairState(currentState: SectorState, candidate): SectorState
	local merged = {
		sector_id = if type(candidate) == "table" and type(candidate.sector_id) == "number"
			then candidate.sector_id
			else currentState.sector_id,
		mechanic = if type(candidate) == "table" and candidate.mechanic ~= nil
			then candidate.mechanic
			else currentState.mechanic,
		params = cloneTableShallow(currentState.params),
		pads = {
			ingress = currentState.pads.ingress,
			egress = currentState.pads.egress,
		},
		version = if type(candidate) == "table" and type(candidate.version) == "number"
			then candidate.version
			else currentState.version,
	}

	if type(candidate) == "table" then
		if type(candidate.params) == "table" then
			for key, value in pairs(candidate.params) do
				merged.params[key] = value
			end
		end
		if type(candidate.pads) == "table" then
			if candidate.pads.ingress ~= nil then
				merged.pads.ingress = candidate.pads.ingress
			end
			if candidate.pads.egress ~= nil then
				merged.pads.egress = candidate.pads.egress
			end
		end
	end

	return merged
end

local function isPlainCrestRequest(request: Request): boolean
	return request.parsed.request_kind == "Mechanic"
		and request.parsed.mechanic == "CrestDip"
		and #request.qualifiers == 0
end

local function isPlainRampRequest(request: Request): boolean
	return request.parsed.request_kind == "Mechanic"
		and request.parsed.mechanic == "RampJump"
		and #request.qualifiers == 0
end

local function isPostCornerEditableSector(sectorId: number): boolean
	return sectorId == 2 or sectorId == 7
end

local function normalizeInitialProposalForRequest(request: Request, state: SectorState): SectorState
	if state.mechanic == "RampJump" then
		local postCornerRamp = isPostCornerEditableSector(request.parsed.sector_id)
		local plainRamp = isPlainRampRequest(request)
		state.params = RampJumpTuner.tune(state.params, {
			postCorner = postCornerRamp,
			preferGentle = plainRamp,
		})
		if postCornerRamp then
			state.pads.ingress = "Brake50"
			state.pads.egress = "Brake25"
		elseif plainRamp then
			state.pads.ingress = "Brake25"
			state.pads.egress = "Brake10"
		end
		return state
	end

	if state.mechanic ~= "CrestDip" then
		return state
	end

	local postCornerCrest = isPostCornerEditableSector(request.parsed.sector_id)
	if isPlainCrestRequest(request) or postCornerCrest then
		state.params.sector_length = math.min(state.params.sector_length or 30, 30)
	end
	if postCornerCrest then
		state.params.height_or_depth = math.min(state.params.height_or_depth or 5, 5)
		state.pads.ingress = "Brake25"
		state.pads.egress = "None"
	elseif isPlainCrestRequest(request) then
		state.params.height_or_depth = math.min(state.params.height_or_depth or 5, 5)
		state.pads.ingress = "Brake50"
	end

	return state
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
		orchestrate = function(payload)
			return HttpService:JSONEncode(MinimalOrchestrator.decide(payload.context))
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

	local templateState, templateErr = MinimalProposer.initial(request)
	if not templateState then
		return nil, "invalid proposal template: " .. tostring(templateErr)
	end

	local candidate = decodedOrErr
	if type(candidate) ~= "table" then
		return nil, "invalid proposal: sector state must be a table"
	end
	if candidate.sector_id ~= nil and candidate.sector_id ~= request.parsed.sector_id then
		return nil, "invalid proposal: sector_id mismatch"
	end
	if request.parsed.request_kind == "Mechanic"
		and candidate.mechanic ~= nil
		and candidate.mechanic ~= request.parsed.mechanic then
		return nil, "invalid proposal: mechanic mismatch"
	end

	local state = mergeRepairState(templateState, candidate)
	state = normalizeInitialProposalForRequest(request, state)
	if state.mechanic == "CrestDip" then
		state.params.height_or_depth, state.params.sector_length = CrestDipTuner.tune(
			state.params.height_or_depth or 0,
			state.params.sector_length or 0
		)
	elseif state.mechanic == "RampJump" then
		state.params = RampJumpTuner.tune(state.params, {
			postCorner = isPostCornerEditableSector(request.parsed.sector_id),
			preferGentle = isPlainRampRequest(request),
		})
	end
	local valid, err = ActionValidator.validateSectorState(state)
	if not valid then
		return nil, "invalid proposal: " .. tostring(err)
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
		local newState = mergeRepairState(packet.sector_state, decoded.newState)
		if newState.mechanic == "CrestDip" then
			newState.params.height_or_depth, newState.params.sector_length = CrestDipTuner.tune(
				newState.params.height_or_depth or 0,
				newState.params.sector_length or 0
			)
		elseif newState.mechanic == "RampJump" then
			newState.params = RampJumpTuner.tune(newState.params, {
				postCorner = isPostCornerEditableSector(newState.sector_id),
			})
		end
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

local EDITABLE_SECTORS = {
	[2] = true,
	[3] = true,
	[4] = true,
	[7] = true,
	[8] = true,
	[9] = true,
}

local function validateOrchestratorDecision(decoded): (OrchestratorDecision?, string?)
	if type(decoded) ~= "table" then
		return nil, "invalid orchestrate response"
	end
	if decoded.action == "begin_loop" then
		return { action = "begin_loop" }, nil
	end
	if not EDITABLE_SECTORS[decoded.sector_id] then
		return nil, "invalid orchestrate response: sector_id must be an editable sector"
	end
	if decoded.mechanic ~= "RampJump" and decoded.mechanic ~= "Chicane" and decoded.mechanic ~= "CrestDip" then
		return nil, "invalid orchestrate response: mechanic missing or unsupported"
	end
	return {
		sector_id = decoded.sector_id,
		mechanic = decoded.mechanic,
		params_hint = if type(decoded.params_hint) == "string" then decoded.params_hint else "",
		rationale = if type(decoded.rationale) == "string" then shortenExplanation(decoded.rationale) else nil,
	}, nil
end

function LLMAdapter.orchestrate(context: OrchestratorContext): (OrchestratorDecision?, string?)
	local provider, providerName = activeProvider()
	if type(provider.orchestrate) ~= "function" then
		return nil, "orchestrate backend missing"
	end

	local ok, rawOrErr = pcall(function()
		return provider.orchestrate({
			context = context,
			messages = OrchestratorPromptBuilder.messages(context),
		})
	end)
	if not ok then
		return nil, "orchestrate backend failure: " .. tostring(rawOrErr)
	end

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "orchestrate")
	end)
	if not decodeOk then
		return nil, tostring(decodedOrErr)
	end

	_lastExchange = {
		kind = "orchestrate",
		provider = providerName,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	return validateOrchestratorDecision(decodedOrErr)
end

return LLMAdapter
