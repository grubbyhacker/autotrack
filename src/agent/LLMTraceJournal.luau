local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type LLMTraceEvent = Types.LLMTraceEvent
type LLMTraceRun = Types.LLMTraceRun

local LLMTraceJournal = {}

local RECENT_RUN_CAPACITY = 3

local _activeRun: LLMTraceRun? = nil
local _recentRuns: { LLMTraceRun } = {}

local function nowMs(): number
	return DateTime.now().UnixTimestampMillis
end

local function isArray(source): boolean
	if type(source) ~= "table" then
		return false
	end
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

local function sanitize(value, seen)
	local valueType = typeof(value)
	if value == nil or valueType == "boolean" or valueType == "number" or valueType == "string" then
		return value
	end

	if valueType == "table" then
		seen = seen or {}
		if seen[value] then
			return "<cycle>"
		end
		seen[value] = true

		local result
		if isArray(value) then
			result = table.create(#value)
			for index, item in ipairs(value) do
				result[index] = sanitize(item, seen)
			end
		else
			result = {}
			for key, item in pairs(value) do
				result[tostring(key)] = sanitize(item, seen)
			end
		end

		seen[value] = nil
		return result
	end

	if valueType == "Vector3" then
		return {
			__type = "Vector3",
			x = value.X,
			y = value.Y,
			z = value.Z,
		}
	end

	if valueType == "Vector2" then
		return {
			__type = "Vector2",
			x = value.X,
			y = value.Y,
		}
	end

	if valueType == "CFrame" then
		local components = { value:GetComponents() }
		return {
			__type = "CFrame",
			components = sanitize(components, seen),
		}
	end

	if valueType == "Color3" then
		return {
			__type = "Color3",
			r = value.R,
			g = value.G,
			b = value.B,
		}
	end

	if valueType == "EnumItem" then
		return tostring(value)
	end

	if valueType == "Instance" then
		return value:GetFullName()
	end

	return tostring(value)
end

local function exportRunTable(run: LLMTraceRun?): { [string]: any }?
	if run == nil then
		return nil
	end

	local export = {
		run_id = run.run_id,
		started_at_ms = run.started_at_ms,
		finished_at_ms = run.finished_at_ms,
		event_count = run.event_count,
		owner = run.owner,
		mode = run.mode,
		job_id = run.job_id,
		request_id = run.request_id,
		meta = sanitize(run.meta),
		summary = sanitize(run.summary),
		events = {},
	}

	for index, event in ipairs(run.events) do
		export.events[index] = {
			run_id = event.run_id,
			seq = event.seq,
			timestamp_ms = event.timestamp_ms,
			role = event.role,
			direction = event.direction,
			provider = event.provider,
			model = event.model,
			kind = event.kind,
			payload = sanitize(event.payload),
		}
	end

	return export
end

local function buildRun(meta): LLMTraceRun
	local safeMeta = sanitize(meta or {})
	local owner = if type(safeMeta) == "table" then safeMeta.owner else nil
	local mode = if type(safeMeta) == "table" then safeMeta.mode else nil
	local prefix = if type(owner) == "string" and owner ~= "" then owner else "llmtrace"

	return {
		run_id = string.format("%s-%s", prefix, HttpService:GenerateGUID(false)),
		started_at_ms = nowMs(),
		finished_at_ms = nil,
		event_count = 0,
		owner = if type(owner) == "string" then owner else nil,
		mode = if type(mode) == "string" then mode else nil,
		job_id = if type(safeMeta) == "table" and type(safeMeta.job_id) == "string" then safeMeta.job_id else nil,
		request_id = if type(safeMeta) == "table" and type(safeMeta.request_id) == "string"
			then safeMeta.request_id
			else nil,
		meta = if type(safeMeta) == "table" then safeMeta else nil,
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

local function ensureActiveRun(eventLike): LLMTraceRun
	if _activeRun == nil then
		local inferredRole = if type(eventLike) == "table" and type(eventLike.role) == "string"
			then eventLike.role
			else "proposal"
		_activeRun = buildRun({
			owner = "implicit",
			mode = "implicit",
			reason = "auto_begin_from_append",
			first_role = inferredRole,
		})
	end
	return _activeRun
end

function LLMTraceJournal.beginRun(meta): string
	if _activeRun ~= nil then
		LLMTraceJournal.finishRun({
			reason = "superseded",
		})
	end

	_activeRun = buildRun(meta)
	return _activeRun.run_id
end

function LLMTraceJournal.append(eventLike): LLMTraceEvent
	assert(type(eventLike) == "table", "LLMTraceJournal.append: eventLike table required")

	local run = ensureActiveRun(eventLike)
	local event: LLMTraceEvent = {
		run_id = run.run_id,
		seq = run.event_count + 1,
		timestamp_ms = nowMs(),
		role = eventLike.role,
		direction = eventLike.direction,
		provider = eventLike.provider,
		model = eventLike.model,
		kind = eventLike.kind,
		payload = sanitize(eventLike.payload or {}),
	}

	table.insert(run.events, event)
	run.event_count = #run.events
	return event
end

function LLMTraceJournal.finishRun(summary)
	if _activeRun == nil then
		return nil
	end

	_activeRun.finished_at_ms = nowMs()
	_activeRun.summary = sanitize(summary or {})

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

function LLMTraceJournal.exportRun(runId: string?): { [string]: any }?
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

function LLMTraceJournal.exportLatestRun(): { [string]: any }?
	return LLMTraceJournal.exportRun(nil)
end

function LLMTraceJournal.clearForTests()
	_activeRun = nil
	table.clear(_recentRuns)
end

function LLMTraceJournal.getRecentRunCapacity(): number
	return RECENT_RUN_CAPACITY
end

return LLMTraceJournal
