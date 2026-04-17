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
		elseif cmd == "phase2" then
			require(script.Parent.TestPhase2).run()
		elseif cmd == "phase3" then
			require(script.Parent.TestPhase3).run()
		elseif cmd == "phase4" then
			require(script.Parent.TestPhase4).run()
		elseif cmd == "phase4_pads" then
			require(script.Parent.TestPhase4).runPads()
		elseif cmd == "phase4_rampjump" then
			require(script.Parent.TestPhase4).runRampJump()
		elseif cmd == "phase4_crestdip" then
			require(script.Parent.TestPhase4).runCrestDip()
		elseif cmd == "phase4_chicane" then
			require(script.Parent.TestPhase4).runChicane()
		elseif cmd == "phase4_5" then
			require(script.Parent.TestPhase4_5).run()
		elseif cmd == "phase4_5_geometry" then
			require(script.Parent.TestPhase4_5).runGeometry()
		elseif cmd == "phase4_5_lap" then
			require(script.Parent.TestPhase4_5).runLap()
		elseif cmd == "phase4_5_speed" then
			require(script.Parent.TestPhase4_5).runSpeed()
		elseif cmd == "phase5" then
			require(script.Parent.TestPhase5).run()
		elseif cmd == "phase5_unit" then
			require(script.Parent.TestPhase5).runUnit()
		elseif cmd == "phase6" then
			require(script.Parent.TestPhase6).run()
		elseif cmd == "phase6_unit" then
			require(script.Parent.TestPhase6).runUnit()
		elseif cmd == "phase6_integration" then
			require(script.Parent.TestPhase6).runIntegration()
		elseif cmd == "phase7" then
			require(script.Parent.TestPhase7).run()
		elseif cmd == "phase7_unit" then
			require(script.Parent.TestPhase7).runUnit()
		elseif cmd == "phase7_integration" then
			require(script.Parent.TestPhase7).runIntegration()
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
