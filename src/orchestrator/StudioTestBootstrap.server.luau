local StudioTestService = game:GetService("StudioTestService")

local TestDispatcher = require(script.Parent.TestDispatcher)

local args = StudioTestService:GetTestArgs()

if args ~= nil then
	task.defer(function()
		local ok, result = pcall(function()
			local suite = tostring(args.suite)
			local bootMode = args.boot_mode
			local baselineTimeout = tonumber(args.baseline_ready_seconds) or 60

			if bootMode == "baseline" then
				local deadline = os.clock() + baselineTimeout
				while os.clock() < deadline do
					if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
						break
					end
					task.wait(0.25)
				end
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
