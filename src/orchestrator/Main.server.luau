local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StudioTestService = game:GetService("StudioTestService")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LLMConfig = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LLMConfig"))
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

-- Consume the skip flag once at boot so stale edit-time/test-bridge state
-- does not silently leak into later Play sessions.
workspace:SetAttribute("AutoTrack_SkipBootBaseline", false)

local function shouldHonorBootLLMOverrides(): boolean
	if workspace:GetAttribute("AutoTrack_HonorBootLLMOverride") == true then
		return true
	end

	local ok, args = pcall(function()
		return StudioTestService:GetTestArgs()
	end)
	if not ok or type(args) ~= "table" then
		return false
	end
	return type(args.llm_enabled) == "boolean"
		or (type(args.llm_model) == "string" and args.llm_model ~= "")
end

-- Default to heuristic on normal startup. Only explicit harness / automation
-- runs should inherit workspace boot overrides.
do
	if shouldHonorBootLLMOverrides() then
		local llmEnabled = workspace:GetAttribute("AutoTrack_LLMEnabled") == true
		local llmModel = workspace:GetAttribute("AutoTrack_LLMModel")
		LLMConfig.setEnabled(llmEnabled)
		if type(llmModel) == "string" and llmModel ~= "" then
			LLMConfig.setModel(llmModel)
		end
	else
		workspace:SetAttribute("AutoTrack_LLMEnabled", false)
		workspace:SetAttribute("AutoTrack_LLMModel", "heuristic")
		LLMConfig.setEnabled(false)
		LLMConfig.setModel("heuristic")
	end
end

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
do
	local cfg = LLMConfig.get()
	UIState.setLLMConfig(cfg.enabled, cfg.modelId)
end
UIState.initTrackCamera(sectors)
UIState.setPhase("Boot", "Initializing track...")
UIState.setBusy(true)
UIState.appendLog("Boot sequence started")
UIState.setCurrentSpeed(car.AssemblyLinearVelocity.Magnitude)
UIState.setSpeedTargets(Constants.CAR_TARGET_SPEED, Constants.CAR_TARGET_SPEED)
UIState.setCurrentSector(1)
UIState.setCurrentSectorKind("Corner")
UIState.setRuntimeIdentity(
	Constants.BUILD_STAMP,
	string.format(
		"corner sf=%.2f in=%.2f out=%.2f",
		Constants.CORNER_SPEED_FACTOR,
		Constants.CORNER_ENTRY_SHOULDER_FRACTION,
		Constants.CORNER_EXIT_SHOULDER_FRACTION
	)
)
UIState.appendLog("Build " .. Constants.BUILD_STAMP)
UIState.appendLog(string.format(
	"Controller sf=%.2f in=%.2f out=%.2f",
	Constants.CORNER_SPEED_FACTOR,
	Constants.CORNER_ENTRY_SHOULDER_FRACTION,
	Constants.CORNER_EXIT_SHOULDER_FRACTION
))
Tracer.log("build " .. Constants.BUILD_STAMP)
Tracer.log(string.format(
	"controller_profile corner_sf=%.2f corner_in=%.2f corner_out=%.2f",
	Constants.CORNER_SPEED_FACTOR,
	Constants.CORNER_ENTRY_SHOULDER_FRACTION,
	Constants.CORNER_EXIT_SHOULDER_FRACTION
))

task.spawn(function()
	while true do
		task.wait(0.1)
		local existing = workspace:FindFirstChild("VerifierCar")
		if existing and existing:IsA("BasePart") then
			UIState.setCurrentSpeed(existing.AssemblyLinearVelocity.Magnitude)
			UIState.setSpeedTargets(
				existing:GetAttribute("AutoTrack_TargetSpeed") or 0,
				existing:GetAttribute("AutoTrack_CommandedSpeed") or 0
			)
			UIState.setCurrentSectorKind(tostring(existing:GetAttribute("AutoTrack_CurrentSectorKind") or ""))
			local look = existing.CFrame.LookVector
			local headingDeg = (math.atan2(-look.Z, look.X) * (180 / math.pi) + 360) % 360
			local pitchDeg = math.asin(math.clamp(look.Y, -1, 1)) * (180 / math.pi)
			UIState.setCarAttitude(headingDeg, pitchDeg)
		else
			UIState.setCurrentSpeed(0)
			UIState.setSpeedTargets(0, 0)
			UIState.setCurrentSectorKind("")
			UIState.setCarAttitude(0, 0)
		end
	end
end)

local function onSectorChange(id: number, entering: boolean)
	if entering then
		UIState.setCurrentSector(id)
		Tracer.log(string.format(
			"sector_enter %d speed=%.1f cmd=%.1f tgt=%.1f kind=%s",
			id,
			car.AssemblyLinearVelocity.Magnitude,
			car:GetAttribute("AutoTrack_CommandedSpeed") or 0,
			car:GetAttribute("AutoTrack_TargetSpeed") or 0,
			tostring(car:GetAttribute("AutoTrack_CurrentSectorKind") or "")
		))
	else
		Tracer.log(string.format(
			"sector_exit %d speed=%.1f cmd=%.1f tgt=%.1f kind=%s",
			id,
			car.AssemblyLinearVelocity.Magnitude,
			car:GetAttribute("AutoTrack_CommandedSpeed") or 0,
			car:GetAttribute("AutoTrack_TargetSpeed") or 0,
			tostring(car:GetAttribute("AutoTrack_CurrentSectorKind") or "")
		))
	end
