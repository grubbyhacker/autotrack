local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local RuntimeContext = require(script.Parent.RuntimeContext)
local Tracer = require(script.Parent.Tracer)
local UIState = require(script.Parent.UIState)
local JobLock = require(script.Parent.JobLock)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

local CameraDemo = {}

local _active = false
local _token = 0
local _priorStates = nil
local _restorePending = false

local function cloneParams(params)
	local copy = {}
	for key, value in pairs(params) do
		copy[key] = value
	end
	return copy
end

local function cloneState(state)
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = cloneParams(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function applyCommittedState(state)
	local targetSector = RuntimeContext.getSectorById(state.sector_id)
	SectorApplier.apply(state, targetSector.entry, targetSector.exit)
	SectorRegistry.commit(state)
end

local function restorePriorStates()
	if not _priorStates then
		return
	end
	for sectorId, state in pairs(_priorStates) do
		local restored = cloneState(state)
		restored.version = state.version + 1
		applyCommittedState(restored)
	end
	_priorStates = nil
	_restorePending = false
end

local function onSectorChange(id: number, entering: boolean)
	if entering then
		UIState.setCurrentSector(id)
	end
end

function CameraDemo.isActive(): boolean
	return _active
end

function CameraDemo.start(options): (boolean, string?)
	options = options or {}
	if _active then
		return false, "camera demo already running"
	end
	assert(RuntimeContext.isReady(), "CameraDemo.start: runtime context not ready")

	_active = true
	_token += 1
	local token = _token
	local loop = options.loop ~= false
	_restorePending = false

	_priorStates = {}
	for _, sectorId in ipairs({ 3, 7 }) do
		local committed = SectorRegistry.getCommitted(sectorId)
		assert(committed ~= nil, "CameraDemo.start: missing committed state for sector " .. tostring(sectorId))
		_priorStates[sectorId] = cloneState(committed)
	end

	local jumpDefaults = LevelMappings.DEFAULTS.RampJump
	for _, sectorId in ipairs({ 3, 7 }) do
		applyCommittedState({
			sector_id = sectorId,
			mechanic = "RampJump",
			params = cloneParams(jumpDefaults),
			pads = {
				ingress = "None",
				egress = "None",
			},
			version = (_priorStates[sectorId] and _priorStates[sectorId].version or 0) + 1,
		})
	end

	UIState.setPhase("CameraDemo", "Camera demo loop running")
	UIState.appendLog("Camera demo enabled: RampJump in sectors 3 and 7")
	UIState.setExplanation("Submit '/demo camera' again to stop the demo")
	Tracer.log("camera_demo_start")

	task.spawn(function()
		local lapIndex = 0
		local sectors = RuntimeContext.getSectors()
		local demoWaypoints, demoWaypointSectors, demoSectorKinds = TrackGenerator.getLapPath(sectors)
		local car = RuntimeContext.getCar()
		local startCF = RuntimeContext.getCanonicalStart()

		repeat
			if JobLock.isHeld() then
				task.wait(0.25)
			else
				assert(JobLock.tryAcquire(), "JobLock busy during camera demo")
				Tracer.log("camera_demo_lap_start")
				VerifierCar.reset(startCF)
				UIState.setPhase("CameraDemoLap", "Running camera demo lap...")
				local ok, result = pcall(function()
					return VerifierController.runLap(car, demoWaypoints, demoWaypointSectors, demoSectorKinds, onSectorChange)
				end)
				JobLock.release()

				if _restorePending then
					restorePriorStates()
				end

				if token ~= _token then
					break
				end

				if not ok then
					UIState.setPhase("CameraDemoFailure", "Camera demo lap failed")
					UIState.appendLog("Camera demo failed: " .. tostring(result))
					Tracer.log("camera_demo_lap_error")
					task.wait(0.5)
				elseif result.success then
					lapIndex += 1
					UIState.publishAttemptResult(result)
					UIState.setPhase("CameraDemo", "Camera demo loop running")
					UIState.appendLog(string.format("Camera demo lap %d complete: %.2fs", lapIndex, result.metrics.lap_time))
					Tracer.log(string.format("camera_demo_lap_complete %.2f", result.metrics.lap_time))
					task.wait(0.5)
				else
					UIState.setPhase("CameraDemoFailure", "Camera demo lap failed")
					UIState.appendLog("Camera demo failure: " .. tostring(result.failure and result.failure.type or "unknown"))
					Tracer.log("camera_demo_lap_failed")
					task.wait(0.5)
				end
			end
		until not loop or token ~= _token or not _active

		if token == _token and not loop then
			CameraDemo.stop()
		end
	end)

	return true, nil
end

function CameraDemo.stop(): (boolean, string?)
	if not _active then
		return false, "camera demo not running"
	end

	_active = false
	_token += 1
	if JobLock.isHeld() then
		_restorePending = true
	else
		restorePriorStates()
	end
	UIState.publishReady()
	UIState.appendLog("Camera demo stopped")
	Tracer.log("camera_demo_stop")
	return true, nil
end

return CameraDemo
