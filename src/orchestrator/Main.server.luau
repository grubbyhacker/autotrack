local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local JobRunner = require(script.Parent.JobRunner)
local UIState = require(script.Parent.UIState)
local CameraDemo = require(script.Parent.CameraDemo)

local baselineLapTime: number? = nil
local skipBootBaseline = workspace:GetAttribute("AutoTrack_SkipBootBaseline") == true
local cameraLoopDemo = workspace:GetAttribute("AutoTrack_CameraLoopDemo") == true

print("[AutoTrack] Booting Phase 1...")

Players.CharacterAutoLoads = false

local function removeCharacter(player: Player)
	if player.Character then
		player.Character:Destroy()
	end
	player.CharacterAdded:Connect(function(character)
		character:Destroy()
	end)
end

local function setReplicationFocusForAll(target: BasePart)
	for _, player in ipairs(Players:GetPlayers()) do
		player.ReplicationFocus = target
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	removeCharacter(player)
end

Players.PlayerAdded:Connect(removeCharacter)
Players.PlayerAdded:Connect(function(player)
	local existing = workspace:FindFirstChild("VerifierCar")
	if existing and existing:IsA("BasePart") then
		player.ReplicationFocus = existing
	end
end)

local sectors = TrackGenerator.generate(Constants.TRACK_ROWS, Constants.TRACK_COLS)
TrackGenerator.buildParts(sectors)
SectorRegistry.init(6)

local startCF = TrackGenerator.canonicalStart()
local car = VerifierCar.spawn(startCF)
setReplicationFocusForAll(car)
local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)

UIState.init(-1)
UIState.initTrackCamera(sectors)
UIState.setPhase("Boot", "Initializing track...")
UIState.setBusy(true)
UIState.appendLog("Boot sequence started")
UIState.setCurrentSpeed(car.AssemblyLinearVelocity.Magnitude)
UIState.setCurrentSector(1)

task.spawn(function()
	while true do
		task.wait(0.1)
		local existing = workspace:FindFirstChild("VerifierCar")
		if existing and existing:IsA("BasePart") then
			UIState.setCurrentSpeed(existing.AssemblyLinearVelocity.Magnitude)
		else
			UIState.setCurrentSpeed(0)
		end
	end
end)

local function onSectorChange(id: number, entering: boolean)
	if entering then
		UIState.setCurrentSector(id)
		Tracer.log(string.format("sector_enter %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
	else
		Tracer.log(string.format("sector_exit %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
	end
end

workspace:SetAttribute("AutoTrack_BootBaselineSkipped", skipBootBaseline)

if skipBootBaseline then
	print("[AutoTrack] Boot baseline skipped by AutoTrack_SkipBootBaseline")
	workspace:SetAttribute("AutoTrack_BaselineLapDone", false)
	workspace:SetAttribute("AutoTrack_BaselineLapTime", -1)
	UIState.setPhase("BootBaselineSkipped", "Baseline recording skipped")
	UIState.appendLog("Boot baseline skipped")
else
	UIState.setPhase("BootBaseline", "Recording baseline lap...")
	UIState.appendLog("Baseline lap started")
	assert(JobLock.tryAcquire(), "JobLock busy")
	Tracer.log("lap_start")
	local ok, result = pcall(function()
		return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, onSectorChange)
	end)
	JobLock.release()

	if not ok then
		error(result)
	end

	if result.success then
		baselineLapTime = result.metrics.lap_time
		Tracer.log(string.format("lap_complete %.2f", baselineLapTime))
		print(string.format("[AutoTrack] Baseline lap complete: %.2fs", baselineLapTime))
		UIState.setBaselineLapTime(baselineLapTime)
		UIState.appendLog(string.format("Baseline lap complete: %.2fs", baselineLapTime))
	else
		print("[AutoTrack] Baseline lap FAILED: " .. tostring(result.failure and result.failure.type or "unknown"))
		UIState.appendLog("Baseline lap failed")
	end

	workspace:SetAttribute("AutoTrack_BaselineLapDone", result.success)
	workspace:SetAttribute("AutoTrack_BaselineLapTime", result.success and result.metrics.lap_time or -1)
end

RuntimeContext.init({
	sectors = sectors,
	car = car,
	canonicalStart = startCF,
	baselineLapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime") or -1,
})
UIState.setBaselineLapTime(workspace:GetAttribute("AutoTrack_BaselineLapTime") or -1)
UIState.publishReady()

if cameraLoopDemo then
	CameraDemo.start()
end

task.spawn(function()
	while true do
		task.wait(1)
		local existing = workspace:FindFirstChild("VerifierCar")
		if existing and existing:IsA("BasePart") then
			if RuntimeContext.getCar() ~= existing then
				RuntimeContext.setCar(existing)
				setReplicationFocusForAll(existing)
			end
		else
			local replacement = VerifierCar.spawn(startCF)
			RuntimeContext.setCar(replacement)
			setReplicationFocusForAll(replacement)
			print("[AutoTrack] Respawned missing VerifierCar")
		end
	end
end)

UIState.getSubmitEvent().OnServerEvent:Connect(function(_player, rawText)
	task.spawn(function()
		JobRunner.submit(tostring(rawText or ""))
	end)
end)

-- Run Phase 1 test suite automatically after boot.
-- TestRunner.server.luau handles on-demand re-runs once Rojo syncs src/test/.
if not skipBootBaseline and not cameraLoopDemo then
	local okTest, errTest = pcall(function()
		require(script.Parent.TestPhase1).run()
	end)
	if not okTest then
		print("[TEST ERROR] Phase1 suite failed to load: " .. tostring(errTest))
	end
end
