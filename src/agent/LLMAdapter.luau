-- LLMAdapter.luau
-- Narrow boundary between the CI orchestrator and the language model.
-- prd_plan.md §17 Phase 7, extended Phase 13
--
-- All LLM calls go through here. Reads LLMConfig on every call so model
-- changes take effect immediately without requiring a restart.
--
-- propose(request, designIntent?)          → (SectorState?, MemoryEntry?, error?)
-- repair(packet, history, designIntent?)   → (AgentAction?, SectorState?, explanation?, MemoryEntry?, error?)
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
local LLMTraceJournal = require(script.Parent.LLMTraceJournal)
local MinimalProposer = require(script.Parent.Parent.Orchestrator.MinimalProposer)
local MinimalOrchestrator = require(script.Parent.Parent.Orchestrator.MinimalOrchestrator)
local ChallengeRunner = require(script.Parent.Parent.Orchestrator.ChallengeRunner)
local EnduranceMemory = require(script.Parent.Parent.Orchestrator.EnduranceMemory)
local CrestDipTuner = require(script.Parent.Parent.Mechanics.CrestDipTuner)
local RampJumpTuner = require(script.Parent.Parent.Mechanics.RampJumpTuner)

type Request = Types.Request
type SectorState = Types.SectorState
type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket
type AttemptRecord = Types.AttemptRecord
type DesignIntent = Types.DesignIntent
type ChallengeUpContext = Types.ChallengeUpContext
type MemoryEntry = Types.MemoryEntry
type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision
type LLMTraceRole = Types.LLMTraceRole
type LLMTraceKind = Types.LLMTraceKind

local LLMAdapter = {}

local _providerName = "mock"
local _lastExchange = nil

-- Optional injected provider used by tests (overrides LLMConfig routing).
local _injectedProvider = nil
local _injectedProviderName = nil

local SCORE_BANDS = {
	low = true,
	medium = true,
	high = true,
	extreme = true,
}

local BUDGET_TOLERANCES = {
	low = true,
	medium = true,
	high = true,
}

local RELIABILITY_LEVELS = {
	conservative = true,
	balanced = true,
	risky = true,
}

local PRIORITY_LEVELS = {
	low = true,
	medium = true,
	high = true,
}

local REPLACEMENT_INTENTS = {
	open_slot_preferred = true,
	replace_if_gain = true,
	preserve_good_sector = true,
}

local MEMORY_CONFIDENCE = {
	low = true,
	medium = true,
	high = true,
}

local MEMORY_SOURCE_TYPES = {
	observed_result = true,
	inferred_pattern = true,
	downstream_warning = true,
	explicit_policy = true,
}

local function traceRoleForKind(kind: LLMTraceKind): LLMTraceRole
	if kind == "orchestrate" then
		return "orchestrator"
	elseif kind == "repair" then
		return "repair"
	end
	return "proposal"
end

local function tracePrompt(kind: LLMTraceKind, providerName: string, modelName: string, payload)
	LLMTraceJournal.append({
		role = traceRoleForKind(kind),
		direction = "prompt",
		provider = providerName,
		model = modelName,
		kind = kind,
		payload = payload,
	})
end

local function traceRawResponse(kind: LLMTraceKind, providerName: string, modelName: string, rawResponse)
	LLMTraceJournal.append({
		role = traceRoleForKind(kind),
		direction = "response",
		provider = providerName,
		model = modelName,
		kind = kind,
		payload = {
			stage = "raw",
			raw_response = rawResponse,
		},
	})
end

local function traceDecodedResponse(kind: LLMTraceKind, providerName: string, modelName: string, rawResponse, decodedResponse)
	LLMTraceJournal.append({
		role = traceRoleForKind(kind),
		direction = "response",
		provider = providerName,
		model = modelName,
		kind = kind,
		payload = {
			stage = "decoded",
			raw_response = rawResponse,
			decoded_response = decodedResponse,
		},
	})
end

local function traceError(kind: LLMTraceKind, providerName: string, modelName: string, stage: string, errorText: string, extraPayload)
	local payload = {
		stage = stage,
		error = errorText,
	}
	if type(extraPayload) == "table" then
		for key, value in pairs(extraPayload) do
			payload[key] = value
		end
	end

	LLMTraceJournal.append({
		role = traceRoleForKind(kind),
		direction = "error",
		provider = providerName,
		model = modelName,
		kind = kind,
		payload = payload,
	})
