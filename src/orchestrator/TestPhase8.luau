local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local UIState = require(script.Parent.UIState)
local JobRunner = require(script.Parent.JobRunner)
local JobLock = require(script.Parent.JobLock)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

local TestPhase8 = {}

local function getStateFolder(): Folder
	return ReplicatedStorage:WaitForChild("AutoTrackUIState") :: Folder
end

local function getWorldRoot(): Folder?
	local root = workspace:FindFirstChild("AutoTrackUIWorld")
	if root and root:IsA("Folder") then
		return root
	end
	return nil
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function waitForCondition(timeoutSeconds: number, predicate): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait(0.1)
	end
	return false
end

function TestPhase8.runUnit()
	local stateFolder = getStateFolder()

	T.expect("phase8_state_folder_exists", stateFolder ~= nil, "missing AutoTrackUIState")
	T.expect(
		"phase8_remote_exists",
		ReplicatedStorage:FindFirstChild("AutoTrack_SubmitRequest") ~= nil,
		"missing submit remote"
	)

	UIState.publishReady()
	T.expect(
		"phase8_ready_boot_state",
		(stateFolder:GetAttribute("phase_label") == "Ready for request")
			and (stateFolder:GetAttribute("busy") == false),
		tostring(stateFolder:GetAttribute("phase_label"))
	)

	T.expect(
		"phase8_baseline_published",
		(stateFolder:GetAttribute("baseline_lap_time") or -1) == (workspace:GetAttribute("AutoTrack_BaselineLapTime") or -1),
		tostring(stateFolder:GetAttribute("baseline_lap_time"))
	)

	UIState.setPhase("AnalyzeFailure", "Analyzing failure...")
	T.expect(
		"phase8_phase_label_mapping",
		stateFolder:GetAttribute("phase") == "AnalyzeFailure" and stateFolder:GetAttribute("phase_label") == "Analyzing failure...",
		tostring(stateFolder:GetAttribute("phase_label"))
	)

	UIState.showFailureBanner("TRAVERSAL FAIL")
	T.expect(
		"phase8_failure_banner_state_updates",
		stateFolder:GetAttribute("failure_banner_visible") == true
			and stateFolder:GetAttribute("failure_banner_text") == "TRAVERSAL FAIL",
		tostring(stateFolder:GetAttribute("failure_banner_text"))
	)
	UIState.hideFailureBanner()
	T.expect(
		"phase8_failure_banner_state_clears",
		stateFolder:GetAttribute("failure_banner_visible") == false
			and stateFolder:GetAttribute("failure_banner_text") == "",
		tostring(stateFolder:GetAttribute("failure_banner_text"))
	)

	UIState.setRepairAction("ENTRY BOOST")
	T.expect(
		"phase8_repair_action_state_updates",
		stateFolder:GetAttribute("repair_action_text") == "ENTRY BOOST",
		tostring(stateFolder:GetAttribute("repair_action_text"))
	)
	UIState.clearRepairAction()
	T.expect(
		"phase8_repair_action_state_clears",
		stateFolder:GetAttribute("repair_action_text") == "",
		tostring(stateFolder:GetAttribute("repair_action_text"))
	)

	UIState.resetLogs()
	for index = 1, 5 do
		UIState.appendLog("line-" .. tostring(index))
	end
	T.expect(
		"phase8_recent_log_caps_at_four",
		stateFolder:GetAttribute("log_1") == "line-2"
			and stateFolder:GetAttribute("log_2") == "line-3"
			and stateFolder:GetAttribute("log_3") == "line-4"
			and stateFolder:GetAttribute("log_4") == "line-5",
		table.concat({
			tostring(stateFolder:GetAttribute("log_1")),
			tostring(stateFolder:GetAttribute("log_2")),
			tostring(stateFolder:GetAttribute("log_3")),
			tostring(stateFolder:GetAttribute("log_4")),
		}, ",")
	)

	local okEmpty, emptyReason = JobRunner.submit("")
	T.expect(
		"phase8_parse_rejection_updates_state",
		okEmpty == false
			and emptyReason == "empty request"
			and stateFolder:GetAttribute("phase_label") == "Request rejected"
			and stateFolder:GetAttribute("error_text") == "empty request"
			and stateFolder:GetAttribute("busy") == false,
		tostring(emptyReason)
	)

	assert(JobLock.tryAcquire(), "expected JobLock acquisition for phase8 busy test")
	local okBusy, busyReason = JobRunner.submit("add a jump in sector 3")
	JobLock.release()
	T.expect(
		"phase8_busy_rejection_updates_state",
		okBusy == false
			and string.find(tostring(busyReason), "busy", 1, true) ~= nil
			and stateFolder:GetAttribute("phase_label") == "Track busy"
			and stateFolder:GetAttribute("busy") == false,
		tostring(busyReason)
	)

	local okDemoStart, demoStartReason = JobRunner.submit("/demo camera")
	local demoStarted = waitForCondition(2, function()
		local sector3Demo = SectorRegistry.getCommitted(3)
		local sector7Demo = SectorRegistry.getCommitted(7)
		local phase = stateFolder:GetAttribute("phase")
		return (phase == "CameraDemo" or phase == "CameraDemoLap")
			and sector3Demo ~= nil
			and sector3Demo.mechanic == "RampJump"
			and sector7Demo ~= nil
			and sector7Demo.mechanic == "RampJump"
	end)
	T.expect(
		"phase8_camera_demo_start_command",
		okDemoStart == true
			and demoStartReason == nil
			and demoStarted,
		tostring(demoStartReason)
	)

	local okDemoStop, demoStopReason = JobRunner.submit("/demo camera")
	local demoStopped = waitForCondition(20, function()
		local sector3Restored = SectorRegistry.getCommitted(3)
		local sector7Restored = SectorRegistry.getCommitted(7)
		return stateFolder:GetAttribute("phase_label") == "Ready for request"
			and sector3Restored ~= nil
			and sector3Restored.mechanic == nil
			and sector7Restored ~= nil
			and sector7Restored.mechanic == nil
	end)
	T.expect(
		"phase8_camera_demo_stop_command",
		okDemoStop == true
			and demoStopReason == nil
			and demoStopped,
		tostring(demoStopReason)
	)

	UIState.publishReady()
