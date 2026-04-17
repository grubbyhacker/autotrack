-- TestRunner.server.luau
-- Triggered by a client-fired RemoteEvent (execute_luau runs client-side).
-- Usage from MCP execute_luau:
--   game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase1")
-- Results printed as [TEST PASS/FAIL: name] lines, readable via get_console_output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local testEvent = Instance.new("RemoteEvent")
testEvent.Name = "AutoTrack_TestCmd"
testEvent.Parent = ReplicatedStorage

testEvent.OnServerEvent:Connect(function(_player, cmd)
	print("[TEST] Running suite: " .. tostring(cmd))

	local ok, err = pcall(function()
		if cmd == "phase1" then
			require(script.Parent.TestPhase1).run()
		else
			print("[TEST FAIL: unknown_suite] " .. tostring(cmd))
		end
	end)

	if not ok then
		print("[TEST ERROR] " .. tostring(err))
	end

	print("[TEST] Suite done: " .. tostring(cmd))
end)

print("[TEST] TestRunner ready")
