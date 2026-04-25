--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local TestSession = require(script.Parent.TestSession)
local T = require(script.Parent.TestUtils)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)

local TestPhase17 = {}

type JsonObject = Types.JsonObject

function TestPhase17.runExport()
	local exportPayload: JsonObject? = LLMTraceJournal.exportLatestRun()
	if exportPayload == nil then
		T.fail("llm_trace_export_available", "no traced LLM run available")
		return
	end

	TestSession.setPayload({
		llm_trace_export = exportPayload,
	})

	local eventCount = if type(exportPayload.event_count) == "number" then exportPayload.event_count else 0
	local line = string.format(
		"[TRACE EXPORT] run=%s events=%d snapshot_payload=llm_trace_export",
		tostring(exportPayload.run_id),
		eventCount
	)
	print(line)
	TestSession.appendLine(line)
	T.pass("llm_trace_export_available")
end

return TestPhase17
