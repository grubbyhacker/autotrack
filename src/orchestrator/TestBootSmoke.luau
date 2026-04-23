local ReplicatedStorage = game:GetService("ReplicatedStorage")

local T = require(script.Parent.TestUtils)
local RuntimeContext = require(script.Parent.RuntimeContext)

local TestBootSmoke = {}

function TestBootSmoke.run()
	local stateFolder = ReplicatedStorage:FindFirstChild("AutoTrackUIState")
	local submitEvent = ReplicatedStorage:FindFirstChild("AutoTrack_SubmitRequest")
	local track = workspace:FindFirstChild("Track")
	local car = workspace:FindFirstChild("VerifierCar")

	T.expect("boot_smoke_runtime_context_ready", RuntimeContext.isReady(), "RuntimeContext.init did not complete")
	T.expect(
		"boot_smoke_ui_state_folder_exists",
		stateFolder ~= nil and stateFolder:IsA("Folder"),
		"AutoTrackUIState missing"
	)
	T.expect(
		"boot_smoke_submit_event_exists",
		submitEvent ~= nil and submitEvent:IsA("RemoteEvent"),
		"AutoTrack_SubmitRequest missing"
	)
	T.expect("boot_smoke_track_folder_exists", track ~= nil and track:IsA("Folder"), "Track folder missing")
	T.expect("boot_smoke_verifier_car_exists", car ~= nil and car:IsA("BasePart"), "VerifierCar missing")
end

return TestBootSmoke