end

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

local function shortenText(value, maxLen: number?): string?
	if type(value) ~= "string" then return nil end
	local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
	if trimmed == "" or #trimmed > (maxLen or 120) then return nil end
	return trimmed
end

local function shortenExplanation(explanation): string?
	return shortenText(explanation, 120)
end

local function truncateText(value: string, maxLen: number): string
	if #value <= maxLen then
		return value
	end
	local truncated = string.sub(value, 1, maxLen)
	return string.match(truncated, "^%s*(.-)%s*$") or truncated
end

local function coerceShortText(value, maxLen: number, defaultText: string?): string?
	if type(value) ~= "string" then
		return defaultText
	end
	local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return defaultText
	end
	return truncateText(trimmed, maxLen)
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

local function cloneSectorState(state: SectorState): SectorState
	return mergeRepairState(state, {})
end

local function normalizeStringArray(value, fieldName: string): ({ string }?, string?)
	if type(value) ~= "table" then
		return nil, fieldName .. " must be an array"
	end

	local result = {}
	for _, item in ipairs(value) do
		local text = coerceShortText(item, 96, nil)
		if text == nil then
			return nil, fieldName .. " entries must be non-empty strings"
		end
		table.insert(result, text)
		if #result >= 4 then
			break
		end
	end
	if #result == 0 then
		return nil, fieldName .. " must contain at least one short string"
	end
	return result, nil
end

local function validateChoice(decoded, fieldName: string, allowed): (string?, string?)
	local value = decoded[fieldName]
	if type(value) ~= "string" or not allowed[value] then
		return nil, "invalid orchestrate response: " .. fieldName .. " missing or unsupported"
	end
	return value, nil
end

local function validateMemoryNote(rawNote, expectedAuthor: string, expectedScope: string, defaultSourceRef: string): (MemoryEntry?, string?)
	if rawNote == nil then
		return nil, nil
	end
	if type(rawNote) ~= "table" then
		return nil, nil
	end

	local rawNoteText = rawNote.note
	if rawNoteText == nil then
		return nil, nil
	end
	if type(rawNoteText) ~= "string" then
		return nil, nil
	end
	local trimmedNote = string.match(rawNoteText, "^%s*(.-)%s*$") or ""
	if trimmedNote == "" then
		return nil, nil
	end

	local author = expectedAuthor
	local scope = expectedScope
	local note = truncateText(trimmedNote, 120)
	local confidence = rawNote.confidence
	if type(confidence) ~= "string" or not MEMORY_CONFIDENCE[confidence] then
		confidence = "medium"
	end

	local sourceType = rawNote.source_type
	if type(sourceType) ~= "string" or not MEMORY_SOURCE_TYPES[sourceType] then
		sourceType = "inferred_pattern"
	end

	local sourceRef = defaultSourceRef
	if type(rawNote.source_ref) == "string" then
		local trimmedRef = string.match(rawNote.source_ref, "^%s*(.-)%s*$") or ""
		if trimmedRef ~= "" then
			sourceRef = truncateText(trimmedRef, 64)
		end
	end

	return {
		entry_id = EnduranceMemory.nextEntryId(expectedAuthor),
		author = author,
		scope = scope,
		note = note,
		confidence = confidence,
		source_type = sourceType,
		source_ref = sourceRef,
		timestamp = DateTime.now().UnixTimestampMillis,
	}, nil
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

local function normalizeChallengeUpProposalForRequest(request: Request, state: SectorState): SectorState
	if state.mechanic == "RampJump" then
		state.params = RampJumpTuner.tune(state.params, {
			postCorner = isPostCornerEditableSector(request.parsed.sector_id),
			preferGentle = false,
		})
		return state
	end

	if state.mechanic == "CrestDip" then
		state.params.height_or_depth, state.params.sector_length = CrestDipTuner.tune(
			state.params.height_or_depth or 0,
			state.params.sector_length or 0
		)
	end

	return state
end

