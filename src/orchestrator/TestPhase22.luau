--!strict

local HttpService = game:GetService("HttpService")

local T = require(script.Parent.TestUtils)
local CameraDemo = require(script.Parent.CameraDemo)
local HUDPreviewDemo = require(script.Parent.HUDPreviewDemo)
local JobLock = require(script.Parent.JobLock)
local JobRunner = require(script.Parent.JobRunner)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TestSuiteRunner = require(script.Parent.TestSuiteRunner)
local TuneMode = require(script.Parent.TuneMode)
local UIState = require(script.Parent.UIState)

local TestPhase22 = {}

type CapturedEnduranceArgs = {
	submit: unknown,
	submitDesignIntent: unknown,
	getLastJob: unknown,
	isCameraDemoActive: unknown,
}

local function waitUntil(predicate, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait(0.1)
	end
	return predicate()
end

local function ensureReady(): boolean
	local ready = waitUntil(function()
		return RuntimeContext.isReady()
	end, 30)
	T.expect("phase22_runtime_context_ready", ready, "runtime context not ready")
	return ready
end

local function waitForSessionSettle(timeoutSeconds: number): boolean
	local settled = waitUntil(function()
		return not CameraDemo.isActive() and not TuneMode.isActive() and not JobLock.isHeld()
	end, timeoutSeconds)
	if settled then
		task.wait(0.75)
	end
	return settled
end

local function cleanupSession()
	if CameraDemo.isActive() then
		CameraDemo.stop()
		waitUntil(function()
			return not CameraDemo.isActive()
		end, 5)
	end
	waitForSessionSettle(5)

	if TuneMode.isActive() then
		TuneMode.stop()
		waitUntil(function()
			return not TuneMode.isActive()
		end, 5)
	end
	waitForSessionSettle(5)

	if HUDPreviewDemo.isActive() then
		local activeKind = HUDPreviewDemo.activeKind()
		if activeKind ~= nil then
			HUDPreviewDemo.toggle(activeKind)
		end
	end

	if JobLock.isHeld() then
		JobLock.release()
	end

	UIState.publishReady()
end

local function withStubbedRunSuite(callback)
	local original = TestSuiteRunner.getRunner()
	local capturedSuite = nil
	TestSuiteRunner.setRunner(function(suite)
		capturedSuite = suite
		return {
			status = "passed",
			pass_count = 1,
			fail_count = 0,
			error_count = 0,
		}
	end)

	local ok, err = pcall(function()
		callback(function()
			return capturedSuite
		end)
	end)

	TestSuiteRunner.setRunner(original)
	if not ok then
		error(err)
	end
end

local function runCommandSurface()
	if not ensureReady() then
		return
	end

	cleanupSession()

	local stateFolder = UIState.getStateFolder()
	local baselinePhase = stateFolder:GetAttribute("phase")

	local repairOk, repairErr = JobRunner.submit("/demo repair")
	T.expect(
		"phase22_demo_repair_preview_toggles_on",
		repairOk == true
			and HUDPreviewDemo.activeKind() == "repair"
			and stateFolder:GetAttribute("target_sector_id") == 3
			and stateFolder:GetAttribute("phase") == "ApplyRepair",
		tostring(repairErr)
	)
	local repairOffOk, repairOffErr = JobRunner.submit("/demo repair")
	T.expect(
		"phase22_demo_repair_preview_toggles_off",
		repairOffOk == true and not HUDPreviewDemo.isActive() and stateFolder:GetAttribute("phase") == baselinePhase,
		tostring(repairOffErr)
	)

	local llmOk, llmErr = JobRunner.submit("/demo llmerror")
	T.expect(
		"phase22_demo_llmerror_preview_sets_warning_state",
		llmOk == true
			and HUDPreviewDemo.activeKind() == "llmerror"
			and string.find(tostring(stateFolder:GetAttribute("error_text")), "LLM error:", 1, true) ~= nil,
		tostring(llmErr)
	)
	JobRunner.submit("/demo llmerror")

	local hotfixOk, hotfixErr = JobRunner.submit("/demo ui-hotfix")
	T.expect(
		"phase22_demo_ui_hotfix_preview_sets_endurance_badges",
		hotfixOk == true
			and HUDPreviewDemo.activeKind() == "ui-hotfix"
			and stateFolder:GetAttribute("endurance_mode_active") == true
			and stateFolder:GetAttribute("endurance_hotfix_active") == true,
		tostring(hotfixErr)
	)
	JobRunner.submit("/demo ui-hotfix")

	local cameraOk, cameraErr = JobRunner.submit("/demo camera")
	T.expect(
		"phase22_demo_camera_starts",
		cameraOk == true and CameraDemo.isActive() and CameraDemo.activePreset() == "camera",
		tostring(cameraErr)
	)

	local blockedTestCalled = false
	local blockedOriginalRunSuite = TestSuiteRunner.getRunner()
	TestSuiteRunner.setRunner(function(_suite)
		blockedTestCalled = true
		return {
			status = "passed",
			pass_count = 1,
			fail_count = 0,
			error_count = 0,
		}
	end)
	local blockedTestOk, blockedTestErr = JobRunner.submit("/test phase11_unit")
	TestSuiteRunner.setRunner(blockedOriginalRunSuite)
	T.expect(
		"phase22_test_rejected_while_camera_demo_active",
		blockedTestOk == false
			and blockedTestCalled == false
			and string.find(tostring(blockedTestErr), "demo 'camera' is running", 1, true) ~= nil,
		tostring(blockedTestErr)
	)

	local rampitupOk, rampitupErr = JobRunner.submit("/demo rampitup")
	T.expect(
		"phase22_second_camera_demo_rejected_while_first_active",
		rampitupOk == false and string.find(tostring(rampitupErr), "demo 'camera' is running", 1, true) ~= nil,
		tostring(rampitupErr)
	)

	local cameraOffOk, cameraOffErr = JobRunner.submit("/demo camera")
	T.expect(
		"phase22_demo_camera_toggles_off",
		cameraOffOk == true and not CameraDemo.isActive(),
		tostring(cameraOffErr)
	)
	cleanupSession()

	local tuneOk, tuneErr = JobRunner.submit("/tune rampjump")
	local tuneStarted = waitUntil(function()
		return TuneMode.isActive()
	end, 5)
	T.expect(
		"phase22_tune_command_starts",
		tuneOk == true and tuneStarted and stateFolder:GetAttribute("tune_mode_active") == true,
		tostring(tuneErr)
	)

	local demoWhileTuneOk, demoWhileTuneErr = JobRunner.submit("/demo repair")
	T.expect(
		"phase22_demo_rejected_while_tune_active",
		demoWhileTuneOk == false and string.find(tostring(demoWhileTuneErr), "tune mode is running", 1, true) ~= nil,
		tostring(demoWhileTuneErr)
	)

	local testWhileTuneCalled = false
	local tuneOriginalRunSuite = TestSuiteRunner.getRunner()
	TestSuiteRunner.setRunner(function(_suite)
		testWhileTuneCalled = true
		return {
			status = "passed",
			pass_count = 1,
			fail_count = 0,
			error_count = 0,
		}
	end)
	local testWhileTuneOk, testWhileTuneErr = JobRunner.submit("/test phase11_unit")
	TestSuiteRunner.setRunner(tuneOriginalRunSuite)
	T.expect(
		"phase22_test_rejected_while_tune_active",
		testWhileTuneOk == false
			and testWhileTuneCalled == false
			and string.find(tostring(testWhileTuneErr), "tune mode is running", 1, true) ~= nil,
		tostring(testWhileTuneErr)
	)

	local tuneOffOk, tuneOffErr = JobRunner.submit("/tune stop")
	local tuneStopped = waitUntil(function()
		return not TuneMode.isActive()
	end, 5)
	waitForSessionSettle(5)
	T.expect(
		"phase22_tune_command_stops",
		tuneOffOk == true and tuneStopped and stateFolder:GetAttribute("tune_mode_active") ~= true,
		tostring(tuneOffErr)
	)

	withStubbedRunSuite(function(getCapturedSuite)
		local testOk, testErr = JobRunner.submit("/test phase11_unit")
		T.expect(
			"phase22_test_command_routes_to_dispatcher",
			testOk == true and getCapturedSuite() == "phase11_unit" and stateFolder:GetAttribute("phase") == "RunTest",
			tostring(testErr)
		)
	end)

	local originalStartEndurance = JobRunner.startEndurance
	local capturedEnduranceStarts = 0
	JobRunner.startEndurance = function()
		capturedEnduranceStarts += 1
		return true, nil
	end
	local enduranceAliasOk, enduranceAliasErr = JobRunner.submit("/demo endurance")
	JobRunner.startEndurance = originalStartEndurance
	T.expect(
		"phase22_demo_endurance_routes_to_internal_seam",
		enduranceAliasOk == true and capturedEnduranceStarts == 1,
		tostring(enduranceAliasErr)
	)

	local removedCommands = {
		{ name = "crest", command = "/demo crest" },
		{ name = "maximize", command = "/demo maximize" },
		{ name = "extreme", command = "/demo extreme" },
		{ name = "hotfix", command = "/demo hotfix" },
	}
	for _, item in ipairs(removedCommands) do
		local ok, reason = JobRunner.submit(item.command)
		T.expect(
			"phase22_removed_demo_" .. item.name .. "_rejected",
			ok == false and string.find(tostring(reason), "is not supported", 1, true) ~= nil,
			HttpService:JSONEncode({ command = item.command, reason = reason })
		)
	end

	local llmOk2, llmErr2 = JobRunner.submit("/llm on")
	T.expect(
		"phase22_removed_llm_command_rejected",
		llmOk2 == false and llmErr2 == "LLM slash commands removed; use the HUD model selector or startup config",
		tostring(llmErr2)
	)

	local unknownOk, unknownErr = JobRunner.submit("/bogus whatever")
	T.expect(
		"phase22_unknown_slash_command_rejected",
		unknownOk == false and unknownErr == "unknown command; supported: /demo, /test, /tune",
		tostring(unknownErr)
	)

	cleanupSession()
end

local function runEnduranceEntry()
	if not ensureReady() then
		return
	end

	cleanupSession()

	local cameraOk, cameraErr = JobRunner.submit("/demo camera")
	T.expect("phase22_endurance_guard_camera_demo_setup", cameraOk == true, tostring(cameraErr))
	local blockedByCameraOk, blockedByCameraErr = JobRunner.startEndurance()
	T.expect(
		"phase22_start_endurance_rejects_camera_demo",
		blockedByCameraOk == false
			and string.find(tostring(blockedByCameraErr), "before /demo endurance", 1, true) ~= nil,
		tostring(blockedByCameraErr)
	)
	JobRunner.submit("/demo camera")
	cleanupSession()

	local originalTuneIsActive = TuneMode.isActive
	TuneMode.isActive = function()
		return true
	end
	local blockedByTuneOk, blockedByTuneErr = JobRunner.startEndurance()
	T.expect(
		"phase22_start_endurance_rejects_tune_mode",
		blockedByTuneOk == false and blockedByTuneErr == "tune mode is running; use /tune stop to exit it",
		tostring(blockedByTuneErr)
	)
	TuneMode.isActive = originalTuneIsActive

	assert(JobLock.tryAcquire(), "failed to acquire job lock for phase22 busy guard")
	local blockedByBusyOk, blockedByBusyErr = JobRunner.startEndurance()
	T.expect(
		"phase22_start_endurance_rejects_busy_track",
		blockedByBusyOk == false and blockedByBusyErr == "track is busy; try again shortly",
		tostring(blockedByBusyErr)
	)
	JobLock.release()

	local originalIsActive = OrchestratorAgent.isActive
	OrchestratorAgent.isActive = function()
		return true
	end
	local blockedByActiveOk, blockedByActiveErr = JobRunner.startEndurance()
	T.expect(
		"phase22_start_endurance_rejects_existing_endurance_run",
		blockedByActiveOk == false and blockedByActiveErr == "endurance mode already running",
		tostring(blockedByActiveErr)
	)
	OrchestratorAgent.isActive = originalIsActive

	local originalRun = OrchestratorAgent.run
	local captured = {
		called = false,
		args = nil :: CapturedEnduranceArgs?,
	}
	OrchestratorAgent.run = function(args: CapturedEnduranceArgs)
		captured.called = true
		captured.args = args
		return true, nil
	end

	local startOk, startErr = JobRunner.startEndurance()
	local started = waitUntil(function()
		return captured.called
	end, 3)
	local capturedArgs = captured.args
	T.expect(
		"phase22_start_endurance_uses_internal_seam",
		startOk == true
			and started
			and capturedArgs ~= nil
			and type(capturedArgs.submit) == "function"
			and type(capturedArgs.submitDesignIntent) == "function"
			and type(capturedArgs.getLastJob) == "function"
			and type(capturedArgs.isCameraDemoActive) == "function",
		HttpService:JSONEncode({
			start_err = startErr,
			called = captured.called,
			args_present = captured.args ~= nil,
		})
	)

	OrchestratorAgent.run = originalRun
	cleanupSession()
end

function TestPhase22.run()
	runCommandSurface()
	runEnduranceEntry()
end

function TestPhase22.runCommandSurface()
	runCommandSurface()
end

function TestPhase22.runEnduranceEntry()
	runEnduranceEntry()
end

return TestPhase22
