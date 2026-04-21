-- TestRunner.server.luau
-- Triggered by a client-fired RemoteEvent (execute_luau runs client-side).
-- Usage from MCP execute_luau:
--   game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase1")
-- Results printed as [TEST PASS/FAIL: name] lines, readable via get_console_output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestDispatcher = require(script.Parent.TestDispatcher)

local BRIDGE_EXPORT_REQUEST_ATTR = "AutoTrack_BridgeExportLLMTraceRequestId"
local BRIDGE_EXPORT_RESULT_ATTR = "AutoTrack_BridgeExportLLMTraceResultId"
local BRIDGE_EXPORT_ERROR_ATTR = "AutoTrack_BridgeExportLLMTraceError"

local testEvent = Instance.new("RemoteEvent")
testEvent.Name = "AutoTrack_TestCmd"
testEvent.Parent = ReplicatedStorage

testEvent.OnServerEvent:Connect(function(_player, cmd)
	TestDispatcher.runSuite(cmd)
end)

local lastBridgeExportRequestId = ""

workspace:GetAttributeChangedSignal(BRIDGE_EXPORT_REQUEST_ATTR):Connect(function()
	local requestId = workspace:GetAttribute(BRIDGE_EXPORT_REQUEST_ATTR)
	if type(requestId) ~= "string" or requestId == "" or requestId == lastBridgeExportRequestId then
		return
	end

	lastBridgeExportRequestId = requestId
	task.spawn(function()
		local snapshot = TestDispatcher.runSuite("llm_trace_export")
		local errText = ""
		if snapshot.status ~= "passed" then
			errText = tostring(snapshot.message or "llm trace export failed")
		end
		workspace:SetAttribute(BRIDGE_EXPORT_ERROR_ATTR, errText)
		workspace:SetAttribute(BRIDGE_EXPORT_RESULT_ATTR, requestId)
	end)
end)

print("[TEST] TestRunner ready")
