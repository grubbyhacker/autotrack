local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)
local Tracer = require(script.Parent.Tracer)

local baselineLapTime: number? = nil

print("[AutoTrack] Booting Phase 1...")

local sectors = TrackGenerator.generate(Constants.TRACK_ROWS, Constants.TRACK_COLS)
TrackGenerator.buildParts(sectors)
SectorRegistry.init(6)

local startCF = TrackGenerator.canonicalStart()
local car = VerifierCar.spawn(startCF)
local waypoints = TrackGenerator.getLapWaypoints(sectors)

local function onSectorChange(id: number, entering: boolean)
	if entering then
		Tracer.log(string.format("sector_enter %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
	else
		Tracer.log(string.format("sector_exit %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
	end
end

assert(JobLock.tryAcquire(), "JobLock busy")
Tracer.log("lap_start")
local ok, result = pcall(function()
	return VerifierController.runLap(car, waypoints, sectors, onSectorChange)
end)
JobLock.release()

if not ok then
	error(result)
end

if result.success then
	baselineLapTime = result.metrics.lap_time
	Tracer.log(string.format("lap_complete %.2f", baselineLapTime))
	print(string.format("[AutoTrack] Baseline lap complete: %.2fs", baselineLapTime))
else
	print("[AutoTrack] Baseline lap FAILED: " .. tostring(result.failure and result.failure.type or "unknown"))
end

workspace:SetAttribute("AutoTrack_BaselineLapDone", result.success)
workspace:SetAttribute("AutoTrack_BaselineLapTime", result.success and result.metrics.lap_time or -1)

-- Run Phase 1 test suite automatically after boot.
-- TestRunner.server.luau handles on-demand re-runs once Rojo syncs src/test/.
local okTest, errTest = pcall(function()
	require(script.Parent.TestPhase1).run()
end)
if not okTest then
	print("[TEST ERROR] Phase1 suite failed to load: " .. tostring(errTest))
end
