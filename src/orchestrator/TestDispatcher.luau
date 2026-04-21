local TestSession = require(script.Parent.TestSession)

local TestDispatcher = {}

local function runSuiteBody(cmd)
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
	elseif cmd == "phase9" then
		require(script.Parent.TestPhase9).run()
	elseif cmd == "phase9_unit" then
		require(script.Parent.TestPhase9).runUnit()
	elseif cmd == "phase9_integration" then
		require(script.Parent.TestPhase9).runIntegration()
	elseif cmd == "phase11" then
		require(script.Parent.TestPhase11).run()
	elseif cmd == "phase11_unit" then
		require(script.Parent.TestPhase11).runUnit()
	elseif cmd == "phase11_integration" then
		require(script.Parent.TestPhase11).runIntegration()
	elseif cmd == "phase13" then
		require(script.Parent.TestPhase13).run()
	elseif cmd == "phase13_unit" then
		require(script.Parent.TestPhase13).runUnit()
	elseif cmd == "phase13_integration" then
		require(script.Parent.TestPhase13).runIntegration()
	elseif cmd == "phase14" then
		require(script.Parent.TestPhase14).run()
	elseif cmd == "phase14_unit" then
		require(script.Parent.TestPhase14).runUnit()
	elseif cmd == "phase14_integration" then
		require(script.Parent.TestPhase14).runIntegration()
	elseif cmd == "phase14_crestdip_pair" then
		require(script.Parent.TestPhase14).runCrestDipPair()
	elseif cmd == "phase14_crestdip_search" then
		require(script.Parent.TestPhase14).runCrestDipSearch()
	elseif cmd == "phase14_sector2_debug" then
		require(script.Parent.TestPhase14).runSector2Debug()
	elseif cmd == "phase14_5" then
		require(script.Parent.TestPhase14_5).run()
	elseif cmd == "phase15" then
		require(script.Parent.TestPhase15).run()
	elseif cmd == "phase16" then
		require(script.Parent.TestPhase16).run()
	elseif cmd == "llm_trace_export" then
		require(script.Parent.TestPhase17).runExport()
	else
		local unknownLine = "[TEST FAIL: unknown_suite] " .. tostring(cmd)
		print(unknownLine)
		TestSession.appendLine(unknownLine)
	end
end

function TestDispatcher.runSuite(cmd)
	local command = tostring(cmd)
	local runningLine = "[TEST] Running suite: " .. command

	print(runningLine)
	TestSession.beginSuite(command)
	TestSession.appendLine(runningLine)

	local ok, err = pcall(function()
		runSuiteBody(cmd)
	end)

	if not ok then
		local errorLine = "[TEST ERROR] " .. tostring(err)
		print(errorLine)
		TestSession.appendLine(errorLine)
	end

	local doneLine = "[TEST] Suite done: " .. command
	print(doneLine)
	TestSession.appendLine(doneLine)

	local snapshot = TestSession.snapshot()
	if snapshot.error_count > 0 then
		TestSession.finishSuite("error", tostring(err))
	elseif snapshot.fail_count > 0 then
		TestSession.finishSuite("failed")
	else
		TestSession.finishSuite("passed")
	end

	return TestSession.snapshot()
end

return TestDispatcher