end

function TestPhase8.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase8_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase8_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	local stateFolder = getStateFolder()
	UIState.publishReady()

	local okCommit, commitReason = JobRunner.submit("add a chicane in sector 3")
	local committedState = SectorRegistry.getCommitted(3)
	local successRoot = getWorldRoot()
	local successMarker = successRoot and successRoot:FindFirstChild("SuccessMarker")
	T.expect(
		"phase8_commit_updates_hud_state",
		okCommit == true
			and commitReason == nil
			and stateFolder:GetAttribute("final_status") == "committed"
			and stateFolder:GetAttribute("phase_label") == "Committed"
			and (stateFolder:GetAttribute("last_lap_time") or -1) > 0
			and (stateFolder:GetAttribute("slowdown_ratio") or 0) > 0
			and committedState ~= nil
			and committedState.mechanic == "Chicane"
			and successMarker ~= nil,
		tostring(commitReason)
	)

	task.wait(Constants.UI_SUCCESS_DWELL + 0.25)
	successRoot = getWorldRoot()
	successMarker = successRoot and successRoot:FindFirstChild("SuccessMarker")
	T.expect(
		"phase8_success_marker_cleans_up",
		successMarker == nil,
		"success marker still present"
	)

	local crestFinished = false
	local crestOk, crestReason = false, nil
	task.spawn(function()
		crestOk, crestReason = JobRunner.submit("add a really tall steep short crest in sector 3")
		crestFinished = true
	end)

	local deadline = os.clock() + 190
	local sawFailureMarker = false
	local sawRepairExplanation = false
	local sawAnalyzePhase = false
	while os.clock() < deadline and not crestFinished do
		local root = getWorldRoot()
		local marker = root and root:FindFirstChild("FailureMarker")
		if marker then
			sawFailureMarker = true
		end
		local phase = stateFolder:GetAttribute("phase")
		if phase == "AnalyzeFailure" or phase == "ApplyRepair" then
			sawAnalyzePhase = true
		end
		local explanation = stateFolder:GetAttribute("explanation") or ""
		if explanation ~= "" then
			sawRepairExplanation = true
		end
		task.wait(0.2)
	end

	local revertedState = SectorRegistry.getCommitted(3)
	local failureRoot = getWorldRoot()
	local failureMarker = failureRoot and failureRoot:FindFirstChild("FailureMarker")
	T.expect(
		"phase8_revert_flow_updates_hud_and_markers",
		crestFinished
			and crestOk == true
			and crestReason == nil
			and sawFailureMarker
			and sawAnalyzePhase
			and sawRepairExplanation
			and stateFolder:GetAttribute("final_status") == "reverted"
			and stateFolder:GetAttribute("phase_label") == "Reverted"
			and failureMarker == nil
			and revertedState ~= nil
			and revertedState.mechanic == "Chicane",
		tostring(crestReason)
	)
end

function TestPhase8.run()
	TestPhase8.runUnit()
	TestPhase8.runIntegration()
end

return TestPhase8
