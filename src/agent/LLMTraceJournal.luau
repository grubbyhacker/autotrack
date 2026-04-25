--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type JsonArray = Types.JsonArray
type JsonObject = Types.JsonObject
type JsonValue = Types.JsonValue
type LLMTraceDirection = Types.LLMTraceDirection
type LLMTraceEvent = Types.LLMTraceEvent
type LLMTraceKind = Types.LLMTraceKind
type LLMTraceRole = Types.LLMTraceRole
type LLMTraceRun = Types.LLMTraceRun

local LLMTraceJournal = {}

local RECENT_RUN_CAPACITY = 3

local _activeRun: LLMTraceRun? = nil
local _recentRuns: { LLMTraceRun } = {}

type SeenSet = { [unknown]: boolean }
type TraceEventInput = { [string]: unknown }

local TRACE_ROLES: { [string]: LLMTraceRole } = {
	orchestrator = "orchestrator",
	repair = "repair",
	proposal = "proposal",
}

local TRACE_DIRECTIONS: { [string]: LLMTraceDirection } = {
	prompt = "prompt",
	response = "response",
	error = "error",
}

local TRACE_KINDS: { [string]: LLMTraceKind } = {
	propose = "propose",
	repair = "repair",
	orchestrate = "orchestrate",
}

local function nowMs(): number
	return DateTime.now().UnixTimestampMillis
end

local function isArray(source: { [unknown]: unknown }): boolean
	local count = 0
	for key in pairs(source) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return false
		end
		count += 1
	end
	for index = 1, count do
		if source[index] == nil then
			return false
		end
	end
	return true
end

