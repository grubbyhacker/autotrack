local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")

local TestDispatcher = require(script.Parent.TestDispatcher)
local JobRunner = require(script.Parent.JobRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)

local function bootFailureSnapshot(message: string, detailLine: string?)
	return {
		ok = false,
		status = "error",
		message = message,
		pass_count = 0,
		fail_count = 0,
		error_count = 1,
		lines = {
			"[TEST ERROR] " .. message,
			detailLine or "[TEST ERROR] Main.server.luau did not complete startup",
		},
	}
end

local function waitForBootReady(timeoutSeconds: number): (boolean, string?)
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		local stateFolder = ReplicatedStorage:FindFirstChild("AutoTrackUIState")
		local submitEvent = ReplicatedStorage:FindFirstChild("AutoTrack_SubmitRequest")
		local track = workspace:FindFirstChild("Track")
		local car = workspace:FindFirstChild("VerifierCar")
		if
			RuntimeContext.isReady()
			and stateFolder ~= nil
			and stateFolder:IsA("Folder")
			and submitEvent ~= nil
			and submitEvent:IsA("RemoteEvent")
			and track ~= nil
			and track:IsA("Folder")
			and car ~= nil
			and car:IsA("BasePart")
		then
			return true, nil
		end
		task.wait(0.25)
	end

	local missing = {}
	if not RuntimeContext.isReady() then
		table.insert(missing, "runtime_context")
	end
	local stateFolder = ReplicatedStorage:FindFirstChild("AutoTrackUIState")
	if stateFolder == nil or not stateFolder:IsA("Folder") then
		table.insert(missing, "ui_state")
	end
	local submitEvent = ReplicatedStorage:FindFirstChild("AutoTrack_SubmitRequest")
	if submitEvent == nil or not submitEvent:IsA("RemoteEvent") then
		table.insert(missing, "submit_event")
	end
	local track = workspace:FindFirstChild("Track")
	if track == nil or not track:IsA("Folder") then
		table.insert(missing, "track")
	end
	local car = workspace:FindFirstChild("VerifierCar")
	if car == nil or not car:IsA("BasePart") then
		table.insert(missing, "verifier_car")
	end

	return false, "boot not ready: missing " .. table.concat(missing, ",")
end

local args = StudioTestService:GetTestArgs()

if args ~= nil then
	task.defer(function()
		local ok, result = pcall(function()
			local commandType = tostring(args.command_type or "run_suite")
			local suite = tostring(args.suite or "")
			local bootMode = args.boot_mode
			local bootReadyTimeout = tonumber(args.boot_ready_seconds) or 30
			local baselineTimeout = tonumber(args.baseline_ready_seconds) or 60

			if commandType == "export_llm_trace" or suite == "llm_trace_export" or bootMode == "live_session" then
				return TestDispatcher.runSuite("llm_trace_export")
			end

			local bootOk, bootErr = waitForBootReady(bootReadyTimeout)
			if not bootOk then
				return bootFailureSnapshot(
					tostring(bootErr),
					"[TEST ERROR] Boot readiness contract failed before suite dispatch"
				)
			end

			if bootMode == "baseline" then
				local deadline = os.clock() + baselineTimeout
				while os.clock() < deadline do
					if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
						break
					end
					task.wait(0.25)
				end
			end

			if commandType == "endurance_trace" then
				local traceDurationSeconds = tonumber(args.trace_duration_seconds) or 60
				local submitOk, submitReason = JobRunner.startEndurance()
				if submitOk ~= true then
					return {
						ok = false,
						status = "error",
						message = "failed to start endurance trace: " .. tostring(submitReason),
						pass_count = 0,
						fail_count = 0,
						error_count = 1,
						lines = {
							"[TEST ERROR] failed to start endurance trace: " .. tostring(submitReason),
						},
					}
				end

				local deadline = os.clock() + traceDurationSeconds
				while os.clock() < deadline do
					task.wait(0.25)
				end

				local snapshot = TestDispatcher.runSuite("llm_trace_export")
				snapshot.command_type = "endurance_trace"
				snapshot.model = args.llm_model
				snapshot.trace_duration_seconds = traceDurationSeconds
				return snapshot
			end

			return TestDispatcher.runSuite(suite)
		end)

		if ok then
			StudioTestService:EndTest(result)
		else
			StudioTestService:EndTest({
				ok = false,
				status = "error",
				message = tostring(result),
				pass_count = 0,
				fail_count = 0,
				error_count = 1,
				lines = { "[TEST ERROR] " .. tostring(result) },
			})
		end
	end)
end
