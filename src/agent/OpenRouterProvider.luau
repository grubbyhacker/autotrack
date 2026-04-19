-- OpenRouterProvider.luau
-- Calls the OpenRouter API (OpenAI-compatible chat completions endpoint).
-- Server-only: uses HttpService:GetSecret for the API key.
--
-- propose(payload) and repair(payload) match the LLMAdapter provider interface.
-- repair expects payload.history: { AttemptRecord } in addition to payload.packet.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local PromptBuilder = require(script.Parent.PromptBuilder)
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))

type Request = Types.Request
type FailurePacket = Types.FailurePacket
type AttemptRecord = Types.AttemptRecord
type SectorState = Types.SectorState

local OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

local function encode(v): string
	return HttpService:JSONEncode(v)
end

-- Extract the first balanced {...} block from a string.
-- Handles models that wrap JSON in prose or markdown code fences.
local function extractJson(content: string): string?
	local start = string.find(content, "{")
	if not start then return nil end
	local depth = 0
	local closing = nil
	for i = start, #content do
		local ch = string.sub(content, i, i)
		if ch == "{" then
			depth += 1
		elseif ch == "}" then
			depth -= 1
			if depth == 0 then
				closing = i
				break
			end
		end
	end
	if closing then
		return string.sub(content, start, closing)
	end
	return nil
end

local function callAPI(modelId: string, messages: { { role: string, content: string } }): string
	local apiKey = HttpService:GetSecret("OPENROUTER_API_KEY")
	local body = encode({
		model = modelId,
		messages = messages,
		temperature = 0.7,
		max_tokens = 512,
	})

	local response = HttpService:RequestAsync({
		Url = OPENROUTER_URL,
		Method = "POST",
		Headers = {
			["Authorization"] = apiKey:AddPrefix("Bearer "),
			["Content-Type"] = "application/json",
			["HTTP-Referer"] = "https://autotrack.dev",
			["X-Title"] = "AutoTrack",
		},
		Body = body,
	})

	if not response.Success then
		error(string.format("OpenRouter HTTP %d: %s", response.StatusCode, tostring(response.Body):sub(1, 200)))
	end

	local parsed = HttpService:JSONDecode(response.Body)
	if not parsed.choices or #parsed.choices == 0 then
		error("OpenRouter returned no choices")
	end

	local content = parsed.choices[1].message and parsed.choices[1].message.content
	if type(content) ~= "string" or content == "" then
		error("OpenRouter choice has empty content")
	end

	local json = extractJson(content)
	if not json then
		error("OpenRouter response contained no JSON object: " .. content:sub(1, 200))
	end
	return json
end

local CRESTDIP_MIN_CURVATURE = 0.006

local function normalizeState(state: SectorState, integerLevers: boolean): SectorState
	-- Clamp and optionally round lever values to legal bounds
	if state.params and state.mechanic then
		local bounds = LevelMappings.LEVER_BOUNDS[state.mechanic]
		for key, value in pairs(state.params) do
			if type(value) == "number" then
				if bounds and bounds[key] then
					value = math.clamp(value, bounds[key].min, bounds[key].max)
				end
				state.params[key] = integerLevers and math.round(value) or value
			end
		end
		-- CrestDip: enforce h/L² >= MIN_CURVATURE by bumping height if needed
		if state.mechanic == "CrestDip" then
			local h = state.params.height_or_depth or 0
			local L = state.params.sector_length or 1
			local minH = math.ceil(CRESTDIP_MIN_CURVATURE * L * L)
			if h < minH then
				local hBound = LevelMappings.LEVER_BOUNDS.CrestDip.height_or_depth
				state.params.height_or_depth = math.min(minH, hBound.max)
			end
		end
	end
	-- Normalise pad values: unknown strings become "None"
	if state.pads then
		if not PadValueUtils.isValid(state.pads.ingress) then state.pads.ingress = "None" end
		if not PadValueUtils.isValid(state.pads.egress) then state.pads.egress = "None" end
	end
	return state
end

-- Build a short repair context description for attempt N.
local function repairContext(record: AttemptRecord): string
	local result = record.result
	local failureType = result.failure and result.failure.type or "unknown"
	local failureDetail = result.failure and result.failure.detail or ""
	local hints = record.hints or {}
	return string.format(
		"Attempt %d result: failure_type=%s detail=%s hints=%s metrics=%s",
		record.attempt_index,
		failureType,
		failureDetail ~= "" and failureDetail or "-",
		#hints > 0 and table.concat(hints, "|") or "-",
		encode({
			air_distance = result.metrics.air_distance,
			lateral_error = result.metrics.lateral_error,
			vertical_displacement = result.metrics.vertical_displacement,
			slowdown_ratio = result.metrics.slowdown_ratio,
			target_progress = result.metrics.target_progress,
			target_left_offset = result.metrics.target_left_offset,
			target_right_offset = result.metrics.target_right_offset,
		})
	)
end

function OpenRouterProvider(modelId: string)
	local cfg = LLMConfig.get()

	local provider = {}

	function provider.propose(payload)
		local messages = PromptBuilder.proposeMessages(payload.request)
		local json = callAPI(modelId, messages)
		local state = HttpService:JSONDecode(json)
		state = normalizeState(state, cfg.integerLevers)
		return encode(state)
	end

	function provider.repair(payload)
		local history = payload.history or {}
		local packet = payload.packet
		local messages = PromptBuilder.repairMessages(packet.request, history, packet)
		local json = callAPI(modelId, messages)
		local state = HttpService:JSONDecode(json)
		state = normalizeState(state, cfg.integerLevers)
		-- Derive a short explanation from the state diff vs the previous attempt
		local explanation = string.format(
			"LLM revised state (attempt %d)",
			packet.attempt_index + 1
		)
		return encode({ newState = state, explanation = explanation })
	end

	return provider
end

return OpenRouterProvider