local function sanitize(value: unknown, seen: SeenSet?): JsonValue
	local valueType = typeof(value)
	if value == nil then
		return nil
	end
	if valueType == "boolean" then
		return value :: boolean
	end
	if valueType == "number" then
		return value :: number
	end
	if valueType == "string" then
		return value :: string
	end

	if valueType == "table" then
		local tableValue = value :: { [unknown]: unknown }
		local activeSeen: SeenSet = seen or {}
		if activeSeen[tableValue] then
			return "<cycle>"
		end
		activeSeen[tableValue] = true

		local sanitized: JsonValue
		if isArray(tableValue) then
			local arrayValue = tableValue :: { unknown }
			local result: JsonArray = table.create(#arrayValue)
			for index, item in ipairs(arrayValue) do
				result[index] = sanitize(item, activeSeen)
			end
			sanitized = result
		else
			local result: JsonObject = {}
			for key, item in pairs(tableValue) do
				result[tostring(key)] = sanitize(item, activeSeen)
			end
			sanitized = result
		end

		activeSeen[tableValue] = nil
		return sanitized
	end

	if valueType == "Vector3" then
		local vector = value :: Vector3
		return {
			__type = "Vector3",
			x = vector.X,
			y = vector.Y,
			z = vector.Z,
		}
	end

	if valueType == "Vector2" then
		local vector = value :: Vector2
		return {
			__type = "Vector2",
			x = vector.X,
			y = vector.Y,
		}
	end

	if valueType == "CFrame" then
		local cframe = value :: CFrame
		local components = { cframe:GetComponents() }
		return {
			__type = "CFrame",
			components = sanitize(components, seen),
		}
	end

	if valueType == "Color3" then
		local color = value :: Color3
		return {
			__type = "Color3",
			r = color.R,
			g = color.G,
			b = color.B,
		}
	end

	if valueType == "EnumItem" then
		return tostring(value)
	end

	if valueType == "Instance" then
		local instance = value :: Instance
		return instance:GetFullName()
	end

	return tostring(value)
end

local function sanitizeObject(value: unknown): JsonObject
	local sanitized = sanitize(value)
	if type(sanitized) == "table" then
		return sanitized :: JsonObject
	end
	return {}
end

local function stringField(source: JsonObject, key: string): string?
	local value = source[key]
	if type(value) == "string" then
		return value
	end
	return nil
end

local function traceRole(value: unknown, fallback: LLMTraceRole?): LLMTraceRole
	if type(value) == "string" then
		local role = TRACE_ROLES[value]
		if role ~= nil then
			return role :: LLMTraceRole
		end
	end
	if fallback ~= nil then
		return fallback
	end
	error("LLMTraceJournal: valid role required")
end

local function traceDirection(value: unknown): LLMTraceDirection
	if type(value) == "string" then
		local direction = TRACE_DIRECTIONS[value]
		if direction ~= nil then
			return direction :: LLMTraceDirection
		end
	end
	error("LLMTraceJournal: valid direction required")
end

local function traceKind(value: unknown): LLMTraceKind
	if type(value) == "string" then
		local kind = TRACE_KINDS[value]
		if kind ~= nil then
			return kind :: LLMTraceKind
		end
	end
	error("LLMTraceJournal: valid kind required")
end

local function exportRunTable(run: LLMTraceRun?): JsonObject?
	if run == nil then
		return nil
	end

	local events: JsonArray = {}
	for index, event in ipairs(run.events) do
		events[index] = {
			run_id = event.run_id,
			seq = event.seq,
			timestamp_ms = event.timestamp_ms,
			role = event.role,
			direction = event.direction,
			provider = event.provider,
			model = event.model,
			kind = event.kind,
			payload = sanitizeObject(event.payload),
		}
	end

	local export: JsonObject = {}
	export.run_id = run.run_id
	export.started_at_ms = run.started_at_ms
	export.finished_at_ms = run.finished_at_ms
	export.event_count = run.event_count
	export.owner = run.owner
	export.mode = run.mode
	export.job_id = run.job_id
	export.request_id = run.request_id
	if run.meta ~= nil then
		export.meta = sanitizeObject(run.meta)
	end
	if run.summary ~= nil then
		export.summary = sanitizeObject(run.summary)
	end
	export.events = events
	return export
end

local function buildRun(meta: unknown?): LLMTraceRun
	local safeMeta = sanitizeObject(meta or {})
	local owner = stringField(safeMeta, "owner")
	local mode = stringField(safeMeta, "mode")
	local prefix = if type(owner) == "string" and owner ~= "" then owner else "llmtrace"

	return {
		run_id = string.format("%s-%s", prefix, HttpService:GenerateGUID(false)),
		started_at_ms = nowMs(),
		finished_at_ms = nil,
		event_count = 0,
		owner = if type(owner) == "string" then owner else nil,
		mode = if type(mode) == "string" then mode else nil,
		job_id = stringField(safeMeta, "job_id"),
		request_id = stringField(safeMeta, "request_id"),
		meta = safeMeta,
		summary = nil,
		events = {},
	}
end

local function pushRecent(run: LLMTraceRun)
	table.insert(_recentRuns, 1, run)
	while #_recentRuns > RECENT_RUN_CAPACITY do
		table.remove(_recentRuns)
	end
end

local function ensureActiveRun(eventLike: TraceEventInput): LLMTraceRun
	if _activeRun == nil then
		local inferredRole = traceRole(eventLike.role, "proposal")
		_activeRun = buildRun({
			owner = "implicit",
			mode = "implicit",
			reason = "auto_begin_from_append",
			first_role = inferredRole,
		})
	end
	assert(_activeRun ~= nil, "LLMTraceJournal: active run missing after ensure")
	return _activeRun
end

function LLMTraceJournal.beginRun(meta: unknown?): string
	if _activeRun ~= nil then
		LLMTraceJournal.finishRun({
			reason = "superseded",
		})
	end

	_activeRun = buildRun(meta)
	local run = _activeRun
	assert(run ~= nil, "LLMTraceJournal: beginRun failed to create run")
	return run.run_id
end

function LLMTraceJournal.append(eventLike: TraceEventInput): LLMTraceEvent
	assert(type(eventLike) == "table", "LLMTraceJournal.append: eventLike table required")

	local run = ensureActiveRun(eventLike)
	local event: LLMTraceEvent = {
		run_id = run.run_id,
		seq = run.event_count + 1,
		timestamp_ms = nowMs(),
		role = traceRole(eventLike.role, nil),
		direction = traceDirection(eventLike.direction),
		provider = if type(eventLike.provider) == "string" then eventLike.provider else nil,
		model = if type(eventLike.model) == "string" then eventLike.model else nil,
		kind = traceKind(eventLike.kind),
		payload = sanitizeObject(eventLike.payload or {}),
	}

	table.insert(run.events, event)
	run.event_count = #run.events
	return event
end

function LLMTraceJournal.finishRun(summary: unknown?): string?
	if _activeRun == nil then
		return nil
	end

	_activeRun.finished_at_ms = nowMs()
	_activeRun.summary = sanitizeObject(summary or {})

	local finished = _activeRun
	_activeRun = nil
	pushRecent(finished)
	return finished.run_id
end

function LLMTraceJournal.getActiveRun(): LLMTraceRun?
	return _activeRun
end

function LLMTraceJournal.getRecentRuns(): { LLMTraceRun }
	return _recentRuns
end

function LLMTraceJournal.exportRun(runId: string?): JsonObject?
	if type(runId) == "string" and runId ~= "" then
		if _activeRun ~= nil and _activeRun.run_id == runId then
			return exportRunTable(_activeRun)
		end
		for _, run in ipairs(_recentRuns) do
			if run.run_id == runId then
				return exportRunTable(run)
			end
		end
		return nil
	end

	if _activeRun ~= nil then
		return exportRunTable(_activeRun)
	end
	if #_recentRuns > 0 then
		return exportRunTable(_recentRuns[1])
	end
	return nil
end

function LLMTraceJournal.exportLatestRun(): JsonObject?
	return LLMTraceJournal.exportRun(nil)
end

function LLMTraceJournal.clearForTests(): ()
	_activeRun = nil
	table.clear(_recentRuns)
end

function LLMTraceJournal.getRecentRunCapacity(): number
	return RECENT_RUN_CAPACITY
end

return LLMTraceJournal