local function mockProvider()
	return {
		propose = function(payload)
			if payload.challenge_up ~= nil then
				local challengeContext = payload.challenge_up
				local baselineState = challengeContext.baseline_state
				local baselineResult = challengeContext.baseline_result
				if baselineState ~= nil and baselineResult ~= nil and baselineResult.score ~= nil then
					local nextState = ChallengeRunner._escalateState(baselineState, baselineResult.score)
					return HttpService:JSONEncode(nextState or cloneSectorState(baselineState))
				end
			end
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
	local cfg = LLMConfig.get()
	if _injectedProvider then
		local injectedName = _injectedProviderName or "injected"
		return _injectedProvider, injectedName, injectedName, cfg.modelId
	end
	if not cfg.enabled or cfg.isHeuristic then
		return mockProvider(), "mock", "mock", "heuristic"
	end
	local OpenRouterProvider = require(script.Parent.OpenRouterProvider)
	return OpenRouterProvider(cfg.modelId), cfg.modelId, "openrouter", cfg.modelId
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

function LLMAdapter.propose(request: Request, designIntent: DesignIntent?): (SectorState?, MemoryEntry?, string?)
	local provider, providerName, traceProvider, traceModel = activeProvider()
	local systemPrompt = PromptBuilder.systemPrompt()
	local userPrompt = PromptBuilder.initialProposal(request)
	local sharedIntent = designIntent or request.design_intent
	local messages = PromptBuilder.proposeMessages(request, sharedIntent)

	tracePrompt("propose", traceProvider, traceModel, {
		system_prompt = systemPrompt,
		user_prompt = userPrompt,
		request = request,
		design_intent = sharedIntent,
		memory_context = request.memory_context,
		messages = messages,
	})

	local ok, rawOrErr = pcall(function()
		return provider.propose({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			request = request,
			design_intent = sharedIntent,
			memory_context = request.memory_context,
			messages = messages,
		})
	end)
	if not ok then
		local errText = "proposal backend failure: " .. tostring(rawOrErr)
		traceError("propose", traceProvider, traceModel, "backend", errText)
		return nil, nil, errText
	end
	traceRawResponse("propose", traceProvider, traceModel, rawOrErr)

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "proposal")
	end)
	if not decodeOk then
		local errText = tostring(decodedOrErr)
		traceError("propose", traceProvider, traceModel, "decode", errText, {
			raw_response = rawOrErr,
		})
		return nil, nil, errText
	end
	traceDecodedResponse("propose", traceProvider, traceModel, rawOrErr, decodedOrErr)

	_lastExchange = {
		kind = "propose",
		provider = providerName,
		model = traceModel,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	local templateState, templateErr = MinimalProposer.initial(request)
	if not templateState then
		local errText = "invalid proposal template: " .. tostring(templateErr)
		traceError("propose", traceProvider, traceModel, "template_validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, errText
	end

	local decoded = decodedOrErr
	local candidate = if type(decoded) == "table" and type(decoded.state) == "table" then decoded.state else decoded
	local memoryNote, memoryErr = validateMemoryNote(
		if type(decoded) == "table" then decoded.memory_note else nil,
		"proposal",
		"proposal",
		string.format("request:%s", request.request_id)
	)
	if memoryErr ~= nil then
		traceError("propose", traceProvider, traceModel, "validation", memoryErr, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, memoryErr
	end
	if type(candidate) ~= "table" then
		local errText = "invalid proposal: sector state must be a table"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, errText
	end
	if candidate.sector_id ~= nil and candidate.sector_id ~= request.parsed.sector_id then
		local errText = "invalid proposal: sector_id mismatch"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, errText
	end
	if request.parsed.request_kind == "Mechanic"
		and candidate.mechanic ~= nil
		and candidate.mechanic ~= request.parsed.mechanic then
		local errText = "invalid proposal: mechanic mismatch"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, errText
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
		local errText = "invalid proposal: " .. tostring(err)
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
			normalized_state = state,
		})
		return nil, nil, errText
	end
	if request.parsed.request_kind == "Pad" then
		local side = request.parsed.pad_side
		local value = request.parsed.pad_value
		if side == nil or value == nil then
			local errText = "invalid proposal: pad request missing target"
			traceError("propose", traceProvider, traceModel, "validation", errText, {
				decoded_response = decodedOrErr,
			})
			return nil, nil, errText
		end
		if state.pads[side] ~= value then
			local errText = "invalid proposal: pad target mismatch"
			traceError("propose", traceProvider, traceModel, "validation", errText, {
				decoded_response = decodedOrErr,
				normalized_state = state,
			})
			return nil, nil, errText
		end
	end

	return state, memoryNote, nil
end

function LLMAdapter.challengeUp(
	request: Request,
	baselineState: SectorState,
	baselineResult,
	designIntent: DesignIntent?,
	challengeContext: ChallengeUpContext
): (SectorState?, MemoryEntry?, string?)
	local provider, providerName, traceProvider, traceModel = activeProvider()
	local systemPrompt = PromptBuilder.systemPrompt()
	local sharedIntent = designIntent or request.design_intent
	local messages = PromptBuilder.challengeUpMessages(request, challengeContext, sharedIntent)
	local userPrompt = messages[2] and messages[2].content or ""

	tracePrompt("propose", traceProvider, traceModel, {
		system_prompt = systemPrompt,
		user_prompt = userPrompt,
		request = request,
		design_intent = sharedIntent,
		memory_context = request.memory_context,
		challenge_up = challengeContext,
		messages = messages,
	})

	local ok, rawOrErr = pcall(function()
		return provider.propose({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			request = request,
			design_intent = sharedIntent,
			memory_context = request.memory_context,
			challenge_up = challengeContext,
			messages = messages,
		})
	end)
	if not ok then
		local errText = "challenge-up backend failure: " .. tostring(rawOrErr)
		traceError("propose", traceProvider, traceModel, "backend", errText)
		return nil, nil, errText
	end
	traceRawResponse("propose", traceProvider, traceModel, rawOrErr)

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "challenge-up proposal")
	end)
	if not decodeOk then
		local errText = tostring(decodedOrErr)
		traceError("propose", traceProvider, traceModel, "decode", errText, {
			raw_response = rawOrErr,
			challenge_up = challengeContext,
		})
		return nil, nil, errText
	end
	traceDecodedResponse("propose", traceProvider, traceModel, rawOrErr, decodedOrErr)

	_lastExchange = {
		kind = "propose",
		provider = providerName,
		model = traceModel,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	local templateState = cloneSectorState(baselineState)
	local decoded = decodedOrErr
	local candidate = if type(decoded) == "table" and type(decoded.state) == "table" then decoded.state else decoded
	local memoryNote, memoryErr = validateMemoryNote(
		if type(decoded) == "table" then decoded.memory_note else nil,
		"proposal",
		"proposal",
		string.format("challenge:%s", request.request_id)
	)
	if memoryErr ~= nil then
		traceError("propose", traceProvider, traceModel, "validation", memoryErr, {
			decoded_response = decodedOrErr,
			challenge_up = challengeContext,
		})
		return nil, nil, memoryErr
	end
	if type(candidate) ~= "table" then
		local errText = "invalid challenge-up proposal: sector state must be a table"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
			challenge_up = challengeContext,
		})
		return nil, nil, errText
	end
	if candidate.sector_id ~= nil and candidate.sector_id ~= baselineState.sector_id then
		local errText = "invalid challenge-up proposal: sector_id mismatch"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
			challenge_up = challengeContext,
		})
		return nil, nil, errText
	end
	if candidate.mechanic ~= nil and candidate.mechanic ~= baselineState.mechanic then
		local errText = "invalid challenge-up proposal: mechanic mismatch"
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
			challenge_up = challengeContext,
		})
		return nil, nil, errText
	end

	local state = mergeRepairState(templateState, candidate)
	state = normalizeChallengeUpProposalForRequest(request, state)
	local valid, err = ActionValidator.validateSectorState(state)
	if not valid then
		local errText = "invalid challenge-up proposal: " .. tostring(err)
		traceError("propose", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
			normalized_state = state,
			challenge_up = challengeContext,
		})
		return nil, nil, errText
	end

	return state, memoryNote, nil
