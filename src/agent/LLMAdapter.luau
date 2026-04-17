-- LLMAdapter.luau
-- Narrow boundary between the CI orchestrator and the language model.
-- prd_plan.md §17 Phase 7
--
-- All LLM calls go through here.  The adapter is swappable:
-- swap out the implementation (Claude, Codex, mock) without touching
-- orchestrator logic.
--
-- Initial proposal:  receives a Request, returns a SectorState
-- Repair step:       receives a FailurePacket, returns an AgentAction
--
-- Both calls must validate structured output before returning.
-- Fail fast on invalid agent output — do not silently accept malformed data.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local PromptBuilder = require(script.Parent.PromptBuilder)
local ActionValidator = require(script.Parent.ActionValidator)
local MinimalProposer = require(script.Parent.Parent.Orchestrator.MinimalProposer)

type Request = Types.Request
type SectorState = Types.SectorState
type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket

local LLMAdapter = {}

local _providerName = "mock"
local _lastExchange = nil

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
	if type(explanation) ~= "string" then
		return nil
	end
	local trimmed = string.match(explanation, "^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return nil
	end
	if #trimmed > 120 then
		return nil
	end
	return trimmed
end

local function mockProvider()
	return {
		propose = function(payload)
			local state, err = MinimalProposer.initial(payload.request)
			if not state then
				error(err)
			end
			return HttpService:JSONEncode(state)
		end,
		repair = function(payload)
			local action, explanation, err = MinimalProposer.repair(payload.packet)
			if not action then
				error(err)
			end
			return HttpService:JSONEncode({
				action = action,
				explanation = explanation,
			})
		end,
	}
end

local _provider = mockProvider()

function LLMAdapter.setProvider(name: string, provider)
	assert(type(name) == "string" and name ~= "", "LLMAdapter.setProvider: provider name is required")
	assert(type(provider) == "table", "LLMAdapter.setProvider: provider table is required")
	assert(type(provider.propose) == "function", "LLMAdapter.setProvider: provider.propose missing")
	assert(type(provider.repair) == "function", "LLMAdapter.setProvider: provider.repair missing")

	_providerName = name
	_provider = provider
end

function LLMAdapter.useMockProvider()
	_providerName = "mock"
	_provider = mockProvider()
end

function LLMAdapter.getProviderName(): string
	return _providerName
end

function LLMAdapter.getLastExchange()
	return _lastExchange
end

-- Request an initial SectorState proposal from the agent.
-- Returns (SectorState, nil) on success or (nil, errorString) on failure.
function LLMAdapter.propose(request: Request): (SectorState?, string?)
	local systemPrompt = PromptBuilder.systemPrompt()
	local userPrompt = PromptBuilder.initialProposal(request)

	local ok, rawOrErr = pcall(function()
		return _provider.propose({
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
		provider = _providerName,
		system_prompt = systemPrompt,
		user_prompt = userPrompt,
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
	if state.mechanic ~= request.parsed.mechanic then
		return nil, "invalid proposal: mechanic mismatch"
	end

	return state, nil
end

-- Request a single repair AgentAction from the agent.
-- Returns (AgentAction, explanation) on success or (nil, errorString) on failure.
function LLMAdapter.repair(packet: FailurePacket): (AgentAction?, string?, string?)
	local systemPrompt = PromptBuilder.systemPrompt()
	local userPrompt = PromptBuilder.repairStep(packet)

	local ok, rawOrErr = pcall(function()
		return _provider.repair({
			system_prompt = systemPrompt,
			user_prompt = userPrompt,
			packet = packet,
		})
	end)
	if not ok then
		return nil, nil, "repair backend failure: " .. tostring(rawOrErr)
	end

	local decodeOk, decodedOrErr = pcall(function()
		return decodeResponse(rawOrErr, "repair")
	end)
	if not decodeOk then
		return nil, nil, tostring(decodedOrErr)
	end

	_lastExchange = {
		kind = "repair",
		provider = _providerName,
		system_prompt = systemPrompt,
		user_prompt = userPrompt,
		raw_response = rawOrErr,
		decoded_response = decodedOrErr,
	}

	local action = decodedOrErr.action
	local explanation = shortenExplanation(decodedOrErr.explanation)
	if action == nil then
		return nil, nil, "invalid repair: missing action"
	end
	if explanation == nil then
		return nil, nil, "invalid repair: explanation must be short non-empty text"
	end

	local valid, err = ActionValidator.validateAction(action, packet.sector_state.mechanic)
	if not valid then
		return nil, nil, "invalid repair: " .. tostring(err)
	end

	return action, explanation, nil
end

return LLMAdapter
