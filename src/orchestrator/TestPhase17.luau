local TestSession = require(script.Parent.TestSession)
local T = require(script.Parent.TestUtils)
local LLMTraceJournal = require(script.Parent.Parent.Agent.LLMTraceJournal)

local TestPhase17 = {}

function TestPhase17.runExport()
	local export = LLMTraceJournal.exportLatestRun()
	if export == nil then
		T.fail("llm_trace_export_available", "no traced LLM run available")
		return
	end

	TestSession.setPayload({
		llm_trace_export = export,
	})

	local line = string.format(
		"[TRACE EXPORT] run=%s events=%d snapshot_payload=llm_trace_export",
		tostring(export.run_id),
		tonumber(export.event_count) or 0
	)
	print(line)
	TestSession.appendLine(line)
	T.pass("llm_trace_export_available")
end

return TestPhase17