end

-- ── repair ───────────────────────────────────────────────────────────────────

-- Returns (AgentAction?, SectorState?, explanation?, MemoryEntry?, error?)
--   heuristic path: (action, nil, explanation, memoryNote?, nil)
--   LLM full-state path: (nil, newSectorState, explanation, memoryNote?, nil)
--   error: (nil, nil, nil, nil, errorString)
function LLMAdapter.repair(packet: FailurePacket, history: { AttemptRecord }?, designIntent: DesignIntent?): (AgentAction?, SectorState?, string?, MemoryEntry?, string?)
	local provider, providerName, traceProvider, traceModel = activeProvider()

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
	local sharedIntent = designIntent or packet.design_intent or packet.request.design_intent
	local messages = PromptBuilder.repairMessages(packet.request, cappedHistory, packet, sharedIntent)

	tracePrompt("repair", traceProvider, traceModel, {
		system_prompt = systemPrompt,
		user_prompt = userPrompt,
		packet = packet,
		history = cappedHistory,
		design_intent = sharedIntent,
		memory_context = packet.memory_context,
		messages = messages,
	})

	local ok, rawOrErr = pcall(function()
		return provider.repair({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			packet = packet,
			history = cappedHistory,
			design_intent = sharedIntent,
			memory_context = packet.memory_context,
			messages = messages,
		})
	end)
	if not ok then
		local errText = "repair backend failure: " .. tostring(rawOrErr)
		traceError("repair", traceProvider, traceModel, "backend", errText)
		return nil, nil, nil, nil, errText
	end
	traceRawResponse("repair", traceProvider, traceModel, rawOrErr)

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "repair")
	end)
	if not decodeOk then
		local errText = tostring(decodedOrErr)
		traceError("repair", traceProvider, traceModel, "decode", errText, {
			raw_response = rawOrErr,
		})
		return nil, nil, nil, nil, errText
	end
	traceDecodedResponse("repair", traceProvider, traceModel, rawOrErr, decodedOrErr)

	_lastExchange = {
		kind = "repair",
		provider = providerName,
		model = traceModel,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	-- Detect LLM full-state path: response has "newState" key
	local decoded = decodedOrErr
	local memoryNote, memoryErr = validateMemoryNote(
		if type(decoded) == "table" then decoded.memory_note else nil,
		"repair",
		"repair",
		string.format("repair:%s:%d", packet.request.request_id, packet.attempt_index)
	)
	if memoryErr ~= nil then
		traceError("repair", traceProvider, traceModel, "validation", memoryErr, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, nil, nil, memoryErr
	end
	if type(decoded) == "table" and decoded.newState ~= nil then
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
			local errText = "invalid LLM repair state: " .. tostring(verr)
			traceError("repair", traceProvider, traceModel, "validation", errText, {
				decoded_response = decodedOrErr,
				normalized_state = newState,
			})
			return nil, nil, nil, nil, errText
		end
		if newState.sector_id ~= packet.sector_state.sector_id then
			local errText = "LLM repair: sector_id mismatch"
			traceError("repair", traceProvider, traceModel, "validation", errText, {
				decoded_response = decodedOrErr,
				normalized_state = newState,
			})
			return nil, nil, nil, nil, errText
		end
		if newState.mechanic ~= packet.sector_state.mechanic then
			local errText = "LLM repair: mechanic mismatch"
			traceError("repair", traceProvider, traceModel, "validation", errText, {
				decoded_response = decodedOrErr,
				normalized_state = newState,
			})
			return nil, nil, nil, nil, errText
		end
		return nil, newState, explanation, memoryNote, nil
	end

	-- Heuristic / injected delta-action path
	if type(decoded) ~= "table" then
		local errText = "invalid repair: response must be an object"
		traceError("repair", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, nil, nil, errText
	end

	local action = decoded.action
	local explanation = shortenExplanation(decoded.explanation)
	if action == nil then
		local errText = "invalid repair: missing action"
		traceError("repair", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, nil, nil, errText
	end
	if explanation == nil then
		local errText = "invalid repair: explanation must be short non-empty text"
		traceError("repair", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, nil, nil, errText
	end

	local valid, err = ActionValidator.validateAction(action, packet.sector_state.mechanic)
	if not valid then
		local errText = "invalid repair: " .. tostring(err)
		traceError("repair", traceProvider, traceModel, "validation", errText, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, nil, nil, errText
	end

	return action, nil, explanation, memoryNote, nil
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
		local rationale = coerceShortText(decoded.rationale, 120, "track balanced enough to begin loop")
		return { action = "begin_loop", rationale = rationale }, nil
	end
	if not EDITABLE_SECTORS[decoded.sector_id] then
		return nil, "invalid orchestrate response: sector_id must be an editable sector"
	end
	if decoded.mechanic ~= "RampJump" and decoded.mechanic ~= "Chicane" and decoded.mechanic ~= "CrestDip" then
		return nil, "invalid orchestrate response: mechanic missing or unsupported"
	end
	local rationale = coerceShortText(decoded.rationale, 120, "advance track objective")
	local desiredFeel = coerceShortText(decoded.desired_feel, 120, "memorable but recoverable obstacle")
	local targetScoreBand, scoreErr = validateChoice(decoded, "target_score_band", SCORE_BANDS)
	if not targetScoreBand then
		return nil, scoreErr
	end
	local targetBudgetTolerance, budgetErr = validateChoice(decoded, "target_budget_tolerance", BUDGET_TOLERANCES)
	if not targetBudgetTolerance then
		return nil, budgetErr
	end
	local targetReliability, reliabilityErr = validateChoice(decoded, "target_reliability", RELIABILITY_LEVELS)
	if not targetReliability then
		return nil, reliabilityErr
	end
	local spectaclePriority, spectacleErr = validateChoice(decoded, "spectacle_priority", PRIORITY_LEVELS)
	if not spectaclePriority then
		return nil, spectacleErr
	end
	local noveltyPriority, noveltyErr = validateChoice(decoded, "novelty_priority", PRIORITY_LEVELS)
	if not noveltyPriority then
		return nil, noveltyErr
	end
	local replacementIntent, replacementErr = validateChoice(decoded, "replacement_intent", REPLACEMENT_INTENTS)
	if not replacementIntent then
		return nil, replacementErr
	end
	local constraints, constraintsErr = normalizeStringArray(decoded.constraints, "constraints")
	if not constraints then
		return nil, "invalid orchestrate response: " .. tostring(constraintsErr)
	end
	return {
		sector_id = decoded.sector_id,
		mechanic = decoded.mechanic,
		params_hint = coerceShortText(decoded.params_hint, 96, "") or "",
		rationale = rationale,
		target_score_band = targetScoreBand,
		target_budget_tolerance = targetBudgetTolerance,
		target_reliability = targetReliability,
		spectacle_priority = spectaclePriority,
		novelty_priority = noveltyPriority,
		replacement_intent = replacementIntent,
		desired_feel = desiredFeel,
		constraints = constraints,
	}, nil
end

function LLMAdapter.orchestrate(context: OrchestratorContext): (OrchestratorDecision?, MemoryEntry?, string?)
	local provider, providerName, traceProvider, traceModel = activeProvider()
	if type(provider.orchestrate) ~= "function" then
		local errText = "orchestrate backend missing"
		traceError("orchestrate", traceProvider, traceModel, "backend", errText)
		return nil, nil, errText
	end

	local messages = OrchestratorPromptBuilder.messages(context)
	tracePrompt("orchestrate", traceProvider, traceModel, {
		context = context,
		memory = context.memory,
		messages = messages,
	})

	local ok, rawOrErr = pcall(function()
		return provider.orchestrate({
			context = context,
			messages = messages,
		})
	end)
	if not ok then
		local errText = "orchestrate backend failure: " .. tostring(rawOrErr)
		traceError("orchestrate", traceProvider, traceModel, "backend", errText)
		return nil, nil, errText
	end
	traceRawResponse("orchestrate", traceProvider, traceModel, rawOrErr)

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "orchestrate")
	end)
	if not decodeOk then
		local errText = tostring(decodedOrErr)
		traceError("orchestrate", traceProvider, traceModel, "decode", errText, {
			raw_response = rawOrErr,
		})
		return nil, nil, errText
	end
	traceDecodedResponse("orchestrate", traceProvider, traceModel, rawOrErr, decodedOrErr)

	_lastExchange = {
		kind = "orchestrate",
		provider = providerName,
		model = traceModel,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	local decision, err = validateOrchestratorDecision(decodedOrErr)
	if not decision then
		traceError("orchestrate", traceProvider, traceModel, "validation", tostring(err), {
			decoded_response = decodedOrErr,
		})
		return nil, nil, err
	end
	local memoryNote, memoryErr = validateMemoryNote(
		if type(decodedOrErr) == "table" then decodedOrErr.memory_note else nil,
		"orchestrator",
		"orchestrator",
		string.format("decision:%d", (context.attempt_budget and context.attempt_budget.used or 0) + 1)
	)
	if memoryErr ~= nil then
		traceError("orchestrate", traceProvider, traceModel, "validation", memoryErr, {
			decoded_response = decodedOrErr,
		})
		return nil, nil, memoryErr
	end
	return decision, memoryNote, nil
end

return LLMAdapter
