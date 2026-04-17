-- TestRunner.server.luau
-- Triggered by a client-fired RemoteEvent (execute_luau runs client-side).
-- Usage from MCP execute_luau:
--   game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase1")
-- Results printed as [TEST PASS/FAIL: name] lines, readable via get_console_output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestDispatcher = require(script.Parent.TestDispatcher)

local testEvent = Instance.new("RemoteEvent")
testEvent.Name = "AutoTrack_TestCmd"
testEvent.Parent = ReplicatedStorage

testEvent.OnServerEvent:Connect(function(_player, cmd)
	TestDispatcher.runSuite(cmd)
end)

print("[TEST] TestRunner ready")
