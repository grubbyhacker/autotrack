local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local JobLock = require(script.Parent.JobLock)

local baselineLapTime: number? = nil

print("[AutoTrack] Booting Phase 1...")

local sectors = TrackGenerator.generate(Constants.TRACK_ROWS, Constants.TRACK_COLS)
TrackGenerator.buildParts(sectors)
SectorRegistry.init(6)

local startCF = TrackGenerator.canonicalStart()
local car = VerifierCar.spawn(startCF)
local waypoints = TrackGenerator.getLapWaypoints(sectors)

assert(JobLock.tryAcquire(), "JobLock busy")
local ok, result = pcall(function()
	return VerifierController.runLap(car, waypoints)
end)
JobLock.release()

if not ok then
	error(result)
end

if result.success then
	baselineLapTime = result.metrics.lap_time
	print(string.format("[AutoTrack] Baseline lap complete: %.2fs", baselineLapTime))
else
	print("[AutoTrack] Baseline lap FAILED: " .. tostring(result.failure and result.failure.type or "unknown"))
end