end

local function logContainmentSummary(metrics)
	local peaks = metrics and metrics.sector_peak_centerline_distance
	if type(peaks) ~= "table" then
		return
	end
	for sectorId, peak in pairs(peaks) do
		Tracer.log(string.format(
			"lap_containment %d center=%.2f front=%.2f body=%.2f signed=%.2f progress=%.2f",
			sectorId,
			peak or 0,
			(metrics.sector_peak_front_distance and metrics.sector_peak_front_distance[sectorId]) or 0,
			(metrics.sector_peak_body_distance and metrics.sector_peak_body_distance[sectorId]) or 0,
			(metrics.sector_peak_signed_lateral and metrics.sector_peak_signed_lateral[sectorId]) or 0,
			(metrics.sector_peak_progress and metrics.sector_peak_progress[sectorId]) or 0
		))
	end
end

local function appendContainmentSummaryToUI(metrics)
	local peaks = metrics and metrics.sector_peak_body_distance
	if type(peaks) ~= "table" then
		return
	end

	local ordered = {}
	for sectorId, peak in pairs(peaks) do
		table.insert(ordered, {
			sectorId = sectorId,
			body = peak or 0,
			front = (metrics.sector_peak_front_distance and metrics.sector_peak_front_distance[sectorId]) or 0,
			center = (metrics.sector_peak_centerline_distance and metrics.sector_peak_centerline_distance[sectorId]) or 0,
			progress = (metrics.sector_peak_progress and metrics.sector_peak_progress[sectorId]) or 0,
		})
	end
	table.sort(ordered, function(a, b)
		return a.body > b.body
	end)

	for index = 1, math.min(2, #ordered) do
		local item = ordered[index]
		UIState.appendLog(string.format(
			"Containment S%d body=%.1f front=%.1f center=%.1f @ %.0f%%",
			item.sectorId,
			item.body,
			item.front,
			item.center,
			item.progress * 100
		))
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
		logContainmentSummary(result.metrics)
		appendContainmentSummaryToUI(result.metrics)
		print(string.format("[AutoTrack] Baseline lap complete: %.2fs", baselineLapTime))
		UIState.setBaselineLapTime(baselineLapTime)
		UIState.setLastLapTime(baselineLapTime)
		UIState.appendLog(string.format("Baseline lap complete: %.2fs", baselineLapTime))
	else
		logContainmentSummary(result.metrics)
		appendContainmentSummaryToUI(result.metrics)
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

local setBaselineEvent = Instance.new("RemoteEvent")
setBaselineEvent.Name = "AutoTrack_SetBaseline"
setBaselineEvent.Parent = ReplicatedStorage

setBaselineEvent.OnServerEvent:Connect(function(_player)
	local stateFolder = UIState.getStateFolder()
	local lastLap = stateFolder:GetAttribute("last_lap_time") or -1
	local bootBaseline = stateFolder:GetAttribute("baseline_lap_time") or -1
	local lapTime = if lastLap > 0 then lastLap else bootBaseline
	if lapTime > 0 then
		UIState.setBaselineLapTime(lapTime)
		RuntimeContext.setBaselineLapTime(lapTime)
		workspace:SetAttribute("AutoTrack_BaselineLapTime", lapTime)
		UIState.appendLog(string.format("Baseline set: %.2fs", lapTime))
	else
		if not JobLock.tryAcquire() then
			UIState.appendLog("Track busy — try again")
			return
		end
		UIState.setPhase("Baseline", "Recording baseline lap...")
		UIState.appendLog("Baseline lap started")
		UIState.setBusy(true)
		task.spawn(function()
			local currentCar = RuntimeContext.getCar()
			local ok, result = pcall(function()
				return VerifierController.runLap(currentCar, waypoints, waypointSectors, sectorKinds, function(id, entering)
					if entering then UIState.setCurrentSector(id) end
				end)
			end)
			JobLock.release()
			UIState.setBusy(false)
			if ok and result.success then
				local t = result.metrics.lap_time
				UIState.setBaselineLapTime(t)
				UIState.setLastLapTime(t)
				RuntimeContext.setBaselineLapTime(t)
				workspace:SetAttribute("AutoTrack_BaselineLapTime", t)
				UIState.appendLog(string.format("Baseline set: %.2fs", t))
			else
				UIState.appendLog("Baseline lap failed")
			end
			UIState.publishReady()
		end)
	end
end)

-- LLM config remote event: client HUD fires this to change model/enabled state.
local setLLMConfigEvent = Instance.new("RemoteEvent")
setLLMConfigEvent.Name = "AutoTrack_SetLLMConfig"
setLLMConfigEvent.Parent = ReplicatedStorage

setLLMConfigEvent.OnServerEvent:Connect(function(_player, config)
	if type(config) ~= "table" then return end
	if type(config.enabled) == "boolean" then
		LLMConfig.setEnabled(config.enabled)
	end
	if type(config.model) == "string" then
		LLMConfig.setModel(config.model)
	end
	local cfg = LLMConfig.get()
	UIState.setLLMConfig(cfg.enabled, cfg.modelId)
	UIState.appendLog(string.format("LLM %s: %s", cfg.enabled and "ON" or "OFF", cfg.displayName))
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
