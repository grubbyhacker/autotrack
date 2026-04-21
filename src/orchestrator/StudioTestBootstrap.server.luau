local StudioTestService = game:GetService("StudioTestService")

local TestDispatcher = require(script.Parent.TestDispatcher)
local JobRunner = require(script.Parent.JobRunner)

local args = StudioTestService:GetTestArgs()

if args ~= nil then
	task.defer(function()
		local ok, result = pcall(function()
			local commandType = tostring(args.command_type or "run_suite")
			local suite = tostring(args.suite or "")
			local bootMode = args.boot_mode
			local baselineTimeout = tonumber(args.baseline_ready_seconds) or 60

			if commandType == "export_llm_trace" or suite == "llm_trace_export" or bootMode == "live_session" then
				return TestDispatcher.runSuite("llm_trace_export")
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
				local submitOk, submitReason = JobRunner.submit("/demo endurance")
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
